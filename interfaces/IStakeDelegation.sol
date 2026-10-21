// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IStakeDelegation
 * @notice Interface for the StakeDelegation contract
 * @dev Defines the core functions for stake delegation operations in WRFCoin's fair launch
 */
interface IStakeDelegation {
    
    // ========== ENUMS ==========

    enum DelegationStatus {
        ACTIVE,        // Stake being repaid by recruit
        COMPLETED,     // Recruit achieved independence
        DEFAULTED,     // Recruit stopped participating
        TERMINATED     // Relationship ended early
    }

    enum ReputationTier {
        NOVICE,        // < 70% success rate
        EXPERIENCED,   // 70-85% success rate
        EXPERT,        // 85-95% success rate
        MASTER         // > 95% success rate
    }

    // ========== STRUCTS ==========

    struct DelegationRelationship {
        address advocate;
        address recruit;
        address stakeAsset;
        uint256 stakeAmount;
        uint256 stakeRepaid;
        uint256 advocateRewardsEarned;
        uint256 recruitEarnings;
        uint256 delegationStartTime;
        uint256 independenceTime;
        uint256 lastEarningsUpdate;
        DelegationStatus status;
        string referralCode;
        uint256 expectedRepaymentPeriod;
        bytes32 delegationId;
    }

    struct AdvocateProfile {
        address advocate;
        uint256 totalDelegations;
        uint256 activeDelegations;
        uint256 successfulDelegations;
        uint256 defaultedDelegations;
        uint256 totalRewardsEarned;
        uint256 totalStakeProvided;
        uint256 totalStakeRecovered;
        uint256 maxDelegations;
        uint256 reputationScore;
        uint256 lastReputationUpdate;
        ReputationTier reputationTier;
        bool isActive;
        uint256 joinedAt;
    }

    struct ReferralLink {
        address advocate;
        string referralCode;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 usageCount;
        uint256 maxUsage;
        uint256 stakeAmount;
        address stakeAsset;
        bool isActive;
        bytes32 linkHash;
    }

    struct EarningsAllocation {
        uint256 stakeRepaymentAmount;
        uint256 advocateBonusAmount;
        uint256 protocolFeeAmount;
        uint256 recruitKeepsAmount;
        uint256 totalProcessed;
    }

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

    // ========== REFERRAL LINK FUNCTIONS ==========

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
    ) external returns (bytes32 linkHash);

    /**
     * @notice Use a referral link to register with delegated stake
     * @param referralCode The referral code to use
     * @param signature EIP-712 signature from the advocate
     * @return delegationId The created delegation relationship ID
     */
    function useReferralLink(
        string calldata referralCode,
        bytes calldata signature
    ) external returns (bytes32 delegationId);

    // ========== EARNINGS FUNCTIONS ==========

    /**
     * @notice Process earnings for a recruit in a delegation relationship
     * @param recruit Address of the recruit
     * @param totalEarnings Total earnings amount to process
     */
    function processRecruitEarnings(
        address recruit,
        uint256 totalEarnings
    ) external;

    // ========== DELEGATION MANAGEMENT ==========

    /**
     * @notice Terminate a delegation relationship
     * @param delegationId The delegation ID to terminate
     * @param reason Reason for termination
     */
    function terminateDelegation(
        bytes32 delegationId,
        string calldata reason
    ) external;

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get delegation relationship details
     * @param delegationId Delegation ID
     * @return delegation Delegation relationship details
     */
    function getDelegation(bytes32 delegationId) 
        external 
        view 
        returns (DelegationRelationship memory delegation);

    /**
     * @notice Get advocate profile
     * @param advocate Advocate address
     * @return profile Advocate profile details
     */
    function getAdvocateProfile(address advocate) 
        external 
        view 
        returns (AdvocateProfile memory profile);

    /**
     * @notice Get advocate's delegation IDs
     * @param advocate Advocate address
     * @return delegationIds Array of delegation IDs
     */
    function getAdvocateDelegationIds(address advocate) 
        external 
        view 
        returns (bytes32[] memory delegationIds);

    /**
     * @notice Get referral link details
     * @param referralCode Referral code
     * @return link Referral link details
     */
    function getReferralLink(string calldata referralCode) 
        external 
        view 
        returns (ReferralLink memory link);

    /**
     * @notice Check if recruit has delegation
     * @param recruit Recruit address
     * @return hasDelegate Whether recruit has active delegation
     * @return delegationId Delegation ID (if exists)
     */
    function getRecruitDelegation(address recruit) 
        external 
        view 
        returns (bool hasDelegate, bytes32 delegationId);

    /**
     * @notice Get platform statistics
     * @return totalDelegations Total delegations created
     * @return activeDelegations Currently active delegations
     * @return totalStaked Total amount currently staked
     * @return totalAdvocateRewardsDistributed Total rewards paid to advocates
     * @return totalProtocolFees Total protocol fees collected
     * @return activeAdvocateCount Number of active advocates
     */
    function getPlatformStats() external view returns (
        uint256 totalDelegations,
        uint256 activeDelegations,
        uint256 totalStaked,
        uint256 totalAdvocateRewardsDistributed,
        uint256 totalProtocolFees,
        uint256 activeAdvocateCount
    );

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
    ) external;

    /**
     * @notice Update protocol treasury address
     * @param newTreasury New treasury address
     */
    function updateProtocolTreasury(address newTreasury) external;

    /**
     * @notice Update max delegations per advocate
     * @param newMaxDelegations New maximum delegations
     */
    function updateMaxDelegationsPerAdvocate(uint256 newMaxDelegations) external;

    /**
     * @notice Emergency pause contract
     */
    function emergencyPause() external;

    /**
     * @notice Emergency unpause contract
     */
    function emergencyUnpause() external;

    /**
     * @notice Manually update advocate reputation (emergency only)
     * @param advocate Advocate address
     * @param newScore New reputation score
     */
    function emergencyUpdateReputation(
        address advocate,
        uint256 newScore
    ) external;

    // ========== CONSTANTS ==========

    function PRECISION() external view returns (uint256);
    function DEFAULT_STAKE_REPAYMENT_RATE() external view returns (uint256);
    function DEFAULT_ADVOCATE_BONUS_RATE() external view returns (uint256);
    function DEFAULT_PROTOCOL_FEE_RATE() external view returns (uint256);
    function MAX_DELEGATION_PERIOD() external view returns (uint256);
    function MIN_DELEGATION_PERIOD() external view returns (uint256);
    function DEFAULT_MAX_DELEGATIONS_PER_ADVOCATE() external view returns (uint256);
    function MIN_ADVOCATE_REPUTATION() external view returns (uint256);
    function MAX_REPUTATION_SCORE() external view returns (uint256);
    function REFERRAL_CODE_LENGTH() external view returns (uint256);
    function REFERRAL_LINK_EXPIRATION() external view returns (uint256);

    // ========== SLASHING FUNCTIONS ==========

    /**
     * @notice Slash delegated stake for violations
     * @param participant Address of the participant to slash
     * @param amount Amount to slash
     */
    function slashDelegatedStake(address participant, uint256 amount) external;
}