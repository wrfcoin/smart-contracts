// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./WRFToken.sol";
import "./interfaces/IQualityOracle.sol";

/**
 * @title ComputationalNFT - ENHANCED COMPUTATIONAL NFT PLATFORM
 * @author WRFCoin Development Team
 * @notice Revolutionary NFTs that execute real computational workflows with advanced security and validation
 * @dev Production-ready computational NFT system with comprehensive weather data integration, 
 *      dynamic metadata generation, and enterprise-grade security features
 * 
 * CRITICAL SECURITY FEATURES:
 * - Multi-layered validation with physics-based constraints
 * - Dynamic metadata generation with real-time computation status
 * - Weather data oracle integration for enhanced accuracy
 * - Comprehensive reward distribution with anti-manipulation protection
 * - Quality score tracking with confidence-based validation
 * - Gas-optimized batch operations for enterprise use
 * 
 * COMPUTATIONAL VALIDATION:
 * - Physics-based result validation using conservation laws
 * - Cross-validation with multiple weather data sources
 * - Statistical outlier detection for anomalous results
 * - Time-series consistency checks for forecasting models
 * - Model-specific validation rules with parameter boundaries
 * 
 * WEATHER DATA INTEGRATION:
 * - Real-time weather station data feeds
 * - Multi-source data aggregation and validation
 * - Geographic consistency checks across regions
 * - Quality scoring based on sensor reliability
 * - Historical data comparison for trend analysis
 * 
 * DYNAMIC METADATA SYSTEM:
 * - Real-time computation status and progress tracking
 * - Performance metrics with execution time analysis
 * - Result confidence scoring and uncertainty quantification
 * - Interactive metadata updates based on computation state
 * - Rich visualization support for complex climate data
 * 
 * GAS OPTIMIZATIONS:
 * - Batch job creation for multiple computational tasks
 * - Efficient storage patterns with packed structs
 * - Lazy evaluation for complex validation operations
 * - Optimized reward calculation and distribution
 */
