// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Append-only anchors for externally retained operational audit-trail roots.
/// @dev Stores only a cryptographic root and source-record range; it does not
///      inspect PostgreSQL records or prove that an off-chain root was built
///      from a complete source trail.
contract AuditTrailAnchor is AccessControl {
    bytes32 public constant AUDIT_ANCHOR_ROLE = keccak256("AUDIT_ANCHOR_ROLE");

    struct AuditEpoch {
        bytes32 root;
        uint64 firstRecord;
        uint64 lastRecord;
        uint64 anchoredAt;
    }

    uint64 public minAnchorInterval;
    AuditEpoch[] private _epochs;

    event AuditRootAnchored(
        uint256 indexed epoch,
        bytes32 indexed root,
        uint64 firstRecord,
        uint64 lastRecord,
        uint64 anchoredAt,
        address indexed anchor
    );
    event MinAnchorIntervalUpdated(uint64 previousInterval, uint64 newInterval);

    constructor(uint64 initialMinAnchorInterval) {
        require(initialMinAnchorInterval > 0, "AuditTrailAnchor: zero interval");
        minAnchorInterval = initialMinAnchorInterval;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDIT_ANCHOR_ROLE, msg.sender);
    }

    function setMinAnchorInterval(uint64 newInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newInterval > 0, "AuditTrailAnchor: zero interval");
        uint64 previous = minAnchorInterval;
        minAnchorInterval = newInterval;
        emit MinAnchorIntervalUpdated(previous, newInterval);
    }

    function anchorAuditRoot(bytes32 root, uint64 firstRecord, uint64 lastRecord)
        external
        onlyRole(AUDIT_ANCHOR_ROLE)
    {
        require(root != bytes32(0), "AuditTrailAnchor: zero root");
        require(firstRecord <= lastRecord, "AuditTrailAnchor: invalid record range");

        if (_epochs.length > 0) {
            AuditEpoch memory previous = _epochs[_epochs.length - 1];
            require(
                block.timestamp >= uint256(previous.anchoredAt) + minAnchorInterval,
                "AuditTrailAnchor: cadence not reached"
            );
            require(firstRecord > previous.lastRecord, "AuditTrailAnchor: non-monotonic record range");
        }

        uint64 anchoredAt = uint64(block.timestamp);
        _epochs.push(AuditEpoch({
            root: root,
            firstRecord: firstRecord,
            lastRecord: lastRecord,
            anchoredAt: anchoredAt
        }));

        emit AuditRootAnchored(_epochs.length - 1, root, firstRecord, lastRecord, anchoredAt, msg.sender);
    }

    function getAuditEpoch(uint256 epoch) external view returns (AuditEpoch memory) {
        require(epoch < _epochs.length, "AuditTrailAnchor: epoch not found");
        return _epochs[epoch];
    }

    function auditEpochCount() external view returns (uint256) {
        return _epochs.length;
    }

    function verifyAuditRoot(uint256 epoch, bytes32 root) external view returns (bool) {
        return epoch < _epochs.length && _epochs[epoch].root == root;
    }
}
