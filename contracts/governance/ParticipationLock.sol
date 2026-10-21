// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ParticipationLock
 * @notice Temporary lockout mechanism that prevents a participant from taking
 *         part in network activities for a configurable duration.
 * @dev Implements smart-contracts#2. One active lock per address at a time;
 *      a new lock can only be created after the previous one has expired or
 *      been released early.
 *
 * Equal liability: locks apply identically to humans, AI agents, and robots.
 */
contract ParticipationLock is AccessControl, ReentrancyGuard {
    bytes32 public constant LOCK_ADMIN_ROLE = keccak256("LOCK_ADMIN_ROLE");

    struct LockRecord {
        address target;
        string reason;
        uint256 lockedAt;
        uint256 expiresAt;
        uint256 blockNumber;
        bool releasedEarly;
        uint256 releasedAt;
    }

    // One active lock record per address (zero-sentinel: lockedAt == 0 means never locked)
    mapping(address => LockRecord) private _locks;
    // Total locks ever applied to an address (incremented on each lock, never decremented)
    mapping(address => uint256) private _lockCount;

    event ParticipantLocked(address indexed target, string reason, uint256 expiresAt);
    event ParticipantUnlocked(address indexed target, bool early);
    event LockExtended(address indexed target, uint256 newExpiresAt);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LOCK_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Lock a participant for a given duration (in seconds).
     * @param target   Address to lock.
     * @param reason   Human-readable reason string.
     * @param duration Lock duration in seconds; added to block.timestamp.
     */
    function lock(
        address target,
        string calldata reason,
        uint256 duration
    ) external onlyRole(LOCK_ADMIN_ROLE) nonReentrant {
        require(target != address(0), "ParticipationLock: zero address");
        require(bytes(reason).length > 0, "ParticipationLock: empty reason");
        require(duration > 0, "ParticipationLock: zero duration");

        // Reject if the target is already actively locked
        LockRecord storage existing = _locks[target];
        bool activeNow = existing.lockedAt != 0
            && !existing.releasedEarly
            && existing.expiresAt > block.timestamp;
        require(!activeNow, "ParticipationLock: already locked");

        uint256 expiresAt = block.timestamp + duration;

        _locks[target] = LockRecord({
            target: target,
            reason: reason,
            lockedAt: block.timestamp,
            expiresAt: expiresAt,
            blockNumber: block.number,
            releasedEarly: false,
            releasedAt: 0
        });
        _lockCount[target]++;

        emit ParticipantLocked(target, reason, expiresAt);
    }

    /**
     * @notice Release a participant before the lock naturally expires.
     * @param target Address to unlock.
     */
    function unlock(address target) external onlyRole(LOCK_ADMIN_ROLE) nonReentrant {
        LockRecord storage record = _locks[target];
        require(record.lockedAt != 0, "ParticipationLock: no lock found");
        require(!record.releasedEarly, "ParticipationLock: already released");
        require(record.expiresAt > block.timestamp, "ParticipationLock: already expired");

        record.releasedEarly = true;
        record.releasedAt = block.timestamp;

        emit ParticipantUnlocked(target, true);
    }

    /**
     * @notice Finalize a naturally expired lock and emit an audit event.
     * @dev Allows downstream governance systems to observe timed release on
     *      chain instead of inferring it solely from timestamps.
     * @param target Address whose expired lock should be released.
     */
    function releaseExpiredLock(address target) external nonReentrant {
        LockRecord storage record = _locks[target];
        require(record.lockedAt != 0, "ParticipationLock: no lock found");
        require(!record.releasedEarly, "ParticipationLock: already released");
        require(record.expiresAt <= block.timestamp, "ParticipationLock: not expired");

        record.releasedEarly = true;
        record.releasedAt = block.timestamp;

        emit ParticipantUnlocked(target, false);
    }

    /**
     * @notice Extend the expiry of an active lock.
     * @param target             Address whose lock is being extended.
     * @param additionalDuration Seconds to add to the current expiresAt.
     */
    function extendLock(
        address target,
        uint256 additionalDuration
    ) external onlyRole(LOCK_ADMIN_ROLE) nonReentrant {
        require(additionalDuration > 0, "ParticipationLock: zero duration");
        LockRecord storage record = _locks[target];
        require(record.lockedAt != 0, "ParticipationLock: no lock found");
        require(!record.releasedEarly, "ParticipationLock: already released");
        require(record.expiresAt > block.timestamp, "ParticipationLock: already expired");

        record.expiresAt += additionalDuration;

        emit LockExtended(target, record.expiresAt);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Returns true when the target is currently locked and not released.
     */
    function isLocked(address target) external view returns (bool) {
        LockRecord storage record = _locks[target];
        if (record.lockedAt == 0) return false;
        if (record.releasedEarly) return false;
        return record.expiresAt > block.timestamp;
    }

    /**
     * @notice Returns true when an expired lock is awaiting finalization.
     */
    function canReleaseExpiredLock(address target) external view returns (bool) {
        LockRecord storage record = _locks[target];
        if (record.lockedAt == 0) return false;
        if (record.releasedEarly) return false;
        return record.expiresAt <= block.timestamp;
    }

    /**
     * @notice Return the most recent lock record for an address.
     *         Reverts if the address has never been locked.
     */
    function getLock(address target) external view returns (LockRecord memory) {
        require(_locks[target].lockedAt != 0, "ParticipationLock: no lock found");
        return _locks[target];
    }

    /**
     * @notice Total number of lock events ever applied to an address.
     */
    function getLockCount(address target) external view returns (uint256) {
        return _lockCount[target];
    }
}
