// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../lib/WeightedMath.sol";

contract WeightedMathHarness {
    function applySwapFee(uint256 amount, uint256 swapFeeBps) external pure returns (uint256) {
        return WeightedMath.applySwapFee(amount, swapFeeBps);
    }

    function removeSwapFee(uint256 amount, uint256 swapFeeBps) external pure returns (uint256) {
        return WeightedMath.removeSwapFee(amount, swapFeeBps);
    }
}
