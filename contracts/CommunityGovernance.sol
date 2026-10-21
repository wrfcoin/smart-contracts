// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CommunityGovernance
 * @author WRFCoin Development Team
 * @notice Community-driven governance for future system upgrades
 * @dev Stake-weighted voting system with NO administrative override powers
 * 
 * === GOVERNANCE PHILOSOPHY ===
 * 
 * Traditional governance problems:
 * - Admin keys can override community decisions
 * - Low participation due to complex voting
 * - Whale dominance in token-based voting
 * - Emergency powers that bypass governance
 * 
 * WRFCoin decentralized governance:
 * - NO admin override capabilities whatsoever
 * - Quadratic voting to reduce whale influence  
 * - Stake-based participation (skin in the game)
 * - Automatic execution of passed proposals
 * - Emergency governance through economic incentives only
 * 
 * === GOVERNANCE SCOPE ===
 * 
 * What this governance CAN control:
 * - Future contract upgrades via proxy pattern
 * - Economic parameter adjustments (within bounds)
 * - New feature activation/deactivation
 * - Treasury management for protocol development
 * 
 * What this governance CANNOT control:
 * - Existing participant stakes (immutable)
 * - Past transactions or decisions
 * - Emergency pause/stop functionality
 * - Individual account restrictions
 * 
 * === VOTING MECHANICS ===
 * 
 * Quadratic Voting Formula:
 * Voting Power = sqrt(StakeAmount) * QuadraticScaling
 * 
 * This reduces whale dominance while maintaining stake-based security
 *
 * NO ADMIN FUNCTIONS - Pure community control
 *
 * === EMERGENCY-STOP / PAUSE POSTURE (#165) ===
 *
 * This contract intentionally has NO emergency-stop, circuit-breaker, or
 * admin pause, and it has no owner/admin/role mechanism to attach one to
 * (`securityEngine` is a read-only stake oracle, not a privileged actor; the
 * only authorization gate anywhere is `msg.sender == address(this)` for
 * self-executed governance actions). An admin-gated `pause()` is deliberately
 * OUT OF SCOPE by design — see "What this governance CANNOT control:
 * Emergency pause/stop functionality" above and the "NO admin override
 * capabilities whatsoever" / "Pure community control" invariants. Adding one
 * would reintroduce exactly the admin-override trust model this contract was
 * built to eliminate.
 *
 * This is therefore an ACCEPTED, DOCUMENTED risk for the testnet: if a bug or
 * abuse surfaces in voting/execution, the remedy is a governed upgrade via the
 * proxy pattern (or redeploy/migration), NOT an operator freeze. Contracts
 * that DO hold funds or admin authority (e.g. ProofOfPublishing, WRFToken,
 * RewardDistributor) carry Pausable circuit breakers instead; this admin-less
 * governance contract does not, by design (#165, Option 1).
 */
contract CommunityGovernance is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================================
    //                                 CONSTANTS
    // ============================================================================
    
    /// @dev Minimum proposal deposit (0.1 ETH)
    uint256 public constant MIN_PROPOSAL_DEPOSIT = 0.1 ether;
    
    /// @dev Maximum proposal deposit to prevent spam (10 ETH)
    uint256 public constant MAX_PROPOSAL_DEPOSIT = 10 ether;
    
    /// @dev Voting period length (7 days)
    uint256 public constant VOTING_PERIOD = 7 days;
    
    /// @dev Proposal execution delay (2 days after passing)
    uint256 public constant EXECUTION_DELAY = 2 days;
    
    /// @dev Proposal expiration time (30 days total)
    uint256 public constant PROPOSAL_EXPIRY = 30 days;
    
    /// @dev Quorum requirement (20% of total stake)
    uint256 public constant QUORUM_PERCENTAGE = 2000; // 20% in basis points
    
    /// @dev Majority threshold (60% of votes)
    uint256 public constant MAJORITY_THRESHOLD = 6000; // 60% in basis points
    
    /// @dev Quadratic scaling factor for voting power
    uint256 public constant QUADRATIC_SCALING = 1000;
    
    /// @dev Maximum voting power to prevent excessive concentration
    uint256 public constant MAX_VOTING_POWER = 10000;
    
    /// @dev Maximum effective stake for voting power calculation (1000 ETH)
    uint256 public constant MAX_EFFECTIVE_STAKE = 1000 ether;
    
    /// @dev Stake consolidation penalty for split stakes
    uint256 public constant CONSOLIDATION_PENALTY = 5000; // 50% penalty for detected splitting
    
    /// @dev Basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;

    // ============================================================================
    //                                   ENUMS
    // ============================================================================
    
    enum ProposalType {
        PARAMETER_CHANGE,   // Adjust economic parameters within bounds
        FEATURE_TOGGLE,     // Enable/disable system features
        TREASURY_SPEND,     // Allocate treasury funds
        CONTRACT_UPGRADE,   // Upgrade contract implementations
        EMERGENCY_ACTION    // Emergency responses to critical issues
    }
    
    enum ProposalStatus {
        PENDING,        // Recently created, voting not started
        ACTIVE,         // Currently accepting votes
        PASSED,         // Passed voting, awaiting execution
        EXECUTED,       // Successfully executed
        REJECTED,       // Failed to meet voting requirements
        EXPIRED,        // Expired without execution
        CANCELLED       // Cancelled by proposer (before voting starts)
    }

    // ============================================================================
    //                                  STRUCTS
    // ============================================================================
    
    /// @dev Core proposal structure
    struct Proposal {
        uint256 id;                     // Unique proposal identifier
        address proposer;               // Who created the proposal
        ProposalType proposalType;      // Category of proposal
        string title;                   // Short description
        string description;             // Detailed proposal description
        bytes32 parametersHash;         // Hash of parameters to change
        bytes executionData;            // Encoded function call data
        address targetContract;         // Contract to execute against
        uint256 deposit;                // ETH deposited by proposer
        uint256 createdAt;              // Creation timestamp
        uint256 votingStartsAt;         // When voting begins
        uint256 votingEndsAt;           // When voting ends  
        uint256 executionTime;          // When execution is allowed
        uint256 expiresAt;              // When proposal expires
        ProposalStatus status;          // Current status
        uint256 yesVotes;               // Total yes voting power
        uint256 noVotes;                // Total no voting power
        uint256 totalParticipants;      // Number of voters
        uint256 participatingStake;     // Sum of raw stake of voters (quorum basis)
        mapping(address => bool) hasVoted; // Track who voted
        mapping(address => bool) voteChoice; // Track vote choices
    }
    
    /// @dev Voter record
    struct Voter {
        uint256 stakeAmount;            // Amount of stake (from security engine)
        uint256 effectiveStake;         // Effective stake after consolidation detection
        uint256 votingPower;            // Calculated quadratic voting power
        uint256 lastVoteTime;           // Last time this address voted
        uint256 totalProposalsVoted;    // Total proposals participated in
        uint256 governanceScore;        // Reputation for governance participation
        bool hasConsolidationPenalty;   // Whether address has stake splitting penalty
        uint256 linkedStakeCount;       // Number of potentially linked addresses
    }
    
    /// @dev Parameter change proposal details
    struct ParameterChange {
        string parameterName;           // Name of parameter to change
        uint256 currentValue;           // Current parameter value
        uint256 proposedValue;          // Proposed new value
        uint256 minimumBound;           // Minimum allowed value
        uint256 maximumBound;           // Maximum allowed value
        string rationale;               // Reasoning for the change
    }
    
    /// @dev Treasury spending proposal details
    struct TreasurySpend {
        address recipient;              // Who will receive the funds
        uint256 amount;                 // Amount to send
        string purpose;                 // Purpose of the spending
        bytes32 milestoneHash;          // Hash of milestone requirements
        bool requiresMilestones;        // Whether payment requires milestones
    }

    // ============================================================================
    //                              STATE VARIABLES
    // ============================================================================
    
    /// @dev Proposal storage
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    
    /// @dev Voter information
    mapping(address => Voter) public voters;
    
    /// @dev Parameter change details
    mapping(uint256 => ParameterChange) public parameterChanges;
    
    /// @dev Treasury spending details
    mapping(uint256 => TreasurySpend) public treasurySpends;
    
    /// @dev Integration with other contracts
    address public immutable securityEngine;
    address public immutable fairLaunchContract;
    
    /// @dev Stake consolidation detection
    mapping(bytes32 => uint256) public deviceFingerprints;
    mapping(address => bytes32[]) public addressFingerprints;
    mapping(bytes32 => address[]) public fingerprintAddresses;
    uint256 public constant MAX_ADDRESSES_PER_FINGERPRINT = 3;
    
    /// @dev Treasury management
    uint256 public treasuryBalance;
    mapping(address => uint256) public treasuryAllocations;
    
    /// @dev Governance parameter values keyed by keccak256(parameterName)
    mapping(bytes32 => uint256) public governanceParameters;

    /// @dev Emergency action target whitelist
    mapping(address => bool) public approvedTargets;

    /// @dev Governance statistics
    uint256 public totalStakeParticipating;
    uint256 public totalProposalsPassed;
    uint256 public totalProposalsExecuted;
    uint256 public activeProposals;

    // ============================================================================
    //                                  EVENTS
    // ============================================================================
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType indexed proposalType,
        string title,
        uint256 deposit
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool choice,
        uint256 votingPower,
        uint256 timestamp
    );
    
    event ProposalPassed(
        uint256 indexed proposalId,
        uint256 yesVotes,
        uint256 noVotes,
        uint256 totalParticipants,
        uint256 executionTime
    );
    
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor,
        bool success,
        bytes returnData
    );
    
    event ProposalRejected(
        uint256 indexed proposalId,
        uint256 yesVotes,
        uint256 noVotes,
        uint256 quorumReached,
        string reason
    );
    
    event ParameterChanged(
        string indexed parameterName,
        uint256 oldValue,
        uint256 newValue,
        uint256 proposalId
    );

    event TargetApprovalUpdated(address indexed target, bool approved);
    
    event TreasuryFundsAllocated(
        address indexed recipient,
        uint256 amount,
        string purpose,
        uint256 proposalId
    );
    
    event GovernanceParticipation(
        address indexed voter,
        uint256 newVotingPower,
        uint256 governanceScore,
        uint256 totalProposalsVoted
    );

    event GovernanceParameterSet(string parameterName, uint256 value);

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Deploy community governance system
     * @param _securityEngine Address of economic security engine
     * @param _fairLaunchContract Address of main fair launch contract
     */
    constructor(address _securityEngine, address _fairLaunchContract) {
        require(_securityEngine != address(0), "Invalid security engine");
        require(_fairLaunchContract != address(0), "Invalid fair launch contract");
        
        securityEngine = _securityEngine;
        fairLaunchContract = _fairLaunchContract;
        
        // NO ADMIN ROLES - Governance is purely community-driven
    }

    // ============================================================================
    //                            PROPOSAL CREATION
    // ============================================================================
    
    /**
     * @notice Create a parameter change proposal
     * @param title Short title for the proposal
     * @param description Detailed description
     * @param parameterName Name of parameter to change
     * @param proposedValue New value for the parameter
     * @param minimumBound Minimum allowed value
     * @param maximumBound Maximum allowed value
     * @param rationale Reasoning for the change
     */
    function createParameterProposal(
        string calldata title,
        string calldata description,
        string calldata parameterName,
        uint256 proposedValue,
        uint256 minimumBound,
        uint256 maximumBound,
        string calldata rationale
    ) external payable nonReentrant returns (uint256 proposalId) {
        require(msg.value >= MIN_PROPOSAL_DEPOSIT, "Insufficient deposit");
        require(msg.value <= MAX_PROPOSAL_DEPOSIT, "Deposit too high");
        require(_hasVotingPower(msg.sender), "No voting power");
        require(proposedValue >= minimumBound && proposedValue <= maximumBound, "Value out of bounds");
        
        proposalId = ++proposalCount;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.proposalType = ProposalType.PARAMETER_CHANGE;
        proposal.title = title;
        proposal.description = description;
        proposal.parametersHash = keccak256(abi.encode(parameterName, proposedValue));
        proposal.deposit = msg.value;
        proposal.createdAt = block.timestamp;
        proposal.votingStartsAt = block.timestamp + 1 days; // 1 day delay before voting
        proposal.votingEndsAt = proposal.votingStartsAt + VOTING_PERIOD;
        proposal.executionTime = proposal.votingEndsAt + EXECUTION_DELAY;
        proposal.expiresAt = proposal.createdAt + PROPOSAL_EXPIRY;
        proposal.status = ProposalStatus.PENDING;
        
        // Store parameter change details
        parameterChanges[proposalId] = ParameterChange({
            parameterName: parameterName,
            currentValue: _getCurrentParameterValue(parameterName),
            proposedValue: proposedValue,
            minimumBound: minimumBound,
            maximumBound: maximumBound,
            rationale: rationale
        });
        
        activeProposals++;
        
        emit ProposalCreated(proposalId, msg.sender, ProposalType.PARAMETER_CHANGE, title, msg.value);
        
        return proposalId;
    }
    
    /**
     * @notice Create a treasury spending proposal
     * @param title Short title for the proposal
     * @param description Detailed description
     * @param recipient Address to receive funds
     * @param amount Amount to allocate
     * @param purpose Purpose of the spending
     */
    function createTreasuryProposal(
        string calldata title,
        string calldata description,
        address recipient,
        uint256 amount,
        string calldata purpose
    ) external payable nonReentrant returns (uint256 proposalId) {
        require(msg.value >= MIN_PROPOSAL_DEPOSIT, "Insufficient deposit");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0 && amount <= treasuryBalance, "Invalid amount");
        require(_hasVotingPower(msg.sender), "No voting power");
        
        proposalId = ++proposalCount;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.proposalType = ProposalType.TREASURY_SPEND;
        proposal.title = title;
        proposal.description = description;
        proposal.deposit = msg.value;
        proposal.createdAt = block.timestamp;
        proposal.votingStartsAt = block.timestamp + 1 days;
        proposal.votingEndsAt = proposal.votingStartsAt + VOTING_PERIOD;
        proposal.executionTime = proposal.votingEndsAt + EXECUTION_DELAY;
        proposal.expiresAt = proposal.createdAt + PROPOSAL_EXPIRY;
        proposal.status = ProposalStatus.PENDING;
        
        // Store treasury spending details
        treasurySpends[proposalId] = TreasurySpend({
            recipient: recipient,
            amount: amount,
            purpose: purpose,
            milestoneHash: bytes32(0),
            requiresMilestones: false
        });
        
        activeProposals++;
        
        emit ProposalCreated(proposalId, msg.sender, ProposalType.TREASURY_SPEND, title, msg.value);
        
        return proposalId;
    }
    
    /**
     * @notice Create an emergency action proposal
     * @param title Short title for the proposal
     * @param description Detailed description
     * @param targetContract Contract to execute against
     * @param executionData Encoded function call
     */
    function createEmergencyProposal(
        string calldata title,
        string calldata description,
        address targetContract,
        bytes calldata executionData
    ) external payable nonReentrant returns (uint256 proposalId) {
        require(msg.value >= MIN_PROPOSAL_DEPOSIT * 2, "Insufficient deposit for emergency"); // Higher deposit
        require(targetContract != address(0), "Invalid target contract");
        require(targetContract != address(this), "CommunityGovernance: Cannot target self");
        require(approvedTargets[targetContract], "CommunityGovernance: Target not approved");
        require(_hasVotingPower(msg.sender), "No voting power");
        
        proposalId = ++proposalCount;
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.proposalType = ProposalType.EMERGENCY_ACTION;
        proposal.title = title;
        proposal.description = description;
        proposal.executionData = executionData;
        proposal.targetContract = targetContract;
        proposal.deposit = msg.value;
        proposal.createdAt = block.timestamp;
        proposal.votingStartsAt = block.timestamp; // Immediate voting for emergencies
        proposal.votingEndsAt = proposal.votingStartsAt + (VOTING_PERIOD / 2); // Shorter voting period
        proposal.executionTime = proposal.votingEndsAt; // No execution delay for emergencies
        proposal.expiresAt = proposal.createdAt + PROPOSAL_EXPIRY;
        proposal.status = ProposalStatus.ACTIVE;
        
        activeProposals++;
        
        emit ProposalCreated(proposalId, msg.sender, ProposalType.EMERGENCY_ACTION, title, msg.value);
        
        return proposalId;
    }

    // ============================================================================
    //                               VOTING SYSTEM
    // ============================================================================
    
    /**
     * @notice Register device fingerprint for stake consolidation detection
     * @param deviceFingerprint Hash of device characteristics (IP, browser, etc.)
     */
    function registerDeviceFingerprint(bytes32 deviceFingerprint) external {
        require(_hasVotingPower(msg.sender), "No voting power");
        
        // Check if this fingerprint already has too many addresses
        address[] storage addresses = fingerprintAddresses[deviceFingerprint];
        if (addresses.length >= MAX_ADDRESSES_PER_FINGERPRINT) {
            // Mark all addresses with this fingerprint as having consolidation penalty
            for (uint256 i = 0; i < addresses.length; i++) {
                voters[addresses[i]].hasConsolidationPenalty = true;
                voters[addresses[i]].linkedStakeCount = addresses.length;
            }
            // Also mark the new address
            voters[msg.sender].hasConsolidationPenalty = true;
            voters[msg.sender].linkedStakeCount = addresses.length + 1;
        }
        
        // Add to fingerprint tracking
        addressFingerprints[msg.sender].push(deviceFingerprint);
        fingerprintAddresses[deviceFingerprint].push(msg.sender);
        deviceFingerprints[deviceFingerprint] = block.timestamp;
    }

    /**
     * @notice Cast a vote on a proposal
     * @param proposalId ID of proposal to vote on
     * @param support Whether to vote yes (true) or no (false)
     */
    function vote(uint256 proposalId, bool support) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.ACTIVE || 
                (proposal.status == ProposalStatus.PENDING && block.timestamp >= proposal.votingStartsAt), 
                "Proposal not active for voting");
        require(block.timestamp >= proposal.votingStartsAt, "Voting not started");
        require(block.timestamp <= proposal.votingEndsAt, "Voting period ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        require(_hasVotingPower(msg.sender), "No voting power");
        
        // Update proposal status to active if it was pending
        if (proposal.status == ProposalStatus.PENDING) {
            proposal.status = ProposalStatus.ACTIVE;
        }
        
        // Calculate quadratic voting power
        uint256 votingPower = _calculateVotingPower(msg.sender);
        require(votingPower > 0, "No voting power");
        
        // Record the vote
        proposal.hasVoted[msg.sender] = true;
        proposal.voteChoice[msg.sender] = support;
        proposal.totalParticipants++;

        if (support) {
            proposal.yesVotes += votingPower;
        } else {
            proposal.noVotes += votingPower;
        }

        // Accumulate raw participating stake for quorum enforcement.
        // _calculateVotingPower() has just cached the voter's raw stake on their
        // record; use it so quorum is measured against total staked supply
        // (raw-stake units) rather than quadratic voting power.
        uint256 voterStake = voters[msg.sender].stakeAmount;
        proposal.participatingStake += voterStake;
        totalStakeParticipating += voterStake;

        // Update voter record
        Voter storage voter = voters[msg.sender];
        voter.votingPower = votingPower;
        voter.lastVoteTime = block.timestamp;
        voter.totalProposalsVoted++;
        voter.governanceScore = _calculateGovernanceScore(msg.sender);
        
        emit VoteCast(proposalId, msg.sender, support, votingPower, block.timestamp);
        emit GovernanceParticipation(msg.sender, votingPower, voter.governanceScore, voter.totalProposalsVoted);
    }
    
    /**
     * @notice Finalize voting and determine proposal outcome
     * @param proposalId ID of proposal to finalize
     */
    function finalizeVoting(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.ACTIVE, "Proposal not active");
        require(block.timestamp > proposal.votingEndsAt, "Voting period not ended");
        
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        // Quorum is measured against the total staked supply (raw-stake units),
        // using the raw stake that actually participated in THIS proposal. The
        // previous code compared quadratic voting power against an unassigned
        // `totalStakeParticipating` (always 0), so quorum was never enforced and
        // a single voter could pass any proposal.
        uint256 totalEligibleStake = ISecurityEngine(securityEngine).totalSecurityStake();
        uint256 requiredQuorum = (totalEligibleStake * QUORUM_PERCENTAGE) / BASIS_POINTS;

        // Check if quorum was met (participating raw stake vs required)
        if (proposal.participatingStake < requiredQuorum) {
            proposal.status = ProposalStatus.REJECTED;
            activeProposals--;
            
            // Return deposit to proposer
            Address.sendValue(payable(proposal.proposer), proposal.deposit);
            
            emit ProposalRejected(proposalId, proposal.yesVotes, proposal.noVotes, totalVotes, "Quorum not met");
            return;
        }
        
        // Check if majority was reached
        uint256 yesPercentage = (proposal.yesVotes * BASIS_POINTS) / totalVotes;
        if (yesPercentage >= MAJORITY_THRESHOLD) {
            proposal.status = ProposalStatus.PASSED;
            totalProposalsPassed++;
            
            emit ProposalPassed(
                proposalId,
                proposal.yesVotes,
                proposal.noVotes,
                proposal.totalParticipants,
                proposal.executionTime
            );
        } else {
            proposal.status = ProposalStatus.REJECTED;
            activeProposals--;
            
            // Return deposit to proposer
            Address.sendValue(payable(proposal.proposer), proposal.deposit);
            
            emit ProposalRejected(proposalId, proposal.yesVotes, proposal.noVotes, totalVotes, "Majority not reached");
        }
    }

    // ============================================================================
    //                           PROPOSAL EXECUTION
    // ============================================================================
    
    /**
     * @notice Execute a passed proposal
     * @param proposalId ID of proposal to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.PASSED, "Proposal not passed");
        require(block.timestamp >= proposal.executionTime, "Execution delay not met");
        require(block.timestamp <= proposal.expiresAt, "Proposal expired");
        
        proposal.status = ProposalStatus.EXECUTED;
        activeProposals--;
        totalProposalsExecuted++;
        
        bool success = false;
        bytes memory returnData;
        
        if (proposal.proposalType == ProposalType.PARAMETER_CHANGE) {
            success = _executeParameterChange(proposalId);
        } else if (proposal.proposalType == ProposalType.TREASURY_SPEND) {
            success = _executeTreasurySpend(proposalId);
        } else if (proposal.proposalType == ProposalType.EMERGENCY_ACTION) {
            (success, returnData) = proposal.targetContract.call(proposal.executionData);
        }
        
        // Return deposit to proposer if execution was successful
        if (success) {
            Address.sendValue(payable(proposal.proposer), proposal.deposit);
        }
        
        emit ProposalExecuted(proposalId, msg.sender, success, returnData);
    }

    /**
     * @notice Approve or revoke an emergency action target contract
     * @dev Only callable by the governance contract itself (via a PARAMETER_CHANGE proposal)
     */
    function setApprovedTarget(address target, bool approved) external {
        require(msg.sender == address(this), "CommunityGovernance: Only via governance");
        require(target != address(0), "CommunityGovernance: Invalid target");
        require(target != address(this), "CommunityGovernance: Cannot approve self");
        approvedTargets[target] = approved;
        emit TargetApprovalUpdated(target, approved);
    }

    // ============================================================================
    //                              INTERNAL FUNCTIONS
    // ============================================================================
    
    /**
     * @dev Calculate quadratic voting power for an address with anti-manipulation security
     */
    function _calculateVotingPower(address voter) internal returns (uint256) {
        // Get stake amount from security engine
        (, uint256 stakeAmount,,,,,,,) = ISecurityEngine(securityEngine).securityRecords(voter);
        
        if (stakeAmount == 0) return 0;
        
        // Apply maximum effective stake cap to prevent whale dominance
        uint256 effectiveStake = stakeAmount;
        if (effectiveStake > MAX_EFFECTIVE_STAKE) {
            effectiveStake = MAX_EFFECTIVE_STAKE;
        }
        
        // Check for stake consolidation penalties
        Voter storage voterRecord = voters[voter];
        if (voterRecord.hasConsolidationPenalty) {
            effectiveStake = (effectiveStake * (BASIS_POINTS - CONSOLIDATION_PENALTY)) / BASIS_POINTS;
        }
        
        // Quadratic voting: sqrt(effectiveStake) * scaling factor
        uint256 votingPower = _sqrt(effectiveStake) * QUADRATIC_SCALING / 1e9; // Adjust for ETH decimals
        
        // Apply additional penalty for detected stake splitting
        if (voterRecord.linkedStakeCount > 1) {
            uint256 splittingPenalty = voterRecord.linkedStakeCount * 1000; // 10% per additional linked address
            if (splittingPenalty > 5000) splittingPenalty = 5000; // Cap at 50% penalty
            votingPower = (votingPower * (BASIS_POINTS - splittingPenalty)) / BASIS_POINTS;
        }
        
        // Cap voting power to prevent excessive concentration
        if (votingPower > MAX_VOTING_POWER) {
            votingPower = MAX_VOTING_POWER;
        }
        
        // Update voter record
        voterRecord.stakeAmount = stakeAmount;
        voterRecord.effectiveStake = effectiveStake;
        
        return votingPower;
    }
    
    /**
     * @dev Check if address has voting power
     */
    function _hasVotingPower(address voter) internal view returns (bool) {
        (, uint256 stakeAmount,,,,,,,) = ISecurityEngine(securityEngine).securityRecords(voter);
        return stakeAmount > 0;
    }
    
    /**
     * @dev Calculate governance participation score
     */
    function _calculateGovernanceScore(address voter) internal view returns (uint256) {
        Voter memory voterRecord = voters[voter];
        
        // Base score from participation
        uint256 participationScore = voterRecord.totalProposalsVoted * 100;
        
        // Bonus for consistent participation
        uint256 consistencyBonus = 0;
        if (voterRecord.totalProposalsVoted >= 10) {
            consistencyBonus = 500; // 5% bonus
        } else if (voterRecord.totalProposalsVoted >= 5) {
            consistencyBonus = 200; // 2% bonus
        }
        
        // Recent participation bonus
        uint256 recentBonus = 0;
        if (block.timestamp - voterRecord.lastVoteTime <= 30 days) {
            recentBonus = 300; // 3% bonus for recent participation
        }
        
        uint256 totalScore = participationScore + consistencyBonus + recentBonus;
        return totalScore > 10000 ? 10000 : totalScore; // Cap at 100%
    }
    
    /**
     * @dev Execute parameter change proposal
     */
    function _executeParameterChange(uint256 proposalId) internal returns (bool) {
        ParameterChange storage change = parameterChanges[proposalId];

        bytes32 key = keccak256(abi.encodePacked(change.parameterName));
        uint256 oldValue = governanceParameters[key];
        governanceParameters[key] = change.proposedValue;

        emit ParameterChanged(
            change.parameterName,
            oldValue,
            change.proposedValue,
            proposalId
        );

        return true;
    }
    
    /**
     * @dev Execute treasury spending proposal
     */
    function _executeTreasurySpend(uint256 proposalId) internal returns (bool) {
        TreasurySpend storage spend = treasurySpends[proposalId];
        
        require(spend.amount <= treasuryBalance, "Insufficient treasury balance");
        
        treasuryBalance -= spend.amount;
        treasuryAllocations[spend.recipient] += spend.amount;
        
        Address.sendValue(payable(spend.recipient), spend.amount);
        
        emit TreasuryFundsAllocated(spend.recipient, spend.amount, spend.purpose, proposalId);
        
        return true;
    }
    
    /**
     * @dev Get current value of a parameter (placeholder)
     */
    function _getCurrentParameterValue(string memory parameterName) internal view returns (uint256) {
        return governanceParameters[keccak256(abi.encodePacked(parameterName))];
    }
    
    /**
     * @dev Calculate square root using Babylonian method
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // ============================================================================
    //                               VIEW FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Get proposal details
     * @param proposalId ID of proposal to query
     */
    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        ProposalType proposalType,
        string memory title,
        string memory description,
        uint256 deposit,
        uint256 createdAt,
        uint256 votingStartsAt,
        uint256 votingEndsAt,
        uint256 executionTime,
        ProposalStatus status,
        uint256 yesVotes,
        uint256 noVotes,
        uint256 totalParticipants
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.proposer,
            proposal.proposalType,
            proposal.title,
            proposal.description,
            proposal.deposit,
            proposal.createdAt,
            proposal.votingStartsAt,
            proposal.votingEndsAt,
            proposal.executionTime,
            proposal.status,
            proposal.yesVotes,
            proposal.noVotes,
            proposal.totalParticipants
        );
    }
    
    /**
     * @notice Get voter information
     * @param voter Address to query
     * @return Voter details
     */
    function getVoter(address voter) external view returns (Voter memory) {
        return voters[voter];
    }
    
    /**
     * @notice Get current voting power for an address
     * @param voter Address to check
     * @return Current voting power
     */
    function getCurrentVotingPower(address voter) external view returns (uint256) {
        (, uint256 stakeAmount,,,,,,,) = ISecurityEngine(securityEngine).securityRecords(voter);
        if (stakeAmount == 0) return 0;
        
        uint256 votingPower = _sqrt(stakeAmount) * QUADRATIC_SCALING / 1e9;
        return votingPower > MAX_VOTING_POWER ? MAX_VOTING_POWER : votingPower;
    }
    
    /**
     * @notice Get governance statistics
     */
    function getGovernanceStats() external view returns (
        uint256 _proposalCount,
        uint256 _activeProposals,
        uint256 _totalProposalsPassed,
        uint256 _totalProposalsExecuted,
        uint256 _treasuryBalance,
        uint256 _totalStakeParticipating
    ) {
        return (
            proposalCount,
            activeProposals,
            totalProposalsPassed,
            totalProposalsExecuted,
            treasuryBalance,
            totalStakeParticipating
        );
    }

    // ============================================================================
    //                              TREASURY MANAGEMENT
    // ============================================================================
    
    /**
     * @notice Add funds to treasury
     * @dev Anyone can contribute to the treasury for protocol development
     */
    function addToTreasury() external payable nonReentrant {
        require(msg.value > 0, "Must send ETH");
        treasuryBalance += msg.value;
    }

    // ============================================================================
    //                              RECEIVE FUNCTION
    // ============================================================================
    
    /**
     * @notice Accept ETH for treasury and proposal deposits
     */
    receive() external payable {
        treasuryBalance += msg.value;
    }
}

// ============================================================================
//                              INTERFACE
// ============================================================================

interface ISecurityEngine {
    function securityRecords(address) external view returns (
        uint256 stakeAmount,
        uint256 effectiveStake,
        uint8 level,
        uint256 lastUpdate,
        uint256 totalSlashed,
        uint256 violationCount,
        uint256 reputationScore,
        uint256 totalEarned,
        bool isValidator
    );

    /// @dev Total staked supply across all security records (quorum denominator)
    function totalSecurityStake() external view returns (uint256);
}