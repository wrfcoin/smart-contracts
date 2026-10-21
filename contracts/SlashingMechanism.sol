// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMultiAssetStaking.sol";
import "./interfaces/IParticipantTypeRegistry.sol";
import "./interfaces/ILayawayRegistration.sol";
import "./interfaces/IStakeDelegation.sol";
import "./interfaces/IWeatherDataValidator.sol";

/**
 * @title SlashingMechanism
 * @dev Comprehensive fraud detection and penalty enforcement system for WRFCoin fair launch
 * @notice Handles stake slashing, fraud detection, appeals process, and penalty enforcement
 */
contract SlashingMechanism is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ CONSTANTS ============
    
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant APPEALS_COMMITTEE_ROLE = keccak256("APPEALS_COMMITTEE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 private constant APPEAL_WINDOW = 30 days;
    uint256 private constant EXECUTION_DELAY = 48 hours;
    uint256 private constant GRACE_PERIOD = 30 days;
    uint256 private constant MIN_VALIDATORS_REQUIRED = 3;
    uint256 private constant LAYAWAY_MULTIPLIER = 2; // 2x normal layaway after slashing
    
    // Slashing percentage constants (basis points)
    uint256 private constant MINOR_SLASH_BPS = 2500;  // 25%
    uint256 private constant MAJOR_SLASH_BPS = 5000;  // 50%
    uint256 private constant CRITICAL_SLASH_BPS = 7500; // 75%
    uint256 private constant TOTAL_SLASH_BPS = 10000; // 100%
    
    // ============ ENUMS ============
    
    enum SlashingReason {
        DATA_MANIPULATION,           // 0
        SYBIL_ATTACK,               // 1
        NETWORK_DISRUPTION,         // 2
        REPEATED_VIOLATIONS,        // 3
        FRAUD,                      // 4
        GAMING_SYSTEM,              // 5
        CONSENSUS_ATTACK,           // 6
        // core4 SlashingReason variants (security/slashing.rs)
        INVALID_REVEAL,             // 7
        ORACLE_ATTESTATION_FRAUD,   // 8
        DATA_QUALITY_VIOLATION,     // 9
        INVALID_ZK_PROOF,          // 10
        REPEATED_LOW_QUALITY_DATA  // 11
    }
    
    enum SlashingStatus {
        PENDING,
        CONFIRMED,
        APPEALED,
        OVERTURNED,
        EXECUTED,
        EXPIRED
    }
    
    enum ViolationSeverity {
        MINOR,
        MAJOR,
        CRITICAL,
        TERMINAL
    }
    
    // ============ STRUCTS ============
    
    struct SlashingEvent {
        uint256 id;
        address participant;
        SlashingReason reason;
        ViolationSeverity severity;
        uint256 slashedAmount;
        uint256 timestamp;
        uint256 executionTime;
        address[] validators;
        bytes32 evidenceHash;
        SlashingStatus status;
        uint256 appealDeadline;
        string description;
        mapping(address => bool) validatorApprovals;
        uint256 approvalCount;
    }
    
    struct ParticipantRecord {
        uint256 violationCount;
        uint256 totalSlashed;
        uint256 lastViolation;
        bool isBanned;
        uint256 banExpiry;
        uint256 graceDeadline;
        bool requiresRefill;
        uint256 layawayMultiplier;
        uint256 lifetimeSlashCount;  // Total lifetime slashes including post-ban re-offenses
        uint256 totalBanCount;       // Number of times banned (for exponential duration)
    }
    
    struct AppealCase {
        uint256 slashingId;
        address appellant;
        bytes32 defendingEvidenceHash;
        string appealReason;
        uint256 submissionTime;
        uint256 votingDeadline;
        uint256 supportVotes;
        uint256 opposeVotes;
        mapping(address => bool) hasVoted;
        bool resolved;
        bool successful;
    }
    
    struct Evidence {
        bytes32 hash;
        string ipfsHash;
        address submitter;
        uint256 timestamp;
        bool verified;
    }
    
    // ============ STATE VARIABLES ============
    
    // Core contract references
    IMultiAssetStaking public multiAssetStaking;
    IParticipantTypeRegistry public participantRegistry;
    ILayawayRegistration public layawayRegistration;
    IStakeDelegation public stakeDelegation;
    IWeatherDataValidator public weatherDataValidator;
    
    // Treasury addresses
    address public treasury;
    address public burnAddress;
    
    // Slashing data
    mapping(uint256 => SlashingEvent) public slashingEvents;
    mapping(address => ParticipantRecord) public participantRecords;
    mapping(uint256 => AppealCase) public appealCases;
    mapping(bytes32 => Evidence) public evidenceRegistry;
    
    // Counters
    uint256 public nextSlashingId;
    uint256 public nextAppealId;
    
    // Configuration
    uint256 public minValidatorsRequired = MIN_VALIDATORS_REQUIRED;
    uint256 public executionDelay = EXECUTION_DELAY;
    uint256 public appealWindow = APPEAL_WINDOW;
    uint256 public gracePeriod = GRACE_PERIOD;
    
    // Asset allocation (basis points)
    uint256 public treasuryAllocationBPS = 5000; // 50% to treasury
    uint256 public burnAllocationBPS = 5000; // 50% burned

    // Slashing distribution
    /// @dev ERC-20 token routed from slashed stakes; set via setWrfToken()
    IERC20 public wrfToken;
    /// @dev True once wrfToken is set and token routing is verified safe to enable
    bool public distributionEnabled;

    // ============ EVENTS ============
    
    event SlashingProposed(
        uint256 indexed slashingId,
        address indexed participant,
        SlashingReason reason,
        ViolationSeverity severity,
        uint256 proposedAmount,
        bytes32 evidenceHash
    );
    
    event SlashingValidated(
        uint256 indexed slashingId,
        address indexed validator,
        uint256 approvalCount,
        uint256 required
    );
    
    event SlashingConfirmed(
        uint256 indexed slashingId,
        address indexed participant,
        uint256 executionTime
    );
    
    event SlashingExecuted(
        uint256 indexed slashingId,
        address indexed participant,
        uint256 slashedAmount,
        uint256 treasuryAmount,
        uint256 burnedAmount
    );
    
    event AppealSubmitted(
        uint256 indexed appealId,
        uint256 indexed slashingId,
        address indexed appellant,
        bytes32 evidenceHash
    );
    
    event AppealResolved(
        uint256 indexed appealId,
        uint256 indexed slashingId,
        bool successful,
        uint256 supportVotes,
        uint256 opposeVotes
    );
    
    event StakeRefilled(
        address indexed participant,
        uint256 amount,
        uint256 newLayawayPeriod
    );
    
    event ParticipantBanned(
        address indexed participant,
        uint256 banDuration,
        SlashingReason reason
    );
    
    event EvidenceSubmitted(
        bytes32 indexed evidenceHash,
        address indexed submitter,
        string ipfsHash
    );
    
    event EmergencySlashing(
        address indexed participant,
        uint256 amount,
        address indexed executor,
        string reason
    );

    /// @dev Emitted when distribution is deferred because wrfToken / distributionEnabled is not set
    event SlashingDistributionDeferred(uint256 totalAmount, uint256 treasuryAmount, uint256 burnAmount);

    /// @dev Emitted when the wrfToken address is configured
    event WrfTokenSet(address indexed token);

    /// @dev Emitted when distribution is enabled or disabled
    event DistributionEnabledChanged(bool enabled);

    // ============ MODIFIERS ============
    
    modifier onlyValidator() {
        require(hasRole(VALIDATOR_ROLE, msg.sender), "SlashingMechanism: Not a validator");
        _;
    }
    
    modifier onlyAppealsCommittee() {
        require(hasRole(APPEALS_COMMITTEE_ROLE, msg.sender), "SlashingMechanism: Not appeals committee");
        _;
    }
    
    modifier onlyEmergency() {
        require(hasRole(EMERGENCY_ROLE, msg.sender), "SlashingMechanism: Not emergency role");
        _;
    }
    
    modifier validSlashing(uint256 slashingId) {
        require(slashingId < nextSlashingId, "SlashingMechanism: Invalid slashing ID");
        _;
    }
    
    modifier validAppeal(uint256 appealId) {
        require(appealId < nextAppealId, "SlashingMechanism: Invalid appeal ID");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(
        address _multiAssetStaking,
        address _participantRegistry,
        address _layawayRegistration,
        address _stakeDelegation,
        address _weatherDataValidator,
        address _treasury,
        address _burnAddress
    ) {
        require(_multiAssetStaking != address(0), "SlashingMechanism: Invalid staking address");
        require(_participantRegistry != address(0), "SlashingMechanism: Invalid registry address");
        require(_treasury != address(0), "SlashingMechanism: Invalid treasury address");
        require(_burnAddress != address(0), "SlashingMechanism: Invalid burn address");
        
        multiAssetStaking = IMultiAssetStaking(_multiAssetStaking);
        participantRegistry = IParticipantTypeRegistry(_participantRegistry);
        layawayRegistration = ILayawayRegistration(_layawayRegistration);
        stakeDelegation = IStakeDelegation(_stakeDelegation);
        weatherDataValidator = IWeatherDataValidator(_weatherDataValidator);
        
        treasury = _treasury;
        burnAddress = _burnAddress;
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VALIDATOR_ROLE, msg.sender);
        _grantRole(APPEALS_COMMITTEE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        nextSlashingId = 1;
        nextAppealId = 1;
    }
    
    // ============ CORE SLASHING FUNCTIONS ============
    
    /**
     * @dev Propose a slashing event with evidence
     * @param participant Address to be slashed
     * @param reason Reason for slashing
     * @param severity Severity level of violation
     * @param evidenceHash Hash of evidence supporting the slashing
     * @param description Human-readable description of the violation
     */
    function proposeSlashing(
        address participant,
        SlashingReason reason,
        ViolationSeverity severity,
        bytes32 evidenceHash,
        string calldata description
    ) external onlyValidator whenNotPaused nonReentrant {
        require(participant != address(0), "SlashingMechanism: Invalid participant");
        require(evidenceRegistry[evidenceHash].verified, "SlashingMechanism: Evidence not verified");
        require(bytes(description).length > 0, "SlashingMechanism: Description required");
        
        // Check if participant has active stake
        require(_getParticipantStake(participant) > 0, "SlashingMechanism: No stake to slash");
        
        uint256 slashingId = nextSlashingId++;
        SlashingEvent storage slashing = slashingEvents[slashingId];
        
        slashing.id = slashingId;
        slashing.participant = participant;
        slashing.reason = reason;
        slashing.severity = severity;
        slashing.slashedAmount = _calculateSlashingAmount(participant, severity);
        slashing.timestamp = block.timestamp;
        slashing.evidenceHash = evidenceHash;
        slashing.status = SlashingStatus.PENDING;
        slashing.appealDeadline = block.timestamp + appealWindow;
        slashing.description = description;
        
        // Add proposer as first validator
        slashing.validators.push(msg.sender);
        slashing.validatorApprovals[msg.sender] = true;
        slashing.approvalCount = 1;
        
        emit SlashingProposed(
            slashingId,
            participant,
            reason,
            severity,
            slashing.slashedAmount,
            evidenceHash
        );
    }
    
    /**
     * @dev Validate a pending slashing proposal
     * @param slashingId ID of the slashing event to validate
     */
    function validateSlashing(uint256 slashingId) 
        external 
        onlyValidator 
        whenNotPaused 
        validSlashing(slashingId) 
    {
        SlashingEvent storage slashing = slashingEvents[slashingId];
        require(slashing.status == SlashingStatus.PENDING, "SlashingMechanism: Not pending");
        require(!slashing.validatorApprovals[msg.sender], "SlashingMechanism: Already validated");
        
        // Add validator approval
        slashing.validators.push(msg.sender);
        slashing.validatorApprovals[msg.sender] = true;
        slashing.approvalCount++;
        
        emit SlashingValidated(
            slashingId,
            msg.sender,
            slashing.approvalCount,
            minValidatorsRequired
        );
        
        // Check if we have enough approvals
        if (slashing.approvalCount >= minValidatorsRequired) {
            slashing.status = SlashingStatus.CONFIRMED;
            slashing.executionTime = block.timestamp + executionDelay;
            
            emit SlashingConfirmed(slashingId, slashing.participant, slashing.executionTime);
        }
    }
    
    /**
     * @dev Execute a confirmed slashing after delay period
     * @param slashingId ID of the slashing event to execute
     */
    function executeSlashing(uint256 slashingId) 
        external 
        whenNotPaused 
        validSlashing(slashingId) 
    {
        SlashingEvent storage slashing = slashingEvents[slashingId];
        require(slashing.status == SlashingStatus.CONFIRMED, "SlashingMechanism: Not confirmed");
        require(block.timestamp >= slashing.executionTime, "SlashingMechanism: Execution delay not met");
        require(block.timestamp <= slashing.appealDeadline, "SlashingMechanism: Appeal window expired");
        
        address participant = slashing.participant;
        // Recompute slash amount at execution time to prevent stale-amount exploits
        // (participant may have changed stake between proposal and execution)
        uint256 slashAmount = _calculateSlashingAmount(participant, slashing.severity);
        slashing.slashedAmount = slashAmount;
        
        // Update participant record
        ParticipantRecord storage record = participantRecords[participant];
        record.violationCount++;
        record.totalSlashed += slashAmount;
        record.lastViolation = block.timestamp;
        record.requiresRefill = true;
        record.graceDeadline = block.timestamp + gracePeriod;
        record.layawayMultiplier = LAYAWAY_MULTIPLIER;
        
        // Apply bans for severe violations
        _applyBanIfRequired(participant, slashing.severity, record.violationCount);
        
        // Execute the slashing
        _executeStakeSlashing(participant, slashAmount);
        
        // Distribute slashed assets
        (uint256 treasuryAmount, uint256 burnAmount) = _distributeSlashedAssets(slashAmount);
        
        slashing.status = SlashingStatus.EXECUTED;
        
        emit SlashingExecuted(slashingId, participant, slashAmount, treasuryAmount, burnAmount);
        
        // Update participant status in registry
        if (address(participantRegistry) != address(0)) {
            participantRegistry.updateParticipantStatus(participant, false);
        }
    }
    
    // ============ APPEALS PROCESS ============
    
    /**
     * @dev Submit an appeal for a slashing decision
     * @param slashingId ID of the slashing to appeal
     * @param defendingEvidenceHash Hash of evidence supporting the appeal
     * @param appealReason Reason for the appeal
     */
    function appealSlashing(
        uint256 slashingId,
        bytes32 defendingEvidenceHash,
        string calldata appealReason
    ) external whenNotPaused validSlashing(slashingId) {
        SlashingEvent storage slashing = slashingEvents[slashingId];
        require(msg.sender == slashing.participant, "SlashingMechanism: Only participant can appeal");
        require(slashing.status == SlashingStatus.CONFIRMED, "SlashingMechanism: Cannot appeal this status");
        require(block.timestamp <= slashing.appealDeadline, "SlashingMechanism: Appeal window expired");
        require(evidenceRegistry[defendingEvidenceHash].verified, "SlashingMechanism: Evidence not verified");
        
        uint256 appealId = nextAppealId++;
        AppealCase storage appeal = appealCases[appealId];
        
        appeal.slashingId = slashingId;
        appeal.appellant = msg.sender;
        appeal.defendingEvidenceHash = defendingEvidenceHash;
        appeal.appealReason = appealReason;
        appeal.submissionTime = block.timestamp;
        appeal.votingDeadline = block.timestamp + 7 days; // 7 day voting period
        
        slashing.status = SlashingStatus.APPEALED;
        
        emit AppealSubmitted(appealId, slashingId, msg.sender, defendingEvidenceHash);
    }
    
    /**
     * @dev Vote on an appeal case (Appeals Committee only)
     * @param appealId ID of the appeal to vote on
     * @param support True to support the appeal, false to oppose
     */
    function voteOnAppeal(uint256 appealId, bool support) 
        external 
        onlyAppealsCommittee 
        whenNotPaused 
        validAppeal(appealId) 
    {
        AppealCase storage appeal = appealCases[appealId];
        require(!appeal.resolved, "SlashingMechanism: Appeal already resolved");
        require(block.timestamp <= appeal.votingDeadline, "SlashingMechanism: Voting period ended");
        require(!appeal.hasVoted[msg.sender], "SlashingMechanism: Already voted");
        
        appeal.hasVoted[msg.sender] = true;
        
        if (support) {
            appeal.supportVotes++;
        } else {
            appeal.opposeVotes++;
        }
    }
    
    /**
     * @dev Resolve an appeal after voting period
     * @param appealId ID of the appeal to resolve
     */
    function resolveAppeal(uint256 appealId) 
        external 
        whenNotPaused 
        validAppeal(appealId) 
    {
        AppealCase storage appeal = appealCases[appealId];
        require(!appeal.resolved, "SlashingMechanism: Appeal already resolved");
        require(block.timestamp > appeal.votingDeadline, "SlashingMechanism: Voting period not ended");
        
        SlashingEvent storage slashing = slashingEvents[appeal.slashingId];
        
        bool successful = appeal.supportVotes > appeal.opposeVotes;
        appeal.resolved = true;
        appeal.successful = successful;
        
        if (successful) {
            // Appeal successful - overturn slashing
            slashing.status = SlashingStatus.OVERTURNED;
            
            // Reset participant record penalties
            ParticipantRecord storage record = participantRecords[slashing.participant];
            if (record.violationCount > 0) {
                record.violationCount--;
            }
            record.requiresRefill = false;
            record.layawayMultiplier = 1;
            
            // Restore participant status
            if (address(participantRegistry) != address(0)) {
                participantRegistry.updateParticipantStatus(slashing.participant, true);
            }
        } else {
            // Appeal rejected - proceed with execution if not already done
            if (slashing.status == SlashingStatus.APPEALED) {
                slashing.status = SlashingStatus.CONFIRMED;
                slashing.executionTime = block.timestamp + executionDelay;
            }
        }
        
        emit AppealResolved(
            appealId,
            appeal.slashingId,
            successful,
            appeal.supportVotes,
            appeal.opposeVotes
        );
    }
    
    // ============ STAKE REFILL FUNCTIONS ============
    
    /**
     * @dev Refill stake after being slashed
     * @param amount Amount to refill
     */
    function refillStake(uint256 amount) external whenNotPaused nonReentrant {
        ParticipantRecord storage record = participantRecords[msg.sender];
        require(record.requiresRefill, "SlashingMechanism: No refill required");
        require(block.timestamp <= record.graceDeadline, "SlashingMechanism: Grace period expired");
        require(amount > 0, "SlashingMechanism: Invalid amount");
        require(!record.isBanned || block.timestamp >= record.banExpiry, "SlashingMechanism: Still banned");
        
        // Calculate required refill amount
        uint256 currentStake = _getParticipantStake(msg.sender);
        uint256 requiredStake = _getRequiredStakeAmount(msg.sender);
        require(currentStake + amount >= requiredStake, "SlashingMechanism: Insufficient refill amount");
        
        // Reset refill requirement
        record.requiresRefill = false;
        record.graceDeadline = 0;
        
        // Calculate new layaway period (2x normal)
        uint256 newLayawayPeriod = _getBaseLayawayPeriod() * record.layawayMultiplier;
        
        // Update layaway registration with extended period
        if (address(layawayRegistration) != address(0)) {
            layawayRegistration.updateLayawayPeriod(msg.sender, newLayawayPeriod);
        }
        
        // Restore participant status
        if (address(participantRegistry) != address(0)) {
            participantRegistry.updateParticipantStatus(msg.sender, true);
        }
        
        emit StakeRefilled(msg.sender, amount, newLayawayPeriod);
    }
    
    /**
     * @dev Check if participant is eligible to continue after slashing
     * @param participant Address to check
     * @return eligible True if participant can continue
     * @return reason Reason if not eligible
     */
    function checkEligibility(address participant)
        external
        view
        returns (bool eligible, string memory reason)
    {
        ParticipantRecord storage record = participantRecords[participant];

        // SECURITY FIX: Check for permanent ban via lifetime threshold.
        // Validators who exceed the lifetime slash threshold (5+) receive permanent bans
        // (banExpiry == type(uint256).max). This check ensures they can never re-enter.
        if (record.isBanned && record.banExpiry == type(uint256).max) {
            return (false, "Participant is permanently banned");
        }

        if (record.isBanned && block.timestamp < record.banExpiry) {
            return (false, "Participant is banned");
        }

        if (record.requiresRefill && block.timestamp > record.graceDeadline) {
            return (false, "Grace period expired, must refill stake");
        }

        if (record.requiresRefill) {
            return (false, "Must refill stake to continue");
        }

        return (true, "");
    }
    
    // ============ EVIDENCE MANAGEMENT ============
    
    /**
     * @dev Submit evidence for slashing or appeals
     * @param evidenceHash Hash of the evidence
     * @param ipfsHash IPFS hash for evidence storage
     */
    function submitEvidence(bytes32 evidenceHash, string calldata ipfsHash) 
        external 
        onlyValidator 
        whenNotPaused 
    {
        require(evidenceHash != bytes32(0), "SlashingMechanism: Invalid evidence hash");
        require(bytes(ipfsHash).length > 0, "SlashingMechanism: IPFS hash required");
        require(!evidenceRegistry[evidenceHash].verified, "SlashingMechanism: Evidence already exists");
        
        evidenceRegistry[evidenceHash] = Evidence({
            hash: evidenceHash,
            ipfsHash: ipfsHash,
            submitter: msg.sender,
            timestamp: block.timestamp,
            verified: true
        });
        
        emit EvidenceSubmitted(evidenceHash, msg.sender, ipfsHash);
    }
    
    /**
     * @dev Verify evidence hash against IPFS content
     * @param evidenceHash Hash to verify
     * @return verified True if evidence is valid
     */
    function verifyEvidence(bytes32 evidenceHash) external view returns (bool verified) {
        return evidenceRegistry[evidenceHash].verified;
    }
    
    // ============ EMERGENCY FUNCTIONS ============
    
    /**
     * @dev Emergency slashing for critical situations
     * @param participant Address to slash
     * @param amount Amount to slash
     * @param reason Reason for emergency slashing
     */
    function emergencySlashing(
        address participant,
        uint256 amount,
        string calldata reason
    ) external onlyEmergency whenNotPaused nonReentrant {
        require(participant != address(0), "SlashingMechanism: Invalid participant");
        require(amount > 0, "SlashingMechanism: Invalid amount");
        require(bytes(reason).length > 0, "SlashingMechanism: Reason required");
        
        uint256 currentStake = _getParticipantStake(participant);
        require(currentStake >= amount, "SlashingMechanism: Insufficient stake");
        
        // Execute immediate slashing
        _executeStakeSlashing(participant, amount);
        
        // Update participant record
        ParticipantRecord storage record = participantRecords[participant];
        record.violationCount++;
        record.totalSlashed += amount;
        record.lastViolation = block.timestamp;
        record.requiresRefill = true;
        record.graceDeadline = block.timestamp + gracePeriod;

        // SECURITY FIX: Track lifetime slash count for emergency slashing too.
        // Previously only _applyBanIfRequired tracked lifetimeSlashCount, so emergency
        // slashes did not contribute to permanent ban thresholds, allowing revolving-door abuse.
        record.lifetimeSlashCount++;

        // Apply ban using centralized logic that respects lifetime thresholds
        _applyBanIfRequired(participant, ViolationSeverity.CRITICAL, record.violationCount);

        // If _applyBanIfRequired didn't set a ban (e.g. first offense minor), ensure
        // emergency slashing still applies at least a 30-day ban
        if (!record.isBanned) {
            record.isBanned = true;
            record.banExpiry = block.timestamp + 30 days;
            record.totalBanCount++;
            emit ParticipantBanned(participant, 30 days, SlashingReason.FRAUD);
        }

        // Distribute slashed assets
        _distributeSlashedAssets(amount);

        emit EmergencySlashing(participant, amount, msg.sender, reason);

        // Update participant status
        if (address(participantRegistry) != address(0)) {
            participantRegistry.updateParticipantStatus(participant, false);
        }
    }
    
    // ============ ADMIN FUNCTIONS ============
    
    /**
     * @dev Update contract configurations
     */
    function updateConfiguration(
        uint256 _minValidatorsRequired,
        uint256 _executionDelay,
        uint256 _appealWindow,
        uint256 _gracePeriod,
        uint256 _treasuryAllocationBPS,
        uint256 _burnAllocationBPS
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minValidatorsRequired >= 2, "SlashingMechanism: Min validators too low");
        require(_executionDelay >= 1 hours, "SlashingMechanism: Execution delay too short");
        require(_appealWindow >= 1 days, "SlashingMechanism: Appeal window too short");
        require(_treasuryAllocationBPS + _burnAllocationBPS == 10000, "SlashingMechanism: Invalid allocation");
        
        minValidatorsRequired = _minValidatorsRequired;
        executionDelay = _executionDelay;
        appealWindow = _appealWindow;
        gracePeriod = _gracePeriod;
        treasuryAllocationBPS = _treasuryAllocationBPS;
        burnAllocationBPS = _burnAllocationBPS;
    }
    
    /**
     * @dev Update contract references
     */
    function updateContractReferences(
        address _multiAssetStaking,
        address _participantRegistry,
        address _layawayRegistration,
        address _stakeDelegation,
        address _weatherDataValidator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_multiAssetStaking != address(0)) {
            multiAssetStaking = IMultiAssetStaking(_multiAssetStaking);
        }
        if (_participantRegistry != address(0)) {
            participantRegistry = IParticipantTypeRegistry(_participantRegistry);
        }
        if (_layawayRegistration != address(0)) {
            layawayRegistration = ILayawayRegistration(_layawayRegistration);
        }
        if (_stakeDelegation != address(0)) {
            stakeDelegation = IStakeDelegation(_stakeDelegation);
        }
        if (_weatherDataValidator != address(0)) {
            weatherDataValidator = IWeatherDataValidator(_weatherDataValidator);
        }
    }
    
    /**
     * @dev Update treasury and burn addresses
     */
    function updateAddresses(address _treasury, address _burnAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_treasury != address(0), "SlashingMechanism: Invalid treasury");
        require(_burnAddress != address(0), "SlashingMechanism: Invalid burn address");

        treasury = _treasury;
        burnAddress = _burnAddress;
    }

    /**
     * @dev Set the WRF token used for slashing distributions.
     *      Must be called before enabling distribution.
     * @param _wrfToken Address of the ERC-20 token contract
     */
    function setWrfToken(address _wrfToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_wrfToken != address(0), "SlashingMechanism: Invalid token address");
        wrfToken = IERC20(_wrfToken);
        emit WrfTokenSet(_wrfToken);
    }

    /**
     * @dev Enable or disable on-chain slashing distribution.
     *      Set wrfToken first; enabling without a token address reverts.
     * @param enabled True to activate token transfers; false to defer them
     */
    function setDistributionEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) {
            require(address(wrfToken) != address(0), "SlashingMechanism: wrfToken not set");
        }
        distributionEnabled = enabled;
        emit DistributionEnabledChanged(enabled);
    }
    
    /**
     * @dev Pause/unpause contract
     */
    function setPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (paused) {
            _pause();
        } else {
            _unpause();
        }
    }
    
    // ============ VIEW FUNCTIONS ============
    
    /**
     * @dev Get slashing event details
     * @param slashingId ID of the slashing event
     */
    function getSlashingEvent(uint256 slashingId) 
        external 
        view 
        validSlashing(slashingId) 
        returns (
            address participant,
            SlashingReason reason,
            ViolationSeverity severity,
            uint256 slashedAmount,
            uint256 timestamp,
            uint256 executionTime,
            SlashingStatus status,
            uint256 appealDeadline,
            string memory description,
            address[] memory validators,
            uint256 approvalCount
        ) 
    {
        SlashingEvent storage slashing = slashingEvents[slashingId];
        return (
            slashing.participant,
            slashing.reason,
            slashing.severity,
            slashing.slashedAmount,
            slashing.timestamp,
            slashing.executionTime,
            slashing.status,
            slashing.appealDeadline,
            slashing.description,
            slashing.validators,
            slashing.approvalCount
        );
    }
    
    /**
     * @dev Get participant violation record
     * @param participant Address to query
     */
    function getParticipantRecord(address participant)
        external
        view
        returns (
            uint256 violationCount,
            uint256 totalSlashed,
            uint256 lastViolation,
            bool isBanned,
            uint256 banExpiry,
            uint256 graceDeadline,
            bool requiresRefill,
            uint256 layawayMultiplier,
            uint256 lifetimeSlashCount,
            uint256 totalBanCount
        )
    {
        ParticipantRecord storage record = participantRecords[participant];
        return (
            record.violationCount,
            record.totalSlashed,
            record.lastViolation,
            record.isBanned,
            record.banExpiry,
            record.graceDeadline,
            record.requiresRefill,
            record.layawayMultiplier,
            record.lifetimeSlashCount,
            record.totalBanCount
        );
    }
    
    /**
     * @dev Get appeal case details
     * @param appealId ID of the appeal case
     */
    function getAppealCase(uint256 appealId) 
        external 
        view 
        validAppeal(appealId) 
        returns (
            uint256 slashingId,
            address appellant,
            bytes32 defendingEvidenceHash,
            string memory appealReason,
            uint256 submissionTime,
            uint256 votingDeadline,
            uint256 supportVotes,
            uint256 opposeVotes,
            bool resolved,
            bool successful
        ) 
    {
        AppealCase storage appeal = appealCases[appealId];
        return (
            appeal.slashingId,
            appeal.appellant,
            appeal.defendingEvidenceHash,
            appeal.appealReason,
            appeal.submissionTime,
            appeal.votingDeadline,
            appeal.supportVotes,
            appeal.opposeVotes,
            appeal.resolved,
            appeal.successful
        );
    }
    
    /**
     * @dev Get pending slashing events for a validator
     * @param validator Address of validator
     * @return pendingIds Array of pending slashing IDs
     */
    function getPendingSlashings(address validator) 
        external 
        view 
        returns (uint256[] memory pendingIds) 
    {
        uint256 count = 0;
        
        // Count pending slashings
        for (uint256 i = 1; i < nextSlashingId; i++) {
            SlashingEvent storage slashing = slashingEvents[i];
            if (slashing.status == SlashingStatus.PENDING && 
                !slashing.validatorApprovals[validator]) {
                count++;
            }
        }
        
        // Populate array
        pendingIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < nextSlashingId; i++) {
            SlashingEvent storage slashing = slashingEvents[i];
            if (slashing.status == SlashingStatus.PENDING && 
                !slashing.validatorApprovals[validator]) {
                pendingIds[index++] = i;
            }
        }
    }
    
    // ============ INTERNAL FUNCTIONS ============
    
    /**
     * @dev Calculate slashing amount based on severity
     * @param participant Address of participant
     * @param severity Violation severity
     * @return amount Amount to slash
     */
    /**
     * @dev Returns the default severity for core4-aligned slashing reasons.
     */
    function getDefaultSeverity(SlashingReason reason) public pure returns (ViolationSeverity) {
        if (reason == SlashingReason.INVALID_REVEAL) return ViolationSeverity.MINOR;
        if (reason == SlashingReason.ORACLE_ATTESTATION_FRAUD) return ViolationSeverity.CRITICAL;
        if (reason == SlashingReason.DATA_QUALITY_VIOLATION) return ViolationSeverity.MINOR;
        if (reason == SlashingReason.INVALID_ZK_PROOF) return ViolationSeverity.CRITICAL;
        if (reason == SlashingReason.REPEATED_LOW_QUALITY_DATA) return ViolationSeverity.MAJOR;
        // For legacy reasons, return MAJOR as a safe middle-ground default
        return ViolationSeverity.MAJOR;
    }

    function _calculateSlashingAmount(address participant, ViolationSeverity severity)
        internal 
        view 
        returns (uint256 amount) 
    {
        uint256 totalStake = _getParticipantStake(participant);
        
        if (severity == ViolationSeverity.MINOR) {
            amount = (totalStake * MINOR_SLASH_BPS) / 10000;
        } else if (severity == ViolationSeverity.MAJOR) {
            amount = (totalStake * MAJOR_SLASH_BPS) / 10000;
        } else if (severity == ViolationSeverity.CRITICAL) {
            amount = (totalStake * CRITICAL_SLASH_BPS) / 10000;
        } else if (severity == ViolationSeverity.TERMINAL) {
            amount = totalStake; // 100% slash
        }
        
        // Increase slashing for repeat offenders
        uint256 violationCount = participantRecords[participant].violationCount;
        if (violationCount > 0) {
            uint256 multiplier = 100 + (violationCount * 25); // +25% per violation
            amount = (amount * multiplier) / 100;
            
            // Cap at total stake
            if (amount > totalStake) {
                amount = totalStake;
            }
        }
    }
    
    /**
     * @dev Apply ban if required based on severity and violation count.
     * SECURITY FIX: Uses lifetime slash count with exponential ban duration to prevent
     * revolving-door abuse where validators get banned, wait out the ban, and repeat.
     * Ban duration doubles with each successive ban: 7d, 14d, 28d, 56d, ... then permanent.
     * @param participant Address of participant
     * @param severity Violation severity
     * @param violationCount Number of violations
     */
    function _applyBanIfRequired(
        address participant,
        ViolationSeverity severity,
        uint256 violationCount
    ) internal {
        ParticipantRecord storage record = participantRecords[participant];

        // Track lifetime slash count (persists across bans)
        record.lifetimeSlashCount++;

        if (severity == ViolationSeverity.TERMINAL || violationCount >= 3 || record.lifetimeSlashCount >= 5) {
            // Terminal violations, 3+ current violations, or 5+ lifetime slashes get permanent ban
            record.isBanned = true;
            record.banExpiry = type(uint256).max; // Permanent ban
            record.totalBanCount++;

            emit ParticipantBanned(participant, type(uint256).max, SlashingReason.REPEATED_VIOLATIONS);
        } else if (severity == ViolationSeverity.CRITICAL || record.lifetimeSlashCount >= 2) {
            // Critical violations or repeat offenders get exponentially increasing ban
            record.totalBanCount++;
            // Exponential ban duration: 7 days * 2^(totalBanCount - 1)
            // Cap the exponent to avoid overflow (max exponent = 8 => 7 * 256 = ~5 years)
            uint256 exponent = record.totalBanCount - 1;
            if (exponent > 8) exponent = 8;
            uint256 banDuration = 7 days * (2 ** exponent);

            record.isBanned = true;
            record.banExpiry = block.timestamp + banDuration;

            emit ParticipantBanned(participant, banDuration, SlashingReason.REPEATED_VIOLATIONS);
        }
    }
    
    /**
     * @dev Execute stake slashing across multiple assets
     * @param participant Address to slash
     * @param amount Total amount to slash
     */
    function _executeStakeSlashing(address participant, uint256 amount) internal {
        if (address(multiAssetStaking) != address(0)) {
            multiAssetStaking.slashStake(participant, amount);
        }
        
        // Also handle delegated stake slashing if applicable
        if (address(stakeDelegation) != address(0)) {
            stakeDelegation.slashDelegatedStake(participant, amount);
        }
    }
    
    /**
     * @dev Distribute slashed assets to treasury and burn
     * @param amount Amount to distribute
     * @return treasuryAmount Amount sent to treasury
     * @return burnAmount Amount burned
     */
    /**
     * @dev Distribute slashed assets to treasury and burn address.
     *
     * When `distributionEnabled` is true and `wrfToken` is set the slashed
     * token balance held by this contract is split and forwarded via
     * SafeERC20.safeTransfer.  The caller (multiAssetStaking) must have
     * already transferred the slashed tokens to this contract.
     *
     * When distribution is not yet enabled the amounts are computed, an event
     * is emitted for off-chain accounting, and the function returns normally —
     * no revert.  Enable via setDistributionEnabled(true) once wrfToken is
     * configured and the token-routing integration is verified.
     */
    function _distributeSlashedAssets(uint256 amount)
        internal
        returns (uint256 treasuryAmount, uint256 burnAmount)
    {
        treasuryAmount = (amount * treasuryAllocationBPS) / 10000;
        burnAmount = amount - treasuryAmount;

        if (!distributionEnabled || address(wrfToken) == address(0)) {
            emit SlashingDistributionDeferred(amount, treasuryAmount, burnAmount);
            return (treasuryAmount, burnAmount);
        }

        if (treasuryAmount > 0) {
            wrfToken.safeTransfer(treasury, treasuryAmount);
        }
        if (burnAmount > 0) {
            wrfToken.safeTransfer(burnAddress, burnAmount);
        }
    }
    
    /**
     * @dev Get participant's total stake amount
     * @param participant Address to query
     * @return stake Total stake amount
     */
    function _getParticipantStake(address participant) internal view returns (uint256 stake) {
        if (address(multiAssetStaking) != address(0)) {
            return multiAssetStaking.getTotalStake(participant);
        }
        return 0;
    }
    
    /**
     * @dev Get required stake amount for participant type
     * @param participant Address to query
     * @return required Required stake amount
     */
    function _getRequiredStakeAmount(address participant) internal view returns (uint256 required) {
        if (address(participantRegistry) != address(0)) {
            return participantRegistry.getRequiredStakeAmount(participant);
        }
        return 1000 * 10**18; // Default 1000 tokens
    }
    
    /**
     * @dev Get base layaway period
     * @return period Base layaway period in seconds
     */
    function _getBaseLayawayPeriod() internal view returns (uint256 period) {
        if (address(layawayRegistration) != address(0)) {
            return layawayRegistration.getBaseLayawayPeriod();
        }
        return 30 days; // Default 30 days
    }

    // ============ LEGACY COMPATIBILITY FUNCTIONS ============

    /**
     * @notice Check if participant has slashing history (Legacy compatibility)
     * @param participant Address to check
     * @return hasSlashing True if participant has been slashed
     * @return slashingCount Number of times slashed
     * @return lastSlashTime Timestamp of last slashing
     */
    function getSlashingHistory(address participant)
        external
        view
        returns (
            bool hasSlashing,
            uint256 slashingCount,
            uint256 lastSlashTime
        )
    {
        ParticipantRecord storage record = participantRecords[participant];
        return (
            record.violationCount > 0,
            record.violationCount,
            record.lastViolation
        );
    }

    /**
     * @notice Get slashing severity for participant (Legacy compatibility)
     * @param participant Address to check
     * @return severity Slashing severity (0-10000 basis points)
     */
    function getSlashingSeverity(address participant)
        external
        view
        returns (uint256 severity)
    {
        ParticipantRecord storage record = participantRecords[participant];
        
        // Calculate severity based on violation count
        if (record.violationCount == 0) {
            return 0;
        } else if (record.violationCount == 1) {
            return 2500; // 25% for first violation
        } else if (record.violationCount == 2) {
            return 5000; // 50% for second violation
        } else if (record.violationCount >= 3) {
            return 7500; // 75% for third+ violation
        }
        
        return 2500; // Default to minor severity
    }

    /**
     * @notice Check if participant is currently suspended (Legacy compatibility)
     * @param participant Address to check
     * @return suspended True if participant is suspended
     * @return suspensionEnd Timestamp when suspension ends
     */
    function isSuspended(address participant)
        external
        view
        returns (bool suspended, uint256 suspensionEnd)
    {
        ParticipantRecord storage record = participantRecords[participant];
        
        if (record.isBanned && record.banExpiry > block.timestamp) {
            return (true, record.banExpiry);
        }
        
        return (false, 0);
    }
}
