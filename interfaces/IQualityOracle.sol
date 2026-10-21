// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOracleAggregator
 * @dev Interface for aggregating multiple oracle services with fallback mechanisms
 */
interface IOracleAggregator {
    
    enum OracleProvider {
        CHAINLINK,
        API3,
        BAND_PROTOCOL,
        DIA_DATA,
        TELLOR,
        CUSTOM
    }
    
    enum DataType {
        PRICE_FEED,
        WEATHER_DATA,
        VERIFICATION_STATUS,
        QUALITY_SCORE,
        VOLATILITY_DATA
    }
    
    struct OracleConfig {
        OracleProvider provider;
        address oracleAddress;
        uint256 weight;          // Weight for aggregation (basis points)
        uint256 maxStaleness;   // Maximum staleness in seconds
        uint256 minConfidence;  // Minimum confidence threshold
        bool isActive;
        string endpoint;        // For API-based oracles
    }
    
    struct DataFeed {
        uint256 value;
        uint256 timestamp;
        uint256 confidence;
        bytes32 dataHash;
        OracleProvider source;
    }
    
    struct AggregatedData {
        uint256 value;
        uint256 timestamp;
        uint256 confidence;
        uint256 sourceCount;
        uint256 deviation;      // Standard deviation of sources
    }
    
    // Events
    event OracleAdded(bytes32 indexed feedId, OracleProvider provider, address oracleAddress);
    event OracleRemoved(bytes32 indexed feedId, OracleProvider provider, address oracleAddress);
    event DataAggregated(bytes32 indexed feedId, uint256 value, uint256 confidence, uint256 sourceCount);
    event FallbackTriggered(bytes32 indexed feedId, OracleProvider failedProvider, OracleProvider fallbackProvider);
    event CircuitBreakerTriggered(bytes32 indexed feedId, string reason);
    
    // Oracle Management
    function addOracle(bytes32 feedId, OracleConfig calldata config) external;
    function removeOracle(bytes32 feedId, OracleProvider provider) external;
    function updateOracleConfig(bytes32 feedId, OracleProvider provider, OracleConfig calldata config) external;
    function setOracleWeight(bytes32 feedId, OracleProvider provider, uint256 weight) external;
    
    // Data Retrieval
    function getAggregatedData(bytes32 feedId) external view returns (AggregatedData memory);
    function getLatestPrice(bytes32 feedId) external view returns (uint256 price, uint256 timestamp);
    function getRoundData(bytes32 feedId, uint256 roundId) external view returns (DataFeed memory);
    
    // Data Validation
    function isDataFresh(bytes32 feedId, uint256 maxAge) external view returns (bool);
    function getDataConfidence(bytes32 feedId) external view returns (uint256);
    function validateDataIntegrity(bytes32 feedId) external view returns (bool);
    
    // Circuit Breaker
    function enableCircuitBreaker(bytes32 feedId) external;
    function disableCircuitBreaker(bytes32 feedId) external;
    function isCircuitBreakerTriggered(bytes32 feedId) external view returns (bool);
    
    // Fallback Management
    function setFallbackOracle(bytes32 feedId, OracleProvider primary, OracleProvider fallbackOracle) external;
    function triggerFallback(bytes32 feedId) external;
    
    // Metrics and Monitoring
    function getOracleHealth(bytes32 feedId, OracleProvider provider) external view returns (uint256 healthScore);
    function getAggregationHistory(
        bytes32 feedId, 
        uint256 fromTimestamp, 
        uint256 toTimestamp
    ) external view returns (AggregatedData[] memory);
}

/**
 * @title IQualityOracle
 * @dev Interface for tracking and evaluating carbon credit quality scores
 * This oracle provides comprehensive quality assessment for carbon credits
 * including various scoring metrics and historical data tracking
 */
interface IQualityOracle {
    
    struct QualityMetrics {
        uint256 overallScore;       // Overall quality score (0-100)
        uint256 vintageScore;       // Vintage year assessment
        uint256 projectTypeScore;   // Project type assessment  
        uint256 verificationScore;  // Verification standard score
        uint256 additionalityScore; // Additionality assessment
        uint256 permanenceScore;    // Permanence assessment
        uint256 cobenefitsScore;    // Co-benefits assessment
        uint256 timestamp;          // Last update timestamp
    }
    
    struct QualityHistory {
        uint256 quality;
        uint256 timestamp;
    }
    
