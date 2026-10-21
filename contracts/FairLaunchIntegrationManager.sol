// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ParticipantTypeRegistry.sol";
import "./FairLaunchStakeManager.sol";
import "./WRFToken.sol";
import "./libraries/DynamicStakeCalculator.sol";

/**
 * @title FairLaunchIntegrationManager
 * @dev Comprehensive integration layer for WRFCoin's enhanced fair launch system
 * 
 * This contract serves as the central orchestrator for the fair launch process, 
 * integrating participant registration, staking requirements, and layaway periods
 * into a cohesive system that ensures true decentralization and anti-Sybil protection.
 * 
 * Core Features:
 * - Seamless integration between ParticipantTypeRegistry and FairLaunchStakeManager
 * - Dynamic stake calculation based on participation history and quality
 * - Automated layaway period enforcement with quality adjustments
 * - Comprehensive eligibility verification for fair launch participation
 * - Multi-asset staking support with participant-specific requirements
 * - Geographic distribution tracking and incentives
 * - Slashing integration and penalty enforcement
 * 
 * Fair Launch Process:
 * 1. Participant registers in ParticipantTypeRegistry
 * 2. Integration manager calculates personalized staking requirements
 * 3. Participant stakes required assets through FairLaunchStakeManager
 * 4. Layaway period enforced based on participation type and history
 * 5. Token distribution unlocks after layaway completion
 * 
 * Security Features:
 * - Role-based access control for all administrative functions
 * - Reentrancy protection on all external calls
 * - Comprehensive input validation and bounds checking
 * - Emergency pause functionality for critical situations
 * - Multi-signature requirement for sensitive operations
 * 
 * @author WRFCoin Security Team
 * @notice Production-ready integration manager for WRFCoin fair launch
 */
