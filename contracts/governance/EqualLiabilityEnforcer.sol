// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EqualLiabilityEnforcer
 * @notice Enforces actor-type-neutral sanction outcomes: equivalent offenses
 *         map to equivalent sanctions regardless of whether the actor is
 *         Human, AI, or Robot.
 * @dev Implements smart-contracts#4. Sanction schedules are keyed by
 *      keccak256(bytes(offenseCode)) and contain no per-actor-class branching.
 *      The _overridesByActorClass mapping exists solely to prove — via
 *      hasActorClassOverride() always returning false — that no actor-class
 *      overrides exist anywhere in the system.
 */
contract EqualLiabilityEnforcer is AccessControl, ReentrancyGuard {
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");
    bytes32 public constant GOVERNANCE_OVERRIDE_ROLE = keccak256("GOVERNANCE_OVERRIDE_ROLE");

    /// @notice Actor classification. Has NO effect on sanction outcomes.
    enum ActorClass { Human, AI, Robot }

    struct SanctionSchedule {
        string offenseCode;
        uint8 severity;
        uint256 slashAmount;
        uint256 lockDuration;
        bool active;
        uint256 registeredAt;
        uint256 updatedAt;
    }

    mapping(bytes32 => SanctionSchedule) private _schedules;
    bytes32[] private _scheduleKeys;

    /**
     * @dev This mapping is intentionally never written to. Its existence
     *      documents — and its permanent emptiness proves — that the contract
     *      contains zero actor-class-specific overrides.
     *      Key: keccak256(bytes(offenseCode)) => ActorClass (as uint8) => bool
     */
    mapping(bytes32 => mapping(uint8 => bool)) private _overridesByActorClass;

    event ScheduleRegistered(
        string indexed offenseCode,
        uint8 severity,
        uint256 slashAmount,
        uint256 lockDuration
    );
    event ScheduleUpdated(
        string indexed offenseCode,
        uint8 newSeverity,
        uint256 newSlashAmount,
        uint256 newLockDuration
    );
    event GovernanceOverrideApplied(
        string indexed offenseCode,
        uint8 newSeverity,
        uint256 newSlashAmount,
        uint256 newLockDuration,
        string rationale
    );
    /// @notice Emitted when a caller verifies parity for a given offense and actor class.
    event LiabilityVerified(
        string indexed offenseCode,
        uint8 actorClass,
        bool parity
    );

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
        _grantRole(GOVERNANCE_OVERRIDE_ROLE, msg.sender);
    }

    // ─── Mutating functions ───────────────────────────────────────────────────

    /**
     * @notice Register a new sanction schedule for an offense code.
     * @param offenseCode  Canonical offense code (e.g. "CONS-001").
     * @param severity     0=Minor, 1=Moderate, 2=Major, 3=Critical.
     * @param slashAmount  Token-equivalent magnitude of the slash.
     * @param lockDuration Seconds the actor's stake is locked.
     */
    function registerSchedule(
        string calldata offenseCode,
        uint8 severity,
        uint256 slashAmount,
        uint256 lockDuration
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        require(bytes(offenseCode).length > 0, "EqualLiabilityEnforcer: empty offense code");
        require(severity <= 3, "EqualLiabilityEnforcer: invalid severity");
        require(slashAmount > 0, "EqualLiabilityEnforcer: zero slash amount");

        bytes32 key = keccak256(bytes(offenseCode));
        require(_schedules[key].registeredAt == 0, "EqualLiabilityEnforcer: duplicate offense code");

        _schedules[key] = SanctionSchedule({
            offenseCode: offenseCode,
            severity: severity,
            slashAmount: slashAmount,
            lockDuration: lockDuration,
            active: true,
            registeredAt: block.timestamp,
            updatedAt: block.timestamp
        });
        _scheduleKeys.push(key);

        emit ScheduleRegistered(offenseCode, severity, slashAmount, lockDuration);
    }

    /**
     * @notice Update an existing, active sanction schedule.
     * @param offenseCode     Canonical offense code of the schedule to update.
     * @param severity        New severity (0–3).
     * @param slashAmount     New slash magnitude (must be > 0).
     * @param lockDuration    New lock duration in seconds.
     */
    function updateSchedule(
        string calldata offenseCode,
        uint8 severity,
        uint256 slashAmount,
        uint256 lockDuration
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        bytes32 key = keccak256(bytes(offenseCode));
        SanctionSchedule storage schedule = _schedules[key];
        require(schedule.registeredAt != 0, "EqualLiabilityEnforcer: schedule not found");
        require(schedule.active, "EqualLiabilityEnforcer: schedule inactive");
        require(severity <= 3, "EqualLiabilityEnforcer: invalid severity");
        require(slashAmount > 0, "EqualLiabilityEnforcer: zero slash amount");

        schedule.severity = severity;
        schedule.slashAmount = slashAmount;
        schedule.lockDuration = lockDuration;
        schedule.updatedAt = block.timestamp;

        emit ScheduleUpdated(offenseCode, severity, slashAmount, lockDuration);
    }

    /**
     * @notice Apply an explicitly governed override to an offense schedule.
     * @dev The override updates the single global schedule for an offense and
     *      therefore preserves actor-class neutrality.
     * @param offenseCode Canonical offense code of the schedule to override.
     * @param severity New severity (0-3).
     * @param slashAmount New slash amount (must be > 0).
     * @param lockDuration New lock duration in seconds.
     * @param rationale Human-readable reason for the override.
     */
    function applyGovernanceOverride(
        string calldata offenseCode,
        uint8 severity,
        uint256 slashAmount,
        uint256 lockDuration,
        string calldata rationale
    ) external onlyRole(GOVERNANCE_OVERRIDE_ROLE) nonReentrant {
        bytes32 key = keccak256(bytes(offenseCode));
        SanctionSchedule storage schedule = _schedules[key];
        require(schedule.registeredAt != 0, "EqualLiabilityEnforcer: schedule not found");
        require(schedule.active, "EqualLiabilityEnforcer: schedule inactive");
        require(severity <= 3, "EqualLiabilityEnforcer: invalid severity");
        require(slashAmount > 0, "EqualLiabilityEnforcer: zero slash amount");
        require(bytes(rationale).length > 0, "EqualLiabilityEnforcer: empty rationale");

        schedule.severity = severity;
        schedule.slashAmount = slashAmount;
        schedule.lockDuration = lockDuration;
        schedule.updatedAt = block.timestamp;

        emit GovernanceOverrideApplied(
            offenseCode,
            severity,
            slashAmount,
            lockDuration,
            rationale
        );
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Retrieve the sanction schedule for an offense code.
     *         Returns the same schedule regardless of caller — actor class
     *         has no influence on the stored data.
     * @param offenseCode Canonical offense code.
     * @return schedule The SanctionSchedule struct for that offense.
     */
    function getSchedule(
        string calldata offenseCode
    ) external view returns (SanctionSchedule memory) {
        bytes32 key = keccak256(bytes(offenseCode));
        require(_schedules[key].registeredAt != 0, "EqualLiabilityEnforcer: schedule not found");
        return _schedules[key];
    }

    /**
     * @notice Verify equal-liability parity for a given offense and actor class.
     * @dev    ALWAYS returns the same slashAmount and lockDuration regardless of
     *         actorClass. parity is always true for any registered active schedule.
     *         Emits LiabilityVerified so that parity checks are auditable on-chain.
     * @param offenseCode Canonical offense code.
     * @param actorClass  Actor classification (Human=0, AI=1, Robot=2). Ignored
     *                    for sanction lookup — present only to make the equal-
     *                    liability guarantee explicit and auditable.
     * @return parity      Always true: sanctions are actor-type neutral.
     * @return slashAmount The universal slash amount for this offense.
     * @return lockDuration The universal lock duration for this offense.
     */
    function verifyParity(
        string calldata offenseCode,
        ActorClass actorClass
    ) external returns (bool parity, uint256 slashAmount, uint256 lockDuration) {
        bytes32 key = keccak256(bytes(offenseCode));
        SanctionSchedule storage schedule = _schedules[key];
        require(schedule.registeredAt != 0, "EqualLiabilityEnforcer: schedule not found");
        require(schedule.active, "EqualLiabilityEnforcer: schedule inactive");

        // Sanctions are identical for every actor class — no branching on actorClass.
        parity = true;
        slashAmount = schedule.slashAmount;
        lockDuration = schedule.lockDuration;

        emit LiabilityVerified(offenseCode, uint8(actorClass), parity);
    }

    /**
     * @notice Check whether any actor-class-specific override exists for an offense.
     * @dev    Always returns false. _overridesByActorClass is never written to,
     *         which is the on-chain proof that no overrides exist.
     * @param offenseCode Canonical offense code.
     * @param actorClass  Actor class to check.
     * @return Always false.
     */
    function hasActorClassOverride(
        string calldata offenseCode,
        ActorClass actorClass
    ) external view returns (bool) {
        bytes32 key = keccak256(bytes(offenseCode));
        return _overridesByActorClass[key][uint8(actorClass)];
    }

    /**
     * @notice Return total schedule count and count of active schedules.
     * @return total  Number of schedules ever registered.
     * @return active Number of currently active schedules.
     */
    function getScheduleCount() external view returns (uint256 total, uint256 active) {
        total = _scheduleKeys.length;
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _scheduleKeys.length; i++) {
            if (_schedules[_scheduleKeys[i]].active) {
                activeCount++;
            }
        }
        return (total, activeCount);
    }

    /**
     * @notice Return all active sanction schedules.
     * @return Array of SanctionSchedule structs where active == true.
     */
    function getAllActiveSchedules() external view returns (SanctionSchedule[] memory) {
        // First pass: count active schedules.
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _scheduleKeys.length; i++) {
            if (_schedules[_scheduleKeys[i]].active) {
                activeCount++;
            }
        }

        SanctionSchedule[] memory result = new SanctionSchedule[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < _scheduleKeys.length; i++) {
            SanctionSchedule storage s = _schedules[_scheduleKeys[i]];
            if (s.active) {
                result[idx++] = s;
            }
        }
        return result;
    }
}
