// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title KInvariantViolator
 * @dev Advanced k-invariant violation testing contract
 * @notice Simulates various k-invariant attack patterns for security testing
 * 
 * Features:
 * - Multiple attack vectors (fee theft, principal manipulation, timing attacks)
 * - Configurable violation patterns
 * - Attack success/failure tracking
 * - Economic impact measurement
 * - Comprehensive test coverage for invariant protection
 */
contract KInvariantViolator {
    address public immutable amm;
    
    /// @dev Attack configuration
    enum AttackType {
        NO_REPAYMENT,
        PRINCIPAL_ONLY,
        PARTIAL_FEE,
        TIMING_ATTACK,
        DOUBLE_SPEND,
        MANIPULATION_ATTACK
    }
    
    /// @dev Attack statistics
    struct AttackResult {
        AttackType attackType;
        bool successful;
        uint256 attemptedProfit;
        uint256 actualProfit;
        uint256 gasUsed;
        string failureReason;
    }
    
    mapping(bytes32 => AttackResult) public attackResults;
    uint256 public totalAttackAttempts;
    uint256 public successfulAttacks;
    
    /// @dev Events for attack analysis
    event AttackAttempted(
        bytes32 indexed attackId,
        AttackType indexed attackType,
        bool successful,
        uint256 profit,
        string reason
    );
    
    event KInvariantProtectionTested(
        address indexed amm,
        uint256 kBefore,
        uint256 kAfter,
        bool protected
    );
    
    constructor(address _amm) {
        amm = _amm;
    }

    /**
     * @dev Advanced flash loan callback that attempts various k-invariant violations
     * @param amount0 Amount of token0 borrowed
     * @param amount1 Amount of token1 borrowed
     * @param data Encoded attack type and parameters
     */
    function executeFlashLoan(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        uint256 startGas = gasleft();
        bytes32 attackId = keccak256(abi.encodePacked(block.timestamp, msg.sender));
        AttackType attackType = AttackType.PRINCIPAL_ONLY;
        
        // Decode attack configuration
        if (data.length > 0) {
            attackType = abi.decode(data, (AttackType));
        }
        
        totalAttackAttempts++;
        
        // Record initial pool state for k-invariant analysis
        uint256 kBefore = _calculateKInvariant();
        
        bool attackSuccessful = false;
        uint256 attemptedProfit = fee0 + fee1;
        string memory failureReason = "";
        
        try this._executeAttack(amount0, amount1, fee0, fee1, attackType) {
            attackSuccessful = true;
            successfulAttacks++;
        } catch Error(string memory reason) {
            failureReason = reason;
        } catch {
            failureReason = "Unknown attack failure";
        }
        
        uint256 kAfter = _calculateKInvariant();
        uint256 gasUsed = startGas - gasleft();
        
        // Record attack result
        attackResults[attackId] = AttackResult({
            attackType: attackType,
            successful: attackSuccessful,
            attemptedProfit: attemptedProfit,
            actualProfit: attackSuccessful ? attemptedProfit : 0,
            gasUsed: gasUsed,
            failureReason: failureReason
        });
        
        emit AttackAttempted(attackId, attackType, attackSuccessful, attemptedProfit, failureReason);
        emit KInvariantProtectionTested(amm, kBefore, kAfter, !attackSuccessful);
    }
    
    /**
     * @dev Execute specific attack type
     * @param amount0 Token0 amount
     * @param amount1 Token1 amount
     * @param fee0 Token0 fee
     * @param fee1 Token1 fee
     * @param attackType Type of k-invariant violation to attempt
     */
    function _executeAttack(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        AttackType attackType
    ) external {
        require(msg.sender == address(this), "Internal function only");
        
        if (attackType == AttackType.NO_REPAYMENT) {
            // Attempt complete non-repayment
            return;
        } else if (attackType == AttackType.PRINCIPAL_ONLY) {
            _repayPrincipalOnly(amount0, amount1);
        } else if (attackType == AttackType.PARTIAL_FEE) {
            _repayPartialFee(amount0, amount1, fee0, fee1);
        } else if (attackType == AttackType.TIMING_ATTACK) {
            _attemptTimingAttack(amount0, amount1, fee0, fee1);
        } else if (attackType == AttackType.DOUBLE_SPEND) {
            _attemptDoubleSpend(amount0, amount1, fee0, fee1);
        } else if (attackType == AttackType.MANIPULATION_ATTACK) {
            _attemptManipulationAttack(amount0, amount1, fee0, fee1);
        }
    }
    
    /**
     * @dev Repay only principal (no fees) - should fail k-invariant check
     */
    function _repayPrincipalOnly(uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            address token0 = address(CarbonCreditAMM(amm).token0());
            IERC20(token0).transfer(amm, amount0);
        }
        
        if (amount1 > 0) {
            address token1 = address(CarbonCreditAMM(amm).token1());
            IERC20(token1).transfer(amm, amount1);
        }
    }
    
    /**
     * @dev Repay partial fees - should fail k-invariant check
     */
    function _repayPartialFee(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) internal {
        if (amount0 > 0) {
            address token0 = address(CarbonCreditAMM(amm).token0());
            // Pay only 50% of required fee
            IERC20(token0).transfer(amm, amount0 + (fee0 / 2));
        }
        
        if (amount1 > 0) {
            address token1 = address(CarbonCreditAMM(amm).token1());
            // Pay only 50% of required fee
            IERC20(token1).transfer(amm, amount1 + (fee1 / 2));
        }
    }
    
    /**
     * @dev Attempt timing-based attack
     */
    function _attemptTimingAttack(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) internal {
        // Simulate timing delay before repayment
        for (uint256 i = 0; i < 50; i++) {
            keccak256(abi.encodePacked(block.timestamp, i));
        }
        
        // Then attempt normal repayment (should still work)
        _repayPrincipalOnly(amount0, amount1);
    }
    
    /**
     * @dev Attempt double spending attack
     */
    function _attemptDoubleSpend(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) internal {
        // Try to use borrowed funds elsewhere before repaying
        if (amount0 > 0) {
            address token0 = address(CarbonCreditAMM(amm).token0());
            uint256 balance = IERC20(token0).balanceOf(address(this));
            
            // Attempt to transfer funds elsewhere
            if (balance >= amount0) {
                // This would normally transfer to another contract, but for testing
                // we just burn some gas and then repay principal only
                keccak256(abi.encodePacked(balance));
                IERC20(token0).transfer(amm, amount0);
            }
        }
        
        if (amount1 > 0) {
            address token1 = address(CarbonCreditAMM(amm).token1());
            uint256 balance = IERC20(token1).balanceOf(address(this));
            
            if (balance >= amount1) {
                keccak256(abi.encodePacked(balance));
                IERC20(token1).transfer(amm, amount1);
            }
        }
    }
    
    /**
     * @dev Attempt manipulation attack on pool reserves
     */
    function _attemptManipulationAttack(
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    ) internal {
        // Try to manipulate by repaying to wrong address or incorrect amounts
        if (amount0 > 0) {
            address token0 = address(CarbonCreditAMM(amm).token0());
            // Try to repay wrong amount
            IERC20(token0).transfer(amm, amount0 + fee0 - 1); // 1 wei short
        }
        
        if (amount1 > 0) {
            address token1 = address(CarbonCreditAMM(amm).token1());
            IERC20(token1).transfer(amm, amount1 + fee1 - 1); // 1 wei short
        }
    }
    
    /**
     * @dev Calculate current k-invariant for analysis
     * @return k Current k-invariant value
     */
    function _calculateKInvariant() internal view returns (uint256 k) {
        // This is a simplified calculation - real implementation would
        // need to access the actual AMM reserve values
        try CarbonCreditAMM(amm).getReserves() returns (uint256 reserve0, uint256 reserve1) {
            k = reserve0 * reserve1;
        } catch {
            k = 0; // Default if unable to access reserves
        }
    }
    
    /**
     * @dev Get attack statistics
     * @return totalAttempts Total attack attempts
     * @return successful Number of successful attacks
     * @return successRate Attack success rate percentage
     */
    function getAttackStats() external view returns (
        uint256 totalAttempts,
        uint256 successful,
        uint256 successRate
    ) {
        totalAttempts = totalAttackAttempts;
        successful = successfulAttacks;
        successRate = totalAttempts > 0 ? (successful * 100) / totalAttempts : 0;
    }
    
    /**
     * @dev Get specific attack result
     * @param attackId Attack identifier
     * @return result Complete attack result
     */
    function getAttackResult(bytes32 attackId) external view returns (AttackResult memory) {
        return attackResults[attackId];
    }
    
    /**
     * @dev Test specific attack type
     * @param attackType Type of attack to test
     * @param amount0 Amount of token0 to borrow
     * @param amount1 Amount of token1 to borrow
     */
    function testAttackType(
        AttackType attackType,
        uint256 amount0,
        uint256 amount1
    ) external {
        bytes memory data = abi.encode(attackType);
        CarbonCreditAMM(amm).flashLoan(amount0, amount1, address(this), data);
    }
    
    /**
     * @dev Reset attack statistics
     */
    function resetStats() external {
        totalAttackAttempts = 0;
        successfulAttacks = 0;
    }
}

interface CarbonCreditAMM {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1);
    function flashLoan(uint256 amount0, uint256 amount1, address recipient, bytes calldata data) external;
}