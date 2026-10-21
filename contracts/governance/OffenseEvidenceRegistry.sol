// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IOffenseEvidence.sol";

/**
 * @title OffenseEvidenceRegistry
 * @notice Registry for signed evidence packets that support governance
 *         enforcement actions such as slashing and participation locks.
 * @dev Implements smart-contracts#3.  Evidence packets are stored by their
 *      evidenceHash.  Validation is a two-step process: (1) the admin calls
 *      validateEvidence() to inspect fields, (2) an admin explicitly marks
 *      the packet as validated or rejected via setEvidenceStatus().
 *
 * Status lifecycle: "pending" → "validated" | "rejected"
 *
 * Equal liability: evidence rules apply identically to humans, AI agents,
 * and robots.
 */
contract OffenseEvidenceRegistry is IOffenseEvidence, AccessControl, ReentrancyGuard {
    using ECDSA for bytes32;

    bytes32 public constant EVIDENCE_ADMIN_ROLE = keccak256("EVIDENCE_ADMIN_ROLE");
    uint32 public constant CURRENT_SCHEMA_VERSION = 1;

    // Internal extended record (superset of IOffenseEvidence.EvidencePacket)
    struct EvidenceRecord {
        EvidencePacket packet;
        string status;           // "pending" | "validated" | "rejected"
        uint256 submittedAt;     // block.timestamp at submission
        uint256 statusUpdatedAt; // block.timestamp of last status change
    }

    // Zero-sentinel: submittedAt == 0 means not found
    mapping(bytes32 => EvidenceRecord) private _evidence;
    bytes32[] private _evidenceKeys;

    event EvidenceSubmitted(
        bytes32 indexed evidenceHash,
        string indexed offenseCode,
        address reporter
    );
    event EvidenceValidated(bytes32 indexed evidenceHash, bool valid);
    event EvidenceStatusUpdated(bytes32 indexed evidenceHash, string newStatus);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EVIDENCE_ADMIN_ROLE, msg.sender);
    }

    // ─── IOffenseEvidence ─────────────────────────────────────────────────────

    /**
     * @notice Submit a new evidence packet. Caller must be EVIDENCE_ADMIN_ROLE.
     * @dev The packet's evidenceHash field is the primary key; duplicate hashes
     *      are rejected.  All non-bytes fields must be non-empty/non-zero.
     */
    function submitEvidence(EvidencePacket calldata packet)
        external
        override
        onlyRole(EVIDENCE_ADMIN_ROLE)
        nonReentrant
    {
        (bool valid, string memory reason) = _validatePacket(packet);
        require(valid, reason);
        require(
            _evidence[packet.evidenceHash].submittedAt == 0,
            "OffenseEvidenceRegistry: duplicate evidence"
        );

        EvidenceRecord storage record = _evidence[packet.evidenceHash];
        record.status = "pending";
        record.submittedAt = block.timestamp;
        record.statusUpdatedAt = block.timestamp;

        EvidencePacket storage storedPacket = record.packet;
        storedPacket.evidenceHash = packet.evidenceHash;
        storedPacket.offenseCode = packet.offenseCode;
        storedPacket.evidenceType = packet.evidenceType;
        storedPacket.reporter = packet.reporter;
        storedPacket.payloadHash = packet.payloadHash;
        storedPacket.observedAt = packet.observedAt;
        storedPacket.validAfter = packet.validAfter;
        storedPacket.expiresAt = packet.expiresAt;
        storedPacket.timestamp = block.timestamp;
        storedPacket.reporterSignature = packet.reporterSignature;
        storedPacket.version = packet.version;

        for (uint256 i = 0; i < packet.witnesses.length; i++) {
            storedPacket.witnesses.push(packet.witnesses[i]);
        }

        _evidenceKeys.push(packet.evidenceHash);

        emit EvidenceSubmitted(packet.evidenceHash, packet.offenseCode, packet.reporter);
    }

    /**
     * @notice Retrieve a stored evidence packet by its hash.
     */
    function getEvidence(bytes32 evidenceHash)
        external
        view
        override
        returns (EvidencePacket memory)
    {
        require(
            _evidence[evidenceHash].submittedAt != 0,
            "OffenseEvidenceRegistry: not found"
        );
        return _evidence[evidenceHash].packet;
    }

    /**
     * @notice Validate a stored evidence packet and return an assessment.
     * @dev This is a read-only check; use setEvidenceStatus() to persist the
     *      outcome on-chain.
     */
    function validateEvidence(bytes32 evidenceHash)
        external
        view
        override
        returns (bool valid, string memory reason)
    {
        EvidenceRecord storage record = _evidence[evidenceHash];
        if (record.submittedAt == 0) {
            return (false, "OffenseEvidenceRegistry: not found");
        }
        return _validatePacket(record.packet);
    }

    function computeEvidenceHash(EvidencePacket calldata packet)
        external
        pure
        override
        returns (bytes32 digest)
    {
        return _computeEvidenceHash(packet);
    }

    // ─── Admin status management ──────────────────────────────────────────────

    /**
     * @notice Explicitly mark a packet as validated or rejected.
     * @param evidenceHash Primary key of the packet.
     * @param newStatus    Must be "validated" or "rejected".
     */
    function setEvidenceStatus(
        bytes32 evidenceHash,
        string calldata newStatus
    ) external onlyRole(EVIDENCE_ADMIN_ROLE) nonReentrant {
        EvidenceRecord storage record = _evidence[evidenceHash];
        require(record.submittedAt != 0, "OffenseEvidenceRegistry: not found");

        bytes32 statusHash = keccak256(bytes(newStatus));
        require(
            statusHash == keccak256(bytes("validated")) ||
            statusHash == keccak256(bytes("rejected")),
            "OffenseEvidenceRegistry: invalid status"
        );

        record.status = newStatus;
        record.statusUpdatedAt = block.timestamp;

        bool isValid = statusHash == keccak256(bytes("validated"));
        emit EvidenceValidated(evidenceHash, isValid);
        emit EvidenceStatusUpdated(evidenceHash, newStatus);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /**
     * @notice Return the current lifecycle status of an evidence packet.
     */
    function getEvidenceStatus(bytes32 evidenceHash)
        external
        view
        returns (string memory status, uint256 submittedAt, uint256 statusUpdatedAt)
    {
        EvidenceRecord storage record = _evidence[evidenceHash];
        require(record.submittedAt != 0, "OffenseEvidenceRegistry: not found");
        return (record.status, record.submittedAt, record.statusUpdatedAt);
    }

    /**
     * @notice Total number of evidence packets stored in the registry.
     */
    function getEvidenceCount() external view returns (uint256) {
        return _evidenceKeys.length;
    }

    function _validatePacket(EvidencePacket calldata packet)
        internal
        pure
        returns (bool valid, string memory reason)
    {
        if (packet.evidenceHash == bytes32(0)) {
            return (false, "OffenseEvidenceRegistry: zero evidence hash");
        }
        if (bytes(packet.offenseCode).length == 0) {
            return (false, "OffenseEvidenceRegistry: empty offense code");
        }
        if (packet.evidenceType == EvidenceType.UNSPECIFIED) {
            return (false, "OffenseEvidenceRegistry: unspecified evidence type");
        }
        if (packet.reporter == address(0)) {
            return (false, "OffenseEvidenceRegistry: zero reporter");
        }
        if (packet.payloadHash == bytes32(0)) {
            return (false, "OffenseEvidenceRegistry: zero payload hash");
        }
        if (packet.observedAt == 0) {
            return (false, "OffenseEvidenceRegistry: zero observedAt");
        }
        if (packet.expiresAt <= packet.validAfter) {
            return (false, "OffenseEvidenceRegistry: invalid time bounds");
        }
        if (packet.observedAt < packet.validAfter || packet.observedAt > packet.expiresAt) {
            return (false, "OffenseEvidenceRegistry: observedAt out of bounds");
        }
        if (packet.reporterSignature.length == 0) {
            return (false, "OffenseEvidenceRegistry: empty reporter signature");
        }
        if (packet.witnesses.length == 0) {
            return (false, "OffenseEvidenceRegistry: missing witness attestations");
        }
        if (packet.version != CURRENT_SCHEMA_VERSION) {
            return (false, "OffenseEvidenceRegistry: unsupported schema version");
        }

        bytes32 digest = _computeEvidenceHash(packet);
        if (digest != packet.evidenceHash) {
            return (false, "OffenseEvidenceRegistry: hash mismatch");
        }
        if (!_verifySignature(packet.reporter, digest, packet.reporterSignature)) {
            return (false, "OffenseEvidenceRegistry: invalid reporter signature");
        }

        for (uint256 i = 0; i < packet.witnesses.length; i++) {
            WitnessAttestation calldata witness = packet.witnesses[i];
            if (witness.witness == address(0)) {
                return (false, "OffenseEvidenceRegistry: zero witness");
            }
            if (witness.signature.length == 0) {
                return (false, "OffenseEvidenceRegistry: empty witness signature");
            }
            if (!_verifySignature(witness.witness, digest, witness.signature)) {
                return (false, "OffenseEvidenceRegistry: invalid witness signature");
            }
            for (uint256 j = i + 1; j < packet.witnesses.length; j++) {
                if (packet.witnesses[j].witness == witness.witness) {
                    return (false, "OffenseEvidenceRegistry: duplicate witness");
                }
            }
        }

        return (true, "");
    }

    function _validatePacket(EvidencePacket storage packet)
        internal
        view
        returns (bool valid, string memory reason)
    {
        if (packet.evidenceHash == bytes32(0)) {
            return (false, "OffenseEvidenceRegistry: zero evidence hash");
        }
        if (bytes(packet.offenseCode).length == 0) {
            return (false, "OffenseEvidenceRegistry: empty offense code");
        }
        if (packet.evidenceType == EvidenceType.UNSPECIFIED) {
            return (false, "OffenseEvidenceRegistry: unspecified evidence type");
        }
        if (packet.reporter == address(0)) {
            return (false, "OffenseEvidenceRegistry: zero reporter");
        }
        if (packet.payloadHash == bytes32(0)) {
            return (false, "OffenseEvidenceRegistry: zero payload hash");
        }
        if (packet.observedAt == 0) {
            return (false, "OffenseEvidenceRegistry: zero observedAt");
        }
        if (packet.expiresAt <= packet.validAfter) {
            return (false, "OffenseEvidenceRegistry: invalid time bounds");
        }
        if (packet.observedAt < packet.validAfter || packet.observedAt > packet.expiresAt) {
            return (false, "OffenseEvidenceRegistry: observedAt out of bounds");
        }
        if (packet.reporterSignature.length == 0) {
            return (false, "OffenseEvidenceRegistry: empty reporter signature");
        }
        if (packet.witnesses.length == 0) {
            return (false, "OffenseEvidenceRegistry: missing witness attestations");
        }
        if (packet.version != CURRENT_SCHEMA_VERSION) {
            return (false, "OffenseEvidenceRegistry: unsupported schema version");
        }

        bytes32 digest = _computeEvidenceHash(packet);
        if (digest != packet.evidenceHash) {
            return (false, "OffenseEvidenceRegistry: hash mismatch");
        }
        if (!_verifySignature(packet.reporter, digest, packet.reporterSignature)) {
            return (false, "OffenseEvidenceRegistry: invalid reporter signature");
        }

        for (uint256 i = 0; i < packet.witnesses.length; i++) {
            WitnessAttestation storage witness = packet.witnesses[i];
            if (witness.witness == address(0)) {
                return (false, "OffenseEvidenceRegistry: zero witness");
            }
            if (witness.signature.length == 0) {
                return (false, "OffenseEvidenceRegistry: empty witness signature");
            }
            if (!_verifySignature(witness.witness, digest, witness.signature)) {
                return (false, "OffenseEvidenceRegistry: invalid witness signature");
            }
            for (uint256 j = i + 1; j < packet.witnesses.length; j++) {
                if (packet.witnesses[j].witness == witness.witness) {
                    return (false, "OffenseEvidenceRegistry: duplicate witness");
                }
            }
        }

        return (true, "");
    }

    function _computeEvidenceHash(EvidencePacket calldata packet) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(bytes(packet.offenseCode)),
                packet.evidenceType,
                packet.reporter,
                packet.payloadHash,
                packet.observedAt,
                packet.validAfter,
                packet.expiresAt,
                packet.version
            )
        );
    }

    function _computeEvidenceHash(EvidencePacket storage packet) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(bytes(packet.offenseCode)),
                packet.evidenceType,
                packet.reporter,
                packet.payloadHash,
                packet.observedAt,
                packet.validAfter,
                packet.expiresAt,
                packet.version
            )
        );
    }

    function _verifySignature(
        address expectedSigner,
        bytes32 digest,
        bytes memory signature
    ) internal pure returns (bool) {
        bytes32 ethSignedDigest = MessageHashUtils.toEthSignedMessageHash(digest);
        return ethSignedDigest.recover(signature) == expectedSigner;
    }
}