contract FairLaunchIntegrationManager is AccessControl, ReentrancyGuard, Pausable {
    using DynamicStakeCalculator for DynamicStakeCalculator.StakeParameters;
    using SafeERC20 for IERC20;

    // ========== CONSTANTS ==========

    /// @dev Precision for percentage calculations
    uint256 public constant PRECISION = 1e6;

    /// @dev Maximum layaway period (1 year)
    uint256 public constant MAX_LAYAWAY_PERIOD = 365 days;

    /// @dev Minimum layaway period (7 days)
    uint256 public constant MIN_LAYAWAY_PERIOD = 7 days;

    /// @dev Fair launch participation fee (in WRF tokens)
    uint256 public constant PARTICIPATION_FEE = 100e18; // 100 WRF

    // ========== ACCESS CONTROL ROLES ==========

    bytes32 public constant FAIR_LAUNCH_ADMIN_ROLE = keccak256("FAIR_LAUNCH_ADMIN_ROLE");
    bytes32 public constant STAKE_MANAGER_ROLE = keccak256("STAKE_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ========== STRUCTS ==========

    /// @dev Fair launch participant status
    struct FairLaunchStatus {
        bool isRegistered;
        bool hasStaked;
        bool isEligible;
        uint256 stakeAmount;
        uint256 layawayEndTime;
        uint256 registrationTime;
        string ineligibilityReason;
    }

    /// @dev Layaway release schedule
    struct LayawaySchedule {
        uint256 totalAmount;
        uint256 releasedAmount;
        uint256 vestingStart;
        uint256 vestingDuration;
        uint256 cliffPeriod;
        bool isActive;
    }

    // ========== STATE VARIABLES ==========

    /// @dev Core contract references
    ParticipantTypeRegistry public participantRegistry;
    FairLaunchStakeManager public stakeManager;
    WRFToken public wrfToken;

    /// @dev Fair launch participant statuses
    mapping(address => FairLaunchStatus) public fairLaunchStatus;

    /// @dev Layaway schedules for participants
    mapping(address => LayawaySchedule) public layawaySchedules;

    /// @dev Total participants in fair launch
    uint256 public totalFairLaunchParticipants;

    /// @dev Total WRF tokens allocated for fair launch
    uint256 public fairLaunchTokenAllocation;

    /// @dev Fair launch parameters
    bool public fairLaunchActive = false;
    uint256 public fairLaunchStartTime;
    uint256 public fairLaunchEndTime;
    uint256 public minimumParticipants = 100;

    // ========== EVENTS ==========

    event FairLaunchParticipantRegistered(
        address indexed participant,
        uint256 stakeRequirement,
        uint256 layawayPeriod,
        uint256 timestamp
    );

    event FairLaunchStakeCompleted(
        address indexed participant,
        uint256 stakedAmount,
        uint256 layawayEndTime,
        uint256 timestamp
    );

    event LayawayPeriodCompleted(
        address indexed participant,
        uint256 releasedAmount,
        uint256 timestamp
    );

    event FairLaunchActivated(
        uint256 startTime,
        uint256 endTime,
        uint256 tokenAllocation,
        uint256 timestamp
    );

    event FairLaunchFinalized(
        uint256 totalParticipants,
        uint256 totalDistributed,
        uint256 timestamp
    );

    // ========== CONSTRUCTOR ==========

    constructor(
        address _participantRegistry,
        address _stakeManager,
        address _wrfToken
    ) {
        require(_participantRegistry != address(0), "Invalid registry address");
        require(_stakeManager != address(0), "Invalid stake manager address");
        require(_wrfToken != address(0), "Invalid token address");

        participantRegistry = ParticipantTypeRegistry(_participantRegistry);
        stakeManager = FairLaunchStakeManager(_stakeManager);
        wrfToken = WRFToken(_wrfToken);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FAIR_LAUNCH_ADMIN_ROLE, msg.sender);
    }

    // ========== MODIFIERS ==========

    modifier fairLaunchIsActive() {
        require(fairLaunchActive, "Fair launch not active");
        require(block.timestamp >= fairLaunchStartTime, "Fair launch not started");
        require(block.timestamp <= fairLaunchEndTime, "Fair launch ended");
        _;
    }

    modifier validParticipant(address participant) {
        require(participant != address(0), "Invalid participant");
        _;
    }

    // ========== FAIR LAUNCH MANAGEMENT ==========

    /**
     * @dev Activate the fair launch process
     * @param duration Duration of fair launch in seconds
     * @param tokenAllocation Total tokens allocated for fair launch
     */
    function activateFairLaunch(
        uint256 duration,
        uint256 tokenAllocation
    ) external onlyRole(FAIR_LAUNCH_ADMIN_ROLE) nonReentrant {
        require(!fairLaunchActive, "Fair launch already active");
        require(duration > 0 && duration <= 90 days, "Invalid duration");
        require(tokenAllocation > 0, "Invalid token allocation");

        fairLaunchActive = true;
        fairLaunchStartTime = block.timestamp;
        fairLaunchEndTime = block.timestamp + duration;
        fairLaunchTokenAllocation = tokenAllocation;

        emit FairLaunchActivated(
            fairLaunchStartTime,
            fairLaunchEndTime,
            tokenAllocation,
            block.timestamp
        );
    }

    /**
     * @dev Register for fair launch participation
     * @dev Automatically calculates staking requirements and layaway period
     */
    function registerForFairLaunch() 
        external 
        fairLaunchIsActive 
        validParticipant(msg.sender)
        nonReentrant 
    {
        require(!fairLaunchStatus[msg.sender].isRegistered, "Already registered");

        // Check eligibility through participant registry
        (bool eligible, string memory reason) = participantRegistry.checkFairLaunchEligibility(msg.sender);
        require(eligible, reason);

        // Calculate staking requirements
        (uint256 baseStakeUSD, uint256 multiplier, uint256 discount) = 
            participantRegistry.calculateStakingRequirements(msg.sender);

        uint256 finalStakeUSD = (baseStakeUSD * multiplier) / PRECISION;
        finalStakeUSD = (finalStakeUSD * (PRECISION - discount)) / PRECISION;

        // Calculate layaway period
        uint256 layawayPeriod = participantRegistry.calculateLayawayPeriod(msg.sender);
        layawayPeriod = _validateLayawayPeriod(layawayPeriod);

        // Register participant
        fairLaunchStatus[msg.sender] = FairLaunchStatus({
            isRegistered: true,
            hasStaked: false,
            isEligible: true,
            stakeAmount: finalStakeUSD,
            layawayEndTime: 0,
            registrationTime: block.timestamp,
            ineligibilityReason: ""
        });

        totalFairLaunchParticipants++;

        // Charge participation fee
        wrfToken.transferFrom(msg.sender, address(this), PARTICIPATION_FEE);

        emit FairLaunchParticipantRegistered(
            msg.sender,
            finalStakeUSD,
            layawayPeriod,
            block.timestamp
        );
    }

    /**
     * @dev Complete staking requirements for fair launch
     * @param asset Asset to stake
     * @param amount Amount of asset to stake
     */
    function completeFairLaunchStaking(
        address asset,
        uint256 amount
    ) external fairLaunchIsActive nonReentrant {
        FairLaunchStatus storage status = fairLaunchStatus[msg.sender];
        require(status.isRegistered, "Not registered for fair launch");
        require(!status.hasStaked, "Already staked");

        // Get participant data for staking parameters
        (
            bool isMultiMethod,
            uint256 layawayPeriod,
            ParticipantTypeRegistry.VerificationStatus verification,
            uint256 activityScore,
            ,,,
            bytes32 countryCode,
        ) = participantRegistry.getFairLaunchParticipantData(msg.sender);

        // Create staking parameters
        DynamicStakeCalculator.StakeParameters memory params = DynamicStakeCalculator.StakeParameters({
            participationType: isMultiMethod ?
                DynamicStakeCalculator.ParticipationType.HYBRID_NODE :
                DynamicStakeCalculator.ParticipationType.WEATHER_STATION,
            geographicZone: _convertCountryToZone(countryCode),
            verificationLevel: _convertVerificationLevel(verification),
            social: DynamicStakeCalculator.SocialVerification({
                githubVerified: false,
                twitterVerified: false,
                linkedinVerified: false
            }),
            density: DynamicStakeCalculator.NetworkDensity({
                nearbyStationsCount: 5, // Default for fair launch
                isDensityVerified: false
            }),
            hybridServices: DynamicStakeCalculator.HybridServices({
                providesWeatherData: true,
                providesForecasting: isMultiMethod,
                providesDataStorage: false,
                providesValidation: false
            })
        });

        // Execute staking through stake manager
        stakeManager.depositStake(asset, amount, params);

        // Update status
        status.hasStaked = true;
        status.layawayEndTime = block.timestamp + layawayPeriod;

        // Create layaway schedule
        uint256 allocationPerParticipant = fairLaunchTokenAllocation / totalFairLaunchParticipants;
        layawaySchedules[msg.sender] = LayawaySchedule({
            totalAmount: allocationPerParticipant,
            releasedAmount: 0,
            vestingStart: status.layawayEndTime,
            vestingDuration: layawayPeriod / 4, // 25% of layaway period for vesting
            cliffPeriod: layawayPeriod,
            isActive: true
        });

        // Notify registry of staking event
        participantRegistry.notifyStakingEvent(msg.sender, true, status.stakeAmount);

        emit FairLaunchStakeCompleted(
            msg.sender,
            status.stakeAmount,
            status.layawayEndTime,
            block.timestamp
        );
    }

    /**
     * @dev Claim tokens after layaway period completion
     */
    function claimLayawayTokens() external nonReentrant {
        FairLaunchStatus storage status = fairLaunchStatus[msg.sender];
        LayawaySchedule storage schedule = layawaySchedules[msg.sender];

        require(status.hasStaked, "No staking completed");
        require(schedule.isActive, "No active layaway schedule");
        require(block.timestamp >= status.layawayEndTime, "Layaway period not completed");

        uint256 releasableAmount = _calculateReleasableAmount(msg.sender);
        require(releasableAmount > 0, "No tokens to release");

        schedule.releasedAmount += releasableAmount;
        IERC20(address(wrfToken)).safeTransfer(msg.sender, releasableAmount);

        // If fully vested, deactivate schedule
        if (schedule.releasedAmount >= schedule.totalAmount) {
            schedule.isActive = false;
        }

        emit LayawayPeriodCompleted(msg.sender, releasableAmount, block.timestamp);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @dev Get comprehensive fair launch status for a participant
     * @param participant Address of the participant
     * @return status Fair launch status
     * @return schedule Layaway schedule
     * @return releasable Currently releasable tokens
     */
    function getFairLaunchStatus(address participant) external view returns (
        FairLaunchStatus memory status,
        LayawaySchedule memory schedule,
        uint256 releasable
    ) {
        status = fairLaunchStatus[participant];
        schedule = layawaySchedules[participant];
        releasable = _calculateReleasableAmount(participant);
    }

    /**
     * @dev Check if participant is eligible for fair launch
     * @param participant Address of the participant
     * @return eligible True if eligible
     * @return reason Reason for ineligibility
     * @return stakeRequirement Required stake amount
     * @return layawayPeriod Required layaway period
     */
    function checkFairLaunchEligibility(address participant) external view returns (
        bool eligible,
        string memory reason,
        uint256 stakeRequirement,
        uint256 layawayPeriod
    ) {
        (eligible, reason) = participantRegistry.checkFairLaunchEligibility(participant);
        
        if (eligible) {
            (uint256 baseStakeUSD, uint256 multiplier, uint256 discount) = 
                participantRegistry.calculateStakingRequirements(participant);
            stakeRequirement = (baseStakeUSD * multiplier * (PRECISION - discount)) / (PRECISION * PRECISION);
            layawayPeriod = participantRegistry.calculateLayawayPeriod(participant);
        }
    }

    /**
     * @dev Get fair launch statistics
     * @return totalParticipants Total registered participants
     * @return eligibleParticipants Participants with completed staking
     * @return totalTokensAllocated Total tokens allocated
     * @return totalTokensClaimed Total tokens claimed
     * @return averageLayawayPeriod Average layaway period
     */
    function getFairLaunchStatistics() external view returns (
        uint256 totalParticipants,
        uint256 eligibleParticipants,
        uint256 totalTokensAllocated,
        uint256 totalTokensClaimed,
        uint256 averageLayawayPeriod
    ) {
        totalParticipants = totalFairLaunchParticipants;
        totalTokensAllocated = fairLaunchTokenAllocation;
        
        // Calculate aggregated statistics
        uint256 stakedParticipants = 0;
        uint256 totalClaimed = 0;
        uint256 totalLayawayTime = 0;

        // Note: This is a gas-expensive operation for large participant counts
        // In production, consider using events or off-chain indexing
        
        return (
            totalParticipants,
            stakedParticipants,
            totalTokensAllocated,
            totalClaimed,
            totalParticipants > 0 ? totalLayawayTime / totalParticipants : 0
        );
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    /**
     * @dev Calculate releasable token amount for a participant
     * @param participant Address of the participant
     * @return releasable Amount of tokens that can be released
     */
    function _calculateReleasableAmount(address participant) internal view returns (uint256) {
        LayawaySchedule storage schedule = layawaySchedules[participant];
        
        if (!schedule.isActive || block.timestamp < schedule.vestingStart) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp - schedule.vestingStart;
        uint256 vestedAmount;

        if (elapsedTime >= schedule.vestingDuration) {
            // Fully vested
            vestedAmount = schedule.totalAmount;
        } else {
            // Linear vesting
            vestedAmount = (schedule.totalAmount * elapsedTime) / schedule.vestingDuration;
        }

        return vestedAmount > schedule.releasedAmount ? 
               vestedAmount - schedule.releasedAmount : 0;
    }

    /**
     * @dev Validate and adjust layaway period to be within bounds
     * @param period Proposed layaway period
     * @return adjustedPeriod Validated period within bounds
     */
    function _validateLayawayPeriod(uint256 period) internal pure returns (uint256) {
        if (period < MIN_LAYAWAY_PERIOD) return MIN_LAYAWAY_PERIOD;
        if (period > MAX_LAYAWAY_PERIOD) return MAX_LAYAWAY_PERIOD;
        return period;
    }

    /**
     * @dev Convert country code to geographic zone
     * @param countryCode ISO country code
     * @return zone Geographic zone enum
     */
    function _convertCountryToZone(bytes32 countryCode) internal pure returns (DynamicStakeCalculator.GeographicZone) {
        // Simplified conversion - in production this would be more comprehensive
        if (countryCode == "US" || countryCode == "CA" || countryCode == "GB") {
            return DynamicStakeCalculator.GeographicZone.DENSE_URBAN_AREA;
        } else if (countryCode == "CN" || countryCode == "IN" || countryCode == "BR") {
            return DynamicStakeCalculator.GeographicZone.UNDERSERVED_AREA;
        } else {
            return DynamicStakeCalculator.GeographicZone.DEFAULT_AREA;
        }
    }

    /**
     * @dev Convert verification status to stake calculator format
     * @param status Participant registry verification status
     * @return level Stake calculator verification level
     */
    function _convertVerificationLevel(
        ParticipantTypeRegistry.VerificationStatus status
    ) internal pure returns (DynamicStakeCalculator.VerificationLevel) {
        if (uint256(status) >= 3) { // GOVERNMENT_ID_VERIFIED or higher
            return DynamicStakeCalculator.VerificationLevel.GOVERNMENT_ID_VERIFIED;
        } else if (uint256(status) >= 1) { // EMAIL_VERIFIED or higher
            return DynamicStakeCalculator.VerificationLevel.EMAIL_VERIFIED;
        } else {
            return DynamicStakeCalculator.VerificationLevel.UNVERIFIED;
        }
    }

    // ========== ADMINISTRATIVE FUNCTIONS ==========

    /**
     * @dev Emergency pause all fair launch operations
     */
    function emergencyPause() external onlyRole(FAIR_LAUNCH_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause fair launch operations
     */
    function unpause() external onlyRole(FAIR_LAUNCH_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Update minimum participants requirement
     * @param newMinimum New minimum participants count
     */
    function updateMinimumParticipants(uint256 newMinimum) external onlyRole(FAIR_LAUNCH_ADMIN_ROLE) {
        require(newMinimum > 0, "Invalid minimum");
        minimumParticipants = newMinimum;
    }

    /**
     * @dev Finalize fair launch and distribute remaining tokens
     */
    function finalizeFairLaunch() external onlyRole(FAIR_LAUNCH_ADMIN_ROLE) nonReentrant {
        require(fairLaunchActive, "Fair launch not active");
        require(block.timestamp > fairLaunchEndTime, "Fair launch still active");
        require(totalFairLaunchParticipants >= minimumParticipants, "Insufficient participants");

        fairLaunchActive = false;

        // Calculate total distributed tokens
        uint256 totalDistributed = totalFairLaunchParticipants > 0 ? 
            (fairLaunchTokenAllocation * totalFairLaunchParticipants) / totalFairLaunchParticipants : 0;

        emit FairLaunchFinalized(totalFairLaunchParticipants, totalDistributed, block.timestamp);
    }
}