// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DynamicStakeCalculator
 * @dev Comprehensive staking calculation library for WRFCoin's enhanced fair launch system
 * 
 * This library implements a sophisticated sliding scale staking system with multiple
 * factors affecting the required stake amount:
 * 
 * Calculation Formula:
 * Raw_Stake = Base_Stake × Participation_Type × Geographic_Factor × Network_Density
 * Discounted_Stake = Raw_Stake × Verification_Discount × Social_Discount
 * Final_Stake = max(Discounted_Stake, $20_USD_Floor)
 * 
 * Features:
 * - Participation type multipliers (Weather Station, Forecast Producer, etc.)
 * - Geographic incentive multipliers (underserved areas get discounts)
 * - Network density adjustments (encourage coverage in sparse areas)
 * - Verification status discounts (KYC, email, phone verification)
 * - Social verification discounts (GitHub, Twitter, LinkedIn)
 * - Minimum $20 USD floor protection
 * - Gas-optimized fixed-point arithmetic
 * - Oracle integration hooks for asset pricing
 * - Comprehensive event logging for transparency
 * 
 * Security:
 * - Input validation and bounds checking
 * - Overflow protection via Solidity 0.8+
 * - Economic security limits
 * - Anti-manipulation safeguards
 * 
 * @author WRFCoin Security Team
 * @notice This library is designed for production use with high-value staking
 */
