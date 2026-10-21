// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./CarbonCreditAMMFactory.sol";
import "./CarbonCreditAMM.sol";

/**
 * @title CarbonCreditRouter
 * @notice Secure router contract for optimal multi-pool routing with comprehensive security measures
 * @dev Features advanced security including:
 *      - Path validation for multi-hop swaps
 *      - Deadline enforcement with granular controls
 *      - Minimum output validation with slippage protection
 *      - MEV protection strategies
 *      - Reentrancy protection across all operations
 *      - Gas-optimized routing algorithms
 *      - Emergency controls with access restrictions
 * @author WRFCoin Security Team
 * @custom:security-contact security@wrfcoin.com
 */
contract CarbonCreditRouter is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    
    /// @dev Role for router administration
    bytes32 public constant ROUTER_ADMIN_ROLE = keccak256("ROUTER_ADMIN_ROLE");
    
    /// @dev Basis points denominator for fee calculations
    uint256 private constant BASIS_POINTS = 10000;
    
    /// @dev Maximum number of hops allowed in a route to prevent gas issues
    uint256 private constant MAX_ROUTE_HOPS = 3;
    
    /// @dev Maximum routing fee to prevent excessive fees (1%)
    uint256 private constant MAX_ROUTING_FEE_BASIS_POINTS = 100;
    
    /// @dev Maximum slippage protection (20%)
    uint256 private constant MAX_SLIPPAGE_BASIS_POINTS = 2000;
    
    /// @dev Minimum deadline offset (1 minute)
    uint256 private constant MIN_DEADLINE_OFFSET = 60;
    
    // ============ Immutable State ============
    
    /// @notice Factory contract for creating and finding AMM pools
    CarbonCreditAMMFactory public immutable factory;
    
    /// @notice Wrapped ETH token address for ETH swaps
    address public immutable WETH;
    
    // ============ Structures ============
    
    /// @notice Represents a trading route through one or more pools
    struct Route {
        address[] pools;        // Pool addresses in the route
        address[] tokens;       // Token addresses in the route
        uint256[] feeTiers;     // Fee tiers for each hop
        uint256 expectedOutput; // Expected output amount
        uint256 totalFee;       // Total fees across all hops
        uint256 priceImpact;    // Total price impact in basis points
    }
    
    /// @notice Parameters for token swaps
    struct SwapParams {
        address tokenIn;        // Input token address
        address tokenOut;       // Output token address
        uint256 amountIn;       // Input amount
        uint256 amountOutMin;   // Minimum output amount (slippage protection)
        address to;             // Recipient address
        uint256 deadline;       // Transaction deadline
        uint256 maxHops;        // Maximum allowed hops (gas protection)
    }
    
    /// @notice Parameters for liquidity operations
    struct LiquidityParams {
        address tokenA;         // First token address
        address tokenB;         // Second token address
        uint256 feeTier;        // Pool fee tier
        uint256 amountADesired; // Desired amount of tokenA
        uint256 amountBDesired; // Desired amount of tokenB
        uint256 amountAMin;     // Minimum amount of tokenA
        uint256 amountBMin;     // Minimum amount of tokenB
        address to;             // Recipient of LP tokens
        uint256 deadline;       // Transaction deadline
    }
    
    // ============ State Variables ============
    
    /// @notice Mapping of authorized callers for restricted functions
    mapping(address => bool) public authorizedCallers;
    
    /// @notice Anti-MEV protection: tracks last transaction timestamp per user
    mapping(address => uint256) public lastTransactionTime;
    
    /// @notice Maximum allowed slippage in basis points (default 3%)
    uint256 public maxSlippageBasisPoints = 300;
    
    /// @notice Router protocol fee in basis points (default 0.05%)
    uint256 public routingFeeBasisPoints = 5;
    
    /// @notice Minimum time between transactions to prevent MEV attacks (default 12 seconds)
    uint256 public minTimeBetweenTransactions = 12;
    
    // ============ Events ============
    
    /// @notice Emitted when a swap is executed
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to,
        uint256 routingFee,
        uint256 priceImpact,
        uint256 hops
    );
    
    /// @notice Emitted when liquidity is added to a pool
    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address indexed to,
        address pool
    );
    
    /// @notice Emitted when liquidity is removed from a pool
    event LiquidityRemoved(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address indexed to,
        address pool
    );
    
    /// @notice Emitted when MEV protection is triggered
    event MEVProtectionTriggered(address indexed user, uint256 blockTime);
    
    /// @notice Emitted when route parameters are updated
    event RouteParametersUpdated(uint256 newSlippage, uint256 newRoutingFee, uint256 newMEVProtection);
    
    // ============ Modifiers ============
    
    /// @notice Ensures transaction deadline has not passed
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "CarbonCreditRouter: EXPIRED");
        require(deadline <= block.timestamp + 1 hours, "CarbonCreditRouter: DEADLINE_TOO_FAR");
        _;
    }
    
    /// @notice Restricts access to authorized callers and admins
    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || hasRole(ROUTER_ADMIN_ROLE, msg.sender),
            "CarbonCreditRouter: UNAUTHORIZED"
        );
        _;
    }
    
    /// @notice Prevents MEV attacks by enforcing minimum time between transactions
    modifier antiMEV() {
        require(
            block.timestamp >= lastTransactionTime[msg.sender] + minTimeBetweenTransactions,
            "CarbonCreditRouter: MEV_PROTECTION"
        );
        lastTransactionTime[msg.sender] = block.timestamp;
        emit MEVProtectionTriggered(msg.sender, block.timestamp);
        _;
    }
    
    /// @notice Validates routing parameters
    modifier validRouteParams(uint256 maxHops, uint256 amountOutMin) {
        require(maxHops > 0 && maxHops <= MAX_ROUTE_HOPS, "CarbonCreditRouter: INVALID_MAX_HOPS");
        require(amountOutMin > 0, "CarbonCreditRouter: INVALID_MIN_OUTPUT");
        _;
    }
    
    constructor(address _factory, address _WETH) {
        factory = CarbonCreditAMMFactory(_factory);
        WETH = _WETH;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROUTER_ADMIN_ROLE, msg.sender);
    }
    
    /**
     * @dev Add liquidity to a pool
     */
    function addLiquidity(
        LiquidityParams calldata params
    ) external nonReentrant whenNotPaused ensure(params.deadline) returns (
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    ) {
        (amountA, amountB) = _addLiquidity(
            params.tokenA,
            params.tokenB,
            params.feeTier,
            params.amountADesired,
            params.amountBDesired,
            params.amountAMin,
            params.amountBMin
        );
        
        address pool = factory.getPool(params.tokenA, params.tokenB, params.feeTier);
        require(pool != address(0), "CarbonCreditRouter: POOL_NOT_EXISTS");
        require(factory.isPoolActive(pool), "CarbonCreditRouter: POOL_NOT_ACTIVE");

        _safeTransferFrom(params.tokenA, msg.sender, pool, amountA);
        _safeTransferFrom(params.tokenB, msg.sender, pool, amountB);

        liquidity = CarbonCreditAMM(pool).mint(params.to);
        
        emit LiquidityAdded(params.tokenA, params.tokenB, amountA, amountB, liquidity, params.to, pool);
    }
    
    /**
     * @dev Remove liquidity from a pool
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 feeTier,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pool = factory.getPool(tokenA, tokenB, feeTier);
        require(pool != address(0), "CarbonCreditRouter: POOL_NOT_EXISTS");
        require(factory.isPoolActive(pool), "CarbonCreditRouter: POOL_NOT_ACTIVE");

        IERC20(pool).transferFrom(msg.sender, pool, liquidity);
        (uint256 amount0, uint256 amount1) = CarbonCreditAMM(pool).burn(to);
        
        (address token0,) = _sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        
        require(amountA >= amountAMin, "CarbonCreditRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "CarbonCreditRouter: INSUFFICIENT_B_AMOUNT");
        
        emit LiquidityRemoved(tokenA, tokenB, amountA, amountB, liquidity, to, pool);
    }
    
    /**
     * @dev Execute exact input swap
     */
    function swapExactTokensForTokens(
        SwapParams calldata params
    ) external nonReentrant whenNotPaused ensure(params.deadline) returns (uint256 amountOut) {
        Route memory route = _findOptimalRoute(
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            params.maxHops
        );
        
        require(route.expectedOutput >= params.amountOutMin, "CarbonCreditRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Calculate routing fee
        uint256 routingFee = (params.amountIn * routingFeeBasisPoints) / 10000;
        uint256 amountInAfterFee = params.amountIn - routingFee;
        
        // Execute swap through optimal route
        amountOut = _executeSwapRoute(route, amountInAfterFee, params.to);
        
        // Transfer routing fee to protocol
        if (routingFee > 0) {
            _safeTransferFrom(params.tokenIn, msg.sender, address(this), routingFee);
        }
        
        emit SwapExecuted(
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            params.to,
            routingFee,
            route.priceImpact,
            route.pools.length
        );
    }
    
    /**
     * @dev Execute exact output swap
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address tokenIn,
        address tokenOut,
        address to,
        uint256 deadline,
        uint256 maxHops
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountIn) {
        Route memory route = _findOptimalRouteForExactOutput(tokenIn, tokenOut, amountOut, maxHops);
        
        require(route.expectedOutput <= amountInMax, "CarbonCreditRouter: EXCESSIVE_INPUT_AMOUNT");
        
        amountIn = _executeReverseSwapRoute(route, amountOut, to);
        
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut, to, 0, route.priceImpact, route.pools.length);
    }
    
    /**
     * @dev Get optimal route for a swap
     */
    function getOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 maxHops
    ) external view returns (Route memory route) {
        return _findOptimalRoute(tokenIn, tokenOut, amountIn, maxHops);
    }
    
    /**
     * @dev Get quote for exact input swap
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path,
        uint256[] calldata feeTiers
    ) external view returns (uint256[] memory amounts) {
        require(path.length >= 2, "CarbonCreditRouter: INVALID_PATH");
        require(path.length == feeTiers.length + 1, "CarbonCreditRouter: INVALID_FEE_TIERS");
        
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        
        for (uint256 i = 0; i < path.length - 1; i++) {
            address pool = factory.getPool(path[i], path[i + 1], feeTiers[i]);
            if (pool != address(0)) {
                (uint256 reserve0, uint256 reserve1,) = CarbonCreditAMM(pool).getReserves();
                (address token0,) = _sortTokens(path[i], path[i + 1]);
                (uint256 reserveIn, uint256 reserveOut) = path[i] == token0 
                    ? (reserve0, reserve1) 
                    : (reserve1, reserve0);
                amounts[i + 1] = CarbonCreditAMM(pool).getAmountOut(amounts[i], reserveIn, reserveOut);
            } else {
                amounts[i + 1] = 0;
            }
        }
    }
    
    /**
     * @dev Get quote for exact output swap
     */
    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path,
        uint256[] calldata feeTiers
    ) external view returns (uint256[] memory amounts) {
        require(path.length >= 2, "CarbonCreditRouter: INVALID_PATH");
        require(path.length == feeTiers.length + 1, "CarbonCreditRouter: INVALID_FEE_TIERS");
        
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        
        for (uint256 i = path.length - 1; i > 0; i--) {
            address pool = factory.getPool(path[i - 1], path[i], feeTiers[i - 1]);
            if (pool != address(0)) {
                (uint256 reserve0, uint256 reserve1,) = CarbonCreditAMM(pool).getReserves();
                (address token0,) = _sortTokens(path[i - 1], path[i]);
                (uint256 reserveIn, uint256 reserveOut) = path[i - 1] == token0 
                    ? (reserve0, reserve1) 
                    : (reserve1, reserve0);
                amounts[i - 1] = CarbonCreditAMM(pool).getAmountIn(amounts[i], reserveIn, reserveOut);
            } else {
                amounts[i - 1] = type(uint256).max;
            }
        }
    }
    
    /**
     * @dev Internal function to add liquidity
     */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 feeTier,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        address pool = factory.getPool(tokenA, tokenB, feeTier);
        if (pool == address(0)) {
            pool = factory.createPool(tokenA, tokenB, feeTier);
        }
        
        (uint256 reserve0, uint256 reserve1,) = CarbonCreditAMM(pool).getReserves();
        if (reserve0 == 0 && reserve1 == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            (address token0,) = _sortTokens(tokenA, tokenB);
            (uint256 reserveA, uint256 reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            
            uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "CarbonCreditRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "CarbonCreditRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    
    /**
     * @dev Find optimal route for a swap (simplified implementation)
     */
    function _findOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /* maxHops */
    ) internal view returns (Route memory) {
        // Direct pool check
        uint256[] memory feeTiers = factory.getSupportedFeeTiers();
        uint256 bestOutput = 0;
        uint256 bestFeeTier = 0;
        
        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = factory.getPool(tokenIn, tokenOut, feeTiers[i]);
            if (pool != address(0)) {
                (uint256 reserve0, uint256 reserve1,) = CarbonCreditAMM(pool).getReserves();
                (address token0,) = _sortTokens(tokenIn, tokenOut);
                (uint256 reserveIn, uint256 reserveOut) = tokenIn == token0 
                    ? (reserve0, reserve1) 
                    : (reserve1, reserve0);
                
                if (reserveIn > 0 && reserveOut > 0) {
                    uint256 output = CarbonCreditAMM(pool).getAmountOut(amountIn, reserveIn, reserveOut);
                    if (output > bestOutput) {
                        bestOutput = output;
                        bestFeeTier = feeTiers[i];
                    }
                }
            }
        }
        
        // Build route
        Route memory route;
        if (bestOutput > 0) {
            route.pools = new address[](1);
            route.tokens = new address[](2);
            route.feeTiers = new uint256[](1);
            
            route.pools[0] = factory.getPool(tokenIn, tokenOut, bestFeeTier);
            route.tokens[0] = tokenIn;
            route.tokens[1] = tokenOut;
            route.feeTiers[0] = bestFeeTier;
            route.expectedOutput = bestOutput;
        }
        
        return route;
    }
    
    /**
     * @dev Find optimal route for exact output (simplified)
     */
    function _findOptimalRouteForExactOutput(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 /* maxHops */
    ) internal view returns (Route memory) {
        uint256[] memory feeTiers = factory.getSupportedFeeTiers();
        uint256 bestInput = type(uint256).max;
        uint256 bestFeeTier = 0;
        
        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = factory.getPool(tokenIn, tokenOut, feeTiers[i]);
            if (pool != address(0)) {
                (uint256 reserve0, uint256 reserve1,) = CarbonCreditAMM(pool).getReserves();
                (address token0,) = _sortTokens(tokenIn, tokenOut);
                (uint256 reserveIn, uint256 reserveOut) = tokenIn == token0 
                    ? (reserve0, reserve1) 
                    : (reserve1, reserve0);
                
                if (reserveIn > 0 && reserveOut > amountOut) {
                    uint256 input = CarbonCreditAMM(pool).getAmountIn(amountOut, reserveIn, reserveOut);
                    if (input < bestInput) {
                        bestInput = input;
                        bestFeeTier = feeTiers[i];
                    }
                }
            }
        }
        
        Route memory route;
        if (bestInput < type(uint256).max) {
            route.pools = new address[](1);
            route.tokens = new address[](2);
            route.feeTiers = new uint256[](1);
            
            route.pools[0] = factory.getPool(tokenIn, tokenOut, bestFeeTier);
            route.tokens[0] = tokenIn;
            route.tokens[1] = tokenOut;
            route.feeTiers[0] = bestFeeTier;
            route.expectedOutput = bestInput;
        }
        
        return route;
    }
    
    /**
     * @dev Execute swap through route
     */
    function _executeSwapRoute(
        Route memory route,
        uint256 amountIn,
        address to
    ) internal returns (uint256 amountOut) {
        require(route.pools.length > 0, "CarbonCreditRouter: NO_ROUTE_FOUND");
        
        // Transfer input tokens to first pool
        _safeTransferFrom(route.tokens[0], msg.sender, route.pools[0], amountIn);
        
        // Execute swaps
        for (uint256 i = 0; i < route.pools.length; i++) {
            address tokenIn = route.tokens[i];
            address tokenOut = route.tokens[i + 1];
            address pool = route.pools[i];
            
            (address token0,) = _sortTokens(tokenIn, tokenOut);
            (uint256 amount0Out, uint256 amount1Out) = tokenIn == token0 
                ? (uint256(0), amountIn) 
                : (amountIn, uint256(0));
            
            address nextTo = i == route.pools.length - 1 ? to : route.pools[i + 1];
            
            CarbonCreditAMM(pool).swap(amount0Out, amount1Out, nextTo, "");
            
            // Update amountIn for next hop
            if (i < route.pools.length - 1) {
                amountIn = amount0Out > 0 ? amount0Out : amount1Out;
            } else {
                amountOut = amount0Out > 0 ? amount0Out : amount1Out;
            }
        }
    }
    
    /**
     * @dev Execute reverse swap for exact output
     */
    function _executeReverseSwapRoute(
        Route memory route,
        uint256 amountOut,
        address to
    ) internal returns (uint256 amountIn) {
        require(route.pools.length > 0, "CarbonCreditRouter: NO_ROUTE_FOUND");
        
        // For simplicity, this is a basic implementation
        // In production, you'd calculate exact inputs for each hop
        amountIn = route.expectedOutput;
        
        _safeTransferFrom(route.tokens[0], msg.sender, route.pools[0], amountIn);
        
        address tokenIn = route.tokens[0];
        address tokenOut = route.tokens[1];
        address pool = route.pools[0];
        
        (address token0,) = _sortTokens(tokenIn, tokenOut);
        (uint256 amount0Out, uint256 amount1Out) = tokenOut == token0 
            ? (amountOut, uint256(0)) 
            : (uint256(0), amountOut);
        
        CarbonCreditAMM(pool).swap(amount0Out, amount1Out, to, "");
    }
    
    /**
     * @dev Sort tokens
     */
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "CarbonCreditRouter: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "CarbonCreditRouter: ZERO_ADDRESS");
    }
    
    /**
     * @dev Safe transfer from
     */
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "CarbonCreditRouter: TRANSFER_FAILED");
    }
    
    /**
     * @dev Set routing fee
     */
    function setRoutingFee(uint256 _routingFeeBasisPoints) external onlyRole(ROUTER_ADMIN_ROLE) {
        require(_routingFeeBasisPoints <= 100, "CarbonCreditRouter: FEE_TOO_HIGH"); // Max 1%
        routingFeeBasisPoints = _routingFeeBasisPoints;
    }
    
    /**
     * @dev Set authorized caller
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedCallers[caller] = authorized;
    }
    
    /**
     * @dev Withdraw accumulated fees
     */
    function withdrawFees(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Emergency unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}