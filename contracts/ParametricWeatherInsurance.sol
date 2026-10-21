// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IWeatherOracle} from "./interfaces/IQualityOracle.sol";

/**
 * @title ParametricWeatherInsurance
 * @notice Parametric weather insurance pools with automatic oracle-triggered payouts.
 *
 * Lifecycle:
 *   1. Admin (POOL_CREATOR_ROLE) creates a pool specifying a station, weather type,
 *      threshold, coverage window, and premium token.
 *   2. Participants call `buyCoverage` before the window opens, paying a premium in
 *      the pool's ERC-20 token.  A fee (feeBps) is immediately forwarded to the treasury.
 *   3. After the window closes, the oracle role calls `resolvePool`.  It fetches the
 *      latest reading from the on-chain IWeatherOracle and flags the pool as either
 *      RESOLVED_TRIGGERED or RESOLVED_NOT_TRIGGERED.
 *      - NOT_TRIGGERED: remaining net premiums are swept to the treasury.
 *   4. If TRIGGERED, coverage-holders call `claim` to receive their pro-rata share of
 *      the net premium pool.
 *
 * Oracle integration:
 *   Uses the canonical IWeatherOracle interface (contracts/interfaces/IQualityOracle.sol).
 *   Values are stored scaled ×100 (e.g., 5 000 = 50 mm rainfall; 2 000 = 20 °C;
 *   -500 = −5 °C).  Thresholds use the same encoding.
 *
 * Fee model:
 *   FEE_DENOMINATOR_BPS = 10 000 (matches the AMM fee convention in this repo).
 *   Maximum fee is capped at MAX_FEE_BPS = 1 000 (10 %).
 */
