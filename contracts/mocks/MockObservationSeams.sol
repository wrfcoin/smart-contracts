// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/INodeKeyRegistry.sol";
import "../interfaces/IPlausibilityVerdictSource.sol";
import "../interfaces/IGeoCellRegistry.sol";

/// @dev Test double for the #158 seam. Not deployable policy.
contract MockNodeKeyRegistry is INodeKeyRegistry {
    mapping(bytes32 => bool) public registered;
    mapping(bytes32 => mapping(uint32 => bool)) public activeKey;

    function setRegistered(bytes32 nodeId, bool ok) external {
        registered[nodeId] = ok;
    }

    function setActiveKey(bytes32 nodeId, uint32 keyVersion, bool ok) external {
        activeKey[nodeId][keyVersion] = ok;
    }

    function isRegisteredNode(bytes32 nodeId) external view returns (bool) {
        return registered[nodeId];
    }

    function isActiveKey(bytes32 nodeId, uint32 keyVersion) external view returns (bool) {
        return activeKey[nodeId][keyVersion];
    }
}

/// @dev Test double for the #161 seam. Not deployable policy.
contract MockGeoCellRegistry is IGeoCellRegistry {
    mapping(bytes32 => bytes32) public cells;

    function setCell(bytes32 nodeId, bytes32 cell) external {
        cells[nodeId] = cell;
    }

    function registeredCell(bytes32 nodeId) external view returns (bytes32) {
        return cells[nodeId];
    }
}

/// @dev Test double for the #160/#219 seam. Not deployable policy.
contract MockPlausibilityVerdictSource is IPlausibilityVerdictSource {
    struct Verdict {
        bool available;
        bool passed;
    }

    mapping(bytes32 => Verdict) public verdicts;
    Verdict public defaultVerdict;

    function setDefault(bool available, bool passed) external {
        defaultVerdict = Verdict(available, passed);
    }

    function setVerdict(bytes32 digest, bool available, bool passed) external {
        verdicts[digest] = Verdict(available, passed);
    }

    function verdictFor(bytes32 digest) external view returns (bool, bool) {
        Verdict memory v = verdicts[digest];
        if (!v.available && !v.passed) v = defaultVerdict;
        return (v.available, v.passed);
    }
}
