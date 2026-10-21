// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MockChainlinkInterface.sol";

/**
 * @title MockAggregatorV3
 * @dev Mock Chainlink aggregator for testing oracle functionality
 */
abstract contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private _decimals;
    string private _description;
    
    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }
    
    RoundData private _latestRoundData;
    mapping(uint80 => RoundData) private _rounds;
    uint80 private _latestRoundId;
    
    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
        _latestRoundId = 1;
        
        // Set initial round data
        _latestRoundData = RoundData({
            roundId: _latestRoundId,
            answer: 0,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: _latestRoundId
        });
        
        _rounds[_latestRoundId] = _latestRoundData;
    }
    
    function decimals() external view returns (uint8) {
        return _decimals;
    }
    
    function description() external view returns (string memory) {
        return _description;
    }
    
    function version() external pure returns (uint256) {
        return 1;
    }
    
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (
            _latestRoundData.roundId,
            _latestRoundData.answer,
            _latestRoundData.startedAt,
            _latestRoundData.updatedAt,
            _latestRoundData.answeredInRound
        );
    }
    
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        RoundData memory round = _rounds[_roundId];
        return (
            round.roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            round.answeredInRound
        );
    }
    
    // Test helper functions
    function setLatestAnswer(int256 answer) external {
        _latestRoundId++;
        
        _latestRoundData = RoundData({
            roundId: _latestRoundId,
            answer: answer,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: _latestRoundId
        });
        
        _rounds[_latestRoundId] = _latestRoundData;
    }
    
    function setRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt
    ) external {
        _rounds[roundId] = RoundData({
            roundId: roundId,
            answer: answer,
            startedAt: startedAt,
            updatedAt: updatedAt,
            answeredInRound: roundId
        });
        
        if (roundId > _latestRoundId) {
            _latestRoundId = roundId;
            _latestRoundData = _rounds[roundId];
        }
    }
    
    function simulateStaleData() external {
        // Set update time to 2 hours ago
        _latestRoundData.updatedAt = block.timestamp - 7200;
        _rounds[_latestRoundData.roundId] = _latestRoundData;
    }
    
    function simulateInvalidData() external {
        _latestRoundData.answer = 0;
        _latestRoundData.updatedAt = 0;
        _rounds[_latestRoundData.roundId] = _latestRoundData;
    }
}