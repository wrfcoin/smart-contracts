// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPlausibilityVerdictSource.sol";

/// @notice Records distinct attester judgments over a canonical observation hash.
/// @dev This is a hook for a future PoO mint consumer. It deliberately does not
///      accept a claimant-provided score/work factor as evidence of a quorum.
contract PlausibilityAttestationRegistry is Ownable, IPlausibilityVerdictSource {
    struct Attestation {
        uint64 revision;
        uint64 attesterRevision;
        bool plausible;
    }

    struct FrameTally {
        bytes32 policyHash;
        uint64 validUntil;
        uint32 plausibleCount;
        uint32 implausibleCount;
        uint32 minimumAttestationsAtTally;
        uint64 revision;
    }

    mapping(address => bool) public attesters;
    mapping(bytes32 => mapping(address => Attestation)) public hasAttested;
    mapping(bytes32 => FrameTally) private _tallies;
    mapping(bytes32 => address[]) private _frameAttesters;
    mapping(bytes32 => mapping(address => bool)) private _frameAttesterSeen;

    uint32 public attesterCount;
    uint32 public minimumAttestations;
    mapping(bytes32 => uint64) private _frameRevisions;
    mapping(address => uint64) private _attesterRevisions;

    event AttesterAdded(address indexed attester);
    event AttesterRemoved(address indexed attester);
    event MinimumAttestationsUpdated(uint32 previousMinimum, uint32 newMinimum);
    event FrameTallyReset(bytes32 indexed frameHash, uint64 revision);
    event PlausibilityAttested(
        bytes32 indexed frameHash,
        bytes32 indexed policyHash,
        address indexed attester,
        bool plausible,
        uint64 validUntil
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyAttester() {
        require(attesters[msg.sender], "PlausibilityRegistry: not attester");
        _;
    }

    function addAttester(address attester) external onlyOwner {
        require(attester != address(0), "PlausibilityRegistry: zero attester");
        require(!attesters[attester], "PlausibilityRegistry: already attester");
        attesters[attester] = true;
        attesterCount++;
        emit AttesterAdded(attester);
    }

    function removeAttester(address attester) external onlyOwner {
        require(attesters[attester], "PlausibilityRegistry: not attester");
        require(attesterCount - 1 >= minimumAttestations, "PlausibilityRegistry: below quorum");

        _attesterRevisions[attester]++;

        attesters[attester] = false;
        attesterCount--;
        emit AttesterRemoved(attester);
    }

    function setMinimumAttestations(uint32 newMinimum) external onlyOwner {
        require(newMinimum > 0, "PlausibilityRegistry: zero quorum");
        require(newMinimum <= attesterCount, "PlausibilityRegistry: quorum exceeds attesters");
        uint32 previous = minimumAttestations;
        minimumAttestations = newMinimum;
        emit MinimumAttestationsUpdated(previous, newMinimum);
    }

    function attest(
        bytes32 frameHash,
        bytes32 policyHash,
        uint64 validUntil,
        bool plausible
    ) external onlyAttester {
        require(frameHash != bytes32(0), "PlausibilityRegistry: zero frame");
        require(policyHash != bytes32(0), "PlausibilityRegistry: zero policy");
        require(validUntil >= block.timestamp, "PlausibilityRegistry: expired attestation");
        uint64 revision = _frameRevisions[frameHash];
        if (revision == 0) {
            revision = 1;
            _frameRevisions[frameHash] = revision;
        }
        FrameTally storage tally = _tallies[frameHash];
        if (tally.policyHash == bytes32(0)) {
            tally.policyHash = policyHash;
            tally.validUntil = validUntil;
            tally.minimumAttestationsAtTally = minimumAttestations;
            tally.revision = revision;
        } else {
            require(tally.policyHash == policyHash, "PlausibilityRegistry: policy mismatch");
            require(tally.validUntil == validUntil, "PlausibilityRegistry: expiry mismatch");
            require(tally.revision == revision, "PlausibilityRegistry: frame reset");
        }

        uint64 attesterRevision = _attesterRevisions[msg.sender];
        require(
            hasAttested[frameHash][msg.sender].revision != revision
                || hasAttested[frameHash][msg.sender].attesterRevision != attesterRevision,
            "PlausibilityRegistry: duplicate attestation"
        );

        hasAttested[frameHash][msg.sender] = Attestation({
            revision: revision,
            attesterRevision: attesterRevision,
            plausible: plausible
        });
        if (!_frameAttesterSeen[frameHash][msg.sender]) {
            _frameAttesters[frameHash].push(msg.sender);
            _frameAttesterSeen[frameHash][msg.sender] = true;
        }

        if (plausible) {
            tally.plausibleCount++;
        } else {
            tally.implausibleCount++;
        }

        emit PlausibilityAttested(frameHash, policyHash, msg.sender, plausible, validUntil);
    }

    function getTally(bytes32 frameHash) external view returns (FrameTally memory) {
        (uint32 plausibleCount, uint32 implausibleCount) = _computeActiveTallies(frameHash);

        FrameTally memory tally = _tallies[frameHash];
        tally.plausibleCount = plausibleCount;
        tally.implausibleCount = implausibleCount;
        return tally;
    }

    function isPlausible(bytes32 frameHash) external view returns (bool) {
        (uint32 plausibleCount, uint32 implausibleCount) = _computeActiveTallies(frameHash);
        FrameTally memory tally = _tallies[frameHash];
        return tally.minimumAttestationsAtTally > 0
            && tally.validUntil >= block.timestamp
            && plausibleCount >= tally.minimumAttestationsAtTally
            && implausibleCount < tally.minimumAttestationsAtTally;
    }

    function isQuarantined(bytes32 frameHash) external view returns (bool) {
        (, uint32 implausibleCount) = _computeActiveTallies(frameHash);
        FrameTally memory tally = _tallies[frameHash];
        return tally.minimumAttestationsAtTally > 0
            && implausibleCount >= tally.minimumAttestationsAtTally;
    }

    /// @notice Exposes this quorum as the fail-closed verdict seam consumed by
    ///         ProofOfObservationMintGate.
    /// @dev A partial positive tally is unavailable so a frame remains retryable.
    ///      A negative quorum is available and failed, including after expiry,
    ///      matching isQuarantined's durable quarantine semantics. Positive
    ///      attestations expire normally and therefore cease to be available.
    function verdictFor(bytes32 frameHash)
        external
        view
        override
        returns (bool available, bool passed)
    {
        (uint32 plausibleCount, uint32 implausibleCount) = _computeActiveTallies(frameHash);
        FrameTally memory tally = _tallies[frameHash];
        uint32 quorum = tally.minimumAttestationsAtTally;

        if (quorum == 0) return (false, false);
        if (implausibleCount >= quorum) return (true, false);
        if (tally.validUntil < block.timestamp) return (false, false);
        if (plausibleCount >= quorum) return (true, true);
        return (false, false);
    }

    function resetFrameTally(bytes32 frameHash) external onlyOwner {
        _frameRevisions[frameHash]++;
        delete _tallies[frameHash];
        emit FrameTallyReset(frameHash, _frameRevisions[frameHash]);
    }

    function _computeActiveTallies(bytes32 frameHash) internal view returns (uint32 plausibleCount, uint32 implausibleCount) {
        address[] memory voters = _frameAttesters[frameHash];
        FrameTally memory tally = _tallies[frameHash];
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            if (!attesters[voter]) {
                continue;
            }
            Attestation memory attestation = hasAttested[frameHash][voter];
            if (attestation.revision != tally.revision || attestation.attesterRevision != _attesterRevisions[voter]) {
                continue;
            }
            if (attestation.plausible) {
                plausibleCount++;
            } else {
                implausibleCount++;
            }
        }
    }
}
