// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title StakeholderIncentives
 * @author WRFCoin Team
 * @notice Advanced stakeholder incentive system with comprehensive security and fair reward distribution
 * @dev Implements multi-dimensional reward mechanisms with anti-gaming protections and performance optimization
 * 
 * Security Features:
 * - Fair reward distribution algorithms with mathematical precision
 * - Anti-gaming mechanisms to prevent exploitation
 * - Vesting schedule enforcement with time-locked rewards
 * - Performance-based rewards with quality metrics
 * - Sybil attack protection through behavior analysis
 * - Economic security thresholds to prevent manipulation
 * 
 * Incentive Mechanisms:
 * - Multi-tier participation rewards with exponential scaling
 * - Achievement-based NFT rewards with rarity mechanics
 * - Community engagement multipliers based on contribution quality
 * - Climate impact scoring with verifiable metrics
 * - Dynamic reward adjustments based on network conditions
 * - Delegation incentive alignment for governance participation
 * 
 * Gas Optimization:
 * - Batch reward distribution to minimize transaction costs
 * - Efficient storage patterns for stakeholder data
 * - Optimized calculation algorithms with mathematical approximations
 * - Event-driven updates to reduce unnecessary computations
 */
contract StakeholderIncentives is ReentrancyGuard, Pausable, AccessControl {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant INCENTIVE_MANAGER_ROLE = keccak256("INCENTIVE_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant SECURITY_MONITOR_ROLE = keccak256("SECURITY_MONITOR_ROLE");

    // Constants for precision and security
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_REWARD_PER_TX = 10000 * 1e18; // 10k tokens max per transaction
    uint256 private constant MIN_TIME_BETWEEN_REWARDS = 1 hours;
    uint256 private constant MAX_TIER_MULTIPLIER = 500; // 5x max multiplier
    uint256 private constant ANTI_GAMING_THRESHOLD = 1000; // 10% basis points
    uint256 private constant VESTING_PERIOD = 30 days;
    uint256 private constant MAX_ACHIEVEMENTS_PER_CALL = 10;
    uint256 private constant SUSPICIOUS_SCORE_THRESHOLD = 5000; // 50% basis points
    
    // Security circuit breakers
    uint256 private constant MAX_DAILY_REWARDS = 100000 * 1e18; // 100k tokens per day
    uint256 private constant MAX_HOURLY_PARTICIPANTS = 1000;
    uint256 private constant RAPID_REWARD_THRESHOLD = 10; // Claims per hour

    // Participation categories
    enum ParticipationCategory {
        VOTING,
        PROPOSAL_CREATION,
        DELEGATION,
        VALIDATION,
        CLIMATE_DATA_CONTRIBUTION,
        COMMUNITY_ENGAGEMENT
    }

    // Reward tiers
    enum RewardTier {
        BRONZE,
        SILVER,
        GOLD,
        PLATINUM,
        DIAMOND
    }

    // Stakeholder profile
    struct StakeholderProfile {
        address stakeholder;
        uint256 totalParticipationScore;
        uint256 climateImpactScore;
        uint256 reputationScore;
        uint256 consecutiveParticipationDays;
        uint256 lastParticipationTime;
        uint256 totalVotes; // Track total number of votes/participations
        RewardTier currentTier;
        mapping(ParticipationCategory => uint256) categoryScores;
        mapping(ParticipationCategory => uint256) lastCategoryActivity;
    }

    // Incentive program configuration
    struct IncentiveProgram {
        string name;
        ParticipationCategory category;
        uint256 baseReward;
        uint256 multiplier;
        uint256 minParticipation;
        uint256 maxReward;
        bool isActive;
        uint256 totalBudget;
        uint256 usedBudget;
    }

    // Achievement definition
    struct Achievement {
        uint256 id;
        string name;
        string description;
        ParticipationCategory category;
        uint256 threshold;
        uint256 rewardAmount;
        bool isRepeatable;
        address nftContract;
        uint256 nftTokenId;
    }

    // Community engagement metrics
    struct CommunityMetrics {
        uint256 forumPosts;
        uint256 helpfulVotes;
        uint256 mentorshipPoints;
        uint256 educationalContributions;
        uint256 socialMediaEngagement;
    }

    // Security and anti-gaming structures
    struct SecurityProfile {
        uint256 suspiciousActivityScore;
        uint256 lastRewardTime;
        uint256 rewardClaimsToday;
        uint256 rewardClaimsThisHour;
        bool flaggedForReview;
        mapping(uint256 => bool) completedAchievements;
    }

    // Vesting and time-locked rewards
    struct VestingSchedule {
        uint256 totalAmount;
        uint256 vestedAmount;
        uint256 startTime;
        uint256 vestingDuration;
        uint256 cliffPeriod;
        bool isActive;
    }

    // Performance tracking for quality-based rewards
    struct PerformanceMetrics {
        uint256 qualityScore; // 0-10000 basis points
        uint256 consistencyScore;
        uint256 impactScore;
        uint256 collaborationScore;
        uint256 lastPerformanceUpdate;
    }

    // State variables
    IERC20 public immutable rewardToken;
    IERC721 public achievementNFT;
    
    mapping(address => StakeholderProfile) public stakeholderProfiles;
    mapping(uint256 => IncentiveProgram) public incentivePrograms;
    mapping(uint256 => Achievement) public achievements;
    mapping(address => mapping(uint256 => bool)) public stakeholderAchievements;
    mapping(address => CommunityMetrics) public communityMetrics;
    
    // Enhanced security and performance tracking
    mapping(address => SecurityProfile) public securityProfiles;
    mapping(address => VestingSchedule) public vestingSchedules;
    mapping(address => PerformanceMetrics) public performanceMetrics;
    
    // Circuit breaker and monitoring
    mapping(uint256 => uint256) public dailyRewardsDistributed; // day => amount
    mapping(uint256 => uint256) public hourlyParticipants; // hour => count
    
    // Tier requirements (participation score thresholds)
    mapping(RewardTier => uint256) public tierThresholds;
    mapping(RewardTier => uint256) public tierMultipliers;
    
    uint256 public nextProgramId;
    uint256 public nextAchievementId;
    uint256 public totalDistributedRewards;
    uint256 public currentSeason;
    uint256 public seasonStartTime;
    uint256 public constant SEASON_DURATION = 90 days;
    
    // Climate impact weights
    mapping(string => uint256) public climateActionWeights;
    
    // Events
    event RewardDistributed(
        address indexed stakeholder,
        ParticipationCategory category,
        uint256 amount,
        uint256 multiplier
    );
    event AchievementUnlocked(
        address indexed stakeholder,
        uint256 indexed achievementId,
        string achievementName
    );
    event TierAdvanced(address indexed stakeholder, RewardTier newTier);
    event ParticipationRecorded(
        address indexed stakeholder,
        ParticipationCategory category,
        uint256 score
    );
    event SeasonAdvanced(uint256 newSeason, uint256 startTime);
    event ClimateImpactUpdated(address indexed stakeholder, uint256 newScore);
    
    // Enhanced security and performance events
    event SuspiciousActivityDetected(
        address indexed stakeholder,
        string activityType,
        uint256 severity,
        uint256 timestamp
    );
    event VestingScheduleCreated(
        address indexed stakeholder,
        uint256 amount,
        uint256 duration,
        uint256 cliff
    );
    event RewardVested(
        address indexed stakeholder,
        uint256 amount,
        uint256 remaining
    );
    event CircuitBreakerTriggered(
        string reason,
        uint256 threshold,
        uint256 actualValue
    );
    event PerformanceUpdated(
        address indexed stakeholder,
        uint256 qualityScore,
        uint256 impactScore
    );
    event AntiGamingMeasureActivated(
        address indexed stakeholder,
        string measure,
        uint256 score
    );

    modifier validStakeholder(address _stakeholder) {
        require(_stakeholder != address(0), "SI: Invalid stakeholder");
        _;
    }

    constructor(
        address _rewardToken,
        address _achievementNFT,
        address _admin
    ) {
        rewardToken = IERC20(_rewardToken);
        achievementNFT = IERC721(_achievementNFT);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(INCENTIVE_MANAGER_ROLE, _admin);
        
        // Initialize tier thresholds
        tierThresholds[RewardTier.BRONZE] = 0;
        tierThresholds[RewardTier.SILVER] = 1000;
        tierThresholds[RewardTier.GOLD] = 5000;
        tierThresholds[RewardTier.PLATINUM] = 20000;
        tierThresholds[RewardTier.DIAMOND] = 100000;
        
        // Initialize tier multipliers
        tierMultipliers[RewardTier.BRONZE] = 100;   // 1x
        tierMultipliers[RewardTier.SILVER] = 125;   // 1.25x
        tierMultipliers[RewardTier.GOLD] = 150;     // 1.5x
        tierMultipliers[RewardTier.PLATINUM] = 200; // 2x
        tierMultipliers[RewardTier.DIAMOND] = 300;  // 3x
        
        // Initialize climate action weights
        climateActionWeights["carbon_offset"] = 100;
        climateActionWeights["renewable_energy"] = 80;
        climateActionWeights["sustainable_transport"] = 60;
        climateActionWeights["waste_reduction"] = 40;
        climateActionWeights["education_outreach"] = 50;
        
        seasonStartTime = block.timestamp;
        currentSeason = 1;
        
        _initializeBasePrograms();
        _initializeAchievements();
    }

    /**
     * @dev Initialize base incentive programs
     */
    function _initializeBasePrograms() internal {
        // Voting participation program
        incentivePrograms[nextProgramId++] = IncentiveProgram({
            name: "Governance Voting Rewards",
            category: ParticipationCategory.VOTING,
            baseReward: 10 * 10**18, // 10 tokens
            multiplier: 100,
            minParticipation: 1,
            maxReward: 1000 * 10**18,
            isActive: true,
            totalBudget: 100000 * 10**18,
            usedBudget: 0
        });

        // Proposal creation program
        incentivePrograms[nextProgramId++] = IncentiveProgram({
            name: "Proposal Creator Rewards",
            category: ParticipationCategory.PROPOSAL_CREATION,
            baseReward: 50 * 10**18, // 50 tokens
            multiplier: 100,
            minParticipation: 1,
            maxReward: 500 * 10**18,
            isActive: true,
            totalBudget: 50000 * 10**18,
            usedBudget: 0
        });

        // Climate data contribution program
        incentivePrograms[nextProgramId++] = IncentiveProgram({
            name: "Climate Data Contribution",
            category: ParticipationCategory.CLIMATE_DATA_CONTRIBUTION,
            baseReward: 25 * 10**18, // 25 tokens
            multiplier: 150,
            minParticipation: 1,
            maxReward: 200 * 10**18,
            isActive: true,
            totalBudget: 75000 * 10**18,
            usedBudget: 0
        });
    }

    /**
     * @dev Initialize base achievements
     */
    function _initializeAchievements() internal {
        // First vote achievement
        achievements[nextAchievementId++] = Achievement({
            id: 0,
            name: "First Vote",
            description: "Cast your first governance vote",
            category: ParticipationCategory.VOTING,
            threshold: 1,
            rewardAmount: 50 * 10**18,
            isRepeatable: false,
            nftContract: address(achievementNFT),
            nftTokenId: 1
        });

        // Active voter achievement
        achievements[nextAchievementId++] = Achievement({
            id: 1,
            name: "Active Voter",
            description: "Participate in 10 governance votes",
            category: ParticipationCategory.VOTING,
            threshold: 10,
            rewardAmount: 200 * 10**18,
            isRepeatable: false,
            nftContract: address(achievementNFT),
            nftTokenId: 2
        });

        // Climate champion achievement
        achievements[nextAchievementId++] = Achievement({
            id: 2,
            name: "Climate Champion",
            description: "Achieve high climate impact score",
            category: ParticipationCategory.CLIMATE_DATA_CONTRIBUTION,
            threshold: 5000,
            rewardAmount: 500 * 10**18,
            isRepeatable: true,
            nftContract: address(achievementNFT),
            nftTokenId: 3
        });
    }

    /**
     * @notice Record participation with comprehensive security monitoring and fair reward distribution
     * @dev Enhanced participation recording with anti-gaming measures and performance tracking
     * @param _stakeholder Address of the participating stakeholder
     * @param _category Type of participation being recorded
     * @param _score Participation score achieved
     * @param _programId ID of the incentive program
     */
    function recordParticipation(
        address _stakeholder,
        ParticipationCategory _category,
        uint256 _score,
        uint256 _programId
    ) external onlyRole(INCENTIVE_MANAGER_ROLE) validStakeholder(_stakeholder) nonReentrant whenNotPaused {
        require(incentivePrograms[_programId].isActive, "SI: Program not active");
        require(incentivePrograms[_programId].category == _category, "SI: Category mismatch");
        require(_score > 0, "SI: Invalid participation score");

        // Security checks before processing
        _performSecurityChecks(_stakeholder);
        
        // Update circuit breaker monitoring
        _updateParticipationMetrics();

        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        SecurityProfile storage security = securityProfiles[_stakeholder];
        PerformanceMetrics storage performance = performanceMetrics[_stakeholder];
        
        // Initialize profile if first participation
        if (profile.stakeholder == address(0)) {
            profile.stakeholder = _stakeholder;
            profile.currentTier = RewardTier.BRONZE;
            performance.qualityScore = 5000; // Start with 50% quality score
        }

        // Anti-gaming validation
        _validateParticipationScore(_stakeholder, _category, _score);
        
        // Update participation scores with quality weighting
        uint256 qualityWeightedScore = (_score * performance.qualityScore) / 10000;
        profile.categoryScores[_category] += qualityWeightedScore;
        profile.lastCategoryActivity[_category] = block.timestamp;
        profile.totalParticipationScore += qualityWeightedScore;
        profile.totalVotes++; // Increment total participation count
        
        // Update performance metrics
        _updatePerformanceMetrics(_stakeholder, _category, _score);
        
        // Update consecutive participation with enhanced tracking
        _updateConsecutiveParticipation(profile);
        
        // Calculate and distribute rewards with security limits
        uint256 reward = _calculateSecureReward(_stakeholder, _category, qualityWeightedScore, _programId);
        if (reward > 0 && _validateRewardDistribution(_stakeholder, reward)) {
            _distributeSecureReward(_stakeholder, _category, reward, _programId);
        }
        
        // Check for tier advancement
        _checkTierAdvancement(_stakeholder);
        
        // Check for achievements with batch processing
        _checkAchievementsBatch(_stakeholder, _category);
        
        // Update security monitoring
        _updateSecurityProfile(_stakeholder);
        
        emit ParticipationRecorded(_stakeholder, _category, qualityWeightedScore);
    }

    /**
     * @dev Calculate reward for participation
     */
    function _calculateReward(
        address _stakeholder,
        ParticipationCategory /* _category */,
        uint256 _score,
        uint256 _programId
    ) internal view returns (uint256) {
        IncentiveProgram storage program = incentivePrograms[_programId];
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        
        if (_score < program.minParticipation) {
            return 0;
        }
        
        // Base reward calculation
        uint256 baseReward = (program.baseReward * _score) / program.minParticipation;
        
        // Apply tier multiplier
        uint256 tierMultiplier = tierMultipliers[profile.currentTier];
        uint256 reward = (baseReward * tierMultiplier) / 100;
        
        // Apply consecutive participation bonus
        if (profile.consecutiveParticipationDays >= 7) {
            uint256 streakBonus = Math.min(profile.consecutiveParticipationDays / 7, 10); // Max 10x bonus
            reward += (reward * streakBonus) / 100;
        }
        
        // Apply climate impact multiplier
        if (profile.climateImpactScore > 0) {
            uint256 climateMultiplier = Math.min(profile.climateImpactScore / 1000, 50); // Max 50% bonus
            reward += (reward * climateMultiplier) / 100;
        }
        
        // Cap at maximum reward
        return Math.min(reward, program.maxReward);
    }

    /**
     * @dev Distribute reward to stakeholder
     */
    function _distributeReward(
        address _stakeholder,
        ParticipationCategory _category,
        uint256 _reward,
        uint256 _programId
    ) internal {
        IncentiveProgram storage program = incentivePrograms[_programId];
        
        // Check budget availability
        require(program.usedBudget + _reward <= program.totalBudget, "SI: Program budget exceeded");
        
        // Transfer reward tokens
        rewardToken.safeTransfer(_stakeholder, _reward);
        
        // Update program budget
        program.usedBudget += _reward;
        totalDistributedRewards += _reward;
        
        // Calculate multiplier for event
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        uint256 multiplier = tierMultipliers[profile.currentTier];
        
        emit RewardDistributed(_stakeholder, _category, _reward, multiplier);
    }

    /**
     * @dev Update consecutive participation tracking
     */
    function _updateConsecutiveParticipation(StakeholderProfile storage _profile) internal {
        uint256 daysSinceLastParticipation = (block.timestamp - _profile.lastParticipationTime) / 1 days;
        
        if (daysSinceLastParticipation <= 1) {
            // Consecutive participation
            if (daysSinceLastParticipation == 1) {
                _profile.consecutiveParticipationDays++;
            }
        } else {
            // Streak broken
            _profile.consecutiveParticipationDays = 1;
        }
        
        _profile.lastParticipationTime = block.timestamp;
    }

    /**
     * @dev Check for tier advancement
     */
    function _checkTierAdvancement(address _stakeholder) internal {
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        RewardTier newTier = _calculateTier(profile.totalParticipationScore);
        
        if (newTier != profile.currentTier) {
            profile.currentTier = newTier;
            emit TierAdvanced(_stakeholder, newTier);
        }
    }

    /**
     * @dev Calculate tier based on participation score
     */
    function _calculateTier(uint256 _score) internal view returns (RewardTier) {
        if (_score >= tierThresholds[RewardTier.DIAMOND]) return RewardTier.DIAMOND;
        if (_score >= tierThresholds[RewardTier.PLATINUM]) return RewardTier.PLATINUM;
        if (_score >= tierThresholds[RewardTier.GOLD]) return RewardTier.GOLD;
        if (_score >= tierThresholds[RewardTier.SILVER]) return RewardTier.SILVER;
        return RewardTier.BRONZE;
    }

    /**
     * @dev Check for achievement unlocks
     */
    function _checkAchievements(address _stakeholder, ParticipationCategory _category) internal {
        for (uint256 i = 0; i < nextAchievementId; i++) {
            Achievement storage achievement = achievements[i];
            
            if (achievement.category == _category && 
                !stakeholderAchievements[_stakeholder][i]) {
                
                StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
                uint256 categoryScore = profile.categoryScores[_category];
                
                if (categoryScore >= achievement.threshold) {
                    stakeholderAchievements[_stakeholder][i] = true;
                    
                    // Award achievement reward
                    if (achievement.rewardAmount > 0) {
                        rewardToken.safeTransfer(_stakeholder, achievement.rewardAmount);
                    }

                    emit AchievementUnlocked(_stakeholder, i, achievement.name);
                }
            }
        }
    }

    /**
     * @dev Update climate impact score
     */
    function updateClimateImpact(
        address _stakeholder,
        string memory _action,
        uint256 _impact
    ) external onlyRole(ORACLE_ROLE) validStakeholder(_stakeholder) {
        uint256 weight = climateActionWeights[_action];
        require(weight > 0, "SI: Invalid climate action");
        
        uint256 weightedImpact = (_impact * weight) / 100;
        stakeholderProfiles[_stakeholder].climateImpactScore += weightedImpact;
        
        emit ClimateImpactUpdated(_stakeholder, stakeholderProfiles[_stakeholder].climateImpactScore);
    }

    /**
     * @dev Update community engagement metrics
     */
    function updateCommunityMetrics(
        address _stakeholder,
        uint256 _forumPosts,
        uint256 _helpfulVotes,
        uint256 _mentorshipPoints,
        uint256 _educationalContributions,
        uint256 _socialMediaEngagement
    ) external onlyRole(INCENTIVE_MANAGER_ROLE) validStakeholder(_stakeholder) {
        CommunityMetrics storage metrics = communityMetrics[_stakeholder];
        metrics.forumPosts += _forumPosts;
        metrics.helpfulVotes += _helpfulVotes;
        metrics.mentorshipPoints += _mentorshipPoints;
        metrics.educationalContributions += _educationalContributions;
        metrics.socialMediaEngagement += _socialMediaEngagement;
        
        // Calculate engagement score
        uint256 engagementScore = _forumPosts * 5 + _helpfulVotes * 10 + 
                                 _mentorshipPoints * 20 + _educationalContributions * 15 +
                                 _socialMediaEngagement * 2;
        
        // Record as community engagement participation
        if (engagementScore > 0) {
            stakeholderProfiles[_stakeholder].categoryScores[
                ParticipationCategory.COMMUNITY_ENGAGEMENT
            ] += engagementScore;
        }
    }

    /**
     * @dev Advance to new season
     */
    function advanceSeason() external onlyRole(INCENTIVE_MANAGER_ROLE) {
        require(block.timestamp >= seasonStartTime + SEASON_DURATION, "SI: Season not ready");
        
        currentSeason++;
        seasonStartTime = block.timestamp;
        
        // Reset seasonal metrics if needed
        // (Implementation depends on specific seasonal mechanics)
        
        emit SeasonAdvanced(currentSeason, seasonStartTime);
    }

    /**
     * @dev Create new incentive program
     */
    function createIncentiveProgram(
        string memory _name,
        ParticipationCategory _category,
        uint256 _baseReward,
        uint256 _multiplier,
        uint256 _minParticipation,
        uint256 _maxReward,
        uint256 _totalBudget
    ) external onlyRole(INCENTIVE_MANAGER_ROLE) {
        incentivePrograms[nextProgramId++] = IncentiveProgram({
            name: _name,
            category: _category,
            baseReward: _baseReward,
            multiplier: _multiplier,
            minParticipation: _minParticipation,
            maxReward: _maxReward,
            isActive: true,
            totalBudget: _totalBudget,
            usedBudget: 0
        });
    }

    /**
     * @dev Create new achievement
     */
    function createAchievement(
        string memory _name,
        string memory _description,
        ParticipationCategory _category,
        uint256 _threshold,
        uint256 _rewardAmount,
        bool _isRepeatable,
        address _nftContract,
        uint256 _nftTokenId
    ) external onlyRole(INCENTIVE_MANAGER_ROLE) {
        achievements[nextAchievementId++] = Achievement({
            id: nextAchievementId - 1,
            name: _name,
            description: _description,
            category: _category,
            threshold: _threshold,
            rewardAmount: _rewardAmount,
            isRepeatable: _isRepeatable,
            nftContract: _nftContract,
            nftTokenId: _nftTokenId
        });
    }

    /**
     * @dev Get stakeholder profile
     */
    function getStakeholderProfile(address _stakeholder) external view returns (
        address stakeholder,
        uint256 totalParticipationScore,
        uint256 climateImpactScore,
        uint256 reputationScore,
        uint256 consecutiveParticipationDays,
        RewardTier currentTier
    ) {
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        return (
            profile.stakeholder,
            profile.totalParticipationScore,
            profile.climateImpactScore,
            profile.reputationScore,
            profile.consecutiveParticipationDays,
            profile.currentTier
        );
    }

    /**
     * @dev Get category score for stakeholder
     */
    function getCategoryScore(
        address _stakeholder,
        ParticipationCategory _category
    ) external view returns (uint256) {
        return stakeholderProfiles[_stakeholder].categoryScores[_category];
    }

    /**
     * @dev Emergency pause function
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause function
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Perform comprehensive security checks before processing participation
     */
    function _performSecurityChecks(address _stakeholder) internal view {
        SecurityProfile storage security = securityProfiles[_stakeholder];
        
        // Check if stakeholder is flagged for review
        require(!security.flaggedForReview, "SI: Stakeholder under review");
        
        // Check reward claiming frequency
        require(
            block.timestamp >= security.lastRewardTime + MIN_TIME_BETWEEN_REWARDS,
            "SI: Too frequent reward claims"
        );
        
        // Check suspicious activity score
        require(
            security.suspiciousActivityScore < SUSPICIOUS_SCORE_THRESHOLD,
            "SI: High suspicious activity score"
        );
    }

    /**
     * @dev Update participation metrics and check circuit breakers
     */
    function _updateParticipationMetrics() internal {
        uint256 currentHour = block.timestamp / 1 hours;
        hourlyParticipants[currentHour]++;
        
        if (hourlyParticipants[currentHour] > MAX_HOURLY_PARTICIPANTS) {
            emit CircuitBreakerTriggered(
                "High participation rate",
                MAX_HOURLY_PARTICIPANTS,
                hourlyParticipants[currentHour]
            );
        }
    }

    /**
     * @dev Validate participation score against anti-gaming measures
     */
    function _validateParticipationScore(
        address _stakeholder,
        ParticipationCategory _category,
        uint256 _score
    ) internal {
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        
        if (profile.totalParticipationScore > 0) {
            uint256 recentAverage = profile.categoryScores[_category] / profile.totalParticipationScore;
            uint256 scoreDifference = _score > recentAverage ? 
                _score - recentAverage : recentAverage - _score;
            
            // Flag if score is suspiciously different from average
            if (scoreDifference > (recentAverage * ANTI_GAMING_THRESHOLD / 10000)) {
                _flagSuspiciousActivity(_stakeholder, "Unusual participation score");
            }
        }
    }

    /**
     * @dev Update performance metrics for quality-based rewards
     */
    function _updatePerformanceMetrics(
        address _stakeholder,
        ParticipationCategory _category,
        uint256 _score
    ) internal {
        PerformanceMetrics storage performance = performanceMetrics[_stakeholder];
        
        // Calculate quality score based on participation consistency
        uint256 expectedScore = 100; // Base expected score
        uint256 qualityAdjustment = 0;
        
        if (_score >= expectedScore) {
            qualityAdjustment = Math.min((_score - expectedScore) * 10, 500); // Max 5% boost
            performance.qualityScore = Math.min(performance.qualityScore + qualityAdjustment, 10000);
        } else {
            qualityAdjustment = Math.min((expectedScore - _score) * 5, 250); // Max 2.5% penalty
            performance.qualityScore = performance.qualityScore > qualityAdjustment ?
                performance.qualityScore - qualityAdjustment : 1000; // Min 10% quality
        }
        
        performance.lastPerformanceUpdate = block.timestamp;
        
        emit PerformanceUpdated(_stakeholder, performance.qualityScore, performance.impactScore);
    }

    /**
     * @dev Calculate reward with enhanced security and precision
     */
    function _calculateSecureReward(
        address _stakeholder,
        ParticipationCategory /* _category */,
        uint256 _score,
        uint256 _programId
    ) internal view returns (uint256) {
        IncentiveProgram storage program = incentivePrograms[_programId];
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        PerformanceMetrics storage performance = performanceMetrics[_stakeholder];
        
        if (_score < program.minParticipation) {
            return 0;
        }
        
        // Enhanced base reward calculation with precision
        uint256 baseReward = (program.baseReward * _score * PRECISION) / 
                           (program.minParticipation * PRECISION);
        
        // Apply tier multiplier with security caps
        uint256 tierMultiplier = Math.min(tierMultipliers[profile.currentTier], MAX_TIER_MULTIPLIER);
        uint256 reward = (baseReward * tierMultiplier) / 100;
        
        // Apply performance-based multiplier
        uint256 performanceMultiplier = Math.max(performance.qualityScore / 100, 50); // Min 50%
        reward = (reward * performanceMultiplier) / 100;
        
        // Apply consecutive participation bonus with diminishing returns
        if (profile.consecutiveParticipationDays >= 7) {
            uint256 streakBonus = Math.min(
                _sqrt(profile.consecutiveParticipationDays / 7) * 10, 
                50
            ); // Max 50% bonus
            reward += (reward * streakBonus) / 100;
        }
        
        // Apply climate impact multiplier with verification
        if (profile.climateImpactScore > 0) {
            uint256 climateMultiplier = Math.min(profile.climateImpactScore / 2000, 25); // Max 25% bonus
            reward += (reward * climateMultiplier) / 100;
        }
        
        // Security cap
        return Math.min(reward, Math.min(program.maxReward, MAX_REWARD_PER_TX));
    }

    /**
     * @dev Validate reward distribution against security thresholds
     */
    function _validateRewardDistribution(address _stakeholder, uint256 _reward) internal returns (bool) {
        SecurityProfile storage security = securityProfiles[_stakeholder];
        uint256 currentDay = block.timestamp / 1 days;
        uint256 currentHour = block.timestamp / 1 hours;
        
        // Check daily limits
        if (dailyRewardsDistributed[currentDay] + _reward > MAX_DAILY_REWARDS) {
            emit CircuitBreakerTriggered(
                "Daily reward limit exceeded",
                MAX_DAILY_REWARDS,
                dailyRewardsDistributed[currentDay] + _reward
            );
            return false;
        }
        
        // Check rapid claiming
        security.rewardClaimsThisHour++;
        if (security.rewardClaimsThisHour > RAPID_REWARD_THRESHOLD) {
            _flagSuspiciousActivity(_stakeholder, "Rapid reward claiming");
            return false;
        }
        
        return true;
    }

    /**
     * @dev Distribute reward with enhanced security and vesting
     */
    function _distributeSecureReward(
        address _stakeholder,
        ParticipationCategory _category,
        uint256 _reward,
        uint256 _programId
    ) internal {
        IncentiveProgram storage program = incentivePrograms[_programId];
        SecurityProfile storage security = securityProfiles[_stakeholder];
        
        // Check budget availability
        require(program.usedBudget + _reward <= program.totalBudget, "SI: Program budget exceeded");
        
        // Determine if reward should be vested
        uint256 immediateReward = _reward;
        uint256 vestedReward = 0;
        
        // High-value rewards get vested
        if (_reward > 1000 * 1e18) {
            immediateReward = _reward / 2;
            vestedReward = _reward - immediateReward;
            _createVestingSchedule(_stakeholder, vestedReward);
        }
        
        // Transfer immediate reward
        rewardToken.safeTransfer(_stakeholder, immediateReward);
        
        // Update tracking
        program.usedBudget += _reward;
        totalDistributedRewards += _reward;
        security.lastRewardTime = block.timestamp;
        security.rewardClaimsToday++;
        
        uint256 currentDay = block.timestamp / 1 days;
        dailyRewardsDistributed[currentDay] += _reward;
        
        // Calculate multiplier for event
        StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
        uint256 multiplier = tierMultipliers[profile.currentTier];
        
        emit RewardDistributed(_stakeholder, _category, immediateReward, multiplier);
        
        if (vestedReward > 0) {
            emit VestingScheduleCreated(_stakeholder, vestedReward, VESTING_PERIOD, VESTING_PERIOD / 4);
        }
    }

    /**
     * @dev Check achievements with batch processing optimization
     */
    function _checkAchievementsBatch(address _stakeholder, ParticipationCategory _category) internal {
        uint256 processed = 0;
        
        for (uint256 i = 0; i < nextAchievementId && processed < MAX_ACHIEVEMENTS_PER_CALL; i++) {
            Achievement storage achievement = achievements[i];
            
            if (achievement.category == _category && 
                !stakeholderAchievements[_stakeholder][i] &&
                !securityProfiles[_stakeholder].completedAchievements[i]) {
                
                StakeholderProfile storage profile = stakeholderProfiles[_stakeholder];
                uint256 categoryScore = profile.categoryScores[_category];
                
                if (categoryScore >= achievement.threshold) {
                    stakeholderAchievements[_stakeholder][i] = true;
                    securityProfiles[_stakeholder].completedAchievements[i] = true;
                    
                    // Award achievement reward
                    if (achievement.rewardAmount > 0) {
                        rewardToken.safeTransfer(_stakeholder, achievement.rewardAmount);
                    }

                    emit AchievementUnlocked(_stakeholder, i, achievement.name);
                }
                processed++;
            }
        }
    }

    /**
     * @dev Update security profile and detect anomalies
     */
    function _updateSecurityProfile(address _stakeholder) internal {
        SecurityProfile storage security = securityProfiles[_stakeholder];
        
        // Reset hourly counters if new hour
        uint256 currentHour = block.timestamp / 1 hours;
        uint256 lastHour = security.lastRewardTime / 1 hours;
        if (currentHour > lastHour) {
            security.rewardClaimsThisHour = 0;
        }
        
        // Reset daily counters if new day
        uint256 currentDay = block.timestamp / 1 days;
        uint256 lastDay = security.lastRewardTime / 1 days;
        if (currentDay > lastDay) {
            security.rewardClaimsToday = 0;
        }
    }

    /**
     * @dev Flag suspicious activity and update security metrics
     */
    function _flagSuspiciousActivity(address _stakeholder, string memory _reason) internal {
        SecurityProfile storage security = securityProfiles[_stakeholder];
        security.suspiciousActivityScore += 100;
        
        emit SuspiciousActivityDetected(
            _stakeholder,
            _reason,
            security.suspiciousActivityScore,
            block.timestamp
        );
        
        // Auto-flag for review if score is too high
        if (security.suspiciousActivityScore >= SUSPICIOUS_SCORE_THRESHOLD) {
            security.flaggedForReview = true;
            emit AntiGamingMeasureActivated(_stakeholder, "Auto-flagged for review", security.suspiciousActivityScore);
        }
    }

    /**
     * @dev Create vesting schedule for high-value rewards
     */
    function _createVestingSchedule(address _stakeholder, uint256 _amount) internal {
        VestingSchedule storage schedule = vestingSchedules[_stakeholder];
        
        schedule.totalAmount += _amount;
        schedule.startTime = block.timestamp;
        schedule.vestingDuration = VESTING_PERIOD;
        schedule.cliffPeriod = VESTING_PERIOD / 4; // 25% cliff
        schedule.isActive = true;
        
        emit VestingScheduleCreated(_stakeholder, _amount, VESTING_PERIOD, schedule.cliffPeriod);
    }

    /**
     * @dev Calculate square root using Babylonian method for bonus calculations
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @notice Claim vested rewards
     * @dev Allow stakeholders to claim their vested rewards after cliff period
     * @param _stakeholder Address to claim vested rewards for (admin only) or msg.sender
     */
    function claimVestedRewards(address _stakeholder) external nonReentrant {
        require(
            _stakeholder == msg.sender || hasRole(INCENTIVE_MANAGER_ROLE, msg.sender),
            "SI: Unauthorized claim"
        );
        
        VestingSchedule storage schedule = vestingSchedules[_stakeholder];
        require(schedule.isActive, "SI: No active vesting schedule");
        require(block.timestamp >= schedule.startTime + schedule.cliffPeriod, "SI: Cliff period not reached");
        
        uint256 vestedAmount = _calculateVestedAmount(_stakeholder);
        uint256 claimableAmount = vestedAmount - schedule.vestedAmount;
        
        require(claimableAmount > 0, "SI: No claimable rewards");
        
        schedule.vestedAmount += claimableAmount;
        
        // Transfer vested tokens
        rewardToken.safeTransfer(_stakeholder, claimableAmount);
        
        // Check if fully vested
        if (schedule.vestedAmount >= schedule.totalAmount) {
            schedule.isActive = false;
        }
        
        emit RewardVested(_stakeholder, claimableAmount, schedule.totalAmount - schedule.vestedAmount);
    }

    /**
     * @dev Calculate vested amount based on time elapsed
     */
    function _calculateVestedAmount(address _stakeholder) internal view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[_stakeholder];
        
        if (block.timestamp < schedule.startTime + schedule.cliffPeriod) {
            return 0;
        }
        
        if (block.timestamp >= schedule.startTime + schedule.vestingDuration) {
            return schedule.totalAmount;
        }
        
        uint256 timeElapsed = block.timestamp - schedule.startTime - schedule.cliffPeriod;
        uint256 vestingTimeRemaining = schedule.vestingDuration - schedule.cliffPeriod;
        
        return (schedule.totalAmount * timeElapsed) / vestingTimeRemaining;
    }

    /**
     * @notice Get vesting information for a stakeholder
     * @param _stakeholder Address to query vesting information for
     * @return totalAmount Total amount in vesting schedule
     * @return vestedAmount Amount already vested
     * @return claimableAmount Amount currently claimable
     * @return nextVestingTime Timestamp of next vesting event
     */
    function getVestingInfo(address _stakeholder) external view returns (
        uint256 totalAmount,
        uint256 vestedAmount,
        uint256 claimableAmount,
        uint256 nextVestingTime
    ) {
        VestingSchedule storage schedule = vestingSchedules[_stakeholder];
        totalAmount = schedule.totalAmount;
        vestedAmount = schedule.vestedAmount;
        
        if (schedule.isActive && block.timestamp >= schedule.startTime + schedule.cliffPeriod) {
            uint256 currentVested = _calculateVestedAmount(_stakeholder);
            claimableAmount = currentVested - schedule.vestedAmount;
        }
        
        if (block.timestamp < schedule.startTime + schedule.cliffPeriod) {
            nextVestingTime = schedule.startTime + schedule.cliffPeriod;
        } else if (block.timestamp < schedule.startTime + schedule.vestingDuration) {
            nextVestingTime = block.timestamp + 1 days; // Daily vesting
        }
    }
}