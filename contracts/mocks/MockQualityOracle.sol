// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockQualityOracle
 * @dev Simplified mock implementation for testing platform integration
 * Only implements the minimal interface needed for testing
 */
abstract contract MockQualityOracle {
    mapping(address => uint256) private qualityScores;
    mapping(address => uint256) private qualityTiers;
    mapping(address => bool) private verifiedSources;

    event QualityScoreUpdated(address indexed carbonBasket, uint256 score);
    event QualityTierUpdated(address indexed carbonBasket, uint256 tier);

    function setQualityScore(address carbonBasket, uint256 score) external {
        require(score <= 100, "MockQualityOracle: Score must be <= 100");
        qualityScores[carbonBasket] = score;
        
        // Auto-determine tier based on score
        uint256 tier;
        if (score >= 90) {
            tier = 1; // Premium
        } else if (score >= 75) {
            tier = 2; // High
        } else if (score >= 50) {
            tier = 3; // Standard
        } else if (score >= 25) {
            tier = 4; // Basic
        } else {
            tier = 5; // Low
        }
        
        qualityTiers[carbonBasket] = tier;
        verifiedSources[carbonBasket] = true;

        emit QualityScoreUpdated(carbonBasket, score);
        emit QualityTierUpdated(carbonBasket, tier);
    }

    function getQualityScore(address carbonBasket) external view returns (uint256) {
        return qualityScores[carbonBasket];
    }

    function getQualityTier(address carbonBasket) external view returns (uint256) {
        uint256 tier = qualityTiers[carbonBasket];
        return tier == 0 ? 3 : tier; // Default to Standard tier
    }

    function isVerifiedSource(address carbonBasket) external view returns (bool) {
        return verifiedSources[carbonBasket];
    }

    function updateQualityData(
        address carbonBasket,
        uint256 score,
        uint256 tier,
        bool verified
    ) external {
        require(score <= 100, "MockQualityOracle: Score must be <= 100");
        require(tier >= 1 && tier <= 5, "MockQualityOracle: Invalid tier");

        qualityScores[carbonBasket] = score;
        qualityTiers[carbonBasket] = tier;
        verifiedSources[carbonBasket] = verified;

        emit QualityScoreUpdated(carbonBasket, score);
        emit QualityTierUpdated(carbonBasket, tier);
    }
}