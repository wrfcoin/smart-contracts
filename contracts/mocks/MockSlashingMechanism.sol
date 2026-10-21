// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ISlashingMechanism.sol";

/**
 * @title MockSlashingMechanism
 * @notice Mock implementation for testing LayawayRegistration
 */
contract MockSlashingMechanism is ISlashingMechanism {
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

    // Stub implementations for full interface compliance
    function proposeSlashing(address, SlashingReason, ViolationSeverity, bytes32, string calldata) external {}
    function validateSlashing(uint256) external {}
    function executeSlashing(uint256) external {}
    function appealSlashing(uint256, bytes32, string calldata) external {}
    function refillStake(uint256) external {}
    function submitEvidence(bytes32, string calldata) external {}
    function emergencySlashing(address, uint256, string calldata) external {}

    function checkEligibility(address) external pure returns (bool, string memory) {
        return (true, "");
    }
    function getParticipantRecord(address) external pure returns (uint256, uint256, uint256, bool, uint256, uint256, bool, uint256) {
        return (0, 0, 0, false, 0, 0, false, 0);
    }
    function getSlashingEvent(uint256) external pure returns (address, SlashingReason, ViolationSeverity, uint256, uint256, uint256, SlashingStatus, uint256, string memory, address[] memory, uint256) {
        return (address(0), SlashingReason.FRAUD, ViolationSeverity.MINOR, 0, 0, 0, SlashingStatus.PENDING, 0, "", new address[](0), 0);
    }
    function getPendingSlashings(address) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }
    function verifyEvidence(bytes32) external pure returns (bool) {
        return false;
    }
}