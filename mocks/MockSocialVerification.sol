// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISocialVerification.sol";

/**
 * @title MockSocialVerification
 * @notice Mock implementation for testing LayawayRegistration
 */
abstract contract MockSocialVerification is ISocialVerification {
    struct VerificationData {
        bool isVerified;
        uint256 verificationScore;
        uint256 verificationTime;
        uint256 bonusMultiplier;
    }

    mapping(address => VerificationData) private verificationData;

    function setVerificationStatus(
        address participant,
        bool isVerified,
        uint256 score,
        uint256 bonusMultiplier
    ) external {
        verificationData[participant] = VerificationData({
            isVerified: isVerified,
            verificationScore: score,
            verificationTime: block.timestamp,
            bonusMultiplier: bonusMultiplier
        });
    }

    function getVerificationStatus(address participant)
        external
        view
        override
        returns (
            bool isVerified,
            uint256 verificationScore,
            uint256 verificationTime
        )
    {
        VerificationData memory data = verificationData[participant];
        return (data.isVerified, data.verificationScore, data.verificationTime);
    }

    function getVerificationBonus(address participant)
        external
        view
        override
        returns (uint256 bonusMultiplier)
    {
        return verificationData[participant].bonusMultiplier;
    }

    function qualifiesForBenefits(address participant)
        external
        view
        override
        returns (bool qualifies)
    {
        return verificationData[participant].isVerified;
    }
}