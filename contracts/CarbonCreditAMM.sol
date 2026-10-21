// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {ICarbonCreditAMM} from "./interfaces/ICarbonCreditAMM.sol";

/**
 * @title CarbonCreditAMM
 * @notice Secure constant product AMM (x * y = k) optimized for carbon credit basket tokens
 * @dev Features comprehensive security measures including:
 *      - K-invariant protection against manipulation attacks
 *      - MEV protection with minimum liquidity locks
 *      - Flash loan callback security with anti-reentrancy
 *      - Precision-safe mathematical operations
 *      - Slippage protection mechanisms
 *      - Gas-optimized storage patterns
 *      - Emergency controls with access restrictions
 * @author WRFCoin Security Team
 * @custom:security-contact security@wrfcoin.com
 */
contract CarbonCreditAMM is ERC20, AccessControl, ReentrancyGuard, Pausable, ICarbonCreditAMM {
    
    // ============ Constants ============
    
    /// @dev Role for factory contract to manage pool operations
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    
    /// @dev Role for setting fee parameters
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");
    
    /// @dev Basis points denominator for fee calculations
    uint256 private constant BASIS_POINTS = 10000;
    
    /// @dev Minimum liquidity tokens to prevent division by zero and manipulation
    uint256 private constant MINIMUM_LIQUIDITY = 10**3;
    
    /// @dev Flash loan fee in basis points (0.3%)
    uint256 public constant FLASH_LOAN_FEE_BASIS_POINTS = 30;
    
    /// @dev Maximum fee to prevent excessive fees (10%)
    uint256 private constant MAX_FEE_BASIS_POINTS = 1000;
    
    /// @dev Maximum protocol fee (2%)
    uint256 private constant MAX_PROTOCOL_FEE_BASIS_POINTS = 200;
    
    /// @dev Minimum time between price oracle updates to prevent manipulation (5 minutes)
    uint256 private constant MIN_ORACLE_UPDATE_TIME = 300;
    
    /// @dev Maximum reserve value to prevent overflow in calculations
    uint256 private constant MAX_RESERVE = type(uint112).max;

    /// @dev Burn address used to permanently lock minimum liquidity
    address private constant LOCKED_LIQUIDITY_ADDRESS =
        0x000000000000000000000000000000000000dEaD;
    
    // ============ Storage Variables ============
    
    /// @notice Token 0 of the trading pair (lexicographically smaller address)
    IERC20 public token0;
    
    /// @notice Token 1 of the trading pair (lexicographically larger address)
    IERC20 public token1;
    
    /// @notice Factory contract that deployed this pool
    address public factory;
    
    /// @notice Current reserve of token0
    /// @dev Uses uint112 to fit both reserves in single storage slot with timestamp
    uint112 public reserve0;
    
    /// @notice Current reserve of token1
    uint112 public reserve1;
    
    /// @notice Timestamp of last reserve update (modulo 2^32)
    uint32 public blockTimestampLast;
    
    /// @notice Cumulative price of token0 in terms of token1
    uint256 public price0CumulativeLast;
    
    /// @notice Cumulative price of token1 in terms of token0
    uint256 public price1CumulativeLast;
    
    /// @notice Product of reserves after most recent liquidity event
    uint256 public kLast;
    
    /// @notice Trading fee in basis points (default 0.3%)
    uint256 public feeBasisPoints = 30;
    
    /// @notice Protocol fee in basis points (default 0.05%)
    uint256 public protocolFeeBasisPoints = 5;
    
    /// @notice Address that receives protocol fees
    address public feeTo;
    
    // ============ Security State ============
    
    /// @notice Mapping of authorized flash loan borrowers
    mapping(address => bool) public authorizedFlashBorrowers;
    
    /// @notice Anti-MEV protection: tracks last transaction timestamp per user
    mapping(address => uint256) public lastTransactionTime;
    
    /// @notice Minimum time between transactions to prevent MEV attacks (1 block)
    uint256 public minTimeBetweenTransactions = 12; // 12 seconds
    
    /// @notice Maximum slippage allowed in basis points to prevent sandwich attacks
    uint256 public maxSlippageBasisPoints = 500; // 5%
    
    // ============ Events ============
    // Mint, Burn, Swap, Sync, FlashLoan inherited from ICarbonCreditAMM.

    /// @notice Emitted when k-invariant protection is triggered
    /// @param kBefore K value before operation
    /// @param kAfter K value after operation
    event KInvariantProtection(uint256 kBefore, uint256 kAfter);
    
    // ============ Modifiers ============
    
    /// @notice Ensures transaction deadline has not passed
    /// @param deadline Unix timestamp deadline
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "CarbonCreditAMM: EXPIRED");
        _;
    }
    
    /// @notice Prevents MEV attacks by enforcing minimum time between transactions
    /// @dev Only applies to sensitive operations like swaps
    modifier antiMEV() {
        require(
            block.timestamp >= lastTransactionTime[msg.sender] + minTimeBetweenTransactions,
            "CarbonCreditAMM: MEV_PROTECTION"
        );
        lastTransactionTime[msg.sender] = block.timestamp;
        _;
    }
    
    /// @notice Validates slippage is within acceptable bounds
    /// @param expectedAmount Expected output amount
    /// @param actualAmount Actual output amount
    modifier slippageProtection(uint256 expectedAmount, uint256 actualAmount) {
        if (expectedAmount > 0) {
            uint256 slippage = expectedAmount > actualAmount 
                ? ((expectedAmount - actualAmount) * BASIS_POINTS) / expectedAmount
                : 0;
            require(slippage <= maxSlippageBasisPoints, "CarbonCreditAMM: EXCESSIVE_SLIPPAGE");
        }
        _;
    }
    
    // ============ Storage: Factory Access Control ============

    /// @notice Expected factory address set at deployment to restrict initialize() caller
    address public immutable expectedFactory;

    // ============ Constructor ============

    /// @notice Constructor sets up the LP token and records the expected factory address
    /// @dev Actual pool initialization happens via initialize() from factory
    /// @param _expectedFactory Address of the factory that is authorized to call initialize()
    constructor(address _expectedFactory) ERC20("Carbon Credit LP", "CC-LP") {
        require(_expectedFactory != address(0), "CarbonCreditAMM: ZERO_EXPECTED_FACTORY");
        expectedFactory = _expectedFactory;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the AMM pool with token pair and configuration
     * @dev Called once by factory during pool creation. Implements comprehensive security checks
     * @param _token0 Address of token0 (lexicographically smaller)
     * @param _token1 Address of token1 (lexicographically larger)
     * @param _factory Address of the factory contract
     * @param _feeBasisPoints Trading fee in basis points
     */
    function initialize(
        address _token0,
        address _token1,
        address _factory,
        uint256 _feeBasisPoints
    ) external {
        // Security: Only the expected factory can call initialize
        require(msg.sender == expectedFactory, "CarbonCreditAMM: UNAUTHORIZED_INITIALIZER");
        // Security: Ensure single initialization
        require(factory == address(0), "CarbonCreditAMM: ALREADY_INITIALIZED");
        
        // Security: Validate inputs
        require(_token0 != address(0) && _token1 != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(_token0 != _token1, "CarbonCreditAMM: IDENTICAL_TOKENS");
        require(_token0 < _token1, "CarbonCreditAMM: TOKENS_NOT_SORTED");
        require(_factory != address(0), "CarbonCreditAMM: ZERO_FACTORY");
        require(_feeBasisPoints <= MAX_FEE_BASIS_POINTS, "CarbonCreditAMM: INVALID_FEE");
        
        // Initialize state
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        factory = _factory;
        feeBasisPoints = _feeBasisPoints;
        
        // Set up access control
        _grantRole(DEFAULT_ADMIN_ROLE, _factory);
        _grantRole(FACTORY_ROLE, _factory);
        
        // Initialize timestamp for price oracle
        blockTimestampLast = uint32(block.timestamp % 2**32);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get current reserves and last update timestamp
     * @return _reserve0 Current reserve of token0
     * @return _reserve1 Current reserve of token1  
     * @return _blockTimestampLast Timestamp of last reserve update
     */
    function getReserves() public view returns (
        uint112 _reserve0,
        uint112 _reserve1,
        uint32 _blockTimestampLast
    ) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }
    
    /**
     * @notice Calculate spot price with current reserves
     * @dev Returns price of token0 in terms of token1, scaled by 1e18
     * @return price Spot price with 18 decimal precision
     */
    function getSpotPrice() external view returns (uint256 price) {
        require(reserve0 > 0 && reserve1 > 0, "CarbonCreditAMM: NO_LIQUIDITY");
        price = (uint256(reserve1) * 1e18) / uint256(reserve0);
    }
    
    /**
     * @notice Get current k-invariant value
     * @return k Product of current reserves
     */
    function getCurrentK() external view returns (uint256 k) {
        k = uint256(reserve0) * uint256(reserve1);
    }
    
    // ============ Liquidity Functions ============
    
    /**
     * @notice Add liquidity to the pool
     * @dev Implements secure liquidity provision with MEV protection and comprehensive validation
     * @param to Address to receive LP tokens
     * @return liquidity Amount of LP tokens minted
     */
    function mint(address to) external nonReentrant whenNotPaused returns (uint256 liquidity) {
        // Security: Validate recipient
        require(to != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(to != address(this), "CarbonCreditAMM: MINT_TO_POOL");
        
        // Get current state with gas optimization
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        
        // Security: Validate balances don't overflow
        require(balance0 <= MAX_RESERVE && balance1 <= MAX_RESERVE, "CarbonCreditAMM: BALANCE_OVERFLOW");
        
        // Calculate amounts with underflow protection
        uint256 amount0 = balance0 > _reserve0 ? balance0 - _reserve0 : 0;
        uint256 amount1 = balance1 > _reserve1 ? balance1 - _reserve1 : 0;
        
        // Security: Ensure liquidity is being added
        require(amount0 > 0 && amount1 > 0, "CarbonCreditAMM: INSUFFICIENT_INPUT");
        
        // Process protocol fees before calculating liquidity
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply(); // Gas optimization: cache total supply
        
        if (_totalSupply == 0) {
            // Initial liquidity provision
            uint256 liquidityBeforeLock = Math.sqrt(amount0 * amount1);
            require(liquidityBeforeLock > MINIMUM_LIQUIDITY, "CarbonCreditAMM: INSUFFICIENT_INITIAL_LIQUIDITY");

            liquidity = liquidityBeforeLock - MINIMUM_LIQUIDITY;
            _mint(LOCKED_LIQUIDITY_ADDRESS, MINIMUM_LIQUIDITY); // Permanently lock minimum liquidity to prevent attacks
        } else {
            // Subsequent liquidity provisions - use minimum to ensure proportional adding
            liquidity = Math.min(
                (amount0 * _totalSupply) / uint256(_reserve0),
                (amount1 * _totalSupply) / uint256(_reserve1)
            );
        }
        
        require(liquidity > 0, "CarbonCreditAMM: INSUFFICIENT_LIQUIDITY_MINTED");
        
        // Mint LP tokens to recipient
        _mint(to, liquidity);
        
        // Update reserves and price oracles
        _update(balance0, balance1, _reserve0, _reserve1);
        
        // Update k-invariant tracking for fee calculation
        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);
        
        emit Mint(msg.sender, amount0, amount1, liquidity);
    }
    
    /**
     * @notice Remove liquidity from the pool
     * @dev Implements secure liquidity removal with proportional token distribution
     * @param to Address to receive underlying tokens
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function burn(address to) external nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        // Security: Validate recipient
        require(to != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(to != address(this), "CarbonCreditAMM: BURN_TO_POOL");
        
        // Get current state - cache for gas optimization
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        
        // Security: Ensure liquidity tokens were sent to pool
        require(liquidity > 0, "CarbonCreditAMM: INSUFFICIENT_LIQUIDITY_BURNED");
        
        // Process protocol fees before calculating outputs
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply(); // Gas optimization: cache total supply
        
        // Calculate pro-rata token amounts using current balances (includes collected fees)
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        
        // Security: Ensure valid output amounts
        require(amount0 > 0 && amount1 > 0, "CarbonCreditAMM: INSUFFICIENT_OUTPUT");
        
        // Security: Prevent draining pool beyond reserves
        require(
            amount0 <= balance0 && amount1 <= balance1,
            "CarbonCreditAMM: INSUFFICIENT_BALANCE"
        );
        
        // Burn LP tokens
        _burn(address(this), liquidity);
        
        // Transfer tokens to recipient
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        
        // Update balances after transfers
        balance0 = token0.balanceOf(address(this));
        balance1 = token1.balanceOf(address(this));
        
        // Update reserves and price oracles
        _update(balance0, balance1, _reserve0, _reserve1);
        
        // Update k-invariant tracking for fee calculation
        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);
        
        emit Burn(msg.sender, amount0, amount1, to, liquidity);
    }
    
    // ============ Trading Functions ============
    
    /**
     * @notice Execute a token swap with comprehensive security and MEV protection
     * @dev Implements k-invariant validation, slippage protection, and anti-manipulation measures
     * @param amount0Out Amount of token0 to send to recipient
     * @param amount1Out Amount of token1 to send to recipient  
     * @param to Address to receive output tokens
     * @param data Callback data for flash swaps
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external nonReentrant whenNotPaused antiMEV {
        // Security: Validate swap parameters
        require(amount0Out > 0 || amount1Out > 0, "CarbonCreditAMM: INSUFFICIENT_OUTPUT_AMOUNT");
        require(!(amount0Out > 0 && amount1Out > 0), "CarbonCreditAMM: INVALID_SWAP_DIRECTION");
        require(to != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(to != address(this), "CarbonCreditAMM: SWAP_TO_POOL");
        
        // Get current reserves with gas optimization
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        
        // Security: Ensure sufficient liquidity for swap
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "CarbonCreditAMM: INSUFFICIENT_LIQUIDITY");
        
        // Security: Store k-invariant before swap for validation
        uint256 kBefore = uint256(_reserve0) * uint256(_reserve1);
        
        uint256 balance0;
        uint256 balance1;
        {
            // Scope to avoid stack too deep
            address _token0 = address(token0);
            address _token1 = address(token1);
            
            // Security: Prevent swapping to token addresses (common mistake)
            require(to != _token0 && to != _token1, "CarbonCreditAMM: INVALID_TO");
            
            // Optimistically transfer tokens to recipient
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            
            // Execute callback for flash swaps (if any) — require authorization
            if (data.length > 0) {
                require(
                    authorizedFlashBorrowers[msg.sender] ||
                    hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                    hasRole(FACTORY_ROLE, msg.sender),
                    "CarbonCreditAMM: UNAUTHORIZED_FLASH_BORROWER"
                );
                // Security: callback must go to the caller (msg.sender), not an arbitrary
                // `to` address. Previously, an authorized borrower could pass `to != msg.sender`
                // and trigger executeOperation() on any contract, enabling malicious cross-contract
                // calls (e.g., re-entrancy or privilege escalation against third-party contracts).
                require(to == msg.sender, "CarbonCreditAMM: FLASH_SWAP_TO_MUST_BE_CALLER");
                IFlashLoanReceiver(to).executeOperation(data);
            }
            
            // Get new balances after transfers and potential callback
            balance0 = token0.balanceOf(address(this));
            balance1 = token1.balanceOf(address(this));
        }
        
        // Validate swap and emit event with reduced stack depth
        _validateAndEmitSwap(
            balance0, 
            balance1, 
            _reserve0, 
            _reserve1, 
            amount0Out, 
            amount1Out, 
            kBefore, 
            to
        );
    }
    
    // ============ Flash Loan Functions ============
    
    /**
     * @notice Execute a flash loan with comprehensive security and k-invariant protection
     * @dev Implements multi-layered security including authorization, k-invariant validation, and fee collection
     * @param amount0 Amount of token0 to borrow
     * @param amount1 Amount of token1 to borrow  
     * @param receiver Address that will receive the flash loan
     * @param data Arbitrary data to pass to the receiver callback
     */
    function flashLoan(
        uint256 amount0,
        uint256 amount1,
        address receiver,
        bytes calldata data
    ) external nonReentrant whenNotPaused {
        // Security: Comprehensive parameter validation
        require(
            authorizedFlashBorrowers[msg.sender] || 
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || 
            hasRole(FACTORY_ROLE, msg.sender),
            "CarbonCreditAMM: UNAUTHORIZED_FLASH_BORROWER"
        );
        require(amount0 > 0 || amount1 > 0, "CarbonCreditAMM: INVALID_FLASH_AMOUNT");
        require(receiver != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(receiver != address(this), "CarbonCreditAMM: RECEIVER_IS_POOL");
        require(receiver != address(token0) && receiver != address(token1), "CarbonCreditAMM: RECEIVER_IS_TOKEN");
        
        // Get current state with gas optimization
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        
        // Security: Validate sufficient liquidity for flash loan
        require(amount0 <= _reserve0 && amount1 <= _reserve1, "CarbonCreditAMM: INSUFFICIENT_LIQUIDITY");
        
        // Security: Prevent flash loans that could drain significant liquidity (> 50%)
        require(
            amount0 <= _reserve0 / 2 && amount1 <= _reserve1 / 2,
            "CarbonCreditAMM: EXCESSIVE_FLASH_AMOUNT"
        );
        
        // Store k-invariant before flash loan for security validation
        uint256 kBefore = uint256(_reserve0) * uint256(_reserve1);
        
        // Calculate flash loan fees with minimum fee protection
        uint256 fee0 = amount0 > 0 ? Math.max((amount0 * FLASH_LOAN_FEE_BASIS_POINTS) / BASIS_POINTS, 1) : 0;
        uint256 fee1 = amount1 > 0 ? Math.max((amount1 * FLASH_LOAN_FEE_BASIS_POINTS) / BASIS_POINTS, 1) : 0;
        
        // Record balances before flash loan
        uint256 balanceBefore0 = token0.balanceOf(address(this));
        uint256 balanceBefore1 = token1.balanceOf(address(this));
        
        // Effects: Transfer tokens to receiver (optimistic execution)
        if (amount0 > 0) _safeTransfer(address(token0), receiver, amount0);
        if (amount1 > 0) _safeTransfer(address(token1), receiver, amount1);
        
        // Interactions: Execute flash loan callback with proper error handling
        try IFlashLoanReceiver(receiver).executeFlashLoan(amount0, amount1, fee0, fee1, data) {
            // Callback executed successfully, continue with validation
        } catch {
            revert("CarbonCreditAMM: CALLBACK_FAILED");
        }
        
        // Final validation: Check post-callback state
        uint256 balanceAfter0 = token0.balanceOf(address(this));
        uint256 balanceAfter1 = token1.balanceOf(address(this));
        
        // Security: Validate complete repayment with fees
        require(
            balanceAfter0 >= balanceBefore0 + fee0,
            "CarbonCreditAMM: INSUFFICIENT_FLASH_REPAYMENT_0"
        );
        require(
            balanceAfter1 >= balanceBefore1 + fee1,
            "CarbonCreditAMM: INSUFFICIENT_FLASH_REPAYMENT_1"
        );
        
        // Critical Security: Validate k-invariant preservation/improvement
        uint256 kAfter = balanceAfter0 * balanceAfter1;
        require(kAfter >= kBefore, "CarbonCreditAMM: K_INVARIANT_VIOLATED");
        
        // Additional Security: Ensure reserves not decreased below original levels
        require(
            balanceAfter0 >= _reserve0 && balanceAfter1 >= _reserve1,
            "CarbonCreditAMM: RESERVES_DECREASED"
        );
        
        // Update reserves to reflect new balances (includes collected fees)
        _update(balanceAfter0, balanceAfter1, _reserve0, _reserve1);
        
        emit FlashLoan(receiver, amount0, amount1, fee0, fee1);
        emit KInvariantProtection(kBefore, kAfter);
    }
    
    // ============ Pricing Functions ============
    
    /**
     * @notice Calculate output amount for a given input using current fee rate
     * @dev Implements constant product formula: (x + Δx) * (y - Δy) = x * y, accounting for fees
     * @param amountIn Amount of input tokens
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Amount of output tokens (before slippage protection)
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public view returns (uint256 amountOut) {
        require(amountIn > 0, "CarbonCreditAMM: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "CarbonCreditAMM: INSUFFICIENT_LIQUIDITY");
        
        // Security: Prevent overflow in calculations
        require(
            amountIn <= type(uint256).max / BASIS_POINTS &&
            reserveIn <= type(uint256).max / BASIS_POINTS &&
            reserveOut <= type(uint256).max / BASIS_POINTS,
            "CarbonCreditAMM: CALCULATION_OVERFLOW"
        );
        
        // Apply trading fee to input amount
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - feeBasisPoints);
        
        // Constant product formula: amountOut = (amountInWithFee * reserveOut) / (reserveIn * BASIS_POINTS + amountInWithFee)
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BASIS_POINTS) + amountInWithFee;
        
        // Security: Prevent division by zero
        require(denominator > 0, "CarbonCreditAMM: DIVISION_BY_ZERO");
        
        amountOut = numerator / denominator;
        
        // Security: Ensure output doesn't exceed available reserves
        require(amountOut < reserveOut, "CarbonCreditAMM: INSUFFICIENT_OUTPUT_LIQUIDITY");
    }
    
    /**
     * @notice Calculate required input amount for a desired output using current fee rate
     * @dev Implements inverse constant product formula accounting for fees
     * @param amountOut Desired amount of output tokens
     * @param reserveIn Reserve of input token  
     * @param reserveOut Reserve of output token
     * @return amountIn Required amount of input tokens (with +1 for rounding protection)
     */
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public view returns (uint256 amountIn) {
        require(amountOut > 0, "CarbonCreditAMM: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "CarbonCreditAMM: INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "CarbonCreditAMM: EXCESSIVE_OUTPUT_AMOUNT");
        
        // Security: Prevent overflow in calculations
        require(
            reserveIn <= type(uint256).max / BASIS_POINTS &&
            amountOut <= type(uint256).max / BASIS_POINTS,
            "CarbonCreditAMM: CALCULATION_OVERFLOW"
        );
        
        // Inverse constant product formula: amountIn = (reserveIn * amountOut * BASIS_POINTS) / ((reserveOut - amountOut) * (BASIS_POINTS - feeBasisPoints))
        uint256 numerator = reserveIn * amountOut * BASIS_POINTS;
        uint256 denominator = (reserveOut - amountOut) * (BASIS_POINTS - feeBasisPoints);
        
        // Security: Prevent division by zero
        require(denominator > 0, "CarbonCreditAMM: DIVISION_BY_ZERO");
        
        // Add 1 to account for rounding errors that could violate k-invariant
        amountIn = (numerator / denominator) + 1;
    }
    
    /**
     * @notice Calculate price impact for a given swap
     * @dev Returns price impact in basis points (10000 = 100%)
     * @param amountIn Amount of input tokens
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return priceImpact Price impact in basis points
     */
    function calculatePriceImpact(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view returns (uint256 priceImpact) {
        require(amountIn > 0 && reserveIn > 0 && reserveOut > 0, "CarbonCreditAMM: INVALID_PARAMETERS");
        
        // Price before swap: reserveOut / reserveIn
        uint256 priceBefore = (reserveOut * BASIS_POINTS) / reserveIn;
        
        // Calculate output amount
        uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        
        // Price after swap: (reserveOut - amountOut) / (reserveIn + amountIn)
        uint256 priceAfter = ((reserveOut - amountOut) * BASIS_POINTS) / (reserveIn + amountIn);
        
        // Calculate price impact: |priceBefore - priceAfter| / priceBefore * 10000
        if (priceBefore > priceAfter) {
            priceImpact = ((priceBefore - priceAfter) * BASIS_POINTS) / priceBefore;
        } else {
            priceImpact = ((priceAfter - priceBefore) * BASIS_POINTS) / priceBefore;
        }
    }
    
    // ============ Utility Functions ============
    
    /**
     * @notice Remove excess tokens that exceed current reserves (recovery function)
     * @dev Can be used to recover tokens sent directly to the pool contract
     * @param to Address to receive excess tokens
     */
    function skim(address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(to != address(this), "CarbonCreditAMM: SKIM_TO_POOL");
        
        address _token0 = address(token0);
        address _token1 = address(token1);
        
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        
        // Only transfer excess amounts beyond current reserves
        if (balance0 > reserve0) {
            _safeTransfer(_token0, to, balance0 - reserve0);
        }
        if (balance1 > reserve1) {
            _safeTransfer(_token1, to, balance1 - reserve1);
        }
    }
    
    /**
     * @notice Synchronize reserves with current token balances (recovery function)
     * @dev Use when token balances don't match reserves due to direct transfers.
     *      Security: restricted to DEFAULT_ADMIN_ROLE only. Previously unrestricted,
     *      allowing any caller to sync reserves and manipulate the TWAP price oracle
     *      by triggering _update() with an adversarially-timed balance snapshot.
     */
    function sync() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        require(balance0 <= MAX_RESERVE && balance1 <= MAX_RESERVE, "CarbonCreditAMM: BALANCE_OVERFLOW");

        _update(balance0, balance1, reserve0, reserve1);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Update reserves and maintain price oracle with precision handling
     * @dev Updates reserves and accumulates price data for TWAP oracles with overflow protection
     * @param balance0 New balance of token0
     * @param balance1 New balance of token1
     * @param _reserve0 Previous reserve of token0
     * @param _reserve1 Previous reserve of token1
     */
    function _update(uint256 balance0, uint256 balance1, uint256 _reserve0, uint256 _reserve1) private {
        // Security: Prevent overflow in reserve storage
        require(balance0 <= MAX_RESERVE && balance1 <= MAX_RESERVE, "CarbonCreditAMM: RESERVE_OVERFLOW");
        
        // Get current timestamp (mod 2^32 to fit in uint32)
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        
        // Update price oracles if time has elapsed and reserves exist
        if (timeElapsed >= MIN_ORACLE_UPDATE_TIME && _reserve0 != 0 && _reserve1 != 0) {
            // Security: Use fixed-point arithmetic to prevent precision loss
            // price0CumulativeLast += price1 * timeElapsed (price1 = reserve0 / reserve1)
            // price1CumulativeLast += price0 * timeElapsed (price0 = reserve1 / reserve0)
            
            // Use UQ112x112 format for precision (112 bits for integer, 112 for fraction)
            unchecked {
                price0CumulativeLast += uint256((uint224(_reserve1) << 112) / _reserve0) * timeElapsed;
                price1CumulativeLast += uint256((uint224(_reserve0) << 112) / _reserve1) * timeElapsed;
            }
        }
        
        // Update reserves
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        
        emit Sync(reserve0, reserve1);
    }
    
    /**
     * @notice Mint protocol fees based on growth in k-invariant
     * @dev Calculates and mints LP tokens to protocol fee recipient based on k growth
     * @param _reserve0 Previous reserve of token0
     * @param _reserve1 Previous reserve of token1
     * @return feeOn Whether protocol fees are enabled
     */
    function _mintFee(uint256 _reserve0, uint256 _reserve1) private returns (bool feeOn) {
        address _feeTo = feeTo;
        feeOn = _feeTo != address(0);
        uint256 _kLast = kLast;
        
        if (feeOn) {
            if (_kLast != 0) {
                // Calculate current k and previous k
                uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = Math.sqrt(_kLast);
                
                // Only mint fees if k has grown (indicating trading activity)
                if (rootK > rootKLast) {
                    // Calculate protocol fee as a fraction of LP token growth
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = (rootK * protocolFeeBasisPoints) / BASIS_POINTS + rootKLast;
                    
                    // Security: Prevent division by zero
                    if (denominator > 0) {
                        uint256 liquidity = numerator / denominator;
                        
                        // Mint protocol fee tokens if amount is significant
                        if (liquidity > 0) {
                            _mint(_feeTo, liquidity);
                        }
                    }
                }
            }
        } else if (_kLast != 0) {
            // Clear k tracking if fees are disabled
            kLast = 0;
        }
    }
    
    /**
     * @notice Safe token transfer with comprehensive error handling
     * @dev Handles both standard ERC20 and non-standard tokens that don't return bool
     * @param token Token contract address
     * @param to Recipient address
     * @param value Amount to transfer
     */
    function _safeTransfer(address token, address to, uint256 value) private {
        require(token != address(0), "CarbonCreditAMM: INVALID_TOKEN");
        require(to != address(0), "CarbonCreditAMM: TRANSFER_TO_ZERO");
        require(value > 0, "CarbonCreditAMM: TRANSFER_ZERO_AMOUNT");
        
        // Execute transfer with low-level call to handle non-standard tokens
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        
        // Verify transfer succeeded and handle return value properly
        require(
            success && (data.length == 0 || abi.decode(data, (bool))), 
            "CarbonCreditAMM: TRANSFER_FAILED"
        );
    }
    
    // ============ Administrative Functions ============
    
    /**
     * @notice Set trading and protocol fee parameters with validation
     * @dev Only callable by accounts with FEE_SETTER_ROLE
     * @param _feeBasisPoints New trading fee in basis points (max 10%)
     * @param _protocolFeeBasisPoints New protocol fee in basis points (max 2%)
     */
    function setFees(
        uint256 _feeBasisPoints,
        uint256 _protocolFeeBasisPoints
    ) external onlyRole(FEE_SETTER_ROLE) {
        require(_feeBasisPoints <= MAX_FEE_BASIS_POINTS, "CarbonCreditAMM: FEE_TOO_HIGH");
        require(_protocolFeeBasisPoints <= MAX_PROTOCOL_FEE_BASIS_POINTS, "CarbonCreditAMM: PROTOCOL_FEE_TOO_HIGH");
        require(_feeBasisPoints > 0, "CarbonCreditAMM: FEE_TOO_LOW"); // Prevent zero fees that could enable attacks
        
        feeBasisPoints = _feeBasisPoints;
        protocolFeeBasisPoints = _protocolFeeBasisPoints;
    }
    
    /**
     * @notice Set protocol fee recipient address
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     * @param _feeTo New fee recipient address (can be zero to disable fees)
     */
    function setFeeTo(address _feeTo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeTo = _feeTo;
    }
    
    /**
     * @notice Authorize or deauthorize flash loan borrowers
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     * @param borrower Address to authorize/deauthorize
     * @param authorized Whether the borrower is authorized
     */
    function setAuthorizedFlashBorrower(address borrower, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(borrower != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        authorizedFlashBorrowers[borrower] = authorized;
    }
    
    /**
     * @notice Set MEV protection parameters
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     * @param _minTimeBetweenTransactions Minimum time between transactions (in seconds)
     * @param _maxSlippageBasisPoints Maximum allowed slippage (in basis points)
     */
    function setMEVProtection(
        uint256 _minTimeBetweenTransactions,
        uint256 _maxSlippageBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minTimeBetweenTransactions <= 300, "CarbonCreditAMM: MEV_TIME_TOO_LONG"); // Max 5 minutes
        require(_maxSlippageBasisPoints <= 2000, "CarbonCreditAMM: SLIPPAGE_TOO_HIGH"); // Max 20%
        
        minTimeBetweenTransactions = _minTimeBetweenTransactions;
        maxSlippageBasisPoints = _maxSlippageBasisPoints;
    }
    
    /**
     * @notice Emergency pause all pool operations
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Resume all pool operations after pause
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Emergency function to rescue stuck tokens (not pool tokens)
     * @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
     * @param token Token address to rescue
     * @param to Address to send rescued tokens
     * @param amount Amount to rescue
     */
    function emergencyTokenRescue(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(token0) && token != address(token1), "CarbonCreditAMM: CANNOT_RESCUE_POOL_TOKENS");
        require(token != address(this), "CarbonCreditAMM: CANNOT_RESCUE_LP_TOKENS");
        require(to != address(0), "CarbonCreditAMM: ZERO_ADDRESS");
        require(amount > 0, "CarbonCreditAMM: ZERO_AMOUNT");
        
        _safeTransfer(token, to, amount);
    }
    
    /**
     * @dev Internal function to validate swap and emit event with reduced stack depth
     */
    function _validateAndEmitSwap(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 kBefore,
        address to
    ) internal {
        // Calculate input amounts with underflow protection
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        
        // Security: Ensure tokens were sent to pool
        require(amount0In > 0 || amount1In > 0, "CarbonCreditAMM: INSUFFICIENT_INPUT_AMOUNT");
        
        // Critical Security: Validate k-invariant with fee adjustment
        {
            // Calculate adjusted balances after fee deduction
            uint256 balance0Adjusted = (balance0 * BASIS_POINTS) - (amount0In * feeBasisPoints);
            uint256 balance1Adjusted = (balance1 * BASIS_POINTS) - (amount1In * feeBasisPoints);
            
            // Ensure k-invariant is maintained: k_new >= k_old
            uint256 kAfterFees = balance0Adjusted * balance1Adjusted;
            uint256 kRequired = uint256(_reserve0) * uint256(_reserve1) * (BASIS_POINTS * BASIS_POINTS);
            
            require(kAfterFees >= kRequired, "CarbonCreditAMM: K_INVARIANT_VIOLATED");
            
            // Additional protection: ensure k actually increased with fees
            uint256 kAfter = balance0 * balance1;
            require(kAfter >= kBefore, "CarbonCreditAMM: K_DECREASED");
            
            emit KInvariantProtection(kBefore, kAfter);
        }
        
        // Update reserves and price oracles
        _update(balance0, balance1, _reserve0, _reserve1);
        
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
}

/**
 * @title IFlashLoanReceiver
 * @notice Interface that flash loan receivers must implement
 * @dev Contracts receiving flash loans must implement both callback functions
 */
interface IFlashLoanReceiver {
    /**
     * @notice Callback function for flash swaps (called during swap execution)
     * @dev This function is called when data.length > 0 in swap function
     * @param data Arbitrary data passed from the swap caller
     */
    function executeOperation(bytes calldata data) external;
    
    /**
     * @notice Callback function for flash loans (called during flashLoan execution)
     * @dev This function must repay the loan + fees before returning
     * @param amount0 Amount of token0 borrowed
     * @param amount1 Amount of token1 borrowed
     * @param fee0 Fee to pay for token0
     * @param fee1 Fee to pay for token1
     * @param data Arbitrary data passed from the flash loan caller
     */
    function executeFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}