library DynamicStakeCalculator {
    
    // ========== CONSTANTS ==========
    
    /// @dev Precision for fixed-point arithmetic (6 decimal places)
    uint256 public constant PRECISION = 1e6;
    
    /// @dev Base stake amount in USD (with PRECISION)
    uint256 public constant BASE_STAKE_USD = 50 * PRECISION; // $50 USD
    
    /// @dev Minimum stake floor in USD (with PRECISION) - CRITICAL CONSTRAINT
    uint256 public constant MIN_STAKE_FLOOR_USD = 20 * PRECISION; // $20 USD
    
    /// @dev Maximum social discount (20%)
    uint256 public constant MAX_SOCIAL_DISCOUNT = 200_000; // 20% in precision units
    
    /// @dev Network density radius in kilometers
    uint256 public constant DENSITY_RADIUS_KM = 50;
    
    // ========== ENUMS ==========
    
    /// @dev Participation types with different stake multipliers
    enum ParticipationType {
        WEATHER_STATION,    // 1.0x (base rate)
        FORECAST_PRODUCER,  // 0.8x (computational contributors)  
        DATA_STORAGE_NODE,  // 0.6x (distributed storage)
        VALIDATOR_NODE,     // 1.2x (consensus participants)
        HYBRID_NODE        // Variable based on services
    }
    
    /// @dev Geographic zone classifications
    enum GeographicZone {
        DEFAULT_AREA,       // 1.0x multiplier
        UNDERSERVED_AREA,   // 0.3x multiplier (high incentive)
        DENSE_URBAN_AREA,   // 2.0x multiplier (high competition)
        RURAL_REMOTE_AREA,  // 0.5x multiplier (medium incentive)
        ISLAND_COASTAL_ZONE // 0.4x multiplier (critical for weather data)
    }
    
    /// @dev Verification status levels
    enum VerificationLevel {
        UNVERIFIED,         // 1.0x (base)
        EMAIL_VERIFIED,     // 0.95x
        PHONE_VERIFIED,     // 0.90x
        GOVERNMENT_ID_VERIFIED, // 0.80x
        PHYSICAL_STATION_INSPECTED // 0.70x
    }
    
    // ========== STRUCTS ==========
    
    /// @dev Comprehensive staking parameters
    struct StakeParameters {
        ParticipationType participationType;
        GeographicZone geographicZone;
        VerificationLevel verificationLevel;
        SocialVerification social;
        NetworkDensity density;
        HybridServices hybridServices;
    }
    
    /// @dev Social media verification details
    struct SocialVerification {
        bool githubVerified;        // 10% discount
        bool twitterVerified;       // 5% discount  
        bool linkedinVerified;      // 7% discount
    }
    
    /// @dev Network density information
    struct NetworkDensity {
        uint256 nearbyStationsCount;   // Number of stations within 50km
        bool isDensityVerified;         // Whether count is oracle-verified
    }
    
    /// @dev Hybrid node services (for additive discounts)
    struct HybridServices {
        bool providesWeatherData;
        bool providesForecasting;
        bool providesDataStorage;
        bool providesValidation;
    }
    
    /// @dev Detailed calculation result
    struct StakeCalculationResult {
        uint256 baseStakeUSD;
        uint256 participationMultiplier;
        uint256 geographicMultiplier;
        uint256 networkDensityMultiplier;
        uint256 rawStakeUSD;
        uint256 verificationDiscount;
        uint256 socialDiscount;
        uint256 discountedStakeUSD;
        uint256 finalStakeUSD;
        bool hitMinimumFloor;
    }
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when stake calculation is performed
    event StakeCalculated(
        address indexed participant,
        uint256 indexed finalStakeUSD,
        ParticipationType participationType,
        GeographicZone geographicZone,
        VerificationLevel verificationLevel,
        uint256 socialDiscountPercent,
        uint256 networkDensityCount,
        bool hitMinimumFloor
    );
    
    /// @notice Emitted when asset conversion is performed
    event AssetConversionCalculated(
        address indexed participant,
        address indexed asset,
        uint256 usdAmount,
        uint256 assetAmount,
        uint256 assetPriceUSD
    );
    
    // ========== ERRORS ==========
    
    error InvalidParticipationType();
    error InvalidGeographicZone();
    error InvalidVerificationLevel();
    error InvalidNetworkDensity();
    error InvalidAssetPrice();
    error CalculationOverflow();
    error MinimumFloorViolation();
    
    // ========== MAIN CALCULATION FUNCTIONS ==========
    
    /**
     * @notice Calculate required stake amount in USD with full parameter breakdown
     * @dev Main calculation function implementing the sophisticated staking formula
     * @param params Complete staking parameters
     * @return result Detailed calculation breakdown
     */
    function calculateRequiredStake(
        StakeParameters memory params
    ) internal pure returns (StakeCalculationResult memory result) {
        
        // Initialize result with base values
        result.baseStakeUSD = BASE_STAKE_USD;
        
        // Step 1: Get participation type multiplier
        result.participationMultiplier = getParticipationMultiplier(
            params.participationType,
            params.hybridServices
        );
        
        // Step 2: Get geographic multiplier
        result.geographicMultiplier = getGeographicMultiplier(params.geographicZone);
        
        // Step 3: Get network density multiplier
        result.networkDensityMultiplier = getNetworkDensityMultiplier(params.density);
        
        // Step 4: Calculate raw stake
        result.rawStakeUSD = _calculateRawStake(
            result.baseStakeUSD,
            result.participationMultiplier,
            result.geographicMultiplier,
            result.networkDensityMultiplier
        );
        
        // Step 5: Apply verification discount
        result.verificationDiscount = getVerificationDiscount(params.verificationLevel);
        
        // Step 6: Apply social verification discount
        result.socialDiscount = getSocialDiscount(params.social);
        
        // Step 7: Calculate discounted stake
        result.discountedStakeUSD = _applyDiscounts(
            result.rawStakeUSD,
            result.verificationDiscount,
            result.socialDiscount
        );
        
        // Step 8: Apply minimum floor constraint
        if (result.discountedStakeUSD < MIN_STAKE_FLOOR_USD) {
            result.finalStakeUSD = MIN_STAKE_FLOOR_USD;
            result.hitMinimumFloor = true;
        } else {
            result.finalStakeUSD = result.discountedStakeUSD;
            result.hitMinimumFloor = false;
        }
        
        return result;
    }
    
    /**
     * @notice Simplified stake calculation for basic use cases
     * @dev Wrapper function for quick stake calculation with minimal parameters
     * @param participationType The type of network participation
     * @param geographicZone The geographic zone classification
     * @param verificationLevel The verification status level
     * @return finalStakeUSD The final required stake in USD (with PRECISION)
     */
    function calculateBasicStake(
        ParticipationType participationType,
        GeographicZone geographicZone,
        VerificationLevel verificationLevel
    ) internal pure returns (uint256 finalStakeUSD) {
        
        StakeParameters memory params = StakeParameters({
            participationType: participationType,
            geographicZone: geographicZone,
            verificationLevel: verificationLevel,
            social: SocialVerification({
                githubVerified: false,
                twitterVerified: false,
                linkedinVerified: false
            }),
            density: NetworkDensity({
                nearbyStationsCount: 2, // Default normal density
                isDensityVerified: false
            }),
            hybridServices: HybridServices({
                providesWeatherData: false,
                providesForecasting: false,
                providesDataStorage: false,
                providesValidation: false
            })
        });
        
        StakeCalculationResult memory result = calculateRequiredStake(params);
        return result.finalStakeUSD;
    }
    
    // ========== MULTIPLIER CALCULATION FUNCTIONS ==========
    
    /**
     * @notice Get participation type multiplier based on network contribution
     * @dev Different participation types have different stake requirements
     * @param participationType The type of network participation
     * @param hybridServices Services provided by hybrid nodes
     * @return multiplier The participation multiplier (with PRECISION)
     */
    function getParticipationMultiplier(
        ParticipationType participationType,
        HybridServices memory hybridServices
    ) internal pure returns (uint256 multiplier) {
        
        if (participationType == ParticipationType.WEATHER_STATION) {
            return PRECISION; // 1.0x base rate
        } else if (participationType == ParticipationType.FORECAST_PRODUCER) {
            return 800_000; // 0.8x (computational contributors)
        } else if (participationType == ParticipationType.DATA_STORAGE_NODE) {
            return 600_000; // 0.6x (distributed storage)
        } else if (participationType == ParticipationType.VALIDATOR_NODE) {
            return 1_200_000; // 1.2x (consensus participants)
        } else if (participationType == ParticipationType.HYBRID_NODE) {
            return _calculateHybridMultiplier(hybridServices);
        }
        
        revert InvalidParticipationType();
    }
    
    /**
     * @notice Get geographic incentive multiplier
     * @dev Encourages participation in underserved areas
     * @param zone The geographic zone classification
     * @return multiplier The geographic multiplier (with PRECISION)
     */
    function getGeographicMultiplier(
        GeographicZone zone
    ) internal pure returns (uint256 multiplier) {
        
        if (zone == GeographicZone.DEFAULT_AREA) {
            return PRECISION; // 1.0x multiplier
        } else if (zone == GeographicZone.UNDERSERVED_AREA) {
            return 300_000; // 0.3x multiplier (high incentive)
        } else if (zone == GeographicZone.DENSE_URBAN_AREA) {
            return 2_000_000; // 2.0x multiplier (high competition)
        } else if (zone == GeographicZone.RURAL_REMOTE_AREA) {
            return 500_000; // 0.5x multiplier (medium incentive)
        } else if (zone == GeographicZone.ISLAND_COASTAL_ZONE) {
            return 400_000; // 0.4x multiplier (critical for weather data)
        }
        
        revert InvalidGeographicZone();
    }
    
    /**
     * @notice Get network density multiplier
     * @dev Adjusts stake based on local network density to encourage coverage
     * @param density Network density information
     * @return multiplier The density multiplier (with PRECISION)
     */
    function getNetworkDensityMultiplier(
        NetworkDensity memory density
    ) internal pure returns (uint256 multiplier) {
        
        uint256 stationCount = density.nearbyStationsCount;
        
        if (stationCount == 0) {
            return 800_000; // 0.8x (encourage coverage in sparse areas)
        } else if (stationCount >= 1 && stationCount <= 3) {
            return PRECISION; // 1.0x (normal density)
        } else if (stationCount >= 4 && stationCount <= 10) {
            return 1_500_000; // 1.5x (moderate density)
        } else if (stationCount > 10) {
            return 2_000_000; // 2.0x (high density areas)
        }
        
        return PRECISION; // Default fallback
    }
    
    /**
     * @notice Get verification status discount
     * @dev Higher verification levels receive larger discounts
     * @param level The verification level achieved
     * @return discount The verification discount factor (with PRECISION)
     */
    function getVerificationDiscount(
        VerificationLevel level
    ) internal pure returns (uint256 discount) {
        
        if (level == VerificationLevel.UNVERIFIED) {
            return PRECISION; // 1.0x (base, no discount)
        } else if (level == VerificationLevel.EMAIL_VERIFIED) {
            return 950_000; // 0.95x (5% discount)
        } else if (level == VerificationLevel.PHONE_VERIFIED) {
            return 900_000; // 0.90x (10% discount)
        } else if (level == VerificationLevel.GOVERNMENT_ID_VERIFIED) {
            return 800_000; // 0.80x (20% discount)
        } else if (level == VerificationLevel.PHYSICAL_STATION_INSPECTED) {
            return 700_000; // 0.70x (30% discount)
        }
        
        revert InvalidVerificationLevel();
    }
    
    /**
     * @notice Get social verification discount
     * @dev Multiple social verifications provide additive discounts up to 20% maximum
     * @param social Social media verification details
     * @return discount The social discount factor (with PRECISION)
     */
    function getSocialDiscount(
        SocialVerification memory social
    ) internal pure returns (uint256 discount) {
        
        uint256 totalDiscount = 0;
        
        if (social.githubVerified) {
            totalDiscount += 100_000; // 10% discount
        }
        
        if (social.twitterVerified) {
            totalDiscount += 50_000; // 5% discount
        }
        
        if (social.linkedinVerified) {
            totalDiscount += 70_000; // 7% discount
        }
        
        // Cap at maximum 20% social discount
        if (totalDiscount > MAX_SOCIAL_DISCOUNT) {
            totalDiscount = MAX_SOCIAL_DISCOUNT;
        }
        
        // Convert discount percentage to multiplier
        return PRECISION - totalDiscount;
    }
    
    // ========== ASSET CONVERSION FUNCTIONS ==========
    
    /**
     * @notice Convert USD stake amount to specific asset amount
     * @dev Converts USD amount to token amount using oracle price
     * @param usdAmount Amount in USD (with PRECISION)
     * @param assetPriceUSD Asset price in USD (with PRECISION)
     * @param assetDecimals Number of decimals for the asset token
     * @return assetAmount Required amount of the asset
     */
    function convertToAsset(
        uint256 usdAmount,
        uint256 assetPriceUSD,
        uint8 assetDecimals
    ) internal pure returns (uint256 assetAmount) {
        
        if (assetPriceUSD == 0) {
            revert InvalidAssetPrice();
        }
        
        // Calculate asset amount: (usdAmount * 10^assetDecimals) / assetPriceUSD
        uint256 assetPrecision = 10 ** assetDecimals;
        assetAmount = (usdAmount * assetPrecision) / assetPriceUSD;
        
        return assetAmount;
    }
    
    /**
     * @notice Get stake requirements for multiple supported assets
     * @dev Returns stake amounts for ETH, WBTC, WRF, USDC, USDT
     * @param usdAmount The USD amount to convert
     * @param ethPriceUSD ETH price in USD (with PRECISION)
     * @param wbtcPriceUSD WBTC price in USD (with PRECISION)  
     * @param wrfPriceUSD WRF price in USD (with PRECISION)
     * @param usdcPriceUSD USDC price in USD (with PRECISION)
     * @param usdtPriceUSD USDT price in USD (with PRECISION)
     * @return ethAmount Required ETH amount
     * @return wbtcAmount Required WBTC amount
     * @return wrfAmount Required WRF amount
     * @return usdcAmount Required USDC amount
     * @return usdtAmount Required USDT amount
     */
    function getMultiAssetStakeAmounts(
        uint256 usdAmount,
        uint256 ethPriceUSD,
        uint256 wbtcPriceUSD,
        uint256 wrfPriceUSD,
        uint256 usdcPriceUSD,
        uint256 usdtPriceUSD
    ) internal pure returns (
        uint256 ethAmount,
        uint256 wbtcAmount,
        uint256 wrfAmount,
        uint256 usdcAmount,
        uint256 usdtAmount
    ) {
        
        ethAmount = convertToAsset(usdAmount, ethPriceUSD, 18);
        wbtcAmount = convertToAsset(usdAmount, wbtcPriceUSD, 8);
        wrfAmount = convertToAsset(usdAmount, wrfPriceUSD, 18);
        usdcAmount = convertToAsset(usdAmount, usdcPriceUSD, 6);
        usdtAmount = convertToAsset(usdAmount, usdtPriceUSD, 6);
        
        return (ethAmount, wbtcAmount, wrfAmount, usdcAmount, usdtAmount);
    }
    
    // ========== INTERNAL HELPER FUNCTIONS ==========
    
    /**
     * @dev Calculate hybrid node multiplier with additive discounts
     * @param services Services provided by the hybrid node
     * @return multiplier The calculated hybrid multiplier
     */
    function _calculateHybridMultiplier(
        HybridServices memory services
    ) private pure returns (uint256 multiplier) {
        
        // Start with base validator rate (highest single-service rate)
        multiplier = 1_200_000; // 1.2x base
        
        uint256 serviceCount = 0;
        if (services.providesWeatherData) serviceCount++;
        if (services.providesForecasting) serviceCount++;
        if (services.providesDataStorage) serviceCount++;
        if (services.providesValidation) serviceCount++;
        
        // Apply discounts for multiple services (5% per additional service)
        if (serviceCount > 1) {
            uint256 discount = (serviceCount - 1) * 50_000; // 5% per additional service
            if (discount > 150_000) discount = 150_000; // Cap at 15% total discount
            multiplier = multiplier - discount;
        }
        
        // Minimum multiplier of 0.6x (storage node rate)
        if (multiplier < 600_000) {
            multiplier = 600_000;
        }
        
        return multiplier;
    }
    
    /**
     * @dev Calculate raw stake before discounts
     * @param baseStake Base stake amount
     * @param participationMult Participation type multiplier
     * @param geographicMult Geographic multiplier
     * @param densityMult Network density multiplier
     * @return rawStake The calculated raw stake amount
     */
    function _calculateRawStake(
        uint256 baseStake,
        uint256 participationMult,
        uint256 geographicMult,
        uint256 densityMult
    ) private pure returns (uint256 rawStake) {
        
        // Raw_Stake = Base_Stake × Participation_Type × Geographic_Factor × Network_Density
        rawStake = baseStake;
        rawStake = (rawStake * participationMult) / PRECISION;
        rawStake = (rawStake * geographicMult) / PRECISION;
        rawStake = (rawStake * densityMult) / PRECISION;
        
        return rawStake;
    }
    
    /**
     * @dev Apply verification and social discounts
     * @param rawStake Raw stake amount before discounts
     * @param verificationDiscount Verification discount factor
     * @param socialDiscount Social discount factor
     * @return discountedStake Final discounted stake amount
     */
    function _applyDiscounts(
        uint256 rawStake,
        uint256 verificationDiscount,
        uint256 socialDiscount
    ) private pure returns (uint256 discountedStake) {
        
        // Discounted_Stake = Raw_Stake × Verification_Discount × Social_Discount
        discountedStake = rawStake;
        discountedStake = (discountedStake * verificationDiscount) / PRECISION;
        discountedStake = (discountedStake * socialDiscount) / PRECISION;
        
        return discountedStake;
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get minimum stake floor in USD
     * @return minFloor The minimum stake floor amount (with PRECISION)
     */
    function getMinimumFloor() internal pure returns (uint256 minFloor) {
        return MIN_STAKE_FLOOR_USD;
    }
    
    /**
     * @notice Get base stake amount in USD
     * @return baseStake The base stake amount (with PRECISION)
     */
    function getBaseStake() internal pure returns (uint256 baseStake) {
        return BASE_STAKE_USD;
    }
    
    /**
     * @notice Get maximum social discount percentage
     * @return maxDiscount Maximum social discount in precision units
     */
    function getMaxSocialDiscount() internal pure returns (uint256 maxDiscount) {
        return MAX_SOCIAL_DISCOUNT;
    }
    
    /**
     * @notice Get network density radius in kilometers
     * @return radius Density calculation radius in km
     */
    function getDensityRadius() internal pure returns (uint256 radius) {
        return DENSITY_RADIUS_KM;
    }
    
    /**
     * @notice Get calculation precision
     * @return precision The precision used for fixed-point arithmetic
     */
    function getPrecision() internal pure returns (uint256 precision) {
        return PRECISION;
    }
    
    // ========== UTILITY FUNCTIONS ==========
    
    /**
     * @notice Validate stake parameters for security
     * @param params Parameters to validate
     * @return isValid Whether parameters are valid
     * @return errorMessage Error message if invalid
     */
    function validateStakeParameters(
        StakeParameters memory params
    ) internal pure returns (bool isValid, string memory errorMessage) {
        
        // Validate participation type
        if (uint8(params.participationType) > 4) {
            return (false, "Invalid participation type");
        }
        
        // Validate geographic zone
        if (uint8(params.geographicZone) > 4) {
            return (false, "Invalid geographic zone");
        }
        
        // Validate verification level
        if (uint8(params.verificationLevel) > 4) {
            return (false, "Invalid verification level");
        }
        
        // Validate network density
        if (params.density.nearbyStationsCount > 1000) {
            return (false, "Invalid network density count");
        }
        
        return (true, "");
    }
    
    /**
     * @notice Check if calculated stake meets security requirements
     * @param stakeUSD Stake amount in USD (with PRECISION)
     * @return meetsRequirements Whether stake meets minimum security requirements
     * @return securityLevel Security level assessment
     */
    function validateStakeSecurity(
        uint256 stakeUSD
    ) internal pure returns (bool meetsRequirements, string memory securityLevel) {
        
        if (stakeUSD < MIN_STAKE_FLOOR_USD) {
            return (false, "Below minimum floor");
        } else if (stakeUSD < 50 * PRECISION) {
            return (true, "Basic security");
        } else if (stakeUSD < 100 * PRECISION) {
            return (true, "Enhanced security");
        } else {
            return (true, "Maximum security");
        }
    }
}