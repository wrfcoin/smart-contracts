// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDerivativesEngine.sol";
import "./DerivativesEngine.sol";
import "./CarbonCreditAMM.sol";
import "./WRFToken.sol";

/**
 * @title DerivativesLiquidator
 * @dev Helper contract for efficient liquidation of derivatives positions using AMM flash loans
 * Integrates with CarbonCreditAMM to provide capital-efficient liquidations
 */
contract DerivativesLiquidator is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    DerivativesEngine public immutable derivativesEngine;
    CarbonCreditAMM public immutable amm;
    WRFToken public immutable wrfToken;
    
    struct LiquidationParams {
        uint256 positionId;
        uint256 maxSlippage;        // Maximum acceptable slippage in basis points
        uint256 minReward;          // Minimum liquidator reward expected
        address rewardToken;        // Token to receive reward in (WRF or underlying)
        bytes data;                 // Additional data for complex liquidations
    }
    
    struct FlashLiquidationData {
        uint256 positionId;
        uint256 expectedReward;
        address liquidator;
        uint256 maxSlippage;
    }
    
    event LiquidationExecuted(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 liquidatorReward,
        uint256 gasUsed
    );
    
    event FlashLiquidationStarted(
        uint256 indexed positionId,
        uint256 flashLoanAmount,
        address liquidator
    );
    
    modifier onlyAuthorizedLiquidator() {
        require(
            hasRole(LIQUIDATOR_ROLE, msg.sender) || msg.sender == address(derivativesEngine),
            "Not authorized liquidator"
        );
        _;
    }
    
    constructor(
        address _derivativesEngine,
        address _amm,
        address _wrfToken
    ) {
        require(_derivativesEngine != address(0), "Invalid derivatives engine");
        require(_amm != address(0), "Invalid AMM");
        require(_wrfToken != address(0), "Invalid WRF token");
        
        derivativesEngine = DerivativesEngine(_derivativesEngine);
        amm = CarbonCreditAMM(_amm);
        wrfToken = WRFToken(_wrfToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LIQUIDATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    /**
     * @dev Execute a simple liquidation without flash loans
     */
    function liquidatePosition(
        uint256 positionId,
        uint256 minReward
    ) external nonReentrant onlyAuthorizedLiquidator returns (uint256 reward) {
        require(derivativesEngine.isPositionLiquidatable(positionId), "Position not liquidatable");
        
        uint256 gasStart = gasleft();
        
        // Execute liquidation through derivatives engine
        reward = derivativesEngine.liquidatePosition(positionId);
        require(reward >= minReward, "Insufficient liquidator reward");
        
        uint256 gasUsed = gasStart - gasleft();
        
        emit LiquidationExecuted(positionId, msg.sender, reward, gasUsed);
    }
    
    /**
     * @dev Execute a flash loan liquidation for capital efficiency
     */
    function flashLiquidatePosition(
        LiquidationParams calldata params
    ) external nonReentrant onlyAuthorizedLiquidator {
        require(derivativesEngine.isPositionLiquidatable(params.positionId), "Position not liquidatable");
        
        IDerivativesEngine.Position memory position = derivativesEngine.getPosition(params.positionId);
        
        // Calculate flash loan amount needed
        uint256 flashLoanAmount = _calculateFlashLoanAmount(params.positionId);
        
        // Prepare flash loan data
        FlashLiquidationData memory flashData = FlashLiquidationData({
            positionId: params.positionId,
            expectedReward: params.minReward,
            liquidator: msg.sender,
            maxSlippage: params.maxSlippage
        });
        
        emit FlashLiquidationStarted(params.positionId, flashLoanAmount, msg.sender);
        
        // Execute flash loan liquidation
        amm.flashLoan(
            flashLoanAmount,
            0, // Only borrow token0 (WRF)
            address(this),
            abi.encode(flashData)
        );
    }
    
    /**
     * @dev Flash loan callback function
     */
    function onFlashLoan(
        address borrower,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        require(msg.sender == address(amm), "Only AMM can call");
        require(borrower == address(this), "Invalid borrower");
        
        FlashLiquidationData memory flashData = abi.decode(data, (FlashLiquidationData));
        
        // Execute the liquidation with borrowed funds
        _executeLiquidationWithFlashLoan(flashData, amount0, fee0);
        
        // Repay flash loan
        uint256 repayAmount = amount0 + fee0;
        IERC20(address(wrfToken)).safeTransfer(address(amm), repayAmount);
    }
    
    /**
     * @dev Batch liquidate multiple positions
     */
    function batchLiquidate(
        uint256[] calldata positionIds,
        uint256[] calldata minRewards
    ) external nonReentrant onlyAuthorizedLiquidator returns (uint256 totalReward) {
        require(positionIds.length == minRewards.length, "Array length mismatch");
        require(positionIds.length <= 10, "Too many positions"); // Gas limit protection
        
        for (uint256 i = 0; i < positionIds.length; i++) {
            if (derivativesEngine.isPositionLiquidatable(positionIds[i])) {
                uint256 reward = derivativesEngine.liquidatePosition(positionIds[i]);
                require(reward >= minRewards[i], "Insufficient reward for position");
                totalReward += reward;
                
                emit LiquidationExecuted(positionIds[i], msg.sender, reward, 0);
            }
        }
    }
    
    /**
     * @dev Check if a position is profitable to liquidate
     */
    function isLiquidationProfitable(
        uint256 positionId,
        uint256 gasPrice
    ) external view returns (bool profitable, uint256 estimatedReward, uint256 estimatedCost) {
        if (!derivativesEngine.isPositionLiquidatable(positionId)) {
            return (false, 0, 0);
        }
        
        IDerivativesEngine.Position memory position = derivativesEngine.getPosition(positionId);
        
        // Estimate liquidator reward (0.5% of collateral)
        estimatedReward = (position.collateralAmount * 50) / 10000;
        
        // Estimate gas cost (approximate)
        estimatedCost = gasPrice * 200000; // Approximate gas for liquidation
        
        profitable = estimatedReward > estimatedCost;
    }
    
    /**
     * @dev Get optimal liquidation strategy for a position
     */
    function getOptimalLiquidationStrategy(
        uint256 positionId
    ) external view returns (
        bool useFlashLoan,
        uint256 requiredCapital,
        uint256 estimatedReward,
        uint256 slippageTolerance
    ) {
        if (!derivativesEngine.isPositionLiquidatable(positionId)) {
            return (false, 0, 0, 0);
        }
        
        IDerivativesEngine.Position memory position = derivativesEngine.getPosition(positionId);
        
        estimatedReward = (position.collateralAmount * 50) / 10000; // 0.5%
        requiredCapital = _calculateFlashLoanAmount(positionId);
        
        // Use flash loan if required capital > liquidator's WRF balance
        useFlashLoan = requiredCapital > wrfToken.balanceOf(msg.sender);
        
        // Calculate appropriate slippage tolerance based on position size
        if (position.collateralAmount < 1000 * 10**18) { // < 1000 WRF
            slippageTolerance = 300; // 3%
        } else if (position.collateralAmount < 10000 * 10**18) { // < 10000 WRF  
            slippageTolerance = 200; // 2%
        } else {
            slippageTolerance = 100; // 1% for large positions
        }
    }
    
    /**
     * @dev Find liquidatable positions for a given trader
     */
    function findLiquidatablePositions(
        address trader,
        uint256 maxPositions
    ) external view returns (uint256[] memory liquidatablePositions) {
        uint256[] memory userPositions = derivativesEngine.getUserPositions(trader);
        uint256[] memory temp = new uint256[](userPositions.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < userPositions.length && count < maxPositions; i++) {
            if (derivativesEngine.isPositionLiquidatable(userPositions[i])) {
                temp[count] = userPositions[i];
                count++;
            }
        }
        
        // Resize array to actual count
        liquidatablePositions = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            liquidatablePositions[i] = temp[i];
        }
    }
    
    // Internal functions
    function _executeLiquidationWithFlashLoan(
        FlashLiquidationData memory flashData,
        uint256 borrowedAmount,
        uint256 fee
    ) internal {
        // Use borrowed funds to execute liquidation
        uint256 reward = derivativesEngine.liquidatePosition(flashData.positionId);
        require(reward >= flashData.expectedReward, "Insufficient liquidation reward");
        
        // Ensure we have enough to repay the flash loan
        uint256 repayAmount = borrowedAmount + fee;
        require(wrfToken.balanceOf(address(this)) >= repayAmount, "Insufficient funds to repay flash loan");
        
        // Calculate net profit
        uint256 netProfit = reward > repayAmount ? reward - repayAmount : 0;
        
        // Transfer net profit to liquidator
        if (netProfit > 0) {
            IERC20(address(wrfToken)).safeTransfer(flashData.liquidator, netProfit);
        }
        
        emit LiquidationExecuted(flashData.positionId, flashData.liquidator, reward, 0);
    }
    
    function _calculateFlashLoanAmount(uint256 positionId) internal view returns (uint256) {
        IDerivativesEngine.Position memory position = derivativesEngine.getPosition(positionId);
        
        // For simplicity, assume we need the full collateral amount
        // In practice, this would be more sophisticated based on the position type and market conditions
        return position.collateralAmount;
    }
    
    // Admin functions
    function updateLiquidatorRole(address account, bool granted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (granted) {
            _grantRole(LIQUIDATOR_ROLE, account);
        } else {
            _revokeRole(LIQUIDATOR_ROLE, account);
        }
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(EMERGENCY_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    // Utility functions for external liquidation bots
    function getPositionHealth(uint256 positionId) external view returns (
        bool isHealthy,
        uint256 healthRatio,
        uint256 liquidationThreshold
    ) {
        try derivativesEngine.getPosition(positionId) returns (IDerivativesEngine.Position memory position) {
            if (position.status != IDerivativesEngine.PositionStatus.ACTIVE) {
                return (false, 0, 0);
            }
            
            uint256 requiredMargin = derivativesEngine.getRequiredMargin(positionId);
            int256 positionValue = derivativesEngine.calculatePositionValue(positionId);
            
            uint256 effectiveCollateral;
            if (positionValue >= 0) {
                effectiveCollateral = position.collateralAmount + uint256(positionValue);
            } else {
                uint256 loss = uint256(-positionValue);
                effectiveCollateral = position.collateralAmount > loss ? position.collateralAmount - loss : 0;
            }
            
            healthRatio = requiredMargin > 0 ? (effectiveCollateral * 10000) / requiredMargin : 10000;
            liquidationThreshold = 10000; // 100% = liquidation threshold
            isHealthy = healthRatio >= liquidationThreshold;
            
        } catch {
            return (false, 0, 0);
        }
    }
}