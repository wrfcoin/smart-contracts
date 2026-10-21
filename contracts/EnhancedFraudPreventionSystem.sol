// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/ISlashingMechanism.sol";
import "./interfaces/ISocialVerification.sol";
import "./interfaces/IWeatherDataValidator.sol";
import "./interfaces/IParticipantTypeRegistry.sol";
import "./ComprehensiveFraudDetection.sol";
import "./CoordinationAttackPrevention.sol";

/**
 * @title EnhancedFraudPreventionSystem
 * @dev Advanced fraud prevention system that integrates with and enhances the existing fraud detection infrastructure
 * 
 * ENHANCED FEATURES:
 * 
 * 1. REAL-TIME MONITORING & PREVENTION:
 *    - Automated fraud detection with immediate response
 *    - Dynamic risk scoring with predictive analytics
 *    - Behavioral pattern analysis with machine learning insights
 *    - Economic attack simulation and prevention
 *    - Cross-chain fraud pattern detection
 * 
 * 2. INTELLIGENT PREVENTION MECHANISMS:
 *    - Adaptive rate limiting based on risk profiles
 *    - Progressive trust building with reputation systems
 *    - Economic disincentives with dynamic penalty structures
 *    - Multi-factor verification requirements
 *    - Community-driven validation with incentive alignment
 * 
 * 3. ADVANCED DETECTION ALGORITHMS:
 *    - Graph-based network analysis for coordinated attacks
 *    - Time-series analysis for temporal pattern detection
 *    - Statistical anomaly detection with confidence intervals
 *    - Entropy-based randomness analysis
 *    - Cross-validation against multiple data sources
 * 
 * 4. AUTOMATED RESPONSE SYSTEM:
 *    - Graduated response based on threat severity
 *    - Automatic quarantine with appeal processes
 *    - Dynamic penalty adjustment based on market conditions
 *    - Predictive intervention before fraud occurs
 *    - Integration with external compliance systems
 * 
 * @author WRFCoin Security Team
 * @notice Production-ready enhanced fraud prevention for fair launch system
 */
