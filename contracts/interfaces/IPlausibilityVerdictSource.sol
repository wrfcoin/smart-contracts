// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPlausibilityVerdictSource
 * @notice The #160 seam: an independent plausibility verdict for a canonical
 *         observation digest (ADR-159 §6).
 * @dev Expected to be satisfied by the PlausibilityAttestationRegistry quorum
 *      (#219, in flight). The gate fails closed: an unset source or an
 *      unavailable verdict quarantines the frame — it never mints.
 */
interface IPlausibilityVerdictSource {
    /**
     * @param canonicalDigest the gate's domain-separated frame digest
     * @return available whether an independent verdict exists for this digest
     * @return passed    the verdict, meaningful only when `available` is true
     */
    function verdictFor(bytes32 canonicalDigest) external view returns (bool available, bool passed);
}