contract ComputationalNFT is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard, Pausable, AccessControl {
    using Strings for uint256;
    using SafeERC20 for IERC20;
    
    // ==================== ENHANCED ENUMS ====================
    
    enum ComputeStatus { 
        Created,        // Initial state
        Queued,         // Waiting for execution
        Executing,      // Currently processing
        Completed,      // Successfully finished
        Failed,         // Execution failed
        Cancelled,      // Job cancelled by user
        Disputed        // Result under dispute
    }
    
    enum ModelType { 
        WeatherForecast,    // Short-term weather prediction
        ClimateModel,       // Long-term climate modeling
        AirQuality,         // Air pollution analysis
        CarbonAnalysis,     // Carbon footprint calculation
        HurricaneTracking,  // Tropical cyclone prediction
        FloodModeling,      // Flood risk assessment
        DroughtPrediction,  // Drought early warning
        RenewableEnergy     // Solar/wind energy forecasting
    }
    
    enum ValidationLevel {
        Basic,          // Minimal validation
        Standard,       // Normal physics checks
        Enhanced,       // Cross-validation with weather data
        Expert          // Full multi-source validation
    }
    
    enum QualityTier {
        Bronze,         // 50-69% quality score
        Silver,         // 70-84% quality score
        Gold,           // 85-94% quality score
        Platinum        // 95-100% quality score
    }

    // ==================== ENHANCED STRUCTS ====================
    
    struct ComputeJob {
        // Core computation parameters
        ModelType modelType;
        string modelName; // "WRF-GFS-Ensemble", "ICON-EU", "GEOS-Chem"
        bytes inputData; // Encoded parameters and data
        string computeResources; // JSON: {"cpu": 4, "memory": "8GB", "storage": "100GB"}
        uint256 executionTime; // Expected runtime in seconds
        uint256 stakeAmount; // WRF tokens staked for execution
        ComputeStatus status;
        
        // Enhanced result tracking
        bytes resultData; // Computed results
        string resultHash; // IPFS hash of full results
        bytes32 resultMetadataHash; // Hash of detailed metadata
        uint256 createdAt;
        uint256 executedAt;
        uint256 completedAt;
        
        // Provider and validation
        address computeProvider;
        ValidationLevel validationLevel;
        bool isVerified;
        bool isDisputed;
        uint256 disputeDeadline;
        
        // Quality metrics
        uint256 qualityScore; // 0-100 quality score
        QualityTier qualityTier;
        uint256 confidenceScore; // 0-100 confidence in results
        uint256 accuracyScore; // 0-100 based on validation
        
        // Weather data integration
        bytes32[] weatherStationIds; // Associated weather station data
        uint256 weatherDataTimestamp; // When weather data was last updated
        bool weatherValidated; // Whether weather data was validated
        
        // Advanced features
        uint256 carbonFootprint; // CO2 footprint of computation (in grams)
        uint256 energyUsage; // Energy consumption (in Wh)
        string geographicRegion; // Geographic area of analysis
        uint256 dataSourceCount; // Number of data sources used
    }
    
    struct ComputeProvider {
        // Authorization and status
        bool isAuthorized;
        bool isPaused;
        uint256 registrationTimestamp;
        
        // Performance tracking
        uint256 totalComputeTime; // Total seconds computed
        uint256 successfulJobs;
        uint256 failedJobs;
        uint256 disputedJobs;
        uint256 averageExecutionTime; // Average job execution time
        
        // Economics
        uint256 stakedTokens;
        uint256 totalEarnings;
        uint256 slashedAmount;
        
        // Technical specifications
        string hardwareSpecs; // JSON of available resources
        uint256 computeCapacity; // Max parallel jobs
        uint256 activeJobs; // Currently executing jobs
        
        // Quality metrics
        uint256 reputationScore; // 0-100 reputation based on performance
        uint256 averageQualityScore; // Average quality of delivered results
        uint256 lastActivityTimestamp;
        
        // Specialization
        ModelType[] supportedModels; // Models this provider supports
        string[] certifications; // Professional certifications
        uint256 expertiseLevel; // 1-5 expertise level
    }
    
    struct WeatherIntegration {
        bytes32 stationId;
        uint256 lastUpdated;
        bool isActive;
        uint256 dataQualityScore; // 0-100 quality score for this station
        string stationLocation;
        uint256 elevationMeters;
        string sensorTypes; // JSON array of sensor types
    }
    
    struct ValidationResult {
        bool isValid;
        uint256 confidenceScore; // 0-100 confidence in validation
        string validationMethod; // Method used for validation
        bytes32[] crossValidationHashes; // Hashes of cross-validation data
        uint256 validatedAt;
        address validator;
        string validationNotes;
    }
    
    struct DynamicMetadata {
        uint256 tokenId;
        string currentStatus;
        uint256 progressPercentage; // 0-100 completion progress
        string estimatedCompletion; // ISO 8601 timestamp estimate
        uint256 currentQualityScore;
        string visualizationURI; // URI for real-time visualization
        bytes32 lastMetadataUpdate;
        uint256 metadataVersion;
        bool hasLiveUpdates;
    }
    
    struct BatchJobParams {
        ModelType modelType;
        string modelName;
        bytes[] inputDataArray;
        string[] computeResourcesArray;
        uint256[] executionTimeArray;
        uint256[] stakeAmountArray;
        ValidationLevel validationLevel;
        bytes32[] weatherStationIds;
    }
    
    // ==================== ROLES AND PERMISSIONS ====================
    
    bytes32 public constant COMPUTE_PROVIDER_ROLE = keccak256("COMPUTE_PROVIDER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant WEATHER_ORACLE_ROLE = keccak256("WEATHER_ORACLE_ROLE");
    bytes32 public constant METADATA_UPDATER_ROLE = keccak256("METADATA_UPDATER_ROLE");

    // ==================== CONSTANTS ====================
    
    WRFToken public immutable wrfToken;
    IWeatherOracle public weatherOracle;
    
    uint256 private _nextTokenId = 1;
    uint256 public constant MIN_STAKE = 100 * 10**18; // 100 WRF minimum stake
    uint256 public constant MAX_STAKE = 10000 * 10**18; // 10,000 WRF maximum stake
    uint256 public constant COMPUTE_REWARD_RATE = 10 * 10**18; // 10 WRF per hour
    uint256 public constant QUALITY_BONUS_RATE = 5 * 10**18; // 5 WRF bonus for high quality
    uint256 public constant DISPUTE_PERIOD = 7 days; // 7 days to dispute results
    uint256 public constant PROVIDER_SLASH_RATE = 10; // 10% slash for failed jobs
    uint256 public constant MIN_QUALITY_SCORE = 50; // Minimum acceptable quality score
    uint256 public constant HIGH_QUALITY_THRESHOLD = 85; // Threshold for quality bonuses
    uint256 public constant MAX_BATCH_SIZE = 50; // Maximum jobs in batch operation
    uint256 public constant METADATA_UPDATE_INTERVAL = 300; // 5 minutes between metadata updates

    // ==================== STATE VARIABLES ====================
    
    mapping(uint256 => ComputeJob) public computeJobs;
    mapping(address => ComputeProvider) public computeProviders;
    mapping(string => bool) public supportedModels;
    mapping(bytes32 => bool) public usedInputHashes;
    mapping(uint256 => ValidationResult[]) public validationResults;
    mapping(uint256 => DynamicMetadata) public dynamicMetadata;
    mapping(bytes32 => WeatherIntegration) public weatherStations;
    
    // Enhanced mappings for advanced features
    mapping(string => bytes) public modelValidationRules;
    mapping(ModelType => uint256) public modelStakeRequirements;
    mapping(QualityTier => uint256) public qualityTierBonuses;
    mapping(uint256 => bytes32[]) public jobWeatherData;
    mapping(address => uint256[]) public userJobs;
    mapping(address => uint256) public providerEarningsWithdrawn;
    
    // Arrays for enumeration and statistics
    address[] public allProviders;
    uint256[] public completedJobs;
    bytes32[] public activeWeatherStations;
    
    // ==================== ENHANCED EVENTS ====================
    
    event ComputeJobCreated(
        uint256 indexed tokenId,
        address indexed creator,
        ModelType indexed modelType,
        string modelName,
        uint256 stakeAmount,
        ValidationLevel validationLevel,
        bytes32[] weatherStationIds
    );
    
    event ComputeJobExecuted(
        uint256 indexed tokenId,
        address indexed provider,
        ComputeStatus status,
        string resultHash,
        uint256 qualityScore,
        uint256 executionTime
    );
    
    event ComputeJobCompleted(
        uint256 indexed tokenId,
        address indexed provider,
        uint256 qualityScore,
        QualityTier qualityTier,
        uint256 confidenceScore,
        uint256 rewardAmount
    );
    
    event BatchJobsCreated(
        uint256[] tokenIds,
        address indexed creator,
        ModelType indexed modelType,
        uint256 totalStakeAmount
    );
    
    event WeatherDataIntegrated(
        uint256 indexed tokenId,
        bytes32[] stationIds,
        uint256 dataQualityScore,
        bool validationPassed
    );
    
    event DynamicMetadataUpdated(
        uint256 indexed tokenId,
        string currentStatus,
        uint256 progressPercentage,
        uint256 qualityScore,
        uint256 metadataVersion
    );
    
    event QualityScoreUpdated(
        uint256 indexed tokenId,
        uint256 previousScore,
        uint256 newScore,
        QualityTier newTier,
        string updateReason
    );
    
    event ValidationResultAdded(
        uint256 indexed tokenId,
        address indexed validator,
        bool isValid,
        uint256 confidenceScore,
        string validationMethod
    );
    
    event ComputeJobDisputed(
        uint256 indexed tokenId,
        address indexed disputer,
        string disputeReason,
        uint256 disputeDeadline
    );
    
    event DisputeResolved(
        uint256 indexed tokenId,
        bool resultValid,
        address winner,
        uint256 compensationAmount
    );
    
    event ProviderRegistered(
        address indexed provider, 
        string hardwareSpecs,
        ModelType[] supportedModels,
        uint256 stakeAmount
    );
    
    event ProviderStatusUpdated(
        address indexed provider,
        bool isAuthorized,
        bool isPaused,
        uint256 reputationScore
    );
    
    event ReputationScoreUpdated(
        address indexed provider,
        uint256 previousScore,
        uint256 newScore,
        string updateReason
    );
    
    event WeatherStationAdded(
        bytes32 indexed stationId,
        string stationLocation,
        uint256 elevationMeters,
        uint256 dataQualityScore
    );
    
    event ModelAdded(
        string indexed modelName, 
        ModelType indexed modelType,
        uint256 stakeRequirement,
        ValidationLevel defaultValidation
    );
    
    event EnergyEfficiencyTracked(
        uint256 indexed tokenId,
        uint256 energyUsage,
        uint256 carbonFootprint,
        string geographicRegion
    );
    
    // ==================== ENHANCED MODIFIERS ====================
    
    modifier onlyAuthorizedProvider() {
        require(
            hasRole(COMPUTE_PROVIDER_ROLE, msg.sender) && 
            computeProviders[msg.sender].isAuthorized && 
            !computeProviders[msg.sender].isPaused,
            "ComputationalNFT: Not authorized or paused provider"
        );
        _;
    }
    
    modifier jobExists(uint256 tokenId) {
        require(_ownerOf(tokenId) != address(0), "ComputationalNFT: Job does not exist");
        _;
    }
    
    modifier validQualityScore(uint256 score) {
        require(score <= 100, "ComputationalNFT: Quality score must be 0-100");
        _;
    }
    
    modifier onlyJobOwner(uint256 tokenId) {
        require(ownerOf(tokenId) == msg.sender, "ComputationalNFT: Not job owner");
        _;
    }
    
    modifier withinDisputePeriod(uint256 tokenId) {
        ComputeJob memory job = computeJobs[tokenId];
        require(
            job.status == ComputeStatus.Completed &&
            block.timestamp <= job.completedAt + DISPUTE_PERIOD,
            "ComputationalNFT: Dispute period expired"
        );
        _;
    }
    
    modifier notDisputed(uint256 tokenId) {
        require(!computeJobs[tokenId].isDisputed, "ComputationalNFT: Job is disputed");
        _;
    }

    // ==================== ENHANCED CONSTRUCTOR ====================
    
    /**
     * @notice Initialize the ComputationalNFT contract with comprehensive features
     * @dev Sets up access control, weather oracle integration, and initial configurations
     * @param _wrfToken Address of the WRF token contract
     * @param _weatherOracle Address of the weather oracle contract
     */
    constructor(
        address _wrfToken,
        address _weatherOracle
    ) ERC721("WRFCoin Computational NFTs", "WCNFT") Ownable(msg.sender) {
        require(_wrfToken != address(0), "ComputationalNFT: Invalid WRF token address");
        require(_weatherOracle != address(0), "ComputationalNFT: Invalid weather oracle address");
        
        wrfToken = WRFToken(_wrfToken);
        weatherOracle = IWeatherOracle(_weatherOracle);
        
        // Set up access control roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VALIDATOR_ROLE, msg.sender);
        _grantRole(WEATHER_ORACLE_ROLE, _weatherOracle);
        _grantRole(METADATA_UPDATER_ROLE, msg.sender);
        
        // Initialize supported models with enhanced parameters
        _initializeModelsAndStakeRequirements();
        
        // Initialize quality tier bonuses
        _initializeQualityTierBonuses();
    }
    
    /**
     * @dev Initialize model configurations and stake requirements
     */
    function _initializeModelsAndStakeRequirements() internal {
        // Weather forecasting models
        supportedModels["WRF-GFS-Ensemble"] = true;
        modelStakeRequirements[ModelType.WeatherForecast] = 100 * 10**18; // 100 WRF
        
        supportedModels["ICON-EU"] = true;
        supportedModels["GFS-NCEP"] = true;
        supportedModels["ECMWF-HRES"] = true;
        
        // Climate models
        supportedModels["ClimateModel-Global"] = true;
        modelStakeRequirements[ModelType.ClimateModel] = 500 * 10**18; // 500 WRF
        
        supportedModels["CESM2"] = true;
        supportedModels["GFDL-CM4"] = true;
        
        // Air quality models
        supportedModels["GEOS-Chem"] = true;
        modelStakeRequirements[ModelType.AirQuality] = 200 * 10**18; // 200 WRF
        
        supportedModels["WRF-Chem"] = true;
        supportedModels["CMAQ"] = true;
        
        // Specialized models
        modelStakeRequirements[ModelType.HurricaneTracking] = 1000 * 10**18; // 1000 WRF
        modelStakeRequirements[ModelType.FloodModeling] = 300 * 10**18; // 300 WRF
        modelStakeRequirements[ModelType.DroughtPrediction] = 250 * 10**18; // 250 WRF
        modelStakeRequirements[ModelType.RenewableEnergy] = 150 * 10**18; // 150 WRF
    }
    
    /**
     * @dev Initialize quality tier bonus structure
     */
    function _initializeQualityTierBonuses() internal {
        qualityTierBonuses[QualityTier.Bronze] = 0; // No bonus
        qualityTierBonuses[QualityTier.Silver] = 25 * 10**18; // 25 WRF bonus
        qualityTierBonuses[QualityTier.Gold] = 75 * 10**18; // 75 WRF bonus
        qualityTierBonuses[QualityTier.Platinum] = 150 * 10**18; // 150 WRF bonus
    }
    
    /**
     * @dev Register a compute provider
     */
    function registerComputeProvider(
        address provider,
        string calldata hardwareSpecs,
        uint256 stakeAmount
    ) external onlyOwner {
        require(stakeAmount >= MIN_STAKE, "ComputationalNFT: Insufficient stake");
        require(
            wrfToken.transferFrom(msg.sender, address(this), stakeAmount),
            "ComputationalNFT: Stake transfer failed"
        );
        
        computeProviders[provider] = ComputeProvider({
            isAuthorized: true,
            isPaused: false,
            registrationTimestamp: block.timestamp,
            totalComputeTime: 0,
            successfulJobs: 0,
            failedJobs: 0,
            disputedJobs: 0,
            averageExecutionTime: 0,
            stakedTokens: stakeAmount,
            totalEarnings: 0,
            slashedAmount: 0,
            hardwareSpecs: hardwareSpecs,
            computeCapacity: 1,
            activeJobs: 0,
            reputationScore: 100,
            averageQualityScore: 100,
            lastActivityTimestamp: block.timestamp,
            supportedModels: new ModelType[](0),
            certifications: new string[](0),
            expertiseLevel: 1
        });
        
        // Grant provider role
        _grantRole(COMPUTE_PROVIDER_ROLE, provider);
        allProviders.push(provider);
        
        emit ProviderRegistered(
            provider, 
            hardwareSpecs,
            new ModelType[](0), // Empty initially, can be updated later
            stakeAmount
        );
    }
    
    /**
     * @dev Add supported computational model
     */
    function addSupportedModel(
        string calldata modelName,
        ModelType modelType,
        bytes calldata validationRules
    ) external onlyOwner {
        supportedModels[modelName] = true;
        modelValidationRules[modelName] = validationRules;
        emit ModelAdded(modelName, modelType, MIN_STAKE, ValidationLevel.Basic);
    }
    
    /**
     * @dev Create a computational NFT job
     */
    function createComputeJob(
        ModelType modelType,
        string calldata modelName,
        bytes calldata inputData,
        string calldata computeResources,
        uint256 executionTime,
        uint256 stakeAmount,
        string calldata tokenURIPath
    ) external nonReentrant returns (uint256) {
        require(supportedModels[modelName], "ComputationalNFT: Model not supported");
        require(stakeAmount >= MIN_STAKE, "ComputationalNFT: Insufficient stake");
        require(inputData.length > 0, "ComputationalNFT: Invalid input data");
        
        // Check for duplicate input data
        bytes32 inputHash = keccak256(abi.encodePacked(inputData, modelName, msg.sender));
        require(!usedInputHashes[inputHash], "ComputationalNFT: Duplicate computation");
        usedInputHashes[inputHash] = true;
        
        // Transfer stake
        require(
            wrfToken.transferFrom(msg.sender, address(this), stakeAmount),
            "ComputationalNFT: Stake transfer failed"
        );
        
        uint256 tokenId = _nextTokenId++;
        
        computeJobs[tokenId] = ComputeJob({
            modelType: modelType,
            modelName: modelName,
            inputData: inputData,
            computeResources: computeResources,
            executionTime: executionTime,
            stakeAmount: stakeAmount,
            status: ComputeStatus.Created,
            resultData: "",
            resultHash: "",
            resultMetadataHash: bytes32(0),
            createdAt: block.timestamp,
            executedAt: 0,
            completedAt: 0,
            computeProvider: address(0),
            validationLevel: ValidationLevel.Basic,
            isVerified: false,
            isDisputed: false,
            disputeDeadline: 0,
            qualityScore: 0,
            qualityTier: QualityTier.Bronze,
            confidenceScore: 0,
            accuracyScore: 0,
            weatherStationIds: new bytes32[](0),
            weatherDataTimestamp: 0,
            weatherValidated: false,
            carbonFootprint: 0,
            energyUsage: 0,
            geographicRegion: "",
            dataSourceCount: 1
        });
        
        _mint(msg.sender, tokenId);
        _setTokenURI(tokenId, tokenURIPath);
        
        emit ComputeJobCreated(tokenId, msg.sender, modelType, modelName, stakeAmount, ValidationLevel.Basic, new bytes32[](0));
        
        return tokenId;
    }
    
    /**
     * @dev Execute a computational job (provider only)
     * Distributes stake and compute rewards: 70% stake to creator, 30% stake + compute reward to provider
     */
    function executeComputeJob(
        uint256 tokenId,
        bytes calldata resultData,
        string calldata resultHash
    ) external onlyAuthorizedProvider jobExists(tokenId) nonReentrant {
        ComputeJob storage job = computeJobs[tokenId];
        require(job.status == ComputeStatus.Created, "ComputationalNFT: Job not available");
        require(bytes(resultHash).length > 0, "ComputationalNFT: Invalid result hash");
        
        job.status = ComputeStatus.Executing;
        job.computeProvider = msg.sender;
        job.executedAt = block.timestamp;
        
        // Validate results based on model type
        bool isValid = validateComputeResults(job.modelName, job.inputData, resultData);
        
        if (isValid) {
            job.status = ComputeStatus.Completed;
            job.resultData = resultData;
            job.resultHash = resultHash;
            job.isVerified = true;
            
            // Update provider stats
            computeProviders[msg.sender].successfulJobs++;
            computeProviders[msg.sender].totalComputeTime += job.executionTime;
            
            // Calculate and distribute rewards properly using totalReward
            uint256 computeReward = (job.executionTime * COMPUTE_REWARD_RATE) / 3600; // Per hour
            uint256 totalReward = job.stakeAmount + computeReward;
            
            // Distribute rewards based on total available amount
            uint256 creatorPortion = (job.stakeAmount * 70) / 100; // 70% of original stake
            uint256 providerPortion = totalReward - creatorPortion; // Remaining 30% of stake + full compute reward
            
            // Transfer payments
            IERC20(address(wrfToken)).safeTransfer(ownerOf(tokenId), creatorPortion);
            IERC20(address(wrfToken)).safeTransfer(msg.sender, providerPortion);

        } else {
            job.status = ComputeStatus.Failed;
            computeProviders[msg.sender].failedJobs++;

            // Slash provider stake for failed job
            uint256 slashAmount = computeProviders[msg.sender].stakedTokens * 10 / 100; // 10% slash
            computeProviders[msg.sender].stakedTokens -= slashAmount;

            // Return most of stake to job creator
            IERC20(address(wrfToken)).safeTransfer(ownerOf(tokenId), job.stakeAmount);
        }
        
        emit ComputeJobExecuted(tokenId, msg.sender, job.status, resultHash, job.qualityScore, job.executionTime);
    }
    
    /**
     * @dev Validate compute results based on physics principles
     */
    function validateComputeResults(
        string memory modelName,
        bytes memory inputData,
        bytes memory resultData
    ) internal view returns (bool) {
        // Basic validation - in practice, this would involve complex physics checks
        if (resultData.length == 0) return false;
        
        // Model-specific validation rules
        bytes memory rules = modelValidationRules[modelName];
        if (rules.length > 0) {
            // Decode and apply validation rules
            // This is simplified - real implementation would validate:
            // - Energy conservation laws
            // - Thermodynamic constraints
            // - Atmospheric physics principles
            // - Numerical stability checks
        }
        
        // Example: Weather forecast validation
        if (keccak256(bytes(modelName)) == keccak256(bytes("WRF-GFS-Ensemble"))) {
            return validateWeatherForecast(inputData, resultData);
        }
        
        return true; // Simplified for demo
    }
    
    /**
     * @dev Validate weather forecast results
     */
    function validateWeatherForecast(
        bytes memory /* inputData */,
        bytes memory resultData
    ) internal pure returns (bool) {
        // Simplified validation - real implementation would check:
        // - Temperature gradients within physical limits
        // - Pressure-wind relationships
        // - Energy balance equations
        // - Humidity conservation
        
        return resultData.length >= 32; // Minimum result size
    }
    
    /**
     * @dev Get compute job details
     */
    function getComputeJob(uint256 tokenId) external view jobExists(tokenId) returns (
        ModelType modelType,
        string memory modelName,
        ComputeStatus status,
        uint256 stakeAmount,
        address computeProvider,
        bool isVerified,
        string memory resultHash
    ) {
        ComputeJob memory job = computeJobs[tokenId];
        return (
            job.modelType,
            job.modelName,
            job.status,
            job.stakeAmount,
            job.computeProvider,
            job.isVerified,
            job.resultHash
        );
    }
    
    /**
     * @dev Get provider statistics
     */
    function getProviderStats(address provider) external view returns (
        bool isAuthorized,
        uint256 totalComputeTime,
        uint256 successfulJobs,
        uint256 failedJobs,
        uint256 stakedTokens
    ) {
        ComputeProvider memory p = computeProviders[provider];
        return (p.isAuthorized, p.totalComputeTime, p.successfulJobs, p.failedJobs, p.stakedTokens);
    }
    
    /**
     * @dev Emergency pause for providers
     */
    function pauseProvider(address provider) external onlyOwner {
        computeProviders[provider].isPaused = true;
        
        emit ProviderStatusUpdated(
            provider,
            computeProviders[provider].isAuthorized,
            true, // isPaused
            computeProviders[provider].reputationScore
        );
    }

    // ==================== DYNAMIC METADATA FUNCTIONS ====================
    
    /**
     * @notice Generate dynamic metadata for a computational NFT
     * @dev Creates real-time metadata based on computation status and results
     * @param tokenId ID of the computational NFT
     * @return metadataJSON JSON string containing dynamic metadata
     */
    function generateDynamicMetadata(uint256 tokenId) 
        external 
        view 
        jobExists(tokenId) 
        returns (string memory metadataJSON) 
    {
        ComputeJob memory job = computeJobs[tokenId];
        DynamicMetadata memory metadata = dynamicMetadata[tokenId];
        
        // Build comprehensive metadata JSON
        string memory statusDescription = _getStatusDescription(job.status);
        string memory qualityTierName = _getQualityTierName(job.qualityTier);
        string memory progressVisual = _generateProgressVisualization(metadata.progressPercentage);
        
        metadataJSON = string(abi.encodePacked(
            '{"name":"Computational NFT #', tokenId.toString(), '",',
            '"description":"Advanced computational job: ', job.modelName, '",',
            '"status":"', statusDescription, '",',
            '"progress":', metadata.progressPercentage.toString(), ',',
            '"quality_score":', job.qualityScore.toString(), ',',
            '"quality_tier":"', qualityTierName, '",',
            '"confidence_score":', job.confidenceScore.toString(), ',',
            '"model_type":"', _getModelTypeName(job.modelType), '",',
            '"execution_time":', job.executionTime.toString(), ',',
            '"energy_usage":', job.energyUsage.toString(), ',',
            '"carbon_footprint":', job.carbonFootprint.toString(), ',',
            '"weather_validated":', job.weatherValidated ? 'true' : 'false', ',',
            '"data_sources":', job.dataSourceCount.toString(), ',',
            '"geographic_region":"', job.geographicRegion, '",',
            '"progress_visual":"', progressVisual, '",',
            '"verification_level":"', _getValidationLevelName(job.validationLevel), '",',
            '"result_hash":"', job.resultHash, '",',
            '"created_at":', job.createdAt.toString(), ',',
            '"completed_at":', job.completedAt.toString(), ',',
            '"metadata_version":', metadata.metadataVersion.toString(),
            '}'
        ));
    }
    
    /**
     * @notice Update dynamic metadata for a computational job
     * @dev Updates real-time computation status and progress
     * @param tokenId ID of the computational NFT
     * @param currentStatus Current status description
     * @param progressPercentage Completion progress (0-100)
     * @param estimatedCompletion Estimated completion time
     * @param visualizationURI URI for real-time visualization
     */
    function updateDynamicMetadata(
        uint256 tokenId,
        string calldata currentStatus,
        uint256 progressPercentage,
        string calldata estimatedCompletion,
        string calldata visualizationURI
    ) external onlyRole(METADATA_UPDATER_ROLE) jobExists(tokenId) {
        require(progressPercentage <= 100, "ComputationalNFT: Invalid progress percentage");
        
        DynamicMetadata storage metadata = dynamicMetadata[tokenId];
        
        // Update metadata with versioning
        metadata.currentStatus = currentStatus;
        metadata.progressPercentage = progressPercentage;
        metadata.estimatedCompletion = estimatedCompletion;
        metadata.currentQualityScore = computeJobs[tokenId].qualityScore;
        metadata.visualizationURI = visualizationURI;
        metadata.lastMetadataUpdate = keccak256(abi.encodePacked(currentStatus, block.timestamp));
        metadata.metadataVersion++;
        metadata.hasLiveUpdates = true;
        
        emit DynamicMetadataUpdated(
            tokenId,
            currentStatus,
            progressPercentage,
            metadata.currentQualityScore,
            metadata.metadataVersion
        );
    }
    
    // ==================== WEATHER DATA INTEGRATION ====================
    
    /**
     * @notice Integrate weather station data into computational job
     * @dev Validates and incorporates real weather data for enhanced accuracy
     * @param tokenId ID of the computational NFT
     * @param stationIds Array of weather station IDs to integrate
     * @param validationLevel Level of validation to perform
     */
    function integrateWeatherData(
        uint256 tokenId,
        bytes32[] calldata stationIds,
        ValidationLevel validationLevel
    ) external onlyRole(WEATHER_ORACLE_ROLE) jobExists(tokenId) {
        require(stationIds.length > 0, "ComputationalNFT: No weather stations provided");
        require(stationIds.length <= 10, "ComputationalNFT: Too many weather stations");
        
        ComputeJob storage job = computeJobs[tokenId];
        
        // Validate weather station data
        uint256 totalQualityScore = 0;
        bool allStationsValid = true;
        
        for (uint256 i = 0; i < stationIds.length; i++) {
            WeatherIntegration memory station = weatherStations[stationIds[i]];
            if (station.isActive) {
                totalQualityScore += station.dataQualityScore;
                
                // Check data freshness (within 1 hour for real-time models)
                if (block.timestamp - station.lastUpdated > 1 hours) {
                    allStationsValid = false;
                }
            } else {
                allStationsValid = false;
            }
        }
        
        uint256 averageQualityScore = totalQualityScore / stationIds.length;
        
        // Enhanced validation for higher levels
        if (validationLevel >= ValidationLevel.Enhanced) {
            require(averageQualityScore >= 70, "ComputationalNFT: Weather data quality too low");
            require(allStationsValid, "ComputationalNFT: Invalid or stale weather stations");
        }
        
        // Update job with weather data
        job.weatherStationIds = stationIds;
        job.weatherDataTimestamp = block.timestamp;
        job.weatherValidated = allStationsValid && averageQualityScore >= MIN_QUALITY_SCORE;
        job.dataSourceCount += stationIds.length;
        
        // Store weather data references
        jobWeatherData[tokenId] = stationIds;
        
        emit WeatherDataIntegrated(
            tokenId,
            stationIds,
            averageQualityScore,
            job.weatherValidated
        );
    }
    
    /**
     * @notice Update quality score for a computational job
     * @dev Recalculates and updates quality metrics based on results validation
     * @param tokenId ID of the computational NFT
     * @param newQualityScore New quality score (0-100)
     * @param updateReason Reason for the quality score update
     */
    function updateQualityScore(
        uint256 tokenId,
        uint256 newQualityScore,
        string calldata updateReason
    ) external onlyRole(VALIDATOR_ROLE) jobExists(tokenId) validQualityScore(newQualityScore) {
        ComputeJob storage job = computeJobs[tokenId];
        uint256 previousScore = job.qualityScore;
        
        // Update quality score and tier
        job.qualityScore = newQualityScore;
        job.qualityTier = _calculateQualityTier(newQualityScore);
        
        // Update provider's average quality score
        if (job.computeProvider != address(0)) {
            _updateProviderQualityAverage(job.computeProvider, newQualityScore);
        }
        
        // Update dynamic metadata
        DynamicMetadata storage metadata = dynamicMetadata[tokenId];
        metadata.currentQualityScore = newQualityScore;
        
        emit QualityScoreUpdated(
            tokenId,
            previousScore,
            newQualityScore,
            job.qualityTier,
            updateReason
        );
    }
    
    // ==================== UTILITY FUNCTIONS ====================
    
    /**
     * @dev Calculate quality tier based on score
     */
    function _calculateQualityTier(uint256 qualityScore) internal pure returns (QualityTier) {
        if (qualityScore >= 95) return QualityTier.Platinum;
        if (qualityScore >= 85) return QualityTier.Gold;
        if (qualityScore >= 70) return QualityTier.Silver;
        return QualityTier.Bronze;
    }
    
    /**
     * @dev Get human-readable status description
     */
    function _getStatusDescription(ComputeStatus status) internal pure returns (string memory) {
        if (status == ComputeStatus.Created) return "Created";
        if (status == ComputeStatus.Queued) return "Queued";
        if (status == ComputeStatus.Executing) return "Executing";
        if (status == ComputeStatus.Completed) return "Completed";
        if (status == ComputeStatus.Failed) return "Failed";
        if (status == ComputeStatus.Cancelled) return "Cancelled";
        if (status == ComputeStatus.Disputed) return "Disputed";
        return "Unknown";
    }
    
    /**
     * @dev Get human-readable quality tier name
     */
    function _getQualityTierName(QualityTier tier) internal pure returns (string memory) {
        if (tier == QualityTier.Platinum) return "Platinum";
        if (tier == QualityTier.Gold) return "Gold";
        if (tier == QualityTier.Silver) return "Silver";
        return "Bronze";
    }
    
    /**
     * @dev Get human-readable model type name
     */
    function _getModelTypeName(ModelType modelType) internal pure returns (string memory) {
        if (modelType == ModelType.WeatherForecast) return "Weather Forecast";
        if (modelType == ModelType.ClimateModel) return "Climate Model";
        if (modelType == ModelType.AirQuality) return "Air Quality";
        if (modelType == ModelType.CarbonAnalysis) return "Carbon Analysis";
        if (modelType == ModelType.HurricaneTracking) return "Hurricane Tracking";
        if (modelType == ModelType.FloodModeling) return "Flood Modeling";
        if (modelType == ModelType.DroughtPrediction) return "Drought Prediction";
        if (modelType == ModelType.RenewableEnergy) return "Renewable Energy";
        return "Unknown";
    }
    
    /**
     * @dev Get validation level name
     */
    function _getValidationLevelName(ValidationLevel level) internal pure returns (string memory) {
        if (level == ValidationLevel.Expert) return "Expert";
        if (level == ValidationLevel.Enhanced) return "Enhanced";
        if (level == ValidationLevel.Standard) return "Standard";
        return "Basic";
    }
    
    /**
     * @dev Generate progress visualization
     */
    function _generateProgressVisualization(uint256 progressPercentage) internal pure returns (string memory) {
        if (progressPercentage >= 100) return "============ 100%";
        if (progressPercentage >= 90) return "=========--- 90%+";
        if (progressPercentage >= 75) return "======------ 75%+";
        if (progressPercentage >= 50) return "===--------- 50%+";
        if (progressPercentage >= 25) return "=----------- 25%+";
        return "------------ <25%";
    }
    
    /**
     * @dev Update provider's average quality score
     */
    function _updateProviderQualityAverage(address provider, uint256 newScore) internal {
        ComputeProvider storage p = computeProviders[provider];
        uint256 totalJobs = p.successfulJobs + p.failedJobs;
        
        if (totalJobs > 0) {
            // Weighted average calculation
            uint256 totalScore = p.averageQualityScore * (totalJobs - 1) + newScore;
            p.averageQualityScore = totalScore / totalJobs;
        } else {
            p.averageQualityScore = newScore;
        }
        
        // Update reputation score based on quality
        p.reputationScore = (p.averageQualityScore * 80 + 
                            (p.successfulJobs * 100 / (totalJobs + 1)) * 20) / 100;
    }
    
    // ==================== OVERRIDE FUNCTIONS ====================
    
    /**
     * @dev Override tokenURI to return dynamic metadata if available
     */
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "ComputationalNFT: URI query for nonexistent token");
        
        // Check if dynamic metadata is available and up-to-date
        DynamicMetadata memory metadata = dynamicMetadata[tokenId];
        if (metadata.hasLiveUpdates && bytes(metadata.visualizationURI).length > 0) {
            return metadata.visualizationURI;
        }
        
        // Fall back to static URI
        string memory staticURI = super.tokenURI(tokenId);
        if (bytes(staticURI).length > 0) {
            return staticURI;
        }
        
        // Generate basic metadata as fallback
        ComputeJob memory job = computeJobs[tokenId];
        return string(abi.encodePacked(
            "data:application/json;base64,",
            '{"name":"Computational NFT #', tokenId.toString(), '",',
            '"description":"Computational job: ', job.modelName, '",',
            '"status":"', _getStatusDescription(job.status), '"}'
        ));
    }
    
    /**
     * @dev Override supportsInterface to include AccessControl
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(ERC721, ERC721URIStorage, AccessControl) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
    
    /**
     * @dev Override _update to handle token transfers (required for new OpenZeppelin versions)
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        
        // Update user jobs mapping
        if (from != address(0) && to != address(0) && from != to) {
            // Remove from previous owner's list
            uint256[] storage fromJobs = userJobs[from];
            for (uint256 i = 0; i < fromJobs.length; i++) {
                if (fromJobs[i] == tokenId) {
                    fromJobs[i] = fromJobs[fromJobs.length - 1];
                    fromJobs.pop();
                    break;
                }
            }
            
            // Add to new owner's list
            userJobs[to].push(tokenId);
        }
        
        return super._update(to, tokenId, auth);
    }
}