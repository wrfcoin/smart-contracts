// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IParticipantTypeRegistry.sol";

/**
 * @title MockParticipantTypeRegistry
 * @notice Mock implementation for testing LayawayRegistration
 */
abstract contract MockParticipantTypeRegistry is IParticipantTypeRegistry {
    struct ParticipantInfo {
        bool isMultiMethod;
        bool isVerified;
        bool hasSlashing;
        uint256 participantType;
        uint256 verificationLevel;
        uint256 methodCount;
    }

    mapping(address => ParticipantInfo) private participantInfo;

    function setParticipantInfo(
        address participant,
        bool isMultiMethod,
        bool isVerified,
        bool hasSlashing
    ) external {
        participantInfo[participant] = ParticipantInfo({
            isMultiMethod: isMultiMethod,
            isVerified: isVerified,
            hasSlashing: hasSlashing,
            participantType: isMultiMethod ? 2 : (isVerified ? 1 : 0),
            verificationLevel: isVerified ? 100 : 0,
            methodCount: isMultiMethod ? 3 : 1
        });
    }

    function getParticipantInfo(address participant)
        external
        view
        override
        returns (
            bool isMultiMethod,
            bool isVerified,
            bool hasSlashing
        )
    {
        ParticipantInfo memory info = participantInfo[participant];
        return (info.isMultiMethod, info.isVerified, info.hasSlashing);
    }

    function getParticipantDetails(address participant)
        external
        view
        override
        returns (
            uint256 participantType,
            uint256 verificationLevel,
            uint256 methodCount
        )
    {
        ParticipantInfo memory info = participantInfo[participant];
        return (info.participantType, info.verificationLevel, info.methodCount);
    }
}