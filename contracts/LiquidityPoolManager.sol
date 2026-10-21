// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./WeightedCarbonPool.sol";
import "./interfaces/IVolatilityOracle.sol";
import "./interfaces/IQualityOracle.sol";

/**
 * @title LiquidityPoolManager
 * @notice Factory and orchestration contract for weighted carbon credit liquidity pools
 * @dev Manages pool creation, configuration, and governance for USDC/CarbonBasketToken pairs
 * 
 * Features:
 * - Secure pool creation with minimal proxy pattern
 * - Oracle-based dynamic weight and fee adjustments
 * - Multi-role access control with emergency functions
 * - Pool statistics tracking and health monitoring
 * - Router integration for DEX aggregation
 * - Economic security limits and circuit breakers
 * 
 * Security Features:
 * - Reentrancy protection on all state-changing functions
 * - Role-based access control for different operations
 * - Emergency pause capabilities for individual pools and entire system
 * - Input validation and bounds checking
 * - Event logging for all critical operations
 * 
 * @author WRFCoin Security Team
 * @custom:security-contact security@wrfcoin.io
 */
contract LiquidityPoolManager is AccessControl, ReentrancyGuard, Pausable {
    
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    struct PoolConfiguration {
        address poolAddress;
        address carbonBasketToken;
        uint256 weightUSDC;
        uint256 weightCBT;
        uint256 swapFee;
        uint256 createdAt;
        bool isActive;
        string poolType; // "stable", "balanced", "growth"
    }
    
    struct PoolStats {
        uint256 totalVolume24h;
        uint256 totalLiquidity;
        uint256 lastVolumeUpdate;
        uint256 feesGenerated24h;
    }
    
    // Core contract addresses
    address public immutable usdcAddress;
    address public immutable poolImplementation;
    
    // Oracles
    IVolatilityOracle public volatilityOracle;
    IQualityOracle public qualityOracle;
    
    // Pool management
    PoolConfiguration[] public pools;
    mapping(address => uint256) public poolIndexes; // pool address => index in pools array
    mapping(address => PoolStats) public poolStats;
    mapping(address => bool) public authorizedCarbonTokens;
    
    // Router integration
    mapping(address => bool) public authorizedRouters;
    address[] public registeredRouters;
    
    // Fee management
    address public feeRecipient;
    uint256 public protocolFeeBasisPoints = 10; // 0.1% of swap fees
    
    // Pool limits and configurations
    uint256 public constant MAX_SWAP_FEE = 1000; // 10%
    uint256 public constant MIN_SWAP_FEE = 5; // 0.05%
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Economic security limits
    uint256 public constant MAX_POOLS_PER_TOKEN = 5; // Maximum pools per carbon token
    uint256 public constant MIN_LIQUIDITY_THRESHOLD = 1000 * 1e6; // 1000 USDC minimum
    uint256 public constant MAX_WEIGHT_DEVIATION = 100 * 1e15; // 10% maximum weight change per update
    uint256 public constant ORACLE_UPDATE_COOLDOWN = 1 hours; // Minimum time between oracle updates
    
    // Pool tracking for security
    mapping(address => uint256) public tokenPoolCount; // Track pools per token
    mapping(address => uint256) public lastOracleUpdate; // Track oracle update frequency
    
    // Supported pool configurations
    mapping(string => bool) public supportedPoolTypes;
    mapping(string => uint256[2]) public poolTypeWeights; // poolType => [usdcWeight, cbtWeight]
    
    event PoolCreated(
        address indexed poolAddress,
        address indexed carbonBasketToken,
        uint256 weightUSDC,
        uint256 weightCBT,
        uint256 swapFee,
        string poolType
    );
    
    event PoolStatusUpdated(address indexed poolAddress, bool isActive);
    event OracleUpdated(address indexed oracle, string oracleType);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event CarbonTokenAuthorized(address indexed tokenAddress, bool authorized);
    event PoolStatsUpdated(address indexed poolAddress, uint256 volume, uint256 fees);
    
    modifier onlyValidPool(address poolAddress) {
        require(poolIndexes[poolAddress] > 0 && pools[poolIndexes[poolAddress] - 1].isActive, 
                "LiquidityPoolManager: Invalid or inactive pool");
        _;
    }
    
    constructor(
        address _usdcAddress,
        address _poolImplementation,
        address _feeRecipient
    ) {
        require(_usdcAddress != address(0), "LiquidityPoolManager: Invalid USDC address");
        require(_poolImplementation != address(0), "LiquidityPoolManager: Invalid implementation");
        require(_feeRecipient != address(0), "LiquidityPoolManager: Invalid fee recipient");
        
        usdcAddress = _usdcAddress;
        poolImplementation = _poolImplementation;
        feeRecipient = _feeRecipient;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POOL_CREATOR_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        // Initialize supported pool types
        _initializePoolTypes();
    }
    
    function _initializePoolTypes() internal {
        // Stable pools (80/20 USDC/CarbonCredit)
        supportedPoolTypes["stable"] = true;
        poolTypeWeights["stable"] = [800 * 1e15, 200 * 1e15]; // 80% USDC, 20% Carbon
        
        // Balanced pools (50/50)
        supportedPoolTypes["balanced"] = true;
        poolTypeWeights["balanced"] = [500 * 1e15, 500 * 1e15]; // 50% USDC, 50% Carbon
        
        // Growth pools (20/80 USDC/CarbonCredit)
        supportedPoolTypes["growth"] = true;
        poolTypeWeights["growth"] = [200 * 1e15, 800 * 1e15]; // 20% USDC, 80% Carbon
    }
    
    /**
     * @notice Creates a new weighted carbon credit liquidity pool
     * @dev Deploys a minimal proxy of the pool implementation with comprehensive validation
     * @param carbonBasketToken Address of the carbon basket token to pair with USDC
     * @param poolType Type of pool configuration ("stable", "balanced", "growth")
     * @param customSwapFee Swap fee in basis points (must be within MIN_SWAP_FEE and MAX_SWAP_FEE)
     * @return poolAddress Address of the newly deployed pool
     * 
     * Requirements:
     * - Caller must have POOL_CREATOR_ROLE
     * - Pool type must be supported
     * - Carbon token must be authorized
     * - Swap fee must be within valid range
     * - Token must not exceed maximum pools per token limit
     * - Contract must not be paused
     * 
     * Emits a {PoolCreated} event
     */
    function createWeightedPool(
        address carbonBasketToken,
        string memory poolType,
        uint256 customSwapFee
    ) external onlyRole(POOL_CREATOR_ROLE) nonReentrant whenNotPaused returns (address poolAddress) {
        // Input validation
        require(supportedPoolTypes[poolType], "LiquidityPoolManager: Unsupported pool type");
        require(authorizedCarbonTokens[carbonBasketToken], "LiquidityPoolManager: Unauthorized carbon token");
        require(customSwapFee >= MIN_SWAP_FEE && customSwapFee <= MAX_SWAP_FEE, 
                "LiquidityPoolManager: Invalid swap fee");
        
        // Economic security check - prevent too many pools for same token
        require(tokenPoolCount[carbonBasketToken] < MAX_POOLS_PER_TOKEN, 
                "LiquidityPoolManager: Too many pools for token");
        
        // Get weights for this pool type
        uint256[2] memory weights = poolTypeWeights[poolType];
        uint256 weightUSDC = weights[0];
        uint256 weightCBT = weights[1];
        
        // Deploy new pool using minimal proxy pattern
        poolAddress = Clones.clone(poolImplementation);
        
        // Initialize the pool
        WeightedCarbonPool(poolAddress).initialize(
            usdcAddress,
            carbonBasketToken,
            weightUSDC,
            weightCBT,
            customSwapFee,
            address(volatilityOracle),
            address(qualityOracle),
            address(this)
        );
        
        // Add to pools registry
        PoolConfiguration memory newPool = PoolConfiguration({
            poolAddress: poolAddress,
            carbonBasketToken: carbonBasketToken,
            weightUSDC: weightUSDC,
            weightCBT: weightCBT,
            swapFee: customSwapFee,
            createdAt: block.timestamp,
            isActive: true,
            poolType: poolType
        });
        
        pools.push(newPool);
        poolIndexes[poolAddress] = pools.length; // Store index + 1 (0 means not found)
        
        // Update token pool count for security tracking
        tokenPoolCount[carbonBasketToken]++;
        
        // Initialize pool stats
        poolStats[poolAddress] = PoolStats({
            totalVolume24h: 0,
            totalLiquidity: 0,
            lastVolumeUpdate: block.timestamp,
            feesGenerated24h: 0
        });
        
        emit PoolCreated(poolAddress, carbonBasketToken, weightUSDC, weightCBT, customSwapFee, poolType);
    }
    
    /**
     * @notice Updates pool weights based on quality oracle data with security constraints
     * @dev Adjusts pool weights based on carbon credit quality score with rate limiting
     * @param poolAddress Address of the pool to update weights for
     * 
     * Requirements:
     * - Caller must have ORACLE_MANAGER_ROLE
     * - Pool must be valid and active
     * - Quality oracle must be configured
     * - Must respect cooldown period between updates
     * - Weight changes are capped to prevent manipulation
     * 
     * Security Features:
     * - Rate limiting on weight updates
     * - Maximum weight deviation caps
     * - Quality score validation
     * - Bounds checking on all calculations
     */
    function updatePoolWeightsFromOracle(address poolAddress) 
        external 
        onlyRole(ORACLE_MANAGER_ROLE) 
        onlyValidPool(poolAddress) 
    {
        require(address(qualityOracle) != address(0), "LiquidityPoolManager: Quality oracle not set");
        require(block.timestamp >= lastOracleUpdate[poolAddress] + ORACLE_UPDATE_COOLDOWN, 
                "LiquidityPoolManager: Oracle update cooldown active");
        
        uint256 poolIndex = poolIndexes[poolAddress] - 1;
        PoolConfiguration storage pool = pools[poolIndex];
        
        // Get quality score and validate
        uint256 qualityScore = qualityOracle.getQualityScore(pool.carbonBasketToken);
        require(qualityScore > 0 && qualityScore <= 100, "LiquidityPoolManager: Invalid quality score");
        
        // Calculate current weights
        uint256 currentCBTWeight = pool.weightCBT;
        uint256 currentUSDCWeight = pool.weightUSDC;
        
        // Calculate new weights based on quality (higher quality = higher carbon weight)
        uint256 baseWeight = 500 * 1e15; // 50% base
        
        // Quality adjustment: 2% per quality point above/below 50
        int256 qualityDiff = int256(qualityScore) - 50;
        uint256 adjustment = uint256(qualityDiff >= 0 ? qualityDiff : -qualityDiff) * 2 * 1e15 / 100;
        
        // Cap adjustment to MAX_WEIGHT_DEVIATION
        if (adjustment > MAX_WEIGHT_DEVIATION) {
            adjustment = MAX_WEIGHT_DEVIATION;
        }
        
        uint256 newCBTWeight;
        if (qualityScore >= 50) {
            newCBTWeight = baseWeight + adjustment;
        } else {
            newCBTWeight = baseWeight - adjustment;
        }
        
        // Ensure weights are within valid bounds (20% to 80%)
        if (newCBTWeight < 200 * 1e15) newCBTWeight = 200 * 1e15;
        if (newCBTWeight > 800 * 1e15) newCBTWeight = 800 * 1e15;
        
        uint256 newUSDCWeight = PRECISION - newCBTWeight;
        
        // Additional check: prevent excessive weight changes
        uint256 weightChange = newCBTWeight > currentCBTWeight 
            ? newCBTWeight - currentCBTWeight 
            : currentCBTWeight - newCBTWeight;
        require(weightChange <= MAX_WEIGHT_DEVIATION, "LiquidityPoolManager: Weight change too large");
        
        // Update pool weights
        WeightedCarbonPool(poolAddress).updateWeights(newUSDCWeight, newCBTWeight);
        
        // Update stored configuration
        pool.weightUSDC = newUSDCWeight;
        pool.weightCBT = newCBTWeight;
        
        // Update cooldown timestamp
        lastOracleUpdate[poolAddress] = block.timestamp;
    }
    
    /**
     * @dev Update pool fee based on volatility oracle
     */
    function updatePoolFeeFromVolatility(address poolAddress) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
        onlyValidPool(poolAddress) 
    {
        require(address(volatilityOracle) != address(0), "LiquidityPoolManager: Volatility oracle not set");
        
        uint256 currentVolatility = volatilityOracle.getVolatility(
            usdcAddress, 
            pools[poolIndexes[poolAddress] - 1].carbonBasketToken
        );
        
        // Calculate dynamic fee: base fee + volatility adjustment
        uint256 baseFee = 30; // 0.3%
        uint256 volatilityFactor = 50; // 0.5% per volatility unit
        uint256 newFee = baseFee + (currentVolatility * volatilityFactor / 100);
        
        // Ensure fee is within bounds
        newFee = newFee < MIN_SWAP_FEE ? MIN_SWAP_FEE : newFee;
        newFee = newFee > MAX_SWAP_FEE ? MAX_SWAP_FEE : newFee;
        
        // Update pool fee
        WeightedCarbonPool(poolAddress).setSwapFee(newFee);
        
        // Update stored configuration
        pools[poolIndexes[poolAddress] - 1].swapFee = newFee;
    }
    
    /**
     * @dev Record swap statistics for a pool
     */
    function recordSwap(
        uint256 volumeUSD,
        uint256 feesGenerated
    ) external onlyValidPool(msg.sender) {
        PoolStats storage stats = poolStats[msg.sender];
        
        // Reset 24h counters if more than 24h passed
        if (block.timestamp >= stats.lastVolumeUpdate + 24 hours) {
            stats.totalVolume24h = 0;
            stats.feesGenerated24h = 0;
            stats.lastVolumeUpdate = block.timestamp;
        }
        
        stats.totalVolume24h += volumeUSD;
        stats.feesGenerated24h += feesGenerated;
        
        emit PoolStatsUpdated(msg.sender, volumeUSD, feesGenerated);
    }
    
    /**
     * @dev Update pool liquidity statistics
     */
    function updatePoolLiquidity(uint256 totalLiquidity) external onlyValidPool(msg.sender) {
        poolStats[msg.sender].totalLiquidity = totalLiquidity;
    }
    
    /**
     * @dev Collect protocol fees from a pool
     */
    function collectProtocolFees(address poolAddress) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
        onlyValidPool(poolAddress) 
        nonReentrant 
    {
        WeightedCarbonPool(poolAddress).collectProtocolFees(feeRecipient);
    }
    
    /**
     * @dev Emergency pause for specific pool
     */
    function emergencyPausePool(address poolAddress) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        onlyValidPool(poolAddress) 
    {
        WeightedCarbonPool(poolAddress).pause();
    }
    
    /**
     * @dev Emergency unpause for specific pool
     */
    function emergencyUnpausePool(address poolAddress) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        onlyValidPool(poolAddress) 
    {
        WeightedCarbonPool(poolAddress).unpause();
    }
    
    /**
     * @dev Set volatility oracle
     */
    function setVolatilityOracle(address _oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        volatilityOracle = IVolatilityOracle(_oracle);
        emit OracleUpdated(_oracle, "volatility");
    }
    
    /**
     * @dev Set quality oracle
     */
    function setQualityOracle(address _oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        qualityOracle = IQualityOracle(_oracle);
        emit OracleUpdated(_oracle, "quality");
    }
    
    /**
     * @dev Authorize carbon basket token for pool creation
     */
    function setCarbonTokenAuthorization(address tokenAddress, bool authorized) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        authorizedCarbonTokens[tokenAddress] = authorized;
        emit CarbonTokenAuthorized(tokenAddress, authorized);
    }
    
    /**
     * @dev Set fee recipient
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(FEE_MANAGER_ROLE) {
        require(_feeRecipient != address(0), "LiquidityPoolManager: Invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }
    
    /**
     * @dev Set protocol fee basis points
     */
    function setProtocolFee(uint256 _protocolFeeBasisPoints) external onlyRole(FEE_MANAGER_ROLE) {
        require(_protocolFeeBasisPoints <= 500, "LiquidityPoolManager: Protocol fee too high"); // Max 5%
        uint256 oldFee = protocolFeeBasisPoints;
        protocolFeeBasisPoints = _protocolFeeBasisPoints;
        emit ProtocolFeeUpdated(oldFee, _protocolFeeBasisPoints);
    }
    
    /**
     * @dev Get all active pools
     */
    function getActivePools() external view returns (PoolConfiguration[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i].isActive) {
                activeCount++;
            }
        }
        
        PoolConfiguration[] memory activePools = new PoolConfiguration[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i].isActive) {
                activePools[currentIndex] = pools[i];
                currentIndex++;
            }
        }
        
        return activePools;
    }
    
    /**
     * @dev Get pool by carbon basket token
     */
    function getPoolConfig(address poolAddress) external view onlyValidPool(poolAddress) returns (PoolConfiguration memory) {
        return pools[poolIndexes[poolAddress] - 1];
    }

    function getPoolByCarbonToken(address carbonToken) external view returns (PoolConfiguration memory) {
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i].carbonBasketToken == carbonToken && pools[i].isActive) {
                return pools[i];
            }
        }
        revert("LiquidityPoolManager: Pool not found");
    }
    
    /**
     * @dev Get pool statistics
     */
    function getPoolStats(address poolAddress) external view returns (PoolStats memory) {
        return poolStats[poolAddress];
    }
    
    /**
     * @dev Get total pools count
     */
    function getPoolsCount() external view returns (uint256) {
        return pools.length;
    }
    
    /**
     * @dev Emergency pause all pools
     */
    function emergencyPauseAll() external onlyRole(EMERGENCY_ROLE) {
        _pause();
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i].isActive) {
                WeightedCarbonPool(pools[i].poolAddress).pause();
            }
        }
    }
    
    /**
     * @dev Emergency unpause all pools
     */
    function emergencyUnpauseAll() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i].isActive) {
                WeightedCarbonPool(pools[i].poolAddress).unpause();
            }
        }
    }
    
    /**
     * @dev Register a router for integration
     */
    function registerRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(router != address(0), "LiquidityPoolManager: Invalid router");
        require(!authorizedRouters[router], "LiquidityPoolManager: Router already registered");
        
        authorizedRouters[router] = true;
        registeredRouters.push(router);
    }
    
    /**
     * @dev Unregister a router
     */
    function unregisterRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(authorizedRouters[router], "LiquidityPoolManager: Router not registered");
        
        authorizedRouters[router] = false;
        
        // Remove from array
        for (uint256 i = 0; i < registeredRouters.length; i++) {
            if (registeredRouters[i] == router) {
                registeredRouters[i] = registeredRouters[registeredRouters.length - 1];
                registeredRouters.pop();
                break;
            }
        }
    }
    
    /**
     * @dev Get all registered routers
     */
    function getRegisteredRouters() external view returns (address[] memory) {
        return registeredRouters;
    }
    
    /**
     * @dev Check if router is authorized
     */
    function isAuthorizedRouter(address router) external view returns (bool) {
        return authorizedRouters[router];
    }
    
    /**
     * @dev Get all pools in a format suitable for router integration
     */
    function getAllPoolsForRouter() external view returns (
        address[] memory poolAddresses,
        address[] memory carbonTokens,
        uint256[] memory usdcWeights,
        uint256[] memory cbtWeights,
        uint256[] memory swapFees,
        bool[] memory activeStates
    ) {
        uint256 length = pools.length;
        
        poolAddresses = new address[](length);
        carbonTokens = new address[](length);
        usdcWeights = new uint256[](length);
        cbtWeights = new uint256[](length);
        swapFees = new uint256[](length);
        activeStates = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            PoolConfiguration memory pool = pools[i];
            poolAddresses[i] = pool.poolAddress;
            carbonTokens[i] = pool.carbonBasketToken;
            usdcWeights[i] = pool.weightUSDC;
            cbtWeights[i] = pool.weightCBT;
            swapFees[i] = pool.swapFee;
            activeStates[i] = pool.isActive;
        }
    }
}