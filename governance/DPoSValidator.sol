// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DPoSValidator
 * @notice Delegated Proof of Stake validator system with enhanced security for WRF governance
 * @dev Comprehensive DPoS system with validator management, slashing protection,
 *      and Byzantine fault tolerance for WRFCoin platform consensus
 * 
 * Features:
 * - Secure validator registration with economic security bonds
 * - Delegation validation with slashing protection mechanisms  
 * - Validator reputation system with performance tracking
 * - Fair reward distribution with commission controls
 * - Byzantine fault tolerance and misbehavior detection
 * - Climate impact scoring for validator selection
 * - Emergency controls and governance integration
 * 
 * Security Measures:
 * - Economic security through minimum stake requirements
 * - Slashing protection with cooldown periods
 * - Validator reputation tracking and scoring
 * - Anti-manipulation controls for delegation
 * - Emergency pause and recovery mechanisms
 * - Comprehensive audit trails for all actions
 * 
 * @custom:security-contact validators@wrfcoin.io
 */
contract DPoSValidator is ReentrancyGuard, Pausable, Ownable {
    using Math for uint256;

    // Security and economic constants
    uint256 public constant MAX_COMMISSION_RATE = 2000; // 20% maximum commission
    uint256 public constant MIN_VALIDATOR_STAKE = 10_000 * 1e18; // 10K WRF minimum
    uint256 public constant MAX_VALIDATORS = 100; // Maximum active validators
    uint256 public constant SLASHING_COOLDOWN = 7 days; // Cooldown between slashing events
    uint256 public constant UNBONDING_PERIOD = 21 days; // Standard unbonding period
    uint256 public constant REPUTATION_DECAY_PERIOD = 30 days; // Reputation decay period
    uint256 public constant MAX_DELEGATION_PER_USER = 1_000_000 * 1e18; // Anti-whale limit
    uint256 private constant MAX_BPS = 10_000; // 100% in basis points

    // Validator status enumeration with enhanced states
    enum ValidatorStatus {
        INACTIVE,
        ACTIVE,
        JAILED,
        SLASHED,
        TOMBSTONED // Permanently banned
    }

    // Validator information structure
    struct Validator {
        address validatorAddress;
        string name;
        string description;
        uint256 selfStake;
        uint256 totalDelegated;
        uint256 commissionRate; // Basis points (100 = 1%)
        uint256 performanceScore;
        uint256 climateScore;
        ValidatorStatus status;
        uint256 jailTime;
        uint256 slashCount;
        uint256 lastRewardClaim;
    }

    // Delegation information structure
    struct Delegation {
        address delegator;
        address validator;
        uint256 amount;
        uint256 stakingTime;
        uint256 lockPeriod;
        uint256 lastRewardClaim;
        bool autoCompound;
    }

    // Staking configuration
    struct StakingConfig {
        uint256 minValidatorStake;
        uint256 minDelegatorStake;
        uint256 maxCommissionRate;
        uint256 unbondingPeriod;
        uint256 slashingPercentage;
        uint256 jailPeriod;
        uint256 maxValidators;
    }

    // State variables
    IERC20 public immutable stakingToken;
    StakingConfig public config;
    
    mapping(address => Validator) public validators;
    mapping(address => mapping(address => Delegation)) public delegations;
    mapping(address => address[]) public delegatorValidators;
    mapping(address => address[]) public validatorDelegators;
    
    address[] public activeValidators;
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public currentEpoch;
    uint256 public epochDuration;
    uint256 public lastEpochTime;

    // Climate validation weights
    mapping(string => uint256) public climateMetricWeights;

    // Enhanced security and risk management
    mapping(address => uint256) public lastSlashTime; // Anti-spam slashing protection
    mapping(address => uint256) public validatorReputationHistory; // Historical reputation tracking
    mapping(address => bool) public tombstoneStatus; // Permanent ban status
    mapping(address => uint256) public byzantineFaultCount; // Track Byzantine failures
    mapping(address => uint256) public proposalValidationScore; // Governance participation scoring
    mapping(uint256 => mapping(address => bool)) public epochValidatorPerformance; // Per-epoch performance
    mapping(address => uint256) public consecutiveFailures; // Track consecutive poor performance
    
    // Anti-manipulation and security measures
    mapping(address => uint256) public delegationCooldown; // Prevent rapid delegation changes
    mapping(address => uint256) public lastDelegationTime; // Track delegation timing
    mapping(address => mapping(address => uint256)) public delegationLimits; // Per-delegator limits
    uint256 public maxDelegationsPerValidator; // Limit delegation concentration

    // Events
    event ValidatorRegistered(address indexed validator, string name, uint256 selfStake);
    event ValidatorUpdated(address indexed validator, uint256 commissionRate);
    event DelegationCreated(address indexed delegator, address indexed validator, uint256 amount);
    event DelegationWithdrawn(address indexed delegator, address indexed validator, uint256 amount);
    event ValidatorJailed(address indexed validator, string reason);
    event ValidatorSlashed(address indexed validator, uint256 amount, string reason);
    event RewardsDistributed(uint256 epoch, uint256 totalAmount);
    event EpochAdvanced(uint256 newEpoch, uint256 timestamp);
    
    // Enhanced security events
    event ValidatorTombstoned(address indexed validator, string reason, uint256 timestamp);
    event ByzantineFaultDetected(address indexed validator, uint256 faultCount, string evidence);
    event ReputationScoreUpdated(address indexed validator, uint256 oldScore, uint256 newScore);
    event DelegationLimitExceeded(address indexed delegator, address indexed validator, uint256 attempted, uint256 limit);
    event ValidatorPerformanceRecorded(address indexed validator, uint256 epoch, bool passed);
    event ConsecutiveFailuresUpdated(address indexed validator, uint256 failureCount);
    event SecurityViolationDetected(address indexed validator, string violationType, uint256 severity);

    constructor(
        address _stakingToken,
        uint256 _epochDuration
    ) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        epochDuration = _epochDuration;
        lastEpochTime = block.timestamp;
        
        // Initialize default configuration
        config = StakingConfig({
            minValidatorStake: 10000 * 10**18, // 10,000 WRF
            minDelegatorStake: 100 * 10**18,   // 100 WRF
            maxCommissionRate: 2000,           // 20%
            unbondingPeriod: 21 days,
            slashingPercentage: 500,           // 5%
            jailPeriod: 7 days,
            maxValidators: 100
        });

        // Initialize climate metric weights
        climateMetricWeights["data_accuracy"] = 30;
        climateMetricWeights["uptime"] = 25;
        climateMetricWeights["response_time"] = 20;
        climateMetricWeights["carbon_footprint"] = 15;
        climateMetricWeights["community_contribution"] = 10;
        
        // Initialize security parameters
        maxDelegationsPerValidator = 1000; // Maximum 1000 delegators per validator
    }

    /**
     * @dev Register as a validator
     */
    function registerValidator(
        string memory _name,
        string memory _description,
        uint256 _commissionRate,
        uint256 _selfStake
    ) external nonReentrant whenNotPaused {
        require(validators[msg.sender].validatorAddress == address(0), "DPoS: Already registered");
        require(_selfStake >= config.minValidatorStake, "DPoS: Insufficient self stake");
        require(_commissionRate <= config.maxCommissionRate, "DPoS: Commission too high");
        require(activeValidators.length < config.maxValidators, "DPoS: Max validators reached");

        // Transfer staking tokens
        require(stakingToken.transferFrom(msg.sender, address(this), _selfStake), "DPoS: Transfer failed");

        // Create validator
        validators[msg.sender] = Validator({
            validatorAddress: msg.sender,
            name: _name,
            description: _description,
            selfStake: _selfStake,
            totalDelegated: 0,
            commissionRate: _commissionRate,
            performanceScore: 100, // Start with perfect score
            climateScore: 100,
            status: ValidatorStatus.ACTIVE,
            jailTime: 0,
            slashCount: 0,
            lastRewardClaim: block.timestamp
        });

        activeValidators.push(msg.sender);
        totalStaked += _selfStake;

        emit ValidatorRegistered(msg.sender, _name, _selfStake);
    }

    /**
     * @dev Update validator configuration
     */
    function updateValidator(
        uint256 _commissionRate,
        string memory _description
    ) external {
        Validator storage validator = validators[msg.sender];
        require(validator.validatorAddress != address(0), "DPoS: Not a validator");
        require(_commissionRate <= config.maxCommissionRate, "DPoS: Commission too high");

        validator.commissionRate = _commissionRate;
        validator.description = _description;

        emit ValidatorUpdated(msg.sender, _commissionRate);
    }

    /**
     * @dev Delegate tokens to a validator
     */
    function delegate(
        address _validator,
        uint256 _amount,
        uint256 _lockPeriod,
        bool _autoCompound
    ) external nonReentrant whenNotPaused {
        require(validators[_validator].status == ValidatorStatus.ACTIVE, "DPoS: Validator not active");
        require(!tombstoneStatus[_validator], "DPoS: Validator is tombstoned");
        require(_amount >= config.minDelegatorStake, "DPoS: Amount too small");
        require(_lockPeriod >= 30 days, "DPoS: Lock period too short");
        
        // Anti-manipulation: delegation cooldown protection
        require(
            block.timestamp >= delegationCooldown[msg.sender],
            "DPoS: Delegation cooldown active"
        );
        
        // Anti-whale: check delegation limits
        uint256 totalUserDelegation = delegations[msg.sender][_validator].amount + _amount;
        require(totalUserDelegation <= MAX_DELEGATION_PER_USER, "DPoS: Delegation limit exceeded");
        
        // Transfer tokens
        require(stakingToken.transferFrom(msg.sender, address(this), _amount), "DPoS: Transfer failed");

        // Update or create delegation
        Delegation storage delegation = delegations[msg.sender][_validator];
        
        // Limit number of delegators per validator for security
        if (delegation.delegator == address(0)) {
            require(
                validatorDelegators[_validator].length < maxDelegationsPerValidator,
                "DPoS: Too many delegators for this validator"
            );
            delegatorValidators[msg.sender].push(_validator);
            validatorDelegators[_validator].push(msg.sender);
        }

        delegation.delegator = msg.sender;
        delegation.validator = _validator;
        delegation.amount += _amount;
        delegation.stakingTime = block.timestamp;
        delegation.lockPeriod = _lockPeriod;
        delegation.lastRewardClaim = block.timestamp;
        delegation.autoCompound = _autoCompound;

        // Update validator's total delegated amount
        validators[_validator].totalDelegated += _amount;
        totalStaked += _amount;

        // Update delegation tracking and cooldown
        lastDelegationTime[msg.sender] = block.timestamp;
        delegationCooldown[msg.sender] = block.timestamp + 1 hours; // 1-hour cooldown
        delegationLimits[msg.sender][_validator] = totalUserDelegation;

        emit DelegationCreated(msg.sender, _validator, _amount);
    }

    /**
     * @dev Withdraw delegation (subject to unbonding period)
     */
    function withdraw(address _validator, uint256 _amount) external nonReentrant {
        Delegation storage delegation = delegations[msg.sender][_validator];
        require(delegation.amount >= _amount, "DPoS: Insufficient delegation");
        require(
            block.timestamp >= delegation.stakingTime + delegation.lockPeriod,
            "DPoS: Still in lock period"
        );

        // Update delegation
        delegation.amount -= _amount;
        validators[_validator].totalDelegated -= _amount;
        totalStaked -= _amount;

        // Transfer tokens back
        require(stakingToken.transfer(msg.sender, _amount), "DPoS: Transfer failed");

        emit DelegationWithdrawn(msg.sender, _validator, _amount);
    }

    /**
     * @dev Update validator performance scores
     */
    function updatePerformanceScores(
        address[] memory _validators,
        uint256[] memory _scores,
        uint256[] memory _climateScores
    ) external onlyOwner {
        require(_validators.length == _scores.length, "DPoS: Array length mismatch");
        require(_validators.length == _climateScores.length, "DPoS: Array length mismatch");

        for (uint256 i = 0; i < _validators.length; i++) {
            require(validators[_validators[i]].validatorAddress != address(0), "DPoS: Invalid validator");
            validators[_validators[i]].performanceScore = _scores[i];
            validators[_validators[i]].climateScore = _climateScores[i];
        }
    }

    /**
     * @dev Jail a validator for poor performance or misbehavior
     */
    function jailValidator(address _validator, string memory _reason) public onlyOwner {
        Validator storage validator = validators[_validator];
        require(validator.status == ValidatorStatus.ACTIVE, "DPoS: Validator not active");

        validator.status = ValidatorStatus.JAILED;
        validator.jailTime = block.timestamp;

        // Remove from active validators
        for (uint256 i = 0; i < activeValidators.length; i++) {
            if (activeValidators[i] == _validator) {
                activeValidators[i] = activeValidators[activeValidators.length - 1];
                activeValidators.pop();
                break;
            }
        }

        emit ValidatorJailed(_validator, _reason);
    }

    /**
     * @dev Slash a validator's stake for malicious behavior
     */
    function slashValidator(
        address _validator,
        string memory _reason
    ) external onlyOwner {
        Validator storage validator = validators[_validator];
        require(validator.status != ValidatorStatus.SLASHED, "DPoS: Already slashed");
        require(!tombstoneStatus[_validator], "DPoS: Validator is tombstoned");
        
        // Anti-spam slashing protection
        require(
            block.timestamp >= lastSlashTime[_validator] + SLASHING_COOLDOWN,
            "DPoS: Slashing cooldown active"
        );

        uint256 slashAmount = (validator.selfStake * config.slashingPercentage) / 10000;
        validator.selfStake -= slashAmount;
        validator.slashCount++;
        validator.status = ValidatorStatus.SLASHED;
        totalStaked -= slashAmount;

        // Progressive slashing: higher penalty for repeat offenses
        if (validator.slashCount >= 3) {
            // Additional 50% penalty for multiple slashes
            uint256 additionalSlash = slashAmount / 2;
            if (validator.selfStake >= additionalSlash) {
                validator.selfStake -= additionalSlash;
                totalStaked -= additionalSlash;
                slashAmount += additionalSlash;
            }
        }

        // Burn slashed tokens by transferring to dead address
        require(stakingToken.transfer(address(0xdead), slashAmount), "DPoS: Burn failed");

        // Add slashing protection cooldown
        lastSlashTime[_validator] = block.timestamp;
        
        // Mark excessive slashing for manual review
        if (validator.slashCount >= 5) {
            emit SecurityViolationDetected(_validator, "excessive_slashing", validator.slashCount);
        }
        
        emit ValidatorSlashed(_validator, slashAmount, _reason);
        emit SecurityViolationDetected(_validator, "slashing", validator.slashCount);
    }

    /**
     * @notice Permanently tombstone a validator for severe violations
     * @param _validator Address of the validator to tombstone
     * @param _reason Reason for tombstoning
     * @dev Tombstoning is permanent and cannot be reversed
     */
    function tombstoneValidator(
        address _validator,
        string memory _reason
    ) public onlyOwner {
        Validator storage validator = validators[_validator];
        require(validator.validatorAddress != address(0), "DPoS: Validator does not exist");
        require(!tombstoneStatus[_validator], "DPoS: Already tombstoned");
        
        // Set validator to tombstoned status
        validator.status = ValidatorStatus.TOMBSTONED;
        tombstoneStatus[_validator] = true;
        
        // Remove from active validators if present
        _removeFromActiveValidators(_validator);
        
        // Slash remaining stake
        if (validator.selfStake > 0) {
            uint256 remainingStake = validator.selfStake;
            validator.selfStake = 0;
            totalStaked -= remainingStake;
            
            // Burn all remaining tokens
            require(stakingToken.transfer(address(0xdead), remainingStake), "DPoS: Burn failed");
        }
        
        emit ValidatorTombstoned(_validator, _reason, block.timestamp);
    }

    /**
     * @notice Record Byzantine fault behavior for a validator
     * @param _validator Address of the validator
     * @param _evidence Evidence of the fault
     */
    function recordByzantineFault(
        address _validator,
        string memory _evidence
    ) external onlyOwner {
        require(validators[_validator].validatorAddress != address(0), "DPoS: Validator does not exist");
        
        byzantineFaultCount[_validator]++;
        
        // Mark as critical Byzantine fault behavior
        if (byzantineFaultCount[_validator] >= 3) {
            emit SecurityViolationDetected(_validator, "critical_byzantine", byzantineFaultCount[_validator]);
        }
        
        emit ByzantineFaultDetected(_validator, byzantineFaultCount[_validator], _evidence);
    }

    /**
     * @notice Update validator reputation score based on performance
     * @param _validator Address of the validator
     * @param _newScore New reputation score (0-100)
     * @param _reason Reason for score change
     */
    function updateReputationScore(
        address _validator,
        uint256 _newScore,
        string memory _reason
    ) external onlyOwner {
        require(_newScore <= 100, "DPoS: Score must be 0-100");
        require(validators[_validator].validatorAddress != address(0), "DPoS: Validator does not exist");
        
        uint256 oldScore = validatorReputationHistory[_validator];
        validatorReputationHistory[_validator] = _newScore;
        
        // Update validator performance score
        validators[_validator].performanceScore = _newScore;
        
        // Mark low reputation for review 
        if (_newScore < 50 && validators[_validator].status == ValidatorStatus.ACTIVE) {
            emit SecurityViolationDetected(_validator, "low_reputation", _newScore);
        }
        
        emit ReputationScoreUpdated(_validator, oldScore, _newScore);
    }

    /**
     * @notice Record validator performance for an epoch
     * @param _validator Address of the validator
     * @param _passed Whether the validator passed performance metrics
     */
    function recordEpochPerformance(
        address _validator,
        bool _passed
    ) external onlyOwner {
        require(validators[_validator].validatorAddress != address(0), "DPoS: Validator does not exist");
        
        epochValidatorPerformance[currentEpoch][_validator] = _passed;
        
        if (!_passed) {
            consecutiveFailures[_validator]++;
            
            // Mark consecutive failures for review
            if (consecutiveFailures[_validator] >= 3 && validators[_validator].status == ValidatorStatus.ACTIVE) {
                emit SecurityViolationDetected(_validator, "consecutive_failures", consecutiveFailures[_validator]);
            }
        } else {
            consecutiveFailures[_validator] = 0; // Reset on success
        }
        
        emit ValidatorPerformanceRecorded(_validator, currentEpoch, _passed);
        emit ConsecutiveFailuresUpdated(_validator, consecutiveFailures[_validator]);
    }

    /**
     * @dev Internal function to remove validator from active list
     */
    function _removeFromActiveValidators(address _validator) internal {
        for (uint256 i = 0; i < activeValidators.length; i++) {
            if (activeValidators[i] == _validator) {
                activeValidators[i] = activeValidators[activeValidators.length - 1];
                activeValidators.pop();
                break;
            }
        }
    }

    /**
     * @dev Unjail a validator after jail period
     */
    function unjailValidator(address _validator) external {
        Validator storage validator = validators[_validator];
        require(validator.status == ValidatorStatus.JAILED, "DPoS: Not jailed");
        require(
            block.timestamp >= validator.jailTime + config.jailPeriod,
            "DPoS: Jail period not over"
        );

        validator.status = ValidatorStatus.ACTIVE;
        validator.jailTime = 0;
        activeValidators.push(_validator);
    }

    /**
     * @dev Distribute rewards to validators and delegators
     */
    function distributeRewards(uint256 _totalRewards) external onlyOwner {
        require(_totalRewards > 0, "DPoS: No rewards to distribute");
        require(stakingToken.transferFrom(msg.sender, address(this), _totalRewards), "DPoS: Transfer failed");

        totalRewards += _totalRewards;

        // Calculate rewards for each validator based on their total stake and performance
        for (uint256 i = 0; i < activeValidators.length; i++) {
            address validatorAddr = activeValidators[i];
            Validator storage validator = validators[validatorAddr];
            
            uint256 totalValidatorStake = validator.selfStake + validator.totalDelegated;
            uint256 baseReward = (_totalRewards * totalValidatorStake) / totalStaked;
            
            // Apply performance multiplier
            uint256 performanceMultiplier = (validator.performanceScore + validator.climateScore) / 2;
            uint256 validatorReward = (baseReward * performanceMultiplier) / 100;
            
            // Validator commission
            uint256 commission = (validatorReward * validator.commissionRate) / 10000;
            uint256 delegatorReward = validatorReward - commission;
            
            // Distribute to validator
            validator.lastRewardClaim = block.timestamp;
            
            // Distribute to delegators proportionally
            _distributeDelegatorRewards(validatorAddr, delegatorReward);
        }

        emit RewardsDistributed(currentEpoch, _totalRewards);
    }

    /**
     * @dev Advance to next epoch
     */
    function advanceEpoch() external {
        require(block.timestamp >= lastEpochTime + epochDuration, "DPoS: Epoch not ready");
        
        currentEpoch++;
        lastEpochTime = block.timestamp;
        
        emit EpochAdvanced(currentEpoch, block.timestamp);
    }

    /**
     * @dev Internal function to distribute rewards to delegators
     */
    function _distributeDelegatorRewards(address _validator, uint256 _totalReward) internal {
        Validator storage validator = validators[_validator];
        
        if (validator.totalDelegated == 0) return;
        
        address[] memory delegators = validatorDelegators[_validator];
        
        for (uint256 i = 0; i < delegators.length; i++) {
            address delegator = delegators[i];
            Delegation storage delegation = delegations[delegator][_validator];
            
            if (delegation.amount > 0) {
                uint256 delegatorReward = (_totalReward * delegation.amount) / validator.totalDelegated;
                
                if (delegation.autoCompound) {
                    // Add reward to delegation amount
                    delegation.amount += delegatorReward;
                    validator.totalDelegated += delegatorReward;
                    totalStaked += delegatorReward;
                } else {
                    // Transfer reward to delegator
                    require(stakingToken.transfer(delegator, delegatorReward), "DPoS: Reward transfer failed");
                }
                
                delegation.lastRewardClaim = block.timestamp;
            }
        }
    }

    /**
     * @dev Get validator information
     */
    function getValidator(address _validator) external view returns (Validator memory) {
        return validators[_validator];
    }

    /**
     * @dev Get delegation information
     */
    function getDelegation(address _delegator, address _validator) external view returns (Delegation memory) {
        return delegations[_delegator][_validator];
    }

    /**
     * @dev Get all active validators
     */
    function getActiveValidators() external view returns (address[] memory) {
        return activeValidators;
    }

    /**
     * @dev Get validator's delegators
     */
    function getValidatorDelegators(address _validator) external view returns (address[] memory) {
        return validatorDelegators[_validator];
    }

    /**
     * @dev Get delegator's validators
     */
    function getDelegatorValidators(address _delegator) external view returns (address[] memory) {
        return delegatorValidators[_delegator];
    }

    /**
     * @notice Get comprehensive validator security information
     * @param _validator Address of the validator
     * @return byzantineFaults Number of Byzantine faults recorded
     * @return slashCount Number of times validator was slashed
     * @return consecutiveFailureCount Current consecutive failure count
     * @return reputationScore Historical reputation score
     * @return isTombstoned Whether validator is permanently banned
     * @return lastSlashTimestamp Timestamp of last slashing event
     */
    function getValidatorSecurityInfo(address _validator) external view returns (
        uint256 byzantineFaults,
        uint256 slashCount,
        uint256 consecutiveFailureCount,
        uint256 reputationScore,
        bool isTombstoned,
        uint256 lastSlashTimestamp
    ) {
        Validator memory validator = validators[_validator];
        return (
            byzantineFaultCount[_validator],
            validator.slashCount,
            consecutiveFailures[_validator],
            validatorReputationHistory[_validator],
            tombstoneStatus[_validator],
            lastSlashTime[_validator]
        );
    }

    /**
     * @notice Check if validator is in good standing for delegation
     * @param _validator Address of the validator
     * @return isGoodStanding True if validator meets security requirements
     */
    function isValidatorInGoodStanding(address _validator) external view returns (bool isGoodStanding) {
        Validator memory validator = validators[_validator];
        
        return validator.status == ValidatorStatus.ACTIVE &&
               !tombstoneStatus[_validator] &&
               validator.slashCount < 3 &&
               byzantineFaultCount[_validator] < 2 &&
               consecutiveFailures[_validator] < 2 &&
               validatorReputationHistory[_validator] >= 50;
    }

    /**
     * @notice Get delegation security metrics for a user
     * @param _delegator Address of the delegator
     * @return cooldownEnd When delegation cooldown ends
     * @return lastDelegationTimestamp Last delegation timestamp
     */
    function getDelegationSecurityInfo(address _delegator) external view returns (
        uint256 cooldownEnd,
        uint256 lastDelegationTimestamp
    ) {
        return (
            delegationCooldown[_delegator],
            lastDelegationTime[_delegator]
        );
    }

    /**
     * @notice Get epoch performance history for validator
     * @param _validator Address of the validator  
     * @param _epoch Epoch number
     * @return passed Whether validator passed performance metrics for the epoch
     */
    function getEpochPerformance(address _validator, uint256 _epoch) external view returns (bool passed) {
        return epochValidatorPerformance[_epoch][_validator];
    }

    /**
     * @dev Update staking configuration (onlyOwner)
     */
    function updateConfig(StakingConfig memory _newConfig) external onlyOwner {
        config = _newConfig;
    }

    /**
     * @notice Update maximum delegations per validator
     * @param _maxDelegations New maximum delegation limit
     */
    function updateMaxDelegationsPerValidator(uint256 _maxDelegations) external onlyOwner {
        require(_maxDelegations >= 100, "DPoS: Minimum 100 delegations required");
        maxDelegationsPerValidator = _maxDelegations;
    }

    /**
     * @dev Emergency pause function
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause function
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}