// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IMultiAssetStaking.sol";
import "../interfaces/IParticipantTypeRegistry.sol";
import "../interfaces/IDynamicStakeCalculator.sol";
import "../libraries/DynamicStakeCalculator.sol";

/**
 * @title TestMultiAssetStaking
 * @dev Concrete mock of IMultiAssetStaking for testing StakeDelegation
 */
contract TestMultiAssetStaking is IMultiAssetStaking {
    mapping(address => uint256) private _totalStakes;

    function stakeAsset(
        address,
        uint256 amount,
        DynamicStakeCalculator.StakeParameters calldata
    ) external payable override {
        _totalStakes[msg.sender] += amount;
    }

    function getStakeValueUSD(address participant)
        external
        view
        override
        returns (uint256, uint256[] memory, address[] memory)
    {
        uint256[] memory breakdown = new uint256[](0);
        address[] memory assets = new address[](0);
        return (_totalStakes[participant], breakdown, assets);
    }

    function rebalanceStake(address, address, address, uint256) external override {}
    function withdrawStake(address, uint256) external override {}
    function convertStakeAsset(address, address, uint256) external override {}

    function getCollateralizationRatio(address)
        external
        pure
        override
        returns (uint256, bool, uint256, uint256)
    {
        return (10000, true, 0, 0);
    }

    function completeCrossChainDeposit(bytes32, address, address, uint256) external override {}
    function completeCrossChainWithdrawal(bytes32, bool, string calldata) external override {}

    function getComprehensiveStakeInfo(address)
        external
        pure
        override
        returns (uint256, uint256, uint256, bool, address[] memory, uint256[] memory, uint256[] memory)
    {
        address[] memory a = new address[](0);
        uint256[] memory b = new uint256[](0);
        uint256[] memory c = new uint256[](0);
        return (0, 0, 10000, true, a, b, c);
    }

    function getSupportedAssets()
        external
        pure
        override
        returns (address[] memory, AssetConfig[] memory)
    {
        address[] memory a = new address[](0);
        AssetConfig[] memory c = new AssetConfig[](0);
        return (a, c);
    }

    function getAssetPrice(address)
        external
        view
        override
        returns (uint256, uint256, bool)
    {
        return (1e18, block.timestamp, false);
    }

    function configureAsset(address, AssetConfig calldata) external override {}
    function removeAssetSupport(address) external override {}
    function emergencyLiquidation(address, address, uint256, string calldata) external override {}
    function slashStake(address, uint256) external override {}

    function getTotalStake(address participant) external view override returns (uint256) {
        return _totalStakes[participant];
    }
}

/**
 * @title TestParticipantTypeRegistry
 * @dev Concrete mock of IParticipantTypeRegistry for testing StakeDelegation
 */
contract TestParticipantTypeRegistry is IParticipantTypeRegistry {
    mapping(address => bool) private _isActive;
    mapping(address => uint256) private _requiredStake;

    function getParticipantInfo(address)
        external
        pure
        override
        returns (bool, bool, bool)
    {
        return (false, true, false);
    }

    function getParticipantDetails(address)
        external
        pure
        override
        returns (uint256, uint256, uint256)
    {
        return (1, 100, 1);
    }

    function updateParticipantStatus(address participant, bool status) external override {
        _isActive[participant] = status;
    }

    function getRequiredStakeAmount(address) external pure override returns (uint256) {
        return 1000e18;
    }
}

/**
 * @title TestDynamicStakeCalculator
 * @dev Concrete mock of IDynamicStakeCalculator for testing StakeDelegation
 */
contract TestDynamicStakeCalculator is IDynamicStakeCalculator {
    function calculateRequiredStake(address) external pure override returns (uint256) {
        return 1000e18;
    }

    function calculateAdjustedStake(address, uint256) external pure override returns (uint256) {
        return 1000e18;
    }

    function getStakeBounds() external pure override returns (uint256, uint256) {
        return (100e18, 10000e18);
    }
}
