// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OffenseRegistry
 * @notice On-chain offense code registry with human-readable semantics.
 * @dev Implements smart-contracts#6. Offense codes match the canonical
 *      offense-taxonomy.toml spec in core4/docs/governance/.
 *
 * Equal liability: offense codes and sanctions apply identically to
 * humans, AI agents, and robots.
 */
contract OffenseRegistry is AccessControl, ReentrancyGuard {
    bytes32 public constant OFFENSE_ADMIN_ROLE = keccak256("OFFENSE_ADMIN_ROLE");
    uint16 public constant MAX_BPS = 10_000;

    struct PenaltyRange {
        uint16 minSlashBps;
        uint16 maxSlashBps;
        uint32 minLockDuration;
        uint32 maxLockDuration;
    }

    struct OffenseRecord {
        string code;           // e.g. "DATA-001"
        uint8 severity;        // 0=Minor, 1=Moderate, 2=Major, 3=Critical
        string description;    // Plain-language description
        PenaltyRange penalties;// Sanction bounds for equal-liability policy tooling
        uint32 version;        // Monotonic version counter
        bool deprecated;       // Soft-delete flag
        uint256 registeredAt;  // Block timestamp
        uint256 updatedAt;     // Block timestamp of last update
    }

    mapping(bytes32 => OffenseRecord) private _offenses;
    bytes32[] private _offenseKeys;
    uint256 private _activeCount;

    event OffenseRegistered(
        string indexed code,
        uint8 severity,
        uint16 minSlashBps,
        uint16 maxSlashBps,
        uint32 version
    );
    event OffenseUpdated(
        string indexed code,
        uint8 newSeverity,
        uint16 minSlashBps,
        uint16 maxSlashBps,
        uint32 version
    );
    event OffenseDeprecated(string indexed code, uint32 version);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFENSE_ADMIN_ROLE, msg.sender);
    }

    function registerOffense(
        string calldata code,
        uint8 severity,
        string calldata description
    ) external onlyRole(OFFENSE_ADMIN_ROLE) nonReentrant {
        PenaltyRange memory defaults = _defaultPenaltyRange(severity);
        _registerOffense(code, severity, description, defaults);
    }

    function registerOffense(
        string calldata code,
        uint8 severity,
        string calldata description,
        uint16 minSlashBps,
        uint16 maxSlashBps,
        uint32 minLockDuration,
        uint32 maxLockDuration
    ) external onlyRole(OFFENSE_ADMIN_ROLE) nonReentrant {
        _registerOffense(
            code,
            severity,
            description,
            PenaltyRange({
                minSlashBps: minSlashBps,
                maxSlashBps: maxSlashBps,
                minLockDuration: minLockDuration,
                maxLockDuration: maxLockDuration
            })
        );
    }

    function updateOffense(
        string calldata code,
        uint8 newSeverity,
        string calldata newDescription
    ) external onlyRole(OFFENSE_ADMIN_ROLE) nonReentrant {
        PenaltyRange memory defaults = _defaultPenaltyRange(newSeverity);
        _updateOffense(code, newSeverity, newDescription, defaults);
    }

    function updateOffense(
        string calldata code,
        uint8 newSeverity,
        string calldata newDescription,
        uint16 minSlashBps,
        uint16 maxSlashBps,
        uint32 minLockDuration,
        uint32 maxLockDuration
    ) external onlyRole(OFFENSE_ADMIN_ROLE) nonReentrant {
        _updateOffense(
            code,
            newSeverity,
            newDescription,
            PenaltyRange({
                minSlashBps: minSlashBps,
                maxSlashBps: maxSlashBps,
                minLockDuration: minLockDuration,
                maxLockDuration: maxLockDuration
            })
        );
    }

    function deprecateOffense(string calldata code) external onlyRole(OFFENSE_ADMIN_ROLE) nonReentrant {
        bytes32 key = keccak256(bytes(code));
        OffenseRecord storage record = _offenses[key];
        require(record.registeredAt != 0, "OffenseRegistry: not found");
        require(!record.deprecated, "OffenseRegistry: already deprecated");

        record.deprecated = true;
        record.version++;
        record.updatedAt = block.timestamp;
        _activeCount--;

        emit OffenseDeprecated(code, record.version);
    }

    function getOffense(string calldata code) external view returns (OffenseRecord memory) {
        bytes32 key = keccak256(bytes(code));
        require(_offenses[key].registeredAt != 0, "OffenseRegistry: not found");
        return _offenses[key];
    }

    function getPenaltyRange(string calldata code) external view returns (PenaltyRange memory) {
        bytes32 key = keccak256(bytes(code));
        require(_offenses[key].registeredAt != 0, "OffenseRegistry: not found");
        return _offenses[key].penalties;
    }

    function getOffenseCount() external view returns (uint256 total, uint256 active) {
        return (_offenseKeys.length, _activeCount);
    }

    function isDeprecated(string calldata code) external view returns (bool) {
        bytes32 key = keccak256(bytes(code));
        require(_offenses[key].registeredAt != 0, "OffenseRegistry: not found");
        return _offenses[key].deprecated;
    }

    function getAllActiveOffenses() external view returns (OffenseRecord[] memory) {
        OffenseRecord[] memory result = new OffenseRecord[](_activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < _offenseKeys.length; i++) {
            OffenseRecord storage record = _offenses[_offenseKeys[i]];
            if (!record.deprecated) {
                result[idx++] = record;
            }
        }
        return result;
    }

    function _registerOffense(
        string calldata code,
        uint8 severity,
        string calldata description,
        PenaltyRange memory penalties
    ) internal {
        require(bytes(code).length > 0, "OffenseRegistry: empty code");
        require(bytes(description).length > 0, "OffenseRegistry: empty description");
        require(severity <= 3, "OffenseRegistry: invalid severity");
        _validatePenaltyRange(penalties);
        bytes32 key = keccak256(bytes(code));
        require(_offenses[key].registeredAt == 0, "OffenseRegistry: duplicate code");

        _offenses[key] = OffenseRecord({
            code: code,
            severity: severity,
            description: description,
            penalties: penalties,
            version: 1,
            deprecated: false,
            registeredAt: block.timestamp,
            updatedAt: block.timestamp
        });
        _offenseKeys.push(key);
        _activeCount++;

        emit OffenseRegistered(
            code,
            severity,
            penalties.minSlashBps,
            penalties.maxSlashBps,
            1
        );
    }

    function _updateOffense(
        string calldata code,
        uint8 newSeverity,
        string calldata newDescription,
        PenaltyRange memory penalties
    ) internal {
        bytes32 key = keccak256(bytes(code));
        OffenseRecord storage record = _offenses[key];
        require(record.registeredAt != 0, "OffenseRegistry: not found");
        require(!record.deprecated, "OffenseRegistry: deprecated");
        require(bytes(newDescription).length > 0, "OffenseRegistry: empty description");
        require(newSeverity <= 3, "OffenseRegistry: invalid severity");
        _validatePenaltyRange(penalties);

        record.severity = newSeverity;
        record.description = newDescription;
        record.penalties = penalties;
        record.version++;
        record.updatedAt = block.timestamp;

        emit OffenseUpdated(
            code,
            newSeverity,
            penalties.minSlashBps,
            penalties.maxSlashBps,
            record.version
        );
    }

    function _validatePenaltyRange(PenaltyRange memory penalties) internal pure {
        require(penalties.minSlashBps <= penalties.maxSlashBps, "OffenseRegistry: invalid slash range");
        require(penalties.maxSlashBps <= MAX_BPS, "OffenseRegistry: slash range too high");
        require(
            penalties.minLockDuration <= penalties.maxLockDuration,
            "OffenseRegistry: invalid lock range"
        );
    }

    function _defaultPenaltyRange(uint8 severity) internal pure returns (PenaltyRange memory) {
        if (severity == 0) {
            return PenaltyRange({ minSlashBps: 0, maxSlashBps: 500, minLockDuration: 0, maxLockDuration: 1 days });
        }
        if (severity == 1) {
            return PenaltyRange({ minSlashBps: 500, maxSlashBps: 1_500, minLockDuration: 1 days, maxLockDuration: 3 days });
        }
        if (severity == 2) {
            return PenaltyRange({ minSlashBps: 1_500, maxSlashBps: 3_500, minLockDuration: 3 days, maxLockDuration: 7 days });
        }
        return PenaltyRange({ minSlashBps: 3_500, maxSlashBps: MAX_BPS, minLockDuration: 7 days, maxLockDuration: 30 days });
    }
}
