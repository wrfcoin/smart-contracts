// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./interfaces/IMultiAssetStaking.sol";
import "./interfaces/IParticipantTypeRegistry.sol";
import "./interfaces/IDynamicStakeCalculator.sol";
import "./interfaces/IWRFToken.sol";
import "./libraries/DynamicStakeCalculator.sol";

/**
 * @title StakeDelegation
 * @dev Comprehensive stake delegation contract for WRFCoin's fair launch advocate/recruiter system
 * 
 * This contract enables experienced participants (advocates) to stake on behalf of newcomers 
 * (recruits) using a structured word-of-mouth recruitment strategy. It provides:
 * 
 * Core Features:
 * - Advocates stake for recruits, removing barriers to entry
 * - Referral link generation with unique tracking codes
 * - Graduated earnings allocation during stake repayment period
 * - Performance-based reputation system for advocates
 * - Anti-gaming measures to prevent fake recruitment
 * - Economic incentives for both advocates and recruits
 * 
 * Economic Model:
 * - Recruit earnings allocation: 30% stake repayment, 5% advocate bonus, 2% protocol fee, 63% recruit keeps
 * - Post-independence: 100% earnings to recruit
 * - Advocate delegation limits based on reputation score
 * - Stake recovery mechanisms for defaulted recruits
 * 
 * Security Features:
 * - EIP-712 signature verification for referral links
 * - Reputation-based delegation limits
 * - Anti-Sybil attack protection
 * - Emergency termination capabilities
 * - Comprehensive audit trail via events
 * 
 * Integration Points:
 * - MultiAssetStaking: Handle various collateral types
 * - ParticipantTypeRegistry: Track recruit participation
 * - DynamicStakeCalculator: Calculate stake requirements
 * - WRFToken: Process earnings and rewards
 * 
 * @author WRFCoin Security Team
 * @notice Production-ready delegation system for viral network growth
 */
