// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../CarbonCreditAMM.sol";

/**
 * @title CarbonCreditAMMFormalHarness
 * @notice Thin test-only harness that lets the formal-verification fixture seed
 *         reserve state without exercising the broken zero-address LP mint path.
 * @dev Inherits the real AMM logic and only adds a state-seeding helper.
 */
contract CarbonCreditAMMFormalHarness is CarbonCreditAMM {
    constructor(address expectedFactory) CarbonCreditAMM(expectedFactory) {}

    function seedReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = uint32(block.timestamp % 2 ** 32);
    }
}
