// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IExtremeWeatherOracle {
    function getEventClassification(
        bytes32 eventId
    ) external view returns (bool isExtreme, uint8 severity, string memory eventType);
}
