// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/DynamicStakeCalculator.sol";

/**
 * @title IMultiAssetStaking
 * @notice Interface for the MultiAssetStaking contract
 * @dev Defines the core functions for multi-asset staking operations
 */
interface IMultiAssetStaking {
    
    // ========== STRUCTS ==========
    
    /// @dev Asset configuration for staking
    struct AssetConfig {
        address tokenAddress;
        address priceOracle;
        uint8 decimals;
        bool isActive;
        bool isCrossChain;
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        uint256 concentrationLimit;
        string symbol;
        bytes32 bridgeId;
    }

    /// @dev Individual asset stake information
    struct AssetStake {
        uint256 amount;
        uint256 valueUSD;
        uint256 lastPriceUpdate;
        uint256 stakedAt;
        bool isActive;
        uint256 pendingWithdrawal;
        bytes32 lastBridgeOperation;
    }

    // ========== EVENTS ==========

    event AssetStaked(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD,
        uint256 newTotalStakeUSD
    );

    event AssetWithdrawn(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD,
        uint256 newTotalStakeUSD
    );

    event StakeRebalanced(
        address indexed participant,
        address indexed fromAsset,
        address indexed toAsset,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 newCollateralizationRatio
    );

    event CrossChainOperationInitiated(
        bytes32 indexed operationId,
        address indexed participant,
        address indexed asset,
        uint256 amount,
        bytes32 bridgeId,
        bool isDeposit
    );

    event CollateralizationRatioUpdated(
        address indexed participant,
        uint256 oldRatio,
        uint256 newRatio,
        bool meetsRequirement
    );

    // ========== MAIN FUNCTIONS ==========

    /**
     * @notice Stake an asset for weather station registration
     * @param asset Address of the asset to stake
     * @param amount Amount to stake in asset units
     * @param parameters Staking parameters for dynamic calculation
     */
    function stakeAsset(
        address asset,
        uint256 amount,
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) external payable;

    /**
     * @notice Get USD value of participant's total stake
     * @param participant Address of the participant
     * @return totalValueUSD Current total stake value in USD
     * @return breakdown Array of individual asset values
     * @return assets Array of staked asset addresses
     */
    function getStakeValueUSD(address participant) 
        external 
        view 
        returns (
            uint256 totalValueUSD,
            uint256[] memory breakdown,
            address[] memory assets
        );

    /**
     * @notice Rebalance stake if collateral value drops below requirements
     * @param participant Address of the participant to rebalance
     * @param fromAsset Asset to convert from
     * @param toAsset Asset to convert to
     * @param amount Amount to rebalance
     */
    function rebalanceStake(
        address participant, 
        address fromAsset, 
        address toAsset, 
        uint256 amount
    ) external;

    /**
     * @notice Withdraw stake after deregistration
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (0 for full withdrawal)
     */
    function withdrawStake(address asset, uint256 amount) external;

    /**
     * @notice Convert stake from one asset to another
     * @param fromAsset Source asset address
     * @param toAsset Destination asset address
     * @param amount Amount to convert from source asset
     */
    function convertStakeAsset(address fromAsset, address toAsset, uint256 amount) external;

    /**
     * @notice Get current collateralization ratio for a participant
     * @param participant Address of the participant
     * @return ratio Current collateralization ratio
     * @return meetsMinimum Whether the participant meets minimum requirements
     * @return requiredStakeUSD Required stake amount in USD
     * @return currentStakeUSD Current stake value in USD
     */
    function getCollateralizationRatio(address participant)
        external
        view
        returns (
            uint256 ratio,
            bool meetsMinimum,
            uint256 requiredStakeUSD,
            uint256 currentStakeUSD
        );

    // ========== CROSS-CHAIN FUNCTIONS ==========

    /**
     * @notice Complete a cross-chain deposit operation
     * @param operationId Cross-chain operation identifier
     * @param participant Address of the participant
     * @param asset Address of the deposited asset
     * @param amount Amount deposited
     */
    function completeCrossChainDeposit(
        bytes32 operationId,
        address participant,
        address asset,
        uint256 amount
    ) external;

    /**
     * @notice Complete a cross-chain withdrawal operation
     * @param operationId Cross-chain operation identifier
     * @param success Whether the withdrawal was successful
     * @param reason Reason if withdrawal failed
     */
    function completeCrossChainWithdrawal(
        bytes32 operationId,
        bool success,
        string calldata reason
    ) external;

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get comprehensive stake information for a participant
     * @param participant Address of the participant
     * @return totalStakeUSD Total stake value in USD
     * @return requiredStakeUSD Required stake amount in USD
     * @return collateralizationRatio Current collateralization ratio
     * @return meetsRequirement Whether stake meets minimum requirement
     * @return stakedAssets List of staked assets
     * @return assetAmounts Amount staked in each asset
     * @return assetValuesUSD USD value of each asset stake
     */
    function getComprehensiveStakeInfo(address participant)
        external
        view
        returns (
            uint256 totalStakeUSD,
            uint256 requiredStakeUSD,
            uint256 collateralizationRatio,
            bool meetsRequirement,
            address[] memory stakedAssets,
            uint256[] memory assetAmounts,
            uint256[] memory assetValuesUSD
        );

    /**
     * @notice Get list of supported assets
     * @return assets Array of supported asset addresses
     * @return configs Array of asset configurations
     */
    function getSupportedAssets() 
        external 
        view 
        returns (
            address[] memory assets,
            AssetConfig[] memory configs
        );

    /**
     * @notice Get current asset prices from oracles
     * @param asset Address of the asset
     * @return priceUSD Current price in USD
     * @return timestamp Last update timestamp
     * @return isStale Whether the price is stale
     */
    function getAssetPrice(address asset)
        external
        view
        returns (
            uint256 priceUSD,
            uint256 timestamp,
            bool isStale
        );

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Configure a supported asset
     * @param asset Address of the asset token contract
     * @param config Asset configuration parameters
     */
    function configureAsset(address asset, AssetConfig calldata config) external;

    /**
     * @notice Remove asset support
     * @param asset Address of the asset to remove
     */
    function removeAssetSupport(address asset) external;

    /**
     * @notice Emergency liquidation for undercollateralized positions
     * @param participant Address of the participant to liquidate
     * @param asset Asset to liquidate
     * @param amount Amount to liquidate
     * @param reason Reason for liquidation
     */
    function emergencyLiquidation(
        address participant,
        address asset,
        uint256 amount,
        string calldata reason
    ) external;

    // ========== SLASHING FUNCTIONS ==========

    /**
     * @notice Slash stake for violations
     * @param participant Address of the participant to slash
     * @param amount Amount to slash in USD value
     */
    function slashStake(address participant, uint256 amount) external;

    /**
     * @notice Get total stake amount for a participant
     * @param participant Address of the participant
     * @return totalStake Total stake amount
     */
    function getTotalStake(address participant) external view returns (uint256 totalStake);
}