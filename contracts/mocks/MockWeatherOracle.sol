// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWeatherOracle} from "../interfaces/IQualityOracle.sol";

/**
 * @title MockWeatherOracle
 * @notice Test double for IWeatherOracle.  Stores one configurable WeatherData
 *         snapshot per stationId, settable by tests via setWeatherData().
 */
contract MockWeatherOracle {
    mapping(bytes32 => IWeatherOracle.WeatherData) private _data;

    function setWeatherData(bytes32 stationId, IWeatherOracle.WeatherData calldata data) external {
        _data[stationId] = data;
    }

    function getLatestWeatherData(bytes32 stationId)
        external
        view
        returns (IWeatherOracle.WeatherData memory)
    {
        return _data[stationId];
    }

    // Stub — satisfies callers that check freshness.
    function isWeatherDataFresh(bytes32, uint256) external pure returns (bool) {
        return true;
    }
}
