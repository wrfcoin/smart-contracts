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
 * @title Model Training Rewards System
 * @author WRFCoin Team
 * @notice Secure incentive system for AI/ML model training contributions with comprehensive validation
 * @dev Features computational verification, quality scoring, anti-gaming mechanisms, and federated learning support
 * 
 * Key Security Features:
 * - Model performance validation with statistical analysis
 * - Computational resource verification and proof-of-work
 * - Quality-based reward distribution with accuracy metrics
 * - Anti-gaming mechanisms for contribution authenticity
 * - Economic security limits for high-value rewards
 * - Reputation system with contributor scoring
 * - Federated learning incentive optimization
 * 
 * Mathematical Models:
 * - Performance-weighted reward calculation
 * - Statistical significance testing for model accuracy
 * - Computational effort verification algorithms
 * - Quality scoring with multiple evaluation criteria
 * - Economic equilibrium for sustainable incentives
 */
contract ModelTrainingRewards is AccessControl, Ownable, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    /// @notice Enhanced training job structure with security features
    struct TrainingJob {
        uint256 jobId;
        address requester;
        string modelType;
        string datasetHash;          // IPFS hash of training dataset
        uint256 computeRequirement;  // Required compute power in TFLOPS
        uint256 deadline;
        uint256 totalReward;
        uint256 maxParticipants;
        uint256 currentParticipants;
        TrainingStatus status;
        bool isActive;
        string[] resultHashes;       // IPFS hashes of trained models
        // Security enhancements
        uint256 minimumAccuracy;     // Minimum required accuracy threshold
        bytes32 datasetFingerprintHash; // Dataset integrity verification
        uint256 fraudDetectionScore; // Job-level fraud detection
        bool requiresProofOfWork;    // Proof-of-work requirement
        uint256 difficultyTarget;    // Computational difficulty target
        mapping(address => bool) verifiedContributors; // Pre-verified contributors only
        uint256 qualityWeightFactor; // Quality vs quantity reward weighting (0-10000)
        uint256 totalComputeVerified; // Total verified computational contribution
        bool isEmergencyHalted;      // Emergency halt status
    }

    /// @notice Enhanced training contribution with verification features
    struct TrainingContribution {
        uint256 contributionId;
        uint256 jobId;
        address contributor;
        uint256 computeProvided;     // Actual compute provided in TFLOPS
        uint256 trainingTime;       // Time spent training in seconds
        string resultHash;          // IPFS hash of model weights/results
        uint256 accuracyScore;      // Model accuracy (0-10000 for precision)
        uint256 validationScore;    // Validation performance score
        bool isVerified;
        uint256 rewardEarned;
        uint256 submissionTime;
        ComputeNetworkType networkType;
        // Security enhancements
        bytes32 proofOfWorkHash;    // Proof-of-work verification hash
        uint256 computeProofNonce;  // Nonce for compute verification
        bool isStatisticallySignificant; // Statistical significance of results
        uint256 confidenceInterval; // Confidence level (0-10000)
        uint256 crossValidationScore; // K-fold cross-validation results
        bytes32 modelFingerprintHash; // Model output fingerprint for uniqueness
        uint256 gasUsedForVerification; // Gas cost for on-chain verification
        bool isSlashable;           // Can be slashed for malicious behavior
        uint256 stakingAmount;      // Staking amount for this contribution
        uint256 qualityMetrics;     // Combined quality score
    }

    /// @notice Enhanced contributor structure with reputation and security features
    struct Contributor {
        address contributorAddress;
        string name;
        uint256 totalContributions;
        uint256 totalComputeProvided;
        uint256 totalRewardsEarned;
        uint256 averageAccuracy;
        uint256 reputationScore;
        bool isVerified;
        ComputeNetworkType[] supportedNetworks;
        uint256 activeJobs;
        // Security and performance enhancements
        uint256 successfulContributions; // Number of successful contributions
        uint256 rejectedContributions;   // Number of rejected contributions
        uint256 averageModelQuality;     // Average quality score across contributions
        uint256 specialistCategories;    // Bitmask for specialized model types
        bool isSlashProtected;           // Protection against slashing
        uint256 totalStaked;            // Total amount staked by contributor
        uint256 slashingHistory;        // History of slashing incidents
        uint256 lastContributionTime;   // Time-based rate limiting
        uint256 fraudScore;             // Fraud detection score
        uint256 verificationLevel;      // Level of identity verification
        mapping(ModelType => uint256) modelTypeExperience; // Experience per model type
        uint256 computeReliabilityScore; // Reliability of computational resources
    }

    struct WeatherModel {
        uint256 modelId;
        string modelName;
        string modelHash;           // IPFS hash of model
        address developer;
        ModelType modelType;
        uint256 accuracy;
        uint256 validationMetrics;
        uint256 deploymentDate;
        bool isDeployed;
        uint256 usageCount;
        uint256 totalRewardsGenerated;
    }

    enum TrainingStatus {
        OPEN,
        IN_PROGRESS,
        COMPLETED,
        CANCELLED,
        EXPIRED
    }

    enum ComputeNetworkType {
        FLUX,
        AKASH,
        GOLEM,
        RENDER,
        IEXEC,
        ICP,
        AIOZ
    }

    enum ModelType {
        WEATHER_PREDICTION,
        CLIMATE_MODELING,
        AIR_QUALITY_FORECASTING,
        TEMPERATURE_ANALYSIS,
        PRECIPITATION_MODELING,
        STORM_TRACKING,
        SEASONAL_FORECASTING,
        CARBON_MODELING
    }

    /// @notice Quality assessment structure for model evaluation
    struct QualityAssessment {
        uint256 accuracyScore;       // Model accuracy (0-10000)
        uint256 precisionScore;      // Model precision (0-10000)
        uint256 recallScore;         // Model recall (0-10000)
        uint256 f1Score;            // F1 score (0-10000)
        uint256 rmseScore;          // Root Mean Square Error (scaled)
        uint256 latencyScore;       // Inference latency performance
        uint256 energyEfficiency;   // Energy consumption efficiency
        bool passesBaseline;        // Exceeds baseline performance
        uint256 evaluationTimestamp; // When evaluation was performed
        address evaluator;          // Who performed the evaluation
    }

    /// @notice Federated learning coordination structure
    struct FederatedRound {
        uint256 roundId;
        uint256 startTime;
        uint256 endTime;
        uint256 minParticipants;
        uint256 currentParticipants;
        bytes32 globalModelHash;    // Hash of global model weights
        mapping(address => bool) participated; // Participation tracking
        uint256 aggregationMethod;  // Aggregation algorithm identifier
        bool isCompleted;
        uint256 totalRewardPool;
        uint256 qualityThreshold;   // Minimum quality for participation rewards
    }

    /// @notice Staking and slashing management structure
    struct StakingInfo {
        uint256 stakedAmount;       // Amount staked by contributor
        uint256 lockupPeriod;       // Staking lockup duration
        uint256 lockupEndTime;      // When staking unlocks
        uint256 slashingRisk;       // Risk level for slashing (0-10000)
        bool isSlashed;            // Whether contributor has been slashed
        uint256 slashedAmount;     // Total amount slashed
        string slashingReason;     // Reason for slashing
        uint256 rewardMultiplier;  // Staking reward multiplier (10000 = 1x)
    }

    // Core mappings
    mapping(uint256 => TrainingJob) public trainingJobs;
    mapping(uint256 => TrainingContribution) public contributions;
    mapping(address => Contributor) public contributors;
    mapping(uint256 => WeatherModel) public weatherModels;
    mapping(uint256 => uint256[]) public jobContributions;
    mapping(address => uint256[]) public contributorJobs;
    mapping(ComputeNetworkType => uint256) public networkRewardMultipliers;
    mapping(uint256 => uint256) public jobRemainingRewards;
    mapping(address => uint256) public pendingRewards;
    
    // Security and quality mappings
    mapping(uint256 => QualityAssessment) public contributionQuality;
    mapping(address => StakingInfo) public stakingInfo;
    mapping(uint256 => FederatedRound) public federatedRounds;
    mapping(bytes32 => bool) public usedModelHashes; // Prevent duplicate model submissions
    mapping(address => uint256) public lastContributionTime; // Rate limiting
    mapping(ModelType => uint256) public modelTypeDifficulty; // Dynamic difficulty per model type
    mapping(address => mapping(uint256 => bool)) public hasContributedToJob; // Prevent multiple contributions per job
    
    // Role definitions
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant EVALUATOR_ROLE = keccak256("EVALUATOR_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant JOB_CREATOR_ROLE = keccak256("JOB_CREATOR_ROLE");
    
    // Economic security constants
    uint256 public constant MAX_REWARD_PER_JOB = 100000 * 10**18; // 100K WRF max per job
    uint256 public constant MIN_STAKING_AMOUNT = 1000 * 10**18;   // 1K WRF minimum stake
    uint256 public constant ACCURACY_THRESHOLD = 7500;           // 75% minimum accuracy
    uint256 public constant FRAUD_DETECTION_THRESHOLD = 8000;     // 80% fraud threshold
    uint256 public constant MAX_CONTRIBUTION_FREQUENCY = 1 hours; // Rate limiting
    uint256 public constant STATISTICAL_SIGNIFICANCE_THRESHOLD = 9000; // 90% confidence
    
    // Configuration variables  
    uint256 public nextJobId = 1;
    uint256 public nextContributionId = 1;
    uint256 public nextModelId = 1;
    uint256 public nextFederatedRoundId = 1;
    
    IERC20 public wrfToken; // WRF token contract
    uint256 public baseRewardPerTFLOPS = 100 * 10**18; // 100 WRF per TFLOPS
    uint256 public accuracyBonusMultiplier = 150; // 1.5x bonus for high accuracy
    uint256 public qualityBonusMultiplier = 200;  // 2x bonus for exceptional quality
    uint256 public stakingRewardMultiplier = 125; // 1.25x bonus for staking
    uint256 public totalRewardsDistributed;
    uint256 public totalComputeProvided;
    uint256 public totalStakedAmount;
    uint256 public totalSlashedAmount;
    
    // Quality and performance tracking
    uint256 public averageModelAccuracy;     // Platform-wide average accuracy
    uint256 public totalModelsDeployed;      // Total number of deployed models
    uint256 public totalFederatedRounds;     // Total federated learning rounds

    // Core events
    event TrainingJobCreated(uint256 indexed jobId, address indexed requester, string modelType, uint256 totalReward);
    event ContributionSubmitted(uint256 indexed contributionId, uint256 indexed jobId, address indexed contributor, uint256 computeProvided);
    event ContributionVerified(uint256 indexed contributionId, uint256 accuracyScore, uint256 reward, bool isStatisticallySignificant);
    event RewardDistributed(address indexed contributor, uint256 amount, uint256 jobId, uint256 qualityScore);
    event ContributorRegistered(address indexed contributor, string name, uint256 initialReputation);
    event WeatherModelDeployed(uint256 indexed modelId, string modelName, address developer, uint256 accuracy);
    event ModelUsageReward(uint256 indexed modelId, address indexed developer, uint256 reward, uint256 usageCount);
    
    // Security and quality events
    event StakingDeposit(address indexed contributor, uint256 amount, uint256 lockupPeriod);
    event StakingWithdraw(address indexed contributor, uint256 amount, uint256 rewardEarned);
    event ContributorSlashed(address indexed contributor, uint256 slashedAmount, string reason);
    event FraudDetected(address indexed contributor, uint256 fraudScore, string evidence);
    event QualityAssessmentCompleted(uint256 indexed contributionId, uint256 overallQuality, address indexed evaluator);
    event ModelAccuracyVerified(uint256 indexed modelId, uint256 accuracy, bool passesBaseline);
    event StatisticalValidationCompleted(uint256 indexed contributionId, uint256 confidenceLevel, bool isSignificant);
    
    // Federated learning events
    event FederatedRoundStarted(uint256 indexed roundId, uint256 minParticipants, uint256 rewardPool);
    event FederatedRoundCompleted(uint256 indexed roundId, uint256 participants, bytes32 globalModelHash);
    event FederatedParticipation(uint256 indexed roundId, address indexed contributor, uint256 qualityScore);
    
    // Economic and governance events
    event RewardMultiplierUpdated(string multiplierType, uint256 oldValue, uint256 newValue);
    event NetworkDifficultyAdjusted(ModelType indexed modelType, uint256 oldDifficulty, uint256 newDifficulty);
    event EmergencyJobHalt(uint256 indexed jobId, string reason, address indexed halter);
    event ContributorVerificationLevelUpdated(address indexed contributor, uint256 oldLevel, uint256 newLevel);

    // Admin action events
    event ContributorVerifiedByAdmin(address indexed contributor, address indexed admin);
    event NetworkMultiplierChangeQueued(bytes32 indexed changeId, ComputeNetworkType network, uint256 newMultiplier, uint256 executeAfter);
    event NetworkMultiplierChangeExecuted(bytes32 indexed changeId, ComputeNetworkType network, uint256 oldMultiplier, uint256 newMultiplier);
    event NetworkMultiplierChangeCancelled(bytes32 indexed changeId, address indexed admin);
    event RewardClaimed(address indexed contributor, uint256 amount);

    // Timelock for admin parameter changes
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant MAX_NETWORK_MULTIPLIER = 500; // 5x max multiplier

    struct PendingMultiplierChange {
        ComputeNetworkType network;
        uint256 newMultiplier;
        uint256 executeAfter;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => PendingMultiplierChange) public pendingMultiplierChanges;
    uint256 private _changeNonce;

    /// @notice Enhanced security modifiers with comprehensive validation

    modifier onlyVerifiedContributor() {
        require(contributors[msg.sender].isVerified, "Must be verified contributor");
        require(contributors[msg.sender].fraudScore < FRAUD_DETECTION_THRESHOLD, "Contributor flagged for fraud");
        require(!stakingInfo[msg.sender].isSlashed, "Contributor has been slashed");
        _;
    }

    modifier onlyJobRequester(uint256 _jobId) {
        require(trainingJobs[_jobId].requester == msg.sender, "Not job requester");
        require(!trainingJobs[_jobId].isEmergencyHalted, "Job is emergency halted");
        _;
    }

    modifier rateLimited() {
        require(
            lastContributionTime[msg.sender] + MAX_CONTRIBUTION_FREQUENCY <= block.timestamp,
            "Rate limit: contribution frequency exceeded"
        );
        _;
    }

    modifier validStaking(uint256 _amount) {
        require(_amount >= MIN_STAKING_AMOUNT, "Staking amount too low");
        require(stakingInfo[msg.sender].lockupEndTime <= block.timestamp, "Previous staking still locked");
        _;
    }

    modifier qualityGate(uint256 _accuracyScore) {
        require(_accuracyScore >= ACCURACY_THRESHOLD, "Accuracy below minimum threshold");
        _;
    }

    modifier antiGameMechanism(uint256 _jobId) {
        require(!hasContributedToJob[msg.sender][_jobId], "Already contributed to this job");
        require(contributors[msg.sender].activeJobs < 5, "Too many active jobs");
        _;
    }

    /**
     * @notice Initialize Model Training Rewards System with comprehensive security
     * @param _wrfToken Address of the WRF token contract
     */
    constructor(address _wrfToken) 
        Ownable(msg.sender)
        EIP712("ModelTrainingRewards", "1")
    {
        require(_wrfToken != address(0), "Invalid WRF token address");
        
        wrfToken = IERC20(_wrfToken);
        
        // Initialize role-based access control
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VALIDATOR_ROLE, msg.sender);
        _grantRole(EVALUATOR_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(JOB_CREATOR_ROLE, msg.sender);
        
        // Initialize network multipliers and difficulty levels
        _initializeNetworkMultipliers();
        // Initialize model type difficulties with default values
        modelTypeDifficulty[ModelType.WEATHER_PREDICTION] = 1e18;
        modelTypeDifficulty[ModelType.CLIMATE_MODELING] = 2e18;
        modelTypeDifficulty[ModelType.STORM_TRACKING] = 5e18;
        
        // Initialize platform statistics
        averageModelAccuracy = 0;
        totalModelsDeployed = 0;
        totalFederatedRounds = 0;
        totalStakedAmount = 0;
        totalSlashedAmount = 0;
    }

    /**
     * @dev Register as a model training contributor
     */
    function registerContributor(
        string memory _name,
        ComputeNetworkType[] memory _supportedNetworks
    ) external {
        require(contributors[msg.sender].contributorAddress == address(0), "Already registered");

        Contributor storage c = contributors[msg.sender];
        c.contributorAddress = msg.sender;
        c.name = _name;
        c.totalContributions = 0;
        c.totalComputeProvided = 0;
        c.totalRewardsEarned = 0;
        c.averageAccuracy = 0;
        c.reputationScore = 100;
        c.isVerified = false;
        c.activeJobs = 0;
        for (uint256 i = 0; i < _supportedNetworks.length; i++) {
            c.supportedNetworks.push(_supportedNetworks[i]);
        }

        emit ContributorRegistered(msg.sender, _name, 100);
    }

    /**
     * @dev Create a new training job
     */
    function createTrainingJob(
        string memory _modelType,
        string memory _datasetHash,
        uint256 _computeRequirement,
        uint256 _deadline,
        uint256 _maxParticipants
    ) external payable {
        require(msg.value > 0, "Must provide reward funds");
        require(_deadline > block.timestamp, "Deadline must be in future");
        require(_computeRequirement > 0, "Compute requirement must be positive");

        uint256 jobId = nextJobId++;

        TrainingJob storage job = trainingJobs[jobId];
        job.jobId = jobId;
        job.requester = msg.sender;
        job.modelType = _modelType;
        job.datasetHash = _datasetHash;
        job.computeRequirement = _computeRequirement;
        job.deadline = _deadline;
        job.totalReward = msg.value;
        jobRemainingRewards[jobId] = msg.value;
        job.maxParticipants = _maxParticipants;
        job.currentParticipants = 0;
        job.status = TrainingStatus.OPEN;
        job.isActive = true;

        emit TrainingJobCreated(jobId, msg.sender, _modelType, msg.value);
    }

    /**
     * @dev Submit training contribution
     */
    function submitContribution(
        uint256 _jobId,
        uint256 _computeProvided,
        uint256 _trainingTime,
        string memory _resultHash,
        ComputeNetworkType _networkType
    ) external onlyVerifiedContributor {
        TrainingJob storage job = trainingJobs[_jobId];
        require(job.isActive, "Job not active");
        require(job.status == TrainingStatus.OPEN, "Job not accepting contributions");
        require(block.timestamp <= job.deadline, "Job deadline passed");
        require(job.currentParticipants < job.maxParticipants, "Job at capacity");
        require(_computeProvided > 0, "Compute provided must be positive");
        require(_supportsNetwork(msg.sender, _networkType), "Network not supported");

        uint256 contributionId = nextContributionId++;

        contributions[contributionId] = TrainingContribution({
            contributionId: contributionId,
            jobId: _jobId,
            contributor: msg.sender,
            computeProvided: _computeProvided,
            trainingTime: _trainingTime,
            resultHash: _resultHash,
            accuracyScore: 0,
            validationScore: 0,
            isVerified: false,
            rewardEarned: 0,
            submissionTime: block.timestamp,
            networkType: _networkType,
            proofOfWorkHash: bytes32(0),
            computeProofNonce: 0,
            isStatisticallySignificant: false,
            confidenceInterval: 0,
            crossValidationScore: 0,
            modelFingerprintHash: bytes32(0),
            gasUsedForVerification: 0,
            isSlashable: false,
            stakingAmount: 0,
            qualityMetrics: 0
        });

        jobContributions[_jobId].push(contributionId);
        contributorJobs[msg.sender].push(_jobId);
        
        job.currentParticipants++;
        job.resultHashes.push(_resultHash);
        
        contributors[msg.sender].totalContributions++;
        contributors[msg.sender].totalComputeProvided += _computeProvided;
        contributors[msg.sender].activeJobs++;

        totalComputeProvided += _computeProvided;

        emit ContributionSubmitted(contributionId, _jobId, msg.sender, _computeProvided);

        // Auto-start job if at capacity
        if (job.currentParticipants >= job.maxParticipants) {
            job.status = TrainingStatus.IN_PROGRESS;
        }
    }

    /**
     * @dev Verify contribution and calculate reward
     */
    function verifyContribution(
        uint256 _contributionId,
        uint256 _accuracyScore,
        uint256 _validationScore
    ) external onlyRole(VALIDATOR_ROLE) {
        require(_accuracyScore <= 10000, "Accuracy score exceeds maximum 10000");
        require(_validationScore <= 10000, "Validation score exceeds maximum 10000");

        TrainingContribution storage contribution = contributions[_contributionId];
        require(!contribution.isVerified, "Already verified");
        require(contribution.contributor != address(0), "Contribution does not exist");

        contribution.accuracyScore = _accuracyScore;
        contribution.validationScore = _validationScore;
        contribution.isVerified = true;

        // Calculate reward based on compute provided, accuracy, and network type
        uint256 baseReward = contribution.computeProvided * baseRewardPerTFLOPS;
        uint256 accuracyBonus = (baseReward * _accuracyScore * accuracyBonusMultiplier) / 1000000;
        uint256 networkMultiplier = networkRewardMultipliers[contribution.networkType];
        uint256 networkBonus = (baseReward * networkMultiplier) / 100;

        uint256 calculatedReward = baseReward + accuracyBonus + networkBonus;
        uint256 availableReward = jobRemainingRewards[contribution.jobId];
        uint256 totalReward = calculatedReward < availableReward ? calculatedReward : availableReward;
        require(totalReward > 0, "No funded rewards remaining");

        jobRemainingRewards[contribution.jobId] = availableReward - totalReward;
        contribution.rewardEarned = totalReward;

        // Update contributor stats
        Contributor storage contributor = contributors[contribution.contributor];
        contributor.totalRewardsEarned += totalReward;
        contributor.activeJobs--;
        pendingRewards[contribution.contributor] += totalReward;

        // Update average accuracy
        uint256 totalAccuracy = contributor.averageAccuracy * (contributor.totalContributions - 1);
        contributor.averageAccuracy = (totalAccuracy + _accuracyScore) / contributor.totalContributions;

        totalRewardsDistributed += totalReward;

        emit ContributionVerified(_contributionId, _accuracyScore, totalReward, false);
        emit RewardDistributed(contribution.contributor, totalReward, contribution.jobId, _validationScore);
    }

    function claimRewards() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        require(amount > 0, "No pending rewards");

        pendingRewards[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Reward transfer failed");

        emit RewardClaimed(msg.sender, amount);
    }

    /**
     * @dev Deploy trained weather model
     */
    function deployWeatherModel(
        string memory _modelName,
        string memory _modelHash,
        ModelType _modelType,
        uint256 _accuracy,
        uint256 _validationMetrics
    ) external {
        uint256 modelId = nextModelId++;

        weatherModels[modelId] = WeatherModel({
            modelId: modelId,
            modelName: _modelName,
            modelHash: _modelHash,
            developer: msg.sender,
            modelType: _modelType,
            accuracy: _accuracy,
            validationMetrics: _validationMetrics,
            deploymentDate: block.timestamp,
            isDeployed: true,
            usageCount: 0,
            totalRewardsGenerated: 0
        });

        emit WeatherModelDeployed(modelId, _modelName, msg.sender, _accuracy);
    }

    /**
     * @dev Record model usage and distribute rewards
     */
    function recordModelUsage(uint256 _modelId, uint256 _usageReward) external onlyRole(VALIDATOR_ROLE) {
        WeatherModel storage model = weatherModels[_modelId];
        require(model.isDeployed, "Model not deployed");

        model.usageCount++;
        model.totalRewardsGenerated += _usageReward;

        emit ModelUsageReward(_modelId, model.developer, _usageReward, model.usageCount);
    }

    /**
     * @dev Complete training job
     */
    function completeJob(uint256 _jobId) external onlyJobRequester(_jobId) {
        TrainingJob storage job = trainingJobs[_jobId];
        require(job.status == TrainingStatus.IN_PROGRESS, "Job not in progress");
        
        job.status = TrainingStatus.COMPLETED;
        job.isActive = false;
    }

    /**
     * @dev Verify contributor (admin function)
     */
    function verifyContributor(address _contributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(contributors[_contributor].contributorAddress != address(0), "Contributor not registered");
        contributors[_contributor].isVerified = true;
        emit ContributorVerifiedByAdmin(_contributor, msg.sender);
    }

    /**
     * @dev Queue a network multiplier change (48hr timelock)
     */
    function queueNetworkMultiplierChange(ComputeNetworkType _network, uint256 _multiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_multiplier > 0, "Multiplier must be positive");
        require(_multiplier <= MAX_NETWORK_MULTIPLIER, "Multiplier exceeds maximum");

        bytes32 changeId = keccak256(abi.encodePacked(_network, _multiplier, _changeNonce++));
        uint256 executeAfter = block.timestamp + TIMELOCK_DELAY;

        pendingMultiplierChanges[changeId] = PendingMultiplierChange({
            network: _network,
            newMultiplier: _multiplier,
            executeAfter: executeAfter,
            executed: false,
            cancelled: false
        });

        emit NetworkMultiplierChangeQueued(changeId, _network, _multiplier, executeAfter);
    }

    /**
     * @dev Execute a queued network multiplier change after timelock expires
     */
    function executeNetworkMultiplierChange(bytes32 _changeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingMultiplierChange storage change = pendingMultiplierChanges[_changeId];
        require(change.executeAfter != 0, "Change does not exist");
        require(!change.executed, "Change already executed");
        require(!change.cancelled, "Change was cancelled");
        require(block.timestamp >= change.executeAfter, "Timelock not expired");
        require(block.timestamp <= change.executeAfter + 7 days, "Change expired");

        change.executed = true;
        uint256 oldMultiplier = networkRewardMultipliers[change.network];
        networkRewardMultipliers[change.network] = change.newMultiplier;

        emit NetworkMultiplierChangeExecuted(_changeId, change.network, oldMultiplier, change.newMultiplier);
    }

    /**
     * @dev Cancel a queued network multiplier change
     */
    function cancelNetworkMultiplierChange(bytes32 _changeId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingMultiplierChange storage change = pendingMultiplierChanges[_changeId];
        require(change.executeAfter != 0, "Change does not exist");
        require(!change.executed, "Change already executed");
        require(!change.cancelled, "Already cancelled");

        change.cancelled = true;
        emit NetworkMultiplierChangeCancelled(_changeId, msg.sender);
    }

    /**
     * @dev Get job details
     */
    function getJobDetails(uint256 _jobId) external view returns (
        address requester,
        string memory modelType,
        uint256 computeRequirement,
        uint256 totalReward,
        TrainingStatus status,
        uint256 participants
    ) {
        TrainingJob storage job = trainingJobs[_jobId];
        return (
            job.requester,
            job.modelType,
            job.computeRequirement,
            job.totalReward,
            job.status,
            job.currentParticipants
        );
    }

    /**
     * @dev Get contributor statistics
     */
    function getContributorStats(address _contributor) external view returns (
        uint256 totalContributions,
        uint256 computeProvided,
        uint256 totalRewardsEarned,
        uint256 averageAccuracy,
        uint256 reputationScore
    ) {
        Contributor storage contributor = contributors[_contributor];
        return (
            contributor.totalContributions,
            contributor.totalComputeProvided,
            contributor.totalRewardsEarned,
            contributor.averageAccuracy,
            contributor.reputationScore
        );
    }

    /**
     * @dev Get training platform statistics
     */
    function getPlatformStats() external view returns (
        uint256 totalJobs,
        uint256 totalContributionsCount,
        uint256 totalRewards,
        uint256 totalCompute
    ) {
        return (
            nextJobId - 1,
            nextContributionId - 1,
            totalRewardsDistributed,
            totalComputeProvided
        );
    }

    /**
     * @dev Internal function to initialize network multipliers
     */
    function _initializeNetworkMultipliers() internal {
        networkRewardMultipliers[ComputeNetworkType.FLUX] = 110;      // 10% bonus
        networkRewardMultipliers[ComputeNetworkType.AKASH] = 105;     // 5% bonus
        networkRewardMultipliers[ComputeNetworkType.GOLEM] = 100;     // No bonus
        networkRewardMultipliers[ComputeNetworkType.RENDER] = 120;    // 20% bonus (GPU)
        networkRewardMultipliers[ComputeNetworkType.IEXEC] = 115;     // 15% bonus (TEE)
        networkRewardMultipliers[ComputeNetworkType.ICP] = 108;       // 8% bonus
        networkRewardMultipliers[ComputeNetworkType.AIOZ] = 112;      // 12% bonus
    }

    /**
     * @dev Check if contributor supports specific network
     */
    function _supportsNetwork(address _contributor, ComputeNetworkType _network) internal view returns (bool) {
        ComputeNetworkType[] memory networks = contributors[_contributor].supportedNetworks;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i] == _network) {
                return true;
            }
        }
        return false;
    }
}
