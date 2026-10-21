// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title InsufficientRepaymentContract
 * @dev Advanced test contract for flash loan repayment failure scenarios
 * @notice Simulates various insufficient repayment patterns for comprehensive testing
 * 
 * Features:
 * - Configurable repayment ratios (0% to 99%)
 * - Multiple failure modes (partial, zero, delayed)
 * - Repayment attempt tracking
 * - Economic security testing
 * - Gas usage optimization for test scenarios
 */
contract InsufficientRepaymentContract {
    
    /// @dev Repayment configuration
    uint256 public repaymentRatio = 50; // 50% repayment by default
    bool public simulateDelayedRepayment = false;
    bool public simulateZeroRepayment = false;
    
    /// @dev Statistics tracking
    uint256 public totalAttempts;
    uint256 public totalFailures;
    mapping(address => uint256) public attemptsByAmm;
    
    /// @dev Events for test analysis
    event RepaymentAttempted(
        address indexed amm,
        uint256 amount0Required,
        uint256 amount1Required,
        uint256 amount0Repaid,
        uint256 amount1Repaid,
        string failureMode
    );
    
    event RepaymentConfigured(
        uint256 newRatio,
        bool delayedMode,
        bool zeroMode
    );
    
    /**
     * @dev Advanced flash loan callback with configurable repayment failure modes
     * @param amount0 Amount of token0 borrowed
     * @param amount1 Amount of token1 borrowed  
     * @param data Encoded repayment configuration or failure mode
     */
    function executeFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 /* fee0 */,
        uint256 /* fee1 */,
        bytes calldata data
    ) external {
        address amm = msg.sender;
        totalAttempts++;
        attemptsByAmm[amm]++;
        
        // Decode configuration from data if provided
        string memory failureMode = "default";
        if (data.length > 0) {
            (uint256 customRatio, string memory mode) = abi.decode(data, (uint256, string));
            if (customRatio < 100) {
                repaymentRatio = customRatio;
            }
            failureMode = mode;
        }
        
        uint256 amount0Repaid = 0;
        uint256 amount1Repaid = 0;
        
        if (simulateZeroRepayment || keccak256(bytes(failureMode)) == keccak256(bytes("zero"))) {
            // Simulate complete non-payment
            failureMode = "zero_repayment";
        } else if (simulateDelayedRepayment || keccak256(bytes(failureMode)) == keccak256(bytes("delayed"))) {
            // Simulate delayed repayment (still insufficient due to missing fees)
            _performDelayedRepayment(amm, amount0, amount1);
            amount0Repaid = amount0;
            amount1Repaid = amount1;
            failureMode = "delayed_repayment";
        } else {
            // Simulate partial repayment based on ratio
            amount0Repaid = _performPartialRepayment(amm, amount0, 0);
            amount1Repaid = _performPartialRepayment(amm, amount1, 1);
            failureMode = "partial_repayment";
        }
        
        totalFailures++;
        
        emit RepaymentAttempted(
            amm,
            amount0,
            amount1,
            amount0Repaid,
            amount1Repaid,
            failureMode
        );
    }
    
    /**
     * @dev Perform partial repayment based on configured ratio
     * @param amm AMM contract address
     * @param amount Amount to partially repay
     * @param tokenIndex 0 for token0, 1 for token1
     * @return repaidAmount Actual amount repaid
     */
    function _performPartialRepayment(
        address amm,
        uint256 amount,
        uint256 tokenIndex
    ) internal returns (uint256 repaidAmount) {
        if (amount == 0) return 0;
        
        address token = tokenIndex == 0 
            ? address(ICarbonCreditAMMTest(amm).token0())
            : address(ICarbonCreditAMMTest(amm).token1());
            
        uint256 balance = IERC20(token).balanceOf(address(this));
        
        // Calculate repayment amount based on ratio (intentionally insufficient)
        repaidAmount = (amount * repaymentRatio) / 100;
        
        // Ensure we don't repay more than our balance
        if (repaidAmount > balance) {
            repaidAmount = balance;
        }
        
        if (repaidAmount > 0) {
            IERC20(token).transfer(amm, repaidAmount);
        }
    }
    
    /**
     * @dev Perform delayed repayment (principal only, no fees)
     * @param amm AMM contract address
     * @param amount0 Amount of token0 to repay
     * @param amount1 Amount of token1 to repay
     */
    function _performDelayedRepayment(
        address amm,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // Simulate processing delay
        for (uint256 i = 0; i < 10; i++) {
            // Waste gas to simulate delay
            keccak256(abi.encodePacked(block.timestamp, i));
        }
        
        // Repay principal only (no fees = insufficient)
        if (amount0 > 0) {
            address token0 = address(ICarbonCreditAMMTest(amm).token0());
            uint256 balance0 = IERC20(token0).balanceOf(address(this));
            if (balance0 >= amount0) {
                IERC20(token0).transfer(amm, amount0);
            }
        }
        
        if (amount1 > 0) {
            address token1 = address(ICarbonCreditAMMTest(amm).token1());
            uint256 balance1 = IERC20(token1).balanceOf(address(this));
            if (balance1 >= amount1) {
                IERC20(token1).transfer(amm, amount1);
            }
        }
    }
    
    /**
     * @dev Configure repayment behavior for testing
     * @param _ratio Repayment ratio (0-99, 100+ means normal repayment)
     * @param _delayedMode Enable delayed repayment simulation
     * @param _zeroMode Enable zero repayment simulation
     */
    function configureRepayment(
        uint256 _ratio,
        bool _delayedMode,
        bool _zeroMode
    ) external {
        repaymentRatio = _ratio;
        simulateDelayedRepayment = _delayedMode;
        simulateZeroRepayment = _zeroMode;
        
        emit RepaymentConfigured(_ratio, _delayedMode, _zeroMode);
    }
    
    /**
     * @dev Get repayment statistics
     * @return attempts Total repayment attempts
     * @return failures Total failures
     * @return successRate Success rate percentage (should be 0 for this contract)
     */
    function getRepaymentStats() external view returns (
        uint256 attempts,
        uint256 failures,
        uint256 successRate
    ) {
        attempts = totalAttempts;
        failures = totalFailures;
        successRate = attempts > 0 ? ((attempts - failures) * 100) / attempts : 0;
    }
    
    /**
     * @dev Reset statistics for testing
     */
    function resetStats() external {
        totalAttempts = 0;
        totalFailures = 0;
    }
    
    /**
     * @dev Fund the contract with tokens for testing
     * @param token Token address to fund
     * @param amount Amount to fund
     */
    function fundForTesting(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

interface ICarbonCreditAMMTest {
    function token0() external view returns (address);
    function token1() external view returns (address);
}