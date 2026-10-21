// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ISocialVerification
 * @notice Interface for social verification contract
 */
interface ISocialVerification {
    /**
     * @notice Check verification status for participant
     * @param participant Address to verify
     * @return isVerified True if participant is socially verified
     * @return verificationScore Score from 0-10000 (100%)
     * @return verificationTime Timestamp of verification
     */
    function getVerificationStatus(address participant)
        external
        view
        returns (
            bool isVerified,
            uint256 verificationScore,
            uint256 verificationTime
        );

    /**
     * @notice Get verification bonus multiplier
     * @param participant Address to check
     * @return bonusMultiplier Multiplier for rewards (10000 = 100%)
     */
    function getVerificationBonus(address participant)
        external
        view
        returns (uint256 bonusMultiplier);

    /**
     * @notice Check if participant qualifies for verification benefits
     * @param participant Address to check
     * @return qualifies True if participant gets verification benefits
     */
    function qualifiesForBenefits(address participant)
        external
        view
        returns (bool qualifies);
}