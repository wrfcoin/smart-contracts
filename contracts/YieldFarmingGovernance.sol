// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "./YieldFarmingManager.sol";
import "./RewardDistributor.sol";

/**
 * @title YieldFarmingGovernance
 * @dev Governance contract for managing yield farming parameters, proposals, and upgrades
 * Enables decentralized decision making for farming program adjustments
 */
contract YieldFarmingGovernance is AccessControl, ReentrancyGuard, Pausable {
    
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    enum ProposalType {
        UPDATE_REWARD_RATE,
        UPDATE_QUALITY_MULTIPLIERS,
        UPDATE_VINTAGE_BONUSES,
        UPDATE_VESTING_DURATION,
        ADD_REWARD_TOKEN,
        EMERGENCY_ACTION,
        UPDATE_FEE_STRUCTURE,
        UPGRADE_CONTRACT
    }
    
    enum ProposalStatus {
        Pending,
        Active,
        Succeeded,
        Defeated,
        Executed,
        Cancelled,
        Expired
    }
    
    struct Proposal {
        uint256 id;
        address proposer;
        ProposalType proposalType;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalStatus status;
        bool executed;
        bytes executionData;
        string description;
        address targetContract;
        uint256 executionDelay;
    }
    
    struct ProposalParams {
        address newRewardToken;
        uint256 newRewardRate;
        uint256 newEmissionRate;
        uint256 newVestingDuration;
        uint256[] qualityTiers;
        uint256[] qualityMultipliers;
        uint256[] vintageYears;
        uint256[] vintageBonuses;
        uint256 newFeeBasisPoints;
        string tokenType;
    }
    
    struct VotingParams {
        uint256 votingDelay;          // Delay before voting starts (in blocks)
        uint256 votingPeriod;         // Length of voting period (in blocks)
        uint256 proposalThreshold;    // Minimum tokens needed to propose
        uint256 quorumNumerator;      // Quorum percentage (out of 100)
        uint256 executionDelay;       // Delay before execution (in seconds)
    }
    
    // Core contracts
    YieldFarmingManager public yieldFarmingManager;
    RewardDistributor public rewardDistributor;
    IERC20 public governanceToken;
    
    // Governance parameters
    VotingParams public votingParams;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => ProposalParams) public proposalParams;
    
    // Voting tracking
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public votingPower; // proposal => user => power
    mapping(address => uint256) public delegatedVotes; // user => delegated voting power
    mapping(address => address) public delegates; // user => delegate
    
    // Time locks and safety
    mapping(uint256 => uint256) public proposalExecutionTime; // proposal => earliest execution time
    mapping(uint256 => uint256) public proposalSnapshotTime; // proposal => timestamp at creation (used by IVotes.getPastVotes)
    mapping(address => bool) public authorizedExecutors;
    uint256 public constant MAX_EXECUTION_DELAY = 30 days;
    uint256 public constant MIN_EXECUTION_DELAY = 2 days;
    
    // Emergency controls
    bool public emergencyModeActive;
    uint256 public emergencyModeEndTime;
    mapping(address => bool) public emergencyGuardians;
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType proposalType,
        uint256 startTime,
        uint256 endTime,
        string description
    );
    
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support, // 0=against, 1=for, 2=abstain
        uint256 votes,
        string reason
    );
    
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor
    );
    
    event ProposalCancelled(
        uint256 indexed proposalId,
        address indexed canceller
    );
    
    event VotingParamsUpdated(
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumNumerator
    );
    
    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );
    
    event EmergencyModeActivated(
        address indexed guardian,
        uint256 endTime
    );
    
    event EmergencyAction(
        string action,
        address indexed target,
        bytes data
    );
    
    modifier onlyActiveProposal(uint256 proposalId) {
        // Proposals are created as Pending; there is no explicit activation step.
        // A proposal is votable while it is in Pending or Active status AND within
        // the voting window.  The original check for Active alone blocked all voting.
        Proposal storage _p = proposals[proposalId];
        require(
            _p.status == ProposalStatus.Active || _p.status == ProposalStatus.Pending,
            "YieldFarmingGovernance: Proposal not votable"
        );
        require(block.timestamp >= _p.startTime,
                "YieldFarmingGovernance: Voting not started");
        require(block.timestamp <= _p.endTime,
                "YieldFarmingGovernance: Voting ended");
        _;
    }
    
    modifier onlyExecutableProposal(uint256 proposalId) {
        require(proposals[proposalId].status == ProposalStatus.Succeeded, 
                "YieldFarmingGovernance: Proposal not succeeded");
        require(!proposals[proposalId].executed, 
                "YieldFarmingGovernance: Already executed");
        require(block.timestamp >= proposalExecutionTime[proposalId], 
                "YieldFarmingGovernance: Execution delay not passed");
        _;
    }
    
    modifier onlyEmergencyGuardian() {
        require(emergencyGuardians[msg.sender] || hasRole(GUARDIAN_ROLE, msg.sender), 
                "YieldFarmingGovernance: Not emergency guardian");
        _;
    }
    
    constructor(
        address _yieldFarmingManager,
        address _rewardDistributor,
        address _governanceToken
    ) {
        require(_yieldFarmingManager != address(0), "YieldFarmingGovernance: Invalid farming manager");
        require(_rewardDistributor != address(0), "YieldFarmingGovernance: Invalid reward distributor");
        require(_governanceToken != address(0), "YieldFarmingGovernance: Invalid governance token");
        
        yieldFarmingManager = YieldFarmingManager(_yieldFarmingManager);
        rewardDistributor = RewardDistributor(_rewardDistributor);
        governanceToken = IERC20(_governanceToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        
        // Initialize default voting parameters
        votingParams = VotingParams({
            votingDelay: 7200,          // ~1 day at 12s blocks
            votingPeriod: 50400,        // ~7 days at 12s blocks
            proposalThreshold: 10000 * 1e18, // 10,000 tokens
            quorumNumerator: 20,        // 20% quorum
            executionDelay: MIN_EXECUTION_DELAY
        });
        
        authorizedExecutors[msg.sender] = true;
        emergencyGuardians[msg.sender] = true;
    }
    
    /**
     * @dev Create a new governance proposal
     */
    function propose(
        ProposalType proposalType,
        address targetContract,
        bytes calldata executionData,
        string calldata description,
        ProposalParams calldata params
    ) external onlyRole(PROPOSER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        require(
            IVotes(address(governanceToken)).getVotes(msg.sender) >= votingParams.proposalThreshold,
            "YieldFarmingGovernance: Below proposal threshold"
        );

        uint256 proposalId = ++proposalCount;
        uint256 startTime = block.timestamp + votingParams.votingDelay;
        uint256 endTime = startTime + votingParams.votingPeriod;

        // Snapshot the current timestamp for flash-loan-resistant vote weight lookups.
        // WRFToken (ERC20Votes) uses timestamp mode: getPastVotes(account, timestamp).
        // We use block.timestamp - 1 to guarantee the timepoint is strictly in the past
        // when castVote is called, even in the same block as propose().
        proposalSnapshotTime[proposalId] = block.timestamp > 0 ? block.timestamp - 1 : 0;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            proposalType: proposalType,
            startTime: startTime,
            endTime: endTime,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            status: ProposalStatus.Pending,
            executed: false,
            executionData: executionData,
            description: description,
            targetContract: targetContract,
            executionDelay: votingParams.executionDelay
        });

        proposalParams[proposalId] = params;
        proposalExecutionTime[proposalId] = endTime + votingParams.executionDelay;
        
        emit ProposalCreated(proposalId, msg.sender, proposalType, startTime, endTime, description);
        
        return proposalId;
    }
    
    /**
     * @dev Cast a vote on a proposal
     */
    function castVote(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external onlyActiveProposal(proposalId) nonReentrant {
        require(support <= 2, "YieldFarmingGovernance: Invalid vote type");
        require(!hasVoted[proposalId][msg.sender], "YieldFarmingGovernance: Already voted");
        
        uint256 votes = _getVotingPower(msg.sender, proposalId);
        require(votes > 0, "YieldFarmingGovernance: No voting power");
        
        hasVoted[proposalId][msg.sender] = true;
        votingPower[proposalId][msg.sender] = votes;
        
        if (support == 0) {
            proposals[proposalId].againstVotes += votes;
        } else if (support == 1) {
            proposals[proposalId].forVotes += votes;
        } else {
            proposals[proposalId].abstainVotes += votes;
        }
        
        emit VoteCast(msg.sender, proposalId, support, votes, reason);
    }
    
    /**
     * @dev Cast vote with signature (for meta-transactions)
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("YieldFarmingGovernance")),
                block.chainid,
                address(this)
            )
        );
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Ballot(uint256 proposalId,uint8 support)"),
                proposalId,
                support
            )
        );
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = ecrecover(digest, v, r, s);
        
        require(signer != address(0), "YieldFarmingGovernance: Invalid signature");
        require(!hasVoted[proposalId][signer], "YieldFarmingGovernance: Already voted");
        
        // Execute vote as if called by signer
        _castVoteInternal(proposalId, signer, support);
    }
    
    /**
     * @dev Internal vote casting logic
     */
    function _castVoteInternal(uint256 proposalId, address voter, uint8 support) internal {
        uint256 votes = _getVotingPower(voter, proposalId);
        require(votes > 0, "YieldFarmingGovernance: No voting power");
        
        hasVoted[proposalId][voter] = true;
        votingPower[proposalId][voter] = votes;
        
        if (support == 0) {
            proposals[proposalId].againstVotes += votes;
        } else if (support == 1) {
            proposals[proposalId].forVotes += votes;
        } else {
            proposals[proposalId].abstainVotes += votes;
        }
        
        emit VoteCast(voter, proposalId, support, votes, "");
    }
    
    /**
     * @dev Execute a succeeded proposal
     */
    function execute(uint256 proposalId) 
        external 
        onlyExecutableProposal(proposalId) 
        nonReentrant 
    {
        require(
            authorizedExecutors[msg.sender] || hasRole(EXECUTOR_ROLE, msg.sender),
            "YieldFarmingGovernance: Not authorized executor"
        );
        
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        proposal.status = ProposalStatus.Executed;
        
        // Execute the proposal based on type
        _executeProposal(proposalId);
        
        emit ProposalExecuted(proposalId, msg.sender);
    }
    
    /**
     * @dev Execute proposal based on its type
     */
    function _executeProposal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        ProposalParams storage params = proposalParams[proposalId];
        
        if (proposal.proposalType == ProposalType.UPDATE_REWARD_RATE) {
            // Update base reward rate for all farms or specific farm
            if (proposal.targetContract != address(0)) {
                CarbonFarmingPool(proposal.targetContract).updateRewardRate(params.newRewardRate);
            }
        } else if (proposal.proposalType == ProposalType.UPDATE_QUALITY_MULTIPLIERS) {
            // Update quality tier multipliers
            for (uint256 i = 0; i < params.qualityTiers.length; i++) {
                // This would need to be implemented in YieldFarmingManager
                // yieldFarmingManager.setQualityTierMultiplier(params.qualityTiers[i], params.qualityMultipliers[i]);
            }
        } else if (proposal.proposalType == ProposalType.ADD_REWARD_TOKEN) {
            // Add new reward token
            rewardDistributor.configureRewardToken(
                params.newRewardToken,
                params.newRewardRate, // totalAllocated
                params.newEmissionRate,
                params.newVestingDuration,
                params.tokenType
            );
        } else if (proposal.proposalType == ProposalType.UPDATE_VESTING_DURATION) {
            // Update vesting duration for reward token
            rewardDistributor.configureRewardToken(
                params.newRewardToken,
                0, // Keep existing allocation
                0, // Keep existing emission rate
                params.newVestingDuration,
                params.tokenType
            );
        } else if (proposal.proposalType == ProposalType.UPDATE_FEE_STRUCTURE) {
            // Update early vesting fee
            rewardDistributor.setEarlyVestingFee(params.newFeeBasisPoints);
        } else if (proposal.proposalType == ProposalType.EMERGENCY_ACTION) {
            // Execute custom emergency action
            (bool success,) = proposal.targetContract.call(proposal.executionData);
            require(success, "YieldFarmingGovernance: Emergency action failed");
        }
    }
    
    /**
     * @dev Finalize proposal status after voting period
     */
    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.status == ProposalStatus.Active || proposal.status == ProposalStatus.Pending, 
                "YieldFarmingGovernance: Proposal already finalized");
        require(block.timestamp > proposal.endTime, "YieldFarmingGovernance: Voting still active");
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        uint256 quorum = (governanceToken.totalSupply() * votingParams.quorumNumerator) / 100;
        
        if (totalVotes >= quorum && proposal.forVotes > proposal.againstVotes) {
            proposal.status = ProposalStatus.Succeeded;
        } else {
            proposal.status = ProposalStatus.Defeated;
        }
    }
    
    /**
     * @dev Cancel a proposal (by proposer or admin)
     */
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "YieldFarmingGovernance: Cannot cancel"
        );
        require(proposal.status != ProposalStatus.Executed, "YieldFarmingGovernance: Already executed");
        
        proposal.status = ProposalStatus.Cancelled;
        
        emit ProposalCancelled(proposalId, msg.sender);
    }
    
    /**
     * @dev Delegate voting power to another address
     */
    function delegate(address delegatee) external {
        address currentDelegate = delegates[msg.sender];
        uint256 delegatorBalance = governanceToken.balanceOf(msg.sender);
        
        delegates[msg.sender] = delegatee;
        
        if (currentDelegate != address(0)) {
            delegatedVotes[currentDelegate] -= delegatorBalance;
        }
        
        if (delegatee != address(0)) {
            delegatedVotes[delegatee] += delegatorBalance;
        }
        
        emit DelegateChanged(msg.sender, currentDelegate, delegatee);
    }
    
    /**
     * @dev Get voting power for an address at proposal time
     */
    function _getVotingPower(address account, uint256 proposalId) internal view returns (uint256) {
        // Use ERC20Votes getPastVotes at the proposal snapshot timestamp.
        // WRFToken.clock() returns block.timestamp, so getPastVotes takes a Unix timestamp.
        // This is flash-loan-resistant: tokens borrowed and returned within the same second
        // as the snapshot will not appear in the historical checkpoint at snapshot - 1.
        uint256 snapshotTime = proposalSnapshotTime[proposalId];
        require(snapshotTime > 0, "YieldFarmingGovernance: Unknown proposal");
        return IVotes(address(governanceToken)).getPastVotes(account, snapshotTime);
    }

    /**
     * @dev Get current voting power for an address (non-snapshot, for display only)
     */
    function getVotingPower(address account) external view returns (uint256) {
        return IVotes(address(governanceToken)).getVotes(account);
    }
    
    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 proposalId) external view returns (
        Proposal memory proposal,
        ProposalParams memory params
    ) {
        return (proposals[proposalId], proposalParams[proposalId]);
    }
    
    /**
     * @dev Get proposal state
     */
    function getProposalState(uint256 proposalId) external view returns (ProposalStatus) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.status == ProposalStatus.Executed || 
            proposal.status == ProposalStatus.Cancelled ||
            proposal.status == ProposalStatus.Defeated) {
            return proposal.status;
        }
        
        if (block.timestamp < proposal.startTime) {
            return ProposalStatus.Pending;
        }
        
        if (block.timestamp <= proposal.endTime) {
            return ProposalStatus.Active;
        }
        
        // Check if expired (not executed within time limit)
        if (block.timestamp > proposalExecutionTime[proposalId] + MAX_EXECUTION_DELAY) {
            return ProposalStatus.Expired;
        }
        
        // Auto-finalize if not done yet
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        uint256 quorum = (governanceToken.totalSupply() * votingParams.quorumNumerator) / 100;
        
        if (totalVotes >= quorum && proposal.forVotes > proposal.againstVotes) {
            return ProposalStatus.Succeeded;
        } else {
            return ProposalStatus.Defeated;
        }
    }
    
    /**
     * @dev Update voting parameters
     */
    function updateVotingParams(
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_votingDelay <= 50400, "YieldFarmingGovernance: Voting delay too long"); // Max ~7 days
        require(_votingPeriod >= 7200, "YieldFarmingGovernance: Voting period too short"); // Min ~1 day
        require(_votingPeriod <= 201600, "YieldFarmingGovernance: Voting period too long"); // Max ~28 days
        require(_quorumNumerator <= 100, "YieldFarmingGovernance: Invalid quorum");
        
        votingParams.votingDelay = _votingDelay;
        votingParams.votingPeriod = _votingPeriod;
        votingParams.proposalThreshold = _proposalThreshold;
        votingParams.quorumNumerator = _quorumNumerator;
        
        emit VotingParamsUpdated(_votingDelay, _votingPeriod, _proposalThreshold, _quorumNumerator);
    }
    
    /**
     * @dev Emergency pause all farming operations
     */
    function emergencyPause() external onlyEmergencyGuardian {
        require(!emergencyModeActive, "YieldFarmingGovernance: Already in emergency mode");
        
        emergencyModeActive = true;
        emergencyModeEndTime = block.timestamp + 72 hours; // 3 days max
        
        // Pause yield farming
        yieldFarmingManager.pause();
        rewardDistributor.pause();
        
        emit EmergencyModeActivated(msg.sender, emergencyModeEndTime);
        emit EmergencyAction("emergency_pause", address(yieldFarmingManager), "");
    }
    
    /**
     * @dev Emergency unpause (can be called after emergency timeout or by admin)
     */
    function emergencyUnpause() external {
        require(emergencyModeActive, "YieldFarmingGovernance: Not in emergency mode");
        require(
            block.timestamp >= emergencyModeEndTime || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "YieldFarmingGovernance: Emergency timeout not reached"
        );
        
        emergencyModeActive = false;
        emergencyModeEndTime = 0;
        
        // Unpause yield farming
        yieldFarmingManager.unpause();
        rewardDistributor.unpause();
        
        emit EmergencyAction("emergency_unpause", address(yieldFarmingManager), "");
    }
    
    /**
     * @dev Add emergency guardian
     */
    function addEmergencyGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyGuardians[guardian] = true;
    }
    
    /**
     * @dev Remove emergency guardian
     */
    function removeEmergencyGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyGuardians[guardian] = false;
    }
    
    /**
     * @dev Authorize executor
     */
    function authorizeExecutor(address executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedExecutors[executor] = true;
    }
    
    /**
     * @dev Revoke executor authorization
     */
    function revokeExecutor(address executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedExecutors[executor] = false;
    }
    
    /**
     * @dev Check if address is emergency guardian
     */
    function isEmergencyGuardian(address account) external view returns (bool) {
        return emergencyGuardians[account] || hasRole(GUARDIAN_ROLE, account);
    }
    
    /**
     * @dev Get voting parameters
     */
    function getVotingParams() external view returns (VotingParams memory) {
        return votingParams;
    }
}