'use strict';

/**
 * #159 — ProofOfObservationMintGate focused suite.
 *
 * ADR-159 mandates two RED cases at the mint seam: a deliberately replayed
 * buffered frame and an unregistered signer must both revert. Both are here,
 * plus the fail-closed seams (unset policy/registry/source, unavailable
 * verdict) and the emission budget, which is enforced even though minting is
 * structurally disabled.
 *
 * What this suite does NOT pin: P-256 signature validity (no verifier exists —
 * the registry seam pins identity/key STATE only), reward values (test numbers
 * are arbitrary), and any token movement (there is none to observe).
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('ProofOfObservationMintGate (#159)', function () {
  const NODE = ethers.id('node-1');
  const KEY_V = 1;

  async function deployGate() {
    const [admin, submitter, outsider] = await ethers.getSigners();

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

    const policy = {
      perFrameAccrual: 100n,
      perNodeEpochCap: 250n,
      globalEpochCap: 400n,
      epochLength: 3600n,
      maxFrameAgeSec: 86400n,
      maxFutureSkewSec: 300n,
      // #161 placeholders — the real K/resolution/bucket are Tony's ruling.
      maxAccruingNodesPerCell: 10,
      geoCellResolution: 6,
      uniquenessBucketSec: 600n,
      // (86400 + 300) / 600 + 1 — the clock window must fit the declaration.
      maxReachableBuckets: 145,
    };

    return { admin, submitter, outsider, gate, registry, source, cellRegistry, policy };
  }

  // Each fresh frame lands in its own #161 time-bucket (601s apart, bucket is
  // 600s) so multi-frame tests exercise what they mean to — the emission
  // budget, replay, plausibility — without tripping the one-accrual-per-
  // (node, cell, bucket) rule. Well within maxFrameAgeSec (86400s).
  let bucketOffset = 0;
  async function freshFrame(overrides = {}) {
    const now = BigInt((await ethers.provider.getBlock('latest')).timestamp);
    bucketOffset += 1;
    return {
      frameDigest: ethers.hexlify(ethers.randomBytes(32)),
      schemaVersion: 1,
      nodeId: NODE,
      keyVersion: KEY_V,
      sequence: 1n,
      observedAt: now - BigInt(bucketOffset * 601),
      ...overrides,
    };
  }

  async function armAllSeams({ gate, admin, registry, source, cellRegistry, policy }) {
    await gate
      .connect(admin)
      .configureSeams(
        await registry.getAddress(),
        await source.getAddress(),
        await cellRegistry.getAddress(),
      );
    await gate.connect(admin).setPolicy(policy);
    await registry.setRegistered(NODE, true);
    await registry.setActiveKey(NODE, KEY_V, true);
    await cellRegistry.setCell(NODE, ethers.id('cell-A'));
    await source.setDefault(true, true);
  }

  async function deployAttestationSource(admin) {
    const [, , , attesterOne, attesterTwo] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory('PlausibilityAttestationRegistry');
    const source = await Registry.deploy(await admin.getAddress());
    await source.waitForDeployment();
    await source.connect(admin).addAttester(await attesterOne.getAddress());
    await source.connect(admin).addAttester(await attesterTwo.getAddress());
    await source.connect(admin).setMinimumAttestations(2);
    return { source, attesterOne, attesterTwo };
  }

  it('fails closed with no policy, registry, verdict source, cell registry, or cell — in that order', async function () {
    const ctx = await deployGate();
    const { gate, admin, submitter, registry, source, cellRegistry, policy } = ctx;
    const frame = await freshFrame();

    await expect(gate.connect(submitter).submitObservation(frame))
      .to.be.revertedWithCustomError(gate, 'PolicyUnset');

    await gate.connect(admin).setPolicy(policy);
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.be.revertedWithCustomError(gate, 'NodeRegistryUnavailable');

    await gate
      .connect(admin)
      .configureSeams(await registry.getAddress(), ethers.ZeroAddress, ethers.ZeroAddress);
    await registry.setRegistered(NODE, true);
    await registry.setActiveKey(NODE, KEY_V, true);
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.be.revertedWithCustomError(gate, 'PlausibilitySourceUnavailable');

    await gate
      .connect(admin)
      .configureSeams(await registry.getAddress(), await source.getAddress(), ethers.ZeroAddress);
    await source.setDefault(true, true);
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.be.revertedWithCustomError(gate, 'GeoCellRegistryUnavailable');

    await gate
      .connect(admin)
      .configureSeams(
        await registry.getAddress(),
        await source.getAddress(),
        await cellRegistry.getAddress(),
      );
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.be.revertedWithCustomError(gate, 'NodeCellUnregistered');

    // Arm the last seam and the same frame passes: each earlier failure was
    // that seam's absence, not something else.
    await cellRegistry.setCell(NODE, ethers.id('cell-A'));
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.emit(gate, 'ObservationVerified');
  });

  it('ADR RED case: an unregistered signer reverts at the seam', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter, registry } = ctx;

    await registry.setRegistered(NODE, false);
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'UnregisteredNode');

    // A registered node under a rotated-out key is equally dead.
    await registry.setRegistered(NODE, true);
    await registry.setActiveKey(NODE, KEY_V, false);
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'InactiveKey');
  });

  it('ADR RED case: a replayed buffered frame reverts on the consumed digest', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter } = ctx;

    const frame = await freshFrame();
    await gate.connect(submitter).submitObservation(frame);

    // Identical frame, replayed from an offline buffer.
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.be.revertedWithCustomError(gate, 'FrameAlreadyConsumed');

    // Same raw digest under a different schema version is a DIFFERENT
    // canonical digest (domain separation), so it is judged on its own.
    // (observedAt shifted to the next #161 bucket — it is not part of the
    // canonical digest, so the domain-separation claim is unchanged.)
    await expect(
      gate
        .connect(submitter)
        .submitObservation({ ...frame, schemaVersion: 2, observedAt: frame.observedAt - 601n })
    ).to.emit(gate, 'ObservationVerified');
  });

  it('quarantines without consuming when no verdict exists, and consumes on an implausible one', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter, source } = ctx;

    const frame = await freshFrame();
    await source.setDefault(false, false);

    // Unavailable verdict: quarantined, NOT consumed — resubmission allowed
    // once a verdict exists.
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.emit(gate, 'FrameQuarantined');
    await source.setDefault(true, true);
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.emit(gate, 'ObservationVerified');

    // Implausible verdict: consumed for good.
    const bad = await freshFrame();
    const badDigest = await gate.canonicalDigest(bad);
    await source.setVerdict(badDigest, true, false);
    await expect(gate.connect(submitter).submitObservation(bad))
      .to.emit(gate, 'FrameQuarantined');
    await source.setVerdict(badDigest, true, true);
    await expect(gate.connect(submitter).submitObservation(bad))
      .to.be.revertedWithCustomError(gate, 'FrameAlreadyConsumed');
  });

  it('RED: the production attestation quorum supplies available/pass and quarantines unavailable or negative digests', async function () {
    const ctx = await deployGate();
    const { gate, admin, submitter, registry, cellRegistry, policy } = ctx;
    const { source, attesterOne, attesterTwo } = await deployAttestationSource(admin);
    const policyHash = ethers.id('SIM-FLUID-V1-policy');

    await gate.connect(admin).configureSeams(
      await registry.getAddress(),
      await source.getAddress(),
      await cellRegistry.getAddress(),
    );
    await gate.connect(admin).setPolicy(policy);
    await registry.setRegistered(NODE, true);
    await registry.setActiveKey(NODE, KEY_V, true);
    await cellRegistry.setCell(NODE, ethers.id('cell-A'));

    const pending = await freshFrame();
    const pendingDigest = await gate.canonicalDigest(pending);
    const validUntil = BigInt((await time.latest()) + 3600);
    await source.connect(attesterOne).attest(pendingDigest, policyHash, validUntil, true);

    // One vote is not a verdict: keep the frame retryable while it is quarantined.
    await expect(gate.connect(submitter).submitObservation(pending))
      .to.emit(gate, 'FrameQuarantined')
      .withArgs(NODE, pendingDigest, false);
    expect(await gate.frameStatus(pendingDigest)).to.equal(0n);

    await source.connect(attesterTwo).attest(pendingDigest, policyHash, validUntil, true);
    await expect(gate.connect(submitter).submitObservation(pending))
      .to.emit(gate, 'ObservationVerified');

    const rejected = await freshFrame();
    const rejectedDigest = await gate.canonicalDigest(rejected);
    const rejectedUntil = BigInt((await time.latest()) + 3600);
    await source.connect(attesterOne).attest(rejectedDigest, policyHash, rejectedUntil, false);
    await source.connect(attesterTwo).attest(rejectedDigest, policyHash, rejectedUntil, false);

    await expect(gate.connect(submitter).submitObservation(rejected))
      .to.emit(gate, 'FrameQuarantined')
      .withArgs(NODE, rejectedDigest, true);
    expect(await gate.frameStatus(rejectedDigest)).to.equal(2n);
  });

  it('enforces per-node and global emission caps on the withheld ledger', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter, registry } = ctx;

    // perFrame=100, perNodeCap=250: two frames accrue, the third breaks the cap.
    await gate.connect(submitter).submitObservation(await freshFrame());
    await gate.connect(submitter).submitObservation(await freshFrame());
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'EmissionBudgetExceeded');

    // globalCap=400: a second node gets 2 more frames worth 200, then the
    // GLOBAL budget (200 already spent) refuses, even though the node budget
    // has room.
    const NODE2 = ethers.id('node-2');
    await registry.setRegistered(NODE2, true);
    await registry.setActiveKey(NODE2, KEY_V, true);
    await ctx.cellRegistry.setCell(NODE2, ethers.id('cell-B'));
    await gate.connect(submitter).submitObservation(await freshFrame({ nodeId: NODE2 }));
    await gate.connect(submitter).submitObservation(await freshFrame({ nodeId: NODE2 }));
    await expect(
      gate.connect(submitter).submitObservation(await freshFrame({ nodeId: NODE2 }))
    ).to.be.revertedWithCustomError(gate, 'EmissionBudgetExceeded');

    expect(await gate.totalWithheldAccrual()).to.equal(400n);
  });

  it('rejects frames outside clock bounds and callers outside SUBMITTER_ROLE', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter, outsider } = ctx;

    const now = BigInt((await ethers.provider.getBlock('latest')).timestamp);
    await expect(
      gate.connect(submitter).submitObservation(await freshFrame({ observedAt: now - 90000n }))
    ).to.be.revertedWithCustomError(gate, 'FrameOutOfClockBounds');
    await expect(
      gate.connect(submitter).submitObservation(await freshFrame({ observedAt: now + 900n }))
    ).to.be.revertedWithCustomError(gate, 'FrameOutOfClockBounds');

    await expect(gate.connect(outsider).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'AccessControlUnauthorizedAccount');
  });

  it('a policy edit cannot hand back the emission budget inside the same window (#220 Finding 1)', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, admin, submitter, policy } = ctx;

    // Cap the node out: 200 accrued against a 250 cap.
    await gate.connect(submitter).submitObservation(await freshFrame());
    await gate.connect(submitter).submitObservation(await freshFrame());
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'EmissionBudgetExceeded');

    // The review's measured bypass: change ONLY epochLength. On the old
    // derived-epoch head this re-keyed the counters and the frame was
    // ACCEPTED (300 against a 250 cap). Anchored, it must still revert.
    await gate.connect(admin).setPolicy({ ...policy, epochLength: 7200n });
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'EmissionBudgetExceeded');

    // Shortening cannot end the running window early either: the ACTIVE
    // length was locked at the boundary, so 61s into a 3600s window a
    // 60s policy is not yet in effect.
    await gate.connect(admin).setPolicy({ ...policy, epochLength: 60n });
    await time.increase(61);
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.be.revertedWithCustomError(gate, 'EmissionBudgetExceeded');

    // Only real elapsed time re-opens the budget: cross the ORIGINAL 3600s
    // boundary and accrual resumes (and the shorter length is adopted from
    // here on, at a boundary, as documented).
    await time.increase(3600);
    await expect(gate.connect(submitter).submitObservation(await freshFrame()))
      .to.emit(gate, 'ObservationVerified');
  });

  it('the replay key is node-scoped: two nodes may consume the same content digest (#220 Finding 2)', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter, registry } = ctx;

    const NODE2 = ethers.id('node-2');
    await registry.setRegistered(NODE2, true);
    await registry.setActiveKey(NODE2, KEY_V, true);
    await ctx.cellRegistry.setCell(NODE2, ethers.id('cell-B'));

    const shared = ethers.hexlify(ethers.randomBytes(32));
    await expect(
      gate.connect(submitter).submitObservation(await freshFrame({ frameDigest: shared }))
    ).to.emit(gate, 'ObservationVerified');
    // On the old head this reverted FrameAlreadyConsumed: node B was denied
    // forever by node A's submission of the same content digest.
    await expect(
      gate
        .connect(submitter)
        .submitObservation(await freshFrame({ frameDigest: shared, nodeId: NODE2 }))
    ).to.emit(gate, 'ObservationVerified');

    // The SAME node replaying the same digest still reverts — Finding 2's fix
    // must not weaken the ADR replay guard.
    await expect(
      gate.connect(submitter).submitObservation(await freshFrame({ frameDigest: shared }))
    ).to.be.revertedWithCustomError(gate, 'FrameAlreadyConsumed');
  });

  it('currentEpoch reverts PolicyUnset instead of panicking, and setPolicy rejects inconsistent caps', async function () {
    const ctx = await deployGate();
    const { gate, admin, policy } = ctx;

    await expect(gate.currentEpoch()).to.be.revertedWithCustomError(gate, 'PolicyUnset');

    await expect(
      gate.connect(admin).setPolicy({ ...policy, perFrameAccrual: 300n })
    ).to.be.revertedWithCustomError(gate, 'InvalidPolicy'); // perFrame > perNodeCap
    await expect(
      gate.connect(admin).setPolicy({ ...policy, perNodeEpochCap: 500n })
    ).to.be.revertedWithCustomError(gate, 'InvalidPolicy'); // perNodeCap > globalCap
  });

  it('minting is structurally disabled: constant false, and no enable surface exists', async function () {
    const ctx = await deployGate();
    await armAllSeams(ctx);
    const { gate, submitter } = ctx;

    expect(await gate.MINTING_ENABLED()).to.equal(false);

    // The verified event reports minted=false while accrual is withheld.
    const frame = await freshFrame();
    const digest = await gate.canonicalDigest(frame);
    await expect(gate.connect(submitter).submitObservation(frame))
      .to.emit(gate, 'ObservationVerified')
      .withArgs(NODE, digest, 100n, false);

    // No TRANSACTION on the ABI can flip it: no state-mutating function is
    // named like an enable/mint switch. (Views are exempt — MINTING_ENABLED's
    // own getter is one.) This is an ABI-shape assertion, so a future PR that
    // adds a supply surface has to consciously delete this line in review.
    const fragments = gate.interface.fragments
      .filter((f) => f.type === 'function' && !['view', 'pure'].includes(f.stateMutability))
      .map((f) => f.name.toLowerCase());
    for (const name of fragments) {
      expect(name.includes('mint') || name.includes('enable'), `unexpected supply surface: ${name}`)
        .to.equal(false);
    }
  });
});
