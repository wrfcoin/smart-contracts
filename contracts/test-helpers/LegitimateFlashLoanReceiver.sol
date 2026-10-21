// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LegitimateFlashLoanReceiver
 * @dev Contract that properly handles flash loan callbacks and repays with fees
 * Used for testing legitimate flash loan operations
 */
contract LegitimateFlashLoanReceiver {
    
    /**
     * @dev Flash loan callback that properly repays the loan with fees
     */
    function executeFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata /* data */
    ) external {
        // Get the AMM address from msg.sender
        address amm = msg.sender;
        
        // Perform some legitimate operations (could be arbitrage, etc.)
        // For testing, we just ensure we have enough funds to repay
        
        // Repay the flash loan with fees
        if (amount0 > 0) {
            // Get token0 address from AMM
            address token0 = address(ICarbonCreditAMMTest(amm).token0());
            IERC20(token0).transfer(amm, amount0 + fee0);
        }
        
        if (amount1 > 0) {
            // Get token1 address from AMM
            address token1 = address(ICarbonCreditAMMTest(amm).token1());
            IERC20(token1).transfer(amm, amount1 + fee1);
        }
    }

    /**
     * @dev Required for swap callback
     */
    function executeOperation(bytes calldata) external {
        // Simple operation callback
    }
}

// Import the AMM interface for type checking
interface ICarbonCreditAMMTest {
    function token0() external view returns (address);
    function token1() external view returns (address);
}