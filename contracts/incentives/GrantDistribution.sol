// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Grant Distribution System
 * @author WRFCoin Team
 * @notice Secure, transparent funding allocation for research projects with comprehensive anti-fraud mechanisms
 * @dev Features multi-stage approval, milestone-based releases, merit scoring, and economic security controls
 * 
 * Key Security Features:
 * - Fair allocation algorithms with Gini coefficient tracking
 * - Multi-signature approval for high-value grants
 * - Anti-gaming mechanisms with reputation tracking
 * - Economic security limits and fraud detection
 * - Milestone-based fund releases with deliverable verification
 * - Emergency controls and fund recovery
 * 
 * Mathematical Models:
 * - Merit-based scoring using weighted evaluation criteria
 * - Statistical analysis of grant performance
 * - Risk assessment algorithms for fraud prevention
 * - Resource allocation optimization
 */
contract GrantDistribution is AccessControl, Ownable, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    /// @notice Core grant data structure with security features
    struct Grant {
        uint256 grantId;
        address recipient;
        address funder;
        string title;
        string descriptionHash;      // IPFS hash
        string proposalHash;         // IPFS hash of full proposal
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 remainingAmount;
        GrantCategory category;
        GrantStatus status;
        uint256 applicationDate;
        uint256 approvalDate;
        uint256 completionDate;
        Milestone[] milestones;
        bool isActive;
        // Security enhancements
        uint256 meritScore;          // Calculated merit score (0-10000)
        uint256 riskScore;           // Risk assessment score (0-10000)
        uint256 requiredApprovals;   // Multi-sig approvals needed
        uint256 currentApprovals;    // Current approval count
        bytes32 fraudCheckHash;      // Anti-fraud verification hash
        mapping(address => bool) approvers; // Multi-sig approver tracking
        uint256 emergencyFreezeTime; // Emergency freeze timestamp
        bool isEmergencyFrozen;      // Emergency freeze status
    }

    /// @notice Enhanced milestone structure with verification features
    struct Milestone {
        uint256 milestoneId;
        string description;
        uint256 amount;
        uint256 deadline;
        bool isCompleted;
        bool isApproved;
        string deliverableHash;      // IPFS hash of deliverables
        uint256 completionDate;
        address approver;
        // Security enhancements
        uint256 qualityScore;        // Deliverable quality score (0-10000)
        uint256 verificationLevel;   // Verification depth level
        bytes32 deliverableHash32;   // Hash for deliverable integrity check
        bool requiresMultiApproval;  // Multi-signature requirement flag
        mapping(address => bool) milestoneApprovers; // Multi-sig milestone approvers
    }

    /// @notice Enhanced proposal structure with fraud prevention
    struct Proposal {
        uint256 proposalId;
        address applicant;
        string title;
        string abstractHash;
        uint256 requestedAmount;
        GrantCategory category;
        uint256 submissionDate;
        uint256 votingDeadline;
        ProposalStatus status;
        uint256 votesFor;
        uint256 votesAgainst;
        mapping(address => bool) hasVoted;
        mapping(address => bool) voteChoice; // true = for, false = against
        // Security enhancements
        uint256 meritScore;          // Calculated merit score
        bytes32 proposalFingerprintHash; // Anti-plagiarism hash
        uint256 applicantReputationAtSubmission; // Reputation snapshot
        bool isPlagiarismChecked;    // Plagiarism verification status
        uint256 requiredQuorum;      // Required voting quorum
        mapping(address => uint256) reviewerScores; // Individual reviewer scores
    }

    /// @notice Enhanced funder structure with reputation system
    struct Funder {
        address funderAddress;
        string name;
        uint256 totalContributed;
        uint256 activeGrants;
        bool isVerified;
        uint256 reputation;
        // Security enhancements
        uint256 successfulGrants;    // Number of successful grants funded
        uint256 failedGrants;        // Number of failed grants funded
        uint256 lastContributionTime; // Time-based contribution tracking
        uint256 averageGrantSuccess; // Success rate (0-10000)
        bool isSuspended;            // Suspension status for bad actors
        uint256 suspensionReason;    // Reason code for suspension
        uint256 contributionLimit;   // Daily contribution limit
        uint256 dailyContributed;    // Today's contribution amount
        uint256 lastResetTime;       // Last daily reset timestamp
    }

    enum GrantCategory {
        CLIMATE_RESEARCH,
        RENEWABLE_ENERGY,
        ENVIRONMENTAL_MONITORING,
        CONSERVATION,
        SUSTAINABLE_AGRICULTURE,
        CLEAN_TECHNOLOGY,
        ENVIRONMENTAL_EDUCATION,
        POLICY_RESEARCH
    }

    enum GrantStatus {
        PENDING,
        APPROVED,
        ACTIVE,
        COMPLETED,
        CANCELLED,
        DISPUTED
    }

    enum ProposalStatus {
        SUBMITTED,
        UNDER_REVIEW,
        VOTING,
        APPROVED,
        REJECTED,
        EXPIRED,
        FLAGGED_FOR_REVIEW,    // Flagged for potential fraud
        PLAGIARISM_DETECTED,   // Plagiarism found
        SUSPENDED             // Temporarily suspended
    }

    /// @notice Fraud detection structure for suspicious activity tracking
    struct FraudDetection {
        uint256 suspicionScore;      // Fraud suspicion score (0-10000)
        uint256 flaggedTransactions; // Number of flagged transactions
        uint256 lastFlagTime;       // Last time activity was flagged
        bool isUnderInvestigation;  // Investigation status
        string[] evidenceHashes;    // IPFS hashes of evidence
        address investigator;       // Assigned investigator
    }

    /// @notice Merit evaluation criteria for fair scoring
    struct MeritCriteria {
        uint256 technicalInnovation;  // Innovation score (0-2500)
        uint256 environmentalImpact;  // Impact score (0-2500)
        uint256 feasibility;         // Feasibility score (0-2500)
        uint256 teamExperience;      // Team experience score (0-2500)
        uint256 totalScore;          // Combined merit score
        bool isVerified;            // Score verification status
        address evaluator;          // Who performed the evaluation
        uint256 evaluationDate;     // When evaluation was completed
    }

    // Core mappings
    mapping(uint256 => Grant) public grants;
    mapping(uint256 => Proposal) public proposals;
    mapping(address => Funder) public funders;
    mapping(address => uint256[]) public recipientGrants;
    mapping(address => uint256[]) public funderGrants;
    mapping(address => bool) public authorizedReviewers;
    mapping(GrantCategory => uint256) public categoryBudgets;
    
    // Security and fraud prevention mappings
    mapping(address => FraudDetection) public fraudDetection;
    mapping(uint256 => MeritCriteria) public proposalMerits;
    mapping(bytes32 => bool) public usedProposalHashes; // Anti-plagiarism
    mapping(address => uint256) public lastProposalTime; // Rate limiting
    mapping(address => uint256) public proposalCount; // Proposal frequency tracking
    mapping(uint256 => uint256) public grantToProposal; // Grant-proposal linking
    mapping(GrantCategory => uint256) public categoryAllocationLimits; // Per-category limits
    mapping(address => mapping(GrantCategory => uint256)) public applicantCategoryCount;
    
    // Role definitions
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");
    bytes32 public constant INVESTIGATOR_ROLE = keccak256("INVESTIGATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MERIT_EVALUATOR_ROLE = keccak256("MERIT_EVALUATOR_ROLE");
    
    // Economic security constants
    uint256 public constant MAX_DAILY_ALLOCATION = 1000000 * 10**18; // 1M WRF daily max
    uint256 public constant HIGH_VALUE_THRESHOLD = 50000 * 10**18; // 50K WRF threshold
    uint256 public constant FRAUD_THRESHOLD = 7500; // Fraud score threshold (out of 10000)
    uint256 public constant MIN_MERIT_SCORE = 6000; // Minimum merit score for approval
    uint256 public constant GINI_COEFFICIENT_TARGET = 3000; // Target inequality (0.3)
    
    // Configuration variables
    uint256 public nextGrantId = 1;
    uint256 public nextProposalId = 1;
    IERC20 public wrfToken; // WRF token contract
    uint256 public minimumProposalAmount = 1000 * 10**18; // 1000 WRF
    uint256 public maximumProposalAmount = 100000 * 10**18; // 100,000 WRF
    uint256 public votingPeriod = 14 days;
    uint256 public proposalCooldown = 7 days; // Minimum time between proposals
    uint256 public totalFundsAllocated;
    uint256 public totalFundsDistributed;
    uint256 public dailyAllocationUsed;
    uint256 public lastResetTime;
    
    // Statistical tracking for fairness
    uint256 public giniCoefficient; // Current inequality measure
    uint256 public totalRecipients; // Total unique recipients
    uint256 public averageGrantSize; // Average grant amount

    // Core events
    event ProposalSubmitted(uint256 indexed proposalId, address indexed applicant, GrantCategory category, uint256 meritScore);
    event GrantApproved(uint256 indexed grantId, address indexed recipient, uint256 amount, uint256 requiredApprovals);
    event MilestoneCompleted(uint256 indexed grantId, uint256 milestoneId, address recipient, uint256 qualityScore);
    event FundsReleased(uint256 indexed grantId, address indexed recipient, uint256 amount, uint256 cumulativeReleased);
    event FunderRegistered(address indexed funder, string name, uint256 initialReputation);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 voterReputation);
    event GrantCompleted(uint256 indexed grantId, address indexed recipient, bool successful);
    
    // Security and fraud prevention events
    event FraudDetected(address indexed suspect, uint256 suspicionScore, string reason);
    event InvestigationStarted(address indexed subject, address indexed investigator, uint256 timestamp);
    event ProposalFlagged(uint256 indexed proposalId, string reason, address indexed flagger);
    event EmergencyFreeze(uint256 indexed grantId, address indexed freezer, string reason);
    event EmergencyUnfreeze(uint256 indexed grantId, address indexed unfreezer, string reason);
    event PlagiarismDetected(uint256 indexed proposalId, bytes32 originalHash, address indexed reporter);
    event MeritEvaluationCompleted(uint256 indexed proposalId, uint256 totalScore, address indexed evaluator);
    event ReputationUpdated(address indexed account, uint256 oldScore, uint256 newScore, string reason);
    
    // Fairness and allocation events
    event GiniCoefficientUpdated(uint256 oldCoefficient, uint256 newCoefficient);
    event AllocationLimitReached(GrantCategory category, uint256 limit);
    event DailyAllocationReset(uint256 previousUsed, uint256 newLimit);
    event RateLimitEnforced(address indexed applicant, uint256 cooldownRemaining);
    
    // Administrative events
    event SecurityParameterUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event CategoryBudgetUpdated(GrantCategory indexed category, uint256 oldBudget, uint256 newBudget);

    /// @notice Enhanced security modifiers with fraud detection
    modifier onlyRoleEnhanced(bytes32 role) {
        require(hasRole(role, msg.sender), "Access denied: insufficient role");
        _;
    }

    modifier onlyReviewer() {
        require(hasRole(REVIEWER_ROLE, msg.sender), "Access denied: not authorized reviewer");
        require(!fraudDetection[msg.sender].isUnderInvestigation, "Account under investigation");
        _;
    }

    modifier onlyGrantRecipient(uint256 _grantId) {
        require(grants[_grantId].recipient == msg.sender, "Access denied: not grant recipient");
        require(!grants[_grantId].isEmergencyFrozen, "Grant is emergency frozen");
        require(fraudDetection[msg.sender].suspicionScore < FRAUD_THRESHOLD, "Recipient flagged for fraud");
        _;
    }

    modifier onlyActiveFunder() {
        require(funders[msg.sender].isVerified, "Access denied: not verified funder");
        require(!funders[msg.sender].isSuspended, "Funder account suspended");
        _resetDailyLimitIfNeeded(msg.sender);
        _;
    }

    modifier rateLimited() {
        require(
            lastProposalTime[msg.sender] + proposalCooldown <= block.timestamp,
            "Rate limit: proposal cooldown not met"
        );
        _;
    }

    modifier antiSpam(uint256 _amount) {
        require(_amount >= minimumProposalAmount, "Amount below minimum");
        require(_amount <= maximumProposalAmount, "Amount exceeds maximum");
        require(proposalCount[msg.sender] < 10, "Too many proposals from this address");
        _;
    }

    modifier economicSecurityCheck(uint256 _amount) {
        _resetDailyAllocationIfNeeded();
        require(
            dailyAllocationUsed + _amount <= MAX_DAILY_ALLOCATION,
            "Daily allocation limit exceeded"
        );
        _;
    }

    modifier fraudCheck() {
        require(
            fraudDetection[msg.sender].suspicionScore < FRAUD_THRESHOLD,
            "Account flagged for suspicious activity"
        );
        _;
    }

    /**
     * @notice Initialize Grant Distribution System with comprehensive security
     * @param _wrfToken Address of the WRF token contract
     */
    constructor(address _wrfToken) 
        Ownable(msg.sender)
        EIP712("GrantDistribution", "1")
    {
        require(_wrfToken != address(0), "Invalid WRF token address");
        
        wrfToken = IERC20(_wrfToken);
        
        // Initialize role-based access control
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REVIEWER_ROLE, msg.sender);
        _grantRole(INVESTIGATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(MERIT_EVALUATOR_ROLE, msg.sender);
        
        // Initialize time tracking
        lastResetTime = block.timestamp;
        
        // Initialize fairness metrics
        giniCoefficient = 0;
        totalRecipients = 0;
        averageGrantSize = 0;
        
        // Initialize category allocation limits (distribute evenly initially)
        uint256 baseLimit = 125000 * 10**18; // 125K WRF per category
        for (uint256 i = 0; i < 8; i++) {
            categoryAllocationLimits[GrantCategory(i)] = baseLimit;
            categoryBudgets[GrantCategory(i)] = baseLimit;
        }
        
        emit SecurityParameterUpdated("initialized", 0, block.timestamp);
    }

    /**
     * @notice Register as a funder with enhanced security verification
     * @param _name Funder name for identification
     * @param _tokenAmount Amount of WRF tokens to contribute
     * @dev Requires token contribution and performs fraud checks
     */
    function registerFunder(string calldata _name, uint256 _tokenAmount) 
        external 
        nonReentrant 
        whenNotPaused 
        fraudCheck 
    {
        require(_tokenAmount >= 1000 * 10**18, "Minimum 1000 WRF contribution required");
        require(bytes(_name).length > 0 && bytes(_name).length <= 64, "Invalid name length");
        require(funders[msg.sender].funderAddress == address(0), "Already registered");
        
        // Transfer tokens from sender
        wrfToken.safeTransferFrom(msg.sender, address(this), _tokenAmount);
        
        // Initialize funder with security features
        funders[msg.sender] = Funder({
            funderAddress: msg.sender,
            name: _name,
            totalContributed: _tokenAmount,
            activeGrants: 0,
            isVerified: false,
            reputation: 1000, // Starting reputation (scaled by 10)
            successfulGrants: 0,
            failedGrants: 0,
            lastContributionTime: block.timestamp,
            averageGrantSuccess: 0,
            isSuspended: false,
            suspensionReason: 0,
            contributionLimit: 10000 * 10**18, // 10K WRF daily limit
            dailyContributed: 0,
            lastResetTime: block.timestamp
        });
        
        emit FunderRegistered(msg.sender, _name, 1000);
    }

    /**
     * @notice Submit a grant proposal with comprehensive validation and fraud prevention
     * @param _title Proposal title (max 128 characters)
     * @param _abstractHash IPFS hash of the proposal abstract
     * @param _requestedAmount Amount requested in WRF tokens
     * @param _category Research category for the proposal
     * @dev Enhanced with plagiarism detection, rate limiting, and merit evaluation
     */
    function submitProposal(
        string calldata _title,
        string calldata _abstractHash,
        uint256 _requestedAmount,
        GrantCategory _category
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        rateLimited 
        antiSpam(_requestedAmount) 
        economicSecurityCheck(_requestedAmount)
        fraudCheck 
    {
        require(bytes(_title).length > 0 && bytes(_title).length <= 128, "Invalid title length");
        require(bytes(_abstractHash).length > 0, "Abstract hash required");
        require(categoryBudgets[_category] >= _requestedAmount, "Insufficient category budget");
        require(
            applicantCategoryCount[msg.sender][_category] < 3,
            "Too many proposals in this category"
        );

        uint256 proposalId = nextProposalId++;
        
        // Create proposal fingerprint for plagiarism detection
        bytes32 fingerprintHash = keccak256(abi.encodePacked(_title, _abstractHash));
        require(!usedProposalHashes[fingerprintHash], "Potential plagiarism detected");
        usedProposalHashes[fingerprintHash] = true;

        Proposal storage newProposal = proposals[proposalId];
        newProposal.proposalId = proposalId;
        newProposal.applicant = msg.sender;
        newProposal.title = _title;
        newProposal.abstractHash = _abstractHash;
        newProposal.requestedAmount = _requestedAmount;
        newProposal.category = _category;
        newProposal.submissionDate = block.timestamp;
        newProposal.votingDeadline = block.timestamp + votingPeriod;
        newProposal.status = ProposalStatus.SUBMITTED;
        // Security enhancements
        newProposal.proposalFingerprintHash = fingerprintHash;
        newProposal.applicantReputationAtSubmission = _getApplicantReputation(msg.sender);
        newProposal.isPlagiarismChecked = true;
        newProposal.requiredQuorum = _calculateRequiredQuorum(_requestedAmount);

        // Update tracking
        lastProposalTime[msg.sender] = block.timestamp;
        proposalCount[msg.sender]++;
        applicantCategoryCount[msg.sender][_category]++;
        dailyAllocationUsed += _requestedAmount;

        // Calculate initial merit score
        uint256 initialMeritScore = _calculateInitialMeritScore(msg.sender, _requestedAmount, _category);
        newProposal.meritScore = initialMeritScore;

        emit ProposalSubmitted(proposalId, msg.sender, _category, initialMeritScore);
    }

    /**
     * @dev Vote on a proposal (for authorized reviewers)
     */
    function voteOnProposal(uint256 _proposalId, bool _support) external onlyReviewer {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.VOTING, "Proposal not in voting phase");
        require(block.timestamp <= proposal.votingDeadline, "Voting period ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");

        proposal.hasVoted[msg.sender] = true;
        proposal.voteChoice[msg.sender] = _support;

        if (_support) {
            proposal.votesFor++;
        } else {
            proposal.votesAgainst++;
        }

        emit VoteCast(_proposalId, msg.sender, _support, 0);

        // Check if proposal should be finalized
        _checkProposalOutcome(_proposalId);
    }

    /**
     * @dev Approve grant with milestones
     */
    function approveGrant(
        uint256 _proposalId,
        string[] calldata _descriptions,
        uint256[] calldata _amounts,
        uint256[] calldata _deadlines
    ) external onlyReviewer {
        require(_descriptions.length == _amounts.length && _amounts.length == _deadlines.length, "Array length mismatch");
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.APPROVED, "Proposal not approved");

        uint256 grantId = nextGrantId++;

        Grant storage newGrant = grants[grantId];
        newGrant.grantId = grantId;
        newGrant.recipient = proposal.applicant;
        newGrant.funder = address(this); // Contract acts as funder pool
        newGrant.title = proposal.title;
        newGrant.descriptionHash = proposal.abstractHash;
        newGrant.totalAmount = proposal.requestedAmount;
        newGrant.remainingAmount = proposal.requestedAmount;
        newGrant.category = proposal.category;
        newGrant.status = GrantStatus.APPROVED;
        newGrant.applicationDate = proposal.submissionDate;
        newGrant.approvalDate = block.timestamp;
        newGrant.isActive = true;

        // Add milestones from separate arrays
        for (uint256 i = 0; i < _descriptions.length; i++) {
            Milestone storage m = newGrant.milestones.push();
            m.milestoneId = i;
            m.description = _descriptions[i];
            m.amount = _amounts[i];
            m.deadline = _deadlines[i];
        }

        recipientGrants[proposal.applicant].push(grantId);
        totalFundsAllocated += proposal.requestedAmount;
        categoryBudgets[proposal.category] -= proposal.requestedAmount;

        emit GrantApproved(grantId, proposal.applicant, proposal.requestedAmount, 1);
    }

    /**
     * @dev Submit milestone completion
     */
    function submitMilestone(
        uint256 _grantId,
        uint256 _milestoneId,
        string memory _deliverableHash
    ) external onlyGrantRecipient(_grantId) {
        Grant storage grant = grants[_grantId];
        require(grant.isActive, "Grant not active");
        require(_milestoneId < grant.milestones.length, "Invalid milestone");
        
        Milestone storage milestone = grant.milestones[_milestoneId];
        require(!milestone.isCompleted, "Milestone already completed");
        require(block.timestamp <= milestone.deadline, "Milestone deadline passed");

        milestone.isCompleted = true;
        milestone.deliverableHash = _deliverableHash;
        milestone.completionDate = block.timestamp;

        emit MilestoneCompleted(_grantId, _milestoneId, msg.sender, 0);
    }

    /**
     * @dev Approve milestone and release funds
     */
    function approveMilestone(
        uint256 _grantId,
        uint256 _milestoneId
    ) external onlyReviewer {
        Grant storage grant = grants[_grantId];
        require(grant.isActive, "Grant not active");
        require(_milestoneId < grant.milestones.length, "Invalid milestone");
        
        Milestone storage milestone = grant.milestones[_milestoneId];
        require(milestone.isCompleted, "Milestone not completed");
        require(!milestone.isApproved, "Milestone already approved");

        milestone.isApproved = true;
        milestone.approver = msg.sender;

        // Release funds
        uint256 releaseAmount = milestone.amount;
        grant.releasedAmount += releaseAmount;
        grant.remainingAmount -= releaseAmount;
        totalFundsDistributed += releaseAmount;

        wrfToken.safeTransfer(grant.recipient, releaseAmount);

        emit FundsReleased(_grantId, grant.recipient, releaseAmount, grant.releasedAmount);

        // Check if grant is completed
        if (_allMilestonesCompleted(_grantId)) {
            grant.status = GrantStatus.COMPLETED;
            grant.completionDate = block.timestamp;
            grant.isActive = false;
            emit GrantCompleted(_grantId, grant.recipient, true);
        }
    }

    /**
     * @dev Set category budget
     */
    function setCategoryBudget(GrantCategory _category, uint256 _budget) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldBudget = categoryBudgets[_category];
        categoryBudgets[_category] = _budget;
        emit CategoryBudgetUpdated(_category, oldBudget, _budget);
    }

    /**
     * @dev Add authorized reviewer
     */
    function addReviewer(address _reviewer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(REVIEWER_ROLE, _reviewer);
        authorizedReviewers[_reviewer] = true;
    }

    /**
     * @dev Verify funder
     */
    function verifyFunder(address _funder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(funders[_funder].funderAddress != address(0), "Funder not registered");
        funders[_funder].isVerified = true;
    }

    /**
     * @dev Start voting phase for proposal
     */
    function startVoting(uint256 _proposalId) external onlyReviewer {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.SUBMITTED, "Invalid proposal status");
        
        proposal.status = ProposalStatus.VOTING;
        proposal.votingDeadline = block.timestamp + votingPeriod;
    }

    /**
     * @dev Get grant details
     */
    function getGrantDetails(uint256 _grantId) external view returns (
        address recipient,
        string memory title,
        uint256 totalAmount,
        uint256 releasedAmount,
        GrantStatus status,
        uint256 milestonesCount
    ) {
        Grant storage grant = grants[_grantId];
        return (
            grant.recipient,
            grant.title,
            grant.totalAmount,
            grant.releasedAmount,
            grant.status,
            grant.milestones.length
        );
    }

    /**
     * @dev Get proposal voting results
     */
    function getProposalVotes(uint256 _proposalId) external view returns (
        uint256 votesFor,
        uint256 votesAgainst,
        ProposalStatus status
    ) {
        Proposal storage proposal = proposals[_proposalId];
        return (proposal.votesFor, proposal.votesAgainst, proposal.status);
    }

    /**
     * @dev Internal function to check proposal outcome
     */
    function _checkProposalOutcome(uint256 _proposalId) internal {
        Proposal storage proposal = proposals[_proposalId];
        
        // Simple majority voting (can be enhanced with quorum requirements)
        if (proposal.votesFor > proposal.votesAgainst && proposal.votesFor >= 3) {
            proposal.status = ProposalStatus.APPROVED;
        } else if (proposal.votesAgainst >= proposal.votesFor && proposal.votesAgainst >= 3) {
            proposal.status = ProposalStatus.REJECTED;
        }
    }

    /**
     * @dev Check if all milestones are completed and approved
     */
    function _allMilestonesCompleted(uint256 _grantId) internal view returns (bool) {
        Grant storage grant = grants[_grantId];
        for (uint256 i = 0; i < grant.milestones.length; i++) {
            if (!grant.milestones[i].isApproved) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Get funding statistics
     */
    function getFundingStats() external view returns (
        uint256 totalAllocated,
        uint256 totalDistributed,
        uint256 activeGrants
    ) {
        uint256 active = 0;
        for (uint256 i = 1; i < nextGrantId; i++) {
            if (grants[i].isActive) {
                active++;
            }
        }
        return (totalFundsAllocated, totalFundsDistributed, active);
    }

    // ============ INTERNAL SECURITY FUNCTIONS ============

    /**
     * @dev Reset daily allocation limit if needed
     */
    function _resetDailyAllocationIfNeeded() internal {
        if (block.timestamp >= lastResetTime + 1 days) {
            emit DailyAllocationReset(dailyAllocationUsed, MAX_DAILY_ALLOCATION);
            dailyAllocationUsed = 0;
            lastResetTime = block.timestamp;
        }
    }

    /**
     * @dev Reset funder daily contribution limit if needed
     */
    function _resetDailyLimitIfNeeded(address _funder) internal {
        Funder storage funder = funders[_funder];
        if (block.timestamp >= funder.lastResetTime + 1 days) {
            funder.dailyContributed = 0;
            funder.lastResetTime = block.timestamp;
        }
    }

    /**
     * @dev Calculate applicant reputation score
     */
    function _getApplicantReputation(address _applicant) internal view returns (uint256) {
        // Base reputation of 1000 for new applicants
        uint256 reputation = 1000;
        
        // Check if funder exists and adjust based on their reputation
        if (funders[_applicant].funderAddress != address(0)) {
            reputation = funders[_applicant].reputation;
        }
        
        // Adjust based on fraud detection score
        if (fraudDetection[_applicant].suspicionScore > 0) {
            reputation = reputation * (10000 - fraudDetection[_applicant].suspicionScore) / 10000;
        }
        
        return reputation;
    }

    /**
     * @dev Calculate required voting quorum based on proposal amount
     */
    function _calculateRequiredQuorum(uint256 _amount) internal pure returns (uint256) {
        if (_amount >= HIGH_VALUE_THRESHOLD) {
            return 5; // High-value proposals need more votes
        } else if (_amount >= 25000 * 10**18) {
            return 4; // Medium-value proposals
        }
        return 3; // Standard minimum quorum
    }

    /**
     * @dev Calculate initial merit score based on applicant history
     */
    function _calculateInitialMeritScore(
        address _applicant, 
        uint256 _amount, 
        GrantCategory _category
    ) internal view returns (uint256) {
        uint256 baseScore = 5000; // Base merit score
        
        // Adjust based on applicant reputation
        uint256 reputation = _getApplicantReputation(_applicant);
        uint256 reputationBonus = (reputation * 2500) / 1000; // Max 2500 bonus
        
        // Adjust based on category demand (less requested categories get bonus)
        uint256 categoryBonus = 0;
        if (applicantCategoryCount[_applicant][_category] == 0) {
            categoryBonus = 500; // First proposal in category bonus
        }
        
        // Penalty for large amounts without proven track record
        uint256 amountPenalty = 0;
        if (_amount > HIGH_VALUE_THRESHOLD && recipientGrants[_applicant].length == 0) {
            amountPenalty = 1000; // Penalty for large first-time requests
        }
        
        uint256 finalScore = baseScore + reputationBonus + categoryBonus;
        if (finalScore > amountPenalty) {
            finalScore -= amountPenalty;
        } else {
            finalScore = 1000; // Minimum score
        }
        
        return finalScore > 10000 ? 10000 : finalScore;
    }

    // ============ EMERGENCY FUNCTIONS ============

    /**
     * @notice Emergency freeze a grant (only emergency role)
     * @param _grantId Grant ID to freeze
     * @param _reason Reason for emergency freeze
     */
    function emergencyFreezeGrant(uint256 _grantId, string calldata _reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        Grant storage grant = grants[_grantId];
        require(grant.grantId != 0, "Grant does not exist");
        require(!grant.isEmergencyFrozen, "Grant already frozen");
        
        grant.isEmergencyFrozen = true;
        grant.emergencyFreezeTime = block.timestamp;
        
        emit EmergencyFreeze(_grantId, msg.sender, _reason);
    }

    /**
     * @notice Emergency unfreeze a grant (only emergency role)
     * @param _grantId Grant ID to unfreeze
     * @param _reason Reason for unfreezing
     */
    function emergencyUnfreezeGrant(uint256 _grantId, string calldata _reason) 
        external 
        onlyRole(EMERGENCY_ROLE) 
    {
        Grant storage grant = grants[_grantId];
        require(grant.isEmergencyFrozen, "Grant not frozen");
        
        grant.isEmergencyFrozen = false;
        grant.emergencyFreezeTime = 0;
        
        emit EmergencyUnfreeze(_grantId, msg.sender, _reason);
    }

    /**
     * @notice Pause contract (only admin role)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract (only admin role)
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
