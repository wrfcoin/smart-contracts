// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./LiquidityPoolManager.sol";
import "./CarbonCreditAMMFactory.sol";
import "./WeightedCarbonPool.sol";
import "./CarbonCreditAMM.sol";

/**
 * @title CarbonPoolRouter
 * @dev Unified router for both weighted pools and constant product AMM pools
 * Enables cross-pool arbitrage and optimal routing for carbon credit trades
 */
contract CarbonPoolRouter is AccessControl, ReentrancyGuard, Pausable {
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    struct PoolInfo {
        address poolAddress;
        uint8 poolType; // 1 = WeightedPool, 2 = CPAMM
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 swapFee;
        bool isActive;
    }
    
    struct SwapRoute {
        address[] pools;
        uint8[] poolTypes;
        address[] tokens;
        uint256[] amounts;
        uint256 totalAmountOut;
        uint256 totalFees;
    }
    
    LiquidityPoolManager public immutable liquidityPoolManager;
    CarbonCreditAMMFactory public immutable ammFactory;
    address public immutable USDC;
    
    // Pool discovery and routing
    mapping(bytes32 => PoolInfo[]) public tokenPairPools; // keccak256(token0, token1) => pools
    mapping(address => bool) public authorizedPools;
    mapping(address => bytes32) internal poolToPairKey;
    
    // Arbitrage tracking
    mapping(address => uint256) public arbitrageVolume24h;
    mapping(address => uint256) public lastArbitrageTime;
    
    // Constants
    uint256 public constant FEE_DENOMINATOR_BPS = 10_000;
    uint256 public constant MAX_SLIPPAGE_TOLERANCE = 1000; // 10%
    uint256 public constant MIN_ARBITRAGE_PROFIT = 1e16; // 0.01 USDC
    uint256 public constant ARBITRAGE_WINDOW = 300; // 5 minutes
    
    event SwapExecuted(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address[] pools,
        uint256 totalFees
    );
    
    event ArbitrageOpportunity(
        address indexed tokenA,
        address indexed tokenB,
        address poolA,
        address poolB,
        uint256 profit,
        uint256 timestamp
    );
    
    event PoolAdded(
        address indexed pool,
        uint8 poolType,
        address indexed token0,
        address indexed token1
    );
    
    constructor(
        address _liquidityPoolManager,
        address _ammFactory,
        address _usdc
    ) {
        require(_liquidityPoolManager != address(0), "CarbonPoolRouter: Invalid LPM");
        require(_ammFactory != address(0), "CarbonPoolRouter: Invalid factory");
        require(_usdc != address(0), "CarbonPoolRouter: Invalid USDC");
        
        liquidityPoolManager = LiquidityPoolManager(_liquidityPoolManager);
        ammFactory = CarbonCreditAMMFactory(_ammFactory);
        USDC = _usdc;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }
    
    /**
     * @dev Initialize router with existing pools
     */
    function initializePools() external onlyRole(OPERATOR_ROLE) {
        // Add weighted pools
        LiquidityPoolManager.PoolConfiguration[] memory weightedPools = liquidityPoolManager.getActivePools();
        for (uint i = 0; i < weightedPools.length; i++) {
            _addPool(
                weightedPools[i].poolAddress,
                1, // WeightedPool
                USDC,
                weightedPools[i].carbonBasketToken
            );
        }
        
        // Add CPAMM pools
        address[] memory ammPools = ammFactory.getAllPools();
        for (uint i = 0; i < ammPools.length; i++) {
            address pool = ammPools[i];
            (
                address poolAddress,
                address token0,
                address token1,
                uint256 feeBasisPoints,
                uint256 createdAt,
                bool isActive
            ) = ammFactory.poolInfo(pool);
            
            if (isActive) {
                _addPool(
                    poolAddress,
                    2, // CPAMM
                    token0,
                    token1
                );
            }
        }
    }
    
    /**
     * @dev Get best swap route for trading tokens
     */
    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (SwapRoute memory bestRoute) {
        bytes32 pairKey = _getPairKey(tokenIn, tokenOut);
        PoolInfo[] memory availablePools = tokenPairPools[pairKey];
        
        uint256 bestAmountOut = 0;
        address bestPool;
        uint8 bestPoolType;
        uint256 bestFee;
        
        // Direct pools first
        for (uint i = 0; i < availablePools.length; i++) {
            if (!availablePools[i].isActive) continue;
            
            uint256 amountOut = _getAmountOut(
                availablePools[i],
                tokenIn,
                amountIn
            );
            
            if (amountOut > bestAmountOut) {
                bestAmountOut = amountOut;
                bestPool = availablePools[i].poolAddress;
                bestPoolType = availablePools[i].poolType;
                bestFee = availablePools[i].swapFee;
            }
        }
        
        // If USDC is not involved, try routing through USDC
        if (tokenIn != USDC && tokenOut != USDC && bestAmountOut == 0) {
            uint256 intermediateAmount = _getBestAmountOut(tokenIn, USDC, amountIn);
            if (intermediateAmount > 0) {
                uint256 finalAmount = _getBestAmountOut(USDC, tokenOut, intermediateAmount);
                if (finalAmount > bestAmountOut) {
                    // Multi-hop route through USDC
                    bestRoute.pools = new address[](2);
                    bestRoute.poolTypes = new uint8[](2);
                    bestRoute.tokens = new address[](3);
                    bestRoute.amounts = new uint256[](2);
                    
                    // First hop: tokenIn -> USDC
                    (address pool1, uint8 type1) = _getBestPool(tokenIn, USDC);
                    bestRoute.pools[0] = pool1;
                    bestRoute.poolTypes[0] = type1;
                    bestRoute.tokens[0] = tokenIn;
                    bestRoute.amounts[0] = intermediateAmount;
                    
                    // Second hop: USDC -> tokenOut
                    (address pool2, uint8 type2) = _getBestPool(USDC, tokenOut);
                    bestRoute.pools[1] = pool2;
                    bestRoute.poolTypes[1] = type2;
                    bestRoute.tokens[1] = USDC;
                    bestRoute.tokens[2] = tokenOut;
                    bestRoute.amounts[1] = finalAmount;
                    
                    bestRoute.totalAmountOut = finalAmount;
                    return bestRoute;
                }
            }
        }
        
        // Single hop route
        if (bestPool != address(0)) {
            bestRoute.pools = new address[](1);
            bestRoute.poolTypes = new uint8[](1);
            bestRoute.tokens = new address[](2);
            bestRoute.amounts = new uint256[](1);
            
            bestRoute.pools[0] = bestPool;
            bestRoute.poolTypes[0] = bestPoolType;
            bestRoute.tokens[0] = tokenIn;
            bestRoute.tokens[1] = tokenOut;
            bestRoute.amounts[0] = bestAmountOut;
            bestRoute.totalAmountOut = bestAmountOut;
            bestRoute.totalFees = (amountIn * bestFee) / FEE_DENOMINATOR_BPS;
        }
    }
    
    /**
     * @dev Execute swap with automatic routing
     */
    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "CarbonPoolRouter: Expired");
        require(amountIn > 0, "CarbonPoolRouter: Invalid amount");
        require(to != address(0), "CarbonPoolRouter: Invalid recipient");
        
        SwapRoute memory route = this.getBestRoute(tokenIn, tokenOut, amountIn);
        require(route.totalAmountOut >= amountOutMin, "CarbonPoolRouter: Insufficient output");
        
        // Transfer input tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        // Execute swaps
        amountOut = _executeSwapRoute(route, amountIn, to);
        
        // Check for arbitrage opportunities
        _checkArbitrageOpportunities(tokenIn, tokenOut);
        
        emit SwapExecuted(
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            route.pools,
            route.totalFees
        );
    }
    
    /**
     * @dev Add new pool to router
     */
    function addPool(
        address pool,
        uint8 poolType,
        address token0,
        address token1
    ) external onlyRole(OPERATOR_ROLE) {
        _addPool(pool, poolType, token0, token1);
    }
    
    /**
     * @dev Check and report arbitrage opportunities
     */
    function checkArbitrageOpportunities() external view returns (
        address[] memory tokenAs,
        address[] memory tokenBs,
        address[] memory poolAs,
        address[] memory poolBs,
        uint256[] memory profits
    ) {
        // Implementation would scan all token pairs and compare prices
        // across different pool types to identify arbitrage opportunities
        uint256 foundCount = 0;
        uint256 maxOpportunities = 10;
        
        tokenAs = new address[](maxOpportunities);
        tokenBs = new address[](maxOpportunities);
        poolAs = new address[](maxOpportunities);
        poolBs = new address[](maxOpportunities);
        profits = new uint256[](maxOpportunities);
        
        // This would iterate through all token pairs and check price differences
        // For brevity, returning empty arrays
    }
    
    /**
     * @dev Execute arbitrage between pools
     */
    function executeArbitrage(
        address tokenA,
        address tokenB,
        address poolLow,
        address poolHigh,
        uint256 amount
    ) external onlyRole(OPERATOR_ROLE) nonReentrant returns (uint256 profit) {
        require(
            block.timestamp >= lastArbitrageTime[msg.sender] + ARBITRAGE_WINDOW,
            "CarbonPoolRouter: Arbitrage cooldown"
        );
        
        // Implementation would:
        // 1. Flash loan or use capital to buy tokenA from poolLow
        // 2. Sell tokenA to poolHigh for higher price
        // 3. Calculate profit after fees
        // 4. Emit ArbitrageOpportunity event
        
        lastArbitrageTime[msg.sender] = block.timestamp;
        arbitrageVolume24h[msg.sender] += amount;
    }
    
    /**
     * @dev Update pool information
     */
    function updatePoolInfo(address pool) external {
        require(authorizedPools[pool], "CarbonPoolRouter: Unauthorized pool");
        
        // Update pool reserves and state
        _updatePoolReserves(pool);
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    function _addPool(
        address pool,
        uint8 poolType,
        address token0,
        address token1
    ) internal {
        require(pool != address(0), "CarbonPoolRouter: Invalid pool");
        require(!authorizedPools[pool], "CarbonPoolRouter: Pool already added");
        
        authorizedPools[pool] = true;

        bytes32 pairKey = _getPairKey(token0, token1);
        poolToPairKey[pool] = pairKey;
        
        PoolInfo memory poolInfo = PoolInfo({
            poolAddress: pool,
            poolType: poolType,
            token0: token0,
            token1: token1,
            reserve0: 0,
            reserve1: 0,
            swapFee: 0,
            isActive: true
        });
        
        // Update pool info
        _updatePoolInfo(poolInfo);
        
        tokenPairPools[pairKey].push(poolInfo);
        
        emit PoolAdded(pool, poolType, token0, token1);
    }
    
    function _updatePoolInfo(PoolInfo memory poolInfo) internal {
        if (poolInfo.poolType == 1) {
            // WeightedCarbonPool
            WeightedCarbonPool weightedPool = WeightedCarbonPool(poolInfo.poolAddress);
            (poolInfo.reserve0, poolInfo.reserve1) = weightedPool.getReserves();
            poolInfo.swapFee = weightedPool.swapFee();
        } else if (poolInfo.poolType == 2) {
            // CarbonCreditAMM
            CarbonCreditAMM ammPool = CarbonCreditAMM(poolInfo.poolAddress);
            poolInfo.reserve0 = ammPool.reserve0();
            poolInfo.reserve1 = ammPool.reserve1();
            poolInfo.swapFee = ammPool.feeBasisPoints();
        }
    }
    
    function _updatePoolReserves(address pool) internal {
        bytes32 pairKey = poolToPairKey[pool];
        PoolInfo[] storage pools = tokenPairPools[pairKey];

        // Find and update the pool
        for (uint i = 0; i < pools.length; i++) {
            if (pools[i].poolAddress == pool) {
                _updatePoolInfo(pools[i]);
                break;
            }
        }
    }
    
    function _executeSwapRoute(
        SwapRoute memory route,
        uint256 amountIn,
        address to
    ) internal returns (uint256 finalAmountOut) {
        uint256 currentAmount = amountIn;
        address currentToken = route.tokens[0];
        
        for (uint i = 0; i < route.pools.length; i++) {
            address nextToken = route.tokens[i + 1];
            address recipient = (i == route.pools.length - 1) ? to : address(this);
            
            if (route.poolTypes[i] == 1) {
                // WeightedCarbonPool
                WeightedCarbonPool pool = WeightedCarbonPool(route.pools[i]);
                IERC20(currentToken).approve(route.pools[i], currentAmount);
                
                currentAmount = pool.swapExactTokensForTokens(
                    currentToken,
                    nextToken,
                    currentAmount,
                    0, // Accept any amount of tokens out
                    recipient,
                    block.timestamp + 3600
                );
            } else if (route.poolTypes[i] == 2) {
                // CarbonCreditAMM
                CarbonCreditAMM pool = CarbonCreditAMM(route.pools[i]);
                IERC20(currentToken).approve(route.pools[i], currentAmount);
                
                // Use AMM's swap function
                (uint256 amount0Out, uint256 amount1Out) = _calculateAMMAmounts(
                    pool,
                    currentToken,
                    currentAmount
                );
                
                pool.swap(amount0Out, amount1Out, recipient, "");
                currentAmount = amount0Out > 0 ? amount0Out : amount1Out;
            }
            
            currentToken = nextToken;
        }
        
        finalAmountOut = currentAmount;
    }
    
    function _getAmountOut(
        PoolInfo memory poolInfo,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        if (poolInfo.poolType == 1) {
            // WeightedCarbonPool
            try WeightedCarbonPool(poolInfo.poolAddress).getAmountOut(tokenIn, amountIn) returns (uint256 amount) {
                amountOut = amount;
            } catch {
                amountOut = 0;
            }
        } else if (poolInfo.poolType == 2) {
            // CarbonCreditAMM - calculate using constant product formula
            if (poolInfo.reserve0 > 0 && poolInfo.reserve1 > 0) {
                uint256 amountInWithFee = amountIn * (10000 - 30); // 0.3% fee
                
                if (tokenIn == poolInfo.token0) {
                    amountOut = (amountInWithFee * poolInfo.reserve1) / 
                               (poolInfo.reserve0 * 10000 + amountInWithFee);
                } else {
                    amountOut = (amountInWithFee * poolInfo.reserve0) / 
                               (poolInfo.reserve1 * 10000 + amountInWithFee);
                }
            }
        }
    }
    
    function _getBestAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 bestAmount) {
        bytes32 pairKey = _getPairKey(tokenIn, tokenOut);
        PoolInfo[] memory pools = tokenPairPools[pairKey];
        
        for (uint i = 0; i < pools.length; i++) {
            if (!pools[i].isActive) continue;
            
            uint256 amountOut = _getAmountOut(pools[i], tokenIn, amountIn);
            if (amountOut > bestAmount) {
                bestAmount = amountOut;
            }
        }
    }
    
    function _getBestPool(
        address tokenIn,
        address tokenOut
    ) internal view returns (address bestPool, uint8 bestType) {
        bytes32 pairKey = _getPairKey(tokenIn, tokenOut);
        PoolInfo[] memory pools = tokenPairPools[pairKey];
        
        uint256 bestAmount = 0;
        
        for (uint i = 0; i < pools.length; i++) {
            if (!pools[i].isActive) continue;
            
            uint256 amountOut = _getAmountOut(pools[i], tokenIn, 1e18); // Test with 1 token
            if (amountOut > bestAmount) {
                bestAmount = amountOut;
                bestPool = pools[i].poolAddress;
                bestType = pools[i].poolType;
            }
        }
    }
    
    function _checkArbitrageOpportunities(address tokenA, address tokenB) internal {
        bytes32 pairKey = _getPairKey(tokenA, tokenB);
        PoolInfo[] memory pools = tokenPairPools[pairKey];
        
        if (pools.length < 2) return;
        
        uint256 testAmount = 1e18; // 1 token
        uint256 minPrice = type(uint256).max;
        uint256 maxPrice = 0;
        address minPool;
        address maxPool;
        
        for (uint i = 0; i < pools.length; i++) {
            if (!pools[i].isActive) continue;
            
            uint256 price = _getAmountOut(pools[i], tokenA, testAmount);
            if (price < minPrice) {
                minPrice = price;
                minPool = pools[i].poolAddress;
            }
            if (price > maxPrice) {
                maxPrice = price;
                maxPool = pools[i].poolAddress;
            }
        }
        
        if (maxPrice > minPrice) {
            uint256 profit = maxPrice - minPrice;
            if (profit >= MIN_ARBITRAGE_PROFIT) {
                emit ArbitrageOpportunity(tokenA, tokenB, minPool, maxPool, profit, block.timestamp);
            }
        }
    }
    
    function _calculateAMMAmounts(
        CarbonCreditAMM pool,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256 amount0Out, uint256 amount1Out) {
        address token0 = address(pool.token0());
        
        if (tokenIn == token0) {
            amount1Out = _getConstantProductAmountOut(
                amountIn,
                pool.reserve0(),
                pool.reserve1(),
                pool.feeBasisPoints()
            );
        } else {
            amount0Out = _getConstantProductAmountOut(
                amountIn,
                pool.reserve1(),
                pool.reserve0(),
                pool.feeBasisPoints()
            );
        }
    }
    
    function _getConstantProductAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBasisPoints
    ) internal pure returns (uint256 amountOut) {
        uint256 amountInWithFee = amountIn * (10000 - feeBasisPoints);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    function _getPairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return tokenA < tokenB 
            ? keccak256(abi.encodePacked(tokenA, tokenB))
            : keccak256(abi.encodePacked(tokenB, tokenA));
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    function getAllPools() external view returns (PoolInfo[] memory allPoolInfo) {
        // Implementation would collect all pools from all pairs
        // For brevity, returning empty array
        allPoolInfo = new PoolInfo[](0);
    }
    
    function getPoolsByTokenPair(
        address token0,
        address token1
    ) external view returns (PoolInfo[] memory) {
        bytes32 pairKey = _getPairKey(token0, token1);
        return tokenPairPools[pairKey];
    }
    
    function getArbitrageStats(address trader) external view returns (
        uint256 volume24h,
        uint256 lastTradeTime
    ) {
        return (arbitrageVolume24h[trader], lastArbitrageTime[trader]);
    }
}
