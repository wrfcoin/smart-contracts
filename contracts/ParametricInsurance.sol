// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IQualityOracle.sol";

/**
 * @title ParametricInsurance
 * @notice Weather insurance pools with automatic payouts triggered by oracle data.
 * @dev Pools are created around a single station/region and settle once a weather
 *      threshold is crossed. Premium deposits are used to reserve payout capacity,
 *      and anyone can trigger settlement by calling evaluateAndSettle().
 */
contract ParametricInsurance is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_POLICIES_PER_POOL = 50;

    IERC20 public immutable payoutToken;
    uint256 public nextPoolId = 1;
    uint256 public nextPolicyId = 1;

    struct Pool {
        bytes32 regionId;
        bytes32 stationId;
        address oracle;
        int256 temperatureThreshold;
        uint256 windThreshold;
        uint256 payoutBps;
        uint256 premiumBps;
        uint256 maxCoveragePerPolicy;
        uint256 maxOracleAge;
        uint256 maxPolicies;
        uint256 liquidity;
        uint256 reservedLiability;
        uint256 totalPremiums;
        uint256 totalPayouts;
        uint256 policyCount;
        uint256 createdAt;
        uint256 settledAt;
        bool active;
        bool settled;
    }

    struct Policy {
        uint256 poolId;
        address holder;
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 payoutAmount;
        uint256 purchasedAt;
        uint256 paidAt;
        bool active;
        bool paid;
    }

    mapping(uint256 => Pool) private _pools;
    mapping(uint256 => Policy) private _policies;
    mapping(uint256 => uint256[]) private _poolPolicyIds;

    event PoolCreated(
        uint256 indexed poolId,
        bytes32 indexed regionId,
        bytes32 indexed stationId,
        address oracle,
        int256 temperatureThreshold,
        uint256 windThreshold,
        uint256 payoutBps,
        uint256 premiumBps
    );
    event PoolFunded(uint256 indexed poolId, address indexed funder, uint256 amount, uint256 liquidity);
    event CoveragePurchased(
        uint256 indexed policyId,
        uint256 indexed poolId,
        address indexed holder,
        uint256 coverageAmount,
        uint256 premiumPaid,
        uint256 payoutAmount
    );
    event PoolTriggered(
        uint256 indexed poolId,
        int256 temperature,
        uint256 windSpeed,
        uint256 observedAt,
        uint256 payoutCount,
        uint256 totalPayout
    );
    event PolicyPayoutExecuted(
        uint256 indexed policyId,
        uint256 indexed poolId,
        address indexed holder,
        uint256 payoutAmount
    );
    event PoolStatusUpdated(uint256 indexed poolId, bool active, bool settled);

    error ParametricInsuranceInvalidAddress();
    error ParametricInsuranceInvalidThreshold();
    error ParametricInsuranceInvalidRate();
    error ParametricInsuranceInvalidPolicyLimit();
    error ParametricInsurancePoolNotFound(uint256 poolId);
    error ParametricInsurancePoolInactive(uint256 poolId);
    error ParametricInsurancePoolSettled(uint256 poolId);
    error ParametricInsuranceCoverageTooLarge(uint256 requested, uint256 maximum);
    error ParametricInsuranceCoverageTooSmall();
    error ParametricInsuranceInsufficientCapacity();
    error ParametricInsuranceOracleStale(uint256 poolId, uint256 observedAt, uint256 maxAge);
    error ParametricInsurancePolicyNotFound(uint256 policyId);
    error ParametricInsurancePolicyInactive(uint256 policyId);
    error ParametricInsuranceAlreadyTriggered(uint256 poolId);

    constructor(address token_, address admin) {
        if (token_ == address(0) || admin == address(0)) {
            revert ParametricInsuranceInvalidAddress();
        }

        payoutToken = IERC20(token_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_MANAGER_ROLE, admin);
    }

    function createPool(
        bytes32 regionId,
        bytes32 stationId,
        address oracle,
        int256 temperatureThreshold,
        uint256 windThreshold,
        uint256 payoutBps,
        uint256 premiumBps,
        uint256 maxCoveragePerPolicy,
        uint256 maxOracleAge,
        uint256 maxPolicies
    ) external onlyRole(POOL_MANAGER_ROLE) returns (uint256 poolId) {
        if (oracle == address(0)) revert ParametricInsuranceInvalidAddress();
        if (temperatureThreshold == 0 && windThreshold == 0) {
            revert ParametricInsuranceInvalidThreshold();
        }
        if (payoutBps == 0 || premiumBps == 0) revert ParametricInsuranceInvalidRate();
        if (maxCoveragePerPolicy == 0 || maxOracleAge == 0) {
            revert ParametricInsuranceInvalidPolicyLimit();
        }
        if (maxPolicies == 0 || maxPolicies > MAX_POLICIES_PER_POOL) {
            revert ParametricInsuranceInvalidPolicyLimit();
        }

        poolId = nextPoolId++;
        _pools[poolId] = Pool({
            regionId: regionId,
            stationId: stationId,
            oracle: oracle,
            temperatureThreshold: temperatureThreshold,
            windThreshold: windThreshold,
            payoutBps: payoutBps,
            premiumBps: premiumBps,
            maxCoveragePerPolicy: maxCoveragePerPolicy,
            maxOracleAge: maxOracleAge,
            maxPolicies: maxPolicies,
            liquidity: 0,
            reservedLiability: 0,
            totalPremiums: 0,
            totalPayouts: 0,
            policyCount: 0,
            createdAt: block.timestamp,
            settledAt: 0,
            active: true,
            settled: false
        });

        emit PoolCreated(
            poolId,
            regionId,
            stationId,
            oracle,
            temperatureThreshold,
            windThreshold,
            payoutBps,
            premiumBps
        );
    }

    function fundPool(uint256 poolId, uint256 amount) external whenNotPaused nonReentrant {
        Pool storage pool = _getActivePool(poolId);
        if (amount == 0) revert ParametricInsuranceCoverageTooSmall();

        payoutToken.safeTransferFrom(msg.sender, address(this), amount);

        pool.liquidity += amount;
        emit PoolFunded(poolId, msg.sender, amount, pool.liquidity);
    }

    function buyCoverage(
        uint256 poolId,
        uint256 coverageAmount
    ) external whenNotPaused nonReentrant returns (uint256 policyId) {
        Pool storage pool = _getActivePool(poolId);
        if (coverageAmount == 0) revert ParametricInsuranceCoverageTooSmall();
        if (coverageAmount > pool.maxCoveragePerPolicy) {
            revert ParametricInsuranceCoverageTooLarge(coverageAmount, pool.maxCoveragePerPolicy);
        }
        if (pool.policyCount >= pool.maxPolicies) {
            revert ParametricInsuranceInvalidPolicyLimit();
        }

        uint256 premiumPaid = (coverageAmount * pool.premiumBps) / BASIS_POINTS;
        uint256 payoutAmount = (coverageAmount * pool.payoutBps) / BASIS_POINTS;
        if (premiumPaid == 0 || payoutAmount == 0) revert ParametricInsuranceCoverageTooSmall();

        uint256 postDepositLiquidity = pool.liquidity + premiumPaid;
        if (postDepositLiquidity < pool.reservedLiability + payoutAmount) {
            revert ParametricInsuranceInsufficientCapacity();
        }

        payoutToken.safeTransferFrom(msg.sender, address(this), premiumPaid);

        pool.liquidity = postDepositLiquidity;
        pool.totalPremiums += premiumPaid;
        pool.reservedLiability += payoutAmount;
        pool.policyCount += 1;

        policyId = nextPolicyId++;
        _policies[policyId] = Policy({
            poolId: poolId,
            holder: msg.sender,
            coverageAmount: coverageAmount,
            premiumPaid: premiumPaid,
            payoutAmount: payoutAmount,
            purchasedAt: block.timestamp,
            paidAt: 0,
            active: true,
            paid: false
        });
        _poolPolicyIds[poolId].push(policyId);

        emit CoveragePurchased(policyId, poolId, msg.sender, coverageAmount, premiumPaid, payoutAmount);
    }

    function evaluateAndSettle(
        uint256 poolId
    ) public whenNotPaused nonReentrant returns (bool triggered, uint256 payoutCount, uint256 totalPayout) {
        Pool storage pool = _getPool(poolId);
        if (pool.settled) {
            return (true, 0, 0);
        }

        IWeatherOracle.WeatherData memory reading = IWeatherOracle(pool.oracle).getLatestWeatherData(
            pool.stationId
        );
        if (reading.timestamp == 0 || block.timestamp - reading.timestamp > pool.maxOracleAge) {
            revert ParametricInsuranceOracleStale(poolId, reading.timestamp, pool.maxOracleAge);
        }

        bool thresholdCrossed = _thresholdCrossed(pool, reading);
        if (!thresholdCrossed) {
            return (false, 0, 0);
        }

        pool.settled = true;
        pool.active = false;
        pool.settledAt = block.timestamp;

        uint256[] storage policyIds = _poolPolicyIds[poolId];
        for (uint256 i = 0; i < policyIds.length; i++) {
            Policy storage policy = _policies[policyIds[i]];
            if (!policy.active || policy.paid) {
                continue;
            }

            policy.active = false;
            policy.paid = true;
            policy.paidAt = block.timestamp;
            pool.reservedLiability -= policy.payoutAmount;
            pool.totalPayouts += policy.payoutAmount;
            totalPayout += policy.payoutAmount;
            payoutCount += 1;

            payoutToken.safeTransfer(policy.holder, policy.payoutAmount);
            emit PolicyPayoutExecuted(policyIds[i], poolId, policy.holder, policy.payoutAmount);
        }

        if (pool.liquidity < totalPayout) {
            revert ParametricInsuranceInsufficientCapacity();
        }

        pool.liquidity -= totalPayout;

        emit PoolTriggered(
            poolId,
            reading.temperature,
            reading.windSpeed,
            reading.timestamp,
            payoutCount,
            totalPayout
        );
        emit PoolStatusUpdated(poolId, pool.active, pool.settled);

        triggered = true;
    }

    function getPool(
        uint256 poolId
    )
        external
        view
        returns (
            bytes32 regionId,
            bytes32 stationId,
            address oracle,
            int256 temperatureThreshold,
            uint256 windThreshold,
            uint256 payoutBps,
            uint256 premiumBps,
            uint256 maxCoveragePerPolicy,
            uint256 maxOracleAge,
            uint256 maxPolicies,
            uint256 liquidity,
            uint256 reservedLiability,
            uint256 totalPremiums,
            uint256 totalPayouts,
            uint256 policyCount,
            uint256 createdAt,
            uint256 settledAt,
            bool active,
            bool settled
        )
    {
        Pool storage pool = _getPool(poolId);
        return (
            pool.regionId,
            pool.stationId,
            pool.oracle,
            pool.temperatureThreshold,
            pool.windThreshold,
            pool.payoutBps,
            pool.premiumBps,
            pool.maxCoveragePerPolicy,
            pool.maxOracleAge,
            pool.maxPolicies,
            pool.liquidity,
            pool.reservedLiability,
            pool.totalPremiums,
            pool.totalPayouts,
            pool.policyCount,
            pool.createdAt,
            pool.settledAt,
            pool.active,
            pool.settled
        );
    }

    function getPolicy(
        uint256 policyId
    )
        external
        view
        returns (
            uint256 poolId,
            address holder,
            uint256 coverageAmount,
            uint256 premiumPaid,
            uint256 payoutAmount,
            uint256 purchasedAt,
            uint256 paidAt,
            bool active,
            bool paid
        )
    {
        Policy storage policy = _getPolicy(policyId);
        return (
            policy.poolId,
            policy.holder,
            policy.coverageAmount,
            policy.premiumPaid,
            policy.payoutAmount,
            policy.purchasedAt,
            policy.paidAt,
            policy.active,
            policy.paid
        );
    }

    function getPoolPolicyIds(uint256 poolId) external view returns (uint256[] memory) {
        _getPool(poolId);
        return _poolPolicyIds[poolId];
    }

    function previewPricing(
        uint256 poolId,
        uint256 coverageAmount
    ) external view returns (uint256 premiumPaid, uint256 payoutAmount) {
        Pool storage pool = _getPool(poolId);
        premiumPaid = (coverageAmount * pool.premiumBps) / BASIS_POINTS;
        payoutAmount = (coverageAmount * pool.payoutBps) / BASIS_POINTS;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _getPool(uint256 poolId) internal view returns (Pool storage pool) {
        if (poolId == 0 || poolId >= nextPoolId) revert ParametricInsurancePoolNotFound(poolId);
        pool = _pools[poolId];
        if (pool.oracle == address(0)) revert ParametricInsurancePoolNotFound(poolId);
    }

    function _getActivePool(uint256 poolId) internal view returns (Pool storage pool) {
        pool = _getPool(poolId);
        if (!pool.active) revert ParametricInsurancePoolInactive(poolId);
        if (pool.settled) revert ParametricInsurancePoolSettled(poolId);
    }

    function _getPolicy(uint256 policyId) internal view returns (Policy storage policy) {
        if (policyId == 0 || policyId >= nextPolicyId) revert ParametricInsurancePolicyNotFound(policyId);
        policy = _policies[policyId];
        if (policy.holder == address(0)) revert ParametricInsurancePolicyNotFound(policyId);
    }

    function _thresholdCrossed(Pool storage pool, IWeatherOracle.WeatherData memory reading) internal view returns (bool) {
        bool temperatureTriggered = pool.temperatureThreshold != 0 &&
            reading.temperature >= pool.temperatureThreshold;
        bool windTriggered = pool.windThreshold != 0 &&
            reading.windSpeed >= pool.windThreshold;
        return temperatureTriggered || windTriggered;
    }
}
