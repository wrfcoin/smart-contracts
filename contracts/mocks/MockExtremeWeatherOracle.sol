// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IExtremeWeatherOracle.sol";

contract MockExtremeWeatherOracle is IExtremeWeatherOracle {
    struct EventClassification {
        bool isExtreme;
        uint8 severity;
        string eventType;
    }

    mapping(bytes32 => EventClassification) private _events;

    function setEventClassification(
        bytes32 eventId,
        bool isExtreme,
        uint8 severity,
        string calldata eventType
    ) external {
        _events[eventId] = EventClassification({
            isExtreme: isExtreme,
            severity: severity,
            eventType: eventType
        });
    }

    function getEventClassification(
        bytes32 eventId
    ) external view override returns (bool isExtreme, uint8 severity, string memory eventType) {
        EventClassification storage eventData = _events[eventId];
        return (eventData.isExtreme, eventData.severity, eventData.eventType);
    }
}
