// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../CarbonCreditAMM.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashLoanReceiver {
    function executeFlashLoan(
        address pool,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        CarbonCreditAMM(pool).flashLoan(amount0, amount1, address(this), data);
    }

    function executeOperation(bytes calldata data) external pure {
        // Simple implementation that does nothing
    }

    function executeFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata /* data */
    ) external {
        // Repay the loan with fees
        if (amount0 > 0) {
            address token0 = address(CarbonCreditAMM(msg.sender).token0());
            IERC20(token0).transfer(msg.sender, amount0 + fee0);
        }
        if (amount1 > 0) {
            address token1 = address(CarbonCreditAMM(msg.sender).token1());
            IERC20(token1).transfer(msg.sender, amount1 + fee1);
        }
    }
}