    // Events
    event QualityUpdated(address indexed basketTokenAddress, uint256 newScore, uint256 timestamp);
    event QualityThresholdSet(uint256 threshold);
    event DetailedMetricsUpdated(address indexed basketTokenAddress, QualityMetrics metrics);
    
    /**
     * @dev Get the current quality score for a basket token
     * @param basketTokenAddress Address of the basket token
     * @return score Current quality score (0-100)
     */
    function getQualityScore(address basketTokenAddress) external view returns (uint256 score);
    
    /**
     * @dev Get detailed quality metrics for a basket token
     * @param basketTokenAddress Address of the basket token
     * @return metrics Detailed quality metrics structure
     */
    function getQualityMetrics(address basketTokenAddress) external view returns (QualityMetrics memory metrics);
    
    /**
     * @dev Update quality score for a basket token
     * @param basketTokenAddress Address of the basket token
     * @param newScore New quality score (0-100)
     */
    function updateQualityScore(address basketTokenAddress, uint256 newScore) external;
    
    /**
     * @dev Set detailed quality metrics for a basket token
     * @param basketTokenAddress Address of the basket token
     * @param metrics Detailed quality metrics
     */
    function setDetailedQualityMetrics(address basketTokenAddress, QualityMetrics calldata metrics) external;
    
    /**
     * @dev Check if quality score is above threshold
     * @param basketTokenAddress Address of the basket token
     * @return meetsThreshold True if quality meets minimum threshold
     */
    function meetsQualityThreshold(address basketTokenAddress) external view returns (bool meetsThreshold);
    
    /**
     * @dev Get quality tier based on score
     * @param basketTokenAddress Address of the basket token
     * @return tier Quality tier (1-5, 5 being highest quality)
     */
    function getQualityTier(address basketTokenAddress) external view returns (uint256 tier);
    
    /**
     * @dev Get pricing factor based on quality score
     * @param basketTokenAddress Address of the basket token  
     * @return factor Pricing factor as percentage (100 = no adjustment)
     */
    function getQualityPricingFactor(address basketTokenAddress) external view returns (uint256 factor);
    
    /**
     * @dev Check if quality data is fresh (updated recently)
     * @param basketTokenAddress Address of the basket token
     * @param maxAge Maximum age in seconds
     * @return isFresh True if data is fresh
     */
    function isQualityDataFresh(address basketTokenAddress, uint256 maxAge) external view returns (bool isFresh);
    
    /**
     * @dev Get historical quality data
     * @param basketTokenAddress Address of the basket token
     * @param fromTimestamp Start timestamp
     * @param toTimestamp End timestamp
     * @return history Array of historical quality data points
     */
    function getQualityHistory(
        address basketTokenAddress, 
        uint256 fromTimestamp, 
        uint256 toTimestamp
    ) external view returns (QualityHistory[] memory history);
    
    /**
     * @dev Compare quality between two basket tokens
     * @param tokenA First basket token address
     * @param tokenB Second basket token address
     * @return comparison -1 if A < B, 0 if A == B, 1 if A > B
     */
    function compareQuality(address tokenA, address tokenB) external view returns (int8 comparison);
    
    /**
     * @dev Update quality from basket token integration
     * @param basketTokenAddress Address of the basket token
     * @param newScore New quality score
     * @param metrics Detailed metrics from basket token
     */
    function updateFromBasketToken(
        address basketTokenAddress, 
        uint256 newScore, 
        QualityMetrics calldata metrics
    ) external;
    
    /**
     * @dev Batch update quality scores for multiple tokens
     * @param basketTokenAddresses Array of basket token addresses
     * @param scores Array of quality scores
     */
    function batchUpdateQuality(address[] calldata basketTokenAddresses, uint256[] calldata scores) external;
    
    /**
     * @dev Set tier thresholds for quality classification
     * @param tier1Min Minimum score for tier 1
     * @param tier2Min Minimum score for tier 2
     * @param tier3Min Minimum score for tier 3
     * @param tier4Min Minimum score for tier 4
     * @param tier5Min Minimum score for tier 5
     */
    function setTierThresholds(
        uint256 tier1Min, 
        uint256 tier2Min, 
        uint256 tier3Min, 
        uint256 tier4Min, 
        uint256 tier5Min
    ) external;
    
    /**
     * @dev Get minimum score for a specific tier
     * @param tier Tier number (1-5)
     * @return minScore Minimum score required for the tier
     */
    function getTierMinimumScore(uint256 tier) external view returns (uint256 minScore);
    
