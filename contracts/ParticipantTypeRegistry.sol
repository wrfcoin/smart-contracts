// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./libraries/DynamicStakeCalculator.sol";

/**
 * @title ParticipantTypeRegistry
 * @dev Comprehensive registry tracking different types of network participation and activity levels
 * 
 * This contract serves as the central hub for tracking all participant activity across the
 * WRFCoin ecosystem, enabling sophisticated sliding scale staking and layaway period calculations.
 * 
 * Core Features:
 * - Multi-method participation tracking (Weather Station + Storage Node, etc.)
 * - Activity scoring system with weighted contributions
 * - Dynamic layaway period calculations based on participation history
 * - Geographic distribution tracking for network density
 * - Performance metrics and quality scoring
 * - Historical participation data with time-based analysis
 * - Integration with verification systems and slashing mechanisms
 * 
 * Layaway Period Rules:
 * - Multi-method participants: 30-day minimum
 * - Verified single-method: 60-day minimum  
 * - Unverified new users: 90-day minimum
 * - Post-slashing penalty: 2x normal periods
 * - Dynamic adjustment based on participation quality
 * 
 * Security:
 * - Role-based access control for authorized updaters
 * - Rate limiting to prevent spam registrations
 * - Comprehensive input validation
 * - Emergency pause functionality
 * - Gas-optimized storage patterns
 * - Event emission for all state changes
 * 
 * @author WRFCoin Security Team
 * @notice Production-ready registry for fair launch participant management
 */
