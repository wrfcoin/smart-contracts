// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IParticipantTypeRegistry
 * @notice Interface for participant type registry contract
 */
interface IParticipantTypeRegistry {
    /**
     * @notice Get participant information for layaway calculation
     * @param participant Address to query
     * @return isMultiMethod True if participant uses multiple methods
     * @return isVerified True if participant is verified
     * @return hasSlashing True if participant has slashing history
     */
    function getParticipantInfo(address participant)
        external
        view
        returns (
            bool isMultiMethod,
            bool isVerified,
            bool hasSlashing
        );

    /**
     * @notice Get participant type details
     * @param participant Address to query
     * @return participantType Encoded participant type
     * @return verificationLevel Verification level (0-100)
     * @return methodCount Number of participation methods
     */
    function getParticipantDetails(address participant)
        external
        view
        returns (
            uint256 participantType,
            uint256 verificationLevel,
            uint256 methodCount
        );

    /**
     * @notice Update participant status after slashing
     * @param participant Address of participant
     * @param status New status (true for active, false for inactive)
     */
    function updateParticipantStatus(address participant, bool status) external;

    /**
     * @notice Get required stake amount for participant
     * @param participant Address of participant
     * @return required Required stake amount
     */
    function getRequiredStakeAmount(address participant) external view returns (uint256 required);
}