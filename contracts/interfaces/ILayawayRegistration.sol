// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ILayawayRegistration
 * @notice Interface for layaway registration contract
 */
interface ILayawayRegistration {
    enum LayawayStatus {
        INACTIVE,
        ACTIVE,
        COMPLETED,
        CANCELLED
    }

    struct LayawayAccount {
        address participant;
        uint256 totalStaked;
        uint256 accumulatedStake;
        uint256 requiredStake;
        uint256 layawayPeriod;
        LayawayStatus status;
        uint256 lastUpdate;
    }

    /**
     * @notice Get a participant's layaway account
     * @param participant Address of participant
     * @return account The layaway account details
     */
    function getLayawayAccount(address participant) external view returns (LayawayAccount memory account);

    /**
     * @notice Update layaway period for a participant
     * @param participant Address of participant
     * @param newPeriod New layaway period in seconds
     */
    function updateLayawayPeriod(address participant, uint256 newPeriod) external;

    /**
     * @notice Get base layaway period
     * @return period Base layaway period in seconds
     */
    function getBaseLayawayPeriod() external view returns (uint256 period);

    /**
     * @notice Get participant's current layaway period
     * @param participant Address of participant
     * @return period Current layaway period in seconds
     */
    function getParticipantLayawayPeriod(address participant) external view returns (uint256 period);
}
