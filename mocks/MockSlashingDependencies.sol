// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IMultiAssetStaking.sol";
import "../interfaces/IParticipantTypeRegistry.sol";
import "../interfaces/ILayawayRegistration.sol";
import "../interfaces/IStakeDelegation.sol";
import "../interfaces/IWeatherDataValidator.sol";

/**
 * @title MockMultiAssetStaking
 * @dev Mock implementation for testing SlashingMechanism
 */
abstract contract MockMultiAssetStaking is IMultiAssetStaking {
    mapping(address => uint256) private totalStakes;
    mapping(address => uint256) private requiredStakes;
    bool private shouldFailSlashing = false;

    function setTotalStake(address participant, uint256 stake) external {
        totalStakes[participant] = stake;
    }

    function setRequiredStake(address participant, uint256 stake) external {
        requiredStakes[participant] = stake;
    }

    function setShouldFailSlashing(bool fail) external {
        shouldFailSlashing = fail;
    }

    function getTotalStake(address participant) external view returns (uint256) {
        return totalStakes[participant];
    }

    function slashStake(address participant, uint256 amount) external {
        require(!shouldFailSlashing, "Mock: Slashing failed");
        if (totalStakes[participant] >= amount) {
            totalStakes[participant] -= amount;
        }
    }

    // Stub implementations for interface compliance
    function stakeAsset(address, uint256, DynamicStakeCalculator.StakeParameters calldata) external payable {}
    function getStakeValueUSD(address) external pure returns (uint256, uint256[] memory, address[] memory) {
        return (0, new uint256[](0), new address[](0));
    }
    function rebalanceStake(address, address, address, uint256) external {}
    function withdrawStake(address, uint256) external {}
    function convertStakeAsset(address, address, uint256) external {}
    function getCollateralizationRatio(address) external pure returns (uint256, bool, uint256, uint256) {
        return (0, false, 0, 0);
    }
    function completeCrossChainDeposit(bytes32, address, address, uint256) external {}
    function completeCrossChainWithdrawal(bytes32, bool, string calldata) external {}
    function getComprehensiveStakeInfo(address) external pure returns (uint256, uint256, uint256, bool, address[] memory, uint256[] memory, uint256[] memory) {
        return (0, 0, 0, false, new address[](0), new uint256[](0), new uint256[](0));
    }
    function getSupportedAssets() external pure returns (address[] memory, AssetConfig[] memory) {
        return (new address[](0), new AssetConfig[](0));
    }
    function getAssetPrice(address) external pure returns (uint256, uint256, bool) {
        return (0, 0, false);
    }
    function configureAsset(address, AssetConfig calldata) external {}
    function removeAssetSupport(address) external {}
    function emergencyLiquidation(address, address, uint256, string calldata) external {}
}

/**
 * @title MockParticipantTypeRegistry
 * @dev Mock implementation for testing SlashingMechanism
 */
abstract contract MockParticipantTypeRegistry is IParticipantTypeRegistry {
    mapping(address => uint256) private requiredStakeAmounts;
    mapping(address => bool) private participantStatus;

    function setRequiredStakeAmount(address participant, uint256 amount) external {
        requiredStakeAmounts[participant] = amount;
    }

    function setParticipantStatus(address participant, bool status) external {
        participantStatus[participant] = status;
    }

    function getParticipantInfo(address) external pure returns (bool, bool, bool) {
        return (true, true, false);
    }

    function getParticipantDetails(address) external pure returns (uint256, uint256, uint256) {
        return (1, 100, 1);
    }

    function updateParticipantStatus(address participant, bool status) external {
        participantStatus[participant] = status;
    }

    function getRequiredStakeAmount(address participant) external view returns (uint256) {
        return requiredStakeAmounts[participant] > 0 ? requiredStakeAmounts[participant] : 1000e18;
    }
}

/**
 * @title MockLayawayRegistration
 * @dev Mock implementation for testing SlashingMechanism
 */
abstract contract MockLayawayRegistration is ILayawayRegistration {
    mapping(address => uint256) private layawayPeriods;
    uint256 private baseLayawayPeriod = 30 days;

    function setBaseLayawayPeriod(uint256 period) external {
        baseLayawayPeriod = period;
    }

    function updateLayawayPeriod(address participant, uint256 newPeriod) external {
        layawayPeriods[participant] = newPeriod;
    }

    function getBaseLayawayPeriod() external view returns (uint256) {
        return baseLayawayPeriod;
    }

    function getParticipantLayawayPeriod(address participant) external view returns (uint256) {
        return layawayPeriods[participant] > 0 ? layawayPeriods[participant] : baseLayawayPeriod;
    }
}

/**
 * @title MockStakeDelegation
 * @dev Mock implementation for testing SlashingMechanism
 */
