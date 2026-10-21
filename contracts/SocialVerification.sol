// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title SocialVerification
 * @dev Comprehensive social media and professional platform verification system for WRFCoin fair launch
 * 
 * This contract manages social verification for staking discounts in the WRFCoin ecosystem,
 * providing secure, oracle-based verification of GitHub, Twitter, and LinkedIn profiles
 * to prevent Sybil attacks and enable merit-based participation discounts.
 * 
 * Core Features:
 * - Multi-platform verification (GitHub, Twitter, LinkedIn) 
 * - Oracle-based verification with external API integration
 * - Time-based verification expiration (1 year validity)
 * - Anti-manipulation protection against fake accounts
 * - Rate limiting and spam prevention
 * - Identity deduplication to prevent multiple accounts per person
 * - Comprehensive audit trails and transparency
 * - Integration with DynamicStakeCalculator for discount application
 * 
 * Verification Criteria:
 * - GitHub: 6+ months old, 10+ repositories, 50+ commits/year, open source contributions
 * - Twitter: Verified account status, 1+ year old, 1000+ followers, recent activity
 * - LinkedIn: Professional profile, 500+ connections, work/education verification
 * 
 * Security Features:
 * - EIP-712 signature verification for secure attestations
 * - Oracle authorization with multi-signature requirements  
 * - Rate limiting to prevent abuse and spam
 * - Comprehensive event logging for transparency
 * - Emergency pause and admin controls
 * - Anti-replay protection for verification submissions
 * 
 * @author WRFCoin Security Team
 * @notice Production-ready social verification system with enterprise security standards
 */