contract StakeDelegation is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using ECDSA for bytes32;

    // ========== CONSTANTS ==========
    
    /// @dev Role for earnings distribution operations
    bytes32 public constant EARNINGS_DISTRIBUTOR_ROLE = keccak256("EARNINGS_DISTRIBUTOR_ROLE");
    
    /// @dev Role for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @dev Role for emergency operations
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    /// @dev Role for referral link management
    bytes32 public constant REFERRAL_MANAGER_ROLE = keccak256("REFERRAL_MANAGER_ROLE");

    /// @dev Precision for percentage calculations (100.00%)
    uint256 public constant PRECISION = 10000;
    
    /// @dev Default stake repayment percentage (30%)
    uint256 public constant DEFAULT_STAKE_REPAYMENT_RATE = 3000;
    
    /// @dev Default advocate bonus percentage (5%)
    uint256 public constant DEFAULT_ADVOCATE_BONUS_RATE = 500;
    
    /// @dev Default protocol fee percentage (2%)
    uint256 public constant DEFAULT_PROTOCOL_FEE_RATE = 200;
    
    /// @dev Maximum delegation period (1 year)
    uint256 public constant MAX_DELEGATION_PERIOD = 365 days;
    
    /// @dev Minimum delegation period (30 days)
    uint256 public constant MIN_DELEGATION_PERIOD = 30 days;
    
    /// @dev Default maximum delegations per advocate
    uint256 public constant DEFAULT_MAX_DELEGATIONS_PER_ADVOCATE = 10;
    
    /// @dev Minimum reputation score for advocates
    uint256 public constant MIN_ADVOCATE_REPUTATION = 7000; // 70%
    
    /// @dev Maximum reputation score
    uint256 public constant MAX_REPUTATION_SCORE = 10000; // 100%
    
    /// @dev Referral code length
    uint256 public constant REFERRAL_CODE_LENGTH = 8;
    
    /// @dev Referral link expiration period (30 days)
    uint256 public constant REFERRAL_LINK_EXPIRATION = 30 days;
    uint256 public constant MIN_REFERRAL_STAKE = 1e16; // 0.01 ETH — anti-spam floor

    /// @dev EIP-712 typehash for referral signatures
    bytes32 public constant REFERRAL_TYPEHASH = keccak256(
        "ReferralLink(address advocate,string referralCode,uint256 nonce,uint256 deadline,uint256 stakeAmount,address stakeAsset)"
    );

    // ========== ENUMS ==========

    /// @dev Delegation relationship status
    enum DelegationStatus {
        ACTIVE,        // Stake being repaid by recruit
        COMPLETED,     // Recruit achieved independence
        DEFAULTED,     // Recruit stopped participating
        TERMINATED     // Relationship ended early
    }

    /// @dev Reputation score tiers
    enum ReputationTier {
        NOVICE,        // < 70% success rate
        EXPERIENCED,   // 70-85% success rate
        EXPERT,        // 85-95% success rate
        MASTER         // > 95% success rate
    }

    // ========== STRUCTS ==========

    /// @dev Individual delegation relationship
    struct DelegationRelationship {
        address advocate;              // Address of the advocate
        address recruit;               // Address of the recruit
        address stakeAsset;            // Asset used for stake
        uint256 stakeAmount;           // Original stake amount
        uint256 stakeRepaid;           // Amount already repaid
        uint256 advocateRewardsEarned; // Total rewards earned by advocate
        uint256 recruitEarnings;       // Total earnings by recruit
        uint256 delegationStartTime;   // When delegation started
        uint256 independenceTime;      // When recruit became independent (0 if still active)
        uint256 lastEarningsUpdate;    // Last earnings processing timestamp
        DelegationStatus status;       // Current status
        string referralCode;           // Original referral code used
        uint256 expectedRepaymentPeriod; // Expected time for full repayment
        bytes32 delegationId;          // Unique delegation identifier
    }

    /// @dev Advocate profile and statistics
    struct AdvocateProfile {
        address advocate;                    // Advocate address
        uint256 totalDelegations;            // Total delegations created
        uint256 activeDelegations;           // Currently active delegations
        uint256 successfulDelegations;       // Completed successful delegations
        uint256 defaultedDelegations;        // Failed/defaulted delegations
        uint256 totalRewardsEarned;          // Lifetime rewards earned
        uint256 totalStakeProvided;          // Total stake provided
        uint256 totalStakeRecovered;         // Total stake recovered
        uint256 maxDelegations;              // Current delegation limit
        uint256 reputationScore;             // Current reputation (0-10000)
        uint256 lastReputationUpdate;        // Last reputation calculation
        ReputationTier reputationTier;       // Current reputation tier
        bool isActive;                       // Whether advocate is active
        uint256 joinedAt;                    // When advocate started
        EnumerableSet.Bytes32Set delegationIds; // Set of delegation IDs
    }

    /// @dev Referral link information
    struct ReferralLink {
        address advocate;           // Advocate who created the link
        string referralCode;        // Unique referral code
        uint256 createdAt;         // Creation timestamp
        uint256 expiresAt;         // Expiration timestamp
        uint256 usageCount;        // Number of times used
        uint256 maxUsage;          // Maximum allowed usage (0 = unlimited)
        uint256 stakeAmount;       // Stake amount for this link
        address stakeAsset;        // Asset for stake
        bool isActive;             // Whether link is active
        bytes32 linkHash;          // Hash of link parameters
    }

    /// @dev Earnings processing parameters
    struct EarningsAllocation {
        uint256 stakeRepaymentAmount;  // Amount going to stake repayment
        uint256 advocateBonusAmount;   // Amount going to advocate
        uint256 protocolFeeAmount;     // Amount going to protocol
        uint256 recruitKeepsAmount;    // Amount recruit keeps
        uint256 totalProcessed;        // Total earnings processed
    }

    // ========== STATE VARIABLES ==========

    /// @dev MultiAssetStaking contract interface
    IMultiAssetStaking public immutable multiAssetStaking;
    
    /// @dev ParticipantTypeRegistry contract interface
    IParticipantTypeRegistry public immutable participantTypeRegistry;
    
    /// @dev DynamicStakeCalculator contract interface
    IDynamicStakeCalculator public immutable dynamicStakeCalculator;
    
    /// @dev WRFToken contract interface
    IWRFToken public immutable wrfToken;

    /// @dev Protocol treasury address
    address public protocolTreasury;

    /// @dev Current stake repayment rate
    uint256 public stakeRepaymentRate;
    
    /// @dev Current advocate bonus rate
    uint256 public advocateBonusRate;
    
    /// @dev Current protocol fee rate
    uint256 public protocolFeeRate;

    /// @dev Default maximum delegations per advocate
    uint256 public maxDelegationsPerAdvocate;

    /// @dev Mapping from delegation ID to relationship details
    mapping(bytes32 => DelegationRelationship) public delegations;

    /// @dev Mapping from advocate address to profile
    mapping(address => AdvocateProfile) internal advocateProfiles;

    /// @dev Mapping from recruit address to delegation ID
    mapping(address => bytes32) public recruitToDelegation;

    /// @dev Mapping from referral code to link information
    mapping(string => ReferralLink) public referralLinks;

    /// @dev Mapping from advocate to their referral codes
    mapping(address => EnumerableSet.Bytes32Set) private advocateReferralCodes;

    /// @dev Mapping for nonce tracking (anti-replay)
    mapping(address => uint256) public nonces;

    /// @dev Set of all delegation IDs
    EnumerableSet.Bytes32Set private allDelegationIds;

    /// @dev Set of all active advocates
    EnumerableSet.AddressSet private activeAdvocates;

    /// @dev Total delegations created
    uint256 public totalDelegationsCreated;

    /// @dev Total stake currently delegated
    uint256 public totalStakeDelegated;

    /// @dev Total rewards distributed to advocates
    uint256 public totalAdvocateRewards;

    /// @dev Total protocol fees collected
    uint256 public totalProtocolFeesCollected;

    // ========== EVENTS ==========

    event ReferralLinkCreated(
        address indexed advocate,
        string referralCode,
        uint256 stakeAmount,
        address stakeAsset,
        uint256 expiresAt
    );

    event DelegationCreated(
        bytes32 indexed delegationId,
        address indexed advocate,
        address indexed recruit,
        address stakeAsset,
        uint256 stakeAmount,
        string referralCode
    );

    event EarningsProcessed(
        bytes32 indexed delegationId,
        address indexed recruit,
        uint256 totalEarnings,
        uint256 stakeRepaymentAmount,
        uint256 advocateBonusAmount,
        uint256 protocolFeeAmount,
        uint256 recruitKeepsAmount
    );

    event StakeRepaid(
        bytes32 indexed delegationId,
        address indexed recruit,
        uint256 repaidAmount,
        uint256 totalRepaid,
        uint256 remainingStake
    );

    event IndependenceAchieved(
        bytes32 indexed delegationId,
        address indexed recruit,
        uint256 totalRepaid,
        uint256 timeToIndependence
    );

    event DelegationTerminated(
        bytes32 indexed delegationId,
        address indexed advocate,
        address indexed recruit,
        DelegationStatus finalStatus,
        uint256 stakeRecovered,
        string reason
    );

    event AdvocateReputationUpdated(
        address indexed advocate,
        uint256 oldScore,
        uint256 newScore,
        ReputationTier oldTier,
        ReputationTier newTier,
        uint256 newMaxDelegations
    );

    event StakeRecovered(
        bytes32 indexed delegationId,
        address indexed advocate,
        uint256 recoveredAmount,
        string reason
    );

    event ReferralLinkUsed(
        string referralCode,
        address indexed advocate,
        address indexed recruit,
        bytes32 delegationId
    );

    // ========== CONSTRUCTOR ==========

    constructor(
        address _multiAssetStaking,
        address _participantTypeRegistry,
        address _dynamicStakeCalculator,
        address _wrfToken,
        address _protocolTreasury
    ) EIP712("WRFCoin StakeDelegation", "1") {
        require(_multiAssetStaking != address(0), "Invalid MultiAssetStaking address");
        require(_participantTypeRegistry != address(0), "Invalid ParticipantTypeRegistry address");
        require(_dynamicStakeCalculator != address(0), "Invalid DynamicStakeCalculator address");
        require(_wrfToken != address(0), "Invalid WRFToken address");
        require(_protocolTreasury != address(0), "Invalid protocol treasury address");

        multiAssetStaking = IMultiAssetStaking(_multiAssetStaking);
        participantTypeRegistry = IParticipantTypeRegistry(_participantTypeRegistry);
        dynamicStakeCalculator = IDynamicStakeCalculator(_dynamicStakeCalculator);
        wrfToken = IWRFToken(_wrfToken);
        protocolTreasury = _protocolTreasury;

        // Set default rates
        stakeRepaymentRate = DEFAULT_STAKE_REPAYMENT_RATE;
        advocateBonusRate = DEFAULT_ADVOCATE_BONUS_RATE;
        protocolFeeRate = DEFAULT_PROTOCOL_FEE_RATE;
        maxDelegationsPerAdvocate = DEFAULT_MAX_DELEGATIONS_PER_ADVOCATE;

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(REFERRAL_MANAGER_ROLE, msg.sender);
    }

    // ========== REFERRAL LINK MANAGEMENT ==========

    /**
     * @notice Create a referral link for recruiting new participants
     * @param referralCode Unique referral code
     * @param stakeAmount Amount to stake for recruits
     * @param stakeAsset Asset to use for staking
     * @param maxUsage Maximum times this link can be used (0 = unlimited)
     * @return linkHash Hash of the created referral link
     */
    function createReferralLink(
        string calldata referralCode,
        uint256 stakeAmount,
        address stakeAsset,
        uint256 maxUsage
    ) external whenNotPaused nonReentrant returns (bytes32 linkHash) {
        require(bytes(referralCode).length == REFERRAL_CODE_LENGTH, "Invalid referral code length");
        (uint256 calcMin, ) = dynamicStakeCalculator.getStakeBounds();
        uint256 floor = calcMin > 0 ? calcMin : MIN_REFERRAL_STAKE;
        require(stakeAmount >= floor, "StakeDelegation: stake below protocol minimum");
        require(referralLinks[referralCode].advocate == address(0), "Referral code already exists");

        // Ensure advocate meets requirements
        _ensureValidAdvocate(msg.sender);
        
        // Check delegation limits
        AdvocateProfile storage profile = advocateProfiles[msg.sender];
        require(
            profile.activeDelegations < profile.maxDelegations,
            "Advocate delegation limit reached"
        );

        // Verify advocate has sufficient balance for stake
        if (stakeAsset == address(0)) {
            // ETH
            require(msg.sender.balance >= stakeAmount, "Insufficient ETH balance");
        } else {
            // ERC20
            require(
                IERC20(stakeAsset).balanceOf(msg.sender) >= stakeAmount,
                "Insufficient token balance"
            );
        }

        // Generate link hash
        linkHash = keccak256(
            abi.encodePacked(
                msg.sender,
                referralCode,
                stakeAmount,
                stakeAsset,
                block.timestamp,
                nonces[msg.sender]++
            )
        );

        // Create referral link
        uint256 expiresAt = block.timestamp + REFERRAL_LINK_EXPIRATION;
        referralLinks[referralCode] = ReferralLink({
            advocate: msg.sender,
            referralCode: referralCode,
            createdAt: block.timestamp,
            expiresAt: expiresAt,
            usageCount: 0,
            maxUsage: maxUsage,
            stakeAmount: stakeAmount,
            stakeAsset: stakeAsset,
            isActive: true,
            linkHash: linkHash
        });

        // Track referral code for advocate
        advocateReferralCodes[msg.sender].add(linkHash);

        emit ReferralLinkCreated(
            msg.sender,
            referralCode,
            stakeAmount,
            stakeAsset,
            expiresAt
        );
    }

    /**
     * @notice Use a referral link to register with delegated stake
     * @param referralCode The referral code to use
     * @param signature EIP-712 signature from the advocate
     * @return delegationId The created delegation relationship ID
     */
    function useReferralLink(
        string calldata referralCode,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (bytes32 delegationId) {
        ReferralLink storage link = referralLinks[referralCode];
        require(link.advocate != address(0), "Referral code does not exist");
        require(link.isActive, "Referral link is not active");
        require(block.timestamp <= link.expiresAt, "Referral link has expired");
        require(link.maxUsage == 0 || link.usageCount < link.maxUsage, "Referral link usage limit reached");
        require(recruitToDelegation[msg.sender] == bytes32(0), "Recruit already has delegation");

        // Verify EIP-712 signature
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REFERRAL_TYPEHASH,
                    link.advocate,
                    keccak256(bytes(referralCode)),
                    nonces[link.advocate],
                    link.expiresAt,
                    link.stakeAmount,
                    link.stakeAsset
                )
            )
        );
        
        address recoveredSigner = digest.recover(signature);
        require(recoveredSigner == link.advocate, "Invalid signature");

        // Create delegation
        delegationId = _createDelegation(
            link.advocate,
            msg.sender,
            link.stakeAsset,
            link.stakeAmount,
            referralCode
        );

        // Update link usage
        link.usageCount++;
        
        // Deactivate if max usage reached
        if (link.maxUsage > 0 && link.usageCount >= link.maxUsage) {
            link.isActive = false;
        }

        emit ReferralLinkUsed(referralCode, link.advocate, msg.sender, delegationId);
    }

    // ========== DELEGATION MANAGEMENT ==========

    /**
     * @notice Create a delegation relationship (internal)
     * @param advocate Address of the advocate
     * @param recruit Address of the recruit
     * @param stakeAsset Asset to use for staking
     * @param stakeAmount Amount to stake
     * @param referralCode Referral code used
     * @return delegationId Created delegation ID
     */
    function _createDelegation(
        address advocate,
        address recruit,
        address stakeAsset,
        uint256 stakeAmount,
        string memory referralCode
    ) internal returns (bytes32 delegationId) {
        // Generate unique delegation ID
        delegationId = keccak256(
            abi.encodePacked(
                advocate,
                recruit,
                stakeAsset,
                stakeAmount,
                block.timestamp,
                totalDelegationsCreated
            )
        );

        // Calculate expected repayment period based on recruit type
        uint256 expectedPeriod = _calculateExpectedRepaymentPeriod(recruit, stakeAmount);

        // Create delegation relationship
        delegations[delegationId] = DelegationRelationship({
            advocate: advocate,
            recruit: recruit,
            stakeAsset: stakeAsset,
            stakeAmount: stakeAmount,
            stakeRepaid: 0,
            advocateRewardsEarned: 0,
            recruitEarnings: 0,
            delegationStartTime: block.timestamp,
            independenceTime: 0,
            lastEarningsUpdate: block.timestamp,
            status: DelegationStatus.ACTIVE,
            referralCode: referralCode,
            expectedRepaymentPeriod: expectedPeriod,
            delegationId: delegationId
        });

        // Update mappings and sets
        recruitToDelegation[recruit] = delegationId;
        allDelegationIds.add(delegationId);

        // Update advocate profile
        AdvocateProfile storage profile = advocateProfiles[advocate];
        profile.activeDelegations++;
        profile.totalDelegations++;
        profile.totalStakeProvided += stakeAmount;
        profile.delegationIds.add(delegationId);

        // Add to active advocates if not already there
        activeAdvocates.add(advocate);

        // Transfer stake from advocate to contract
        _transferStakeToContract(advocate, stakeAsset, stakeAmount);

        // Update global counters
        totalDelegationsCreated++;
        totalStakeDelegated += stakeAmount;

        emit DelegationCreated(
            delegationId,
            advocate,
            recruit,
            stakeAsset,
            stakeAmount,
            referralCode
        );
    }

    /**
     * @notice Process earnings for a recruit in a delegation relationship
     * @param recruit Address of the recruit
     * @param totalEarnings Total earnings amount to process
     */
    function processRecruitEarnings(
        address recruit,
        uint256 totalEarnings
    ) external whenNotPaused nonReentrant onlyRole(EARNINGS_DISTRIBUTOR_ROLE) {
        require(totalEarnings > 0, "Earnings must be greater than 0");
        
        bytes32 delegationId = recruitToDelegation[recruit];
        require(delegationId != bytes32(0), "No delegation found for recruit");

        DelegationRelationship storage delegation = delegations[delegationId];
        require(delegation.status == DelegationStatus.ACTIVE, "Delegation not active");

        // Calculate earnings allocation
        EarningsAllocation memory allocation = _calculateEarningsAllocation(
            delegation,
            totalEarnings
        );

        // Update delegation state
        delegation.recruitEarnings += totalEarnings;
        delegation.stakeRepaid += allocation.stakeRepaymentAmount;
        delegation.advocateRewardsEarned += allocation.advocateBonusAmount;
        delegation.lastEarningsUpdate = block.timestamp;

        // Update advocate rewards
        advocateProfiles[delegation.advocate].totalRewardsEarned += allocation.advocateBonusAmount;

        // Update global counters
        totalAdvocateRewards += allocation.advocateBonusAmount;
        totalProtocolFeesCollected += allocation.protocolFeeAmount;

        // Distribute payments
        _distributeEarnings(delegation, allocation);

        emit EarningsProcessed(
            delegationId,
            recruit,
            totalEarnings,
            allocation.stakeRepaymentAmount,
            allocation.advocateBonusAmount,
            allocation.protocolFeeAmount,
            allocation.recruitKeepsAmount
        );

        emit StakeRepaid(
            delegationId,
            recruit,
            allocation.stakeRepaymentAmount,
            delegation.stakeRepaid,
            delegation.stakeAmount - delegation.stakeRepaid
        );

        // Check if recruit has achieved independence
        if (delegation.stakeRepaid >= delegation.stakeAmount) {
            _achieveIndependence(delegationId);
        }
    }

    /**
     * @notice Achieve independence for a recruit (internal)
     * @param delegationId The delegation ID
     */
    function _achieveIndependence(bytes32 delegationId) internal {
        DelegationRelationship storage delegation = delegations[delegationId];
        require(delegation.status == DelegationStatus.ACTIVE, "Delegation not active");
        require(delegation.stakeRepaid >= delegation.stakeAmount, "Stake not fully repaid");

        // Update delegation status
        delegation.status = DelegationStatus.COMPLETED;
        delegation.independenceTime = block.timestamp;

        // Update advocate profile
        AdvocateProfile storage profile = advocateProfiles[delegation.advocate];
        profile.activeDelegations--;
        profile.successfulDelegations++;

        // Update reputation
        _updateAdvocateReputation(delegation.advocate);

        // Update global counter
        totalStakeDelegated -= delegation.stakeAmount;

        uint256 timeToIndependence = block.timestamp - delegation.delegationStartTime;

        emit IndependenceAchieved(
            delegationId,
            delegation.recruit,
            delegation.stakeRepaid,
            timeToIndependence
        );
    }

    /**
     * @notice Terminate a delegation relationship
     * @param delegationId The delegation ID to terminate
     * @param reason Reason for termination
     */
    function terminateDelegation(
        bytes32 delegationId,
        string calldata reason
    ) external whenNotPaused nonReentrant {
        DelegationRelationship storage delegation = delegations[delegationId];
        require(delegation.advocate != address(0), "Delegation does not exist");
        require(delegation.status == DelegationStatus.ACTIVE, "Delegation not active");
        
        // Only advocate, recruit, or admin can terminate
        require(
            msg.sender == delegation.advocate ||
            msg.sender == delegation.recruit ||
            hasRole(ADMIN_ROLE, msg.sender),
            "Not authorized to terminate"
        );

        // Calculate stake recovery amount
        uint256 stakeRecovered = 0;
        if (delegation.stakeRepaid < delegation.stakeAmount) {
            stakeRecovered = delegation.stakeAmount - delegation.stakeRepaid;
        }

        // ── Effects (all state changes before any external call) ──────────────

        // Update delegation status
        delegation.status = msg.sender == delegation.advocate ?
            DelegationStatus.TERMINATED : DelegationStatus.DEFAULTED;

        // Update advocate profile
        AdvocateProfile storage profile = advocateProfiles[delegation.advocate];
        profile.activeDelegations--;
        profile.totalStakeRecovered += stakeRecovered;

        if (delegation.status == DelegationStatus.DEFAULTED) {
            profile.defaultedDelegations++;
        }

        // Update reputation
        _updateAdvocateReputation(delegation.advocate);

        // Update global counter
        totalStakeDelegated -= stakeRecovered;

        // Clear recruit mapping
        delete recruitToDelegation[delegation.recruit];

        emit DelegationTerminated(
            delegationId,
            delegation.advocate,
            delegation.recruit,
            delegation.status,
            stakeRecovered,
            reason
        );

        if (stakeRecovered > 0) {
            emit StakeRecovered(delegationId, delegation.advocate, stakeRecovered, reason);
        }

        // ── Interactions (external call after all state changes) ──────────────

        // Return remaining stake to advocate (CEI: interaction last)
        if (stakeRecovered > 0) {
            _returnStakeToAdvocate(
                delegation.advocate,
                delegation.stakeAsset,
                stakeRecovered
            );
        }
    }

    // ========== REPUTATION SYSTEM ==========

    /**
     * @notice Update advocate reputation based on performance
     * @param advocate Address of the advocate
     */
    function _updateAdvocateReputation(address advocate) internal {
        AdvocateProfile storage profile = advocateProfiles[advocate];
        
        if (profile.totalDelegations == 0) {
            return;
        }

        // Calculate success rate
        uint256 successRate = (profile.successfulDelegations * PRECISION) / profile.totalDelegations;
        
        // Calculate network effect bonus (if advocates recruit other advocates)
        uint256 networkBonus = 0; // Could be implemented based on recruit advocacy performance
        
        // Calculate participation quality (based on average recruit performance)
        uint256 qualityBonus = 0; // Could be implemented based on recruit earnings/participation
        
        // Calculate base reputation score
        uint256 oldScore = profile.reputationScore;
        uint256 newScore = successRate + networkBonus + qualityBonus;
        
        // Cap at maximum
        if (newScore > MAX_REPUTATION_SCORE) {
            newScore = MAX_REPUTATION_SCORE;
        }

        // Apply penalties for defaults
        if (profile.defaultedDelegations > 0) {
            uint256 defaultPenalty = (profile.defaultedDelegations * 1000) / profile.totalDelegations;
            if (newScore > defaultPenalty) {
                newScore -= defaultPenalty;
            } else {
                newScore = 0;
            }
        }

        profile.reputationScore = newScore;
        profile.lastReputationUpdate = block.timestamp;

        // Update reputation tier and delegation limits
        ReputationTier oldTier = profile.reputationTier;
        ReputationTier newTier = _calculateReputationTier(newScore);
        profile.reputationTier = newTier;
        
        uint256 newMaxDelegations = _calculateMaxDelegations(newTier, newScore);
        profile.maxDelegations = newMaxDelegations;

        emit AdvocateReputationUpdated(
            advocate,
            oldScore,
            newScore,
            oldTier,
            newTier,
            newMaxDelegations
        );
    }

    /**
     * @notice Calculate reputation tier based on score
     * @param score Reputation score
     * @return tier Reputation tier
     */
    function _calculateReputationTier(uint256 score) internal pure returns (ReputationTier tier) {
        if (score >= 9500) {
            return ReputationTier.MASTER;
        } else if (score >= 8500) {
            return ReputationTier.EXPERT;
        } else if (score >= 7000) {
            return ReputationTier.EXPERIENCED;
        } else {
            return ReputationTier.NOVICE;
        }
    }

    /**
     * @notice Calculate maximum delegations based on reputation
     * @param tier Reputation tier
     * @param score Exact reputation score
     * @return maxDelegations Maximum allowed delegations
     */
    function _calculateMaxDelegations(
        ReputationTier tier,
        uint256 score
    ) internal view returns (uint256 maxDelegations) {
        uint256 baseLimit = maxDelegationsPerAdvocate;
        
        if (tier == ReputationTier.MASTER) {
            return baseLimit * 5; // 50 delegations
        } else if (tier == ReputationTier.EXPERT) {
            return baseLimit * 3; // 30 delegations
        } else if (tier == ReputationTier.EXPERIENCED) {
            return baseLimit * 2; // 20 delegations
        } else {
            return baseLimit; // 10 delegations
        }
    }

    // ========== HELPER FUNCTIONS ==========

    /**
     * @notice Ensure advocate meets requirements
     * @param advocate Address to check
     */
    function _ensureValidAdvocate(address advocate) internal {
        // Check if already initialized
        if (advocateProfiles[advocate].advocate == address(0)) {
            // Initialize new advocate
            AdvocateProfile storage profile = advocateProfiles[advocate];
            profile.advocate = advocate;
            profile.reputationScore = 7000; // Start at minimum
            profile.reputationTier = ReputationTier.EXPERIENCED;
            profile.maxDelegations = maxDelegationsPerAdvocate;
            profile.isActive = true;
            profile.joinedAt = block.timestamp;
        }

        AdvocateProfile storage profile = advocateProfiles[advocate];
        require(profile.isActive, "Advocate is not active");
        require(profile.reputationScore >= MIN_ADVOCATE_REPUTATION, "Insufficient reputation");
    }

    /**
     * @notice Calculate expected repayment period
     * @param recruit Address of recruit
     * @param stakeAmount Stake amount
     * @return period Expected period in seconds
     */
    function _calculateExpectedRepaymentPeriod(
        address recruit,
        uint256 stakeAmount
    ) internal view returns (uint256 period) {
        // Base calculation could use DynamicStakeCalculator and ParticipantTypeRegistry
        // For now, use a simple model based on stake amount
        if (stakeAmount <= 1000 * 1e18) { // <= 1000 tokens
            return 90 days;
        } else if (stakeAmount <= 5000 * 1e18) { // <= 5000 tokens
            return 180 days;
        } else {
            return 365 days;
        }
    }

    /**
     * @notice Calculate earnings allocation
     * @param delegation Delegation relationship
     * @param totalEarnings Total earnings to allocate
     * @return allocation Earnings allocation breakdown
     */
    function _calculateEarningsAllocation(
        DelegationRelationship memory delegation,
        uint256 totalEarnings
    ) internal view returns (EarningsAllocation memory allocation) {
        // Calculate stake repayment (30% default)
        uint256 maxRepayment = delegation.stakeAmount - delegation.stakeRepaid;
        uint256 targetRepayment = (totalEarnings * stakeRepaymentRate) / PRECISION;
        allocation.stakeRepaymentAmount = maxRepayment < targetRepayment ? 
            maxRepayment : targetRepayment;

        // Calculate advocate bonus (5% default)
        allocation.advocateBonusAmount = (totalEarnings * advocateBonusRate) / PRECISION;

        // Calculate protocol fee (2% default)
        allocation.protocolFeeAmount = (totalEarnings * protocolFeeRate) / PRECISION;

        // Remaining goes to recruit
        allocation.recruitKeepsAmount = totalEarnings - 
            allocation.stakeRepaymentAmount - 
            allocation.advocateBonusAmount - 
            allocation.protocolFeeAmount;

        allocation.totalProcessed = totalEarnings;
    }

    /**
     * @notice Distribute earnings payments
     * @param delegation Delegation relationship
     * @param allocation Earnings allocation
     */
    function _distributeEarnings(
        DelegationRelationship memory delegation,
        EarningsAllocation memory allocation
    ) internal {
        // Transfer advocate bonus
        if (allocation.advocateBonusAmount > 0) {
            IERC20(address(wrfToken)).safeTransfer(delegation.advocate, allocation.advocateBonusAmount);
        }

        // Transfer protocol fee
        if (allocation.protocolFeeAmount > 0) {
            IERC20(address(wrfToken)).safeTransfer(protocolTreasury, allocation.protocolFeeAmount);
        }

        // Transfer recruit earnings
        if (allocation.recruitKeepsAmount > 0) {
            IERC20(address(wrfToken)).safeTransfer(delegation.recruit, allocation.recruitKeepsAmount);
        }

        // Stake repayment stays in contract until independence
    }

    /**
     * @notice Transfer stake from advocate to contract
     * @param advocate Advocate address
     * @param stakeAsset Asset address
     * @param amount Amount to transfer
     */
    function _transferStakeToContract(
        address advocate,
        address stakeAsset,
        uint256 amount
    ) internal {
        if (stakeAsset == address(0)) {
            // ETH - handled via payable function or separate deposit
            require(address(this).balance >= amount, "Insufficient contract ETH balance");
        } else {
            // ERC20
            IERC20(stakeAsset).safeTransferFrom(advocate, address(this), amount);
        }
    }

    /**
     * @notice Return stake to advocate
     * @param advocate Advocate address
     * @param stakeAsset Asset address
     * @param amount Amount to return
     */
    function _returnStakeToAdvocate(
        address advocate,
        address stakeAsset,
        uint256 amount
    ) internal {
        if (stakeAsset == address(0)) {
            // ETH - use call instead of transfer to avoid 2300 gas limit
            (bool success, ) = payable(advocate).call{value: amount}("");
            require(success, "StakeDelegation: ETH transfer failed");
        } else {
            // ERC20
            IERC20(stakeAsset).safeTransfer(advocate, amount);
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get delegation relationship details
     * @param delegationId Delegation ID
     * @return delegation Delegation relationship details
     */
    function getDelegation(bytes32 delegationId) 
        external 
        view 
        returns (DelegationRelationship memory delegation) 
    {
        return delegations[delegationId];
    }

    /**
     * @notice Get advocate profile
     * @param advocate Advocate address
     */
    function getAdvocateProfile(address advocate)
        external
        view
        returns (
            address advocateAddr,
            uint256 totalDelegations,
            uint256 activeDelegations,
            uint256 successfulDelegations,
            uint256 defaultedDelegations,
            uint256 totalRewardsEarned,
            uint256 totalStakeProvided,
            uint256 totalStakeRecovered,
            uint256 maxDelegations,
            uint256 reputationScore,
            ReputationTier reputationTier,
            bool isActive
        )
    {
        AdvocateProfile storage profile = advocateProfiles[advocate];
        return (
            profile.advocate,
            profile.totalDelegations,
            profile.activeDelegations,
            profile.successfulDelegations,
            profile.defaultedDelegations,
            profile.totalRewardsEarned,
            profile.totalStakeProvided,
            profile.totalStakeRecovered,
            profile.maxDelegations,
            profile.reputationScore,
            profile.reputationTier,
            profile.isActive
        );
    }

    /**
     * @notice Get advocate's delegation IDs
     * @param advocate Advocate address
     * @return delegationIds Array of delegation IDs
     */
    function getAdvocateDelegationIds(address advocate) 
        external 
        view 
        returns (bytes32[] memory delegationIds) 
    {
        AdvocateProfile storage profile = advocateProfiles[advocate];
        uint256 length = profile.delegationIds.length();
        delegationIds = new bytes32[](length);
        
        for (uint256 i = 0; i < length; i++) {
            delegationIds[i] = profile.delegationIds.at(i);
        }
    }

    /**
     * @notice Get referral link details
     * @param referralCode Referral code
     * @return link Referral link details
     */
    function getReferralLink(string calldata referralCode) 
        external 
        view 
        returns (ReferralLink memory link) 
    {
        return referralLinks[referralCode];
    }

    /**
     * @notice Check if recruit has delegation
     * @param recruit Recruit address
     * @return hasDelegate Whether recruit has active delegation
     * @return delegationId Delegation ID (if exists)
     */
    function getRecruitDelegation(address recruit) 
        external 
        view 
        returns (bool hasDelegate, bytes32 delegationId) 
    {
        delegationId = recruitToDelegation[recruit];
        hasDelegate = delegationId != bytes32(0);
    }

    /**
     * @notice Get platform statistics
     */
    function getPlatformStats() external view returns (
        uint256 totalDelegations,
        uint256 activeDelegations,
        uint256 totalStaked,
        uint256 totalAdvocateRewardsDistributed,
        uint256 totalProtocolFees,
        uint256 activeAdvocateCount
    ) {
        totalDelegations = totalDelegationsCreated;
        activeDelegations = allDelegationIds.length();
        totalStaked = totalStakeDelegated;
        totalAdvocateRewardsDistributed = totalAdvocateRewards;
        totalProtocolFees = totalProtocolFeesCollected;
        activeAdvocateCount = activeAdvocates.length();
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Update earning rates (admin only)
     * @param newStakeRepaymentRate New stake repayment rate
     * @param newAdvocateBonusRate New advocate bonus rate
     * @param newProtocolFeeRate New protocol fee rate
     */
    function updateEarningRates(
        uint256 newStakeRepaymentRate,
        uint256 newAdvocateBonusRate,
        uint256 newProtocolFeeRate
    ) external onlyRole(ADMIN_ROLE) {
        require(
            newStakeRepaymentRate + newAdvocateBonusRate + newProtocolFeeRate <= PRECISION,
            "Total rates exceed 100%"
        );
        
        stakeRepaymentRate = newStakeRepaymentRate;
        advocateBonusRate = newAdvocateBonusRate;
        protocolFeeRate = newProtocolFeeRate;
    }

    /**
     * @notice Update protocol treasury address
     * @param newTreasury New treasury address
     */
    function updateProtocolTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury address");
        protocolTreasury = newTreasury;
    }

    /**
     * @notice Update max delegations per advocate
     * @param newMaxDelegations New maximum delegations
     */
    function updateMaxDelegationsPerAdvocate(uint256 newMaxDelegations) external onlyRole(ADMIN_ROLE) {
        require(newMaxDelegations > 0, "Max delegations must be greater than 0");
        maxDelegationsPerAdvocate = newMaxDelegations;
    }

    /**
     * @notice Emergency pause contract
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Emergency unpause contract
     */
    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Manually update advocate reputation (emergency only)
     * @param advocate Advocate address
     * @param newScore New reputation score
     */
    function emergencyUpdateReputation(
        address advocate,
        uint256 newScore
    ) external onlyRole(EMERGENCY_ROLE) {
        require(newScore <= MAX_REPUTATION_SCORE, "Invalid reputation score");
        
        AdvocateProfile storage profile = advocateProfiles[advocate];
        uint256 oldScore = profile.reputationScore;
        profile.reputationScore = newScore;
        
        ReputationTier oldTier = profile.reputationTier;
        ReputationTier newTier = _calculateReputationTier(newScore);
        profile.reputationTier = newTier;
        profile.maxDelegations = _calculateMaxDelegations(newTier, newScore);

        emit AdvocateReputationUpdated(
            advocate,
            oldScore,
            newScore,
            oldTier,
            newTier,
            profile.maxDelegations
        );
    }

    // ========== RECEIVE FUNCTION ==========

    /**
     * @notice Receive ETH deposits
     */
    receive() external payable {
        // Allow ETH deposits for stake operations
    }
}
