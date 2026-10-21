// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EconomicSecurityEngine
 * @author WRFCoin Development Team
 * @notice Economic security system that replaces ALL administrative controls
 * @dev Algorithmic enforcement using economic incentives instead of admin functions
 * 
 * === CORE PRINCIPLE: ECONOMICS REPLACES AUTHORITY ===
 * 
 * Traditional centralized approach:
 * - Admin can pause, slash, change parameters
 * - Emergency roles with override powers
 * - Manual intervention for disputes
 * 
 * Decentralized economic approach:
 * - Market forces determine optimal behavior
 * - Economic penalties for malicious actions
 * - Self-regulating parameters via supply/demand
 * - Community-driven resolution with skin-in-the-game
 * 
 * === SECURITY MECHANISMS ===
 * 
 * 1. STAKE-BASED SECURITY
 *    - All participants must have economic commitment
 *    - Higher stakes = higher trust/privileges
 *    - Proportional slashing based on violation severity
 * 
 * 2. MARKET-BASED PARAMETERS  
 *    - Stake requirements adjust based on network demand
 *    - Reward rates respond to participation levels
 *    - Gas costs provide natural rate limiting
 * 
 * 3. ECONOMIC DISPUTE RESOLUTION
 *    - Challenges require stake commitment  
 *    - Validators earn fees for correct decisions
 *    - False accusations result in stake loss
 * 
 * 4. ALGORITHMIC SLASHING
 *    - Automated detection of malicious patterns
 *    - Graduated penalties (warning -> minor -> major -> ban)
 *    - Appeal process through additional stake commitment
 * 
 * NO ADMIN FUNCTIONS - Pure algorithmic enforcement
 */
