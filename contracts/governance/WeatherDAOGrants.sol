// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title WeatherDAOGrants
 * @notice DAO-governed grant program that funds proposals for deploying weather
 *         stations, building integrations, or conducting atmospheric research.
 *
 * Flow:
 *   1. Anyone submits a proposal (requires a small WRF deposit to deter spam).
 *   2. During the VOTING_PERIOD, WRF holders cast weighted votes.
 *      - Quadratic voting: effective power = floor(sqrt(tokenBalance))
 *   3. After the voting period a DAO admin executes or rejects the proposal.
 *   4. Approved proposals receive funds in tranches tied to on-chain milestones.
 *      Each milestone must be verified by the ORACLE_ROLE before the tranche
 *      is released to the grantee.
 *   5. Unused funds can be recovered by a TREASURY_MANAGER_ROLE admin.
 *
 * Treasury:
 *   - Funded by direct `deposit()` calls (e.g., a percentage of block rewards
 *     forwarded from the WRFToken reward distributor).
 *   - Uses ERC-20 WRF token; ETH is not accepted.
 */
contract WeatherDAOGrants is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE            = keccak256("ORACLE_ROLE");
    bytes32 public constant DAO_ADMIN_ROLE         = keccak256("DAO_ADMIN_ROLE");

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    uint256 public constant VOTING_PERIOD     = 7 days;
    uint256 public constant PROPOSAL_DEPOSIT  = 100e18;   // 100 WRF spam guard
    uint256 public constant MAX_MILESTONES    = 5;
    uint256 public constant MAX_GRANT_AMOUNT  = 50_000e18; // 50 000 WRF per grant

    // -----------------------------------------------------------------------
    // Data model
    // -----------------------------------------------------------------------
    enum ProposalStatus {
        Active,     // voting open
        Approved,   // passed, pending milestone release
        Rejected,   // failed or vetoed
        Completed,  // all milestones released
        Cancelled   // withdrawn by proposer before voting ends
    }

    struct Milestone {
        string  description;
        uint256 releaseAmount;  // WRF to release on verification
        bool    verified;
        bool    released;
    }

    struct Proposal {
        uint256     proposalId;
        address     proposer;
        string      title;
        string      descriptionHash;    // IPFS CID of full proposal text
        string      region;             // Target geographic region
        uint256     totalAmount;        // Total WRF requested
        uint256     releasedAmount;     // WRF already disbursed
        ProposalStatus status;
        uint256     submittedAt;
        uint256     votingEndsAt;
        uint256     votesFor;           // quadratic-weighted votes for
        uint256     votesAgainst;       // quadratic-weighted votes against
        uint256     milestoneCount;
        mapping(uint256 => Milestone) milestones;
        mapping(address => bool) hasVoted;
    }

    IERC20 public immutable wrfToken;

    uint256 private _nextProposalId = 1;
    uint256 public  treasuryBalance;

    /// @dev Snapshot timestamp captured at proposal creation for flash-loan-resistant voting
    mapping(uint256 => uint256) public proposalSnapshotTime;

    mapping(uint256 => Proposal) private _proposals;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event Deposited(address indexed from, uint256 amount);
    event ProposalSubmitted(
        uint256 indexed proposalId,
        address indexed proposer,
        string  title,
        uint256 amount
    );
    event Voted(
        uint256 indexed proposalId,
        address indexed voter,
        bool    support,
        uint256 weight
    );
    event ProposalApproved(uint256 indexed proposalId, address indexed admin);
    event ProposalRejected(uint256 indexed proposalId, address indexed admin);
    event ProposalCancelled(uint256 indexed proposalId, address indexed proposer);
    event MilestoneVerified(uint256 indexed proposalId, uint256 milestoneIndex, address indexed oracle);
    event MilestoneReleased(uint256 indexed proposalId, uint256 milestoneIndex, uint256 amount);
    event FundsRecovered(address indexed to, uint256 amount);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error ZeroAddress();
    error InvalidAmount();
    error TreasuryInsufficient(uint256 requested, uint256 available);
    error VotingClosed(uint256 proposalId);
    error VotingStillOpen(uint256 proposalId);
    error AlreadyVoted(address voter, uint256 proposalId);
    error NotProposer(uint256 proposalId, address caller);
    error BadStatus(uint256 proposalId, ProposalStatus expected, ProposalStatus actual);
    error InvalidMilestone(uint256 index);
    error MilestoneAlreadyVerified(uint256 proposalId, uint256 index);
    error MilestoneNotVerified(uint256 proposalId, uint256 index);
    error MilestoneAlreadyReleased(uint256 proposalId, uint256 index);
    error TooManyMilestones();
    error MilestoneSumMismatch(uint256 sum, uint256 total);
    error DepositRequired();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(address _wrfToken, address _daoAdmin, address _oracle) {
        if (_wrfToken == address(0) || _daoAdmin == address(0) || _oracle == address(0))
            revert ZeroAddress();

        wrfToken = IERC20(_wrfToken);

        _grantRole(DEFAULT_ADMIN_ROLE,    msg.sender);
        _grantRole(DAO_ADMIN_ROLE,        _daoAdmin);
        _grantRole(ORACLE_ROLE,           _oracle);
        _grantRole(TREASURY_MANAGER_ROLE, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Treasury funding
    // -----------------------------------------------------------------------

    /**
     * @notice Deposit WRF into the grant treasury.
     *         Intended to be called by the WRFToken reward distributor
     *         or manually by the DAO admin.
     */
    function deposit(uint256 amount) external whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        wrfToken.safeTransferFrom(msg.sender, address(this), amount);
        treasuryBalance += amount;
        emit Deposited(msg.sender, amount);
    }

    // -----------------------------------------------------------------------
    // Proposal lifecycle
    // -----------------------------------------------------------------------

    /**
     * @notice Submit a grant proposal.
     *         The proposer must have approved this contract to spend
     *         PROPOSAL_DEPOSIT WRF (held until cancel/end).
     *
     * @param title             Short proposal title (≤128 chars enforced off-chain)
     * @param descriptionHash   IPFS CID of the full proposal document
     * @param region            Target geographic region string
     * @param totalAmount       Total WRF requested (≤ MAX_GRANT_AMOUNT)
     * @param milestoneDescs    Array of milestone descriptions
     * @param milestoneAmounts  Parallel array of per-milestone WRF amounts; must sum to totalAmount
     */
    function submitProposal(
        string calldata title,
        string calldata descriptionHash,
        string calldata region,
        uint256         totalAmount,
        string[] calldata milestoneDescs,
        uint256[] calldata milestoneAmounts
    ) external whenNotPaused returns (uint256 proposalId) {
        if (totalAmount == 0 || totalAmount > MAX_GRANT_AMOUNT) revert InvalidAmount();
        if (milestoneDescs.length == 0 || milestoneDescs.length > MAX_MILESTONES)
            revert TooManyMilestones();
        if (milestoneDescs.length != milestoneAmounts.length) revert InvalidAmount();

        // Validate milestone amounts sum
        uint256 sum;
        for (uint256 i; i < milestoneAmounts.length; ++i) sum += milestoneAmounts[i];
        if (sum != totalAmount) revert MilestoneSumMismatch(sum, totalAmount);

        // Check treasury can cover it
        if (treasuryBalance < totalAmount) revert TreasuryInsufficient(totalAmount, treasuryBalance);

        // Collect spam-guard deposit
        wrfToken.safeTransferFrom(msg.sender, address(this), PROPOSAL_DEPOSIT);

        proposalId = _nextProposalId++;
        // Capture snapshot one second in the past to guarantee it's checkpointed
        proposalSnapshotTime[proposalId] = block.timestamp > 0 ? block.timestamp - 1 : 0;

        Proposal storage p = _proposals[proposalId];
        p.proposalId    = proposalId;
        p.proposer      = msg.sender;
        p.title         = title;
        p.descriptionHash = descriptionHash;
        p.region        = region;
        p.totalAmount   = totalAmount;
        p.status        = ProposalStatus.Active;
        p.submittedAt   = block.timestamp;
        p.votingEndsAt  = block.timestamp + VOTING_PERIOD;
        p.milestoneCount = milestoneDescs.length;

        for (uint256 i; i < milestoneDescs.length; ++i) {
            p.milestones[i] = Milestone({
                description:   milestoneDescs[i],
                releaseAmount: milestoneAmounts[i],
                verified:      false,
                released:      false
            });
        }

        // Reserve the funds in treasury
        treasuryBalance -= totalAmount;

        emit ProposalSubmitted(proposalId, msg.sender, title, totalAmount);
    }

    /**
     * @notice Cast a vote on an active proposal.
     *         Voting weight = floor(sqrt(voterBalance)) — quadratic voting.
     */
    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = _proposals[proposalId];
        _requireStatus(p, ProposalStatus.Active);
        if (block.timestamp > p.votingEndsAt) revert VotingClosed(proposalId);
        if (p.hasVoted[msg.sender]) revert AlreadyVoted(msg.sender, proposalId);

        p.hasVoted[msg.sender] = true;

        // Use snapshot-based voting power to prevent flash-loan governance attacks
        uint256 snapshotTime = proposalSnapshotTime[proposalId];
        uint256 balance = IVotes(address(wrfToken)).getPastVotes(msg.sender, snapshotTime);
        uint256 weight  = _sqrt(balance);

        if (support) p.votesFor     += weight;
        else         p.votesAgainst += weight;

        emit Voted(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice DAO admin approves or rejects a proposal after voting ends.
     */
    function executeProposal(uint256 proposalId, bool approve) external onlyRole(DAO_ADMIN_ROLE) {
        Proposal storage p = _proposals[proposalId];
        _requireStatus(p, ProposalStatus.Active);
        if (block.timestamp <= p.votingEndsAt) revert VotingStillOpen(proposalId);

        if (approve) {
            p.status = ProposalStatus.Approved;
            emit ProposalApproved(proposalId, msg.sender);
        } else {
            p.status = ProposalStatus.Rejected;
            // Return reserved funds to treasury
            treasuryBalance += p.totalAmount;
            // Return proposer deposit
            wrfToken.safeTransfer(p.proposer, PROPOSAL_DEPOSIT);
            emit ProposalRejected(proposalId, msg.sender);
        }
    }

    /**
     * @notice Proposer can cancel their proposal while voting is still open.
     *         Deposit is forfeited to treasury.
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer != msg.sender) revert NotProposer(proposalId, msg.sender);
        _requireStatus(p, ProposalStatus.Active);
        if (block.timestamp > p.votingEndsAt) revert VotingClosed(proposalId);

        p.status = ProposalStatus.Cancelled;
        // Return reserved grant funds but keep deposit
        treasuryBalance += p.totalAmount;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Milestone management
    // -----------------------------------------------------------------------

    /**
     * @notice Oracle verifies that a grantee has delivered a milestone.
     */
    function verifyMilestone(uint256 proposalId, uint256 milestoneIndex)
        external onlyRole(ORACLE_ROLE)
    {
        Proposal storage p = _proposals[proposalId];
        _requireStatus(p, ProposalStatus.Approved);
        _checkMilestoneIndex(p, milestoneIndex);

        Milestone storage m = p.milestones[milestoneIndex];
        if (m.verified) revert MilestoneAlreadyVerified(proposalId, milestoneIndex);

        m.verified = true;
        emit MilestoneVerified(proposalId, milestoneIndex, msg.sender);
    }

    /**
     * @notice Release the WRF tranche for a verified milestone to the grantee.
     *         Can be called by anyone (permissionless release after verification).
     */
    function releaseMilestone(uint256 proposalId, uint256 milestoneIndex)
        external nonReentrant whenNotPaused
    {
        Proposal storage p = _proposals[proposalId];
        _requireStatus(p, ProposalStatus.Approved);
        _checkMilestoneIndex(p, milestoneIndex);

        Milestone storage m = p.milestones[milestoneIndex];
        if (!m.verified) revert MilestoneNotVerified(proposalId, milestoneIndex);
        if (m.released)  revert MilestoneAlreadyReleased(proposalId, milestoneIndex);

        m.released = true;
        p.releasedAmount += m.releaseAmount;

        wrfToken.safeTransfer(p.proposer, m.releaseAmount);
        emit MilestoneReleased(proposalId, milestoneIndex, m.releaseAmount);

        // Auto-complete when all milestones released
        if (p.releasedAmount == p.totalAmount) {
            p.status = ProposalStatus.Completed;
            // Return proposer deposit
            wrfToken.safeTransfer(p.proposer, PROPOSAL_DEPOSIT);
        }
    }

    // -----------------------------------------------------------------------
    // Treasury recovery
    // -----------------------------------------------------------------------

    /**
     * @notice Recover stranded funds (e.g., from a rejected proposal whose
     *         reserved amount was already returned, or an emergency drain).
     */
    function recoverFunds(address to, uint256 amount)
        external onlyRole(TREASURY_MANAGER_ROLE) nonReentrant
    {
        if (to == address(0))         revert ZeroAddress();
        if (amount > treasuryBalance) revert TreasuryInsufficient(amount, treasuryBalance);

        treasuryBalance -= amount;
        wrfToken.safeTransfer(to, amount);
        emit FundsRecovered(to, amount);
    }

    // -----------------------------------------------------------------------
    // Pause
    // -----------------------------------------------------------------------
    function pause()   external onlyRole(DAO_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DAO_ADMIN_ROLE) { _unpause(); }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        string memory title,
        string memory descriptionHash,
        string memory region,
        uint256 totalAmount,
        uint256 releasedAmount,
        ProposalStatus status,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votingEndsAt,
        uint256 milestoneCount
    ) {
        Proposal storage p = _proposals[proposalId];
        return (
            p.proposer, p.title, p.descriptionHash, p.region,
            p.totalAmount, p.releasedAmount, p.status,
            p.votesFor, p.votesAgainst, p.votingEndsAt, p.milestoneCount
        );
    }

    function getMilestone(uint256 proposalId, uint256 index) external view returns (
        string memory description,
        uint256 releaseAmount,
        bool verified,
        bool released
    ) {
        Milestone storage m = _proposals[proposalId].milestones[index];
        return (m.description, m.releaseAmount, m.verified, m.released);
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _proposals[proposalId].hasVoted[voter];
    }

    function nextProposalId() external view returns (uint256) {
        return _nextProposalId;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _requireStatus(Proposal storage p, ProposalStatus expected) internal view {
        if (p.status != expected)
            revert BadStatus(p.proposalId, expected, p.status);
    }

    function _checkMilestoneIndex(Proposal storage p, uint256 index) internal view {
        if (index >= p.milestoneCount) revert InvalidMilestone(index);
    }

    /// @dev Integer square root (Babylonian method).
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
