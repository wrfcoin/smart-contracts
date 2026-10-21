// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IParticipantTypeRegistry.sol";
import "./interfaces/IDynamicStakeCalculator.sol";
import "./interfaces/ISocialVerification.sol";
import "./interfaces/IWRFToken.sol";
import "./interfaces/ISlashingMechanism.sol";

/**
 * @title LayawayRegistration
 * @author WRFCoin Development Team
 * @notice Enables zero-upfront-cost registration with gradual stake accumulation through earnings
 * @dev Implements graduated earning allocation system for fair launch accessibility
 * 
 * Key Features:
 * - Provisional registration with zero upfront stake
 * - Graduated earnings allocation (100% -> 75% -> 50% -> 25% -> 0% to stake)
 * - Variable layaway periods based on participant type and verification
 * - Acceleration through manual payments
 * - Quality-based period reductions
 * - Post-slashing penalty extensions
 */
contract LayawayRegistration is
    Initializable,
    ReentrancyGuard,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                     ROLES & CONSTANTS
    // =============================================================
    
    bytes32 public constant EARNINGS_DISTRIBUTOR_ROLE = keccak256("EARNINGS_DISTRIBUTOR_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant PERCENTAGE_PRECISION = 10000; // 100.00%
    uint256 public constant MAX_LAYAWAY_PERIOD = 365 days; // 1 year maximum
    uint256 public constant MIN_LAYAWAY_PERIOD = 30 days; // 30 days minimum
    uint256 public constant QUALITY_BONUS_MAX = 2500; // 25% maximum reduction

    // =============================================================
    //                        ENUMS & STRUCTS
    // =============================================================
    
    enum LayawayStatus {
        PROVISIONAL,    // Registered but not fully staked
        ACTIVE,         // Fully staked and activated
        SUSPENDED,      // Temporarily suspended (slashing/violations)
        COMPLETED       // Fully completed layaway process
    }

    enum PaymentAsset {
        ETH,
        WRF,
        USDC,
        USDT,
        DAI
    }

    struct LayawayAccount {
        address participant;
        uint256 requiredStake;        // Total stake needed (USD equivalent in wei)
        uint256 accumulatedStake;     // Current accumulated amount (USD equivalent in wei)
        uint256 registrationTime;     // When layaway started
        uint256 activationTime;       // When fully activated (0 if pending)
        uint256 minimumLayawayPeriod; // Minimum time before withdrawal
        uint256 totalEarningsReceived; // Total earnings processed (USD equivalent)
        uint256 totalAllocatedToStake; // Amount allocated to stake (USD equivalent)
        LayawayStatus status;
        uint256 qualityMultiplier;    // Quality-based bonus (10000 = 100%)
        uint256 lastEarningTime;      // Last time earnings were processed
        bool emergencyExit;           // If emergency withdrawal was used
    }

    struct AccelerationHistory {
        uint256 amount;               // Amount in USD equivalent
        uint256 timestamp;
        PaymentAsset asset;
        uint256 blockNumber;
    }

    struct LayawayConfiguration {
        uint256 multiMethodPeriod;    // Multi-method participants (30 days)
        uint256 singleMethodPeriod;   // Verified single-method (60 days)
        uint256 unverifiedPeriod;     // Unverified new users (90 days)
        uint256 slashingMultiplier;   // Post-slashing multiplier (2x)
        uint256 completionBonus;      // Bonus for completing layaway
        uint256 referralReward;       // Reward for referrals
        bool emergencyWithdrawalEnabled; // Emergency withdrawal toggle
    }

    // =============================================================
    //                        STATE VARIABLES
    // =============================================================
    
    // Core registries and contracts
    IParticipantTypeRegistry public participantTypeRegistry;
    IDynamicStakeCalculator public stakeCalculator;
    ISocialVerification public socialVerification;
    IWRFToken public wrfToken;
    ISlashingMechanism public slashingMechanism;

    // Layaway accounts and configuration
    mapping(address => LayawayAccount) public layawayAccounts;
    mapping(address => AccelerationHistory[]) public accelerationHistory;
    mapping(address => mapping(address => uint256)) public referralRewards;
    LayawayConfiguration public config;

    // Supported payment assets
    mapping(PaymentAsset => address) public paymentAssets;
    mapping(PaymentAsset => bool) public assetEnabled;

    // Statistics and tracking
    uint256 public totalProvisionalParticipants;
    uint256 public totalActiveParticipants;
    uint256 public totalStakeAccumulated;
    uint256 public totalEarningsProcessed;

    // Rate limiting
    mapping(address => uint256) public lastProcessTime;
    uint256 public processingCooldown;

    // =============================================================
    //                        EVENTS
    // =============================================================
    
    event LayawayRegistered(
        address indexed participant,
        uint256 requiredStake,
        uint256 minimumPeriod,
        uint256 timestamp
    );

    event EarningsProcessed(
        address indexed participant,
        uint256 totalEarnings,
        uint256 allocatedToStake,
        uint256 allocatedToParticipant,
        uint256 stakeProgress
    );

    event StakeAccelerated(
        address indexed participant,
        uint256 amount,
        PaymentAsset asset,
        uint256 newAccumulated
    );

    event ParticipantActivated(
        address indexed participant,
        uint256 totalStakeAccumulated,
        uint256 activationTime
    );

    event EmergencyWithdrawal(
        address indexed participant,
        uint256 amount,
        uint256 penalty,
        uint256 timestamp
    );

    event LayawayConfigUpdated(
        uint256 multiMethodPeriod,
        uint256 singleMethodPeriod,
        uint256 unverifiedPeriod,
        uint256 slashingMultiplier
    );

    event QualityBonusApplied(
        address indexed participant,
        uint256 oldMultiplier,
        uint256 newMultiplier,
        uint256 periodReduction
    );

    // =============================================================
    //                        MODIFIERS
    // =============================================================
    
    modifier onlyRegistered(address participant) {
        require(layawayAccounts[participant].participant != address(0), "Not registered");
        _;
    }

    modifier rateLimited(address participant) {
        require(
            block.timestamp >= lastProcessTime[participant] + processingCooldown,
            "Rate limited"
        );
        lastProcessTime[participant] = block.timestamp;
        _;
    }

    modifier validAsset(PaymentAsset asset) {
        require(assetEnabled[asset], "Asset not supported");
        _;
    }

    // =============================================================
    //                        INITIALIZATION
    // =============================================================
    
    function initialize(
        address _participantTypeRegistry,
        address _stakeCalculator,
        address _socialVerification,
        address _wrfToken,
        address _slashingMechanism
    ) public initializer {
        __Pausable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        participantTypeRegistry = IParticipantTypeRegistry(_participantTypeRegistry);
        stakeCalculator = IDynamicStakeCalculator(_stakeCalculator);
        socialVerification = ISocialVerification(_socialVerification);
        wrfToken = IWRFToken(_wrfToken);
        slashingMechanism = ISlashingMechanism(_slashingMechanism);

        // Initialize default configuration
        config = LayawayConfiguration({
            multiMethodPeriod: 30 days,      // Multi-method participants
            singleMethodPeriod: 60 days,     // Verified single-method
            unverifiedPeriod: 90 days,       // Unverified new users
            slashingMultiplier: 20000,       // 2x multiplier (200%)
            completionBonus: 500,            // 5% completion bonus
            referralReward: 100,             // 1% referral reward
            emergencyWithdrawalEnabled: true
        });

        processingCooldown = 1 hours; // Prevent spam processing
    }

    // =============================================================
    //                    REGISTRATION FUNCTIONS
    // =============================================================
    
    /**
     * @notice Register for layaway system with zero upfront cost
     * @dev Creates provisional participant account with graduated earning allocation
     */
    function registerLayaway() external nonReentrant whenNotPaused {
        address participant = msg.sender;
        require(layawayAccounts[participant].participant == address(0), "Already registered");

        // Get required stake from calculator
        uint256 requiredStake = stakeCalculator.calculateRequiredStake(participant);
        require(requiredStake > 0, "Invalid stake requirement");

        // Determine minimum layaway period based on participant type
        uint256 minimumPeriod = _calculateLayawayPeriod(participant);

        // Create layaway account
        layawayAccounts[participant] = LayawayAccount({
            participant: participant,
            requiredStake: requiredStake,
            accumulatedStake: 0,
            registrationTime: block.timestamp,
            activationTime: 0,
            minimumLayawayPeriod: minimumPeriod,
            totalEarningsReceived: 0,
            totalAllocatedToStake: 0,
            status: LayawayStatus.PROVISIONAL,
            qualityMultiplier: PERCENTAGE_PRECISION, // 100% initially
            lastEarningTime: block.timestamp,
            emergencyExit: false
        });

        totalProvisionalParticipants++;

        emit LayawayRegistered(participant, requiredStake, minimumPeriod, block.timestamp);
    }

    /**
     * @notice Process earnings for a participant with graduated allocation
     * @param participant Address of the participant
     * @param earnings Total earnings amount (in USD equivalent)
     */
    function processEarnings(address participant, uint256 earnings)
        external
        onlyRole(EARNINGS_DISTRIBUTOR_ROLE)
        nonReentrant
        whenNotPaused
        onlyRegistered(participant)
        rateLimited(participant)
    {
        require(earnings > 0, "Invalid earnings amount");

        LayawayAccount storage account = layawayAccounts[participant];
        require(account.status == LayawayStatus.PROVISIONAL || account.status == LayawayStatus.ACTIVE, 
                "Invalid status");

        // Calculate allocation based on stake progress
        (uint256 toStake, uint256 toParticipant) = _calculateEarningsAllocation(
            earnings, 
            _getStakeProgress(participant)
        );

        // Update account with new earnings
        account.totalEarningsReceived += earnings;
        account.totalAllocatedToStake += toStake;
        account.accumulatedStake += toStake;
        account.lastEarningTime = block.timestamp;

        totalEarningsProcessed += earnings;
        totalStakeAccumulated += toStake;

        // Check if participant can be activated
        if (account.status == LayawayStatus.PROVISIONAL && _canActivateParticipant(participant)) {
            _activateParticipant(participant);
        }

        // Transfer participant portion if any
        if (toParticipant > 0) {
            IERC20(address(wrfToken)).safeTransfer(participant, toParticipant);
        }

        emit EarningsProcessed(
            participant,
            earnings,
            toStake,
            toParticipant,
            _getStakeProgress(participant)
        );
    }

    /**
     * @notice Make manual payment to accelerate stake accumulation
     * @param amount Amount to pay (in asset units)
     * @param asset Type of asset for payment
     */
    function accelerateStake(uint256 amount, PaymentAsset asset)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyRegistered(msg.sender)
        validAsset(asset)
    {
        require(amount > 0, "Invalid amount");

        LayawayAccount storage account = layawayAccounts[msg.sender];
        require(account.status == LayawayStatus.PROVISIONAL, "Not in layaway");

        // Convert to USD equivalent
        uint256 usdAmount = _convertToUSD(amount, asset);
        require(usdAmount > 0, "Invalid USD conversion");

        // Ensure we don't exceed required stake
        uint256 remainingStake = account.requiredStake - account.accumulatedStake;
        if (usdAmount > remainingStake) {
            usdAmount = remainingStake;
        }

        // Process payment based on asset type
        _processPayment(msg.sender, amount, asset);

        // Update account
        account.accumulatedStake += usdAmount;
        totalStakeAccumulated += usdAmount;

        // Record acceleration history
        accelerationHistory[msg.sender].push(AccelerationHistory({
            amount: usdAmount,
            timestamp: block.timestamp,
            asset: asset,
            blockNumber: block.number
        }));

        // Check for activation
        if (_canActivateParticipant(msg.sender)) {
            _activateParticipant(msg.sender);
        }

        emit StakeAccelerated(msg.sender, usdAmount, asset, account.accumulatedStake);
    }

    // =============================================================
    //                    ACTIVATION FUNCTIONS
    // =============================================================
    
    /**
     * @notice Check if participant is eligible for activation
     * @param participant Address to check
     * @return eligible True if can be activated
     */
    function checkActivationEligibility(address participant)
        external
        view
        onlyRegistered(participant)
        returns (bool eligible)
    {
        return _canActivateParticipant(participant);
    }

    /**
     * @notice Manually activate participant if eligible
     * @param participant Address to activate
     */
    function activateParticipant(address participant)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
        onlyRegistered(participant)
    {
        require(_canActivateParticipant(participant), "Not eligible for activation");
        _activateParticipant(participant);
    }

    // =============================================================
    //                    WITHDRAWAL FUNCTIONS
    // =============================================================
    
    /**
     * @notice Emergency withdrawal of accumulated stake with penalties
     * @dev Can only be used after minimum layaway period or in emergency
     */
    function withdrawAccumulated() external nonReentrant whenNotPaused onlyRegistered(msg.sender) {
        LayawayAccount storage account = layawayAccounts[msg.sender];
        require(config.emergencyWithdrawalEnabled, "Emergency withdrawals disabled");
        require(account.accumulatedStake > 0, "No stake to withdraw");
        require(
            block.timestamp >= account.registrationTime + account.minimumLayawayPeriod,
            "Minimum period not met"
        );

        uint256 withdrawAmount = account.accumulatedStake;
        uint256 penalty = 0;

        // Apply penalty if withdrawing before activation
        if (account.status == LayawayStatus.PROVISIONAL) {
            penalty = withdrawAmount * 1000 / PERCENTAGE_PRECISION; // 10% penalty
            withdrawAmount -= penalty;
        }

        // Mark as emergency exit
        account.emergencyExit = true;
        account.status = LayawayStatus.SUSPENDED;
        account.accumulatedStake = 0;

        // Update statistics
        totalStakeAccumulated -= (withdrawAmount + penalty);
        if (account.status == LayawayStatus.PROVISIONAL) {
            totalProvisionalParticipants--;
        }

        // Transfer withdrawal amount
        IERC20(address(wrfToken)).safeTransfer(msg.sender, withdrawAmount);

        emit EmergencyWithdrawal(msg.sender, withdrawAmount, penalty, block.timestamp);
    }

    // =============================================================
    //                    ADMINISTRATIVE FUNCTIONS
    // =============================================================
    
    /**
     * @notice Update layaway configuration
     */
    function updateLayawayConfiguration(
        uint256 _multiMethodPeriod,
        uint256 _singleMethodPeriod,
        uint256 _unverifiedPeriod,
        uint256 _slashingMultiplier
    ) external onlyRole(ADMIN_ROLE) {
        require(_multiMethodPeriod >= MIN_LAYAWAY_PERIOD && _multiMethodPeriod <= MAX_LAYAWAY_PERIOD, 
                "Invalid multi-method period");
        require(_singleMethodPeriod >= MIN_LAYAWAY_PERIOD && _singleMethodPeriod <= MAX_LAYAWAY_PERIOD, 
                "Invalid single-method period");
        require(_unverifiedPeriod >= MIN_LAYAWAY_PERIOD && _unverifiedPeriod <= MAX_LAYAWAY_PERIOD, 
                "Invalid unverified period");
        require(_slashingMultiplier >= PERCENTAGE_PRECISION && _slashingMultiplier <= 30000, 
                "Invalid slashing multiplier");

        config.multiMethodPeriod = _multiMethodPeriod;
        config.singleMethodPeriod = _singleMethodPeriod;
        config.unverifiedPeriod = _unverifiedPeriod;
        config.slashingMultiplier = _slashingMultiplier;

        emit LayawayConfigUpdated(
            _multiMethodPeriod,
            _singleMethodPeriod,
            _unverifiedPeriod,
            _slashingMultiplier
        );
    }

    /**
     * @notice Apply quality bonus to reduce layaway period
     * @param participant Address of participant
     * @param newMultiplier New quality multiplier (10000 = 100%)
     */
    function applyQualityBonus(address participant, uint256 newMultiplier)
        external
        onlyRole(ADMIN_ROLE)
        onlyRegistered(participant)
    {
        require(newMultiplier >= 7500 && newMultiplier <= 12500, "Invalid multiplier range"); // 75%-125%

        LayawayAccount storage account = layawayAccounts[participant];
        uint256 oldMultiplier = account.qualityMultiplier;
        
        account.qualityMultiplier = newMultiplier;

        // Calculate period reduction if multiplier improved
        uint256 periodReduction = 0;
        if (newMultiplier > PERCENTAGE_PRECISION) {
            periodReduction = account.minimumLayawayPeriod * 
                              (newMultiplier - PERCENTAGE_PRECISION) / 
                              PERCENTAGE_PRECISION;
            
            // Cap at maximum quality bonus
            uint256 maxReduction = account.minimumLayawayPeriod * QUALITY_BONUS_MAX / PERCENTAGE_PRECISION;
            if (periodReduction > maxReduction) {
                periodReduction = maxReduction;
            }
            
            account.minimumLayawayPeriod -= periodReduction;
        }

        emit QualityBonusApplied(participant, oldMultiplier, newMultiplier, periodReduction);
    }

    /**
     * @notice Handle slashing event - reset accumulation and extend period
     * @param participant Address of participant being slashed
     */
    function handleSlashing(address participant)
        external
        onlyRole(EARNINGS_DISTRIBUTOR_ROLE)
        onlyRegistered(participant)
    {
        LayawayAccount storage account = layawayAccounts[participant];
        
        // Extend layaway period by slashing multiplier
        account.minimumLayawayPeriod = account.minimumLayawayPeriod * 
                                       config.slashingMultiplier / 
                                       PERCENTAGE_PRECISION;
        
        // Reset accumulated stake (harsh penalty)
        totalStakeAccumulated -= account.accumulatedStake;
        account.accumulatedStake = 0;
        account.totalAllocatedToStake = 0;
        
        // Suspend account temporarily
        account.status = LayawayStatus.SUSPENDED;
        
        // Update registration time to restart period
        account.registrationTime = block.timestamp;
    }

    /**
     * @notice Configure supported payment assets
     */
    function configurePaymentAsset(
        PaymentAsset asset,
        address tokenAddress,
        bool enabled
    ) external onlyRole(ADMIN_ROLE) {
        paymentAssets[asset] = tokenAddress;
        assetEnabled[asset] = enabled;
    }

    /**
     * @notice Bulk process earnings for multiple participants
     * @param participants Array of participant addresses
     * @param earnings Array of earnings amounts
     */
    function bulkProcessEarnings(
        address[] calldata participants,
        uint256[] calldata earnings
    ) external onlyRole(EARNINGS_DISTRIBUTOR_ROLE) nonReentrant whenNotPaused {
        require(participants.length == earnings.length, "Array length mismatch");
        require(participants.length <= 100, "Batch too large");

        for (uint256 i = 0; i < participants.length; i++) {
            if (layawayAccounts[participants[i]].participant != address(0) && 
                earnings[i] > 0 &&
                block.timestamp >= lastProcessTime[participants[i]] + processingCooldown) {
                
                // Process without individual checks to save gas
                _processEarningsInternal(participants[i], earnings[i]);
            }
        }
    }

    // =============================================================
    //                    VIEW FUNCTIONS
    // =============================================================
    
    /**
     * @notice Get stake progress percentage for participant
     * @param participant Address to check
     * @return progress Percentage completed (0-10000 for 0-100%)
     */
    function getStakeProgress(address participant)
        external
        view
        onlyRegistered(participant)
        returns (uint256 progress)
    {
        return _getStakeProgress(participant);
    }

    /**
     * @notice Get detailed layaway account information
     * @param participant Address to query
     * @return account Complete LayawayAccount struct
     */
    function getLayawayAccount(address participant)
        external
        view
        onlyRegistered(participant)
        returns (LayawayAccount memory account)
    {
        return layawayAccounts[participant];
    }

    /**
     * @notice Get acceleration history for participant
     * @param participant Address to query
     * @return history Array of acceleration payments
     */
    function getAccelerationHistory(address participant)
        external
        view
        returns (AccelerationHistory[] memory history)
    {
        return accelerationHistory[participant];
    }

    /**
     * @notice Preview earnings allocation for given amount and progress
     * @param participant Address of participant
     * @param earnings Earnings amount to preview
     * @return toStake Amount that would go to stake
     * @return toParticipant Amount that would go to participant
     */
    function previewEarningsAllocation(address participant, uint256 earnings)
        external
        view
        onlyRegistered(participant)
        returns (uint256 toStake, uint256 toParticipant)
    {
        uint256 progress = _getStakeProgress(participant);
        return _calculateEarningsAllocation(earnings, progress);
    }

    /**
     * @notice Get system statistics
     */
    function getSystemStats()
        external
        view
        returns (
            uint256 provisional,
            uint256 active,
            uint256 totalStake,
            uint256 totalEarnings
        )
    {
        return (
            totalProvisionalParticipants,
            totalActiveParticipants,
            totalStakeAccumulated,
            totalEarningsProcessed
        );
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================
    
    /**
     * @notice Calculate layaway period based on participant type and verification
     */
    function _calculateLayawayPeriod(address participant) internal view returns (uint256) {
        // Get participant type from registry
        (bool isMultiMethod, bool isVerified, bool hasSlashing) = 
            participantTypeRegistry.getParticipantInfo(participant);

        uint256 basePeriod;
        
        if (isMultiMethod) {
            basePeriod = config.multiMethodPeriod;      // 30 days
        } else if (isVerified) {
            basePeriod = config.singleMethodPeriod;     // 60 days
        } else {
            basePeriod = config.unverifiedPeriod;       // 90 days
        }

        // Apply slashing penalty if exists
        if (hasSlashing) {
            basePeriod = basePeriod * config.slashingMultiplier / PERCENTAGE_PRECISION; // 2x
        }

        return basePeriod;
    }

    /**
     * @notice Calculate earnings allocation based on stake progress
     */
    function _calculateEarningsAllocation(uint256 earnings, uint256 stakeProgress)
        internal
        pure
        returns (uint256 toStake, uint256 toParticipant)
    {
        if (stakeProgress < 2500) {          // First 25%
            return (earnings, 0);                                    // 100% to stake
        } else if (stakeProgress < 5000) {   // Next 25% (25-50%)
            return (earnings * 7500 / PERCENTAGE_PRECISION, earnings * 2500 / PERCENTAGE_PRECISION); // 75%/25%
        } else if (stakeProgress < 7500) {   // Next 25% (50-75%)
            return (earnings * 5000 / PERCENTAGE_PRECISION, earnings * 5000 / PERCENTAGE_PRECISION); // 50%/50%
        } else if (stakeProgress < 10000) {  // Final 25% (75-100%)
            return (earnings * 2500 / PERCENTAGE_PRECISION, earnings * 7500 / PERCENTAGE_PRECISION); // 25%/75%
        } else {                             // After 100%
            return (0, earnings);                                    // 100% to participant
        }
    }

    /**
     * @notice Get stake completion progress as percentage
     */
    function _getStakeProgress(address participant) internal view returns (uint256) {
        LayawayAccount memory account = layawayAccounts[participant];
        if (account.requiredStake == 0) return 0;
        
        uint256 progress = account.accumulatedStake * PERCENTAGE_PRECISION / account.requiredStake;
        return progress > PERCENTAGE_PRECISION ? PERCENTAGE_PRECISION : progress;
    }

    /**
     * @notice Check if participant can be activated
     */
    function _canActivateParticipant(address participant) internal view returns (bool) {
        LayawayAccount memory account = layawayAccounts[participant];
        
        return account.status == LayawayStatus.PROVISIONAL &&
               account.accumulatedStake >= account.requiredStake &&
               block.timestamp >= account.registrationTime + account.minimumLayawayPeriod;
    }

    /**
     * @notice Activate participant from provisional to active
     */
    function _activateParticipant(address participant) internal {
        LayawayAccount storage account = layawayAccounts[participant];
        
        account.status = LayawayStatus.ACTIVE;
        account.activationTime = block.timestamp;
        
        // Update statistics
        totalProvisionalParticipants--;
        totalActiveParticipants++;
        
        // Apply completion bonus
        uint256 bonus = account.accumulatedStake * config.completionBonus / PERCENTAGE_PRECISION;
        if (bonus > 0) {
            IERC20(address(wrfToken)).safeTransfer(participant, bonus);
        }

        emit ParticipantActivated(participant, account.accumulatedStake, block.timestamp);
    }

    /**
     * @notice Process payment for acceleration
     */
    function _processPayment(address participant, uint256 amount, PaymentAsset asset) internal {
        if (asset == PaymentAsset.ETH) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            address tokenAddress = paymentAssets[asset];
            require(tokenAddress != address(0), "Asset not configured");
            
            IERC20(tokenAddress).safeTransferFrom(participant, address(this), amount);
        }
    }

    /**
     * @notice Convert asset amount to USD equivalent
     * @dev This would integrate with price oracles in production
     */
    function _convertToUSD(uint256 amount, PaymentAsset asset) internal pure returns (uint256) {
        // Simplified conversion - in production, use Chainlink or other oracles
        // For now, assume 1:1 conversion for demonstration
        return amount;
    }

    /**
     * @notice Internal earnings processing without external checks
     */
    function _processEarningsInternal(address participant, uint256 earnings) internal {
        LayawayAccount storage account = layawayAccounts[participant];
        
        (uint256 toStake, uint256 toParticipant) = _calculateEarningsAllocation(
            earnings,
            _getStakeProgress(participant)
        );

        account.totalEarningsReceived += earnings;
        account.totalAllocatedToStake += toStake;
        account.accumulatedStake += toStake;
        account.lastEarningTime = block.timestamp;
        lastProcessTime[participant] = block.timestamp;

        totalEarningsProcessed += earnings;
        totalStakeAccumulated += toStake;

        if (account.status == LayawayStatus.PROVISIONAL && _canActivateParticipant(participant)) {
            _activateParticipant(participant);
        }

        if (toParticipant > 0) {
            IERC20(address(wrfToken)).safeTransfer(participant, toParticipant);
        }

        emit EarningsProcessed(participant, earnings, toStake, toParticipant, _getStakeProgress(participant));
    }

    // =============================================================
    //                    EMERGENCY FUNCTIONS
    // =============================================================
    
    /**
     * @notice Emergency pause all operations
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Resume operations after emergency
     */
    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of contract funds
     */
    function emergencyWithdrawFunds(address asset, uint256 amount)
        external
        onlyRole(EMERGENCY_ROLE)
    {
        if (asset == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "LayawayRegistration: ETH emergency withdrawal failed");
        } else {
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
    }

    // =============================================================
    //                    RECEIVE & FALLBACK
    // =============================================================
    
    /**
     * @notice Receive ETH payments for acceleration
     */
    receive() external payable {
        // ETH received for acceleration - handled in accelerateStake
    }
}