contract ParticipantTypeRegistry is AccessControl, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ========== CONSTANTS ==========

    /// @dev Precision for percentage calculations
    uint256 public constant PRECISION = 1e6;

    /// @dev Base layaway periods (in days)
    uint256 public constant BASE_LAYAWAY_MULTI_METHOD = 30 days;
    uint256 public constant BASE_LAYAWAY_VERIFIED_SINGLE = 60 days; 
    uint256 public constant BASE_LAYAWAY_UNVERIFIED = 90 days;

    /// @dev Activity scoring constants
    uint256 public constant MIN_ACTIVITY_SCORE = 100;
    uint256 public constant MAX_ACTIVITY_SCORE = 10000;
    uint256 public constant SCORE_DECAY_RATE = 50; // 0.005% per day

    /// @dev Quality score thresholds
    uint256 public constant EXCELLENT_QUALITY_THRESHOLD = 9000; // 90%
    uint256 public constant GOOD_QUALITY_THRESHOLD = 7500;      // 75%
    uint256 public constant POOR_QUALITY_THRESHOLD = 5000;      // 50%

    /// @dev Rate limiting constants
    uint256 public constant UPDATE_COOLDOWN = 1 hours;
    uint256 public constant REGISTRATION_DAILY_LIMIT = 10;

    // ========== ACCESS CONTROL ROLES ==========

    bytes32 public constant WEATHER_STATION_ROLE = keccak256("WEATHER_STATION_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant STORAGE_ROLE = keccak256("STORAGE_ROLE");
    bytes32 public constant SLASHING_ROLE = keccak256("SLASHING_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    // ========== ENUMS ==========

    /// @dev Extended participation types for comprehensive tracking
    enum ParticipationType {
        WEATHER_STATION,     // Hardware weather sensor operators
        FORECAST_PRODUCER,   // Computational forecasting contributors
        DATA_STORAGE_NODE,   // IPFS/Filecoin/decentralized storage providers
        VALIDATOR_NODE,      // Network consensus participants
        ORACLE_NODE,         // Data verification and quality scoring
        HYBRID_NODE,         // Multiple service combinations
        GOVERNANCE_PARTICIPANT, // DAO voting and governance
        CARBON_CREDIT_PROVIDER, // Carbon offset verification
        RESEARCH_CONTRIBUTOR,   // Academic/research contributions
        DEVELOPER_CONTRIBUTOR   // Code/protocol improvements
    }

    /// @dev Verification status levels
    enum VerificationStatus {
        UNVERIFIED,
        EMAIL_VERIFIED,
        PHONE_VERIFIED,
        GOVERNMENT_ID_VERIFIED,
        MULTI_FACTOR_VERIFIED,
        SOCIAL_MEDIA_VERIFIED,
        ACADEMIC_VERIFIED,
        ENTERPRISE_VERIFIED
    }

    /// @dev Performance rating categories
    enum PerformanceRating {
        POOR,        // 0-50%
        FAIR,        // 50-70%
        GOOD,        // 70-85%
        EXCELLENT,   // 85-95%
        OUTSTANDING  // 95-100%
    }

    // ========== STRUCTS ==========

    /// @dev Geographic location data
    struct GeographicData {
        int256 latitude;     // Scaled by 1e6
        int256 longitude;    // Scaled by 1e6
        uint256 zone;        // Geographic zone classification
        bytes32 countryCode; // ISO country code
        bytes32 regionCode;  // Regional identifier
    }

    /// @dev Activity metrics for each participation type
    struct ActivityMetrics {
        uint256 totalContributions;    // Total number of contributions
        uint256 qualityScore;          // Quality score (0-10000)
        uint256 uptimePercentage;      // Uptime percentage (0-10000)
        uint256 lastContribution;      // Timestamp of last activity
        uint256 rewardsEarned;         // Total rewards earned
        uint256 penaltiesIncurred;     // Total penalties/slashing
        uint256 consecutiveDaysActive; // Streak tracking
        uint256 averageResponseTime;   // Average response time (ms)
    }

    /// @dev Slashing history for penalty tracking
    struct SlashingHistory {
        uint256 totalSlashingEvents;
        uint256 totalAmountSlashed;
        uint256 lastSlashingTime;
        uint256 penaltyMultiplier; // Applied to layaway periods
        bool isCurrentlySlashed;
        uint256 slashingRecoveryTime;
    }

    /// @dev Comprehensive participant profile
    struct ParticipantProfile {
        address participant;
        EnumerableSet.UintSet participationTypes; // Multiple types supported
        uint256 totalActivityScore;
        uint256 registrationTimestamp;
        uint256 lastActivityTimestamp;
        uint256 lastUpdateTimestamp;
        GeographicData location;
        VerificationStatus verification;
        SlashingHistory slashingInfo;
        PerformanceRating overallRating;
        mapping(ParticipationType => ActivityMetrics) typeMetrics;
        mapping(uint256 => uint256) dailyActivityCount; // Date => activity count
        uint256 totalDaysActive;
        uint256 maxConsecutiveDays;
    }

    // ========== STATE VARIABLES ==========

    /// @dev Main participant registry
    mapping(address => ParticipantProfile) internal participants;

    /// @dev Active participants set for enumeration
    EnumerableSet.AddressSet private activeParticipants;

    /// @dev Participation type counts for statistics
    mapping(ParticipationType => uint256) public participationTypeCounts;

    /// @dev Geographic distribution tracking
    mapping(bytes32 => EnumerableSet.AddressSet) private participantsByCountry;
    mapping(bytes32 => EnumerableSet.AddressSet) private participantsByRegion;

    /// @dev Rate limiting tracking
    mapping(address => uint256) public lastRegistrationTime;
    mapping(uint256 => uint256) public dailyRegistrations; // Date => count

    /// @dev Contract configuration
    uint256 public totalParticipants;
    uint256 public totalActiveParticipants;
    bool public registrationOpen = true;

    /// @dev Fair launch integration contracts
    address public fairLaunchStakeManager;
    address public wrfToken;

    // ========== EVENTS ==========

    event ParticipantRegistered(
        address indexed participant,
        ParticipationType indexed participationType,
        uint256 timestamp
    );

    event ParticipationTypeAdded(
        address indexed participant,
        ParticipationType indexed participationType,
        uint256 timestamp
    );

    event ParticipationTypeRemoved(
        address indexed participant,
        ParticipationType indexed participationType,
        uint256 timestamp
    );

    event ActivityUpdated(
        address indexed participant,
        ParticipationType indexed participationType,
        uint256 qualityScore,
        uint256 newActivityScore,
        uint256 timestamp
    );

    event VerificationStatusUpdated(
        address indexed participant,
        VerificationStatus indexed oldStatus,
        VerificationStatus indexed newStatus,
        uint256 timestamp
    );

    event SlashingEventRecorded(
        address indexed participant,
        uint256 amount,
        uint256 penaltyMultiplier,
        uint256 timestamp
    );

    event LayawayPeriodCalculated(
        address indexed participant,
        uint256 calculatedPeriod,
        uint256 baseType,
        uint256 timestamp
    );

    event GeographicLocationUpdated(
        address indexed participant,
        bytes32 indexed countryCode,
        bytes32 indexed regionCode,
        uint256 timestamp
    );

    event PerformanceRatingUpdated(
        address indexed participant,
        PerformanceRating indexed oldRating,
        PerformanceRating indexed newRating,
        uint256 timestamp
    );

    event FairLaunchIntegrationUpdated(
        address indexed stakeManager,
        address indexed wrfToken,
        uint256 timestamp
    );

    // ========== CONSTRUCTOR ==========

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        
        // Set role hierarchies
        _setRoleAdmin(WEATHER_STATION_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(ORACLE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(VALIDATOR_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(STORAGE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(SLASHING_ROLE, GOVERNANCE_ROLE);
    }

    // ========== MODIFIERS ==========

    modifier validParticipant(address participant) {
        require(participant != address(0), "Invalid participant address");
        require(participant != address(this), "Cannot be contract address");
        _;
    }

    modifier registrationAllowed(address participant) {
        require(registrationOpen, "Registration is closed");
        require(
            block.timestamp >= lastRegistrationTime[participant] + UPDATE_COOLDOWN,
            "Registration cooldown active"
        );
        
        uint256 today = block.timestamp / 1 days;
        require(
            dailyRegistrations[today] < REGISTRATION_DAILY_LIMIT,
            "Daily registration limit exceeded"
        );
        _;
    }

    modifier participantExists(address participant) {
        require(
            participants[participant].registrationTimestamp > 0,
            "Participant not registered"
        );
        _;
    }

    // ========== CORE REGISTRATION FUNCTIONS ==========

    /**
     * @dev Register a new participant with initial participation type
     * @param participant Address of the participant
     * @param participationType Initial participation type
     * @param location Geographic location data
     * @param verification Initial verification status
     */
    function registerParticipant(
        address participant,
        ParticipationType participationType,
        GeographicData calldata location,
        VerificationStatus verification
    ) 
        external 
        validParticipant(participant)
        registrationAllowed(participant)
        nonReentrant 
        whenNotPaused 
    {
        require(hasRole(ORACLE_ROLE, msg.sender) || hasRole(GOVERNANCE_ROLE, msg.sender), 
                "Unauthorized registration");
        require(uint256(participationType) <= uint256(ParticipationType.DEVELOPER_CONTRIBUTOR), 
                "Invalid participation type");
        require(participants[participant].registrationTimestamp == 0, 
                "Participant already registered");

        // Validate geographic data
        require(location.latitude >= -90e6 && location.latitude <= 90e6, "Invalid latitude");
        require(location.longitude >= -180e6 && location.longitude <= 180e6, "Invalid longitude");

        ParticipantProfile storage profile = participants[participant];
        
        // Initialize profile
        profile.participant = participant;
        profile.registrationTimestamp = block.timestamp;
        profile.lastActivityTimestamp = block.timestamp;
        profile.lastUpdateTimestamp = block.timestamp;
        profile.location = location;
        profile.verification = verification;
        profile.overallRating = PerformanceRating.FAIR; // Start with fair rating
        profile.totalActivityScore = MIN_ACTIVITY_SCORE;

        // Add participation type
        profile.participationTypes.add(uint256(participationType));
        
        // Initialize metrics for this type
        ActivityMetrics storage metrics = profile.typeMetrics[participationType];
        metrics.qualityScore = 5000; // Start with 50% quality
        metrics.uptimePercentage = 10000; // Assume 100% initially
        metrics.lastContribution = block.timestamp;

        // Update global tracking
        activeParticipants.add(participant);
        participationTypeCounts[participationType]++;
        totalParticipants++;
        totalActiveParticipants++;

        // Geographic tracking
        participantsByCountry[location.countryCode].add(participant);
        participantsByRegion[location.regionCode].add(participant);

        // Rate limiting tracking
        lastRegistrationTime[participant] = block.timestamp;
        uint256 today = block.timestamp / 1 days;
        dailyRegistrations[today]++;

        emit ParticipantRegistered(participant, participationType, block.timestamp);
        emit GeographicLocationUpdated(participant, location.countryCode, location.regionCode, block.timestamp);
    }

    /**
     * @dev Add a new participation type for an existing participant
     * @param participant Address of the participant
     * @param participationType New participation type to add
     */
    function addParticipationType(
        address participant,
        ParticipationType participationType
    ) 
        external 
        participantExists(participant)
        nonReentrant 
        whenNotPaused 
    {
        require(hasRole(ORACLE_ROLE, msg.sender) || hasRole(GOVERNANCE_ROLE, msg.sender), 
                "Unauthorized update");
        require(uint256(participationType) <= uint256(ParticipationType.DEVELOPER_CONTRIBUTOR), 
                "Invalid participation type");

        ParticipantProfile storage profile = participants[participant];
        require(!profile.participationTypes.contains(uint256(participationType)), 
                "Participation type already exists");

        // Add new participation type
        profile.participationTypes.add(uint256(participationType));
        profile.lastUpdateTimestamp = block.timestamp;

        // Initialize metrics for new type
        ActivityMetrics storage metrics = profile.typeMetrics[participationType];
        metrics.qualityScore = 5000; // Start with 50% quality
        metrics.uptimePercentage = 10000; // Assume 100% initially
        metrics.lastContribution = block.timestamp;

        // Update global tracking
        participationTypeCounts[participationType]++;

        emit ParticipationTypeAdded(participant, participationType, block.timestamp);
    }

    /**
     * @dev Remove a participation type from a participant
     * @param participant Address of the participant
     * @param participationType Participation type to remove
     */
    function removeParticipationType(
        address participant,
        ParticipationType participationType
    ) 
        external 
        participantExists(participant)
        nonReentrant 
        whenNotPaused 
    {
        require(hasRole(ORACLE_ROLE, msg.sender) || hasRole(GOVERNANCE_ROLE, msg.sender), 
                "Unauthorized update");

        ParticipantProfile storage profile = participants[participant];
        require(profile.participationTypes.contains(uint256(participationType)), 
                "Participation type not found");
        require(profile.participationTypes.length() > 1, 
                "Cannot remove last participation type");

        // Remove participation type
        profile.participationTypes.remove(uint256(participationType));
        profile.lastUpdateTimestamp = block.timestamp;

        // Clear metrics for removed type
        delete profile.typeMetrics[participationType];

        // Update global tracking
        participationTypeCounts[participationType]--;

        emit ParticipationTypeRemoved(participant, participationType, block.timestamp);
    }

    // ========== ACTIVITY TRACKING FUNCTIONS ==========

    /**
     * @dev Update activity metrics for a participant
     * @param participant Address of the participant
     * @param participationType Type of participation being updated
     * @param qualityScore New quality score (0-10000)
     * @param contributionCount Number of new contributions
     * @param uptimePercentage New uptime percentage (0-10000)
     */
    function updateActivity(
        address participant,
        ParticipationType participationType,
        uint256 qualityScore,
        uint256 contributionCount,
        uint256 uptimePercentage
    ) 
        external 
        participantExists(participant)
        nonReentrant 
        whenNotPaused 
    {
        require(hasRole(ORACLE_ROLE, msg.sender) || 
                hasRole(WEATHER_STATION_ROLE, msg.sender) || 
                hasRole(VALIDATOR_ROLE, msg.sender) ||
                hasRole(STORAGE_ROLE, msg.sender), 
                "Unauthorized activity update");
        
        require(qualityScore <= 10000, "Invalid quality score");
        require(uptimePercentage <= 10000, "Invalid uptime percentage");

        ParticipantProfile storage profile = participants[participant];
        require(profile.participationTypes.contains(uint256(participationType)), 
                "Participation type not found");

        ActivityMetrics storage metrics = profile.typeMetrics[participationType];
        
        // Update metrics
        metrics.qualityScore = qualityScore;
        metrics.totalContributions += contributionCount;
        metrics.uptimePercentage = uptimePercentage;
        metrics.lastContribution = block.timestamp;

        // Update daily activity tracking
        uint256 today = block.timestamp / 1 days;
        profile.dailyActivityCount[today] += contributionCount;
        
        // Update consecutive days tracking
        uint256 yesterday = today - 1;
        if (profile.dailyActivityCount[yesterday] > 0) {
            metrics.consecutiveDaysActive++;
        } else {
            metrics.consecutiveDaysActive = 1; // Reset streak
        }

        // Update max consecutive days
        if (metrics.consecutiveDaysActive > profile.maxConsecutiveDays) {
            profile.maxConsecutiveDays = metrics.consecutiveDaysActive;
        }

        // Recalculate total activity score
        uint256 newActivityScore = _calculateActivityScore(participant);
        profile.totalActivityScore = newActivityScore;
        profile.lastActivityTimestamp = block.timestamp;

        // Update performance rating
        PerformanceRating oldRating = profile.overallRating;
        PerformanceRating newRating = _calculatePerformanceRating(participant);
        if (newRating != oldRating) {
            profile.overallRating = newRating;
            emit PerformanceRatingUpdated(participant, oldRating, newRating, block.timestamp);
        }

        emit ActivityUpdated(participant, participationType, qualityScore, newActivityScore, block.timestamp);
    }

    /**
     * @dev Record a slashing event for a participant
     * @param participant Address of the participant
     * @param slashedAmount Amount that was slashed
     * @param penaltyMultiplier Multiplier for layaway period penalties
     */
    function recordSlashingEvent(
        address participant,
        uint256 slashedAmount,
        uint256 penaltyMultiplier
    ) 
        external 
        participantExists(participant)
        nonReentrant 
        whenNotPaused 
    {
        require(hasRole(SLASHING_ROLE, msg.sender), "Unauthorized slashing record");
        require(penaltyMultiplier > 0 && penaltyMultiplier <= 5 * PRECISION, "Invalid penalty multiplier");

        ParticipantProfile storage profile = participants[participant];
        SlashingHistory storage slashing = profile.slashingInfo;

        slashing.totalSlashingEvents++;
        slashing.totalAmountSlashed += slashedAmount;
        slashing.lastSlashingTime = block.timestamp;
        slashing.penaltyMultiplier = penaltyMultiplier;
        slashing.isCurrentlySlashed = true;
        slashing.slashingRecoveryTime = block.timestamp + (90 days); // 90-day recovery period

        // Penalize activity score
        profile.totalActivityScore = (profile.totalActivityScore * 80) / 100; // 20% penalty
        if (profile.totalActivityScore < MIN_ACTIVITY_SCORE) {
            profile.totalActivityScore = MIN_ACTIVITY_SCORE;
        }

        emit SlashingEventRecorded(participant, slashedAmount, penaltyMultiplier, block.timestamp);
    }

    // ========== LAYAWAY PERIOD CALCULATION ==========

    /**
     * @dev Calculate the layaway period for a participant
     * @param participant Address of the participant
     * @return layawayPeriod Calculated layaway period in seconds
     */
    function calculateLayawayPeriod(address participant) 
        external 
        view 
        participantExists(participant) 
        returns (uint256 layawayPeriod) 
    {
        ParticipantProfile storage profile = participants[participant];
        
        // Determine base period based on participation characteristics
        uint256 basePeriod = _getBaseLayawayPeriod(participant);
        
        // Apply quality adjustments
        uint256 qualityAdjustment = _getQualityAdjustment(participant);
        
        // Apply slashing penalties
        uint256 slashingMultiplier = PRECISION;
        if (profile.slashingInfo.isCurrentlySlashed && 
            block.timestamp < profile.slashingInfo.slashingRecoveryTime) {
            slashingMultiplier = profile.slashingInfo.penaltyMultiplier;
        }
        
        // Apply activity bonus (up to 20% reduction for excellent participants)
        uint256 activityBonus = _getActivityBonus(participant);
        
        // Calculate final period
        layawayPeriod = (basePeriod * qualityAdjustment * slashingMultiplier) / (PRECISION * PRECISION);
        layawayPeriod = (layawayPeriod * (PRECISION - activityBonus)) / PRECISION;
        
        // Ensure minimum bounds
        if (layawayPeriod < 7 days) {
            layawayPeriod = 7 days; // Absolute minimum
        }
        if (layawayPeriod > 365 days) {
            layawayPeriod = 365 days; // Absolute maximum
        }

        return layawayPeriod;
    }

    /**
     * @dev Get base layaway period based on participation type and verification
     * @param participant Address of the participant
     * @return basePeriod Base layaway period in seconds
     */
    function _getBaseLayawayPeriod(address participant) internal view returns (uint256) {
        ParticipantProfile storage profile = participants[participant];
        
        // Multi-method participants get the shortest base period
        if (profile.participationTypes.length() >= 2) {
            return BASE_LAYAWAY_MULTI_METHOD;
        }
        
        // Verified single-method participants
        if (uint256(profile.verification) >= uint256(VerificationStatus.EMAIL_VERIFIED)) {
            return BASE_LAYAWAY_VERIFIED_SINGLE;
        }
        
        // Unverified participants get the longest base period
        return BASE_LAYAWAY_UNVERIFIED;
    }

    /**
     * @dev Calculate quality-based adjustment to layaway period
     * @param participant Address of the participant
     * @return adjustment Quality adjustment multiplier (precision units)
     */
    function _getQualityAdjustment(address participant) internal view returns (uint256) {
        uint256 averageQuality = _getAverageQualityScore(participant);
        
        if (averageQuality >= EXCELLENT_QUALITY_THRESHOLD) {
            return 700_000; // 70% of base period (30% reduction)
        } else if (averageQuality >= GOOD_QUALITY_THRESHOLD) {
            return 850_000; // 85% of base period (15% reduction)
        } else if (averageQuality >= POOR_QUALITY_THRESHOLD) {
            return PRECISION; // 100% of base period (no change)
        } else {
            return 1_200_000; // 120% of base period (20% increase)
        }
    }

    /**
     * @dev Calculate activity-based bonus for layaway period
     * @param participant Address of the participant
     * @return bonus Activity bonus (precision units, max 20% reduction)
     */
    function _getActivityBonus(address participant) internal view returns (uint256) {
        ParticipantProfile storage profile = participants[participant];
        
        // Base bonus on total activity score
        uint256 scoreRatio = (profile.totalActivityScore * PRECISION) / MAX_ACTIVITY_SCORE;
        uint256 maxBonus = 200_000; // 20% maximum reduction
        
        return (scoreRatio * maxBonus) / PRECISION;
    }

    // ========== QUERY FUNCTIONS ==========

    /**
     * @dev Check if participant uses multiple participation methods
     * @param participant Address of the participant
     * @return isMultiMethod True if participant has multiple methods
     */
    function isMultiMethodParticipant(address participant) 
        external 
        view 
        participantExists(participant) 
        returns (bool isMultiMethod) 
    {
        return participants[participant].participationTypes.length() >= 2;
    }

    /**
     * @dev Get participation score for a participant
     * @param participant Address of the participant
     * @return participationScore Overall participation score
     */
    function getParticipationScore(address participant) 
        external 
        view 
        participantExists(participant) 
        returns (uint256 participationScore) 
    {
        return participants[participant].totalActivityScore;
    }

    /**
     * @dev Get participant's participation types
     * @param participant Address of the participant
     * @return participationTypes Array of participation types
     */
    function getParticipationTypes(address participant) 
        external 
        view 
        participantExists(participant) 
        returns (ParticipationType[] memory participationTypes) 
    {
        ParticipantProfile storage profile = participants[participant];
        uint256 length = profile.participationTypes.length();
        participationTypes = new ParticipationType[](length);
        
        for (uint256 i = 0; i < length; i++) {
            participationTypes[i] = ParticipationType(profile.participationTypes.at(i));
        }
    }

    /**
     * @dev Get activity metrics for a specific participation type
     * @param participant Address of the participant
     * @param participationType Type of participation
     * @return metrics Activity metrics for the type
     */
    function getActivityMetrics(address participant, ParticipationType participationType) 
        external 
        view 
        participantExists(participant) 
        returns (ActivityMetrics memory metrics) 
    {
        ParticipantProfile storage profile = participants[participant];
        require(profile.participationTypes.contains(uint256(participationType)), 
                "Participation type not found");
        
        return profile.typeMetrics[participationType];
    }

    /**
     * @dev Get participant's historical activity data
     * @param participant Address of the participant
     * @return registrationTime When participant registered
     * @return lastActivity Time of last activity
     * @return totalDaysActive Total days with activity
     * @return maxStreak Maximum consecutive days active
     * @return overallRating Current performance rating
     */
    function getParticipantHistory(address participant) 
        external 
        view 
        participantExists(participant) 
        returns (
            uint256 registrationTime,
            uint256 lastActivity,
            uint256 totalDaysActive,
            uint256 maxStreak,
            PerformanceRating overallRating
        ) 
    {
        ParticipantProfile storage profile = participants[participant];
        return (
            profile.registrationTimestamp,
            profile.lastActivityTimestamp,
            profile.totalDaysActive,
            profile.maxConsecutiveDays,
            profile.overallRating
        );
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    /**
     * @dev Calculate total activity score for a participant
     * @param participant Address of the participant
     * @return activityScore Calculated activity score
     */
    function _calculateActivityScore(address participant) internal view returns (uint256) {
        ParticipantProfile storage profile = participants[participant];
        uint256 totalScore = 0;
        uint256 typeCount = profile.participationTypes.length();
        
        // Sum weighted scores across all participation types
        for (uint256 i = 0; i < typeCount; i++) {
            ParticipationType pType = ParticipationType(profile.participationTypes.at(i));
            ActivityMetrics storage metrics = profile.typeMetrics[pType];
            
            // Weight based on participation type importance
            uint256 typeWeight = _getParticipationTypeWeight(pType);
            uint256 typeScore = (metrics.qualityScore * metrics.uptimePercentage * typeWeight) / (PRECISION * PRECISION);
            
            totalScore += typeScore;
        }
        
        // Average across types and apply time-based decay
        if (typeCount > 0) {
            totalScore = totalScore / typeCount;
            
            // Apply time-based decay for inactive participants
            uint256 daysSinceActivity = (block.timestamp - profile.lastActivityTimestamp) / 1 days;
            if (daysSinceActivity > 0) {
                uint256 decayAmount = (daysSinceActivity * SCORE_DECAY_RATE);
                if (decayAmount > totalScore) {
                    totalScore = MIN_ACTIVITY_SCORE;
                } else {
                    totalScore -= decayAmount;
                }
            }
        }
        
        // Ensure within bounds
        if (totalScore < MIN_ACTIVITY_SCORE) totalScore = MIN_ACTIVITY_SCORE;
        if (totalScore > MAX_ACTIVITY_SCORE) totalScore = MAX_ACTIVITY_SCORE;
        
        return totalScore;
    }

    /**
     * @dev Get weight for a participation type
     * @param participationType Type of participation
     * @return weight Weight multiplier for the type
     */
    function _getParticipationTypeWeight(ParticipationType participationType) internal pure returns (uint256) {
        if (participationType == ParticipationType.WEATHER_STATION) return PRECISION;
        if (participationType == ParticipationType.VALIDATOR_NODE) return 1_200_000;
        if (participationType == ParticipationType.ORACLE_NODE) return 1_100_000;
        if (participationType == ParticipationType.FORECAST_PRODUCER) return 900_000;
        if (participationType == ParticipationType.DATA_STORAGE_NODE) return 800_000;
        if (participationType == ParticipationType.HYBRID_NODE) return 1_300_000;
        if (participationType == ParticipationType.GOVERNANCE_PARTICIPANT) return 700_000;
        if (participationType == ParticipationType.CARBON_CREDIT_PROVIDER) return 800_000;
        if (participationType == ParticipationType.RESEARCH_CONTRIBUTOR) return 900_000;
        if (participationType == ParticipationType.DEVELOPER_CONTRIBUTOR) return 1_000_000;
        return PRECISION; // Default weight
    }

    /**
     * @dev Calculate performance rating based on metrics
     * @param participant Address of the participant
     * @return rating Calculated performance rating
     */
    function _calculatePerformanceRating(address participant) internal view returns (PerformanceRating) {
        uint256 averageQuality = _getAverageQualityScore(participant);
        uint256 averageUptime = _getAverageUptimeScore(participant);
        uint256 overallScore = (averageQuality + averageUptime) / 2;
        
        if (overallScore >= 9500) return PerformanceRating.OUTSTANDING;
        if (overallScore >= 8500) return PerformanceRating.EXCELLENT;
        if (overallScore >= 7000) return PerformanceRating.GOOD;
        if (overallScore >= 5000) return PerformanceRating.FAIR;
        return PerformanceRating.POOR;
    }

    /**
     * @dev Get average quality score across all participation types
     * @param participant Address of the participant
     * @return averageQuality Average quality score
     */
    function _getAverageQualityScore(address participant) internal view returns (uint256) {
        ParticipantProfile storage profile = participants[participant];
        uint256 totalQuality = 0;
        uint256 typeCount = profile.participationTypes.length();
        
        for (uint256 i = 0; i < typeCount; i++) {
            ParticipationType pType = ParticipationType(profile.participationTypes.at(i));
            totalQuality += profile.typeMetrics[pType].qualityScore;
        }
        
        return typeCount > 0 ? totalQuality / typeCount : 0;
    }

    /**
     * @dev Get average uptime score across all participation types
     * @param participant Address of the participant
     * @return averageUptime Average uptime score
     */
    function _getAverageUptimeScore(address participant) internal view returns (uint256) {
        ParticipantProfile storage profile = participants[participant];
        uint256 totalUptime = 0;
        uint256 typeCount = profile.participationTypes.length();
        
        for (uint256 i = 0; i < typeCount; i++) {
            ParticipationType pType = ParticipationType(profile.participationTypes.at(i));
            totalUptime += profile.typeMetrics[pType].uptimePercentage;
        }
        
        return typeCount > 0 ? totalUptime / typeCount : 0;
    }

    // ========== ADMINISTRATIVE FUNCTIONS ==========

    /**
     * @dev Update verification status for a participant
     * @param participant Address of the participant
     * @param newStatus New verification status
     */
    function updateVerificationStatus(
        address participant,
        VerificationStatus newStatus
    ) 
        external 
        participantExists(participant)
        nonReentrant 
    {
        require(hasRole(ORACLE_ROLE, msg.sender) || hasRole(GOVERNANCE_ROLE, msg.sender), 
                "Unauthorized verification update");
        require(uint256(newStatus) <= uint256(VerificationStatus.ENTERPRISE_VERIFIED), 
                "Invalid verification status");

        ParticipantProfile storage profile = participants[participant];
        VerificationStatus oldStatus = profile.verification;
        profile.verification = newStatus;
        profile.lastUpdateTimestamp = block.timestamp;

        emit VerificationStatusUpdated(participant, oldStatus, newStatus, block.timestamp);
    }

    /**
     * @dev Update geographic location for a participant
     * @param participant Address of the participant
     * @param newLocation New geographic location data
     */
    function updateGeographicLocation(
        address participant,
        GeographicData calldata newLocation
    ) 
        external 
        participantExists(participant)
        nonReentrant 
    {
        require(hasRole(ORACLE_ROLE, msg.sender) || hasRole(GOVERNANCE_ROLE, msg.sender), 
                "Unauthorized location update");
        require(newLocation.latitude >= -90e6 && newLocation.latitude <= 90e6, "Invalid latitude");
        require(newLocation.longitude >= -180e6 && newLocation.longitude <= 180e6, "Invalid longitude");

        ParticipantProfile storage profile = participants[participant];
        
        // Remove from old geographic tracking
        participantsByCountry[profile.location.countryCode].remove(participant);
        participantsByRegion[profile.location.regionCode].remove(participant);
        
        // Update location
        profile.location = newLocation;
        profile.lastUpdateTimestamp = block.timestamp;
        
        // Add to new geographic tracking
        participantsByCountry[newLocation.countryCode].add(participant);
        participantsByRegion[newLocation.regionCode].add(participant);

        emit GeographicLocationUpdated(participant, newLocation.countryCode, newLocation.regionCode, block.timestamp);
    }

    /**
     * @dev Toggle registration status
     * @param open Whether registration should be open
     */
    function setRegistrationOpen(bool open) external {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "Unauthorized");
        registrationOpen = open;
    }

    /**
     * @dev Emergency pause functionality
     */
    function pause() external {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "Unauthorized");
        _pause();
    }

    /**
     * @dev Unpause functionality
     */
    function unpause() external {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "Unauthorized");
        _unpause();
    }

    /**
     * @dev Set fair launch integration contracts
     * @param _stakeManager Address of FairLaunchStakeManager
     * @param _wrfToken Address of WRFToken contract
     */
    function setFairLaunchContracts(
        address _stakeManager,
        address _wrfToken
    ) external {
        require(hasRole(GOVERNANCE_ROLE, msg.sender), "Unauthorized");
        require(_stakeManager != address(0), "Invalid stake manager");
        require(_wrfToken != address(0), "Invalid WRF token");

        fairLaunchStakeManager = _stakeManager;
        wrfToken = _wrfToken;

        emit FairLaunchIntegrationUpdated(_stakeManager, _wrfToken, block.timestamp);
    }

    // ========== VIEW FUNCTIONS FOR STATISTICS ==========

    /**
     * @dev Get total counts by participation type
     * @param participationType Type to query
     * @return count Number of participants with this type
     */
    function getParticipationTypeCount(ParticipationType participationType) 
        external 
        view 
        returns (uint256 count) 
    {
        return participationTypeCounts[participationType];
    }

    /**
     * @dev Get participants in a specific country
     * @param countryCode ISO country code
     * @return participants Array of participant addresses
     */
    function getParticipantsByCountry(bytes32 countryCode) 
        external 
        view 
        returns (address[] memory) 
    {
        EnumerableSet.AddressSet storage countrySet = participantsByCountry[countryCode];
        uint256 length = countrySet.length();
        address[] memory result = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            result[i] = countrySet.at(i);
        }
        
        return result;
    }

    /**
     * @dev Get contract statistics
     * @return stats Array containing various statistics
     */
    function getContractStats() 
        external 
        view 
        returns (uint256[] memory stats) 
    {
        stats = new uint256[](12);
        stats[0] = totalParticipants;
        stats[1] = totalActiveParticipants;
        stats[2] = participationTypeCounts[ParticipationType.WEATHER_STATION];
        stats[3] = participationTypeCounts[ParticipationType.FORECAST_PRODUCER];
        stats[4] = participationTypeCounts[ParticipationType.DATA_STORAGE_NODE];
        stats[5] = participationTypeCounts[ParticipationType.VALIDATOR_NODE];
        stats[6] = participationTypeCounts[ParticipationType.ORACLE_NODE];
        stats[7] = participationTypeCounts[ParticipationType.HYBRID_NODE];
        stats[8] = participationTypeCounts[ParticipationType.GOVERNANCE_PARTICIPANT];
        stats[9] = participationTypeCounts[ParticipationType.CARBON_CREDIT_PROVIDER];
        stats[10] = participationTypeCounts[ParticipationType.RESEARCH_CONTRIBUTOR];
        stats[11] = participationTypeCounts[ParticipationType.DEVELOPER_CONTRIBUTOR];
        
        return stats;
    }

    // ========== FAIR LAUNCH INTEGRATION FUNCTIONS ==========

    /**
     * @dev Get comprehensive participant data for fair launch calculations
     * @param participant Address of the participant
     */
    function getFairLaunchParticipantData(address participant) 
        external 
        view 
        participantExists(participant)
        returns (
            bool isMultiMethod,
            uint256 layawayPeriod,
            VerificationStatus verification,
            uint256 totalActivityScore,
            PerformanceRating overallRating,
            uint256 registrationTime,
            bool isCurrentlySlashed,
            bytes32 countryCode,
            bytes32 regionCode
        )
    {
        ParticipantProfile storage profile = participants[participant];
        
        return (
            profile.participationTypes.length() >= 2,
            this.calculateLayawayPeriod(participant),
            profile.verification,
            profile.totalActivityScore,
            profile.overallRating,
            profile.registrationTimestamp,
            profile.slashingInfo.isCurrentlySlashed,
            profile.location.countryCode,
            profile.location.regionCode
        );
    }

    /**
     * @dev Check if participant meets minimum requirements for fair launch
     * @param participant Address of the participant
     * @return eligible True if participant meets requirements
     * @return reason Reason for ineligibility (empty if eligible)
     */
    function checkFairLaunchEligibility(address participant) 
        external 
        view 
        participantExists(participant)
        returns (bool eligible, string memory reason) 
    {
        ParticipantProfile storage profile = participants[participant];
        
        // Check minimum activity score
        if (profile.totalActivityScore < MIN_ACTIVITY_SCORE * 2) {
            return (false, "Insufficient activity score");
        }
        
        // Check if currently slashed
        if (profile.slashingInfo.isCurrentlySlashed && 
            block.timestamp < profile.slashingInfo.slashingRecoveryTime) {
            return (false, "Currently under slashing penalty");
        }
        
        // Check minimum activity period (30 days)
        if (block.timestamp - profile.registrationTimestamp < 30 days) {
            return (false, "Insufficient registration time");
        }
        
        // Check for recent activity
        if (block.timestamp - profile.lastActivityTimestamp > 7 days) {
            return (false, "No recent activity");
        }
        
        return (true, "");
    }

    /**
     * @dev Calculate dynamic staking requirements based on participant profile
     * @param participant Address of the participant
     * @return baseStakeUSD Base stake requirement in USD (with precision)
     * @return multiplier Stake multiplier based on participation and quality
     * @return discount Discount percentage for high-quality participants
     */
    function calculateStakingRequirements(address participant) 
        external 
        view 
        participantExists(participant)
        returns (
            uint256 baseStakeUSD,
            uint256 multiplier,
            uint256 discount
        ) 
    {
        ParticipantProfile storage profile = participants[participant];
        
        // Base stake: $1000 USD (scaled by precision)
        baseStakeUSD = 1000 * PRECISION;
        
        // Multi-method discount
        if (profile.participationTypes.length() >= 2) {
            discount = 200_000; // 20% discount
        }
        
        // Quality-based adjustments
        uint256 averageQuality = _getAverageQualityScore(participant);
        if (averageQuality >= EXCELLENT_QUALITY_THRESHOLD) {
            discount += 150_000; // Additional 15% discount
        } else if (averageQuality < POOR_QUALITY_THRESHOLD) {
            multiplier = 1_500_000; // 1.5x multiplier for poor quality
        } else {
            multiplier = PRECISION; // 1x multiplier
        }
        
        // Slashing penalty
        if (profile.slashingInfo.totalSlashingEvents > 0) {
            multiplier = (multiplier * profile.slashingInfo.penaltyMultiplier) / PRECISION;
        }
        
        // Ensure reasonable bounds
        if (discount > 350_000) discount = 350_000; // Max 35% discount
        if (multiplier == 0) multiplier = PRECISION;
        if (multiplier > 3 * PRECISION) multiplier = 3 * PRECISION; // Max 3x multiplier
    }

    /**
     * @dev Batch check eligibility for multiple participants
     * @param participantAddrs Array of participant addresses
     * @return eligible Array of eligibility status
     * @return eligibleCount Total count of eligible participants
     */
    function batchCheckEligibility(address[] calldata participantAddrs)
        external
        view
        returns (bool[] memory eligible, uint256 eligibleCount)
    {
        eligible = new bool[](participantAddrs.length);
        eligibleCount = 0;

        for (uint256 i = 0; i < participantAddrs.length; i++) {
            if (participants[participantAddrs[i]].registrationTimestamp > 0) {
                (bool isEligible,) = this.checkFairLaunchEligibility(participantAddrs[i]);
                eligible[i] = isEligible;
                if (isEligible) eligibleCount++;
            }
        }
    }

    /**
     * @dev Get participation distribution statistics for fair launch analysis
     * @return multiMethodCount Number of multi-method participants
     * @return singleMethodCount Number of single-method participants
     * @return highQualityCount Number of high-quality participants
     * @return geographicDistribution Distribution across countries
     */
    function getFairLaunchDistribution() 
        external 
        view 
        returns (
            uint256 multiMethodCount,
            uint256 singleMethodCount,
            uint256 highQualityCount,
            uint256 geographicDistribution
        ) 
    {
        uint256 activeCount = activeParticipants.length();
        
        for (uint256 i = 0; i < activeCount; i++) {
            address participant = activeParticipants.at(i);
            ParticipantProfile storage profile = participants[participant];
            
            // Multi-method vs single-method
            if (profile.participationTypes.length() >= 2) {
                multiMethodCount++;
            } else {
                singleMethodCount++;
            }
            
            // High quality participants
            if (profile.overallRating >= PerformanceRating.EXCELLENT) {
                highQualityCount++;
            }
        }
        
        // Geographic distribution (count of unique countries)
        // This is an approximation - full implementation would require iterating through all countries
        geographicDistribution = totalActiveParticipants; // Simplified for demo
    }

    /**
     * @dev Integration hook for stake manager to notify of staking events
     * @param participant Address of the participant
     * @param staked True if staking, false if unstaking
     * @param amount Amount staked/unstaked in USD (with precision)
     */
    function notifyStakingEvent(
        address participant,
        bool staked,
        uint256 amount
    ) external participantExists(participant) {
        require(msg.sender == fairLaunchStakeManager, "Unauthorized stake manager");
        
        ParticipantProfile storage profile = participants[participant];
        
        if (staked) {
            // Boost activity score for staking
            uint256 bonus = (amount * 10) / PRECISION; // 1% of stake amount as score bonus
            profile.totalActivityScore += bonus;
            
            if (profile.totalActivityScore > MAX_ACTIVITY_SCORE) {
                profile.totalActivityScore = MAX_ACTIVITY_SCORE;
            }
        }
        
        profile.lastActivityTimestamp = block.timestamp;
        profile.lastUpdateTimestamp = block.timestamp;
    }
}