contract ParametricWeatherInsurance is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Roles ──────────────────────────────────────────────────────────────────

    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant ORACLE_ROLE       = keccak256("ORACLE_ROLE");

    // ── Fee constants ──────────────────────────────────────────────────────────

    uint256 public constant FEE_DENOMINATOR_BPS = 10_000;
    uint256 public constant MAX_FEE_BPS         =  1_000; // 10 %

    // ── Immutables ─────────────────────────────────────────────────────────────

    IWeatherOracle public immutable weatherOracle;
    address        public           treasury;

    // ── Types ──────────────────────────────────────────────────────────────────

    /// @notice Which weather measurement type to evaluate against the threshold.
    enum WeatherType {
        RAINFALL,    // data.rainfall   (mm  × 100, uint)
        TEMPERATURE, // data.temperature (°C  × 100, int)
        WIND_SPEED,  // data.windSpeed   (m/s × 100, uint)
        HUMIDITY     // data.humidity    (%   × 100, uint)
    }

    /// @notice Whether the payout triggers when the observed value is above or below threshold.
    enum ThresholdDirection { ABOVE, BELOW }

    enum PoolState { OPEN, RESOLVED_TRIGGERED, RESOLVED_NOT_TRIGGERED }

    struct InsurancePool {
        bytes32            stationId;
        WeatherType        weatherType;
        ThresholdDirection direction;
        /// @dev Threshold in the same scaled unit as IWeatherOracle.WeatherData fields.
        int256             threshold;
        uint256            windowStart;
        uint256            windowEnd;
        address            premiumToken;
        /// @dev Total raw premium deposited (pre-fee); used for pro-rata coverage share.
        uint256            totalCoverage;
        /// @dev Net premium pool (post-fee) available for payout.
        uint256            netPremiums;
        uint256            feeBps;
        PoolState          state;
        /// @dev Observed oracle value recorded at resolution; 0 before resolution.
        int256             resolvedValue;
        uint256            createdAt;
    }

    // ── State ──────────────────────────────────────────────────────────────────

    mapping(uint256 => InsurancePool)                     private  _pools;
    mapping(uint256 => mapping(address => uint256)) public          coverageOf;
    mapping(uint256 => mapping(address => bool))    public          hasClaimed;

    uint256 public nextPoolId = 1;

    // ── Events ─────────────────────────────────────────────────────────────────

    event PoolCreated(
        uint256 indexed    poolId,
        bytes32 indexed    stationId,
        WeatherType        weatherType,
        ThresholdDirection direction,
        int256             threshold,
        uint256            windowStart,
        uint256            windowEnd,
        uint256            feeBps
    );
    event CoverageBought(
        uint256 indexed poolId,
        address indexed buyer,
        uint256         amount,
        uint256         fee
    );
    event PoolResolved(
        uint256 indexed poolId,
        PoolState       state,
        int256          resolvedValue
    );
    event Claimed(
        uint256 indexed poolId,
        address indexed claimant,
        uint256         amount
    );

    // ── Custom errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InvalidWindow();
    error InvalidFeeBps();
    error PoolNotFound();
    error WindowAlreadyStarted();
    error WindowNotClosed();
    error PoolAlreadyResolved();
    error PoolNotResolved();
    error NotTriggered();
    error AlreadyClaimed();
    error NoCoverage();
    error OracleDataOutsideWindow();

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor(address weatherOracle_, address treasury_) {
        if (weatherOracle_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        weatherOracle = IWeatherOracle(weatherOracle_);
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POOL_CREATOR_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
    }

    // ── Pool admin ─────────────────────────────────────────────────────────────

    /**
     * @notice Open a new parametric insurance pool.
     * @param stationId     IWeatherOracle station identifier for the coverage region.
     * @param weatherType   Which measurement field to evaluate (rainfall, temperature, …).
     * @param direction     Trigger when value is ABOVE or BELOW the threshold.
     * @param threshold     Comparison value in the oracle's scaled unit (×100).
     * @param windowStart   Unix timestamp when the coverage window opens (must be future).
     * @param windowEnd     Unix timestamp when the coverage window closes.
     * @param premiumToken  ERC-20 token used for premium payments.
     * @param feeBps        Fee in basis points forwarded to treasury on each premium (≤ MAX_FEE_BPS).
     */
    function createPool(
        bytes32            stationId,
        WeatherType        weatherType,
        ThresholdDirection direction,
        int256             threshold,
        uint256            windowStart,
        uint256            windowEnd,
        address            premiumToken,
        uint256            feeBps
    ) external onlyRole(POOL_CREATOR_ROLE) returns (uint256 poolId) {
        if (windowStart <= block.timestamp)  revert InvalidWindow();
        if (windowEnd   <= windowStart)      revert InvalidWindow();
        if (premiumToken == address(0))      revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS)            revert InvalidFeeBps();

        poolId = nextPoolId++;
        _pools[poolId] = InsurancePool({
            stationId:     stationId,
            weatherType:   weatherType,
            direction:     direction,
            threshold:     threshold,
            windowStart:   windowStart,
            windowEnd:     windowEnd,
            premiumToken:  premiumToken,
            totalCoverage: 0,
            netPremiums:   0,
            feeBps:        feeBps,
            state:         PoolState.OPEN,
            resolvedValue: 0,
            createdAt:     block.timestamp
        });

        emit PoolCreated(poolId, stationId, weatherType, direction, threshold, windowStart, windowEnd, feeBps);
    }

    function pause()   external onlyRole(POOL_CREATOR_ROLE) { _pause(); }
    function unpause() external onlyRole(POOL_CREATOR_ROLE) { _unpause(); }

    // ── Coverage purchase ──────────────────────────────────────────────────────

    /**
     * @notice Buy coverage in a pool by paying a premium.
     * @dev Only callable before the coverage window opens.  A fee is forwarded to
     *      the treasury immediately; the remainder enters the net-premium pool.
     * @param poolId  Pool to purchase coverage in.
     * @param amount  Premium amount in pool's premiumToken.
     */
    function buyCoverage(uint256 poolId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        InsurancePool storage pool = _pool(poolId);
        if (block.timestamp >= pool.windowStart) revert WindowAlreadyStarted();

        uint256 fee = (amount * pool.feeBps) / FEE_DENOMINATOR_BPS;
        uint256 net = amount - fee;

        IERC20(pool.premiumToken).safeTransferFrom(msg.sender, address(this), amount);
        if (fee > 0) {
            IERC20(pool.premiumToken).safeTransfer(treasury, fee);
        }

        coverageOf[poolId][msg.sender] += amount;
        pool.totalCoverage += amount;
        pool.netPremiums   += net;

        emit CoverageBought(poolId, msg.sender, amount, fee);
    }

    // ── Oracle resolution ──────────────────────────────────────────────────────

    /**
     * @notice Resolve a pool after the coverage window has closed.
     * @dev Fetches the latest weather reading from the on-chain oracle.  The
     *      observation timestamp must fall within [windowStart, windowEnd].
     *      If NOT_TRIGGERED, net premiums are immediately swept to the treasury.
     */
    function resolvePool(uint256 poolId)
        external
        onlyRole(ORACLE_ROLE)
        whenNotPaused
    {
        InsurancePool storage pool = _pool(poolId);
        if (pool.state != PoolState.OPEN)         revert PoolAlreadyResolved();
        if (block.timestamp <= pool.windowEnd)    revert WindowNotClosed();

        IWeatherOracle.WeatherData memory data =
            weatherOracle.getLatestWeatherData(pool.stationId);

        if (data.timestamp < pool.windowStart || data.timestamp > pool.windowEnd) {
            revert OracleDataOutsideWindow();
        }

        int256 observed    = _extractValue(data, pool.weatherType);
        pool.resolvedValue = observed;

        bool triggered = (pool.direction == ThresholdDirection.ABOVE)
            ? (observed > pool.threshold)
            : (observed < pool.threshold);

        pool.state = triggered
            ? PoolState.RESOLVED_TRIGGERED
            : PoolState.RESOLVED_NOT_TRIGGERED;

        // Sweep net premiums to treasury when not triggered.
        if (!triggered && pool.netPremiums > 0) {
            IERC20(pool.premiumToken).safeTransfer(treasury, pool.netPremiums);
        }

        emit PoolResolved(poolId, pool.state, observed);
    }

    // ── Claim ──────────────────────────────────────────────────────────────────

    /**
     * @notice Claim pro-rata payout from a triggered pool.
     * @dev Reverts if the pool was not triggered, if the caller has no coverage, or
     *      if the caller already claimed.
     */
    function claim(uint256 poolId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        InsurancePool storage pool = _pool(poolId);
        if (pool.state == PoolState.OPEN)                       revert PoolNotResolved();
        if (pool.state != PoolState.RESOLVED_TRIGGERED)         revert NotTriggered();
        if (hasClaimed[poolId][msg.sender])                     revert AlreadyClaimed();

        uint256 coverage = coverageOf[poolId][msg.sender];
        if (coverage == 0) revert NoCoverage();

        hasClaimed[poolId][msg.sender] = true;

        // Pro-rata: share of net premiums proportional to coverage units purchased.
        amount = (coverage * pool.netPremiums) / pool.totalCoverage;

        IERC20(pool.premiumToken).safeTransfer(msg.sender, amount);
        emit Claimed(poolId, msg.sender, amount);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function getPool(uint256 poolId) external view returns (InsurancePool memory) {
        return _pool(poolId);
    }

    /**
     * @notice Pre-claim amount estimate for a coverage-holder in a triggered pool.
     */
    function claimableAmount(uint256 poolId, address buyer) external view returns (uint256) {
        InsurancePool storage pool = _pool(poolId);
        if (pool.state != PoolState.RESOLVED_TRIGGERED) return 0;
        if (hasClaimed[poolId][buyer]) return 0;
        uint256 coverage = coverageOf[poolId][buyer];
        if (coverage == 0 || pool.totalCoverage == 0) return 0;
        return (coverage * pool.netPremiums) / pool.totalCoverage;
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    function _pool(uint256 poolId) internal view returns (InsurancePool storage) {
        InsurancePool storage pool = _pools[poolId];
        if (pool.createdAt == 0) revert PoolNotFound();
        return pool;
    }

    /**
     * @dev Extract the relevant measurement from a WeatherData snapshot and
     *      return it as a signed integer for threshold comparison.
     *      All IWeatherOracle values are scaled ×100.
     */
    function _extractValue(
        IWeatherOracle.WeatherData memory data,
        WeatherType weatherType
    ) internal pure returns (int256) {
        if (weatherType == WeatherType.RAINFALL)   return int256(data.rainfall);
        if (weatherType == WeatherType.WIND_SPEED)  return int256(data.windSpeed);
        if (weatherType == WeatherType.HUMIDITY)    return int256(data.humidity);
        return data.temperature; // TEMPERATURE is already int256
    }
}