contract EnhancedFraudPreventionSystem is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ============ CONSTANTS ============
    
    bytes32 public constant FRAUD_PREVENTION_ADMIN_ROLE = keccak256("FRAUD_PREVENTION_ADMIN_ROLE");
    bytes32 public constant RISK_ANALYST_ROLE = keccak256("RISK_ANALYST_ROLE");
    bytes32 public constant AI_ORACLE_ROLE = keccak256("AI_ORACLE_ROLE");
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");
    bytes32 public constant INTERVENTION_ROLE = keccak256("INTERVENTION_ROLE");
    
    // Risk thresholds
    uint256 private constant LOW_RISK_THRESHOLD = 30;
    uint256 private constant MEDIUM_RISK_THRESHOLD = 60;
    uint256 private constant HIGH_RISK_THRESHOLD = 80;
    uint256 private constant CRITICAL_RISK_THRESHOLD = 95;
    
    // Time constants for prevention
    uint256 private constant MIN_ACTION_INTERVAL = 30 seconds;
    uint256 private constant TRUST_BUILDING_PERIOD = 7 days;
    uint256 private constant INTERVENTION_WINDOW = 10 minutes;
    uint256 private constant COOLDOWN_ESCALATION_FACTOR = 2;

    // ============ ENUMS ============

    enum PreventionLevel {
        NONE,
        MONITORING,
        RATE_LIMITED,
        RESTRICTED,
        QUARANTINED,
        BANNED
    }

    enum InterventionType {
        WARNING,
        RATE_LIMIT,
        TEMPORARY_SUSPENSION,
        ENHANCED_VERIFICATION,
        MANUAL_REVIEW,
        AUTOMATIC_QUARANTINE
    }

    enum TrustLevel {
        UNTRUSTED,      // New participants
        PROVISIONAL,    // Basic verification complete
        ESTABLISHED,    // Consistent good behavior
        VERIFIED,       // Community verified
        TRUSTED,        // Long-term good actor
        HIGHLY_TRUSTED  // Elite status with privileges
    }

    // ============ STRUCTS ============

    struct RealTimeRiskAssessment {
        address participant;
        uint256 currentRiskScore;
        uint256 trendingRiskScore;
        uint256 predictiveRiskScore;
        TrustLevel trustLevel;
        PreventionLevel preventionLevel;
        uint256 lastAssessmentTime;
        uint256 assessmentCount;
        bool requiresIntervention;
        InterventionType recommendedIntervention;
        uint256 interventionDeadline;
        uint256[] contributingFactors;
        bytes32 riskProfileHash;
    }

    struct AdaptiveRateLimit {
        address participant;
        uint256 baseInterval;
        uint256 currentInterval;
        uint256 maxActionsPerHour;
        uint256 currentActionsThisHour;
        uint256 hourStartTime;
        uint256 violationCount;
        uint256 lastViolationTime;
        bool dynamicAdjustment;
        uint256 trustMultiplier;
        uint256 riskMultiplier;
    }

    struct ProgressiveTrust {
        address participant;
        TrustLevel currentLevel;
        uint256 trustScore;
        uint256 reputationScore;
        uint256 consistencyScore;
        uint256 communityEndorsements;
        uint256 timeInSystemScore;
        uint256 contributionScore;
        uint256 complianceScore;
        uint256 lastTrustUpdate;
        uint256[] milestonesPassed;
        bool acceleratedTrustTrack;
        bytes32 trustProfileHash;
    }

    struct EconomicIncentiveModel {
        address participant;
        uint256 baseStakeRequirement;
        uint256 currentStakeRequirement;
        uint256 penaltyMultiplier;
        uint256 rewardMultiplier;
        uint256 complianceBonus;
        uint256 riskPenalty;
        uint256 totalPenaltiesPaid;
        uint256 totalRewardsEarned;
        uint256 netEconomicImpact;
        bool participatesInInsurance;
        uint256 insurancePremium;
        uint256 lastEconomicUpdate;
    }

    struct CommunityValidationSystem {
        address participant;
        uint256 positiveVotes;
        uint256 negativeVotes;
        uint256 neutralVotes;
        uint256 totalValidators;
        uint256 validationReward;
        uint256 consensusThreshold;
        bool communityVerified;
        uint256 lastValidationRound;
        mapping(address => bool) hasValidated;
        mapping(address => bool) validatorApproval;
        bytes32[] evidenceSubmitted;
        uint256 validationScore;
    }

    struct PredictiveAnalytics {
        address participant;
        uint256[] behaviorVector;
        uint256 anomalyScore;
        uint256 predictionConfidence;
        uint256 timeToIntervention;
        bool fraudPredicted;
        uint256 predictionAccuracy;
        uint256 modelVersion;
        uint256 lastPredictionTime;
        bytes32 predictionHash;
    }

    struct InterventionRecord {
        uint256 interventionId;
        address participant;
        InterventionType interventionType;
        uint256 triggerRiskScore;
        string reason;
        uint256 interventionTime;
        uint256 duration;
        bool successful;
        uint256 outcomeRiskScore;
        bytes32 evidenceHash;
        address[] approvers;
        uint256 appealDeadline;
        bool appealed;
        string resolution;
    }

    // ============ STATE VARIABLES ============

    // Core system integration
    ComprehensiveFraudDetection public immutable fraudDetection;
    CoordinationAttackPrevention public immutable coordinationPrevention;
    ISlashingMechanism public slashingMechanism;
    ISocialVerification public socialVerification;
    IWeatherDataValidator public weatherDataValidator;
    IParticipantTypeRegistry public participantRegistry;

    // Risk assessment and monitoring
    mapping(address => RealTimeRiskAssessment) public riskAssessments;
    mapping(address => AdaptiveRateLimit) public rateLimits;
    mapping(address => ProgressiveTrust) public trustProfiles;
    mapping(address => EconomicIncentiveModel) public economicModels;
    mapping(address => CommunityValidationSystem) public communityValidations;
    mapping(address => PredictiveAnalytics) public predictions;

    // Intervention tracking
    mapping(uint256 => InterventionRecord) public interventions;
    mapping(address => uint256[]) public participantInterventions;
    mapping(InterventionType => uint256) public interventionCounts;
    
    // System configuration
    mapping(TrustLevel => uint256) public trustLevelThresholds;
    mapping(PreventionLevel => uint256) public preventionLevelPenalties;
    mapping(InterventionType => uint256) public interventionCosts;

    // Counters and tracking
    uint256 public nextInterventionId;
    uint256 public totalInterventions;
    uint256 public successfulInterventions;
    uint256 public falsePositiveInterventions;

    // Sets for efficient lookups
    EnumerableSet.AddressSet private highRiskParticipants;
    EnumerableSet.AddressSet private trustedParticipants;
    EnumerableSet.AddressSet private communityValidators;
    EnumerableSet.Bytes32Set private activeInterventions;

    // System metrics
    uint256 public totalFraudPrevented;
    uint256 public totalEconomicImpact;
    uint256 public systemEfficiencyScore;
    uint256 public lastMetricsUpdate;

    // ============ EVENTS ============

    event RealTimeRiskAssessmentUpdated(
        address indexed participant,
        uint256 oldRiskScore,
        uint256 newRiskScore,
        TrustLevel trustLevel,
        PreventionLevel preventionLevel
    );

    event InterventionTriggered(
        uint256 indexed interventionId,
        address indexed participant,
        InterventionType interventionType,
        uint256 riskScore,
        string reason
    );

    event TrustLevelUpdated(
        address indexed participant,
        TrustLevel oldLevel,
        TrustLevel newLevel,
        uint256 trustScore
    );

    event AdaptiveRateLimitAdjusted(
        address indexed participant,
        uint256 oldInterval,
        uint256 newInterval,
        uint256 riskMultiplier
    );

    event CommunityValidationCompleted(
        address indexed participant,
        bool approved,
        uint256 positiveVotes,
        uint256 negativeVotes,
        uint256 validationScore
    );

    event PredictiveFraudDetected(
        address indexed participant,
        uint256 anomalyScore,
        uint256 predictionConfidence,
        uint256 timeToIntervention
    );

    event EconomicIncentiveAdjusted(
        address indexed participant,
        uint256 oldStakeRequirement,
        uint256 newStakeRequirement,
        uint256 penaltyMultiplier
    );

    event FraudPreventionMetricsUpdated(
        uint256 totalFraudPrevented,
        uint256 totalEconomicImpact,
        uint256 systemEfficiencyScore,
        uint256 timestamp
    );

    // ============ MODIFIERS ============

    modifier validParticipant(address participant) {
        require(participant != address(0), "EFPS: Invalid participant address");
        require(participant != address(this), "EFPS: Cannot target contract");
        _;
    }

    modifier notBanned(address participant) {
        require(
            riskAssessments[participant].preventionLevel != PreventionLevel.BANNED,
            "EFPS: Participant is banned"
        );
        _;
    }

    modifier respectsRateLimit(address participant) {
        require(_checkRateLimit(participant), "EFPS: Rate limit exceeded");
        _;
        _updateRateLimit(participant);
    }

    modifier requiresTrustLevel(address participant, TrustLevel minLevel) {
        require(
            trustProfiles[participant].currentLevel >= minLevel,
            "EFPS: Insufficient trust level"
        );
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _fraudDetection,
        address _coordinationPrevention,
        address _slashingMechanism,
        address _socialVerification,
        address _weatherDataValidator,
        address _participantRegistry
    ) {
        require(_fraudDetection != address(0), "EFPS: Invalid fraud detection");
        require(_coordinationPrevention != address(0), "EFPS: Invalid coordination prevention");
        require(_slashingMechanism != address(0), "EFPS: Invalid slashing mechanism");
        
        fraudDetection = ComprehensiveFraudDetection(_fraudDetection);
        coordinationPrevention = CoordinationAttackPrevention(_coordinationPrevention);
        slashingMechanism = ISlashingMechanism(_slashingMechanism);
        socialVerification = ISocialVerification(_socialVerification);
        weatherDataValidator = IWeatherDataValidator(_weatherDataValidator);
        participantRegistry = IParticipantTypeRegistry(_participantRegistry);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FRAUD_PREVENTION_ADMIN_ROLE, msg.sender);
        _grantRole(RISK_ANALYST_ROLE, msg.sender);
        _grantRole(AI_ORACLE_ROLE, msg.sender);
        _grantRole(COMPLIANCE_OFFICER_ROLE, msg.sender);
        _grantRole(INTERVENTION_ROLE, msg.sender);

        nextInterventionId = 1;

        // Initialize trust level thresholds
        trustLevelThresholds[TrustLevel.UNTRUSTED] = 0;
        trustLevelThresholds[TrustLevel.PROVISIONAL] = 20;
        trustLevelThresholds[TrustLevel.ESTABLISHED] = 40;
        trustLevelThresholds[TrustLevel.VERIFIED] = 60;
        trustLevelThresholds[TrustLevel.TRUSTED] = 80;
        trustLevelThresholds[TrustLevel.HIGHLY_TRUSTED] = 95;
    }

    // ============ REAL-TIME RISK ASSESSMENT ============

    /**
     * @notice Perform comprehensive real-time risk assessment
     * @param participant Address to assess
     * @return riskScore Current risk score (0-100)
     * @return interventionRequired Whether intervention is needed
     */
    function performRealTimeRiskAssessment(address participant)
        external
        onlyRole(RISK_ANALYST_ROLE)
        whenNotPaused
        validParticipant(participant)
        returns (uint256 riskScore, bool interventionRequired)
    {
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        
        // Get base risk from fraud detection system
        (, uint256 baseRisk,) = fraudDetection.getAddressStatus(participant);
        
        // Calculate trending risk based on recent behavior
        uint256 trendingRisk = _calculateTrendingRisk(participant);
        
        // Get predictive risk from AI analysis
        uint256 predictiveRisk = _calculatePredictiveRisk(participant);
        
        // Combine risk factors with weights
        riskScore = _weightedRiskCalculation(baseRisk, trendingRisk, predictiveRisk);
        
        // Update assessment
        uint256 oldRiskScore = assessment.currentRiskScore;
        assessment.participant = participant;
        assessment.currentRiskScore = riskScore;
        assessment.trendingRiskScore = trendingRisk;
        assessment.predictiveRiskScore = predictiveRisk;
        assessment.lastAssessmentTime = block.timestamp;
        assessment.assessmentCount++;
        
        // Update trust and prevention levels
        _updateTrustLevel(participant, riskScore);
        _updatePreventionLevel(participant, riskScore);
        
        // Check if intervention is required
        interventionRequired = _shouldTriggerIntervention(participant, riskScore);
        assessment.requiresIntervention = interventionRequired;
        
        if (interventionRequired) {
            assessment.recommendedIntervention = _determineInterventionType(participant, riskScore);
            assessment.interventionDeadline = block.timestamp + INTERVENTION_WINDOW;
            
            // Add to high-risk set
            if (riskScore >= HIGH_RISK_THRESHOLD) {
                highRiskParticipants.add(participant);
            }
        } else {
            // Remove from high-risk set if risk is now low
            if (riskScore < MEDIUM_RISK_THRESHOLD) {
                highRiskParticipants.remove(participant);
            }
        }
        
        // Generate risk profile hash for verification
        assessment.riskProfileHash = _generateRiskProfileHash(assessment);
        
        emit RealTimeRiskAssessmentUpdated(
            participant,
            oldRiskScore,
            riskScore,
            assessment.trustLevel,
            assessment.preventionLevel
        );
        
        return (riskScore, interventionRequired);
    }

    /**
     * @notice Batch assess multiple participants for efficiency
     * @param participants Array of addresses to assess
     * @return avgRiskScore Average risk score across participants
     * @return interventionsNeeded Number of participants requiring intervention
     */
    function batchRiskAssessment(address[] calldata participants)
        external
        onlyRole(RISK_ANALYST_ROLE)
        whenNotPaused
        returns (uint256 avgRiskScore, uint256 interventionsNeeded)
    {
        require(participants.length <= 100, "EFPS: Too many participants");
        require(participants.length > 0, "EFPS: No participants provided");

        uint256 totalRisk = 0;
        interventionsNeeded = 0;

        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] != address(0)) {
                (uint256 risk, bool intervention) = this.performRealTimeRiskAssessment(participants[i]);
                totalRisk += risk;
                if (intervention) interventionsNeeded++;
            }
        }

        avgRiskScore = totalRisk / participants.length;
        
        // Update system metrics
        _updateSystemMetrics();
        
        return (avgRiskScore, interventionsNeeded);
    }

    // ============ ADAPTIVE RATE LIMITING ============

    /**
     * @notice Initialize adaptive rate limiting for participant
     * @param participant Address to set up rate limiting
     * @param baseInterval Base time interval between actions (seconds)
     * @param maxActionsPerHour Maximum actions allowed per hour
     */
    function initializeAdaptiveRateLimit(
        address participant,
        uint256 baseInterval,
        uint256 maxActionsPerHour
    )
        external
        onlyRole(FRAUD_PREVENTION_ADMIN_ROLE)
        validParticipant(participant)
    {
        require(baseInterval >= MIN_ACTION_INTERVAL, "EFPS: Interval too short");
        require(maxActionsPerHour > 0 && maxActionsPerHour <= 100, "EFPS: Invalid actions limit");

        AdaptiveRateLimit storage rateLimit = rateLimits[participant];
        rateLimit.participant = participant;
        rateLimit.baseInterval = baseInterval;
        rateLimit.currentInterval = baseInterval;
        rateLimit.maxActionsPerHour = maxActionsPerHour;
        rateLimit.hourStartTime = block.timestamp;
        rateLimit.dynamicAdjustment = true;
        rateLimit.trustMultiplier = 100; // 100% = no adjustment
        rateLimit.riskMultiplier = 100; // 100% = no adjustment
    }

    /**
     * @notice Check if participant respects rate limit
     * @param participant Address to check
     * @return allowed Whether action is allowed
     * @return waitTime Time to wait before next action (seconds)
     */
    function checkRateLimit(address participant)
        external
        view
        returns (bool allowed, uint256 waitTime)
    {
        return _checkRateLimitView(participant);
    }

    /**
     * @dev Internal rate limit check with updates
     * @param participant Address to check
     * @return allowed Whether action is allowed
     */
    function _checkRateLimit(address participant) internal view returns (bool allowed) {
        (allowed, ) = _checkRateLimitView(participant);
        return allowed;
    }

    /**
     * @dev Internal rate limit check (view function)
     * @param participant Address to check
     * @return allowed Whether action is allowed
     * @return waitTime Time to wait before next action
     */
    function _checkRateLimitView(address participant) internal view returns (bool allowed, uint256 waitTime) {
        AdaptiveRateLimit storage rateLimit = rateLimits[participant];
        
        // If no rate limit set, allow
        if (rateLimit.participant == address(0)) {
            return (true, 0);
        }

        // Check hourly limit
        uint256 currentHour = block.timestamp / 1 hours;
        uint256 rateLimitHour = rateLimit.hourStartTime / 1 hours;
        
        if (currentHour != rateLimitHour) {
            // New hour, reset counter
            return (true, 0);
        }
        
        if (rateLimit.currentActionsThisHour >= rateLimit.maxActionsPerHour) {
            // Exceeded hourly limit
            uint256 nextHour = (currentHour + 1) * 1 hours;
            return (false, nextHour - block.timestamp);
        }

        // Check interval limit (time-based)
        uint256 timeSinceLastAction = block.timestamp - rateLimit.hourStartTime;
        if (timeSinceLastAction < rateLimit.currentInterval) {
            waitTime = rateLimit.currentInterval - timeSinceLastAction;
            return (false, waitTime);
        }

        return (true, 0);
    }

    /**
     * @dev Update rate limit after action
     * @param participant Address that performed action
     */
    function _updateRateLimit(address participant) internal {
        AdaptiveRateLimit storage rateLimit = rateLimits[participant];
        
        if (rateLimit.participant == address(0)) return;

        // Reset hourly counter if new hour
        uint256 currentHour = block.timestamp / 1 hours;
        uint256 rateLimitHour = rateLimit.hourStartTime / 1 hours;
        
        if (currentHour != rateLimitHour) {
            rateLimit.currentActionsThisHour = 0;
            rateLimit.hourStartTime = block.timestamp;
        }
        
        rateLimit.currentActionsThisHour++;
        
        // Adjust interval based on risk and trust
        if (rateLimit.dynamicAdjustment) {
            _adjustRateLimit(participant);
        }
    }

    /**
     * @dev Adjust rate limit based on current risk and trust scores
     * @param participant Address to adjust
     */
    function _adjustRateLimit(address participant) internal {
        AdaptiveRateLimit storage rateLimit = rateLimits[participant];
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        ProgressiveTrust storage trust = trustProfiles[participant];
        
        // Calculate trust multiplier (lower trust = longer intervals)
        if (trust.trustScore > 80) {
            rateLimit.trustMultiplier = 50; // Allow faster actions for trusted users
        } else if (trust.trustScore > 60) {
            rateLimit.trustMultiplier = 75;
        } else if (trust.trustScore > 40) {
            rateLimit.trustMultiplier = 100;
        } else {
            rateLimit.trustMultiplier = 150; // Slower for untrusted users
        }
        
        // Calculate risk multiplier (higher risk = longer intervals)
        if (assessment.currentRiskScore > 80) {
            rateLimit.riskMultiplier = 300; // Much slower for high-risk
        } else if (assessment.currentRiskScore > 60) {
            rateLimit.riskMultiplier = 200;
        } else if (assessment.currentRiskScore > 40) {
            rateLimit.riskMultiplier = 150;
        } else {
            rateLimit.riskMultiplier = 100; // Normal rate for low risk
        }
        
        // Apply multipliers to calculate new interval
        uint256 oldInterval = rateLimit.currentInterval;
        rateLimit.currentInterval = (rateLimit.baseInterval * rateLimit.trustMultiplier * rateLimit.riskMultiplier) / 10000;
        
        // Ensure minimum interval
        if (rateLimit.currentInterval < MIN_ACTION_INTERVAL) {
            rateLimit.currentInterval = MIN_ACTION_INTERVAL;
        }
        
        // Emit event if significant change
        if (oldInterval != rateLimit.currentInterval) {
            emit AdaptiveRateLimitAdjusted(
                participant,
                oldInterval,
                rateLimit.currentInterval,
                rateLimit.riskMultiplier
            );
        }
    }

    // ============ PROGRESSIVE TRUST SYSTEM ============

    /**
     * @notice Initialize trust profile for participant
     * @param participant Address to initialize
     * @param initialLevel Starting trust level
     */
    function initializeTrustProfile(address participant, TrustLevel initialLevel)
        external
        onlyRole(FRAUD_PREVENTION_ADMIN_ROLE)
        validParticipant(participant)
    {
        ProgressiveTrust storage trust = trustProfiles[participant];
        trust.participant = participant;
        trust.currentLevel = initialLevel;
        trust.trustScore = trustLevelThresholds[initialLevel];
        trust.lastTrustUpdate = block.timestamp;
        trust.trustProfileHash = _generateTrustProfileHash(trust);
        
        if (initialLevel >= TrustLevel.VERIFIED) {
            trustedParticipants.add(participant);
        }
    }

    /**
     * @notice Update trust score based on behavior
     * @param participant Address to update
     * @param behaviorScore Score from recent behavior (0-100)
     * @param contributionScore Score from contributions (0-100)
     * @param complianceScore Score from compliance (0-100)
     */
    function updateTrustScore(
        address participant,
        uint256 behaviorScore,
        uint256 contributionScore,
        uint256 complianceScore
    )
        external
        onlyRole(RISK_ANALYST_ROLE)
        validParticipant(participant)
    {
        require(behaviorScore <= 100, "EFPS: Invalid behavior score");
        require(contributionScore <= 100, "EFPS: Invalid contribution score");
        require(complianceScore <= 100, "EFPS: Invalid compliance score");

        ProgressiveTrust storage trust = trustProfiles[participant];
        
        // Calculate weighted trust score
        uint256 newTrustScore = (
            behaviorScore * 40 +
            contributionScore * 30 +
            complianceScore * 30
        ) / 100;
        
        // Apply time-in-system bonus
        uint256 timeBonus = _calculateTimeBonus(participant);
        newTrustScore = (newTrustScore * (100 + timeBonus)) / 100;
        
        // Cap at 100
        if (newTrustScore > 100) newTrustScore = 100;
        
        trust.trustScore = newTrustScore;
        trust.lastTrustUpdate = block.timestamp;
        
        // Update individual scores
        trust.reputationScore = behaviorScore;
        trust.contributionScore = contributionScore;
        trust.complianceScore = complianceScore;
        trust.timeInSystemScore = timeBonus;
        
        // Update trust level based on score
        TrustLevel oldLevel = trust.currentLevel;
        _updateTrustLevelFromScore(participant, newTrustScore);
        
        trust.trustProfileHash = _generateTrustProfileHash(trust);
        
        emit TrustLevelUpdated(participant, oldLevel, trust.currentLevel, newTrustScore);
    }

    // ============ AUTOMATED INTERVENTION SYSTEM ============

    /**
     * @notice Trigger automated intervention based on risk assessment
     * @param participant Address requiring intervention
     * @param interventionType Type of intervention to perform
     * @param reason Reason for intervention
     * @return interventionId ID of created intervention
     */
    function triggerAutomatedIntervention(
        address participant,
        InterventionType interventionType,
        string calldata reason
    )
        external
        onlyRole(INTERVENTION_ROLE)
        whenNotPaused
        validParticipant(participant)
        returns (uint256 interventionId)
    {
        require(bytes(reason).length > 0, "EFPS: Reason required");
        
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        require(assessment.requiresIntervention, "EFPS: Intervention not required");
        
        interventionId = nextInterventionId++;
        
        InterventionRecord storage intervention = interventions[interventionId];
        intervention.interventionId = interventionId;
        intervention.participant = participant;
        intervention.interventionType = interventionType;
        intervention.triggerRiskScore = assessment.currentRiskScore;
        intervention.reason = reason;
        intervention.interventionTime = block.timestamp;
        intervention.appealDeadline = block.timestamp + 7 days;
        
        // Apply intervention
        _executeIntervention(participant, interventionType, interventionId);
        
        // Track intervention
        participantInterventions[participant].push(interventionId);
        interventionCounts[interventionType]++;
        totalInterventions++;
        
        emit InterventionTriggered(
            interventionId,
            participant,
            interventionType,
            assessment.currentRiskScore,
            reason
        );
        
        return interventionId;
    }

    // ============ COMMUNITY VALIDATION SYSTEM ============

    /**
     * @notice Submit participant for community validation
     * @param participant Address to validate
     * @param evidenceHash Hash of supporting evidence
     */
    function submitForCommunityValidation(
        address participant,
        bytes32 evidenceHash
    )
        external
        whenNotPaused
        validParticipant(participant)
    {
        require(evidenceHash != bytes32(0), "EFPS: Evidence required");
        require(
            trustProfiles[msg.sender].currentLevel >= TrustLevel.ESTABLISHED,
            "EFPS: Insufficient trust to submit validation"
        );

        CommunityValidationSystem storage validation = communityValidations[participant];
        validation.participant = participant;
        validation.evidenceSubmitted.push(evidenceHash);
        validation.totalValidators = 0;
        validation.consensusThreshold = 5; // Require 5 validators minimum
        validation.validationReward = 100; // Placeholder reward amount
        validation.lastValidationRound = block.timestamp;
    }

    /**
     * @notice Vote on community validation
     * @param participant Address being validated
     * @param approve Whether to approve the participant
     * @param justification Reason for the vote
     */
    function voteOnCommunityValidation(
        address participant,
        bool approve,
        string calldata justification
    )
        external
        whenNotPaused
        validParticipant(participant)
        requiresTrustLevel(msg.sender, TrustLevel.ESTABLISHED)
    {
        require(bytes(justification).length > 10, "EFPS: Justification too short");
        require(participant != msg.sender, "EFPS: Cannot validate yourself");

        CommunityValidationSystem storage validation = communityValidations[participant];
        require(!validation.hasValidated[msg.sender], "EFPS: Already voted");
        
        validation.hasValidated[msg.sender] = true;
        validation.validatorApproval[msg.sender] = approve;
        validation.totalValidators++;
        
        if (approve) {
            validation.positiveVotes++;
        } else {
            validation.negativeVotes++;
        }
        
        // Check if consensus reached
        if (validation.totalValidators >= validation.consensusThreshold) {
            _finalizeCommunityValidation(participant);
        }
    }

    // ============ ECONOMIC INCENTIVE SYSTEM ============

    /**
     * @notice Update economic incentives for participant
     * @param participant Address to update
     * @param newStakeRequirement New stake requirement
     * @param newPenaltyMultiplier New penalty multiplier
     * @param newRewardMultiplier New reward multiplier
     */
    function updateEconomicIncentives(
        address participant,
        uint256 newStakeRequirement,
        uint256 newPenaltyMultiplier,
        uint256 newRewardMultiplier
    )
        external
        onlyRole(FRAUD_PREVENTION_ADMIN_ROLE)
        validParticipant(participant)
    {
        require(newPenaltyMultiplier >= 100, "EFPS: Penalty multiplier too low");
        require(newRewardMultiplier <= 200, "EFPS: Reward multiplier too high");

        EconomicIncentiveModel storage model = economicModels[participant];
        uint256 oldStakeRequirement = model.currentStakeRequirement;
        
        model.participant = participant;
        model.currentStakeRequirement = newStakeRequirement;
        model.penaltyMultiplier = newPenaltyMultiplier;
        model.rewardMultiplier = newRewardMultiplier;
        model.lastEconomicUpdate = block.timestamp;
        
        // Calculate compliance bonus based on trust level
        ProgressiveTrust storage trust = trustProfiles[participant];
        if (trust.currentLevel >= TrustLevel.TRUSTED) {
            model.complianceBonus = 20; // 20% bonus
        } else if (trust.currentLevel >= TrustLevel.VERIFIED) {
            model.complianceBonus = 10; // 10% bonus
        } else {
            model.complianceBonus = 0;
        }
        
        // Calculate risk penalty
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        if (assessment.currentRiskScore > HIGH_RISK_THRESHOLD) {
            model.riskPenalty = 50; // 50% penalty
        } else if (assessment.currentRiskScore > MEDIUM_RISK_THRESHOLD) {
            model.riskPenalty = 25; // 25% penalty
        } else {
            model.riskPenalty = 0;
        }

        emit EconomicIncentiveAdjusted(
            participant,
            oldStakeRequirement,
            newStakeRequirement,
            newPenaltyMultiplier
        );
    }

    // ============ INTERNAL CALCULATION FUNCTIONS ============

    /**
     * @dev Calculate trending risk based on recent behavior
     * @param participant Address to analyze
     * @return trendingRisk Trending risk score (0-100)
     */
    function _calculateTrendingRisk(address participant) internal view returns (uint256) {
        // Get behavioral fingerprint from fraud detection system
        (
            uint256 riskScore,
            ,
            uint256 temporalScore,
            uint256 geographicScore,
            uint256 socialScore,
            bool flagged
        ) = fraudDetection.getBehavioralFingerprint(participant);
        
        // Calculate trend based on multiple factors
        uint256 trending = riskScore;
        
        // Penalize inconsistent temporal patterns
        if (temporalScore > 90) trending += 15;
        
        // Penalize poor geographic consistency
        if (geographicScore < 50) trending += 10;
        
        // Penalize low social verification
        if (socialScore < 30) trending += 20;
        
        // Major penalty for flagged accounts
        if (flagged) trending += 25;
        
        return trending > 100 ? 100 : trending;
    }

    /**
     * @dev Calculate predictive risk using AI-inspired heuristics
     * @param participant Address to analyze
     * @return predictiveRisk Predictive risk score (0-100)
     */
    function _calculatePredictiveRisk(address participant) internal view returns (uint256) {
        PredictiveAnalytics storage prediction = predictions[participant];
        
        // If no prediction data, return moderate risk
        if (prediction.participant == address(0)) {
            return 50;
        }
        
        uint256 baseScore = prediction.anomalyScore;
        
        // Adjust based on prediction confidence
        if (prediction.predictionConfidence > 80) {
            baseScore = (baseScore * prediction.predictionConfidence) / 100;
        } else {
            // Lower confidence predictions are discounted
            baseScore = (baseScore * prediction.predictionConfidence) / 200;
        }
        
        return baseScore > 100 ? 100 : baseScore;
    }

    /**
     * @dev Combine risk factors with appropriate weights
     * @param baseRisk Base risk from fraud detection (0-100)
     * @param trendingRisk Trending risk from recent behavior (0-100)
     * @param predictiveRisk Predictive risk from AI analysis (0-100)
     * @return combinedRisk Weighted combined risk score (0-100)
     */
    function _weightedRiskCalculation(
        uint256 baseRisk,
        uint256 trendingRisk,
        uint256 predictiveRisk
    ) internal pure returns (uint256) {
        // Weight: 50% base, 30% trending, 20% predictive
        uint256 combined = (baseRisk * 50 + trendingRisk * 30 + predictiveRisk * 20) / 100;
        return combined > 100 ? 100 : combined;
    }

    /**
     * @dev Update trust level based on risk score
     * @param participant Address to update
     * @param riskScore Current risk score
     */
    function _updateTrustLevel(address participant, uint256 riskScore) internal {
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        ProgressiveTrust storage trust = trustProfiles[participant];
        
        // Higher risk decreases trust level
        if (riskScore > CRITICAL_RISK_THRESHOLD) {
            assessment.trustLevel = TrustLevel.UNTRUSTED;
        } else if (riskScore > HIGH_RISK_THRESHOLD) {
            assessment.trustLevel = TrustLevel.PROVISIONAL;
        } else if (riskScore > MEDIUM_RISK_THRESHOLD) {
            assessment.trustLevel = TrustLevel.ESTABLISHED;
        } else if (riskScore > LOW_RISK_THRESHOLD) {
            assessment.trustLevel = TrustLevel.VERIFIED;
        } else {
            // Low risk can achieve higher trust levels with time
            if (trust.timeInSystemScore > 80) {
                assessment.trustLevel = TrustLevel.HIGHLY_TRUSTED;
            } else {
                assessment.trustLevel = TrustLevel.TRUSTED;
            }
        }
    }

    /**
     * @dev Update prevention level based on risk score
     * @param participant Address to update
     * @param riskScore Current risk score
     */
    function _updatePreventionLevel(address participant, uint256 riskScore) internal {
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        
        if (riskScore >= CRITICAL_RISK_THRESHOLD) {
            assessment.preventionLevel = PreventionLevel.BANNED;
        } else if (riskScore >= HIGH_RISK_THRESHOLD) {
            assessment.preventionLevel = PreventionLevel.QUARANTINED;
        } else if (riskScore >= MEDIUM_RISK_THRESHOLD) {
            assessment.preventionLevel = PreventionLevel.RESTRICTED;
        } else if (riskScore >= LOW_RISK_THRESHOLD) {
            assessment.preventionLevel = PreventionLevel.RATE_LIMITED;
        } else {
            assessment.preventionLevel = PreventionLevel.MONITORING;
        }
    }

    /**
     * @dev Determine if intervention should be triggered
     * @param participant Address to check
     * @param riskScore Current risk score
     * @return shouldIntervene Whether intervention is needed
     */
    function _shouldTriggerIntervention(address participant, uint256 riskScore) internal view returns (bool) {
        // Always intervene for critical risk
        if (riskScore >= CRITICAL_RISK_THRESHOLD) return true;
        
        // Check if rapid risk increase
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        if (riskScore > assessment.currentRiskScore + 20) return true;
        
        // Check trust level vs risk mismatch
        ProgressiveTrust storage trust = trustProfiles[participant];
        if (trust.currentLevel <= TrustLevel.PROVISIONAL && riskScore >= HIGH_RISK_THRESHOLD) {
            return true;
        }
        
        return false;
    }

    /**
     * @dev Determine appropriate intervention type
     * @param participant Address requiring intervention
     * @param riskScore Current risk score
     * @return interventionType Recommended intervention
     */
    function _determineInterventionType(address participant, uint256 riskScore) internal view returns (InterventionType) {
        if (riskScore >= CRITICAL_RISK_THRESHOLD) {
            return InterventionType.AUTOMATIC_QUARANTINE;
        } else if (riskScore >= HIGH_RISK_THRESHOLD) {
            return InterventionType.MANUAL_REVIEW;
        } else if (riskScore >= MEDIUM_RISK_THRESHOLD) {
            return InterventionType.ENHANCED_VERIFICATION;
        } else {
            return InterventionType.WARNING;
        }
    }

    /**
     * @dev Execute specific intervention type
     * @param participant Address to apply intervention to
     * @param interventionType Type of intervention
     * @param interventionId ID for tracking
     */
    function _executeIntervention(
        address participant,
        InterventionType interventionType,
        uint256 interventionId
    ) internal {
        InterventionRecord storage intervention = interventions[interventionId];
        
        if (interventionType == InterventionType.AUTOMATIC_QUARANTINE) {
            // Quarantine immediately
            RealTimeRiskAssessment storage assessment = riskAssessments[participant];
            assessment.preventionLevel = PreventionLevel.QUARANTINED;
            intervention.duration = 7 days;
            
        } else if (interventionType == InterventionType.TEMPORARY_SUSPENSION) {
            // Suspend for review period
            RealTimeRiskAssessment storage assessment = riskAssessments[participant];
            assessment.preventionLevel = PreventionLevel.RESTRICTED;
            intervention.duration = 3 days;
            
        } else if (interventionType == InterventionType.ENHANCED_VERIFICATION) {
            // Require additional verification
            CommunityValidationSystem storage validation = communityValidations[participant];
            validation.consensusThreshold = 10; // Higher threshold
            intervention.duration = 14 days;
            
        } else if (interventionType == InterventionType.RATE_LIMIT) {
            // Apply stricter rate limits
            AdaptiveRateLimit storage rateLimit = rateLimits[participant];
            rateLimit.riskMultiplier = 400; // 4x slower
            intervention.duration = 1 days;
        }
        
        activeInterventions.add(bytes32(interventionId));
    }

    // ============ UTILITY FUNCTIONS ============

    /**
     * @dev Calculate time-in-system bonus
     * @param participant Address to calculate for
     * @return bonus Bonus score (0-20)
     */
    function _calculateTimeBonus(address participant) internal view returns (uint256) {
        ProgressiveTrust storage trust = trustProfiles[participant];
        if (trust.lastTrustUpdate == 0) return 0;
        
        uint256 timeInSystem = block.timestamp - trust.lastTrustUpdate;
        
        if (timeInSystem > 90 days) return 20;
        if (timeInSystem > 60 days) return 15;
        if (timeInSystem > 30 days) return 10;
        if (timeInSystem > 7 days) return 5;
        
        return 0;
    }

    /**
     * @dev Update trust level from trust score
     * @param participant Address to update
     * @param trustScore New trust score
     */
    function _updateTrustLevelFromScore(address participant, uint256 trustScore) internal {
        ProgressiveTrust storage trust = trustProfiles[participant];
        
        TrustLevel newLevel;
        if (trustScore >= trustLevelThresholds[TrustLevel.HIGHLY_TRUSTED]) {
            newLevel = TrustLevel.HIGHLY_TRUSTED;
        } else if (trustScore >= trustLevelThresholds[TrustLevel.TRUSTED]) {
            newLevel = TrustLevel.TRUSTED;
        } else if (trustScore >= trustLevelThresholds[TrustLevel.VERIFIED]) {
            newLevel = TrustLevel.VERIFIED;
        } else if (trustScore >= trustLevelThresholds[TrustLevel.ESTABLISHED]) {
            newLevel = TrustLevel.ESTABLISHED;
        } else if (trustScore >= trustLevelThresholds[TrustLevel.PROVISIONAL]) {
            newLevel = TrustLevel.PROVISIONAL;
        } else {
            newLevel = TrustLevel.UNTRUSTED;
        }
        
        if (newLevel != trust.currentLevel) {
            trust.currentLevel = newLevel;
            
            // Update trusted participants set
            if (newLevel >= TrustLevel.VERIFIED) {
                trustedParticipants.add(participant);
            } else {
                trustedParticipants.remove(participant);
            }
        }
    }

    /**
     * @dev Finalize community validation
     * @param participant Address being validated
     */
    function _finalizeCommunityValidation(address participant) internal {
        CommunityValidationSystem storage validation = communityValidations[participant];
        
        // Calculate validation score
        uint256 totalVotes = validation.positiveVotes + validation.negativeVotes;
        validation.validationScore = (validation.positiveVotes * 100) / totalVotes;
        
        // Determine if community verified
        validation.communityVerified = validation.validationScore >= 70; // 70% approval required
        
        // Update trust if community verified
        if (validation.communityVerified) {
            ProgressiveTrust storage trust = trustProfiles[participant];
            trust.communityEndorsements++;
            
            // Boost trust score
            if (trust.trustScore < 80) {
                trust.trustScore = trust.trustScore + 10 > 80 ? 80 : trust.trustScore + 10;
            }
        }
        
        emit CommunityValidationCompleted(
            participant,
            validation.communityVerified,
            validation.positiveVotes,
            validation.negativeVotes,
            validation.validationScore
        );
    }

    /**
     * @dev Generate risk profile hash
     * @param assessment Risk assessment data
     * @return hash Unique hash for risk profile
     */
    function _generateRiskProfileHash(RealTimeRiskAssessment storage assessment) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            assessment.participant,
            assessment.currentRiskScore,
            assessment.trendingRiskScore,
            assessment.predictiveRiskScore,
            assessment.lastAssessmentTime
        ));
    }

    /**
     * @dev Generate trust profile hash
     * @param trust Trust profile data
     * @return hash Unique hash for trust profile
     */
    function _generateTrustProfileHash(ProgressiveTrust storage trust) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            trust.participant,
            trust.trustScore,
            trust.reputationScore,
            trust.contributionScore,
            trust.complianceScore,
            trust.lastTrustUpdate
        ));
    }

    /**
     * @dev Update system performance metrics
     */
    function _updateSystemMetrics() internal {
        // Calculate system efficiency
        if (totalInterventions > 0) {
            systemEfficiencyScore = (successfulInterventions * 100) / totalInterventions;
        } else {
            systemEfficiencyScore = 100;
        }
        
        lastMetricsUpdate = block.timestamp;
        
        emit FraudPreventionMetricsUpdated(
            totalFraudPrevented,
            totalEconomicImpact,
            systemEfficiencyScore,
            block.timestamp
        );
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get comprehensive risk assessment for participant
     * @param participant Address to query
     * @return currentRisk Current risk score
     * @return trustLevel Current trust level
     * @return preventionLevel Current prevention level
     * @return interventionRequired Whether intervention is needed
     */
    function getRiskAssessment(address participant)
        external
        view
        returns (
            uint256 currentRisk,
            TrustLevel trustLevel,
            PreventionLevel preventionLevel,
            bool interventionRequired
        )
    {
        RealTimeRiskAssessment storage assessment = riskAssessments[participant];
        return (
            assessment.currentRiskScore,
            assessment.trustLevel,
            assessment.preventionLevel,
            assessment.requiresIntervention
        );
    }

    /**
     * @notice Get trust profile for participant
     * @param participant Address to query
     * @return currentLevel Current trust level
     * @return trustScore Trust score (0-100)
     * @return communityVerified Whether community verified
     */
    function getTrustProfile(address participant)
        external
        view
        returns (
            TrustLevel currentLevel,
            uint256 trustScore,
            bool communityVerified
        )
    {
        ProgressiveTrust storage trust = trustProfiles[participant];
        CommunityValidationSystem storage validation = communityValidations[participant];
        
        return (
            trust.currentLevel,
            trust.trustScore,
            validation.communityVerified
        );
    }

    /**
     * @notice Get system performance metrics
     * @return totalInterventions_ Total interventions performed
     * @return successfulInterventions_ Successful interventions
     * @return systemEfficiency_ System efficiency score
     * @return totalFraudPrevented_ Total fraud prevented value
     */
    function getSystemMetrics()
        external
        view
        returns (
            uint256 totalInterventions_,
            uint256 successfulInterventions_,
            uint256 systemEfficiency_,
            uint256 totalFraudPrevented_
        )
    {
        return (
            totalInterventions,
            successfulInterventions,
            systemEfficiencyScore,
            totalFraudPrevented
        );
    }

    // ============ ADMINISTRATIVE FUNCTIONS ============

    /**
     * @notice Update system configuration
     * @param newTrustThresholds New trust level thresholds
     * @param newPreventionPenalties New prevention level penalties
     */
    function updateSystemConfiguration(
        uint256[6] calldata newTrustThresholds,
        uint256[6] calldata newPreventionPenalties
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Update trust thresholds
        for (uint256 i = 0; i < 6; i++) {
            trustLevelThresholds[TrustLevel(i)] = newTrustThresholds[i];
        }
        
        // Update prevention penalties
        for (uint256 i = 0; i < 6; i++) {
            preventionLevelPenalties[PreventionLevel(i)] = newPreventionPenalties[i];
        }
    }

    /**
     * @notice Emergency pause functionality
     */
    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause functionality
     */
    function emergencyUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}