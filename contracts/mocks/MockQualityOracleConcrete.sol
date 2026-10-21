// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IQualityOracle.sol";

/**
 * @title MockQualityOracleConcrete
 * @dev Concrete mock for testing — implements full IQualityOracle interface with stubs
 */
contract MockQualityOracleConcrete is IQualityOracle {
    mapping(address => uint256) private _scores;

    function setQualityScore(address token, uint256 score) external {
        _scores[token] = score;
    }

    function getQualityScore(address token) external view override returns (uint256) {
        return _scores[token];
    }

    // ---- stubs for the rest of the interface ----
    function getQualityMetrics(address) external pure override returns (QualityMetrics memory m) { return m; }
    function updateQualityScore(address, uint256) external override {}
    function setDetailedQualityMetrics(address, QualityMetrics calldata) external override {}
    function meetsQualityThreshold(address) external pure override returns (bool) { return true; }
    function getQualityTier(address) external pure override returns (uint256) { return 3; }
    function getQualityPricingFactor(address) external pure override returns (uint256) { return 100; }
    function isQualityDataFresh(address, uint256) external pure override returns (bool) { return true; }
    function getQualityHistory(address, uint256, uint256) external pure override returns (QualityHistory[] memory h) { return h; }
    function compareQuality(address, address) external pure override returns (int8) { return 0; }
    function updateFromBasketToken(address, uint256, QualityMetrics calldata) external override {}
    function batchUpdateQuality(address[] calldata, uint256[] calldata) external override {}
    function setTierThresholds(uint256, uint256, uint256, uint256, uint256) external override {}
    function getTierMinimumScore(uint256) external pure override returns (uint256) { return 0; }
    function getTWAQuality(address, uint256) external pure override returns (uint256) { return 80; }
    function getRelativeQuality(address) external pure override returns (uint256) { return 100; }
    function getQualityHistoryLength(address) external pure override returns (uint256) { return 0; }
    function getQualityHistoryPoint(address, uint256) external pure override returns (QualityHistory memory h) { return h; }
}