abstract contract MockStakeDelegation is IStakeDelegation {
    mapping(address => uint256) private delegatedStakes;

    function setDelegatedStake(address participant, uint256 stake) external {
        delegatedStakes[participant] = stake;
    }

    function slashDelegatedStake(address participant, uint256 amount) external {
        if (delegatedStakes[participant] >= amount) {
            delegatedStakes[participant] -= amount;
        }
    }

    function getDelegatedStake(address participant) external view returns (uint256) {
        return delegatedStakes[participant];
    }

    // Stub implementations for interface compliance
    function createReferralLink(string calldata, uint256, address, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
    function useReferralLink(string calldata, bytes calldata) external pure returns (bytes32) {
        return bytes32(0);
    }
    function processRecruitEarnings(address, uint256) external {}
    function terminateDelegation(bytes32, string calldata) external {}
    function getDelegation(bytes32) external pure returns (DelegationRelationship memory) {
        return DelegationRelationship({
            advocate: address(0),
            recruit: address(0),
            stakeAsset: address(0),
            stakeAmount: 0,
            stakeRepaid: 0,
            advocateRewardsEarned: 0,
            recruitEarnings: 0,
            delegationStartTime: 0,
            independenceTime: 0,
            lastEarningsUpdate: 0,
            status: DelegationStatus.ACTIVE,
            referralCode: "",
            expectedRepaymentPeriod: 0,
            delegationId: bytes32(0)
        });
    }
    function getAdvocateProfile(address) external pure returns (AdvocateProfile memory) {
        return AdvocateProfile({
            advocate: address(0),
            totalDelegations: 0,
            activeDelegations: 0,
            successfulDelegations: 0,
            defaultedDelegations: 0,
            totalRewardsEarned: 0,
            totalStakeProvided: 0,
            totalStakeRecovered: 0,
            maxDelegations: 0,
            reputationScore: 0,
            lastReputationUpdate: 0,
            reputationTier: ReputationTier.NOVICE,
            isActive: false,
            joinedAt: 0
        });
    }
    function getAdvocateDelegationIds(address) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function getReferralLink(string calldata) external pure returns (ReferralLink memory) {
        return ReferralLink({
            advocate: address(0),
            referralCode: "",
            createdAt: 0,
            expiresAt: 0,
            usageCount: 0,
            maxUsage: 0,
            stakeAmount: 0,
            stakeAsset: address(0),
            isActive: false,
            linkHash: bytes32(0)
        });
    }
    function getRecruitDelegation(address) external pure returns (bool, bytes32) {
        return (false, bytes32(0));
    }
    function getPlatformStats() external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, 0);
    }
    function updateEarningRates(uint256, uint256, uint256) external {}
    function updateProtocolTreasury(address) external {}
    function updateMaxDelegationsPerAdvocate(uint256) external {}
    function emergencyPause() external {}
    function emergencyUnpause() external {}
    function emergencyUpdateReputation(address, uint256) external {}
    function PRECISION() external pure returns (uint256) { return 10000; }
    function DEFAULT_STAKE_REPAYMENT_RATE() external pure returns (uint256) { return 5000; }
    function DEFAULT_ADVOCATE_BONUS_RATE() external pure returns (uint256) { return 1000; }
    function DEFAULT_PROTOCOL_FEE_RATE() external pure returns (uint256) { return 500; }
    function MAX_DELEGATION_PERIOD() external pure returns (uint256) { return 365 days; }
    function MIN_DELEGATION_PERIOD() external pure returns (uint256) { return 30 days; }
    function DEFAULT_MAX_DELEGATIONS_PER_ADVOCATE() external pure returns (uint256) { return 10; }
    function MIN_ADVOCATE_REPUTATION() external pure returns (uint256) { return 7000; }
    function MAX_REPUTATION_SCORE() external pure returns (uint256) { return 10000; }
    function REFERRAL_CODE_LENGTH() external pure returns (uint256) { return 8; }
    function REFERRAL_LINK_EXPIRATION() external pure returns (uint256) { return 30 days; }
}

/**
 * @title MockWeatherDataValidator
 * @dev Mock implementation for testing SlashingMechanism
 */
abstract contract MockWeatherDataValidator is IWeatherDataValidator {
    mapping(address => uint256) private violationCounts;
    mapping(address => uint256) private qualityScores;
    mapping(address => uint256) private lastViolations;

    function setViolationCount(address participant, uint256 count) external {
        violationCounts[participant] = count;
    }

    function setQualityScore(address participant, uint256 score) external {
        qualityScores[participant] = score;
    }

    function reportDataQualityViolation(address participant, uint8, bytes32) external {
        violationCounts[participant]++;
        lastViolations[participant] = block.timestamp;
    }

    function validateWeatherData(address participant, bytes32) external view returns (bool, uint256) {
        uint256 score = qualityScores[participant] > 0 ? qualityScores[participant] : 85;
        return (score >= 70, score);
    }

    function getDataQualityHistory(address participant) external view returns (uint256, uint256, uint256) {
        uint256 avgQuality = qualityScores[participant] > 0 ? qualityScores[participant] : 85;
        return (avgQuality, violationCounts[participant], lastViolations[participant]);
    }
}