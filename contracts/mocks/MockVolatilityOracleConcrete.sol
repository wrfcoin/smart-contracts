// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../interfaces/IVolatilityOracle.sol";

/**
 * @title MockVolatilityOracleConcrete
 * @dev Simple mock for testing — returns configurable volatility values.
 */
contract MockVolatilityOracleConcrete is IVolatilityOracle {
    uint256 private _volatility = 500; // default 5%

    function setVolatility(uint256 vol) external {
        _volatility = vol;
    }

    function getVolatility(address, address) external view override returns (uint256) {
        return _volatility;
    }

    function getVolatilityData(address, address) external view override returns (VolatilityData memory) {
        return VolatilityData(_volatility, block.timestamp, 95, 100);
    }

    function getTWAVolatility(address, address, uint256) external view override returns (uint256) {
        return _volatility;
    }

    function updateVolatility(address, address, uint256) external override {}

    function isDataFresh(address, address, uint256) external pure override returns (bool) {
        return true;
    }

    function getVolatilityThreshold(address, address) external pure override returns (uint256) {
        return 2000;
    }

    function isHighVolatility(address, address) external view override returns (bool) {
        return _volatility > 2000;
    }
}