    /**
     * @dev Get time-weighted average quality over a period
     * @param basketTokenAddress Address of the basket token
     * @param period Time period in seconds
     * @return avgQuality Average quality over the period
     */
    function getTWAQuality(address basketTokenAddress, uint256 period) external view returns (uint256 avgQuality);
    
    /**
     * @dev Get relative quality compared to market average
     * @param basketTokenAddress Address of the basket token
     * @return relativeScore Relative score (100 = market average)
     */
    function getRelativeQuality(address basketTokenAddress) external view returns (uint256 relativeScore);
    
    /**
     * @dev Get length of quality history for a token
     * @param basketTokenAddress Address of the basket token
     * @return length Number of historical data points
     */
    function getQualityHistoryLength(address basketTokenAddress) external view returns (uint256 length);
    
    /**
     * @dev Get specific quality history point
     * @param basketTokenAddress Address of the basket token
     * @param index Index of the history point
     * @return historyPoint Quality history data point
     */
    function getQualityHistoryPoint(
        address basketTokenAddress, 
        uint256 index
    ) external view returns (QualityHistory memory historyPoint);
}

/**
 * @title IWeatherOracle
 * @dev Interface for climate and weather data feeds
 */
interface IWeatherOracle {
    
    struct WeatherData {
        int256 temperature;      // Temperature in Celsius * 100
        uint256 humidity;       // Humidity percentage * 100
        uint256 pressure;       // Atmospheric pressure in hPa * 100
        uint256 windSpeed;      // Wind speed in m/s * 100
        uint256 rainfall;       // Rainfall in mm * 100
        uint256 timestamp;      // Data timestamp
        bytes32 stationId;      // Weather station identifier
        uint256 confidence;     // Data confidence score (0-100)
    }
    
    struct ClimateData {
        uint256 co2Level;       // CO2 concentration in ppm * 100
        int256 avgTemperature;  // Average temperature over period
        uint256 precipitation;  // Total precipitation over period
        uint256 period;         // Time period in seconds
        uint256 timestamp;      // Data timestamp
        uint256 confidence;     // Data confidence score (0-100)
    }
    
    // Events
    event WeatherDataUpdated(bytes32 indexed stationId, WeatherData data);
    event ClimateDataUpdated(bytes32 indexed regionId, ClimateData data);
    event StationAdded(bytes32 indexed stationId, string location);
    event StationRemoved(bytes32 indexed stationId);
    
    // Weather Data Functions
    function updateWeatherData(bytes32 stationId, WeatherData calldata data) external;
    function getLatestWeatherData(bytes32 stationId) external view returns (WeatherData memory);
    function getWeatherDataHistory(
        bytes32 stationId, 
        uint256 fromTimestamp, 
        uint256 toTimestamp
    ) external view returns (WeatherData[] memory);
    function isWeatherDataFresh(bytes32 stationId, uint256 maxAge) external view returns (bool);
    
    // Climate Data Functions
    function updateClimateData(bytes32 regionId, ClimateData calldata data) external;
    function getLatestClimateData(bytes32 regionId) external view returns (ClimateData memory);
    function getClimateDataHistory(
        bytes32 regionId, 
        uint256 fromTimestamp, 
        uint256 toTimestamp
    ) external view returns (ClimateData[] memory);
    function isClimateDataFresh(bytes32 regionId, uint256 maxAge) external view returns (bool);
    
    // Station Management
    function addWeatherStation(bytes32 stationId, string calldata location) external;
    function removeWeatherStation(bytes32 stationId) external;
    function getStationLocation(bytes32 stationId) external view returns (string memory);
    function isStationActive(bytes32 stationId) external view returns (bool);
    
    // Data Validation
    function validateWeatherData(WeatherData calldata data) external pure returns (bool);
    function validateClimateData(ClimateData calldata data) external pure returns (bool);
    function getDataQualityScore(bytes32 stationId) external view returns (uint256);
}

/**
 * @title IVerificationOracle
 * @dev Interface for carbon credit project verification status
 */
interface IVerificationOracle {
    
    enum VerificationStatus {
        PENDING,
        VERIFIED,
        REJECTED,
        SUSPENDED,
        EXPIRED,
        REVOKED
    }
    
    enum VerificationStandard {
        VCS,           // Verified Carbon Standard
        GOLD_STANDARD, // Gold Standard
        CDM,           // Clean Development Mechanism
        CAR,           // Climate Action Reserve
        ACR,           // American Carbon Registry
        CUSTOM
    }
    
    struct VerificationData {
        VerificationStatus status;
        VerificationStandard standard;
        bytes32 projectId;
        bytes32 verifierId;
        uint256 verificationDate;
        uint256 expiryDate;
        uint256 creditAmount;
        bytes32 documentHash;
        uint256 confidence;
        string metadata;
    }
    