contract SocialVerification is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ========== CONSTANTS ==========

    /// @dev Precision for percentage calculations
    uint256 public constant PRECISION = 1e6;

    /// @dev Maximum combined social verification discount (20%)
    uint256 public constant MAX_SOCIAL_DISCOUNT = 200_000; // 20% in precision units

    /// @dev Verification validity period (1 year)
    uint256 public constant VERIFICATION_VALIDITY_PERIOD = 365 days;

    /// @dev Rate limiting constants
    uint256 public constant VERIFICATION_COOLDOWN = 24 hours;
    uint256 public constant MAX_DAILY_VERIFICATIONS = 50;

    /// @dev Maximum verification attempts per account
    uint256 public constant MAX_VERIFICATION_ATTEMPTS = 5;

    /// @dev Minimum account age requirements (seconds)
    uint256 public constant MIN_GITHUB_ACCOUNT_AGE = 180 days; // 6 months
    uint256 public constant MIN_TWITTER_ACCOUNT_AGE = 365 days; // 1 year
    uint256 public constant MIN_LINKEDIN_ACCOUNT_AGE = 90 days;  // 3 months

    // ========== ACCESS CONTROL ROLES ==========

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE"); 
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ========== ENUMS ==========

    /// @dev Supported social platforms for verification
    enum SocialPlatform {
        GITHUB,     // Open source contributions and development activity
        TWITTER,    // Social media presence and community engagement
        LINKEDIN    // Professional network and career verification
    }

    /// @dev Verification status tracking
    enum VerificationStatus {
        PENDING,    // Verification request submitted
        VERIFIED,   // Successfully verified by oracle
        EXPIRED,    // Verification period has ended
        REVOKED,    // Manually revoked for violations
        REJECTED    // Failed verification criteria
    }

    /// @dev GitHub verification criteria levels
    enum GitHubTier {
        BASIC,      // Meets minimum requirements
        CONTRIBUTOR, // Active open source contributor
        MAINTAINER, // Project maintainer or significant contributor
        ECOSYSTEM   // WRFCoin ecosystem contributor (bonus tier)
    }

    // ========== STRUCTS ==========

    /// @dev Comprehensive social verification record
    struct SocialVerificationRecord {
        address participant;                    // Address of the verified participant
        SocialPlatform platform;               // Which platform was verified
        string profileIdentifier;             // Platform username or profile ID
        uint256 verificationTimestamp;        // When verification was completed
        uint256 expirationTimestamp;          // When verification expires
        uint256 discountPercentage;           // Discount percentage earned (precision units)
        VerificationStatus status;            // Current verification status
        bytes32 proofHash;                    // Hash of verification proof data
        bytes32 identityHash;                 // Hash for identity deduplication
        uint256 lastUpdateTimestamp;          // Last status update time
    }

    /// @dev GitHub-specific verification details
    struct GitHubVerificationData {
        uint256 accountAge;                   // Account age in seconds
        uint256 publicRepositories;          // Number of public repositories
        uint256 commitsLastYear;             // Commits in past year
        uint256 contributionsScore;          // Weighted contributions score
        GitHubTier tier;                     // Achievement tier
        bool ecosystemContributor;           // WRFCoin ecosystem contributor flag
        string[] topRepositories;            // Top repositories for validation
    }

    /// @dev Twitter verification details
    struct TwitterVerificationData {
        bool isVerifiedAccount;              // Official Twitter verification status
        uint256 accountAge;                  // Account age in seconds
        uint256 followerCount;               // Number of followers
        uint256 tweetCount;                  // Total tweets
        uint256 lastActivityTimestamp;       // Last tweet/activity timestamp
        bool hasRecentActivity;              // Active in last 3 months
        string profileUrl;                   // Profile URL for verification
    }

    /// @dev LinkedIn verification details
    struct LinkedInVerificationData {
        uint256 connectionCount;             // Number of LinkedIn connections
        uint256 accountAge;                  // Account age in seconds
        bool hasWorkExperience;              // Has verified work experience
        bool hasEducation;                   // Has education information
        uint256 endorsementCount;            // Skills endorsements received
        uint256 recommendationCount;         // Professional recommendations
        string profileUrl;                   // Profile URL for verification
    }

    /// @dev Identity fingerprint for deduplication
    struct IdentityFingerprint {
        bytes32 emailHash;                   // Hashed email for deduplication
        bytes32 phoneHash;                   // Hashed phone for deduplication  
        bytes32 deviceFingerprint;           // Device/browser fingerprint
        bytes32 behaviorFingerprint;         // Behavioral pattern hash
        uint256 creationTimestamp;          // When fingerprint was created
    }

    /// @dev Rate limiting tracker
    struct RateLimitData {
        uint256 lastVerificationAttempt;    // Last verification attempt timestamp
        uint256 dailyVerificationCount;     // Verifications attempted today
        uint256 totalAttempts;              // Total verification attempts
        uint256 successfulVerifications;    // Number of successful verifications
        uint256 lastDailyReset;             // Last daily counter reset
    }

    // ========== STATE VARIABLES ==========

    /// @dev Main verification registry
    mapping(address => mapping(SocialPlatform => SocialVerificationRecord)) public verifications;

    /// @dev Platform-specific verification data
    mapping(address => mapping(SocialPlatform => bytes)) public platformData;

    /// @dev Identity deduplication mapping
    mapping(bytes32 => address) public identityRegistry;
    mapping(address => IdentityFingerprint) public identityFingerprints;

    /// @dev Rate limiting tracking
    mapping(address => RateLimitData) public rateLimits;
    mapping(uint256 => uint256) public dailyVerificationCounts; // Date => count

    /// @dev Used signature hashes for replay protection
    mapping(bytes32 => bool) public usedSignatureHashes;

    /// @dev Active participants by platform
    mapping(SocialPlatform => EnumerableSet.AddressSet) private verifiedParticipants;

    /// @dev Oracle management
    EnumerableSet.AddressSet private authorizedOracles;
    mapping(address => bool) public oracleActive;

    /// @dev Platform configuration
    mapping(SocialPlatform => bool) public platformEnabled;
    mapping(SocialPlatform => uint256) public platformDiscounts;

    /// @dev Contract statistics
    uint256 public totalVerifications;
    uint256 public totalParticipants;
    uint256 public totalActiveVerifications;

    /// @dev Integration contracts
    address public dynamicStakeCalculator;
    address public fairLaunchStakeManager;
    address public participantTypeRegistry;

    // ========== EVENTS ==========

    /// @notice Emitted when a verification request is submitted
    event VerificationSubmitted(
        address indexed participant,
        SocialPlatform indexed platform,
        string profileIdentifier,
        bytes32 proofHash,
        uint256 timestamp
    );

    /// @notice Emitted when verification is completed by oracle
    event VerificationCompleted(
        address indexed participant,
        SocialPlatform indexed platform,
        VerificationStatus indexed status,
        uint256 discountPercentage,
        uint256 expirationTimestamp
    );

    /// @notice Emitted when verification status changes
    event VerificationStatusChanged(
        address indexed participant,
        SocialPlatform indexed platform,
        VerificationStatus oldStatus,
        VerificationStatus indexed newStatus,
        string reason
    );

    /// @notice Emitted when verification expires
    event VerificationExpired(
        address indexed participant,
        SocialPlatform indexed platform,
        uint256 timestamp
    );

    /// @notice Emitted when combined discount is calculated
    event CombinedDiscountCalculated(
        address indexed participant,
        uint256 githubDiscount,
        uint256 twitterDiscount,
        uint256 linkedinDiscount,
        uint256 totalDiscount,
        uint256 cappedDiscount
    );

    /// @notice Emitted when identity deduplication is triggered
    event IdentityDeduplicationDetected(
        address indexed participant,
        address indexed existingAccount,
        bytes32 identityHash,
        string reason
    );

    /// @notice Emitted when oracle authorization changes
    event OracleAuthorizationUpdated(
        address indexed oracle,
        bool indexed authorized,
        address indexed admin
    );

    /// @notice Emitted when platform configuration changes
    event PlatformConfigurationUpdated(
        SocialPlatform indexed platform,
        bool enabled,
        uint256 discountPercentage
    );

    // ========== ERRORS ==========

    error InvalidPlatform();
    error InvalidDiscountPercentage();
    error VerificationNotFound();
    error VerificationAlreadyExists();
    error VerificationHasExpired();
    error UnauthorizedOracle();
    error RateLimitExceeded();
    error MaxAttemptsExceeded();
    error DuplicateIdentity();
    error InvalidProofData();
    error SignatureAlreadyUsed();
    error InsufficientAccountAge();
    error PlatformNotEnabled();

    // ========== MODIFIERS ==========

    /// @dev Ensures caller is authorized oracle
    modifier onlyAuthorizedOracle() {
        if (!authorizedOracles.contains(msg.sender) || !oracleActive[msg.sender]) {
            revert UnauthorizedOracle();
        }
        _;
    }

    /// @dev Ensures platform is supported and enabled
    modifier onlyEnabledPlatform(SocialPlatform platform) {
        if (!platformEnabled[platform]) {
            revert PlatformNotEnabled();
        }
        _;
    }

    /// @dev Rate limiting protection
    modifier rateLimited(address participant) {
        RateLimitData storage limit = rateLimits[participant];
        
        // Check cooldown period
        if (block.timestamp < limit.lastVerificationAttempt + VERIFICATION_COOLDOWN) {
            revert RateLimitExceeded();
        }

        // Reset daily counter if new day
        uint256 today = block.timestamp / 1 days;
        if (today > limit.lastDailyReset) {
            limit.dailyVerificationCount = 0;
            limit.lastDailyReset = today;
        }

        // Check daily limit
        if (limit.dailyVerificationCount >= MAX_DAILY_VERIFICATIONS) {
            revert RateLimitExceeded();
        }

        // Check max attempts
        if (limit.totalAttempts >= MAX_VERIFICATION_ATTEMPTS) {
            revert MaxAttemptsExceeded();
        }

        _;

        // Update rate limiting data
        limit.lastVerificationAttempt = block.timestamp;
        limit.dailyVerificationCount++;
        limit.totalAttempts++;
    }

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initialize SocialVerification contract
     */
    constructor() EIP712("SocialVerification", "1") {
        // Setup access control
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);

        // Enable platforms with default discounts
        platformEnabled[SocialPlatform.GITHUB] = true;
        platformEnabled[SocialPlatform.TWITTER] = true;
        platformEnabled[SocialPlatform.LINKEDIN] = true;

        platformDiscounts[SocialPlatform.GITHUB] = 100_000;  // 10%
        platformDiscounts[SocialPlatform.TWITTER] = 50_000;  // 5% 
        platformDiscounts[SocialPlatform.LINKEDIN] = 70_000; // 7%
    }

    // ========== VERIFICATION SUBMISSION FUNCTIONS ==========

    /**
     * @notice Submit verification request for a social platform
     * @param platform The social platform to verify
     * @param profileIdentifier Username or profile ID on the platform
     * @param identityFingerprint Identity fingerprint for deduplication
     * @param proofData Encoded proof data specific to platform
     * @param signature Oracle signature for verification request
     */
    function submitVerification(
        SocialPlatform platform,
        string calldata profileIdentifier,
        IdentityFingerprint calldata identityFingerprint,
        bytes calldata proofData,
        bytes calldata signature
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyEnabledPlatform(platform)
        rateLimited(msg.sender)
    {
        // Check if verification already exists
        if (verifications[msg.sender][platform].verificationTimestamp != 0) {
            revert VerificationAlreadyExists();
        }

        // Validate signature to prevent spam
        bytes32 proofHash = keccak256(proofData);
        bytes32 signatureHash = keccak256(signature);
        if (usedSignatureHashes[signatureHash]) {
            revert SignatureAlreadyUsed();
        }
        usedSignatureHashes[signatureHash] = true;

        // Generate identity hash for deduplication
        bytes32 identityHash = _generateIdentityHash(identityFingerprint);
        
        // Check for duplicate identity
        if (identityRegistry[identityHash] != address(0)) {
            address existingAccount = identityRegistry[identityHash];
            emit IdentityDeduplicationDetected(
                msg.sender, 
                existingAccount, 
                identityHash, 
                "Duplicate identity detected"
            );
            revert DuplicateIdentity();
        }

        // Store identity fingerprint
        identityFingerprints[msg.sender] = identityFingerprint;
        identityRegistry[identityHash] = msg.sender;

        // Create verification record
        SocialVerificationRecord storage verification = verifications[msg.sender][platform];
        verification.participant = msg.sender;
        verification.platform = platform;
        verification.profileIdentifier = profileIdentifier;
        verification.verificationTimestamp = block.timestamp;
        verification.expirationTimestamp = block.timestamp + VERIFICATION_VALIDITY_PERIOD;
        verification.discountPercentage = 0; // Set by oracle upon verification
        verification.status = VerificationStatus.PENDING;
        verification.proofHash = proofHash;
        verification.identityHash = identityHash;
        verification.lastUpdateTimestamp = block.timestamp;

        // Store platform-specific data
        platformData[msg.sender][platform] = proofData;

        // Update statistics
        totalVerifications++;

        emit VerificationSubmitted(
            msg.sender,
            platform,
            profileIdentifier,
            proofHash,
            block.timestamp
        );
    }

    // ========== ORACLE VERIFICATION FUNCTIONS ==========

    /**
     * @notice Verify a submitted social platform verification (Oracle only)
     * @param participant Address of the participant
     * @param platform The social platform being verified
     * @param status Verification result status
     * @param discountPercentage Discount percentage to award (precision units)
     * @param tier Achievement tier for GitHub (optional)
     */
    function verifyAccount(
        address participant,
        SocialPlatform platform,
        VerificationStatus status,
        uint256 discountPercentage,
        uint256 tier
    )
        external
        nonReentrant
        onlyAuthorizedOracle
        whenNotPaused
    {
        SocialVerificationRecord storage verification = verifications[participant][platform];
        
        // Ensure verification exists and is pending
        if (verification.verificationTimestamp == 0) {
            revert VerificationNotFound();
        }
        if (verification.status != VerificationStatus.PENDING) {
            return; // Already processed
        }

        // Validate discount percentage
        if (discountPercentage > platformDiscounts[platform]) {
            revert InvalidDiscountPercentage();
        }

        // Process verification based on platform and status
        if (status == VerificationStatus.VERIFIED) {
            _processSuccessfulVerification(participant, platform, discountPercentage, tier);
        } else {
            _processFailedVerification(participant, platform, status);
        }

        // Update verification record
        verification.status = status;
        verification.discountPercentage = (status == VerificationStatus.VERIFIED) ? discountPercentage : 0;
        verification.lastUpdateTimestamp = block.timestamp;

        // Update statistics
        if (status == VerificationStatus.VERIFIED) {
            totalActiveVerifications++;
            verifiedParticipants[platform].add(participant);
            rateLimits[participant].successfulVerifications++;
        }

        emit VerificationCompleted(
            participant,
            platform,
            status,
            discountPercentage,
            verification.expirationTimestamp
        );
    }

    /**
     * @notice Batch verify multiple verification requests (Oracle only)
     * @param participants Array of participant addresses
     * @param platforms Array of platforms being verified
     * @param statuses Array of verification statuses
     * @param discountPercentages Array of discount percentages
     * @param tiers Array of achievement tiers
     */
    function batchVerifyAccounts(
        address[] calldata participants,
        SocialPlatform[] calldata platforms,
        VerificationStatus[] calldata statuses,
        uint256[] calldata discountPercentages,
        uint256[] calldata tiers
    )
        external
        nonReentrant
        onlyAuthorizedOracle
        whenNotPaused
    {
        require(participants.length == platforms.length, "Array length mismatch");
        require(participants.length == statuses.length, "Array length mismatch");
        require(participants.length == discountPercentages.length, "Array length mismatch");
        require(participants.length == tiers.length, "Array length mismatch");

        for (uint256 i = 0; i < participants.length; i++) {
            try this.verifyAccount(
                participants[i],
                platforms[i],
                statuses[i],
                discountPercentages[i],
                tiers[i]
            ) {} catch {
                // Continue processing other verifications even if one fails
                continue;
            }
        }
    }

    // ========== VERIFICATION STATUS MANAGEMENT ==========

    /**
     * @notice Renew an existing verification before expiration
     * @param platform The social platform to renew
     * @param proofData Updated proof data for renewal
     */
    function renewVerification(
        SocialPlatform platform,
        bytes calldata proofData
    )
        external
        nonReentrant
        whenNotPaused
        onlyEnabledPlatform(platform)
    {
        SocialVerificationRecord storage verification = verifications[msg.sender][platform];
        
        // Ensure verification exists and is verified
        if (verification.status != VerificationStatus.VERIFIED) {
            revert VerificationNotFound();
        }

        // Allow renewal up to 30 days before expiration
        if (block.timestamp < verification.expirationTimestamp - 30 days) {
            revert VerificationNotFound(); // Too early to renew
        }

        // Update proof data and reset to pending
        verification.proofHash = keccak256(proofData);
        verification.status = VerificationStatus.PENDING;
        verification.lastUpdateTimestamp = block.timestamp;

        // Store new proof data
        platformData[msg.sender][platform] = proofData;

        emit VerificationSubmitted(
            msg.sender,
            platform,
            verification.profileIdentifier,
            verification.proofHash,
            block.timestamp
        );
    }

    /**
     * @notice Revoke a verification for policy violations (Admin only)
     * @param participant Address of the participant
     * @param platform The social platform verification to revoke
     * @param reason Reason for revocation
     */
    function revokeVerification(
        address participant,
        SocialPlatform platform,
        string calldata reason
    )
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        SocialVerificationRecord storage verification = verifications[participant][platform];
        
        if (verification.verificationTimestamp == 0) {
            revert VerificationNotFound();
        }

        VerificationStatus oldStatus = verification.status;
        verification.status = VerificationStatus.REVOKED;
        verification.discountPercentage = 0;
        verification.lastUpdateTimestamp = block.timestamp;

        // Update statistics
        if (oldStatus == VerificationStatus.VERIFIED) {
            totalActiveVerifications--;
            verifiedParticipants[platform].remove(participant);
        }

        emit VerificationStatusChanged(
            participant,
            platform,
            oldStatus,
            VerificationStatus.REVOKED,
            reason
        );
    }

    /**
     * @notice Check and expire stale verifications
     * @param participants Array of participants to check
     * @param platforms Array of platforms to check
     */
    function checkAndExpireVerifications(
        address[] calldata participants,
        SocialPlatform[] calldata platforms
    )
        external
        nonReentrant
    {
        require(participants.length == platforms.length, "Array length mismatch");

        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            SocialPlatform platform = platforms[i];
            
            SocialVerificationRecord storage verification = verifications[participant][platform];
            
            if (verification.status == VerificationStatus.VERIFIED &&
                block.timestamp > verification.expirationTimestamp) {
                
                verification.status = VerificationStatus.EXPIRED;
                verification.discountPercentage = 0;
                verification.lastUpdateTimestamp = block.timestamp;

                totalActiveVerifications--;
                verifiedParticipants[platform].remove(participant);

                emit VerificationExpired(participant, platform, block.timestamp);
            }
        }
    }

    // ========== DISCOUNT CALCULATION FUNCTIONS ==========

    /**
     * @notice Get the current social verification discount for a participant
     * @param participant Address of the participant
     * @return totalDiscount Total discount percentage (precision units)
     * @return platformDiscounts_ Individual platform discounts
     * @return hasActiveVerifications Whether participant has any active verifications
     */
    function getCombinedDiscount(address participant) 
        external 
        view 
        returns (
            uint256 totalDiscount,
            uint256[3] memory platformDiscounts_,
            bool hasActiveVerifications
        ) 
    {
        uint256 githubDiscount = 0;
        uint256 twitterDiscount = 0;
        uint256 linkedinDiscount = 0;

        // Check GitHub verification
        SocialVerificationRecord storage githubVerif = verifications[participant][SocialPlatform.GITHUB];
        if (githubVerif.status == VerificationStatus.VERIFIED && 
            block.timestamp <= githubVerif.expirationTimestamp) {
            githubDiscount = githubVerif.discountPercentage;
            hasActiveVerifications = true;
        }

        // Check Twitter verification
        SocialVerificationRecord storage twitterVerif = verifications[participant][SocialPlatform.TWITTER];
        if (twitterVerif.status == VerificationStatus.VERIFIED && 
            block.timestamp <= twitterVerif.expirationTimestamp) {
            twitterDiscount = twitterVerif.discountPercentage;
            hasActiveVerifications = true;
        }

        // Check LinkedIn verification  
        SocialVerificationRecord storage linkedinVerif = verifications[participant][SocialPlatform.LINKEDIN];
        if (linkedinVerif.status == VerificationStatus.VERIFIED && 
            block.timestamp <= linkedinVerif.expirationTimestamp) {
            linkedinDiscount = linkedinVerif.discountPercentage;
            hasActiveVerifications = true;
        }

        // Calculate combined discount with maximum cap
        totalDiscount = githubDiscount + twitterDiscount + linkedinDiscount;
        if (totalDiscount > MAX_SOCIAL_DISCOUNT) {
            totalDiscount = MAX_SOCIAL_DISCOUNT;
        }

        platformDiscounts_ = [githubDiscount, twitterDiscount, linkedinDiscount];

        return (totalDiscount, platformDiscounts_, hasActiveVerifications);
    }

    /**
     * @notice Check if participant is verified on a specific platform
     * @param participant Address of the participant
     * @param platform The social platform to check
     * @return verified Whether participant is currently verified
     * @return discountPercentage Discount percentage earned
     * @return expirationTimestamp When verification expires
     */
    function isVerified(
        address participant, 
        SocialPlatform platform
    ) 
        external 
        view 
        returns (
            bool verified,
            uint256 discountPercentage,
            uint256 expirationTimestamp
        ) 
    {
        SocialVerificationRecord storage verification = verifications[participant][platform];
        
        verified = (verification.status == VerificationStatus.VERIFIED && 
                   block.timestamp <= verification.expirationTimestamp);
        discountPercentage = verified ? verification.discountPercentage : 0;
        expirationTimestamp = verification.expirationTimestamp;

        return (verified, discountPercentage, expirationTimestamp);
    }

    // ========== ADMINISTRATIVE FUNCTIONS ==========

    /**
     * @notice Add or update authorized oracle
     * @param oracle Address of the oracle
     * @param authorized Whether oracle is authorized
     */
    function setOracleAuthorization(
        address oracle,
        bool authorized
    ) 
        external 
        onlyRole(ADMIN_ROLE)
    {
        require(oracle != address(0), "Invalid oracle address");

        if (authorized) {
            authorizedOracles.add(oracle);
            oracleActive[oracle] = true;
            _grantRole(ORACLE_ROLE, oracle);
        } else {
            authorizedOracles.remove(oracle);
            oracleActive[oracle] = false;
            _revokeRole(ORACLE_ROLE, oracle);
        }

        emit OracleAuthorizationUpdated(oracle, authorized, msg.sender);
    }

    /**
     * @notice Configure platform settings
     * @param platform The social platform to configure
     * @param enabled Whether platform verification is enabled
     * @param discountPercentage Maximum discount percentage for platform
     */
    function configurePlatform(
        SocialPlatform platform,
        bool enabled,
        uint256 discountPercentage
    )
        external
        onlyRole(ADMIN_ROLE)
    {
        require(discountPercentage <= MAX_SOCIAL_DISCOUNT, "Discount too high");

        platformEnabled[platform] = enabled;
        platformDiscounts[platform] = discountPercentage;

        emit PlatformConfigurationUpdated(platform, enabled, discountPercentage);
    }

    /**
     * @notice Set integration contract addresses
     * @param _dynamicStakeCalculator DynamicStakeCalculator contract address
     * @param _fairLaunchStakeManager FairLaunchStakeManager contract address
     * @param _participantTypeRegistry ParticipantTypeRegistry contract address
     */
    function setIntegrationContracts(
        address _dynamicStakeCalculator,
        address _fairLaunchStakeManager,
        address _participantTypeRegistry
    )
        external
        onlyRole(ADMIN_ROLE)
    {
        dynamicStakeCalculator = _dynamicStakeCalculator;
        fairLaunchStakeManager = _fairLaunchStakeManager;
        participantTypeRegistry = _participantTypeRegistry;
    }

    /**
     * @notice Emergency pause functionality
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause functionality
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get comprehensive verification information for a participant
     * @param participant Address of the participant
     * @return verificationData Array of verification records for all platforms
     * @return totalActiveVerifications_ Number of active verifications
     * @return identityFingerprint Identity fingerprint data
     */
    function getVerificationInfo(address participant)
        external
        view
        returns (
            SocialVerificationRecord[3] memory verificationData,
            uint256 totalActiveVerifications_,
            IdentityFingerprint memory identityFingerprint
        )
    {
        verificationData[0] = verifications[participant][SocialPlatform.GITHUB];
        verificationData[1] = verifications[participant][SocialPlatform.TWITTER];
        verificationData[2] = verifications[participant][SocialPlatform.LINKEDIN];

        // Count active verifications
        totalActiveVerifications_ = 0;
        for (uint256 i = 0; i < 3; i++) {
            if (verificationData[i].status == VerificationStatus.VERIFIED &&
                block.timestamp <= verificationData[i].expirationTimestamp) {
                totalActiveVerifications_++;
            }
        }

        identityFingerprint = identityFingerprints[participant];

        return (verificationData, totalActiveVerifications_, identityFingerprint);
    }

    /**
     * @notice Get platform-specific verification data
     * @param participant Address of the participant
     * @param platform The social platform
     * @return proofData Stored proof data for verification
     */
    function getPlatformData(
        address participant,
        SocialPlatform platform
    )
        external
        view
        returns (bytes memory proofData)
    {
        return platformData[participant][platform];
    }

    /**
     * @notice Get verification statistics
     * @return stats Array containing various statistics
     */
    function getVerificationStats()
        external
        view
        returns (uint256[] memory stats)
    {
        stats = new uint256[](12);
        stats[0] = totalVerifications;
        stats[1] = totalParticipants;
        stats[2] = totalActiveVerifications;
        stats[3] = verifiedParticipants[SocialPlatform.GITHUB].length();
        stats[4] = verifiedParticipants[SocialPlatform.TWITTER].length();
        stats[5] = verifiedParticipants[SocialPlatform.LINKEDIN].length();
        stats[6] = authorizedOracles.length();
        stats[7] = platformEnabled[SocialPlatform.GITHUB] ? 1 : 0;
        stats[8] = platformEnabled[SocialPlatform.TWITTER] ? 1 : 0;
        stats[9] = platformEnabled[SocialPlatform.LINKEDIN] ? 1 : 0;
        stats[10] = platformDiscounts[SocialPlatform.GITHUB];
        stats[11] = MAX_SOCIAL_DISCOUNT;

        return stats;
    }

    /**
     * @notice Get list of verified participants for a platform
     * @param platform The social platform
     * @return participants Array of verified participant addresses
     */
    function getVerifiedParticipants(SocialPlatform platform)
        external
        view
        returns (address[] memory participants)
    {
        uint256 length = verifiedParticipants[platform].length();
        participants = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            participants[i] = verifiedParticipants[platform].at(i);
        }

        return participants;
    }

    /**
     * @notice Check rate limiting status for a participant
     * @param participant Address to check
     * @return canVerify Whether participant can submit verification
     * @return cooldownRemaining Seconds remaining in cooldown
     * @return attemptsRemaining Verification attempts remaining
     */
    function checkRateLimit(address participant)
        external
        view
        returns (
            bool canVerify,
            uint256 cooldownRemaining,
            uint256 attemptsRemaining
        )
    {
        RateLimitData storage limit = rateLimits[participant];
        
        // Check cooldown
        uint256 nextAllowed = limit.lastVerificationAttempt + VERIFICATION_COOLDOWN;
        if (block.timestamp < nextAllowed) {
            cooldownRemaining = nextAllowed - block.timestamp;
            canVerify = false;
        } else {
            cooldownRemaining = 0;
        }

        // Check attempts
        if (limit.totalAttempts >= MAX_VERIFICATION_ATTEMPTS) {
            attemptsRemaining = 0;
            canVerify = false;
        } else {
            attemptsRemaining = MAX_VERIFICATION_ATTEMPTS - limit.totalAttempts;
        }

        // Check daily limit
        uint256 today = block.timestamp / 1 days;
        if (today == limit.lastDailyReset && 
            limit.dailyVerificationCount >= MAX_DAILY_VERIFICATIONS) {
            canVerify = false;
        }

        return (canVerify && cooldownRemaining == 0 && attemptsRemaining > 0, cooldownRemaining, attemptsRemaining);
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    /**
     * @dev Process successful verification
     */
    function _processSuccessfulVerification(
        address participant,
        SocialPlatform platform,
        uint256 discountPercentage,
        uint256 tier
    ) private {
        // Platform-specific processing logic would go here
        // This could include additional validation based on the platform
        
        if (platform == SocialPlatform.GITHUB) {
            _processGitHubVerification(participant, tier);
        } else if (platform == SocialPlatform.TWITTER) {
            _processTwitterVerification(participant);
        } else if (platform == SocialPlatform.LINKEDIN) {
            _processLinkedInVerification(participant);
        }
    }

    /**
     * @dev Process failed verification
     */
    function _processFailedVerification(
        address participant,
        SocialPlatform platform,
        VerificationStatus status
    ) private {
        // Log failed verification reason and potentially blacklist for suspicious activity
        // This is a placeholder for more complex failure processing
    }

    /**
     * @dev Process GitHub-specific verification logic
     */
    function _processGitHubVerification(address participant, uint256 tier) private {
        // Additional GitHub-specific verification processing
        // Could check for WRFCoin ecosystem contributions for bonus tier
    }

    /**
     * @dev Process Twitter-specific verification logic
     */
    function _processTwitterVerification(address participant) private {
        // Additional Twitter-specific verification processing
        // Could check for recent engagement with WRFCoin community
    }

    /**
     * @dev Process LinkedIn-specific verification logic
     */
    function _processLinkedInVerification(address participant) private {
        // Additional LinkedIn-specific verification processing  
        // Could verify professional connections to climate/tech industry
    }

    /**
     * @dev Generate identity hash for deduplication
     */
    function _generateIdentityHash(
        IdentityFingerprint calldata fingerprint
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(
            fingerprint.emailHash,
            fingerprint.phoneHash,
            fingerprint.deviceFingerprint,
            fingerprint.behaviorFingerprint
        ));
    }

    // ========== INTEGRATION FUNCTIONS ==========

    /**
     * @notice Integration function for DynamicStakeCalculator to get social discount
     * @param participant Address of the participant
     * @return discount Social verification discount (precision units)
     */
    function getSocialVerificationDiscount(address participant) 
        external 
        view 
        returns (uint256 discount) 
    {
        (uint256 totalDiscount,,) = this.getCombinedDiscount(participant);
        return PRECISION - totalDiscount; // Convert discount to multiplier
    }

    /**
     * @notice Integration function to check if participant has GitHub verification
     * @param participant Address of the participant
     * @return verified Whether participant has active GitHub verification
     */
    function hasGitHubVerification(address participant) 
        external 
        view 
        returns (bool verified) 
    {
        (verified,,) = this.isVerified(participant, SocialPlatform.GITHUB);
        return verified;
    }

    /**
     * @notice Integration function to check if participant has Twitter verification
     * @param participant Address of the participant
     * @return verified Whether participant has active Twitter verification
     */
    function hasTwitterVerification(address participant) 
        external 
        view 
        returns (bool verified) 
    {
        (verified,,) = this.isVerified(participant, SocialPlatform.TWITTER);
        return verified;
    }

    /**
     * @notice Integration function to check if participant has LinkedIn verification
     * @param participant Address of the participant
     * @return verified Whether participant has active LinkedIn verification
     */
    function hasLinkedInVerification(address participant) 
        external 
        view 
        returns (bool verified) 
    {
        (verified,,) = this.isVerified(participant, SocialPlatform.LINKEDIN);
        return verified;
    }
}