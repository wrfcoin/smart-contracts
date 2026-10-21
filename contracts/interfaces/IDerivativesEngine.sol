// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IDerivativesEngine
 * @dev Interface for the central derivatives trading engine
 * Manages futures, options, margin, and settlements for carbon credit derivatives
 */
interface IDerivativesEngine {
    
    enum DerivativeType {
        FUTURE,
        CALL_OPTION,
        PUT_OPTION
    }
    
    enum SettlementType {
        CASH_SETTLED,
        PHYSICALLY_SETTLED
    }
    
    enum PositionStatus {
        ACTIVE,
        LIQUIDATED,
        SETTLED,
        EXPIRED
    }
    
    struct Future {
        uint256 futureId;
        uint256 underlyingTokenId;     // EnhancedCarbonCredits tokenId
        uint256 contractSize;          // Amount of carbon credits per contract
        uint256 expiryTimestamp;
        uint256 settlementPrice;       // Set at expiry (0 if not settled)
        SettlementType settlementType;
        bool isActive;
        string description;            // "Q1-2025 VCS Forestry Futures"
    }
    
    struct Option {
        uint256 optionId;
        uint256 underlyingTokenId;     // EnhancedCarbonCredits tokenId
        uint256 contractSize;          // Amount of carbon credits per contract
        uint256 strikePrice;           // Strike price in WRF per unit
        uint256 expiryTimestamp;
        uint256 premium;               // Option premium in WRF
        DerivativeType optionType;     // CALL_OPTION or PUT_OPTION
        SettlementType settlementType;
        bool isActive;
        string description;            // "Q1-2025 VCS Forestry $25 Call"
    }
    
    struct Position {
        uint256 positionId;
        address trader;
        uint256 derivativeId;          // futureId or optionId
        DerivativeType derivativeType;
        bool isLong;                   // true = long, false = short
        uint256 quantity;              // Number of contracts
        uint256 entryPrice;            // Price when position opened
        uint256 collateralAmount;      // WRF collateral deposited
        uint256 lastMarginCall;        // Timestamp of last margin call
        PositionStatus status;
        uint256 openTimestamp;
    }
    
    struct MarginRequirement {
        uint256 initialMargin;         // Initial margin percentage (basis points)
        uint256 maintenanceMargin;     // Maintenance margin percentage (basis points)
        uint256 qualityAdjustment;     // Quality-based adjustment (basis points)
        uint256 volatilityAdjustment;  // Volatility-based adjustment (basis points)
    }
    
    struct LiquidationData {
        uint256 positionId;
        address liquidator;
        uint256 liquidationPrice;
        uint256 liquidationTimestamp;
        uint256 collateralSeized;
        uint256 liquidatorReward;
    }
    
    // Events
    event FutureCreated(
        uint256 indexed futureId,
        uint256 indexed underlyingTokenId,
        uint256 contractSize,
        uint256 expiryTimestamp,
        SettlementType settlementType
    );
    
    event OptionCreated(
        uint256 indexed optionId,
        uint256 indexed underlyingTokenId,
        uint256 contractSize,
        uint256 strikePrice,
        uint256 expiryTimestamp,
        DerivativeType optionType,
        SettlementType settlementType
    );
    
    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        uint256 indexed derivativeId,
        DerivativeType derivativeType,
        bool isLong,
        uint256 quantity,
        uint256 entryPrice,
        uint256 collateralAmount
    );
    
    event PositionClosed(
        uint256 indexed positionId,
        address indexed trader,
        uint256 exitPrice,
        int256 pnl,
        uint256 collateralReturned
    );
    
    event MarginCall(
        uint256 indexed positionId,
        address indexed trader,
        uint256 requiredMargin,
        uint256 currentCollateral,
        uint256 deadline
    );
    
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed trader,
        address indexed liquidator,
        uint256 liquidationPrice,
        uint256 collateralSeized,
        uint256 liquidatorReward
    );
    
    event DerivativeSettled(
        uint256 indexed derivativeId,
        DerivativeType derivativeType,
        uint256 settlementPrice,
        uint256 settledPositions
    );
    
    // Core Trading Functions
    function createFuture(
        uint256 underlyingTokenId,
        uint256 contractSize,
        uint256 expiryTimestamp,
        SettlementType settlementType,
        string calldata description
    ) external returns (uint256 futureId);
    
    function createOption(
        uint256 underlyingTokenId,
        uint256 contractSize,
        uint256 strikePrice,
        uint256 expiryTimestamp,
        uint256 premium,
        DerivativeType optionType,
        SettlementType settlementType,
        string calldata description
    ) external returns (uint256 optionId);
    
    function openPosition(
        uint256 derivativeId,
        DerivativeType derivativeType,
        bool isLong,
        uint256 quantity,
        uint256 maxPrice,        // Maximum price willing to pay (slippage protection)
        uint256 collateralAmount
    ) external returns (uint256 positionId);
    
    function closePosition(
        uint256 positionId,
        uint256 minPrice        // Minimum price willing to accept (slippage protection)
    ) external returns (int256 pnl);
    
    function addCollateral(uint256 positionId, uint256 amount) external;
    function removeCollateral(uint256 positionId, uint256 amount) external;
    
    // Liquidation Functions
    function liquidatePosition(uint256 positionId) external returns (uint256 liquidatorReward);
    function isPositionLiquidatable(uint256 positionId) external view returns (bool);
    
    // Settlement Functions
    function settleDerivative(uint256 derivativeId, DerivativeType derivativeType) external;
    function exerciseOption(uint256 positionId) external;
    
    // View Functions
    function getFuture(uint256 futureId) external view returns (Future memory);
    function getOption(uint256 optionId) external view returns (Option memory);
    function getPosition(uint256 positionId) external view returns (Position memory);
    function getMarginRequirement(
        uint256 derivativeId, 
        DerivativeType derivativeType
    ) external view returns (MarginRequirement memory);
    function calculatePositionValue(uint256 positionId) external view returns (int256 value);
    function getRequiredMargin(uint256 positionId) external view returns (uint256 required);
    function getUserPositions(address user) external view returns (uint256[] memory positionIds);
    
    // Oracle Integration
    function updateMarginRequirements(uint256 derivativeId, DerivativeType derivativeType) external;
    function getCurrentPrice(uint256 underlyingTokenId) external view returns (uint256 price, uint256 confidence);
    function getQualityAdjustedPrice(uint256 underlyingTokenId) external view returns (uint256 adjustedPrice);
}