// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IDynamicStakeCalculator.sol";

/**
 * @title MockDynamicStakeCalculator
 * @notice Mock implementation for testing LayawayRegistration
 */
contract MockDynamicStakeCalculator is IDynamicStakeCalculator {
    mapping(address => uint256) private requiredStakes;
    uint256 public minStake = 100e18; // 100 USD equivalent
    uint256 public maxStake = 10000e18; // 10,000 USD equivalent

    function setRequiredStake(address participant, uint256 stake) external {
        requiredStakes[participant] = stake;
    }

    function calculateRequiredStake(address participant)
        external
        view
        override
        returns (uint256 requiredStake)
    {
        uint256 stake = requiredStakes[participant];
        return stake > 0 ? stake : 1000e18; // Default 1000 USD
    }

    function calculateAdjustedStake(address participant, uint256 qualityScore)
        external
        view
        override
        returns (uint256 adjustedStake)
    {
        uint256 baseStake = this.calculateRequiredStake(participant);
        // Adjust stake based on quality (higher quality = lower stake)
        return baseStake * 10000 / qualityScore;
    }

    function getStakeBounds()
        external
        view
        override
        returns (uint256 minStakeReturn, uint256 maxStakeReturn)
    {
        return (minStake, maxStake);
    }
}