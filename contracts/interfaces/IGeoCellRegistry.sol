// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IGeoCellRegistry
 * @notice The #161 seam: the geo-cell a registered station claimed at
 *         registration time.
 * @dev The cell is REGISTRY state, written when the station registers
 *      (infra#589 surface -> registrar), never taken from the submitted frame —
 *      a frame cannot claim an arbitrary cell. Cell ids are derived off-chain
 *      from lat/lon at the resolution named in the gate's policy
 *      (`geoCellResolution`); the chain binds the claim, it does not re-derive
 *      it. Moving cells is an explicit re-registration, not silent drift.
 *      Returns bytes32(0) for a node with no registered cell — the gate fails
 *      closed on that.
 */
interface IGeoCellRegistry {
    function registeredCell(bytes32 nodeId) external view returns (bytes32);
}
