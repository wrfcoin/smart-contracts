'use strict';

/**
 * #161 — geo-temporal uniqueness / Sybil resistance at the mint gate.
 *
 * The contract posted on #161 (manager-ACKed): one hardware root = one
 * identity, one registered geo-cell, at most one accrual per
 * (nodeId, geoCell, timeBucket), and at most K identities earning per cell
 * per bucket. The cell comes from REGISTRY state, never from the frame.
 *
 * What this suite does NOT pin: GPS truth or trajectory continuity (off-chain
 * plausibility inputs by design), the real K / cell resolution / bucket length
 * (governance values — Tony's ruling; numbers here are placeholders), and the
 * registry implementation itself (mocked — none exists until the #158-class
 * registrar lands). Per #223 Finding 2 it also does NOT pin per-identity
 * accrual across buckets to fewer than maxReachableBuckets: an identity may
 * legitimately accrue once in every reachable bucket. What IS pinned is that
 * the reachable count is a declared policy input — the per-cell bound is
 * K x maxReachableBuckets by declaration, never an emergent product of clock
 * knobs.
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('ProofOfObservationMintGate — #161 geo-temporal uniqueness', function () {
  const KEY_V = 1;
  const CELL_A = ethers.id('cell-A');
  const CELL_B = ethers.id('cell-B');

  async function deployArmed() {
    const [admin, submitter] = await ethers.getSigners();

    const Gate = await ethers.getContractFactory('ProofOfObservationMintGate');
    const gate = await Gate.deploy(await admin.getAddress());
    const Registry = await ethers.getContractFactory('MockNodeKeyRegistry');
    const registry = await Registry.deploy();
    const Source = await ethers.getContractFactory('MockPlausibilityVerdictSource');
    const source = await Source.deploy();
    const Cells = await ethers.getContractFactory('MockGeoCellRegistry');
    const cellRegistry = await Cells.deploy();

    await gate.connect(admin).grantRole(await gate.POLICY_ADMIN_ROLE(), await admin.getAddress());
    await gate.connect(admin).grantRole(await gate.SUBMITTER_ROLE(), await submitter.getAddress());
    await gate
      .connect(admin)
      .configureSeams(
        await registry.getAddress(),
        await source.getAddress(),
        await cellRegistry.getAddress(),
      );
    await gate.connect(admin).setPolicy({
      perFrameAccrual: 10n,
      perNodeEpochCap: 1000n,
      globalEpochCap: 10000n,
      epochLength: 3600n,
      maxFrameAgeSec: 86400n,
      maxFutureSkewSec: 300n,
      // Placeholders — real values are a governance ruling (see PR body).
      maxAccruingNodesPerCell: 2,
      geoCellResolution: 6,
      uniquenessBucketSec: 600n,
      // (86400 + 300) / 600 + 1 — the clock window must fit the declaration.
      maxReachableBuckets: 145,
    });
    await source.setDefault(true, true);

    const nodes = [];
    for (const name of ['n1', 'n2', 'n3']) {
      const id = ethers.id(name);
      await registry.setRegistered(id, true);
      await registry.setActiveKey(id, KEY_V, true);
      nodes.push(id);
    }

    const now = BigInt((await ethers.provider.getBlock('latest')).timestamp);
    const frame = (nodeId, observedAt) => ({
      frameDigest: ethers.hexlify(ethers.randomBytes(32)),
      schemaVersion: 1,
      nodeId,
      keyVersion: KEY_V,
      sequence: 1n,
      observedAt,
    });

    return { gate, submitter, cellRegistry, nodes, now, frame };
  }

  it('rejects a node with no registered cell — the frame cannot claim one', async function () {
    const { gate, submitter, nodes, now, frame } = await deployArmed();

    await expect(gate.connect(submitter).submitObservation(frame(nodes[0], now)))
      .to.be.revertedWithCustomError(gate, 'NodeCellUnregistered');
  });

  it('allows one accrual per (node, cell, bucket); the next bucket accrues again', async function () {
    const { gate, submitter, cellRegistry, nodes, now, frame } = await deployArmed();
    await cellRegistry.setCell(nodes[0], CELL_A);

    await expect(gate.connect(submitter).submitObservation(frame(nodes[0], now)))
      .to.emit(gate, 'GeoTemporalClaimRecorded');

    // A DIFFERENT frame, same node, same 600s bucket: refused.
    await expect(gate.connect(submitter).submitObservation(frame(nodes[0], now - 1n)))
      .to.be.revertedWithCustomError(gate, 'DuplicateGeoTemporalClaim');

    // Next bucket: earns again.
    await expect(gate.connect(submitter).submitObservation(frame(nodes[0], now - 601n)))
      .to.emit(gate, 'ObservationVerified');
  });

  it('caps accruing identities per cell per bucket at K; other cells unaffected', async function () {
    const { gate, submitter, cellRegistry, nodes, now, frame } = await deployArmed();
    const [n1, n2, n3] = nodes;
    await cellRegistry.setCell(n1, CELL_A);
    await cellRegistry.setCell(n2, CELL_A);
    await cellRegistry.setCell(n3, CELL_A);

    // K = 2: the first two identities in cell-A earn this bucket.
    await gate.connect(submitter).submitObservation(frame(n1, now));
    await gate.connect(submitter).submitObservation(frame(n2, now));

    // The third earns exactly nothing.
    await expect(gate.connect(submitter).submitObservation(frame(n3, now)))
      .to.be.revertedWithCustomError(gate, 'GeoCellCapReached');

    // Same identity, different registered cell: unaffected by cell-A's cap.
    await cellRegistry.setCell(n3, CELL_B);
    await expect(gate.connect(submitter).submitObservation(frame(n3, now)))
      .to.emit(gate, 'ObservationVerified');

    // And cell-A frees up in the next bucket.
    await expect(gate.connect(submitter).submitObservation(frame(n1, now - 601n)))
      .to.emit(gate, 'ObservationVerified');
  });

  it('treats a partially set #161 policy as unset (fail closed)', async function () {
    const { gate, submitter, cellRegistry, nodes, now, frame } = await deployArmed();
    await cellRegistry.setCell(nodes[0], CELL_A);
    const [admin] = await ethers.getSigners();

    const basePolicy = {
      perFrameAccrual: 10n,
      perNodeEpochCap: 1000n,
      globalEpochCap: 10000n,
      epochLength: 3600n,
      maxFrameAgeSec: 86400n,
      maxFutureSkewSec: 300n,
      maxAccruingNodesPerCell: 2,
      geoCellResolution: 6,
      uniquenessBucketSec: 600n,
      maxReachableBuckets: 145,
    };

    for (const hole of [{ uniquenessBucketSec: 0n }, { maxAccruingNodesPerCell: 0 }]) {
      await gate.connect(admin).setPolicy({ ...basePolicy, ...hole });
      await expect(gate.connect(submitter).submitObservation(frame(nodes[0], now)))
        .to.be.revertedWithCustomError(gate, 'PolicyUnset');
    }
  });

  it('geo identity parameters are immutable after first accrual (#220-review class)', async function () {
    const { gate, submitter, cellRegistry, nodes, now, frame } = await deployArmed();
    const [admin] = await ethers.getSigners();
    await cellRegistry.setCell(nodes[0], CELL_A);

    const policy = {
      perFrameAccrual: 10n,
      perNodeEpochCap: 1000n,
      globalEpochCap: 10000n,
      epochLength: 3600n,
      maxFrameAgeSec: 86400n,
      maxFutureSkewSec: 300n,
      maxAccruingNodesPerCell: 2,
      geoCellResolution: 6,
      uniquenessBucketSec: 600n,
      maxReachableBuckets: 145,
    };

    // BEFORE any accrual: identity params may still be tuned — but a shorter
    // bucket reaches more buckets, so the declared bound must move with it
    // (#223 Finding 2 coupling).
    await expect(
      gate
        .connect(admin)
        .setPolicy({ ...policy, uniquenessBucketSec: 300n, maxReachableBuckets: 290 }),
    ).to.emit(gate, 'PolicyUpdated');
    await expect(gate.connect(admin).setPolicy(policy)).to.emit(gate, 'PolicyUpdated');

    // First accrual starts the epoch clock and locks the identity params:
    // re-bucketing (uniquenessBucketSec) or re-keying cell derivation
    // (geoCellResolution) would re-open claims already consumed — the same
    // mutable-divisor class as the #220 epoch finding, one layer over.
    await gate.connect(submitter).submitObservation(frame(nodes[0], now));

    await expect(gate.connect(admin).setPolicy({ ...policy, uniquenessBucketSec: 300n }))
      .to.be.revertedWithCustomError(gate, 'GeoParamsImmutableAfterUse');
    await expect(gate.connect(admin).setPolicy({ ...policy, geoCellResolution: 7 }))
      .to.be.revertedWithCustomError(gate, 'GeoParamsImmutableAfterUse');

    // Emission caps remain tunable — they are budget knobs, not identity keys.
    await expect(gate.connect(admin).setPolicy({ ...policy, perNodeEpochCap: 2000n }))
      .to.emit(gate, 'PolicyUpdated');
  });

  it('refuses a clock window that reaches more buckets than the policy declares (#223 Finding 2)', async function () {
    const { gate } = await deployArmed();
    const [admin] = await ethers.getSigners();

    const policy = {
      perFrameAccrual: 10n,
      perNodeEpochCap: 1000n,
      globalEpochCap: 10000n,
      epochLength: 3600n,
      maxFrameAgeSec: 86400n,
      maxFutureSkewSec: 300n,
      maxAccruingNodesPerCell: 2,
      geoCellResolution: 6,
      uniquenessBucketSec: 600n,
      maxReachableBuckets: 145, // (86400 + 300) / 600 + 1 — exactly fits
    };

    // An UNDECLARED bound with the geo policy set is a misconfiguration, not
    // a default: the old behavior (K x an emergent 144) is no longer settable.
    await expect(gate.connect(admin).setPolicy({ ...policy, maxReachableBuckets: 0 }))
      .to.be.revertedWithCustomError(gate, 'InvalidPolicy');

    // A maxFrameAgeSec "tuning" edit used to silently multiply the identity
    // budget through the bucket derivation. Now the window must fit the
    // declaration: widening it alone is refused ...
    await expect(gate.connect(admin).setPolicy({ ...policy, maxFrameAgeSec: 172800n }))
      .to.be.revertedWithCustomError(gate, 'InvalidPolicy');

    // ... and accepted only as an EXPLICIT joint decision with the bound —
    // the coupling Alice's review named, expressed at the policy surface.
    await expect(
      gate
        .connect(admin)
        .setPolicy({ ...policy, maxFrameAgeSec: 172800n, maxReachableBuckets: 289 }),
    ).to.emit(gate, 'PolicyUpdated');

    // Shrinking the window within the declared bound is ordinary tuning.
    await expect(gate.connect(admin).setPolicy({ ...policy, maxFrameAgeSec: 3600n }))
      .to.emit(gate, 'PolicyUpdated');
  });

  it('surfaces the per-cell identity budget governance actually approves: K x maxReachableBuckets', async function () {
    const { gate, submitter, cellRegistry, nodes, now, frame } = await deployArmed();
    const [n1, n2, n3] = nodes;
    await cellRegistry.setCell(n1, CELL_A);
    await cellRegistry.setCell(n2, CELL_A);
    await cellRegistry.setCell(n3, CELL_A);

    // K = 2, declared reachable buckets = 145: the number governance approved
    // is 290 accruals per cell per window — visible, not emergent.
    expect(await gate.maxAccrualsPerCellPerWindow()).to.equal(2n * 145n);

    // Alice's PROBE D, restated as declared intent rather than evasion: an
    // identity that finds its bucket full MAY accrue in another reachable
    // bucket — that accrual spends the declared K x 145 budget. What changed
    // is not this behavior but its accounting: the bound it draws on is now
    // written at the policy surface, and no clock-window edit can widen it
    // without the declaration moving in the same decision.
    await gate.connect(submitter).submitObservation(frame(n1, now));
    await gate.connect(submitter).submitObservation(frame(n2, now));
    await expect(gate.connect(submitter).submitObservation(frame(n3, now)))
      .to.be.revertedWithCustomError(gate, 'GeoCellCapReached');
    await expect(gate.connect(submitter).submitObservation(frame(n3, now - 601n)))
      .to.emit(gate, 'ObservationVerified');
  });

  it('a quarantined frame claims no geo-temporal slot', async function () {
    const { gate, submitter, cellRegistry, nodes, now, frame } = await deployArmed();
    await cellRegistry.setCell(nodes[0], CELL_A);

    // Force an implausible verdict for one specific frame.
    const bad = frame(nodes[0], now);
    const Source = await ethers.getContractAt(
      'MockPlausibilityVerdictSource',
      await gate.plausibilitySource(),
    );
    const digest = await gate.canonicalDigest(bad);
    await Source.setVerdict(digest, true, false);

    await expect(gate.connect(submitter).submitObservation(bad))
      .to.emit(gate, 'FrameQuarantined');

    // The slot is still free: a plausible frame in the SAME bucket accrues.
    await expect(gate.connect(submitter).submitObservation(frame(nodes[0], now - 1n)))
      .to.emit(gate, 'ObservationVerified');
  });
});
