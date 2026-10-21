// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title WeightedMath
 * @dev Library for weighted AMM mathematics based on Balancer V2 formulas
 * Implements constant value function: V = Π(Balance_i^Weight_i)
 */
library WeightedMath {
    
    uint256 internal constant ONE = 1e18; // 18 decimal fixed point
    uint256 internal constant BONE = ONE;
    
    uint256 internal constant MIN_WEIGHT = ONE / 50; // 2%
    uint256 internal constant MAX_WEIGHT = ONE - MIN_WEIGHT; // 98%
    
    uint256 internal constant MIN_BALANCE = ONE / 1e12; // Minimum balance
    uint256 internal constant MAX_BALANCE = ONE * 1e12; // Maximum balance
    
    uint256 internal constant MIN_FEE = ONE / 1e6; // 0.0001%
    uint256 internal constant MAX_FEE = ONE / 10; // 10%
    
    uint256 internal constant BONE_DIV_2 = BONE / 2;
    uint256 internal constant EXIT_FEE = 0; // No exit fee for now
    
    error WeightedMath__InvalidWeight();
    error WeightedMath__InvalidBalance();
    error WeightedMath__InvalidFee();
    error WeightedMath__DivByZero();
    error WeightedMath__Overflow();
    
    /**
     * @dev Calculate spot price between two tokens
     * @param balanceIn Balance of token going in
     * @param weightIn Weight of token going in (normalized to 1e18)
     * @param balanceOut Balance of token going out
     * @param weightOut Weight of token going out (normalized to 1e18)
     * @return spotPrice The spot price ratio
     */
    function calcSpotPrice(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut
    ) internal pure returns (uint256 spotPrice) {
        if (balanceIn == 0 || balanceOut == 0) revert WeightedMath__InvalidBalance();
        if (weightIn == 0 || weightOut == 0) revert WeightedMath__InvalidWeight();
        
        uint256 numer = bdiv(balanceIn, weightIn);
        uint256 denom = bdiv(balanceOut, weightOut);
        return bdiv(numer, denom);
    }
    
    /**
     * @dev Calculate tokens out given tokens in
     * @param balanceIn Current balance of token going in
     * @param weightIn Weight of token going in
     * @param balanceOut Current balance of token going out
     * @param weightOut Weight of token going out
     * @param amountIn Amount of tokens going in
     * @param swapFee Swap fee (as a fraction of 1e18)
     * @return amountOut Amount of tokens going out
     */
    function calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn,
        uint256 swapFee
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        
        // Validate inputs
        _validateBalance(balanceIn);
        _validateBalance(balanceOut);
        _validateWeight(weightIn);
        _validateWeight(weightOut);
        _validateFee(swapFee);
        
        // Calculate amount in after fee
        uint256 amountInAfterFee = bmul(amountIn, bsub(ONE, swapFee));
        
        // Calculate the ratio of new balance to old balance
        uint256 balanceRatio = bdiv(badd(balanceIn, amountInAfterFee), balanceIn);
        
        // Calculate weight ratio (weightIn / weightOut)
        uint256 weightRatio = bdiv(weightIn, weightOut);
        
        // Calculate the power: balanceRatio^weightRatio
        uint256 adjustedBalanceRatio = bpow(balanceRatio, weightRatio);
        
        // Calculate amount out: balanceOut * (1 - adjustedBalanceRatio)
        amountOut = bmul(balanceOut, bsub(ONE, adjustedBalanceRatio));
        
        return amountOut;
    }
    
    /**
     * @dev Calculate tokens in given tokens out
     * @param balanceIn Current balance of token going in
     * @param weightIn Weight of token going in
     * @param balanceOut Current balance of token going out
     * @param weightOut Weight of token going out
     * @param amountOut Amount of tokens going out
     * @param swapFee Swap fee (as a fraction of 1e18)
     * @return amountIn Amount of tokens going in
     */
    function calcInGivenOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut,
        uint256 swapFee
    ) internal pure returns (uint256 amountIn) {
        if (amountOut == 0) return 0;
        if (amountOut >= balanceOut) revert WeightedMath__InvalidBalance();
        
        // Validate inputs
        _validateBalance(balanceIn);
        _validateBalance(balanceOut);
        _validateWeight(weightIn);
        _validateWeight(weightOut);
        _validateFee(swapFee);
        
        // Calculate the ratio of new balance to old balance
        uint256 balanceRatio = bdiv(bsub(balanceOut, amountOut), balanceOut);
        
        // Calculate weight ratio (weightOut / weightIn)
        uint256 weightRatio = bdiv(weightOut, weightIn);
        
        // Calculate the power: balanceRatio^weightRatio
        uint256 adjustedBalanceRatio = bpow(balanceRatio, weightRatio);
        
        // Calculate amount in before fee: balanceIn * (1/adjustedBalanceRatio - 1)
        uint256 amountInBeforeFee = bmul(balanceIn, bsub(bdiv(ONE, adjustedBalanceRatio), ONE));
        
        // Account for swap fee
        amountIn = bdiv(amountInBeforeFee, bsub(ONE, swapFee));
        
        return amountIn;
    }
    
    /**
     * @dev Calculate pool tokens out given single token in
     * @param balance Current balance of the token
     * @param normalizedWeight Normalized weight of the token
     * @param poolSupply Current pool token supply
     * @param amountIn Amount of tokens going in
     * @param swapFee Swap fee
     * @return poolAmountOut Amount of pool tokens to mint
     */
    function calcPoolOutGivenSingleIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 poolSupply,
        uint256 amountIn,
        uint256 swapFee
    ) internal pure returns (uint256 poolAmountOut) {
        if (amountIn == 0) return 0;
        
        _validateBalance(balance);
        _validateWeight(normalizedWeight);
        _validateFee(swapFee);
        
        // Calculate amount in after fee
        uint256 amountInAfterFee = bmul(amountIn, bsub(ONE, swapFee));
        
        // Calculate balance ratio
        uint256 balanceRatio = bdiv(badd(balance, amountInAfterFee), balance);
        
        // Calculate pool ratio: balanceRatio^normalizedWeight
        uint256 poolRatio = bpow(balanceRatio, normalizedWeight);
        
        // Calculate pool tokens out
        poolAmountOut = bmul(poolSupply, bsub(poolRatio, ONE));
        
        return poolAmountOut;
    }
    
    /**
     * @dev Calculate single token out given pool tokens in
     * @param balance Current balance of the token
     * @param normalizedWeight Normalized weight of the token
     * @param poolSupply Current pool token supply
     * @param poolAmountIn Amount of pool tokens going in
     * @param swapFee Swap fee
     * @return amountOut Amount of tokens going out
     */
    function calcSingleOutGivenPoolIn(
        uint256 balance,
        uint256 normalizedWeight,
        uint256 poolSupply,
        uint256 poolAmountIn,
        uint256 swapFee
    ) internal pure returns (uint256 amountOut) {
        if (poolAmountIn == 0) return 0;
        if (poolAmountIn >= poolSupply) revert WeightedMath__InvalidBalance();
        
        _validateBalance(balance);
        _validateWeight(normalizedWeight);
        _validateFee(swapFee);
        
        // Calculate pool ratio
        uint256 poolRatio = bdiv(bsub(poolSupply, poolAmountIn), poolSupply);
        
        // Calculate balance ratio: poolRatio^(1/normalizedWeight)
        uint256 balanceRatio = bpow(poolRatio, bdiv(ONE, normalizedWeight));
        
        // Calculate amount out before fee
        uint256 amountOutBeforeFee = bmul(balance, bsub(ONE, balanceRatio));
        
        // Apply exit fee
        amountOut = bmul(amountOutBeforeFee, bsub(ONE, EXIT_FEE));
        
        return amountOut;
    }
    
    /**
     * @dev Calculate invariant given balances and weights
     * @param balances Array of token balances
     * @param weights Array of normalized weights
     * @return invariant The pool invariant
     */
    function calcInvariant(
        uint256[] memory balances,
        uint256[] memory weights
    ) internal pure returns (uint256 invariant) {
        if (balances.length != weights.length) revert WeightedMath__InvalidWeight();
        if (balances.length == 0) revert WeightedMath__InvalidBalance();
        
        invariant = ONE;
        
        for (uint256 i = 0; i < balances.length; i++) {
            _validateBalance(balances[i]);
            _validateWeight(weights[i]);
            
            // invariant = invariant * (balance[i] ^ weight[i])
            invariant = bmul(invariant, bpow(balances[i], weights[i]));
        }
        
        return invariant;
    }
    
    // ========== BALANCER MATH UTILITIES ==========
    
    function badd(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        if (c < a) revert WeightedMath__Overflow();
        return c;
    }
    
    function bsub(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b > a) revert WeightedMath__DivByZero();
        return a - b;
    }
    
    function bmul(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c0 = a * b;
        if (a != 0 && c0 / a != b) revert WeightedMath__Overflow();
        uint256 c1 = c0 + (BONE / 2);
        if (c1 < c0) revert WeightedMath__Overflow();
        uint256 c2 = c1 / BONE;
        return c2;
    }
    
    function bdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert WeightedMath__DivByZero();
        uint256 c0 = a * BONE;
        if (a != 0 && c0 / a != BONE) revert WeightedMath__Overflow();
        uint256 c1 = c0 + (b / 2);
        if (c1 < c0) revert WeightedMath__Overflow();
        uint256 c2 = c1 / b;
        return c2;
    }
    
    function bpow(uint256 base, uint256 exp) internal pure returns (uint256) {
        if (base == 0) return 0;
        if (exp == 0) return BONE;
        if (exp == BONE) return base;
        
        // Use simplified power calculation for common cases
        if (exp == BONE_DIV_2) {
            return bsqrt(base);
        }
        
        // For other cases, use approximation
        return bpowApprox(base, exp);
    }
    
    function bpowApprox(uint256 base, uint256 exp) internal pure returns (uint256) {
        if (base >= 2 * BONE || base <= BONE / 2) {
            return bpowInternal(base, exp);
        }
        
        // For base close to 1, use Taylor series approximation
        uint256 baseMinusOne = bsub(base, BONE);
        uint256 expMulBaseMinusOne = bmul(exp, baseMinusOne);
        
        // First order approximation: 1 + exp * (base - 1)
        return badd(BONE, expMulBaseMinusOne);
    }
    
    function bpowInternal(uint256 base, uint256 exp) internal pure returns (uint256) {
        uint256 whole = bfloor(exp);
        uint256 remain = bsub(exp, whole);
        
        uint256 wholePow = bpowi(base, btoi(whole));
        
        if (remain == 0) {
            return wholePow;
        }
        
        uint256 partialResult = bpowApproxInternal(base, remain);
        return bmul(wholePow, partialResult);
    }
    
    function bpowApproxInternal(uint256 base, uint256 exp) internal pure returns (uint256) {
        uint256 a = exp;
        uint256 x = bsub(base, BONE);
        uint256 term = BONE;
        uint256 sum = term;
        bool negative = false;
        
        for (uint256 i = 1; term >= BONE / 1000; i++) {
            uint256 bigK = bmul(bmul(a, bsub(a, BONE)), bdiv(BONE, bfromInt(i)));
            uint256 c = bmul(bigK, x);
            term = bdiv(term, c);
            
            if (term == 0) break;
            
            if (negative) {
                sum = bsub(sum, term);
            } else {
                sum = badd(sum, term);
            }
            negative = !negative;
            a = bsub(a, BONE);
        }
        
        return sum;
    }
    
    function bpowi(uint256 a, uint256 n) internal pure returns (uint256) {
        uint256 z = n % 2 != 0 ? a : BONE;
        
        for (n /= 2; n != 0; n /= 2) {
            a = bmul(a, a);
            
            if (n % 2 != 0) {
                z = bmul(z, a);
            }
        }
        return z;
    }
    
    function bsqrt(uint256 y) internal pure returns (uint256) {
        if (y == 0) return 0;
        
        uint256 z = y;
        uint256 x = (y + 1) / 2;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
        return z;
    }
    
    function btoi(uint256 a) internal pure returns (uint256) {
        return a / BONE;
    }
    
    function bfromInt(uint256 a) internal pure returns (uint256) {
        return a * BONE;
    }
    
    function bfloor(uint256 a) internal pure returns (uint256) {
        return btoi(a) * BONE;
    }
    
    // ========== VALIDATION FUNCTIONS ==========
    
    function _validateWeight(uint256 weight) private pure {
        if (weight < MIN_WEIGHT || weight > MAX_WEIGHT) {
            revert WeightedMath__InvalidWeight();
        }
    }
    
    function _validateBalance(uint256 balance) private pure {
        if (balance < MIN_BALANCE || balance > MAX_BALANCE) {
            revert WeightedMath__InvalidBalance();
        }
    }
    
    function _validateFee(uint256 fee) private pure {
        if (fee < MIN_FEE || fee > MAX_FEE) {
            revert WeightedMath__InvalidFee();
        }
    }
}