// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISlashingMechanism.sol";

/**
 * @title MockSlashingMechanism
 * @notice Mock implementation for testing LayawayRegistration
 */
abstract contract MockSlashingMechanism is ISlashingMechanism {
    struct SlashingData {
        bool hasSlashing;
        uint256 slashingCount;
        uint256 lastSlashTime;
        uint256 severity;
        bool suspended;
        uint256 suspensionEnd;
    }

    mapping(address => SlashingData) private slashingData;

    function setSlashingHistory(
        address participant,
        bool hasSlashing,
        uint256 count,
        uint256 severity
    ) external {
        slashingData[participant] = SlashingData({
            hasSlashing: hasSlashing,
            slashingCount: count,
            lastSlashTime: hasSlashing ? block.timestamp : 0,
            severity: severity,
            suspended: hasSlashing,
            suspensionEnd: hasSlashing ? block.timestamp + 30 days : 0
        });
    }

    function getSlashingHistory(address participant)
        external
        view
        override
        returns (
            bool hasSlashing,
            uint256 slashingCount,
            uint256 lastSlashTime
        )
    {
        SlashingData memory data = slashingData[participant];
        return (data.hasSlashing, data.slashingCount, data.lastSlashTime);
    }

    function getSlashingSeverity(address participant)
        external
        view
        override
        returns (uint256 severity)
    {
        return slashingData[participant].severity;
    }

    function isSuspended(address participant)
        external
        view
        override
        returns (bool suspended, uint256 suspensionEnd)
    {
        SlashingData memory data = slashingData[participant];
        return (data.suspended && block.timestamp < data.suspensionEnd, data.suspensionEnd);
    }
}