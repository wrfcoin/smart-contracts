// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SlashingController
 * @notice On-chain slashing for participant misconduct with reversal support.
 * @dev Implements smart-contracts#1. Slash records are keyed by a composite
 *      hash of (target, offenseCode, slashedAt) to allow multiple distinct
 *      slashes for the same address and offense code at different times.
 *
 * Equal liability: slashing applies identically to humans, AI agents, and robots.
 */
contract SlashingController is AccessControl, ReentrancyGuard {
    bytes32 public constant SLASH_ADMIN_ROLE = keccak256("SLASH_ADMIN_ROLE");

    struct SlashRecord {
        address target;
        string offenseCode;
        uint256 amount;
        uint256 slashedAt;
        uint256 blockNumber;
        bytes32 evidenceHash;
        bool reversed;
        uint256 reversedAt;
    }

    mapping(bytes32 => SlashRecord) private _slashes;
    bytes32[] private _slashKeys;
    mapping(address => uint256) private _totalSlashed;

    event Slashed(
        address indexed target,
        string indexed offenseCode,
        uint256 amount,
        bytes32 evidenceHash,
        bytes32 slashId
    );
    event SlashReversed(
        bytes32 indexed slashId,
        address indexed target,
        uint256 amount
    );
    event SlashAmountUpdated(
        bytes32 indexed slashId,
        uint256 oldAmount,
        uint256 newAmount
    );

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SLASH_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Record a slash against a target address for a specific offense.
     * @param target      Address being slashed.
     * @param offenseCode Canonical offense code (e.g. "CONS-001").
     * @param amount      Token-equivalent magnitude of the slash.
     * @param evidenceHash blake3/keccak hash of the supporting evidence packet.
     */
    function slash(
        address target,
        string calldata offenseCode,
        uint256 amount,
        bytes32 evidenceHash
    ) external onlyRole(SLASH_ADMIN_ROLE) nonReentrant {
        require(target != address(0), "SlashingController: zero address");
        require(bytes(offenseCode).length > 0, "SlashingController: empty offense code");
        require(amount > 0, "SlashingController: zero amount");
        require(evidenceHash != bytes32(0), "SlashingController: zero evidence hash");

        uint256 ts = block.timestamp;
        bytes32 slashId = keccak256(abi.encodePacked(target, offenseCode, ts));
        require(_slashes[slashId].slashedAt == 0, "SlashingController: duplicate slash");

        _slashes[slashId] = SlashRecord({
            target: target,
            offenseCode: offenseCode,
            amount: amount,
            slashedAt: ts,
            blockNumber: block.number,
            evidenceHash: evidenceHash,
            reversed: false,
            reversedAt: 0
        });
        _slashKeys.push(slashId);
        _totalSlashed[target] += amount;

        emit Slashed(target, offenseCode, amount, evidenceHash, slashId);
    }

    /**
     * @notice Reverse a previously recorded slash.
     * @param slashId Composite key returned by the Slashed event or computed
     *                as keccak256(abi.encodePacked(target, offenseCode, slashedAt)).
     */
    function reverseSlash(bytes32 slashId) external onlyRole(SLASH_ADMIN_ROLE) nonReentrant {
        SlashRecord storage record = _slashes[slashId];
        require(record.slashedAt != 0, "SlashingController: slash not found");
        require(!record.reversed, "SlashingController: already reversed");

        record.reversed = true;
        record.reversedAt = block.timestamp;

        // Subtract from cumulative without underflowing
        if (_totalSlashed[record.target] >= record.amount) {
            _totalSlashed[record.target] -= record.amount;
        } else {
            _totalSlashed[record.target] = 0;
        }

        emit SlashReversed(slashId, record.target, record.amount);
    }

    /**
     * @notice Update the amount on an existing, non-reversed slash record.
     * @param slashId   Slash record identifier.
     * @param newAmount Updated token magnitude.
     */
    function updateSlashAmount(
        bytes32 slashId,
        uint256 newAmount
    ) external onlyRole(SLASH_ADMIN_ROLE) nonReentrant {
        SlashRecord storage record = _slashes[slashId];
        require(record.slashedAt != 0, "SlashingController: slash not found");
        require(!record.reversed, "SlashingController: already reversed");
        require(newAmount > 0, "SlashingController: zero amount");

        uint256 oldAmount = record.amount;

        // Adjust cumulative total
        if (newAmount >= oldAmount) {
            _totalSlashed[record.target] += (newAmount - oldAmount);
        } else {
            uint256 diff = oldAmount - newAmount;
            if (_totalSlashed[record.target] >= diff) {
                _totalSlashed[record.target] -= diff;
            } else {
                _totalSlashed[record.target] = 0;
            }
        }

        record.amount = newAmount;
        emit SlashAmountUpdated(slashId, oldAmount, newAmount);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Retrieve a slash record by its composite id.
     */
    function getSlash(bytes32 slashId) external view returns (SlashRecord memory) {
        require(_slashes[slashId].slashedAt != 0, "SlashingController: slash not found");
        return _slashes[slashId];
    }

    /**
     * @notice Cumulative slash amount for an address (reversed slashes deducted).
     */
    function getTotalSlashed(address target) external view returns (uint256) {
        return _totalSlashed[target];
    }

    /**
     * @notice Return total and active (non-reversed) slash counts.
     */
    function getSlashCount() external view returns (uint256 total, uint256 active) {
        total = _slashKeys.length;
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _slashKeys.length; i++) {
            if (!_slashes[_slashKeys[i]].reversed) {
                activeCount++;
            }
        }
        return (total, activeCount);
    }

    /**
     * @notice Returns true if the address has any cumulative slash amount > 0.
     */
    function isSlashed(address target) external view returns (bool) {
        return _totalSlashed[target] > 0;
    }
}
