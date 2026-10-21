// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IDynamicStakeCalculator
 * @notice Interface for dynamic stake calculation contract
 */
interface IDynamicStakeCalculator {
    /**
     * @notice Calculate required stake for participant
     * @param participant Address of participant
     * @return requiredStake Amount of stake required in USD equivalent (wei)
     */
    function calculateRequiredStake(address participant)
        external
        view
        returns (uint256 requiredStake);

    /**
     * @notice Calculate stake with quality adjustments
     * @param participant Address of participant
     * @param qualityScore Quality score (0-10000)
     * @return adjustedStake Stake amount adjusted for quality
     */
    function calculateAdjustedStake(address participant, uint256 qualityScore)
        external
        view
        returns (uint256 adjustedStake);

    /**
     * @notice Get minimum and maximum stake bounds
     * @return minStake Minimum stake requirement
     * @return maxStake Maximum stake requirement
     */
    function getStakeBounds()
        external
        view
        returns (uint256 minStake, uint256 maxStake);
}