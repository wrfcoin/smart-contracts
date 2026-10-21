// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ILayawayRegistration
 * @notice Interface for layaway registration contract
 */
interface ILayawayRegistration {
    struct LayawayAccount {
        uint256 totalStaked;
        uint256 layawayPeriod;
        bool active;
        uint256 lastUpdate;
    }
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