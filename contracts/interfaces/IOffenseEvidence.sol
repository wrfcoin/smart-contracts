// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IOffenseEvidence
 * @notice Interface for submitting and querying signed evidence packets that
 *         back on-chain governance enforcement actions.
 * @dev Implements part of smart-contracts#3. Evidence packets are identified
 *      by their evidenceHash field; callers must ensure uniqueness.
 */
interface IOffenseEvidence {
    enum EvidenceType {
        UNSPECIFIED,
        CONSENSUS_PROOF,
        ORACLE_ATTESTATION,
        GOVERNANCE_ACTION,
        ECONOMIC_ABUSE,
        OPERATIONAL_MISCONDUCT
    }

    struct WitnessAttestation {
        address witness;
        bytes signature;
    }

    struct EvidencePacket {
        bytes32 evidenceHash;            // Deterministic digest over the packet contents
        string offenseCode;              // Canonical offense code (e.g. "CONS-001")
        EvidenceType evidenceType;       // Canonical evidence family used for downstream review
        address reporter;                // Address that submitted the evidence
        bytes32 payloadHash;             // Digest of the underlying evidence payload/document
        uint64 observedAt;               // When the misconduct was observed off-chain
        uint64 validAfter;               // Earliest accepted observation timestamp
        uint64 expiresAt;                // Latest accepted observation timestamp
        uint256 timestamp;               // Submission timestamp (block.timestamp at receipt)
        bytes reporterSignature;         // Reporter signature over the canonical packet digest
        WitnessAttestation[] witnesses;  // Independent witness attestations over the same digest
        uint32 version;                  // Schema version of the evidence packet
    }

    /**
     * @notice Submit a new evidence packet.
     * @param packet Fully populated EvidencePacket struct.
     */
    function submitEvidence(EvidencePacket calldata packet) external;

    /**
     * @notice Retrieve a stored evidence packet by its hash.
     * @param evidenceHash Primary key of the desired packet.
     * @return packet The stored EvidencePacket.
     */
    function getEvidence(bytes32 evidenceHash) external view returns (EvidencePacket memory packet);

    /**
     * @notice Validate an evidence packet and return a human-readable reason
     *         when invalid.
     * @param evidenceHash Primary key of the packet to validate.
     * @return valid  True when the packet passes all integrity checks.
     * @return reason Empty string when valid; descriptive phrase when invalid.
     */
    function validateEvidence(bytes32 evidenceHash)
        external
        view
        returns (bool valid, string memory reason);

    /**
     * @notice Compute the canonical digest for an evidence packet.
     * @param packet Packet to hash.
     * @return digest Deterministic keccak256 hash over the packet contents.
     */
    function computeEvidenceHash(EvidencePacket calldata packet) external pure returns (bytes32 digest);
}
