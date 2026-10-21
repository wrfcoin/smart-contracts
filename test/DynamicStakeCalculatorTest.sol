// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/DynamicStakeCalculator.sol";

/**
 * @title DynamicStakeCalculatorTest
 * @dev Test contract that exposes DynamicStakeCalculator library functions for testing
 */
contract DynamicStakeCalculatorTest {
    using DynamicStakeCalculator for DynamicStakeCalculator.StakeParameters;
    
    function getPrecision() external pure returns (uint256) {
        return DynamicStakeCalculator.getPrecision();
    }
    
    function getBaseStake() external pure returns (uint256) {
        return DynamicStakeCalculator.getBaseStake();
    }
    
    function getMinimumFloor() external pure returns (uint256) {
        return DynamicStakeCalculator.getMinimumFloor();
    }
    
    function getMaxSocialDiscount() external pure returns (uint256) {
        return DynamicStakeCalculator.getMaxSocialDiscount();
    }
    
    function getDensityRadius() external pure returns (uint256) {
        return DynamicStakeCalculator.getDensityRadius();
    }
    
    function getParticipationMultiplier(
        DynamicStakeCalculator.ParticipationType participationType,
        DynamicStakeCalculator.HybridServices memory hybridServices
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.getParticipationMultiplier(participationType, hybridServices);
    }
    
    function getGeographicMultiplier(
        DynamicStakeCalculator.GeographicZone zone
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.getGeographicMultiplier(zone);
    }
    
    function getNetworkDensityMultiplier(
        DynamicStakeCalculator.NetworkDensity memory density
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.getNetworkDensityMultiplier(density);
    }
    
    function getVerificationDiscount(
        DynamicStakeCalculator.VerificationLevel level
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.getVerificationDiscount(level);
    }
    
    function getSocialDiscount(
        DynamicStakeCalculator.SocialVerification memory social
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.getSocialDiscount(social);
    }
    
    function calculateRequiredStake(
        DynamicStakeCalculator.StakeParameters memory params
    ) external pure returns (DynamicStakeCalculator.StakeCalculationResult memory) {
        return DynamicStakeCalculator.calculateRequiredStake(params);
    }
    
    function calculateBasicStake(
        DynamicStakeCalculator.ParticipationType participationType,
        DynamicStakeCalculator.GeographicZone geographicZone,
        DynamicStakeCalculator.VerificationLevel verificationLevel
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.calculateBasicStake(participationType, geographicZone, verificationLevel);
    }
    
    function convertToAsset(
        uint256 usdAmount,
        uint256 assetPriceUSD,
        uint8 assetDecimals
    ) external pure returns (uint256) {
        return DynamicStakeCalculator.convertToAsset(usdAmount, assetPriceUSD, assetDecimals);
    }
    
    function getMultiAssetStakeAmounts(
        uint256 usdAmount,
        uint256 ethPriceUSD,
        uint256 wbtcPriceUSD,
        uint256 wrfPriceUSD,
        uint256 usdcPriceUSD,
        uint256 usdtPriceUSD
    ) external pure returns (
        uint256 ethAmount,
        uint256 wbtcAmount,
        uint256 wrfAmount,
        uint256 usdcAmount,
        uint256 usdtAmount
    ) {
        return DynamicStakeCalculator.getMultiAssetStakeAmounts(
            usdAmount,
            ethPriceUSD,
            wbtcPriceUSD,
            wrfPriceUSD,
            usdcPriceUSD,
            usdtPriceUSD
        );
    }
    
    function validateStakeParameters(
        DynamicStakeCalculator.StakeParameters memory params
    ) external pure returns (bool, string memory) {
        return DynamicStakeCalculator.validateStakeParameters(params);
    }
    
    function validateStakeSecurity(
        uint256 stakeUSD
    ) external pure returns (bool, string memory) {
        return DynamicStakeCalculator.validateStakeSecurity(stakeUSD);
    }
}