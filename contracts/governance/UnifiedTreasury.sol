// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Multi-asset DAO treasury with auditable, period-bounded allocations.
/// @dev Asset transfers settle to on-chain recipient addresses. Paying external
///      APIs/vendors remains an off-chain executor responsibility.
contract UnifiedTreasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ALLOCATION_EXECUTOR_ROLE = keccak256("ALLOCATION_EXECUTOR_ROLE");
    uint16 public constant WINDOW_SLOT_COUNT = 24;

    struct AllocationBucket {
        address asset; // address(0) for native ETH
        address recipient;
        uint128 periodLimit;
        uint128 spentInPeriod;
        uint64 periodSeconds;
        bool enabled;
    }

    struct AllocationWindowBucket {
        uint64 slotId;
        uint128 spent;
        bool initialized;
    }

    mapping(bytes32 => AllocationBucket) private _buckets;
    mapping(bytes32 => mapping(uint16 => AllocationWindowBucket)) private _bucketWindowSpending;

    event Deposited(address indexed asset, address indexed from, uint256 amount, bytes32 indexed sourceRef);
    event BucketConfigured(bytes32 indexed bucketId, address indexed asset, address indexed recipient, uint256 periodLimit, uint64 periodSeconds, bool enabled);
    event AllocationExecuted(bytes32 indexed bucketId, address indexed asset, address indexed recipient, uint256 amount, uint256 spentInPeriod);

    constructor(address governance) {
        require(governance != address(0), "UnifiedTreasury: zero governance");
        _grantRole(DEFAULT_ADMIN_ROLE, governance);
        _grantRole(ALLOCATION_EXECUTOR_ROLE, governance);
    }

    receive() external payable {
        emit Deposited(address(0), msg.sender, msg.value, bytes32(0));
    }

    function depositNative(bytes32 sourceRef) external payable {
        require(msg.value > 0, "UnifiedTreasury: zero deposit");
        emit Deposited(address(0), msg.sender, msg.value, sourceRef);
    }

    function depositERC20(address asset, uint256 amount, bytes32 sourceRef) external nonReentrant {
        require(asset != address(0), "UnifiedTreasury: native uses depositNative");
        require(amount > 0, "UnifiedTreasury: zero deposit");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(asset, msg.sender, amount, sourceRef);
    }

    function configureBucket(
        bytes32 bucketId,
        address asset,
        address recipient,
        uint128 periodLimit,
        uint64 periodSeconds,
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bucketId != bytes32(0), "UnifiedTreasury: zero bucket");
        require(recipient != address(0), "UnifiedTreasury: zero recipient");
        require(periodLimit > 0, "UnifiedTreasury: zero limit");
        require(periodSeconds > 0, "UnifiedTreasury: zero period");

        AllocationBucket storage bucket = _buckets[bucketId];
        for (uint16 i = 0; i < WINDOW_SLOT_COUNT; i++) {
            delete _bucketWindowSpending[bucketId][i];
        }

        bucket.asset = asset;
        bucket.recipient = recipient;
        bucket.periodLimit = periodLimit;
        bucket.spentInPeriod = 0;
        bucket.periodSeconds = periodSeconds;
        bucket.enabled = enabled;
        emit BucketConfigured(bucketId, asset, recipient, periodLimit, periodSeconds, enabled);
    }

    function executeAllocation(bytes32 bucketId, uint256 amount)
        external
        nonReentrant
        onlyRole(ALLOCATION_EXECUTOR_ROLE)
    {
        AllocationBucket storage bucket = _buckets[bucketId];
        require(bucket.recipient != address(0), "UnifiedTreasury: unknown bucket");
        require(bucket.enabled, "UnifiedTreasury: bucket disabled");
        require(amount > 0, "UnifiedTreasury: zero allocation");
        require(amount <= uint256(bucket.periodLimit), "UnifiedTreasury: bucket limit exceeded");

        _accrueAllocation(bucketId, bucket, uint128(amount));
        require(bucket.spentInPeriod <= bucket.periodLimit, "UnifiedTreasury: bucket limit exceeded");

        if (bucket.asset == address(0)) {
            (bool sent,) = payable(bucket.recipient).call{value: amount}("");
            require(sent, "UnifiedTreasury: native transfer failed");
        } else {
            IERC20(bucket.asset).safeTransfer(bucket.recipient, amount);
        }
        emit AllocationExecuted(bucketId, bucket.asset, bucket.recipient, amount, bucket.spentInPeriod);
    }

    function getBucket(bytes32 bucketId) external view returns (AllocationBucket memory) {
        return _buckets[bucketId];
    }

    function _accrueAllocation(bytes32 bucketId, AllocationBucket storage bucket, uint128 amount) internal {
        require(bucket.periodSeconds > 0, "UnifiedTreasury: zero period");
        require(amount > 0, "UnifiedTreasury: zero allocation");

        uint16 slotCount = _windowSlotCount(bucket.periodSeconds);
        uint64 slotSpan = _windowSlotSpan(bucket.periodSeconds, slotCount);
        require(slotCount > 0 && slotSpan > 0, "UnifiedTreasury: invalid period");

        uint64 nowSlotId = uint64(block.timestamp) / slotSpan;
        uint64 cutoffSlotId = nowSlotId >= uint64(slotCount) ? nowSlotId - uint64(slotCount) : 0;

        for (uint16 i = 0; i < slotCount; i++) {
            AllocationWindowBucket storage windowBucket = _bucketWindowSpending[bucketId][i];
            if (windowBucket.initialized && windowBucket.slotId <= cutoffSlotId) {
                if (bucket.spentInPeriod >= windowBucket.spent) {
                    bucket.spentInPeriod -= windowBucket.spent;
                } else {
                    bucket.spentInPeriod = 0;
                }
                windowBucket.initialized = false;
                windowBucket.slotId = 0;
                windowBucket.spent = 0;
            }
        }

        uint16 idx = uint16(nowSlotId % slotCount);
        AllocationWindowBucket storage active = _bucketWindowSpending[bucketId][idx];
        if (!active.initialized || active.slotId != nowSlotId) {
            if (active.slotId > 0) {
                if (bucket.spentInPeriod >= active.spent) {
                    bucket.spentInPeriod -= active.spent;
                } else {
                    bucket.spentInPeriod = 0;
                }
            }
            active.initialized = true;
            active.slotId = nowSlotId;
            active.spent = 0;
        }
        active.spent += amount;
        bucket.spentInPeriod += amount;
    }

    function _windowSlotCount(uint64 periodSeconds) internal pure returns (uint16) {
        periodSeconds;
        return WINDOW_SLOT_COUNT;
    }

    function _windowSlotSpan(uint64 periodSeconds, uint16 slotCount) internal pure returns (uint64) {
        if (slotCount == 0) return 0;
        uint64 span = periodSeconds / uint64(slotCount);
        if (periodSeconds % uint64(slotCount) == 0) return span;
        return span + 1;
    }
}
