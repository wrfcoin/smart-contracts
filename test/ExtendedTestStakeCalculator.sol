// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/DynamicStakeCalculator.sol";

/**
 * @title ExtendedTestStakeCalculator
 * @dev Extended test contract to validate all DynamicStakeCalculator multiplier combinations
 * This contract exposes more test functions to validate the full range of the library's capabilities
 */
contract ExtendedTestStakeCalculator {
    using DynamicStakeCalculator for DynamicStakeCalculator.StakeParameters;
    
    /**
     * @dev Test validator node in dense urban area with government ID verification
     * Expected: 50 * 1.2 * 2.0 * 0.8 = 96 USD
     */
    function testHighStakeScenario() external pure returns (uint256) {
        return DynamicStakeCalculator.calculateBasicStake(
            DynamicStakeCalculator.ParticipationType.VALIDATOR_NODE,      // 1.2x
            DynamicStakeCalculator.GeographicZone.DENSE_URBAN_AREA,       // 2.0x
            DynamicStakeCalculator.VerificationLevel.GOVERNMENT_ID_VERIFIED  // 0.8x (20% discount)
        );
    }
    
    /**
     * @dev Test forecast producer in rural remote area with phone verification
     * Expected: 50 * 0.8 * 0.5 * 0.9 = 18 USD -> clamped to 20 USD minimum
     */
    function testMidRangeScenario() external pure returns (uint256) {
        return DynamicStakeCalculator.calculateBasicStake(
            DynamicStakeCalculator.ParticipationType.FORECAST_PRODUCER,   // 0.8x
            DynamicStakeCalculator.GeographicZone.RURAL_REMOTE_AREA,      // 0.5x
            DynamicStakeCalculator.VerificationLevel.PHONE_VERIFIED       // 0.9x (10% discount)
        );
    }
    
    /**
     * @dev Test data storage in island coastal zone with physical inspection
     * Expected: 50 * 0.6 * 0.4 * 0.7 = 8.4 USD -> clamped to 20 USD minimum
     */
    function testLowStakeScenario() external pure returns (uint256) {
        return DynamicStakeCalculator.calculateBasicStake(
            DynamicStakeCalculator.ParticipationType.DATA_STORAGE_NODE,   // 0.6x
            DynamicStakeCalculator.GeographicZone.ISLAND_COASTAL_ZONE,    // 0.4x
            DynamicStakeCalculator.VerificationLevel.PHYSICAL_STATION_INSPECTED  // 0.7x (30% discount)
        );
    }
    
    /**
     * @dev Test unverified weather station in default area (baseline)
     * Expected: 50 * 1.0 * 1.0 * 1.0 = 50 USD
     */
    function testBaselineScenario() external pure returns (uint256) {
        return DynamicStakeCalculator.calculateBasicStake(
            DynamicStakeCalculator.ParticipationType.WEATHER_STATION,    // 1.0x
            DynamicStakeCalculator.GeographicZone.DEFAULT_AREA,          // 1.0x
            DynamicStakeCalculator.VerificationLevel.UNVERIFIED          // 1.0x (no discount)
        );
    }
    
    /**
     * @dev Test extreme underserved scenario
     * Expected: 50 * 0.6 * 0.3 * 0.95 = 8.55 USD -> clamped to 20 USD minimum
     */
    function testExtremeUnderservedScenario() external pure returns (uint256) {
        return DynamicStakeCalculator.calculateBasicStake(
            DynamicStakeCalculator.ParticipationType.DATA_STORAGE_NODE,   // 0.6x
            DynamicStakeCalculator.GeographicZone.UNDERSERVED_AREA,       // 0.3x
            DynamicStakeCalculator.VerificationLevel.EMAIL_VERIFIED       // 0.95x (5% discount)
        );
    }
}