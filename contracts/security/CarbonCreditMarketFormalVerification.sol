// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICarbonCreditAMMFormal {
    function expectedFactory() external view returns (address);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function feeBasisPoints() external view returns (uint256);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view returns (uint256 amountOut);
}

interface ICarbonPoolRouterFormal {
    struct PoolInfo {
        address poolAddress;
        uint8 poolType;
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 swapFee;
        bool isActive;
    }

    struct SwapRoute {
        address[] pools;
        uint8[] poolTypes;
        address[] tokens;
        uint256[] amounts;
        uint256 totalAmountOut;
        uint256 totalFees;
    }

    function getPoolsByTokenPair(
        address token0,
        address token1
    ) external view returns (PoolInfo[] memory);

    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (SwapRoute memory);

    function authorizedPools(address pool) external view returns (bool);
}

/**
 * @title CarbonCreditMarketFormalVerification
 * @notice Deterministic on-chain assertions for CarbonCreditAMM and the
 *         CarbonPoolRouter.
 * @dev This contract is intentionally small and view-only so the formal
 *      verification surface stays easy to exercise in CI.
 */
contract CarbonCreditMarketFormalVerification {
    uint256 public constant MAX_FEE_BASIS_POINTS = 1000;

    function verifyAmmConfiguration(address amm) external view returns (bool) {
        if (amm == address(0)) {
            return false;
        }

        try ICarbonCreditAMMFormal(amm).expectedFactory() returns (
            address expectedFactory
        ) {
            if (expectedFactory == address(0)) {
                return false;
            }

            try ICarbonCreditAMMFormal(amm).factory() returns (address factory) {
                if (factory != expectedFactory) {
                    return false;
                }

                try ICarbonCreditAMMFormal(amm).token0() returns (
                    address token0
                ) {
                    try ICarbonCreditAMMFormal(amm).token1() returns (
                        address token1
                    ) {
                        try ICarbonCreditAMMFormal(amm).feeBasisPoints() returns (
                            uint256 feeBasisPoints
                        ) {
                            return
                                token0 != address(0) &&
                                token1 != address(0) &&
                                token0 != token1 &&
                                token0 < token1 &&
                                feeBasisPoints > 0 &&
                                feeBasisPoints <= MAX_FEE_BASIS_POINTS;
                        } catch {
                            return false;
                        }
                    } catch {
                        return false;
                    }
                } catch {
                    return false;
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyAmmPricingBounds(
        address amm,
        uint256 amountIn
    ) external view returns (bool) {
        if (amm == address(0) || amountIn == 0) {
            return false;
        }

        try ICarbonCreditAMMFormal(amm).getReserves() returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32
        ) {
            if (reserve0 == 0 || reserve1 == 0) {
                return false;
            }

            try ICarbonCreditAMMFormal(amm).getAmountOut(
                amountIn,
                reserve0,
                reserve1
            ) returns (uint256 amountOutForward) {
                if (amountOutForward >= reserve1) {
                    return false;
                }

                try ICarbonCreditAMMFormal(amm).getAmountOut(
                    amountIn,
                    reserve1,
                    reserve0
                ) returns (uint256 amountOutReverse) {
                    return amountOutReverse < reserve0;
                } catch {
                    return false;
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyRouterPairSymmetry(
        address router,
        address tokenA,
        address tokenB
    ) external view returns (bool) {
        if (
            router == address(0) ||
            tokenA == address(0) ||
            tokenB == address(0) ||
            tokenA == tokenB
        ) {
            return false;
        }

        try ICarbonPoolRouterFormal(router).getPoolsByTokenPair(
            tokenA,
            tokenB
        ) returns (ICarbonPoolRouterFormal.PoolInfo[] memory forward) {
            try ICarbonPoolRouterFormal(router).getPoolsByTokenPair(
                tokenB,
                tokenA
            ) returns (ICarbonPoolRouterFormal.PoolInfo[] memory reverse) {
                if (forward.length != reverse.length) {
                    return false;
                }

                for (uint256 i = 0; i < forward.length; i++) {
                    if (
                        forward[i].poolAddress != reverse[i].poolAddress ||
                        forward[i].poolType != reverse[i].poolType ||
                        forward[i].token0 != reverse[i].token0 ||
                        forward[i].token1 != reverse[i].token1 ||
                        forward[i].isActive != reverse[i].isActive
                    ) {
                        return false;
                    }
                }

                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyRouterRouteShape(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (bool) {
        if (
            router == address(0) ||
            tokenIn == address(0) ||
            tokenOut == address(0) ||
            tokenIn == tokenOut ||
            amountIn == 0
        ) {
            return false;
        }

        try ICarbonPoolRouterFormal(router).getBestRoute(
            tokenIn,
            tokenOut,
            amountIn
        ) returns (ICarbonPoolRouterFormal.SwapRoute memory route) {
            if (route.pools.length == 0 || route.totalAmountOut == 0) {
                return false;
            }

            if (route.tokens.length != route.pools.length + 1) {
                return false;
            }

            if (route.amounts.length != route.pools.length) {
                return false;
            }

            if (
                route.tokens[0] != tokenIn ||
                route.tokens[route.tokens.length - 1] != tokenOut
            ) {
                return false;
            }

            if (route.totalFees > amountIn) {
                return false;
            }

            for (uint256 i = 0; i < route.pools.length; i++) {
                if (!ICarbonPoolRouterFormal(router).authorizedPools(route.pools[i])) {
                    return false;
                }
            }

            return true;
        } catch {
            return false;
        }
    }
}
