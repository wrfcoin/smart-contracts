// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../CarbonCreditAMM.sol";

/**
 * @title MaliciousFlashLoanReceiver
 * @dev Contract that attempts various reentrancy attacks during flash loan callbacks
 * Used for testing the reentrancy protection mechanisms
 */
contract MaliciousFlashLoanReceiver {
    CarbonCreditAMM public immutable amm;
    
    constructor(address _amm) {
        amm = CarbonCreditAMM(_amm);
    }

    /**
     * @dev Attempts to call flash loan again during callback (direct reentrancy)
     */
    function initiateReentrancyAttack(uint256 amount0, uint256 amount1) external {
        amm.flashLoan(amount0, amount1, address(this), "");
    }

    /**
     * @dev Attempts to call swap during flash loan callback (cross-function reentrancy)
     */
    function initiateSwapReentrancyAttack(uint256 amount0, uint256 amount1) external {
        amm.flashLoan(amount0, amount1, address(this), abi.encode("swap_attack"));
    }

    /**
     * @dev Attempts to call mint during flash loan callback
     */
    function initiateMintReentrancyAttack(uint256 amount0, uint256 amount1) external {
        amm.flashLoan(amount0, amount1, address(this), abi.encode("mint_attack"));
    }

    /**
     * @dev Attempts to call burn during flash loan callback
     */
    function initiateBurnReentrancyAttack(uint256 amount0, uint256 amount1) external {
        amm.flashLoan(amount0, amount1, address(this), abi.encode("burn_attack"));
    }

    /**
     * @dev Flash loan callback that attempts reentrancy
     */
    function executeFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 /* fee0 */,
        uint256 /* fee1 */,
        bytes calldata data
    ) external {
        if (data.length == 0) {
            // Direct reentrancy attack
            amm.flashLoan(amount0, amount1, address(this), "");
        } else {
            string memory attackType = abi.decode(data, (string));
            
            if (keccak256(bytes(attackType)) == keccak256(bytes("swap_attack"))) {
                // Attempt to call swap (cross-function reentrancy)
                amm.swap(amount0 / 2, 0, address(this), "");
            } else if (keccak256(bytes(attackType)) == keccak256(bytes("mint_attack"))) {
                // Attempt to call mint
                amm.mint(address(this));
            } else if (keccak256(bytes(attackType)) == keccak256(bytes("burn_attack"))) {
                // Attempt to call burn
                amm.burn(address(this));
            }
        }
    }

    /**
     * @dev Required for swap callback (shouldn't be reached due to reentrancy protection)
     */
    function executeOperation(bytes calldata /* data */) external pure {
        // This should not be called if reentrancy protection works
        revert("Reentrancy protection failed");
    }
}