    // Events
    event VerificationUpdated(bytes32 indexed projectId, VerificationStatus status, uint256 timestamp);
    event VerifierAdded(bytes32 indexed verifierId, string name);
    event VerifierRemoved(bytes32 indexed verifierId);
    event DocumentUploaded(bytes32 indexed projectId, bytes32 documentHash);
    
    // Verification Functions
    function updateVerificationStatus(bytes32 projectId, VerificationData calldata data) external;
    function getVerificationStatus(bytes32 projectId) external view returns (VerificationStatus);
    function getVerificationData(bytes32 projectId) external view returns (VerificationData memory);
    function isProjectVerified(bytes32 projectId) external view returns (bool);
    function isVerificationValid(bytes32 projectId) external view returns (bool);
    
    // Verifier Management
    function addVerifier(bytes32 verifierId, string calldata name, VerificationStandard standard) external;
    function removeVerifier(bytes32 verifierId) external;
    function isVerifierAuthorized(bytes32 verifierId) external view returns (bool);
    function getVerifierInfo(bytes32 verifierId) external view returns (
        string memory name, 
        VerificationStandard standard
    );
    
    // Document Management
    function uploadDocument(bytes32 projectId, bytes32 documentHash, string calldata documentType) external;
    function verifyDocument(bytes32 projectId, bytes32 documentHash) external view returns (bool);
    function getProjectDocuments(bytes32 projectId) external view returns (bytes32[] memory);
    
    // Batch Operations
    function batchUpdateVerification(bytes32[] calldata projectIds, VerificationData[] calldata data) external;
    function getVerificationHistory(
        bytes32 projectId, 
        uint256 fromTimestamp, 
        uint256 toTimestamp
    ) external view returns (VerificationData[] memory);
}

/**
 * @title IPriceFeedOracle
 * @dev Interface for carbon credit price feeds from external markets
 */
interface IPriceFeedOracle {
    
    struct PriceData {
        uint256 price;          // Price in wei (18 decimals)
        uint256 timestamp;      // Price timestamp
        uint256 volume;         // Trading volume in 24h
        uint256 marketCap;      // Market capitalization
        uint256 confidence;     // Price confidence (0-100)
        bytes32 marketId;       // Market identifier
    }
    
    struct MarketInfo {
        string name;            // Market name
        string symbol;          // Market symbol
        bool isActive;          // Market status
        uint256 weight;         // Weight in aggregation
        address dataSource;     // Data source address
    }
    
    // Events
    event PriceUpdated(bytes32 indexed pair, uint256 price, uint256 timestamp);
    event MarketAdded(bytes32 indexed marketId, string name);
    event MarketRemoved(bytes32 indexed marketId);
    event PriceThresholdExceeded(bytes32 indexed pair, uint256 price, uint256 threshold);
    
    // Price Feed Functions
    function updatePrice(bytes32 pair, PriceData calldata data) external;
    function getLatestPrice(bytes32 pair) external view returns (uint256 price, uint256 timestamp);
    function getPriceData(bytes32 pair) external view returns (PriceData memory);
    function getAggregatedPrice(bytes32 pair) external view returns (uint256 price, uint256 confidence);
    
    // Historical Data
    function getPriceHistory(
        bytes32 pair, 
        uint256 fromTimestamp, 
        uint256 toTimestamp
    ) external view returns (PriceData[] memory);
    function getTimeWeightedPrice(bytes32 pair, uint256 period) external view returns (uint256);
    function getPriceChange(bytes32 pair, uint256 period) external view returns (int256);
    
    // Market Management
    function addMarket(bytes32 marketId, MarketInfo calldata info) external;
    function removeMarket(bytes32 marketId) external;
    function updateMarketWeight(bytes32 marketId, uint256 weight) external;
    function getMarketInfo(bytes32 marketId) external view returns (MarketInfo memory);
    
    // Data Validation
    function isPriceFresh(bytes32 pair, uint256 maxAge) external view returns (bool);
    function validatePriceData(PriceData calldata data) external pure returns (bool);
    function getPriceDeviation(bytes32 pair) external view returns (uint256);
    
    // Circuit Breaker
    function setPriceThreshold(bytes32 pair, uint256 threshold) external;
    function isPriceThresholdExceeded(bytes32 pair) external view returns (bool);
    function emergencyPause(bytes32 pair) external;
    function emergencyUnpause(bytes32 pair) external;
}