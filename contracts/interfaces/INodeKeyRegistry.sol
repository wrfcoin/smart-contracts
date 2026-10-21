// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title INodeKeyRegistry
 * @notice The #158 seam: hardware-root node identity and key lifecycle.
 * @dev #158 is closed-blocked — no implementation exists in this repository yet.
 *      ProofOfObservationMintGate treats an unset or false-answering registry as
 *      a hard failure (ADR-159 §2: an arbitrary Ethereum key is not a
 *      hardware-root substitute). This interface asserts key REGISTRY STATE
 *      only; it does not verify P-256 signatures. Signature verification is a
 *      separate unresolved decision (see epic #157 discussion).
 */
interface INodeKeyRegistry {
    /// @return true iff `nodeId` is a registered, non-revoked hardware root.
    function isRegisteredNode(bytes32 nodeId) external view returns (bool);

    /// @return true iff `keyVersion` is the active (non-rotated, non-revoked)
    ///         key version for `nodeId`.
    function isActiveKey(bytes32 nodeId, uint32 keyVersion) external view returns (bool);
}
