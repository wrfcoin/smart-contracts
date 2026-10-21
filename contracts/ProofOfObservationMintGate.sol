// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/INodeKeyRegistry.sol";
import "./interfaces/IPlausibilityVerdictSource.sol";
import "./interfaces/IGeoCellRegistry.sol";

/**
 * @title ProofOfObservationMintGate — the fail-closed mint seam of ADR-159
 * @notice Implements the #159 validation + emission-budget policy WITHOUT any
 *         token supply surface. Every ADR-159 input is an explicit seam that
 *         fails closed, and the emission budget is enforced on an accrual
 *         ledger before correctness tuning — the lesson of backend#940, where
 *         an unbudgeted mint path became a launch blocker.
 *
 * @dev MINTING IS STRUCTURALLY DISABLED. There is no token address, no mint
 *      call, and deliberately NO function that could enable one: turning this
 *      ledger into token supply requires a contract change reviewed by
 *      governance with named reward values and a supply-impact review
 *      (ADR-159 "Consequences"). A boolean an admin could quietly flip would
 *      be weaker than a switch that does not exist.
 *
 *      What this contract does NOT pin, stated rather than implied:
 *      - It does NOT verify P-256/ATECC608A signatures. #158 is closed-blocked
 *        and CryptographicSecurityModule reverts on ECDSA_SECP256R1. Until a
 *        verifier decision lands, signature validity is the SUBMITTER_ROLE
 *        oracle's assertion; the registry seam pins key/identity STATE only.
 *      - It does NOT choose reward values. Policy numbers are governance
 *        inputs; unset policy reverts.
 *      - It does NOT pay or mint anything. `withheldAccrual` is bookkeeping
 *        for a future governance-approved consumer.
 */
