// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ICarbonCreditAMM
/// @notice Canonical interface for the WRFCoin carbon-credit pool.
///
/// @dev CarbonCreditAMM uses the Uniswap-v2 low-level pair interface
///      (transfer-then-mint/burn/swap) with carbon-specific extensions.
///      It does NOT implement IWrfAMM (wrfcoin/defi-protocols) because the two
///      AMMs serve different asset classes with incompatible router patterns:
///
///      ┌──────────────────────┬────────────────────────────────────────────────┐
///      │ Contract             │ Pattern                                        │
///      ├──────────────────────┼────────────────────────────────────────────────┤
///      │ AMMRouter            │ High-level: swap(tokenIn, tokenOut, amountIn,  │
///      │ (wrfcoin/defi-       │   minAmountOut). Multi-pair, address-based.    │
///      │  protocols)          │ Implements IWrfAMM.                            │
///      ├──────────────────────┼────────────────────────────────────────────────┤
///      │ CarbonCreditAMM      │ Low-level: transfer tokens → mint/burn/swap.   │
///      │ (this repo)          │ Single carbon-credit pair (token0/token1).     │
///      │                      │ ERC-20 LP tokens, flash loans, k-invariant     │
///      │                      │ guard, MEV protection.                         │
///      │                      │ Implements ICarbonCreditAMM (this interface).  │
///      └──────────────────────┴────────────────────────────────────────────────┘
///
///      Fee model: both AMMs use basis-point fees
///      (e.g. feeBasisPoints = 30 → 0.3%, denominator = 10_000).
///      This ensures consistent fee semantics across the WRFCoin DeFi stack.
interface ICarbonCreditAMM {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when liquidity is added
    event Mint(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Emitted when liquidity is removed
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to, uint256 liquidity);

    /// @notice Emitted when a swap is executed
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Emitted when reserves are synced
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice Emitted when a flash loan is executed
    event FlashLoan(
        address indexed borrower,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );

    // -----------------------------------------------------------------------
    // View — pair metadata
    // -----------------------------------------------------------------------

    function token0() external view returns (IERC20);
    function token1() external view returns (IERC20);

    /// @notice Trading fee in basis points (e.g. 30 = 0.3%). Denominator is 10_000.
    function feeBasisPoints() external view returns (uint256);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Spot price of token0 denominated in token1, scaled by 1e18
    function getSpotPrice() external view returns (uint256 price);

    /// @notice Current k-invariant (reserve0 * reserve1)
    function getCurrentK() external view returns (uint256 k);

    // -----------------------------------------------------------------------
    // View — pricing helpers
    // -----------------------------------------------------------------------

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view returns (uint256 amountIn);

    function calculatePriceImpact(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view returns (uint256 priceImpact);

    // -----------------------------------------------------------------------
    // Liquidity — Uniswap-v2 transfer-then-call pattern
    // -----------------------------------------------------------------------

    /// @notice Caller transfers tokens to pool first, then calls mint to receive LP shares
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Caller transfers LP shares to pool first, then calls burn to receive tokens
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    // -----------------------------------------------------------------------
    // Swap — Uniswap-v2 low-level pattern
    // -----------------------------------------------------------------------

    /// @notice Execute a swap. Caller specifies desired output amounts; input is inferred
    ///         from the pool's balance delta. Pass non-empty `data` for flash swaps.
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    // -----------------------------------------------------------------------
    // Flash loans
    // -----------------------------------------------------------------------

    function flashLoan(
        uint256 amount0,
        uint256 amount1,
        address receiver,
        bytes calldata data
    ) external;

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    /// @param feeBasisPoints_ Trading fee in bps (max 1000 = 10%)
    /// @param protocolFeeBasisPoints_ Protocol fee in bps (max 200 = 2%)
    function setFees(uint256 feeBasisPoints_, uint256 protocolFeeBasisPoints_) external;

    function pause() external;
    function unpause() external;
}
