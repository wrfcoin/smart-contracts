// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./CarbonFarmingPool.sol";
import "./RewardDistributor.sol";
import "./LiquidityPoolManager.sol";
import "./interfaces/IQualityOracle.sol";
import "./interfaces/IVolatilityOracle.sol";

/**
 * @title YieldFarmingManager
 * @dev Central orchestration contract for carbon credit yield farming programs
 * Manages farming pools, reward distribution, and carbon-specific incentives
 */
contract YieldFarmingManager is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant FARM_MANAGER_ROLE = keccak256("FARM_MANAGER_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    struct FarmConfiguration {
        address farmAddress;
        address liquidityPool;
        address carbonBasketToken;
        uint256 baseRewardRate;        // Base WRF tokens per second per LP token
        uint256 qualityMultiplier;     // Quality bonus multiplier (1e18 = 100%)
        uint256 vintageBonus;          // Vintage bonus in basis points
        uint256 minStakeDuration;      // Minimum stake duration for full rewards
        uint256 maxStakeDuration;      // Duration for maximum bonus
        uint256 startTime;
        uint256 endTime;
        bool isActive;
        string farmType;               // "stable", "balanced", "growth", "premium"
    }
    
    struct RewardTokenConfig {
        address tokenAddress;
        uint256 emissionRate;          // Tokens per second
        uint256 totalAllocated;        // Total tokens allocated to farming
        uint256 distributedSoFar;      // Total distributed so far
        bool isActive;
        string tokenType;              // "governance", "quality", "vintage", "sustainability"
    }
    
    struct UserFarmInfo {
        uint256 totalStaked;           // Total LP tokens staked across all farms
        uint256 totalRewardsEarned;    // Lifetime rewards earned
        uint256 lastActivityTime;      // Last stake/unstake/claim time
        mapping(address => uint256) farmStakes; // farm => staked amount
        mapping(address => uint256) lastClaimTime; // farm => last claim time
    }
    
    // Core contracts
    LiquidityPoolManager public immutable poolManager;
    RewardDistributor public rewardDistributor;
    address public immutable farmImplementation;
    
    // Oracles for carbon-specific features
    IQualityOracle public qualityOracle;
    IVolatilityOracle public volatilityOracle;
    
    // Governance and reward tokens
    IERC20 public immutable wrfToken; // Main governance/farming token
    mapping(address => RewardTokenConfig) public rewardTokens;
    address[] public supportedRewardTokens;
    
    // Farm management
    FarmConfiguration[] public farms;
    mapping(address => uint256) public farmIndexes; // farm address => index + 1
    mapping(address => bool) public authorizedLiquidityPools;
    
    // User tracking
    mapping(address => UserFarmInfo) private userInfo;
    mapping(address => mapping(address => bool)) public userOptedInFarms; // user => farm => opted in
    
    // Quality tier definitions
    mapping(uint256 => uint256) public qualityTierMultipliers; // tier => multiplier (1e18 = 100%)
    mapping(uint256 => uint256) public vintageYearBonuses; // year => bonus basis points
    
    // Anti-gaming and security
    uint256 public constant MAX_FARMS_PER_USER = 50;
    uint256 public constant MIN_STAKE_AMOUNT = 1e6; // Minimum LP tokens to stake
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_DAY = 86400;
    
    // Emergency controls
    bool public emergencyWithdrawEnabled;
    uint256 public globalRewardMultiplier = PRECISION; // Global multiplier for all rewards
    
    event FarmCreated(
        address indexed farmAddress,
        address indexed liquidityPool,
        address indexed carbonBasketToken,
        uint256 baseRewardRate,
        string farmType
    );
    
    event UserStaked(
        address indexed user,
        address indexed farm,
        uint256 amount,
        uint256 qualityMultiplier,
        uint256 vintageBonus
    );
    
    event UserUnstaked(
        address indexed user,
        address indexed farm,
        uint256 amount,
        uint256 penalty
    );
    
    event RewardsClaimed(
        address indexed user,
        address indexed farm,
        address indexed rewardToken,
        uint256 amount
    );
    
    event QualityBonusApplied(
        address indexed user,
        address indexed farm,
        uint256 qualityTier,
        uint256 bonusMultiplier
    );
    
    event VintageBonusApplied(
        address indexed user,
        address indexed farm,
        uint256 vintageYear,
        uint256 bonusPoints
    );
    
    event RewardTokenUpdated(
        address indexed token,
        uint256 emissionRate,
        string tokenType
    );
    
    event EmergencyAction(
        string action,
        address indexed farm,
        address indexed user
    );
    
    modifier onlyActiveFarm(address farmAddress) {
        require(farmIndexes[farmAddress] > 0 && farms[farmIndexes[farmAddress] - 1].isActive, 
                "YieldFarmingManager: Invalid or inactive farm");
        _;
    }
    
    modifier validStakeAmount(uint256 amount) {
        require(amount >= MIN_STAKE_AMOUNT, "YieldFarmingManager: Stake amount too small");
        _;
    }
    
    constructor(
        address _poolManager,
        address _wrfToken,
        address _farmImplementation,
        address _rewardDistributor
    ) {
        require(_poolManager != address(0), "YieldFarmingManager: Invalid pool manager");
        require(_wrfToken != address(0), "YieldFarmingManager: Invalid WRF token");
        require(_farmImplementation != address(0), "YieldFarmingManager: Invalid farm implementation");
        require(_rewardDistributor != address(0), "YieldFarmingManager: Invalid reward distributor");
        
        poolManager = LiquidityPoolManager(_poolManager);
        wrfToken = IERC20(_wrfToken);
        farmImplementation = _farmImplementation;
        rewardDistributor = RewardDistributor(_rewardDistributor);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FARM_MANAGER_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        // Initialize quality tier multipliers
        _initializeQualityTiers();
        
        // Initialize vintage bonuses
        _initializeVintageBonuses();
        
        // Setup main WRF token as primary reward
        _setupPrimaryRewardToken(_wrfToken);
    }
    
    function _initializeQualityTiers() internal {
        // Quality tier multipliers (1e18 = 100%)
        qualityTierMultipliers[1] = 2 * PRECISION;     // Premium: 200%
        qualityTierMultipliers[2] = 15 * PRECISION / 10; // High: 150%
        qualityTierMultipliers[3] = PRECISION;          // Standard: 100%
        qualityTierMultipliers[4] = PRECISION / 2;      // Basic: 50%
    }
    
    function _initializeVintageBonuses() internal {
        uint256 currentYear = 2024; // This would typically be block.timestamp based
        
        // Recent vintages get bonuses (basis points)
        vintageYearBonuses[currentYear] = 1500;     // 15% for current year
        vintageYearBonuses[currentYear - 1] = 1000; // 10% for last year
        vintageYearBonuses[currentYear - 2] = 500;  // 5% for 2 years ago
        // Older vintages get no bonus (0%)
    }
    
    function _setupPrimaryRewardToken(address _wrfToken) internal {
        rewardTokens[_wrfToken] = RewardTokenConfig({
            tokenAddress: _wrfToken,
            emissionRate: 1e18, // 1 WRF per second initially
            totalAllocated: 0,  // To be set by governance
            distributedSoFar: 0,
            isActive: true,
            tokenType: "governance"
        });
        supportedRewardTokens.push(_wrfToken);
    }
    
    /**
     * @dev Create a new yield farming pool for a liquidity pool
     */
    function createFarm(
        address liquidityPool,
        uint256 baseRewardRate,
        uint256 minStakeDuration,
        uint256 maxStakeDuration,
        uint256 duration,
        string memory farmType
    ) external onlyRole(FARM_MANAGER_ROLE) nonReentrant whenNotPaused returns (address farmAddress) {
        require(poolManager.isAuthorizedRouter(address(this)), "YieldFarmingManager: Not authorized with pool manager");
        require(baseRewardRate > 0, "YieldFarmingManager: Invalid reward rate");
        require(minStakeDuration <= maxStakeDuration, "YieldFarmingManager: Invalid stake durations");
        require(duration > 0, "YieldFarmingManager: Invalid farm duration");
        
        // Get pool configuration from pool manager
        LiquidityPoolManager.PoolConfiguration memory poolConfig = _getPoolConfig(liquidityPool);
        
        // Deploy new farm using minimal proxy pattern
        farmAddress = Clones.clone(farmImplementation);
        
        // Calculate quality multiplier and vintage bonus based on carbon basket token
        uint256 qualityMultiplier = _calculateQualityMultiplier(poolConfig.carbonBasketToken);
        uint256 vintageBonus = _calculateVintageBonus(poolConfig.carbonBasketToken);
        
        // Initialize the farm
        CarbonFarmingPool(farmAddress).initialize(
            liquidityPool,
            address(this),
            address(rewardDistributor),
            baseRewardRate,
            minStakeDuration,
            maxStakeDuration
        );
        
        // Add to farms registry
        FarmConfiguration memory newFarm = FarmConfiguration({
            farmAddress: farmAddress,
            liquidityPool: liquidityPool,
            carbonBasketToken: poolConfig.carbonBasketToken,
            baseRewardRate: baseRewardRate,
            qualityMultiplier: qualityMultiplier,
            vintageBonus: vintageBonus,
            minStakeDuration: minStakeDuration,
            maxStakeDuration: maxStakeDuration,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            isActive: true,
            farmType: farmType
        });
        
        farms.push(newFarm);
        farmIndexes[farmAddress] = farms.length;
        authorizedLiquidityPools[liquidityPool] = true;
        
        emit FarmCreated(farmAddress, liquidityPool, poolConfig.carbonBasketToken, baseRewardRate, farmType);
    }
    
    /**
     * @dev Get pool configuration safely
     */
    function _getPoolConfig(
        address liquidityPool
    ) internal view returns (LiquidityPoolManager.PoolConfiguration memory) {
        return poolManager.getPoolConfig(liquidityPool);
    }
    
    /**
     * @dev Calculate quality multiplier based on carbon basket token quality
     */
    function _calculateQualityMultiplier(address carbonBasketToken) internal view returns (uint256) {
        if (address(qualityOracle) == address(0)) {
            return PRECISION; // Default 100% if no oracle
        }
        
        uint256 qualityTier = qualityOracle.getQualityTier(carbonBasketToken);
        return qualityTierMultipliers[qualityTier];
    }
    
    /**
     * @dev Calculate vintage bonus for carbon basket token
     */
    function _calculateVintageBonus(address carbonBasketToken) internal view returns (uint256) {
        // This would need to access vintage information from the carbon basket token
        // For now, return a default bonus
        uint256 currentYear = 2024; // Would be calculated from block.timestamp
        return vintageYearBonuses[currentYear];
    }
    
    /**
     * @dev Stake LP tokens in a farm
     */
    function stake(
        address farmAddress,
        uint256 amount
    ) external onlyActiveFarm(farmAddress) validStakeAmount(amount) nonReentrant whenNotPaused {
        UserFarmInfo storage user = userInfo[msg.sender];
        FarmConfiguration memory farm = farms[farmIndexes[farmAddress] - 1];
        
        // Check user hasn't exceeded max farms
        require(_getUserActiveFarmCount(msg.sender) < MAX_FARMS_PER_USER, 
                "YieldFarmingManager: Too many active farms");
        
        // Transfer LP tokens from user (Y-01 fix: use SafeERC20)
        IERC20(farm.liquidityPool).safeTransferFrom(msg.sender, farmAddress, amount);

        // Update user info
        user.farmStakes[farmAddress] += amount;
        user.totalStaked += amount;
        user.lastActivityTime = block.timestamp;

        // Y-02 fix: Initialize lastClaimTime on first stake to prevent reward inflation
        if (user.lastClaimTime[farmAddress] == 0) {
            user.lastClaimTime[farmAddress] = block.timestamp;
        }

        // Opt user into farm if first stake
        if (!userOptedInFarms[msg.sender][farmAddress]) {
            userOptedInFarms[msg.sender][farmAddress] = true;
        }
        
        // Call farm contract to handle staking logic
        CarbonFarmingPool(farmAddress).handleStake(msg.sender, amount);
        
        emit UserStaked(msg.sender, farmAddress, amount, farm.qualityMultiplier, farm.vintageBonus);
        
        // Apply quality bonus if applicable
        if (farm.qualityMultiplier > PRECISION) {
            uint256 qualityTier = qualityOracle.getQualityTier(farm.carbonBasketToken);
            emit QualityBonusApplied(msg.sender, farmAddress, qualityTier, farm.qualityMultiplier);
        }
        
        // Apply vintage bonus if applicable
        if (farm.vintageBonus > 0) {
            uint256 vintageYear = 2024; // Would be calculated from carbon basket token
            emit VintageBonusApplied(msg.sender, farmAddress, vintageYear, farm.vintageBonus);
        }
    }
    
    /**
     * @dev Unstake LP tokens from a farm
     */
    function unstake(
        address farmAddress,
        uint256 amount
    ) external onlyActiveFarm(farmAddress) nonReentrant {
        UserFarmInfo storage user = userInfo[msg.sender];
        require(user.farmStakes[farmAddress] >= amount, "YieldFarmingManager: Insufficient stake");
        
        FarmConfiguration memory farm = farms[farmIndexes[farmAddress] - 1];
        
        // Calculate early unstaking penalty if applicable
        uint256 penalty = 0;
        uint256 stakeDuration = block.timestamp - user.lastClaimTime[farmAddress];
        if (stakeDuration < farm.minStakeDuration) {
            penalty = (amount * (farm.minStakeDuration - stakeDuration) * 1000) / 
                     (farm.minStakeDuration * BASIS_POINTS); // Up to 10% penalty
        }
        
        // Update user info
        user.farmStakes[farmAddress] -= amount;
        user.totalStaked -= amount;
        user.lastActivityTime = block.timestamp;
        
        // Call farm contract to handle unstaking logic
        CarbonFarmingPool(farmAddress).handleUnstake(msg.sender, amount, penalty);
        
        emit UserUnstaked(msg.sender, farmAddress, amount, penalty);
    }
    
    /**
     * @dev Claim rewards from a farm
     */
    function claimRewards(address farmAddress) external onlyActiveFarm(farmAddress) nonReentrant {
        UserFarmInfo storage user = userInfo[msg.sender];
        require(user.farmStakes[farmAddress] > 0, "YieldFarmingManager: No stake in farm");
        
        // Calculate and distribute rewards
        uint256 rewards = _calculateUserRewards(msg.sender, farmAddress);
        if (rewards > 0) {
            user.totalRewardsEarned += rewards;
            user.lastClaimTime[farmAddress] = block.timestamp;
            
            // Distribute rewards through RewardDistributor
            rewardDistributor.distributeRewards(msg.sender, address(wrfToken), rewards);
            
            emit RewardsClaimed(msg.sender, farmAddress, address(wrfToken), rewards);
        }
    }
    
    /**
     * @dev Calculate pending rewards for a user in a farm
     */
    function _calculateUserRewards(address user, address farmAddress) internal view returns (uint256) {
        UserFarmInfo storage userData = userInfo[user];
        FarmConfiguration memory farm = farms[farmIndexes[farmAddress] - 1];
        
        if (userData.farmStakes[farmAddress] == 0) {
            return 0;
        }
        
        uint256 stakeDuration = block.timestamp - userData.lastClaimTime[farmAddress];
        uint256 baseRewards = (userData.farmStakes[farmAddress] * farm.baseRewardRate * stakeDuration) / PRECISION;
        
        // Apply quality multiplier
        uint256 qualityBoostedRewards = (baseRewards * farm.qualityMultiplier) / PRECISION;
        
        // Apply vintage bonus
        uint256 vintageBonus = (qualityBoostedRewards * farm.vintageBonus) / BASIS_POINTS;
        
        // Apply global multiplier
        uint256 finalRewards = ((qualityBoostedRewards + vintageBonus) * globalRewardMultiplier) / PRECISION;
        
        return finalRewards;
    }
    
    /**
     * @dev Get number of active farms for a user
     */
    function _getUserActiveFarmCount(address user) internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < farms.length; i++) {
            if (userInfo[user].farmStakes[farms[i].farmAddress] > 0) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev Emergency withdraw - allows users to withdraw without rewards in case of emergency
     */
    function emergencyWithdraw(address farmAddress) external nonReentrant {
        require(emergencyWithdrawEnabled, "YieldFarmingManager: Emergency withdraw not enabled");
        
        UserFarmInfo storage user = userInfo[msg.sender];
        uint256 amount = user.farmStakes[farmAddress];
        require(amount > 0, "YieldFarmingManager: No stake to withdraw");
        
        // Update user info
        user.farmStakes[farmAddress] = 0;
        user.totalStaked -= amount;
        user.lastActivityTime = block.timestamp;
        
        // Call farm contract for emergency withdrawal
        CarbonFarmingPool(farmAddress).emergencyWithdraw(msg.sender, amount);
        
        emit EmergencyAction("emergency_withdraw", farmAddress, msg.sender);
    }
    
    /**
     * @dev Set quality oracle
     */
    function setQualityOracle(address _oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        qualityOracle = IQualityOracle(_oracle);
    }
    
    /**
     * @dev Set volatility oracle
     */
    function setVolatilityOracle(address _oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        volatilityOracle = IVolatilityOracle(_oracle);
    }
    
    /**
     * @dev Add or update reward token configuration
     */
    function configureRewardToken(
        address tokenAddress,
        uint256 emissionRate,
        uint256 totalAllocated,
        string memory tokenType
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(tokenAddress != address(0), "YieldFarmingManager: Invalid token address");
        
        if (rewardTokens[tokenAddress].tokenAddress == address(0)) {
            // New token
            supportedRewardTokens.push(tokenAddress);
        }
        
        rewardTokens[tokenAddress] = RewardTokenConfig({
            tokenAddress: tokenAddress,
            emissionRate: emissionRate,
            totalAllocated: totalAllocated,
            distributedSoFar: rewardTokens[tokenAddress].distributedSoFar,
            isActive: true,
            tokenType: tokenType
        });
        
        emit RewardTokenUpdated(tokenAddress, emissionRate, tokenType);
    }
    
    /**
     * @dev Update global reward multiplier
     */
    function setGlobalRewardMultiplier(uint256 _multiplier) external onlyRole(REWARD_MANAGER_ROLE) {
        require(_multiplier <= 5 * PRECISION, "YieldFarmingManager: Multiplier too high"); // Max 5x
        globalRewardMultiplier = _multiplier;
    }
    
    /**
     * @dev Enable/disable emergency withdrawals
     */
    function setEmergencyWithdrawEnabled(bool _enabled) external onlyRole(EMERGENCY_ROLE) {
        emergencyWithdrawEnabled = _enabled;
        emit EmergencyAction(_enabled ? "emergency_enabled" : "emergency_disabled", address(0), address(0));
    }
    
    /**
     * @dev Pause/unpause all farming operations
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Get user's farming information
     */
    function getUserFarmInfo(address user) external view returns (
        uint256 totalStaked,
        uint256 totalRewardsEarned,
        uint256 lastActivityTime,
        uint256 activeFarmCount
    ) {
        UserFarmInfo storage info = userInfo[user];
        return (
            info.totalStaked,
            info.totalRewardsEarned,
            info.lastActivityTime,
            _getUserActiveFarmCount(user)
        );
    }
    
    /**
     * @dev Get user's stake in a specific farm
     */
    function getUserStakeInFarm(address user, address farmAddress) external view returns (uint256) {
        return userInfo[user].farmStakes[farmAddress];
    }
    
    /**
     * @dev Get pending rewards for a user in a farm
     */
    function getPendingRewards(address user, address farmAddress) external view returns (uint256) {
        return _calculateUserRewards(user, farmAddress);
    }
    
    /**
     * @dev Get all active farms
     */
    function getActiveFarms() external view returns (FarmConfiguration[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < farms.length; i++) {
            if (farms[i].isActive && block.timestamp < farms[i].endTime) {
                activeCount++;
            }
        }
        
        FarmConfiguration[] memory activeFarms = new FarmConfiguration[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < farms.length; i++) {
            if (farms[i].isActive && block.timestamp < farms[i].endTime) {
                activeFarms[currentIndex] = farms[i];
                currentIndex++;
            }
        }
        
        return activeFarms;
    }
    
    /**
     * @dev Get farm information by address
     */
    function getFarmInfo(address farmAddress) external view returns (FarmConfiguration memory) {
        require(farmIndexes[farmAddress] > 0, "YieldFarmingManager: Farm not found");
        return farms[farmIndexes[farmAddress] - 1];
    }
    
    /**
     * @dev Get all supported reward tokens
     */
    function getSupportedRewardTokens() external view returns (address[] memory) {
        return supportedRewardTokens;
    }
    
    /**
     * @dev Get reward token configuration
     */
    function getRewardTokenConfig(address tokenAddress) external view returns (RewardTokenConfig memory) {
        return rewardTokens[tokenAddress];
    }
    
    /**
     * @dev Get total farms count
     */
    function getFarmsCount() external view returns (uint256) {
        return farms.length;
    }
}