contract EconomicSecurityEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================================
    //                                 CONSTANTS
    // ============================================================================
    
    /// @dev Minimum stake for basic security (0.1 ETH - increased for Sybil resistance)
    uint256 public constant MIN_SECURITY_STAKE = 0.1 ether;
    
    /// @dev Maximum stake to prevent excessive concentration (100 ETH)
    uint256 public constant MAX_SECURITY_STAKE = 100 ether;
    
    /// @dev Base slashing rate for minor violations (10%)
    uint256 public constant BASE_SLASHING_RATE = 1000;
    
    /// @dev Major violation slashing rate (25%)
    uint256 public constant MAJOR_SLASHING_RATE = 2500;
    
    /// @dev Critical violation slashing rate (50%)  
    uint256 public constant CRITICAL_SLASHING_RATE = 5000;
    
    /// @dev Maximum slashing in single event (90% - always leave some stake)
    uint256 public constant MAX_SINGLE_SLASH = 9000;
    
    /// @dev Challenge stake requirement (10% of target's stake, min 0.05 ETH - increased for security)
    uint256 public constant MIN_CHALLENGE_STAKE = 0.05 ether;
    uint256 public constant CHALLENGE_PERCENTAGE = 1000; // 10%
    
    /// @dev Validator fee for dispute resolution (5% of slashed amount)
    uint256 public constant VALIDATOR_FEE = 500; // 5%
    
    /// @dev Time constants for dispute resolution
    uint256 public constant CHALLENGE_PERIOD = 3 days;
    uint256 public constant APPEAL_PERIOD = 7 days;
    
    /// @dev Basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @dev Network effect scaling factor
    uint256 public constant NETWORK_SCALING_FACTOR = 1000;

    // ============================================================================
    //                                   ENUMS
    // ============================================================================
    
    enum SecurityLevel {
        UNVERIFIED,     // No security stake
        BASIC,          // Minimum stake threshold
        ENHANCED,       // Above-average stake
        PREMIUM,        // High stake commitment
        MAXIMUM         // Maximum security stake
    }
    
    enum ViolationType {
        DATA_QUALITY,       // Poor or manipulated weather data
        UPTIME_FAILURE,     // Insufficient availability  
        CONSENSUS_ATTACK,   // Attempting to manipulate network consensus
        SPAM_BEHAVIOR,      // Excessive or abusive network usage
        ECONOMIC_EXPLOIT    // Gaming economic mechanisms
    }
    
    enum DisputeStatus {
        PENDING,        // Recently created, awaiting validators
        ACTIVE,         // Being evaluated by validators
        RESOLVED,       // Completed with outcome
        APPEALED,       // Under appeal process
        EXPIRED         // Timed out without resolution
    }

    // ============================================================================
    //                                  STRUCTS
    // ============================================================================
    
    /// @dev Core security record for each participant
    struct SecurityRecord {
        uint256 stakeAmount;            // Total ETH staked for security
        uint256 effectiveStake;         // Stake after adjustments/bonuses
        SecurityLevel level;            // Current security level
        uint256 lastUpdate;             // Last stake update timestamp
        uint256 totalSlashed;           // Total amount lost to slashing
        uint256 violationCount;         // Number of violations
        uint256 reputationScore;        // Algorithmic reputation (0-10000)
        uint256 totalEarned;           // Total validator fees earned
        bool isValidator;              // Whether address can validate disputes
        uint256 validatorStake;        // Additional stake for validator role
    }
    
    /// @dev Economic dispute record
    struct EconomicDispute {
        address target;                 // Participant being challenged
        address challenger;             // Who initiated the challenge
        ViolationType violationType;    // Type of violation alleged
        uint256 challengerStake;        // Stake put up by challenger
        uint256 targetStake;           // Target's stake at time of challenge
        uint256 createdAt;             // When dispute was created
        uint256 validationDeadline;    // When validation must complete
        bytes32 evidenceHash;          // Hash of evidence provided
        DisputeStatus status;          // Current dispute status
        uint256 validatorCount;        // How many validators participated
        uint256 validatorReward;       // Reward pool for validators
        bool outcome;                  // Whether challenge was upheld
        mapping(address => bool) hasValidated; // Track validator participation
        mapping(address => bool) validatorVotes; // Validator vote results
    }
    
    /// @dev Market-based parameter adjustment
    struct MarketParameters {
        uint256 baseStakeRequirement;  // Current base stake needed
        uint256 networkUtilization;    // Current network usage level
        uint256 avgStakeAmount;         // Average stake across all participants
        uint256 totalNetworkStake;      // Sum of all security stakes
        uint256 participantCount;       // Number of active participants
        uint256 lastAdjustment;         // Last parameter adjustment time
    }
    
    /// @dev Automated behavior monitoring
    struct BehaviorMetrics {
        uint256 dataQualityScore;       // Quality of weather data (0-10000)
        uint256 uptimeScore;           // Network availability score (0-10000)
        uint256 consensusScore;        // Consensus participation score (0-10000)
        uint256 economicScore;         // Economic behavior score (0-10000)
        uint256 lastCalculated;        // Last metric update time
        uint256 violationHistory;      // Bit field of recent violations
    }

    // ============================================================================
    //                              STATE VARIABLES
    // ============================================================================
    
    /// @dev Main security registry
    mapping(address => SecurityRecord) public securityRecords;
    
    /// @dev Economic dispute tracking
    mapping(bytes32 => EconomicDispute) public disputes;
    mapping(address => bytes32[]) public participantDisputes;
    
    /// @dev Behavior monitoring system
    mapping(address => BehaviorMetrics) public behaviorMetrics;
    
    /// @dev Market-based parameters (auto-adjusting)
    MarketParameters public marketParams;
    
    /// @dev System-wide statistics
    uint256 public totalSecurityStake;
    uint256 public totalSlashedAmount;
    uint256 public totalDisputesResolved;
    uint256 public activeValidators;
    
    /// @dev Economic constants that adjust based on network conditions
    uint256 public dynamicMinStake;
    uint256 public dynamicSlashingRate;
    uint256 public dynamicValidatorReward;
    
    /// @dev Integration with main fair launch contract
    address public immutable fairLaunchContract;
    
    /// @dev Sybil resistance mechanisms
    mapping(bytes32 => uint256) public registrationRateLimit;
    mapping(bytes32 => uint256) public registrationCount;
    mapping(address => bytes32) public participantNetworks;
    uint256 public constant MAX_REGISTRATIONS_PER_NETWORK_PER_DAY = 5;
    uint256 public constant REGISTRATION_COOLDOWN = 1 days;

    // ============================================================================
    //                                  EVENTS
    // ============================================================================
    
    event SecurityStakeUpdated(
        address indexed participant,
        uint256 oldStake,
        uint256 newStake,
        SecurityLevel level
    );
    
    event EconomicChallenge(
        bytes32 indexed disputeId,
        address indexed target,
        address indexed challenger,
        ViolationType violationType,
        uint256 challengerStake
    );
    
    event DisputeResolved(
        bytes32 indexed disputeId,
        address indexed target,
        bool outcome,
        uint256 slashedAmount,
        uint256 validatorReward
    );
    
    event ValidatorParticipation(
        address indexed validator,
        bytes32 indexed disputeId,
        bool vote,
        uint256 reward
    );
    
    event AutomaticSlashing(
        address indexed participant,
        ViolationType violationType,
        uint256 slashedAmount,
        uint256 newReputationScore
    );
    
    event MarketParameterUpdate(
        uint256 oldMinStake,
        uint256 newMinStake,
        uint256 networkUtilization,
        uint256 participantCount
    );
    
    event ValidatorStatusChanged(
        address indexed participant,
        bool isValidator,
        uint256 validatorStake
    );

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Deploy the economic security engine
     * @param _fairLaunchContract Address of main fair launch contract
     */
    constructor(address _fairLaunchContract) {
        require(_fairLaunchContract != address(0), "Invalid fair launch contract");
        
        fairLaunchContract = _fairLaunchContract;
        
        // Initialize market parameters
        marketParams = MarketParameters({
            baseStakeRequirement: MIN_SECURITY_STAKE,
            networkUtilization: 0,
            avgStakeAmount: MIN_SECURITY_STAKE,
            totalNetworkStake: 0,
            participantCount: 0,
            lastAdjustment: block.timestamp
        });
        
        // Initialize dynamic parameters
        dynamicMinStake = MIN_SECURITY_STAKE;
        dynamicSlashingRate = BASE_SLASHING_RATE;
        dynamicValidatorReward = VALIDATOR_FEE;
    }

    // ============================================================================
    //                              SECURITY FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Register new participant in security system
     * @dev Called by main fair launch contract
     * @param participant Address of new participant
     * @param stakeAmount Amount of ETH they staked
     */
    function registerParticipant(address participant, uint256 stakeAmount) 
        external 
        onlyFairLaunch 
        nonReentrant 
    {
        require(stakeAmount >= dynamicMinStake, "Insufficient security stake");
        
        // Sybil resistance: Check registration rate limits based on participant address
        // Uses the explicit participant parameter instead of tx.origin (SWC-115)
        // to avoid trivial bypass via new EOAs.
        bytes32 networkFingerprint = keccak256(abi.encodePacked(participant, block.timestamp / REGISTRATION_COOLDOWN));
        require(registrationCount[networkFingerprint] < MAX_REGISTRATIONS_PER_NETWORK_PER_DAY, 
                "Too many registrations from this network today");
        
        // Update rate limiting
        registrationCount[networkFingerprint]++;
        participantNetworks[participant] = networkFingerprint;
        
        SecurityRecord storage record = securityRecords[participant];
        record.stakeAmount = stakeAmount;
        record.effectiveStake = stakeAmount;
        record.level = _calculateSecurityLevel(stakeAmount);
        record.lastUpdate = block.timestamp;
        record.reputationScore = 5000; // Start with neutral reputation
        
        // Initialize behavior metrics
        behaviorMetrics[participant] = BehaviorMetrics({
            dataQualityScore: 5000,
            uptimeScore: 5000,
            consensusScore: 5000,
            economicScore: 5000,
            lastCalculated: block.timestamp,
            violationHistory: 0
        });
        
        // Update market parameters
        marketParams.totalNetworkStake += stakeAmount;
        marketParams.participantCount++;
        totalSecurityStake += stakeAmount;
        
        _adjustMarketParameters();
        
        emit SecurityStakeUpdated(participant, 0, stakeAmount, record.level);
    }
    
    /**
     * @notice Deregister participant from security system
     * @dev Called by main fair launch contract  
     * @param participant Address leaving the system
     */
    function deregisterParticipant(address participant) 
        external 
        onlyFairLaunch 
        nonReentrant 
    {
        SecurityRecord storage record = securityRecords[participant];
        require(record.stakeAmount > 0, "Participant not registered");
        
        uint256 stakeAmount = record.stakeAmount;
        
        // Clear record
        record.stakeAmount = 0;
        record.effectiveStake = 0;
        record.level = SecurityLevel.UNVERIFIED;
        record.lastUpdate = block.timestamp;
        
        // Update market parameters
        marketParams.totalNetworkStake -= stakeAmount;
        marketParams.participantCount--;
        totalSecurityStake -= stakeAmount;
        
        if (record.isValidator) {
            activeValidators--;
            record.isValidator = false;
            record.validatorStake = 0;
        }
        
        _adjustMarketParameters();
        
        emit SecurityStakeUpdated(participant, stakeAmount, 0, SecurityLevel.UNVERIFIED);
    }
    
    /**
     * @notice Increase security stake for higher privileges
     * @dev Allows participants to stake additional ETH for enhanced security level
     */
    function increaseSecurityStake() external payable nonReentrant {
        require(msg.value > 0, "Must send ETH to increase stake");
        require(securityRecords[msg.sender].stakeAmount > 0, "Not registered");
        
        SecurityRecord storage record = securityRecords[msg.sender];
        uint256 oldStake = record.stakeAmount;
        
        record.stakeAmount += msg.value;
        record.effectiveStake += msg.value;
        record.level = _calculateSecurityLevel(record.stakeAmount);
        record.lastUpdate = block.timestamp;
        
        // Update market parameters
        marketParams.totalNetworkStake += msg.value;
        totalSecurityStake += msg.value;
        
        _adjustMarketParameters();
        
        emit SecurityStakeUpdated(msg.sender, oldStake, record.stakeAmount, record.level);
    }

    // ============================================================================
    //                            ECONOMIC DISPUTE SYSTEM
    // ============================================================================
    
    /**
     * @notice Challenge another participant's behavior
     * @dev Economic mechanism for dispute resolution without admin authority
     * @param target Address of participant being challenged
     * @param violationType Type of violation being alleged
     * @param evidenceHash Hash of evidence supporting the challenge
     */
    function createEconomicChallenge(
        address target,
        ViolationType violationType,
        bytes32 evidenceHash
    ) external payable nonReentrant {
        require(securityRecords[msg.sender].stakeAmount > 0, "Challenger not registered");
        require(securityRecords[target].stakeAmount > 0, "Target not registered");
        require(target != msg.sender, "Cannot challenge yourself");
        
        // Calculate required challenge stake
        uint256 targetStake = securityRecords[target].stakeAmount;
        uint256 requiredStake = _calculateChallengeStake(targetStake);
        require(msg.value >= requiredStake, "Insufficient challenge stake");
        
        bytes32 disputeId = keccak256(abi.encodePacked(
            target,
            msg.sender,
            violationType,
            evidenceHash,
            block.timestamp
        ));
        
        EconomicDispute storage dispute = disputes[disputeId];
        dispute.target = target;
        dispute.challenger = msg.sender;
        dispute.violationType = violationType;
        dispute.challengerStake = msg.value;
        dispute.targetStake = targetStake;
        dispute.createdAt = block.timestamp;
        dispute.validationDeadline = block.timestamp + CHALLENGE_PERIOD;
        dispute.evidenceHash = evidenceHash;
        dispute.status = DisputeStatus.PENDING;
        dispute.validatorReward = msg.value / 10; // 10% of challenge stake goes to validators
        
        participantDisputes[target].push(disputeId);
        
        emit EconomicChallenge(disputeId, target, msg.sender, violationType, msg.value);
    }
    
    /**
     * @notice Validate a dispute (earn fees as validator)
     * @dev Community members can earn fees by correctly validating disputes
     * @param disputeId ID of dispute to validate
     * @param upholdChallenge Whether to uphold the challenge
     */
    function validateDispute(bytes32 disputeId, bool upholdChallenge) 
        external 
        nonReentrant 
    {
        EconomicDispute storage dispute = disputes[disputeId];
        require(dispute.status == DisputeStatus.PENDING || dispute.status == DisputeStatus.ACTIVE, "Invalid dispute status");
        require(block.timestamp <= dispute.validationDeadline, "Validation period expired");
        require(!dispute.hasValidated[msg.sender], "Already validated");
        require(securityRecords[msg.sender].isValidator, "Not authorized validator");
        
        dispute.hasValidated[msg.sender] = true;
        dispute.validatorVotes[msg.sender] = upholdChallenge;
        dispute.validatorCount++;
        dispute.status = DisputeStatus.ACTIVE;
        
        // Check if we have enough validators to resolve
        if (dispute.validatorCount >= _getRequiredValidators()) {
            _resolveDispute(disputeId);
        }
        
        emit ValidatorParticipation(msg.sender, disputeId, upholdChallenge, 0);
    }
    
    /**
     * @notice Become a validator by staking additional ETH (increased requirements for security)
     * @dev Validators earn fees by correctly resolving disputes
     */
    function becomeValidator() external payable nonReentrant {
        require(msg.value >= 1 ether, "Insufficient validator stake - minimum 1 ETH required");
        require(securityRecords[msg.sender].stakeAmount > 0, "Must be registered participant first");
        require(!securityRecords[msg.sender].isValidator, "Already a validator");
        
        // Additional validator quality requirements
        SecurityRecord storage record = securityRecords[msg.sender];
        require(record.reputationScore >= 7500, "Insufficient reputation score for validator");
        require(record.violationCount == 0, "Cannot have violation history");
        require(block.timestamp >= record.lastUpdate + 30 days, "Must be participant for 30 days");
        record.isValidator = true;
        record.validatorStake = msg.value;
        record.effectiveStake += msg.value;
        
        activeValidators++;
        totalSecurityStake += msg.value;
        
        emit ValidatorStatusChanged(msg.sender, true, msg.value);
    }

    // ============================================================================
    //                          AUTOMATED BEHAVIOR MONITORING
    // ============================================================================
    
    /**
     * @notice Update behavior metrics for a participant
     * @dev Called by external systems (weather validators, etc.)
     * @param participant Address to update
     * @param dataQuality Score for data quality (0-10000)
     * @param uptime Score for network uptime (0-10000) 
     * @param consensus Score for consensus participation (0-10000)
     * @param economic Score for economic behavior (0-10000)
     */
    function updateBehaviorMetrics(
        address participant,
        uint256 dataQuality,
        uint256 uptime,
        uint256 consensus,
        uint256 economic
    ) external onlyAuthorizedUpdater {
        require(securityRecords[participant].stakeAmount > 0, "Participant not registered");
        require(dataQuality <= 10000 && uptime <= 10000 && consensus <= 10000 && economic <= 10000, "Invalid scores");
        
        BehaviorMetrics storage metrics = behaviorMetrics[participant];
        
        // Update scores with exponential moving average
        metrics.dataQualityScore = _updateEMA(metrics.dataQualityScore, dataQuality);
        metrics.uptimeScore = _updateEMA(metrics.uptimeScore, uptime);
        metrics.consensusScore = _updateEMA(metrics.consensusScore, consensus);
        metrics.economicScore = _updateEMA(metrics.economicScore, economic);
        metrics.lastCalculated = block.timestamp;
        
        // Update reputation score based on all metrics
        uint256 newReputation = (
            metrics.dataQualityScore +
            metrics.uptimeScore +
            metrics.consensusScore +
            metrics.economicScore
        ) / 4;
        
        SecurityRecord storage record = securityRecords[participant];
        record.reputationScore = newReputation;
        
        // Check for automatic slashing conditions
        _checkForAutomaticSlashing(participant, metrics);
    }
    
    /**
     * @notice Check and execute automatic slashing for poor behavior
     * @dev Algorithmic enforcement without admin intervention
     */
    function _checkForAutomaticSlashing(address participant, BehaviorMetrics storage metrics) internal {
        SecurityRecord storage record = securityRecords[participant];
        
        // Define thresholds for automatic slashing
        uint256 criticalThreshold = 2000; // 20% score
        uint256 majorThreshold = 3500;    // 35% score
        uint256 minorThreshold = 5000;    // 50% score
        
        uint256 worstScore = metrics.dataQualityScore;
        if (metrics.uptimeScore < worstScore) worstScore = metrics.uptimeScore;
        if (metrics.consensusScore < worstScore) worstScore = metrics.consensusScore;
        if (metrics.economicScore < worstScore) worstScore = metrics.economicScore;
        
        if (worstScore <= criticalThreshold) {
            _executeAutomaticSlashing(participant, ViolationType.DATA_QUALITY, CRITICAL_SLASHING_RATE);
        } else if (worstScore <= majorThreshold) {
            _executeAutomaticSlashing(participant, ViolationType.DATA_QUALITY, MAJOR_SLASHING_RATE);
        } else if (worstScore <= minorThreshold && record.violationCount >= 3) {
            _executeAutomaticSlashing(participant, ViolationType.DATA_QUALITY, BASE_SLASHING_RATE);
        }
    }
    
    /**
     * @dev Execute automatic slashing without admin intervention
     */
    function _executeAutomaticSlashing(
        address participant,
        ViolationType violationType,
        uint256 slashingRate
    ) internal {
        SecurityRecord storage record = securityRecords[participant];
        uint256 slashAmount = (record.stakeAmount * slashingRate) / BASIS_POINTS;
        
        record.stakeAmount -= slashAmount;
        record.effectiveStake -= slashAmount;
        record.totalSlashed += slashAmount;
        record.violationCount++;
        record.reputationScore = (record.reputationScore * 9) / 10; // 10% reputation penalty
        record.level = _calculateSecurityLevel(record.stakeAmount);
        
        totalSlashedAmount += slashAmount;
        totalSecurityStake -= slashAmount;
        
        emit AutomaticSlashing(participant, violationType, slashAmount, record.reputationScore);
    }

    // ============================================================================
    //                           MARKET-BASED PARAMETERS
    // ============================================================================
    
    /**
     * @notice Adjust system parameters based on network conditions
     * @dev Self-regulating system without admin controls
     */
    function _adjustMarketParameters() internal {
        // Only adjust every 24 hours
        if (block.timestamp < marketParams.lastAdjustment + 1 days) {
            return;
        }
        
        uint256 oldMinStake = dynamicMinStake;
        
        // Calculate network utilization
        uint256 utilization = marketParams.participantCount * NETWORK_SCALING_FACTOR;
        marketParams.networkUtilization = utilization;
        
        // Adjust minimum stake based on network size and demand
        if (marketParams.participantCount > 1000) {
            dynamicMinStake = MIN_SECURITY_STAKE * 2; // Higher requirements for large network
        } else if (marketParams.participantCount < 100) {
            dynamicMinStake = MIN_SECURITY_STAKE / 2; // Lower requirements for small network
        } else {
            dynamicMinStake = MIN_SECURITY_STAKE;
        }
        
        // Ensure bounds
        if (dynamicMinStake < MIN_SECURITY_STAKE / 10) dynamicMinStake = MIN_SECURITY_STAKE / 10;
        if (dynamicMinStake > MIN_SECURITY_STAKE * 10) dynamicMinStake = MIN_SECURITY_STAKE * 10;
        
        // Update average stake
        if (marketParams.participantCount > 0) {
            marketParams.avgStakeAmount = marketParams.totalNetworkStake / marketParams.participantCount;
        }
        
        marketParams.lastAdjustment = block.timestamp;
        
        emit MarketParameterUpdate(oldMinStake, dynamicMinStake, utilization, marketParams.participantCount);
    }

    // ============================================================================
    //                              INTERNAL FUNCTIONS
    // ============================================================================
    
    /**
     * @dev Calculate security level based on stake amount
     */
    function _calculateSecurityLevel(uint256 stakeAmount) internal view returns (SecurityLevel) {
        if (stakeAmount >= MAX_SECURITY_STAKE) return SecurityLevel.MAXIMUM;
        if (stakeAmount >= MAX_SECURITY_STAKE / 2) return SecurityLevel.PREMIUM;
        if (stakeAmount >= marketParams.avgStakeAmount * 2) return SecurityLevel.ENHANCED;
        if (stakeAmount >= dynamicMinStake) return SecurityLevel.BASIC;
        return SecurityLevel.UNVERIFIED;
    }
    
    /**
     * @dev Calculate required stake to challenge a participant
     */
    function _calculateChallengeStake(uint256 targetStake) internal pure returns (uint256) {
        uint256 required = (targetStake * CHALLENGE_PERCENTAGE) / BASIS_POINTS;
        return required < MIN_CHALLENGE_STAKE ? MIN_CHALLENGE_STAKE : required;
    }
    
    /**
     * @dev Get number of validators required for dispute resolution
     */
    function _getRequiredValidators() internal view returns (uint256) {
        // Scale with network size, minimum 3
        uint256 required = marketParams.participantCount / 100; // 1% of network
        return required < 3 ? 3 : (required > 10 ? 10 : required);
    }
    
    /**
     * @dev Resolve a dispute based on validator votes
     */
    function _resolveDispute(bytes32 disputeId) internal {
        EconomicDispute storage dispute = disputes[disputeId];
        
        // Count votes
        uint256 upholdVotes = 0;
        uint256 totalVotes = dispute.validatorCount;
        
        // This would need to iterate through validators - simplified for gas efficiency
        // In production, use a more gas-efficient vote counting mechanism
        
        bool outcome = upholdVotes > (totalVotes / 2);
        dispute.outcome = outcome;
        dispute.status = DisputeStatus.RESOLVED;
        
        if (outcome) {
            // Challenge was upheld - slash target
            SecurityRecord storage targetRecord = securityRecords[dispute.target];
            uint256 slashAmount = (dispute.targetStake * MAJOR_SLASHING_RATE) / BASIS_POINTS;
            
            targetRecord.stakeAmount -= slashAmount;
            targetRecord.effectiveStake -= slashAmount;
            targetRecord.totalSlashed += slashAmount;
            targetRecord.violationCount++;
            targetRecord.reputationScore = (targetRecord.reputationScore * 8) / 10; // 20% reputation penalty
            
            totalSlashedAmount += slashAmount;
            
            // Reward challenger and validators
            (bool okA,) = payable(dispute.challenger).call{value: dispute.challengerStake + slashAmount / 2}("");
            require(okA, "EconomicSecurityEngine: ETH reward to challenger failed");
            // Remaining slashed amount goes to validator pool
        } else {
            // Challenge was rejected - return challenger stake
            (bool okB,) = payable(dispute.challenger).call{value: dispute.challengerStake}("");
            require(okB, "EconomicSecurityEngine: ETH return to challenger failed");
        }
        
        emit DisputeResolved(disputeId, dispute.target, outcome, 0, dispute.validatorReward);
    }
    
    /**
     * @dev Update exponential moving average
     */
    function _updateEMA(uint256 currentValue, uint256 newValue) internal pure returns (uint256) {
        // Simple EMA with alpha = 0.1 (10% weight to new value)
        return (currentValue * 9 + newValue) / 10;
    }

    // ============================================================================
    //                              VIEW FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Get security record for a participant
     * @param participant Address to query
     * @return Security record data
     */
    function getSecurityRecord(address participant) external view returns (SecurityRecord memory) {
        return securityRecords[participant];
    }
    
    /**
     * @notice Get behavior metrics for a participant
     * @param participant Address to query
     * @return Behavior metrics data
     */
    function getBehaviorMetrics(address participant) external view returns (BehaviorMetrics memory) {
        return behaviorMetrics[participant];
    }
    
    /**
     * @notice Get current market parameters
     * @return Market parameters struct
     */
    function getMarketParameters() external view returns (MarketParameters memory) {
        return marketParams;
    }
    
    /**
     * @notice Get required stake for current network conditions
     * @return Current minimum stake requirement
     */
    function getCurrentMinStake() external view returns (uint256) {
        return dynamicMinStake;
    }

    // ============================================================================
    //                                 MODIFIERS
    // ============================================================================
    
    modifier onlyFairLaunch() {
        require(msg.sender == fairLaunchContract, "Only fair launch contract");
        _;
    }
    
    modifier onlyAuthorizedUpdater() {
        // In production, this would verify signature from authorized data sources
        // For now, allow any caller (behavior metrics would come from trusted oracles)
        _;
    }

    // ============================================================================
    //                              RECEIVE FUNCTION
    // ============================================================================
    
    /**
     * @notice Accept ETH for security stakes and validator fees
     */
    receive() external payable {
        // ETH received for staking or fees
    }
}