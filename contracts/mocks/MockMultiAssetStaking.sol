// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IMultiAssetStaking.sol";

/**
 * @title MockMultiAssetStaking
 * @dev Mock implementation of MultiAssetStaking for testing BTCStakeRegistry integration
 */
abstract contract MockBTCMultiAssetStaking is IMultiAssetStaking {
    // Test tracking variables
    bytes32 public lastStationId;
    uint256 public lastStakedAmount;
    address public lastStaker;
    bool public shouldFail = false;
    bool public stakingSuccess = true;

    // Storage for mock data
    mapping(bytes32 => mapping(address => uint256)) private stakedAmounts;
    mapping(bytes32 => mapping(address => uint256)) private rewards;
    
    /**
     * @notice Mock BTC staking function
     */
    function stakeBTC(
        bytes32 stationId,
        uint256 amount,
        address staker
    ) external returns (bool success) {
        if (shouldFail) {
            revert("Mock staking failure");
        }

        // Record the staking operation for testing
        lastStationId = stationId;
        lastStakedAmount = amount;
        lastStaker = staker;

        // Update mock balances
        stakedAmounts[stationId][staker] += amount;

        return stakingSuccess;
    }

    /**
     * @notice Mock BTC unstaking function
     */
    function unstakeBTC(
        bytes32 stationId,
        uint256 amount,
        address staker
    ) external returns (bool success) {
        if (shouldFail) {
            revert("Mock unstaking failure");
        }

        require(stakedAmounts[stationId][staker] >= amount, "Insufficient staked amount");
        
        stakedAmounts[stationId][staker] -= amount;
        return true;
    }

    /**
     * @notice Get staked BTC amount
     */
    function getStakedBTC(
        bytes32 stationId,
        address staker
    ) external view returns (uint256 stakedAmount) {
        return stakedAmounts[stationId][staker];
    }

    /**
     * @notice Calculate BTC rewards (mock implementation)
     */
    function calculateBTCRewards(
        bytes32 stationId,
        address staker
    ) external view returns (uint256 rewardsAmount) {
        return rewards[stationId][staker];
    }

    // Test helper functions to control mock behavior
    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function setStakingSuccess(bool _success) external {
        stakingSuccess = _success;
    }

    function setMockRewards(
        bytes32 stationId,
        address staker,
        uint256 amount
    ) external {
        rewards[stationId][staker] = amount;
    }

    function resetTestState() external {
        lastStationId = bytes32(0);
        lastStakedAmount = 0;
        lastStaker = address(0);
        shouldFail = false;
        stakingSuccess = true;
    }
}