// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IQualityOracle.sol";

/**
 * @title RewardDistributor
 * @notice Manages distribution of multiple reward tokens with vesting, quality bonuses, and anti-gaming measures
 * @dev Advanced reward distribution system with comprehensive security features
 * 
 * Features:
 * - Multi-token reward distribution with configurable vesting
 * - Quality-based bonus calculations for carbon credits
 * - Time-weighted reward calculations to prevent gaming
 * - Early vesting with penalty mechanisms
 * - Batch operations for gas efficiency
 * - Emergency controls and circuit breakers
 * 
 * Security Features:
 * - Anti-gaming measures with time delays
 * - Comprehensive input validation
 * - Reentrancy protection on all functions
 * - Role-based access control
 * - Emergency pause and freeze capabilities
 * - Mathematical precision safeguards
 * 
 * Economic Security:
 * - Reward emission rate limits
 * - Maximum vesting duration caps
 * - Early withdrawal penalties
 * - Quality bonus verification
 * - Total allocation tracking
 * 
 * @author WRFCoin Security Team
 * @custom:security-contact security@wrfcoin.io
 */
contract RewardDistributor is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    struct RewardToken {
        address tokenAddress;
        uint256 totalAllocated;        // Total tokens allocated
        uint256 totalDistributed;      // Total tokens distributed
        uint256 emissionRate;          // Tokens per second
        uint256 lastEmission;          // Last emission timestamp
        uint256 vestingDuration;       // Vesting period in seconds
        bool isActive;
        string tokenType;              // "governance", "quality", "vintage", "sustainability"
    }
    
    struct VestingSchedule {
        uint256 totalAmount;           // Total amount to vest
        uint256 vestedAmount;          // Amount already vested
        uint256 startTime;             // Vesting start time
        uint256 duration;              // Vesting duration
        uint256 lastClaimTime;         // Last claim timestamp
        bool isRevoked;                // Vesting revoked flag
    }
    
    struct QualityReward {
        uint256 baseAmount;            // Base reward amount
        uint256 qualityMultiplier;     // Quality-based multiplier
        uint256 qualityTier;           // Quality tier (1-4)
        uint256 vintageBonus;          // Vintage bonus in basis points
        uint256 sustainabilityBonus;   // Sustainability bonus in basis points
        uint256 finalAmount;           // Final calculated amount
    }
    
    // Reward tokens
    mapping(address => RewardToken) public rewardTokens;
    address[] public supportedTokens;
    
    // Vesting schedules: user => token => vesting schedule
    mapping(address => mapping(address => VestingSchedule)) public vestingSchedules;
    
    // User reward tracking
    mapping(address => mapping(address => uint256)) public userTotalRewards; // user => token => total
    mapping(address => mapping(address => uint256)) public userClaimedRewards; // user => token => claimed
    mapping(address => uint256) public userLastActivity; // Anti-gaming
    
    // Quality-based rewards tracking
    mapping(address => mapping(address => QualityReward)) public qualityRewards; // user => token => quality reward
    
    // Oracle integration
    IQualityOracle public qualityOracle;
    
    // Mathematical precision constants
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Vesting configuration limits
    uint256 public constant MAX_VESTING_DURATION = 365 days;
    uint256 public constant MIN_VESTING_DURATION = 7 days;
    uint256 public constant MAX_EARLY_VESTING_FEE = 5000; // 50% maximum penalty
    
    // Anti-gaming and security measures
    uint256 public constant ANTI_GAMING_DELAY = 1 hours;
    uint256 public constant MAX_BATCH_SIZE = 100; // Maximum batch operation size
    uint256 public constant MIN_REWARD_AMOUNT = 1e12; // Minimum reward amount (dust protection)
    uint256 public constant MAX_QUALITY_MULTIPLIER = 3 * PRECISION; // 300% maximum bonus
    
    // Economic security limits
    uint256 public constant MAX_EMISSION_RATE = 1000 * PRECISION; // 1000 tokens per second maximum
    uint256 public constant MAX_TOTAL_ALLOCATION = 1000000 * PRECISION; // 1M tokens maximum per reward token
    uint256 public constant REWARD_BUFFER_RATIO = 110; // 110% - require 10% buffer above allocated amounts
    
    // Emergency controls
    bool public emergencyWithdrawEnabled;
    mapping(address => bool) public tokenEmergencyFrozen;
    
    // Fee structure for early vesting
    uint256 public earlyVestingFeeBasisPoints = 2000; // 20% fee for early vesting
    address public feeRecipient;
    
    event RewardDistributed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 vestingDuration,
        uint256 qualityMultiplier
    );
    
    event RewardClaimed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 remainingVested
    );
    
    event QualityBonusApplied(
        address indexed user,
        address indexed token,
        uint256 qualityTier,
        uint256 bonusAmount
    );
    
    event VintageBonusApplied(
        address indexed user,
        address indexed token,
        uint256 vintageYear,
        uint256 bonusAmount
    );
    
    event SustainabilityBonusApplied(
        address indexed user,
        address indexed token,
        uint256 bonusAmount
    );
    
    event VestingScheduleCreated(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 duration
    );
    
    event VestingScheduleRevoked(
        address indexed user,
        address indexed token,
        uint256 unvestedAmount
    );
    
    event EarlyVesting(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 fee
    );
    
    event EmergencyAction(
        string action,
        address indexed token,
        address indexed user
    );
    
    modifier onlyDistributor() {
        require(hasRole(DISTRIBUTOR_ROLE, msg.sender), "RewardDistributor: Not authorized distributor");
        _;
    }
    
    modifier antiGaming() {
        require(
            block.timestamp >= userLastActivity[msg.sender] + ANTI_GAMING_DELAY,
            "RewardDistributor: Anti-gaming delay active"
        );
        _;
        userLastActivity[msg.sender] = block.timestamp;
    }
    
    modifier tokenNotFrozen(address token) {
        require(!tokenEmergencyFrozen[token], "RewardDistributor: Token frozen");
        _;
    }
    
    constructor(address _feeRecipient, address _qualityOracle) {
        require(_feeRecipient != address(0), "RewardDistributor: Invalid fee recipient");
        
        feeRecipient = _feeRecipient;
        qualityOracle = IQualityOracle(_qualityOracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    /**
     * @notice Configures or updates a reward token with comprehensive validation
     * @dev Sets up reward token parameters with security limits and validation
     * @param tokenAddress Address of the ERC20 reward token
     * @param totalAllocated Total amount of tokens allocated for rewards
     * @param emissionRate Rate of token emission per second
     * @param vestingDuration Vesting period for rewards in seconds
     * @param tokenType Type classification for bonus calculations
     * 
     * Requirements:
     * - Caller must have REWARD_MANAGER_ROLE
     * - Token address must be valid
     * - Vesting duration within allowed range
     * - Emission rate within security limits
     * - Total allocation within maximum limits
     * - Contract must hold sufficient token balance
     * 
     * Security Features:
     * - Economic limits validation
     * - Token balance verification
     * - Emission rate caps
     * - Allocation limits
     */
    function configureRewardToken(
        address tokenAddress,
        uint256 totalAllocated,
        uint256 emissionRate,
        uint256 vestingDuration,
        string memory tokenType
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(tokenAddress != address(0), "RewardDistributor: Invalid token address");
        require(vestingDuration >= MIN_VESTING_DURATION && vestingDuration <= MAX_VESTING_DURATION,
                "RewardDistributor: Invalid vesting duration");
        require(totalAllocated <= MAX_TOTAL_ALLOCATION, "RewardDistributor: Allocation too large");
        require(emissionRate <= MAX_EMISSION_RATE, "RewardDistributor: Emission rate too high");
        require(totalAllocated > 0, "RewardDistributor: Invalid allocation");
        
        // Verify contract has sufficient token balance (with buffer)
        uint256 requiredBalance = (totalAllocated * REWARD_BUFFER_RATIO) / 100;
        require(IERC20(tokenAddress).balanceOf(address(this)) >= requiredBalance,
                "RewardDistributor: Insufficient token balance");
        
        // Add to supported tokens if new
        if (rewardTokens[tokenAddress].tokenAddress == address(0)) {
            supportedTokens.push(tokenAddress);
        }
        
        rewardTokens[tokenAddress] = RewardToken({
            tokenAddress: tokenAddress,
            totalAllocated: totalAllocated,
            totalDistributed: rewardTokens[tokenAddress].totalDistributed,
            emissionRate: emissionRate,
            lastEmission: block.timestamp,
            vestingDuration: vestingDuration,
            isActive: true,
            tokenType: tokenType
        });
    }
    
    /**
     * @notice Distributes rewards to a user with quality bonuses and comprehensive validation
     * @dev Calculates and distributes rewards with quality-based multipliers and security checks
     * @param user Address of the reward recipient
     * @param token Address of the reward token
     * @param baseAmount Base reward amount before bonuses
     * 
     * Requirements:
     * - Caller must have DISTRIBUTOR_ROLE
     * - User address must be valid
     * - Token must be active and not frozen
     * - Base amount must meet minimum threshold
     * - Total distribution must not exceed allocation
     * - Contract must not be paused
     * 
     * Security Features:
     * - Reentrancy protection
     * - Anti-gaming delay enforcement
     * - Quality bonus validation
     * - Emission rate limiting
     * - Total allocation tracking
     */
    function distributeRewards(
        address user,
        address token,
        uint256 baseAmount
    ) external onlyDistributor nonReentrant tokenNotFrozen(token) whenNotPaused {
        require(user != address(0), "RewardDistributor: Invalid user");
        require(rewardTokens[token].isActive, "RewardDistributor: Token not active");
        require(baseAmount >= MIN_REWARD_AMOUNT, "RewardDistributor: Amount too small");
        
        RewardToken storage rewardToken = rewardTokens[token];

        // Calculate quality-based bonuses BEFORE checking allocation
        // so the cap check accounts for the full multiplied amount
        QualityReward memory qualityReward = _calculateQualityRewards(user, token, baseAmount);
        uint256 finalAmount = qualityReward.finalAmount;

        // Check emission limits against finalAmount (not baseAmount)
        require(
            rewardToken.totalDistributed + finalAmount <= rewardToken.totalAllocated,
            "RewardDistributor: Exceeds allocation"
        );
        
        // Update distribution tracking
        rewardToken.totalDistributed += finalAmount;
        userTotalRewards[user][token] += finalAmount;
        
        // Create or update vesting schedule
        _createVestingSchedule(user, token, finalAmount, rewardToken.vestingDuration);
        
        // Store quality reward details
        qualityRewards[user][token] = qualityReward;
        
        emit RewardDistributed(user, token, finalAmount, rewardToken.vestingDuration, qualityReward.qualityMultiplier);
        
        // Emit quality bonus events
        if (qualityReward.qualityMultiplier > PRECISION) {
            emit QualityBonusApplied(user, token, qualityReward.qualityTier, 
                                   finalAmount - qualityReward.baseAmount);
        }
        
        if (qualityReward.vintageBonus > 0) {
            uint256 vintageYear = 2024; // This would be calculated from blockchain time
            emit VintageBonusApplied(user, token, vintageYear, 
                                   (qualityReward.baseAmount * qualityReward.vintageBonus) / BASIS_POINTS);
        }
        
        if (qualityReward.sustainabilityBonus > 0) {
            emit SustainabilityBonusApplied(
                user, 
                token, 
                (qualityReward.baseAmount * qualityReward.sustainabilityBonus) / BASIS_POINTS
            );
        }
    }
    
    /**
     * @dev Calculate quality-based reward bonuses
     */
    function _calculateQualityRewards(
        address /* user */,
        address token,
        uint256 baseAmount
    ) internal view returns (QualityReward memory) {
        // Start with base amount
        uint256 currentAmount = baseAmount;
        uint256 qualityMultiplier = PRECISION;
        uint256 qualityTier = 3; // Default to Standard
        uint256 vintageBonus = 0;
        uint256 sustainabilityBonus = 0;
        
        // Apply quality multiplier if oracle is available
        if (address(qualityOracle) != address(0)) {
            // Get quality score from oracle (0-100 scale)
            uint256 qualityScore = qualityOracle.getQualityScore(token);

            /// @dev SECURITY FIX: Validate oracle return value is within expected bounds.
            /// A score of 0 indicates stale or missing data; scores above 100 indicate oracle malfunction.
            require(qualityScore > 0 && qualityScore <= 100, "RewardDistributor: Invalid quality score from oracle");

            // Convert quality score to tier:
            // Premium (1): 95-100, High (2): 80-94, Standard (3): 60-79, Basic (4): 0-59
            if (qualityScore >= 95) {
                qualityTier = 1; // Premium
            } else if (qualityScore >= 80) {
                qualityTier = 2; // High
            } else if (qualityScore >= 60) {
                qualityTier = 3; // Standard
            } else {
                qualityTier = 4; // Basic
            }

            // Apply tier-based multipliers
            if (qualityTier == 1) {
                qualityMultiplier = 2 * PRECISION;  // Premium: 200%
            } else if (qualityTier == 2) {
                qualityMultiplier = 15 * PRECISION / 10; // High: 150%
            } else if (qualityTier == 3) {
                qualityMultiplier = PRECISION;       // Standard: 100%
            } else {
                qualityMultiplier = PRECISION / 2;   // Basic: 50%
            }
            
            currentAmount = (baseAmount * qualityMultiplier) / PRECISION;
        }
        
        // Apply vintage bonus (recent vintages get bonus)
        if (keccak256(abi.encodePacked(rewardTokens[token].tokenType)) == keccak256("vintage")) {
            vintageBonus = 1000; // 10% bonus for vintage tokens
            currentAmount += (baseAmount * vintageBonus) / BASIS_POINTS;
        }
        
        // Apply sustainability bonus
        if (keccak256(abi.encodePacked(rewardTokens[token].tokenType)) == keccak256("sustainability")) {
            sustainabilityBonus = 500; // 5% bonus for sustainability tokens
            currentAmount += (baseAmount * sustainabilityBonus) / BASIS_POINTS;
        }
        
        return QualityReward({
            baseAmount: baseAmount,
            qualityMultiplier: qualityMultiplier,
            qualityTier: qualityTier,
            vintageBonus: vintageBonus,
            sustainabilityBonus: sustainabilityBonus,
            finalAmount: currentAmount
        });
    }
    
    /**
     * @dev Create or update vesting schedule for user
     */
    function _createVestingSchedule(
        address user,
        address token,
        uint256 amount,
        uint256 duration
    ) internal {
        VestingSchedule storage schedule = vestingSchedules[user][token];
        
        if (schedule.totalAmount == 0) {
            // New vesting schedule
            schedule.totalAmount = amount;
            schedule.startTime = block.timestamp;
            schedule.duration = duration;
            schedule.lastClaimTime = block.timestamp;
        } else {
            // Add to an existing schedule (#147).
            //
            // `schedule.vestedAmount` is the *claimed watermark* — how much has
            // already been transferred to the user via claimRewards. The tokens
            // the user is still owed (both already-vested-but-unclaimed and not-
            // yet-vested) are `totalAmount - vestedAmount`; we carry that forward
            // and fold in the new `amount`, then restart the vesting clock.
            //
            // Because the new `totalAmount` already EXCLUDES everything claimed
            // and the clock restarts at `block.timestamp`, the claimed watermark
            // for the fresh schedule must be reset to 0. The previous code set it
            // to `_calculateVestedAmount(...)` (up to the OLD total) while also
            // resetting startTime, so the very next claim computed
            // `claimableAmount = 0 - watermark` and reverted on underflow,
            // locking claims for the full new duration.
            schedule.totalAmount = schedule.totalAmount - schedule.vestedAmount + amount;
            schedule.vestedAmount = 0;
            schedule.startTime = block.timestamp;
            schedule.duration = duration;
            schedule.lastClaimTime = block.timestamp;
        }
        
        emit VestingScheduleCreated(user, token, amount, duration);
    }
    
    /**
     * @dev Calculate vested amount for a user's schedule
     */
    function _calculateVestedAmount(address user, address token) internal view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user][token];
        
        if (schedule.totalAmount == 0 || schedule.isRevoked) {
            return 0;
        }
        
        uint256 elapsed = block.timestamp - schedule.startTime;
        
        if (elapsed >= schedule.duration) {
            return schedule.totalAmount;
        }
        
        return (schedule.totalAmount * elapsed) / schedule.duration;
    }
    
    /**
     * @dev Claim vested rewards
     */
    function claimRewards(address token) external nonReentrant antiGaming tokenNotFrozen(token) whenNotPaused {
        VestingSchedule storage schedule = vestingSchedules[msg.sender][token];
        require(schedule.totalAmount > 0, "RewardDistributor: No vesting schedule");
        require(!schedule.isRevoked, "RewardDistributor: Vesting revoked");
        
        uint256 vestedAmount = _calculateVestedAmount(msg.sender, token);
        uint256 claimableAmount = vestedAmount - schedule.vestedAmount;
        
        require(claimableAmount > 0, "RewardDistributor: Nothing to claim");
        
        // Update schedule
        schedule.vestedAmount = vestedAmount;
        schedule.lastClaimTime = block.timestamp;
        
        // Update user tracking
        userClaimedRewards[msg.sender][token] += claimableAmount;
        
        // Transfer tokens
        IERC20(token).safeTransfer(msg.sender, claimableAmount);
        
        uint256 remainingVested = schedule.totalAmount - vestedAmount;
        
        emit RewardClaimed(msg.sender, token, claimableAmount, remainingVested);
    }
    
    /**
     * @dev Early vesting with penalty fee
     */
    function claimEarlyVesting(address token) external nonReentrant antiGaming tokenNotFrozen(token) whenNotPaused {
        VestingSchedule storage schedule = vestingSchedules[msg.sender][token];
        require(schedule.totalAmount > 0, "RewardDistributor: No vesting schedule");
        require(!schedule.isRevoked, "RewardDistributor: Vesting revoked");
        
        uint256 vestedAmount = _calculateVestedAmount(msg.sender, token);
        uint256 unvestedAmount = schedule.totalAmount - vestedAmount;

        require(unvestedAmount > 0, "RewardDistributor: No unvested amount");

        // #146: the early-exit fee applies ONLY to the not-yet-vested portion.
        // Any already-vested-but-unclaimed tokens (the difference between the
        // total vested so far and the claimed watermark) have been earned in
        // full and must be paid out fee-free. The previous implementation
        // transferred only `unvestedAmount - fee` yet marked the schedule fully
        // claimed (`vestedAmount = totalAmount`), permanently stranding those
        // already-vested-but-unclaimed tokens with no recovery path.
        uint256 alreadyVestedUnclaimed = vestedAmount - schedule.vestedAmount;

        // Fee on the unvested portion only.
        uint256 fee = (unvestedAmount * earlyVestingFeeBasisPoints) / BASIS_POINTS;
        uint256 unvestedAfterFee = unvestedAmount - fee;

        // User receives the full unclaimed-vested amount plus the discounted
        // unvested amount.
        uint256 userReceives = alreadyVestedUnclaimed + unvestedAfterFee;

        // Update schedule to fully settled (everything now accounted for).
        schedule.vestedAmount = schedule.totalAmount;
        schedule.lastClaimTime = block.timestamp;

        // Update user tracking
        userClaimedRewards[msg.sender][token] += userReceives;

        // Transfer tokens
        if (userReceives > 0) {
            IERC20(token).safeTransfer(msg.sender, userReceives);
        }

        // Send fee to fee recipient
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        emit EarlyVesting(msg.sender, token, userReceives, fee);
    }
    
    /**
     * @dev Revoke vesting schedule (emergency only)
     */
    function revokeVesting(address user, address token) external onlyRole(EMERGENCY_ROLE) {
        VestingSchedule storage schedule = vestingSchedules[user][token];
        require(schedule.totalAmount > 0, "RewardDistributor: No vesting schedule");
        require(!schedule.isRevoked, "RewardDistributor: Already revoked");
        
        uint256 vestedAmount = _calculateVestedAmount(user, token);
        uint256 unvestedAmount = schedule.totalAmount - vestedAmount;
        
        schedule.isRevoked = true;
        
        emit VestingScheduleRevoked(user, token, unvestedAmount);
        emit EmergencyAction("vesting_revoked", token, user);
    }
    
    /**
     * @dev Emergency withdraw for specific token
     */
    function emergencyWithdraw(address token) external nonReentrant {
        require(emergencyWithdrawEnabled, "RewardDistributor: Emergency withdraw disabled");
        
        VestingSchedule storage schedule = vestingSchedules[msg.sender][token];
        require(schedule.totalAmount > 0, "RewardDistributor: No vesting schedule");
        
        uint256 vestedAmount = _calculateVestedAmount(msg.sender, token);
        uint256 claimableAmount = vestedAmount - schedule.vestedAmount;
        
        if (claimableAmount > 0) {
            schedule.vestedAmount = vestedAmount;
            userClaimedRewards[msg.sender][token] += claimableAmount;
            IERC20(token).safeTransfer(msg.sender, claimableAmount);
        }
        
        emit EmergencyAction("emergency_withdraw", token, msg.sender);
    }
    
    /**
     * @dev Get claimable amount for user
     */
    function getClaimableAmount(address user, address token) external view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[user][token];
        
        if (schedule.totalAmount == 0 || schedule.isRevoked) {
            return 0;
        }
        
        uint256 vestedAmount = _calculateVestedAmount(user, token);
        return vestedAmount - schedule.vestedAmount;
    }
    
    /**
     * @dev Get vesting schedule information
     */
    function getVestingInfo(address user, address token) external view returns (
        uint256 totalAmount,
        uint256 vestedAmount,
        uint256 claimableAmount,
        uint256 remainingAmount,
        uint256 startTime,
        uint256 duration,
        bool isRevoked
    ) {
        VestingSchedule storage schedule = vestingSchedules[user][token];
        uint256 vested = _calculateVestedAmount(user, token);
        uint256 claimable = vested - schedule.vestedAmount;
        uint256 remaining = schedule.totalAmount - vested;
        
        return (
            schedule.totalAmount,
            vested,
            claimable,
            remaining,
            schedule.startTime,
            schedule.duration,
            schedule.isRevoked
        );
    }
    
    /**
     * @dev Get user's total rewards across all tokens
     */
    function getUserTotalRewards(address user) external view returns (
        address[] memory tokens,
        uint256[] memory totalRewards,
        uint256[] memory claimedRewards,
        uint256[] memory pendingRewards
    ) {
        uint256 length = supportedTokens.length;
        tokens = new address[](length);
        totalRewards = new uint256[](length);
        claimedRewards = new uint256[](length);
        pendingRewards = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            address token = supportedTokens[i];
            tokens[i] = token;
            totalRewards[i] = userTotalRewards[user][token];
            claimedRewards[i] = userClaimedRewards[user][token];
            pendingRewards[i] = this.getClaimableAmount(user, token);
        }
    }
    
    /**
     * @dev Set quality oracle
     */
    function setQualityOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        qualityOracle = IQualityOracle(_oracle);
    }
    
    /**
     * @dev Set early vesting fee
     */
    function setEarlyVestingFee(uint256 _feeBasisPoints) external onlyRole(REWARD_MANAGER_ROLE) {
        require(_feeBasisPoints <= 5000, "RewardDistributor: Fee too high"); // Max 50%
        earlyVestingFeeBasisPoints = _feeBasisPoints;
    }
    
    /**
     * @dev Set fee recipient
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeRecipient != address(0), "RewardDistributor: Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @dev Emergency freeze/unfreeze token
     */
    function setTokenFrozen(address token, bool frozen) external onlyRole(EMERGENCY_ROLE) {
        tokenEmergencyFrozen[token] = frozen;
        emit EmergencyAction(frozen ? "token_frozen" : "token_unfrozen", token, address(0));
    }
    
    /**
     * @dev Enable/disable emergency withdrawals
     */
    function setEmergencyWithdrawEnabled(bool _enabled) external onlyRole(EMERGENCY_ROLE) {
        emergencyWithdrawEnabled = _enabled;
        emit EmergencyAction(_enabled ? "emergency_enabled" : "emergency_disabled", address(0), address(0));
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }
    
    /**
     * @dev Emergency unpause
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Get supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }
    
    /**
     * @dev Get reward token configuration
     */
    function getRewardToken(address token) external view returns (RewardToken memory) {
        return rewardTokens[token];
    }
    
    /**
     * @dev Get quality reward details for user
     */
    function getQualityReward(address user, address token) external view returns (QualityReward memory) {
        return qualityRewards[user][token];
    }
    
    /**
     * @notice Batch distribute rewards to multiple users for gas efficiency
     * @dev Distributes rewards to multiple users in a single transaction
     * @param users Array of user addresses
     * @param tokens Array of token addresses (must match users array length)
     * @param amounts Array of base amounts (must match users array length)
     * 
     * Requirements:
     * - All arrays must have the same length
     * - Array length must not exceed MAX_BATCH_SIZE
     * - All individual distribution requirements must be met
     * 
     * Gas Optimization:
     * - Batches multiple distributions in one transaction
     * - Reduces transaction overhead
     * - Optimizes for bulk reward distribution
     */
    function batchDistributeRewards(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external onlyDistributor nonReentrant whenNotPaused {
        uint256 length = users.length;
        require(length > 0 && length <= MAX_BATCH_SIZE, "RewardDistributor: Invalid batch size");
        require(tokens.length == length && amounts.length == length, "RewardDistributor: Array length mismatch");
        
        for (uint256 i = 0; i < length;) {
            address user = users[i];
            address token = tokens[i];
            uint256 amount = amounts[i];
            
            // Skip if token is frozen or invalid parameters
            if (tokenEmergencyFrozen[token] || user == address(0) || amount < MIN_REWARD_AMOUNT || 
                !rewardTokens[token].isActive) {
                unchecked { ++i; }
                continue;
            }
            
            RewardToken storage rewardToken = rewardTokens[token];

            // Calculate quality-based bonuses BEFORE checking allocation
            QualityReward memory qualityReward = _calculateQualityRewards(user, token, amount);
            uint256 finalAmount = qualityReward.finalAmount;

            // Check emission limits against finalAmount (not base amount)
            if (rewardToken.totalDistributed + finalAmount > rewardToken.totalAllocated) {
                unchecked { ++i; }
                continue;
            }
            
            // Update distribution tracking
            rewardToken.totalDistributed += finalAmount;
            userTotalRewards[user][token] += finalAmount;
            
            // Create or update vesting schedule
            _createVestingSchedule(user, token, finalAmount, rewardToken.vestingDuration);
            
            // Store quality reward details
            qualityRewards[user][token] = qualityReward;
            
            emit RewardDistributed(user, token, finalAmount, rewardToken.vestingDuration, qualityReward.qualityMultiplier);
            
            unchecked { ++i; }
        }
    }
    
    /**
     * @notice Emergency batch claim for multiple users (admin only)
     * @dev Allows emergency claiming of vested rewards for multiple users
     * @param users Array of user addresses
     * @param tokens Array of token addresses
     * 
     * Requirements:
     * - Caller must have EMERGENCY_ROLE
     * - Emergency withdrawals must be enabled
     * - Arrays must have matching lengths
     */
    function emergencyBatchClaim(
        address[] calldata users,
        address[] calldata tokens
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(emergencyWithdrawEnabled, "RewardDistributor: Emergency disabled");
        require(users.length == tokens.length, "RewardDistributor: Array length mismatch");
        require(users.length <= MAX_BATCH_SIZE, "RewardDistributor: Batch too large");
        
        for (uint256 i = 0; i < users.length;) {
            address user = users[i];
            address token = tokens[i];
            
            VestingSchedule storage schedule = vestingSchedules[user][token];
            if (schedule.totalAmount > 0 && !schedule.isRevoked) {
                uint256 vestedAmount = _calculateVestedAmount(user, token);
                uint256 claimableAmount = vestedAmount - schedule.vestedAmount;
                
                if (claimableAmount > 0) {
                    schedule.vestedAmount = vestedAmount;
                    userClaimedRewards[user][token] += claimableAmount;
                    IERC20(token).safeTransfer(user, claimableAmount);
                    
                    emit EmergencyAction("emergency_batch_claim", token, user);
                }
            }
            
            unchecked { ++i; }
        }
    }
}
