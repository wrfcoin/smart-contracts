// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IWRFToken {
    function registerWeatherStationSimple(string calldata stationId) external payable;
    function voteToDeregisterStation(address station) external;
    function deregisterAndRecoverStake() external;
}

/**
 * @title MaliciousStation
 * @dev Contract that attempts reentrancy via receive() when receiving ETH — for testing only
 */
contract MaliciousStation {
    IWRFToken public wrfToken;
    address public targetStation;
    bool public attackEnabled;
    uint256 public reentrancyAttempts;

    constructor(address _wrfToken) {
        wrfToken = IWRFToken(_wrfToken);
    }

    function register(string calldata stationId) external payable {
        wrfToken.registerWeatherStationSimple{value: msg.value}(stationId);
    }

    function setAttack(address _targetStation) external {
        targetStation = _targetStation;
        attackEnabled = true;
    }

    function disableAttack() external {
        attackEnabled = false;
    }

    function voteToDeregister(address station) external {
        wrfToken.voteToDeregisterStation(station);
    }

    function selfDeregister() external {
        wrfToken.deregisterAndRecoverStake();
    }

    receive() external payable {
        // Attempt reentrancy when receiving ETH refund
        if (attackEnabled && address(wrfToken) != address(0)) {
            attackEnabled = false; // prevent infinite loop
            reentrancyAttempts++;
            // Try re-entering deregisterAndRecoverStake
            try wrfToken.deregisterAndRecoverStake() {} catch {}
        }
    }
}
