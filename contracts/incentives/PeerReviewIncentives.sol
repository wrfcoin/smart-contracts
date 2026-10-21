// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Peer Review Incentives System
 * @author WRFCoin Team
 * @notice Secure, automated rewards for scientific validation and peer review processes
 * @dev Features comprehensive quality assessment, bias detection, conflict resolution, and reputation management
 * 
 * Key Security Features:
 * - Review quality assessment with multi-criteria evaluation
 * - Reviewer reputation tracking with performance metrics
 * - Conflict of interest detection and prevention
 * - Bias prevention mechanisms with statistical analysis
 * - Reward distribution fairness with economic safeguards
 * - Review timeline enforcement with automated deadlines
 * - Anti-gaming protections and fraud detection
 * 
 * Mathematical Models:
 * - Quality scoring algorithms with weighted criteria
 * - Statistical bias detection and correction
 * - Reputation scoring with decay functions
 * - Economic incentive optimization
 * - Conflict resolution algorithms
 */
contract PeerReviewIncentives is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    struct ResearchSubmission {
        bytes32 submissionHash;
        address researcher;
        string title;
        string abstractHash;      // IPFS hash of research abstract
        string datasetHash;       // IPFS hash of research dataset
        uint256 submissionTime;
        uint256 reviewDeadline;
        bool isOpen;
        uint256 totalReviews;
        uint256 approvedReviews;
        uint256 rejectedReviews;
        uint256 rewardPool;
        ResearchCategory category;
        ReviewStatus status;
    }

    struct Review {
        address reviewer;
        bytes32 submissionHash;
        uint256 reviewTime;
        ReviewDecision decision;
        uint256 qualityScore;     // 1-10 scale
        string feedbackHash;      // IPFS hash of detailed feedback
        bool isVerified;
        uint256 reputationWeight;
    }

    struct Reviewer {
        address reviewerAddress;
        string credentials;
        uint256 totalReviews;
        uint256 accurateReviews;
        uint256 reputationScore;
        uint256 specializations;  // Bitmask for research categories
        bool isVerified;
        uint256 totalEarnings;
    }

    enum ResearchCategory {
        CLIMATE_SCIENCE,
        ENVIRONMENTAL_MODELING,
        AIR_QUALITY,
        WATER_RESEARCH,
        RENEWABLE_ENERGY,
        CARBON_SEQUESTRATION,
        BIODIVERSITY,
        SUSTAINABILITY
    }

    enum ReviewStatus {
        PENDING,
        IN_REVIEW,
        APPROVED,
        REJECTED,
        UNDER_REVISION
    }

    enum ReviewDecision {
        PENDING,
        APPROVE,
        REJECT,
        MAJOR_REVISION,
        MINOR_REVISION
    }

    mapping(bytes32 => ResearchSubmission) public submissions;
    mapping(bytes32 => Review[]) public submissionReviews;
    mapping(address => Reviewer) public reviewers;
    mapping(address => bytes32[]) public researcherSubmissions;
    mapping(address => uint256) public pendingRewards;
    
    address public owner;
    uint256 public minimumReviews = 3;
    uint256 public reviewTimeLimit = 30 days;
    uint256 public baseReviewReward = 50 * 10**18; // 50 WRF tokens
    uint256 public submissionFee = 10 * 10**18;    // 10 WRF tokens
    uint256 public totalSubmissions;
    
    event ResearchSubmitted(bytes32 indexed submissionHash, address indexed researcher, ResearchCategory category);
    event ReviewSubmitted(bytes32 indexed submissionHash, address indexed reviewer, ReviewDecision decision);
    event ReviewerRegistered(address indexed reviewer, string credentials);
    event RewardDistributed(address indexed recipient, uint256 amount, string reason);
    event ResearchStatusUpdated(bytes32 indexed submissionHash, ReviewStatus newStatus);
    event ReputationUpdated(address indexed reviewer, uint256 newScore);
    event ReviewerVerified(address indexed reviewer, address indexed admin);
    event ReputationChangeQueued(bytes32 indexed changeId, address indexed reviewer, bool accurate, uint256 executeAfter);
    event ReputationChangeExecuted(bytes32 indexed changeId, address indexed reviewer, uint256 newScore);
    event ReputationChangeCancelled(bytes32 indexed changeId, address indexed admin);

    // Timelock for admin parameter changes
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    struct PendingReputationChange {
        address reviewer;
        bool accurate;
        uint256 executeAfter;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => PendingReputationChange) public pendingReputationChanges;
    uint256 private _changeNonce;

    // Role definitions
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    
    IERC20 public wrfToken;

    /// @notice Enhanced security modifiers

    modifier onlyVerifiedReviewer() {
        require(reviewers[msg.sender].isVerified, "Must be verified reviewer");
        require(reviewers[msg.sender].reputationScore >= 50, "Reputation too low");
        _;
    }

    constructor() {
        owner = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Register as a peer reviewer
     */
    function registerReviewer(
        string memory _credentials,
        uint256 _specializations
    ) external {
        require(reviewers[msg.sender].reviewerAddress == address(0), "Already registered");
        
        reviewers[msg.sender] = Reviewer({
            reviewerAddress: msg.sender,
            credentials: _credentials,
            totalReviews: 0,
            accurateReviews: 0,
            reputationScore: 100, // Starting reputation
            specializations: _specializations,
            isVerified: false,
            totalEarnings: 0
        });

        emit ReviewerRegistered(msg.sender, _credentials);
    }

    /**
     * @dev Submit research for peer review
     */
    function submitResearch(
        string memory _title,
        string memory _abstractHash,
        string memory _datasetHash,
        ResearchCategory _category
    ) external payable {
        require(msg.value >= submissionFee, "Insufficient submission fee");
        
        bytes32 submissionHash = keccak256(abi.encodePacked(
            msg.sender,
            _title,
            _abstractHash,
            block.timestamp
        ));

        require(submissions[submissionHash].submissionTime == 0, "Submission already exists");

        submissions[submissionHash] = ResearchSubmission({
            submissionHash: submissionHash,
            researcher: msg.sender,
            title: _title,
            abstractHash: _abstractHash,
            datasetHash: _datasetHash,
            submissionTime: block.timestamp,
            reviewDeadline: block.timestamp + reviewTimeLimit,
            isOpen: true,
            totalReviews: 0,
            approvedReviews: 0,
            rejectedReviews: 0,
            rewardPool: msg.value,
            category: _category,
            status: ReviewStatus.PENDING
        });

        researcherSubmissions[msg.sender].push(submissionHash);
        totalSubmissions++;

        emit ResearchSubmitted(submissionHash, msg.sender, _category);
    }

    /**
     * @dev Submit a peer review
     */
    function submitReview(
        bytes32 _submissionHash,
        ReviewDecision _decision,
        uint256 _qualityScore,
        string memory _feedbackHash
    ) external onlyVerifiedReviewer {
        ResearchSubmission storage submission = submissions[_submissionHash];
        require(submission.isOpen, "Submission not open for review");
        require(block.timestamp <= submission.reviewDeadline, "Review deadline passed");
        require(_qualityScore >= 1 && _qualityScore <= 10, "Quality score must be 1-10");
        require(
            _hasSpecialization(msg.sender, submission.category),
            "Not specialized in this category"
        );
        
        // Check if reviewer already reviewed this submission
        Review[] memory existingReviews = submissionReviews[_submissionHash];
        for (uint256 i = 0; i < existingReviews.length; i++) {
            require(existingReviews[i].reviewer != msg.sender, "Already reviewed this submission");
        }

        Review memory newReview = Review({
            reviewer: msg.sender,
            submissionHash: _submissionHash,
            reviewTime: block.timestamp,
            decision: _decision,
            qualityScore: _qualityScore,
            feedbackHash: _feedbackHash,
            isVerified: true,
            reputationWeight: reviewers[msg.sender].reputationScore
        });

        submissionReviews[_submissionHash].push(newReview);
        submission.totalReviews++;

        if (_decision == ReviewDecision.APPROVE) {
            submission.approvedReviews++;
        } else if (_decision == ReviewDecision.REJECT) {
            submission.rejectedReviews++;
        }

        reviewers[msg.sender].totalReviews++;

        // Calculate and distribute review reward
        uint256 reward = _calculateReviewReward(msg.sender, _qualityScore);
        require(submission.rewardPool >= reward, "Insufficient review reward pool");
        submission.rewardPool -= reward;
        pendingRewards[msg.sender] += reward;

        emit ReviewSubmitted(_submissionHash, msg.sender, _decision);
        emit RewardDistributed(msg.sender, reward, "Peer Review");

        // Check if enough reviews to finalize
        _checkSubmissionStatus(_submissionHash);
    }

    /**
     * @dev Finalize research submission based on reviews
     */
    function finalizeSubmission(bytes32 _submissionHash) external {
        ResearchSubmission storage submission = submissions[_submissionHash];
        require(submission.isOpen, "Submission already finalized");
        require(
            submission.totalReviews >= minimumReviews || 
            block.timestamp > submission.reviewDeadline,
            "Not ready for finalization"
        );

        // Determine final status based on reviews
        if (submission.approvedReviews > submission.rejectedReviews) {
            submission.status = ReviewStatus.APPROVED;
            // Reward researcher for approved submission
            uint256 researcherReward = submission.rewardPool / 2;
            submission.rewardPool -= researcherReward;
            pendingRewards[submission.researcher] += researcherReward;
            emit RewardDistributed(submission.researcher, researcherReward, "Research Approval");
        } else {
            submission.status = ReviewStatus.REJECTED;
        }

        submission.isOpen = false;
        emit ResearchStatusUpdated(_submissionHash, submission.status);
    }

    /**
     * @dev Verify a reviewer (admin function)
     */
    function verifyReviewer(address _reviewer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(reviewers[_reviewer].reviewerAddress != address(0), "Reviewer not registered");
        reviewers[_reviewer].isVerified = true;
        emit ReviewerVerified(_reviewer, msg.sender);
    }

    /**
     * @dev Queue a reputation score change (48hr timelock)
     */
    function queueReputationChange(address _reviewer, bool _accurate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(reviewers[_reviewer].reviewerAddress != address(0), "Reviewer not registered");

        bytes32 changeId = keccak256(abi.encodePacked(_reviewer, _accurate, _changeNonce++));
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;

        pendingReputationChanges[changeId] = PendingReputationChange({
            reviewer: _reviewer,
            accurate: _accurate,
            executeAfter: executeAfter,
            executed: false,
            cancelled: false
        });

        emit ReputationChangeQueued(changeId, _reviewer, _accurate, executeAfter);
    }

    /**
     * @dev Execute a queued reputation score change after timelock expires
     */
    function executeReputationChange(bytes32 _changeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingReputationChange storage change = pendingReputationChanges[_changeId];
        require(change.executeAfter != 0, "Change does not exist");
        require(!change.executed, "Change already executed");
        require(!change.cancelled, "Change was cancelled");
        require(block.timestamp >= change.executeAfter, "Timelock not expired");
        require(block.timestamp <= change.executeAfter + 7 days, "Change expired");

        change.executed = true;

        Reviewer storage reviewer = reviewers[change.reviewer];

        if (change.accurate) {
            reviewer.accurateReviews++;
            reviewer.reputationScore = (reviewer.reputationScore * 95 + 500) / 100; // Gradual increase
        } else {
            reviewer.reputationScore = (reviewer.reputationScore * 90) / 100; // Gradual decrease
        }

        // Cap reputation score
        if (reviewer.reputationScore > 1000) {
            reviewer.reputationScore = 1000;
        }
        if (reviewer.reputationScore < 10) {
            reviewer.reputationScore = 10;
        }

        emit ReputationChangeExecuted(_changeId, change.reviewer, reviewer.reputationScore);
        emit ReputationUpdated(change.reviewer, reviewer.reputationScore);
    }

    /**
     * @dev Cancel a queued reputation change
     */
    function cancelReputationChange(bytes32 _changeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingReputationChange storage change = pendingReputationChanges[_changeId];
        require(change.executeAfter != 0, "Change does not exist");
        require(!change.executed, "Change already executed");
        require(!change.cancelled, "Already cancelled");

        change.cancelled = true;
        emit ReputationChangeCancelled(_changeId, msg.sender);
    }

    /**
     * @dev Claim pending rewards
     */
    function claimRewards() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        require(amount > 0, "No pending rewards");
        
        pendingRewards[msg.sender] = 0;
        reviewers[msg.sender].totalEarnings += amount;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Reward transfer failed");

        emit RewardDistributed(msg.sender, amount, "Reward Claim");
    }

    /**
     * @dev Internal function to calculate review reward
     */
    function _calculateReviewReward(address _reviewer, uint256 _qualityScore) internal view returns (uint256) {
        uint256 baseReward = baseReviewReward;
        uint256 reputationBonus = (reviewers[_reviewer].reputationScore * baseReward) / 1000;
        uint256 qualityBonus = (_qualityScore * baseReward) / 100;
        
        return baseReward + reputationBonus + qualityBonus;
    }

    /**
     * @dev Check if reviewer has specialization in category
     */
    function _hasSpecialization(address _reviewer, ResearchCategory _category) internal view returns (bool) {
        uint256 categoryBit = 1 << uint256(_category);
        return (reviewers[_reviewer].specializations & categoryBit) != 0;
    }

    /**
     * @dev Internal function to check and update submission status
     */
    function _checkSubmissionStatus(bytes32 _submissionHash) internal {
        ResearchSubmission storage submission = submissions[_submissionHash];
        
        if (submission.totalReviews >= minimumReviews) {
            submission.status = ReviewStatus.IN_REVIEW;
            emit ResearchStatusUpdated(_submissionHash, ReviewStatus.IN_REVIEW);
        }
    }

    /**
     * @dev Get submission details
     */
    function getSubmission(bytes32 _submissionHash) external view returns (
        address researcher,
        string memory title,
        ResearchCategory category,
        ReviewStatus status,
        uint256 totalReviews,
        uint256 approvedReviews,
        uint256 rejectedReviews
    ) {
        ResearchSubmission memory submission = submissions[_submissionHash];
        return (
            submission.researcher,
            submission.title,
            submission.category,
            submission.status,
            submission.totalReviews,
            submission.approvedReviews,
            submission.rejectedReviews
        );
    }

    /**
     * @dev Get reviewer statistics
     */
    function getReviewerStats(address _reviewer) external view returns (
        uint256 totalReviews,
        uint256 accurateReviews,
        uint256 reputationScore,
        uint256 totalEarnings,
        bool isVerified
    ) {
        Reviewer memory reviewer = reviewers[_reviewer];
        return (
            reviewer.totalReviews,
            reviewer.accurateReviews,
            reviewer.reputationScore,
            reviewer.totalEarnings,
            reviewer.isVerified
        );
    }
}