contract ProofOfObservationMintGate is AccessControl {
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");

    /// @notice ADR-159 §1 domain tag; schema-versioned in `canonicalDigest`.
    /// @dev V2: the digest preimage now includes `nodeId` (#220 review,
    ///      Finding 2), so the replay key matches the accrual key per ADR-159
    ///      §3 ("registered node identity plus a ... frame identifier"). Two
    ///      nodes observing identical content no longer collide, and one node
    ///      cannot consume a digest another node would need.
    bytes32 public constant DOMAIN_TAG = keccak256("WRFCOIN_POO_FRAME_V2");

    /// @notice Structurally false — see the contract-level @dev note.
    bool public constant MINTING_ENABLED = false;

    struct ObservationFrame {
        bytes32 frameDigest; // W3 frame digest as produced off-chain
        uint32 schemaVersion; // W3 schema version the digest was computed under
        bytes32 nodeId; // registered hardware-root identity
        uint32 keyVersion; // key version the frame was signed under
        uint64 sequence; // node-local monotonic sequence (observability)
        uint64 observedAt; // observation timestamp, seconds
    }

    /// @notice ADR-159 §4/§5 parameters. All zero until governance sets them.
    /// @dev The #161 values (`maxAccruingNodesPerCell`, `geoCellResolution`,
    ///      `uniquenessBucketSec`) are GOVERNANCE inputs like the caps — the
    ///      defaults used in tests are placeholders, not a ruling. Same
    ///      discipline as backend#940's emission ceilings.
    struct EmissionPolicy {
        uint128 perFrameAccrual; // accrued per verified frame (may be 0)
        uint128 perNodeEpochCap; // max accrual per node per epoch
        uint128 globalEpochCap; // max accrual across all nodes per epoch
        uint64 epochLength; // seconds; 0 means "policy unset" => gate closed
        uint64 maxFrameAgeSec; // oldest acceptable observedAt relative to now
        uint64 maxFutureSkewSec; // furthest-future acceptable observedAt
        uint32 maxAccruingNodesPerCell; // #161 K: identities earning per cell per bucket
        uint32 geoCellResolution; // #161: off-chain cell derivation resolution, named on-chain
        uint64 uniquenessBucketSec; // #161 time-bucket length; 0 => policy unset
        // #223 review, Finding 2: `timeBucket` derives from the submitter-chosen
        // `observedAt`, so the true per-cell bound is K x (buckets reachable
        // inside the clock window), not K. This field DECLARES that bucket
        // count; `setPolicy` refuses any clock window that reaches more. It is
        // a budget bound like K — it re-keys nothing, so it stays tunable —
        // but widening the identity budget now requires touching the parameter
        // whose name says what it does, never a `maxFrameAgeSec` "tuning" edit.
        uint32 maxReachableBuckets; // #161: declared buckets reachable per submission window
    }

    enum FrameStatus {
        Unseen,
        Verified, // consumed; accrual recorded (withheld — minting disabled)
        QuarantinedImplausible // consumed; judged implausible, no accrual
    }

    INodeKeyRegistry public nodeKeyRegistry;
    IPlausibilityVerdictSource public plausibilitySource;
    IGeoCellRegistry public geoCellRegistry;
    EmissionPolicy public policy;

    /// @notice consumed-frame storage scoped to the canonical digest (ADR-159 §3).
    mapping(bytes32 => FrameStatus) public frameStatus;
    /// @notice highest sequence seen per node — observability, not a replay guard.
    mapping(bytes32 => uint64) public highestSequence;
    /// @notice withheld accrual ledger (no token behind it).
    mapping(bytes32 => uint256) public withheldAccrual;
    uint256 public totalWithheldAccrual;

    // ---- Anchored epoch state (#220 review, Finding 1) ----
    // The epoch index is a MONOTONE counter advanced only by elapsed time,
    // never by a policy edit. Deriving it as timestamp/epochLength re-keyed
    // every budget counter the moment epochLength changed, handing back a
    // fresh budget inside the same wall-clock window (measured in review:
    // 300 accrued against a 250 cap). `activeEpochLength` is locked at each
    // boundary, so an edit takes effect only from the NEXT epoch — a
    // setPolicy call can neither re-key nor shorten the window it is in.
    uint256 public epochIndex;
    uint64 public epochStartedAt; // 0 = no accrual epoch started yet
    uint64 public activeEpochLength; // length governing the CURRENT epoch

    // epoch => accrued
    mapping(uint256 => uint256) public globalAccruedInEpoch;
    // nodeId => epoch => accrued
    mapping(bytes32 => mapping(uint256 => uint256)) public nodeAccruedInEpoch;

    // ---- #161 geo-temporal uniqueness (extends the consumed-digest shape,
    //      not a second dedupe seam) ----
    // nodeId => cell => bucket => claimed
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => bool))) public cellClaimed;
    // cell => bucket => number of distinct accruing identities
    mapping(bytes32 => mapping(uint256 => uint256)) public cellAccruerCount;

    event SeamsConfigured(
        address nodeKeyRegistry, address plausibilitySource, address geoCellRegistry
    );
    event GeoTemporalClaimRecorded(
        bytes32 indexed nodeId, bytes32 indexed geoCell, uint256 timeBucket
    );
    event PolicyUpdated(EmissionPolicy policy);
    event ObservationVerified(
        bytes32 indexed nodeId, bytes32 indexed canonicalDigest, uint256 accrued, bool minted
    );
    event FrameQuarantined(
        bytes32 indexed nodeId, bytes32 indexed canonicalDigest, bool verdictAvailable
    );

    error PolicyUnset();
    error InvalidPolicy();
    error NodeRegistryUnavailable();
    error PlausibilitySourceUnavailable();
    error UnregisteredNode(bytes32 nodeId);
    error InactiveKey(bytes32 nodeId, uint32 keyVersion);
    error FrameAlreadyConsumed(bytes32 canonicalDigest);
    error FrameOutOfClockBounds(uint64 observedAt);
    error EmissionBudgetExceeded(bytes32 nodeId);
    error GeoCellRegistryUnavailable();
    error NodeCellUnregistered(bytes32 nodeId);
    error DuplicateGeoTemporalClaim(bytes32 nodeId, bytes32 geoCell, uint256 timeBucket);
    error GeoCellCapReached(bytes32 geoCell, uint256 timeBucket);
    error GeoParamsImmutableAfterUse();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------
    // Governance surface
    // ------------------------------------------------------------------

    function configureSeams(
        INodeKeyRegistry registry,
        IPlausibilityVerdictSource source,
        IGeoCellRegistry cellRegistry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nodeKeyRegistry = registry;
        plausibilitySource = source;
        geoCellRegistry = cellRegistry;
        emit SeamsConfigured(address(registry), address(source), address(cellRegistry));
    }

    function setPolicy(EmissionPolicy calldata newPolicy) external onlyRole(POLICY_ADMIN_ROLE) {
        // A set policy must be internally consistent: a per-frame accrual
        // larger than the per-node cap makes every submission revert, and a
        // per-node cap above the global cap is unreachable. Both are silent
        // misconfigurations on exactly the surface where misconfiguration is
        // the risk (#220 review). An all-zero policy (unset) remains legal.
        if (newPolicy.epochLength != 0) {
            if (
                newPolicy.perFrameAccrual > newPolicy.perNodeEpochCap
                    || newPolicy.perNodeEpochCap > newPolicy.globalEpochCap
            ) revert InvalidPolicy();
        }
        // #161 / #220-review class: the geo parameters are IDENTITY-affecting,
        // not tuning knobs. `uniquenessBucketSec` re-buckets every
        // (node, cell, timeBucket) claim and `geoCellResolution` re-keys every
        // off-chain cell derivation — either edit would re-open claims already
        // consumed, the same mutable-divisor defect as the epoch finding, one
        // layer over. Once any accrual epoch has started they are immutable;
        // changing them requires a redeploy with a governance review.
        if (epochStartedAt != 0) {
            if (
                newPolicy.uniquenessBucketSec != policy.uniquenessBucketSec
                    || newPolicy.geoCellResolution != policy.geoCellResolution
            ) revert GeoParamsImmutableAfterUse();
        }
        // #223 review, Finding 2: nothing used to constrain the trio
        // (maxFrameAgeSec, maxFutureSkewSec, uniquenessBucketSec) against each
        // other, so K bounded identities per BUCKET while the submitter chose
        // the bucket — the effective cap was an emergent K x 144 with the
        // placeholder values, and a maxFrameAgeSec edit multiplied it
        // silently. The reachable-bucket count must now be DECLARED, and the
        // clock window must fit inside it: governance approves
        // K x maxReachableBuckets per cell per window, explicitly. Checked
        // after immutability so a frozen-param edit names the freeze, not the
        // arithmetic.
        if (newPolicy.uniquenessBucketSec != 0) {
            uint256 reachable = (
                uint256(newPolicy.maxFrameAgeSec) + uint256(newPolicy.maxFutureSkewSec)
            ) / newPolicy.uniquenessBucketSec + 1;
            if (newPolicy.maxReachableBuckets == 0 || reachable > newPolicy.maxReachableBuckets) {
                revert InvalidPolicy();
            }
        }
        policy = newPolicy;
        emit PolicyUpdated(newPolicy);
    }

    // ------------------------------------------------------------------
    // The gate
    // ------------------------------------------------------------------

    /// @notice ADR-159 §1/§3: versioned digest under chain/contract/schema
    ///         domain, scoped to the submitting node's identity.
    function canonicalDigest(ObservationFrame calldata frame) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TAG,
                block.chainid,
                address(this),
                frame.nodeId,
                frame.schemaVersion,
                frame.frameDigest
            )
        );
    }

    /// @notice Observability view of the anchored epoch: what `_rollEpoch`
    ///         would return now, without mutating. Reverts `PolicyUnset`
    ///         instead of panicking on division before the policy exists.
    function currentEpoch() public view returns (uint256) {
        if (policy.epochLength == 0) revert PolicyUnset();
        if (epochStartedAt == 0) return epochIndex;
        uint256 elapsed = block.timestamp - epochStartedAt;
        if (elapsed < activeEpochLength) return epochIndex;
        return epochIndex + elapsed / activeEpochLength;
    }

    /// @notice The per-cell identity budget governance is ACTUALLY approving
    ///         (#223 review, Finding 2): K identities per bucket times the
    ///         declared reachable-bucket count — visible, not emergent.
    function maxAccrualsPerCellPerWindow() external view returns (uint256) {
        if (policy.uniquenessBucketSec == 0 || policy.maxAccruingNodesPerCell == 0) {
            revert PolicyUnset();
        }
        return uint256(policy.maxAccruingNodesPerCell) * uint256(policy.maxReachableBuckets);
    }

    /// @dev Advance the anchored epoch by ELAPSED TIME only. The length
    ///      governing the current epoch was locked at its boundary; a policy
    ///      edit is adopted at the next boundary, never mid-window (#220
    ///      review, Finding 1).
    function _rollEpoch() internal returns (uint256) {
        if (epochStartedAt == 0) {
            epochStartedAt = uint64(block.timestamp);
            activeEpochLength = policy.epochLength;
            return epochIndex;
        }
        uint256 elapsed = block.timestamp - epochStartedAt;
        if (elapsed >= activeEpochLength) {
            uint256 advance = elapsed / activeEpochLength;
            epochIndex += advance;
            epochStartedAt += uint64(advance * uint256(activeEpochLength));
            activeEpochLength = policy.epochLength;
        }
        return epochIndex;
    }

    /**
     * @notice Validate one observation frame through every ADR-159 seam, in a
     *         fixed order so each failure names its cause. A frame that passes
     *         everything is consumed and its accrual WITHHELD (minting is
     *         structurally disabled).
     */
    function submitObservation(ObservationFrame calldata frame)
        external
        onlyRole(SUBMITTER_ROLE)
        returns (bytes32 digest)
    {
        // ADR-159 §4 / #161: no policy, no gate. All-or-nothing — a partially
        // set policy (missing bucket length or a zero cell cap) is unset.
        if (
            policy.epochLength == 0 || policy.uniquenessBucketSec == 0
                || policy.maxAccruingNodesPerCell == 0
        ) revert PolicyUnset();

        // ADR-159 §2: registry state must exist and answer for this node/key.
        INodeKeyRegistry registry = nodeKeyRegistry;
        if (address(registry) == address(0)) revert NodeRegistryUnavailable();
        if (!registry.isRegisteredNode(frame.nodeId)) revert UnregisteredNode(frame.nodeId);
        if (!registry.isActiveKey(frame.nodeId, frame.keyVersion)) {
            // Named consequence: rotation invalidates frames a node buffered
            // offline under the superseded keyVersion. Correct as a security
            // posture — a revoked key must not keep minting — but operators
            // should rotate with the offline-buffer window (ADR-159 §5) in
            // mind.
            revert InactiveKey(frame.nodeId, frame.keyVersion);
        }

        // ADR-159 §5: clock bounds for late/offline frames.
        if (
            frame.observedAt + policy.maxFrameAgeSec < block.timestamp
                || frame.observedAt > block.timestamp + policy.maxFutureSkewSec
        ) revert FrameOutOfClockBounds(frame.observedAt);

        // ADR-159 §3: replay across offline buffers — consumed-digest storage.
        digest = canonicalDigest(frame);
        if (frameStatus[digest] != FrameStatus.Unseen) revert FrameAlreadyConsumed(digest);

        // ADR-159 §6: independent plausibility verdict, fail closed.
        IPlausibilityVerdictSource source = plausibilitySource;
        if (address(source) == address(0)) revert PlausibilitySourceUnavailable();
        (bool available, bool passed) = source.verdictFor(digest);
        if (!available) {
            // NOT consumed: the frame may be re-submitted once a verdict
            // exists. Submission is role-gated, so this cannot be spammed by
            // the public.
            emit FrameQuarantined(frame.nodeId, digest, false);
            return digest;
        }
        if (!passed) {
            // Judged implausible: consumed, so the same frame cannot be
            // retried into a mint later (#160 quarantine semantics).
            frameStatus[digest] = FrameStatus.QuarantinedImplausible;
            emit FrameQuarantined(frame.nodeId, digest, true);
            return digest;
        }

        // #161: geo-temporal uniqueness. The cell is REGISTRY state claimed at
        // registration (infra#589 surface), never read from the frame — a
        // frame cannot claim an arbitrary cell.
        IGeoCellRegistry cellRegistry = geoCellRegistry;
        if (address(cellRegistry) == address(0)) revert GeoCellRegistryUnavailable();
        bytes32 geoCell = cellRegistry.registeredCell(frame.nodeId);
        if (geoCell == bytes32(0)) revert NodeCellUnregistered(frame.nodeId);

        // One accrual per (identity, cell, time-bucket) — the consumed-digest
        // shape, keyed on the observation's own timestamp.
        uint256 timeBucket = uint256(frame.observedAt) / policy.uniquenessBucketSec;
        if (cellClaimed[frame.nodeId][geoCell][timeBucket]) {
            revert DuplicateGeoTemporalClaim(frame.nodeId, geoCell, timeBucket);
        }
        // At most K identities earn per cell per bucket: the 10,001st station
        // in a cell earns exactly nothing.
        if (cellAccruerCount[geoCell][timeBucket] >= policy.maxAccruingNodesPerCell) {
            revert GeoCellCapReached(geoCell, timeBucket);
        }

        // ADR-159 §4: emission budget enforced BEFORE any accrual, keyed on
        // the ANCHORED epoch (a policy edit cannot hand back a fresh budget).
        // A capped frame is NOT consumed — deliberate defer-don't-destroy:
        // the same frame may be resubmitted once a later epoch has budget.
        // This is the one place a frame survives a rejection.
        uint256 epoch = _rollEpoch();
        uint256 accrual = policy.perFrameAccrual;
        if (
            nodeAccruedInEpoch[frame.nodeId][epoch] + accrual > policy.perNodeEpochCap
                || globalAccruedInEpoch[epoch] + accrual > policy.globalEpochCap
        ) revert EmissionBudgetExceeded(frame.nodeId);

        cellClaimed[frame.nodeId][geoCell][timeBucket] = true;
        cellAccruerCount[geoCell][timeBucket] += 1;
        emit GeoTemporalClaimRecorded(frame.nodeId, geoCell, timeBucket);

        frameStatus[digest] = FrameStatus.Verified;
        if (frame.sequence > highestSequence[frame.nodeId]) {
            highestSequence[frame.nodeId] = frame.sequence;
        }
        nodeAccruedInEpoch[frame.nodeId][epoch] += accrual;
        globalAccruedInEpoch[epoch] += accrual;
        withheldAccrual[frame.nodeId] += accrual;
        totalWithheldAccrual += accrual;

        emit ObservationVerified(frame.nodeId, digest, accrual, MINTING_ENABLED);
    }
}
