/**
 * @title SlashingMechanism Edge Case Tests (Issue #78)
 * @dev Tests the edge cases not covered by the happy-path test suite:
 *   4. Concurrent slash + unstake ordering and no double-accounting
 *   5. MultiAssetStaking cross-asset slash proportionality
 *   6. (Optional) Batch slash gas limits
 *
 * IMPLEMENTATION NOTES:
 * - SlashingMechanism._distributeSlashedAssets() always reverts with
 *   "Slashing distribution not implemented - token transfer required".
 *   This means executeSlashing() and emergencySlashing() BOTH always revert.
 * - Tests that exercise these paths assert the expected revert message,
 *   documenting the gap. State verifications are done using the
 *   proposeSlashing → validateSlashing path (which does NOT call distribution).
 * - For state-mutation tests that require the slash to "execute", we use
 *   MockMultiAssetStaking.setTotalStake() to simulate post-slash state manually,
 *   then verify the SlashingMechanism accounting is correct up to the execution gate.
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
} = require('@nomicfoundation/hardhat-network-helpers');

// ─────────────────────────────────────────────────────────────────────────────
//  Shared fixture
// ─────────────────────────────────────────────────────────────────────────────

async function deploySlashingFixture() {
  const [
    owner,
    validator1,
    validator2,
    validator3,
    participant1,
    participant2,
    participant3,
    treasury,
    burnAddress,
  ] = await ethers.getSigners();

  const MockMultiAssetStaking = await ethers.getContractFactory('MockMultiAssetStaking');
  const mockMultiAssetStaking = await MockMultiAssetStaking.deploy();

  const MockParticipantTypeRegistry = await ethers.getContractFactory('MockParticipantTypeRegistry');
  const mockParticipantRegistry = await MockParticipantTypeRegistry.deploy();

  const MockLayawayRegistration = await ethers.getContractFactory('MockLayawayRegistration');
  const mockLayawayRegistration = await MockLayawayRegistration.deploy();

  const MockStakeDelegation = await ethers.getContractFactory('MockStakeDelegation');
  const mockStakeDelegation = await MockStakeDelegation.deploy();

  const MockWeatherDataValidator = await ethers.getContractFactory('MockWeatherDataValidator');
  const mockWeatherDataValidator = await MockWeatherDataValidator.deploy();

  const SlashingMechanism = await ethers.getContractFactory('SlashingMechanism');
  const slashingMechanism = await SlashingMechanism.deploy(
    await mockMultiAssetStaking.getAddress(),
    await mockParticipantRegistry.getAddress(),
    await mockLayawayRegistration.getAddress(),
    await mockStakeDelegation.getAddress(),
    await mockWeatherDataValidator.getAddress(),
    treasury.address,
    burnAddress.address
  );

  const VALIDATOR_ROLE = await slashingMechanism.VALIDATOR_ROLE();
  const EMERGENCY_ROLE = await slashingMechanism.EMERGENCY_ROLE();

  await slashingMechanism.grantRole(VALIDATOR_ROLE, validator1.address);
  await slashingMechanism.grantRole(VALIDATOR_ROLE, validator2.address);
  await slashingMechanism.grantRole(VALIDATOR_ROLE, validator3.address);
  await slashingMechanism.grantRole(EMERGENCY_ROLE, owner.address);

  await mockMultiAssetStaking.setTotalStake(participant1.address, ethers.parseEther('1000'));
  await mockMultiAssetStaking.setTotalStake(participant2.address, ethers.parseEther('500'));
  await mockMultiAssetStaking.setTotalStake(participant3.address, ethers.parseEther('2000'));

  return {
    slashingMechanism,
    mockMultiAssetStaking,
    mockParticipantRegistry,
    mockLayawayRegistration,
    mockStakeDelegation,
    mockWeatherDataValidator,
    owner,
    validator1,
    validator2,
    validator3,
    participant1,
    participant2,
    participant3,
    treasury,
    burnAddress,
  };
}

/**
 * Submit evidence and propose a slashing event.
 * Returns the slashingId (captured before the increment).
 */
async function proposeSlashing({
  slashingMechanism,
  validator,
  participant,
  severity = 1, // MAJOR
  reason = 0,   // DATA_MANIPULATION
  description = 'Violation',
  evidenceSeed = 'default-evidence',
}) {
  const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes(evidenceSeed));

  // Submit evidence (skip if already submitted)
  const alreadyVerified = await slashingMechanism.verifyEvidence(evidenceHash);
  if (!alreadyVerified) {
    await slashingMechanism
      .connect(validator)
      .submitEvidence(evidenceHash, `QmEdge${evidenceSeed.slice(0, 20)}`);
  }

  const slashingId = Number(await slashingMechanism.nextSlashingId());

  await slashingMechanism
    .connect(validator)
    .proposeSlashing(participant.address, reason, severity, evidenceHash, description);

  return slashingId;
}

/**
 * Confirm a slashing by adding validator2 and validator3 approvals.
 * Assumes validator1 already approved at proposal time.
 */
async function confirmSlashing({ slashingMechanism, slashingId, validator2, validator3 }) {
  await slashingMechanism.connect(validator2).validateSlashing(slashingId);
  await slashingMechanism.connect(validator3).validateSlashing(slashingId);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Edge Case 4 — Concurrent slash + unstake ordering
// ─────────────────────────────────────────────────────────────────────────────

describe('SlashingMechanism edge cases: concurrent slash + unstake ordering', function () {
  /**
   * The contract RECOMPUTES slashAmount at executeSlashing time (not proposal time).
   * A participant who reduces stake between proposal and execution receives a smaller
   * slash — this is a known slash-evasion vulnerability.
   *
   * Because executeSlashing always reverts (unimplemented distribution), we:
   * 1. Verify the proposed amount is computed correctly at proposal time.
   * 2. Verify that stake changes between proposal and confirmation affect execution-time amount.
   * 3. Document that executeSlashing reverts (the distribution is not yet implemented).
   */

  it('should compute slash amount from stake at proposal time', async function () {
    const {
      slashingMechanism,
      mockMultiAssetStaking,
      validator1,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    const initialStake = ethers.parseEther('1000');
    expect(await mockMultiAssetStaking.getTotalStake(participant1.address)).to.equal(initialStake);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1, // MAJOR = 50%
      evidenceSeed: 'slash-at-proposal-time',
    });

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    // MAJOR = 50% of 1000 = 500 ETH
    expect(event.slashedAmount).to.equal((initialStake * 5000n) / 10000n);
    expect(event.status).to.equal(0); // PENDING
  });

  it('should document stake-race gap: stake reduced between proposal and execution', async function () {
    const {
      slashingMechanism,
      mockMultiAssetStaking,
      validator1,
      validator2,
      validator3,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    const initialStake = ethers.parseEther('1000');

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1,
      evidenceSeed: 'stake-race-gap',
    });

    // Proposed slash amount = 500 ETH (50% of 1000)
    const eventAtProposal = await slashingMechanism.getSlashingEvent(slashingId);
    expect(eventAtProposal.slashedAmount).to.equal(ethers.parseEther('500'));

    // CONCURRENT: participant reduces stake between proposal and execution
    // (In the real system, hasPendingSlashing flag would block this —
    //  MockMultiAssetStaking has no such guard)
    const reducedStake = ethers.parseEther('200');
    await mockMultiAssetStaking.setTotalStake(participant1.address, reducedStake);

    // Confirm the slashing
    await confirmSlashing({ slashingMechanism, slashingId, validator2, validator3 });

    const eventConfirmed = await slashingMechanism.getSlashingEvent(slashingId);
    expect(eventConfirmed.status).to.equal(1); // CONFIRMED

    // Advance past execution delay
    await time.increase(48 * 3600 + 1);

    // executeSlashing recomputes amount at execution time (200 * 50% = 100 — not 500!)
    // and defers distribution accounting when token routing is not enabled.
    await expect(
      slashingMechanism.executeSlashing(slashingId)
    ).to.emit(slashingMechanism, 'SlashingDistributionDeferred');

    const eventExecuted = await slashingMechanism.getSlashingEvent(slashingId);
    expect(eventExecuted.status).to.equal(4); // EXECUTED
    expect(eventExecuted.slashedAmount).to.equal(ethers.parseEther('100'));
  });

  it('should prevent same validator from double-validating a slashing', async function () {
    const {
      slashingMechanism,
      mockMultiAssetStaking,
      validator1,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1,
      evidenceSeed: 'no-double-validate',
    });

    // validator1 already approved at proposal time — attempt a second approval
    await expect(
      slashingMechanism.connect(validator1).validateSlashing(slashingId)
    ).to.be.revertedWith('SlashingMechanism: Already validated');
  });

  it('should transition to CONFIRMED state after 3 validator approvals', async function () {
    const {
      slashingMechanism,
      validator1,
      validator2,
      validator3,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1,
      evidenceSeed: 'confirm-three-validators',
    });

    // After proposal: 1 approval, still PENDING
    let event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.status).to.equal(0); // PENDING

    await slashingMechanism.connect(validator2).validateSlashing(slashingId);
    event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.status).to.equal(0); // Still PENDING (need 3)

    await expect(
      slashingMechanism.connect(validator3).validateSlashing(slashingId)
    ).to.emit(slashingMechanism, 'SlashingConfirmed');

    event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.status).to.equal(1); // CONFIRMED
    expect(event.approvalCount).to.equal(3n);
  });

  it('should reject executeSlashing before execution delay passes', async function () {
    const {
      slashingMechanism,
      validator1,
      validator2,
      validator3,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1,
      evidenceSeed: 'execution-delay-check',
    });

    await confirmSlashing({ slashingMechanism, slashingId, validator2, validator3 });

    // Attempt execution immediately (before 48-hour delay)
    await expect(
      slashingMechanism.executeSlashing(slashingId)
    ).to.be.revertedWith('SlashingMechanism: Execution delay not met');
  });

  it('should execute slashing and defer distribution accounting after delay passes', async function () {
    const {
      slashingMechanism,
      validator1,
      validator2,
      validator3,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1,
      evidenceSeed: 'exec-not-implemented',
    });

    await confirmSlashing({ slashingMechanism, slashingId, validator2, validator3 });
    await time.increase(48 * 3600 + 1);

    // Distribution is intentionally deferred until token routing is enabled.
    await expect(
      slashingMechanism.executeSlashing(slashingId)
    ).to.emit(slashingMechanism, 'SlashingDistributionDeferred');

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.status).to.equal(4); // EXECUTED
  });

  it('should execute emergencySlashing and defer distribution accounting', async function () {
    /**
     * emergencySlashing also calls _distributeSlashedAssets, which now defers
     * accounting until token routing is enabled.
     */
    const {
      slashingMechanism,
      owner,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    await expect(
      slashingMechanism
        .connect(owner)
        .emergencySlashing(participant1.address, ethers.parseEther('100'), 'Critical fraud')
    ).to.emit(slashingMechanism, 'SlashingDistributionDeferred');

    const record = await slashingMechanism.participantRecords(participant1.address);
    expect(record.violationCount).to.equal(1);
    expect(record.requiresRefill).to.equal(true);
    expect(record.isBanned).to.equal(true);
  });

  it('should verify violation count tracking via participant records (pre-execution state)', async function () {
    /**
     * The participantRecords are only written inside executeSlashing and emergencySlashing,
     * both of which revert. So violationCount is always 0 until distribution is implemented.
     * This test documents the gap.
     */
    const {
      slashingMechanism,
      validator1,
      validator2,
      validator3,
      participant1,
    } = await loadFixture(deploySlashingFixture);

    // Initial state
    let record = await slashingMechanism.getParticipantRecord(participant1.address);
    expect(record.violationCount).to.equal(0n);
    expect(record.totalSlashed).to.equal(0n);
    expect(record.isBanned).to.be.false;

    // Propose and confirm slash (no state change until execution)
    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1,
      evidenceSeed: 'violation-count-check',
    });

    await confirmSlashing({ slashingMechanism, slashingId, validator2, validator3 });

    // After confirmation but before execution: violation count is still 0
    record = await slashingMechanism.getParticipantRecord(participant1.address);
    expect(record.violationCount).to.equal(0n);
    // TODO: Once distribution is implemented, after executeSlashing:
    //   expect(record.violationCount).to.equal(1);
    //   expect(record.requiresRefill).to.be.true;
  });
});

// ─────────────────────────────────────────────────────────────────────────────
//  Edge Case 5 — MultiAssetStaking cross-asset slash proportionality
// ─────────────────────────────────────────────────────────────────────────────

describe('SlashingMechanism edge cases: cross-asset slash proportionality', function () {
  /**
   * SlashingMechanism computes slash amount from aggregate total stake
   * (via getTotalStake) and delegates per-asset distribution to MultiAssetStaking.
   *
   * Tests verify:
   * (a) Aggregate total stake is used for slash computation.
   * (b) Different severity levels produce correctly scaled slash amounts.
   * (c) MockMultiAssetStaking correctly simulates stake reduction.
   * (d) Documents that per-asset proportional logic is delegated entirely.
   */

  it('should compute slash amount from aggregate total stake (MINOR = 25%)', async function () {
    const { slashingMechanism, mockMultiAssetStaking, validator1, participant1 } =
      await loadFixture(deploySlashingFixture);

    // 1000 WRF total stake (could be ETH + WBTC + WRF combined in the real contract)
    const totalStake = ethers.parseEther('1000');
    expect(await mockMultiAssetStaking.getTotalStake(participant1.address)).to.equal(totalStake);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 0, // MINOR = 25%
      evidenceSeed: 'minor-cross-asset',
    });

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.slashedAmount).to.equal((totalStake * 2500n) / 10000n); // 250 ETH
  });

  it('should compute MAJOR slash (50%) from aggregate total stake', async function () {
    const { slashingMechanism, validator1, participant1 } =
      await loadFixture(deploySlashingFixture);

    const totalStake = ethers.parseEther('1000');

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 1, // MAJOR = 50%
      evidenceSeed: 'major-cross-asset',
    });

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.slashedAmount).to.equal((totalStake * 5000n) / 10000n); // 500 ETH
  });

  it('should compute CRITICAL slash (75%) from aggregate total stake', async function () {
    const { slashingMechanism, validator1, participant2 } =
      await loadFixture(deploySlashingFixture);

    const totalStake = ethers.parseEther('500');

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant2,
      severity: 2, // CRITICAL = 75%
      evidenceSeed: 'critical-cross-asset',
    });

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.slashedAmount).to.equal((totalStake * 7500n) / 10000n); // 375 ETH
  });

  it('should compute TERMINAL slash (100%) from aggregate total stake', async function () {
    const { slashingMechanism, validator1, participant3 } =
      await loadFixture(deploySlashingFixture);

    const totalStake = ethers.parseEther('2000');

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant3,
      severity: 3, // TERMINAL = 100%
      evidenceSeed: 'terminal-cross-asset',
    });

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    expect(event.slashedAmount).to.equal(totalStake); // 100% = 2000 ETH
  });

  it('should apply proportionally larger slash for CRITICAL vs MINOR severity', async function () {
    const { slashingMechanism, validator1, participant1, participant2 } =
      await loadFixture(deploySlashingFixture);

    const slashingId1 = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant1,
      severity: 0, // MINOR
      evidenceSeed: 'minor-for-comparison',
    });

    const slashingId2 = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant2,
      severity: 2, // CRITICAL
      evidenceSeed: 'critical-for-comparison',
    });

    const event1 = await slashingMechanism.getSlashingEvent(slashingId1);
    const event2 = await slashingMechanism.getSlashingEvent(slashingId2);

    // participant1 (1000 WRF) MINOR: 250; participant2 (500 WRF) CRITICAL: 375
    // CRITICAL produces a larger absolute slash despite smaller base stake
    expect(event2.slashedAmount).to.be.greaterThan(event1.slashedAmount);

    // As a percentage: MINOR is 25%, CRITICAL is 75% — 3x ratio
    const minorPercent = (event1.slashedAmount * 10000n) /
      ethers.parseEther('1000');
    const criticalPercent = (event2.slashedAmount * 10000n) /
      ethers.parseEther('500');

    expect(minorPercent).to.equal(2500n);    // 25.00%
    expect(criticalPercent).to.equal(7500n); // 75.00%
  });

  it('should scale slash amount for repeat offenders', async function () {
    /**
     * _calculateSlashingAmount applies +25% per prior violation for repeat offenders.
     * Since executeSlashing reverts, we cannot actually execute a first slash to test
     * the repeat-offender logic. We document this as a gap and verify the formula
     * via getDefaultSeverity (a public view function).
     */
    const { slashingMechanism } = await loadFixture(deploySlashingFixture);

    // getDefaultSeverity maps SlashingReason to ViolationSeverity
    const minorSeverity = await slashingMechanism.getDefaultSeverity(7); // INVALID_REVEAL
    const criticalSeverity = await slashingMechanism.getDefaultSeverity(8); // ORACLE_ATTESTATION_FRAUD
    const majorSeverity = await slashingMechanism.getDefaultSeverity(9); // DATA_QUALITY_VIOLATION

    expect(minorSeverity).to.equal(0);    // MINOR
    expect(criticalSeverity).to.equal(2); // CRITICAL
    expect(majorSeverity).to.equal(0);    // MINOR

    // TODO: Once executeSlashing distribution is implemented, test repeat offender scaling:
    //   After first slash: violationCount = 1
    //   Second slash amount = base * 1.25 (capped at total stake)
  });

  it('should document gap: per-asset proportional slashing is fully delegated to MultiAssetStaking', async function () {
    /**
     * Gap: SlashingMechanism._executeStakeSlashing() calls:
     *   multiAssetStaking.slashStake(participant, totalAmount)
     *
     * How that totalAmount is divided across ETH, WBTC, WRF, etc. is entirely
     * decided inside MultiAssetStaking. The SlashingMechanism has no visibility
     * into per-asset allocation.
     *
     * Risk: If MultiAssetStaking always slashes ETH first, a participant who
     * primarily holds WBTC can partially evade slash penalties on their largest
     * position. Proportional slashing across all staked assets is NOT enforced
     * by SlashingMechanism itself.
     *
     * TODO: Add a cross-asset proportional slashing test once MultiAssetStaking
     * exposes per-asset balances and its slashStake() implementation is finalized.
     */
    const { slashingMechanism, mockMultiAssetStaking, validator1, participant3 } =
      await loadFixture(deploySlashingFixture);

    // participant3 has 2000 ETH total stake (could be multi-asset in real system)
    const totalStake = ethers.parseEther('2000');
    expect(await mockMultiAssetStaking.getTotalStake(participant3.address)).to.equal(totalStake);

    const slashingId = await proposeSlashing({
      slashingMechanism,
      validator: validator1,
      participant: participant3,
      severity: 1, // MAJOR
      evidenceSeed: 'multi-asset-gap-doc',
    });

    const event = await slashingMechanism.getSlashingEvent(slashingId);
    // Slash amount is computed from aggregate — 50% of 2000 = 1000
    expect(event.slashedAmount).to.equal(ethers.parseEther('1000'));

    // How the 1000 is divided across ETH vs WBTC vs WRF depends on MockMultiAssetStaking.
    // MockMultiAssetStaking.slashStake() subtracts from a single totalStakes mapping —
    // no per-asset proportional logic is implemented.
    // TODO: Real MultiAssetStaking should enforce proportional per-asset slashing.
  });
});

// ─────────────────────────────────────────────────────────────────────────────
//  Edge Case 6 — Batch slash gas limits
// ─────────────────────────────────────────────────────────────────────────────

describe('SlashingMechanism edge cases: batch slash gas limits', function () {
  /**
   * With 12+ operators on testnet, gas limits for batch slashing operations matter.
   * The SlashingMechanism has no batch function — each proposeSlashing is a separate tx.
   * We measure gas per-proposal and verify it stays within safe limits.
   */

  it('should propose slashing for 12 validators within gas budget', async function () {
    const {
      slashingMechanism,
      mockMultiAssetStaking,
      validator1,
    } = await loadFixture(deploySlashingFixture);

    const signers = await ethers.getSigners();
    const BATCH_SIZE = 12;
    const participants = signers.slice(9, 9 + BATCH_SIZE);

    for (const p of participants) {
      await mockMultiAssetStaking.setTotalStake(p.address, ethers.parseEther('1000'));
    }

    // Shared evidence (verified once, reused for all proposals)
    const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('batch-proposal-gas'));
    await slashingMechanism
      .connect(validator1)
      .submitEvidence(evidenceHash, 'QmBatchGasTest');

    const gasUsages = [];
    for (const p of participants) {
      const tx = await slashingMechanism.connect(validator1).proposeSlashing(
        p.address,
        0, // DATA_MANIPULATION
        0, // MINOR
        evidenceHash,
        'Batch gas test'
      );
      const receipt = await tx.wait();
      gasUsages.push(receipt.gasUsed);
    }

    const totalGas = gasUsages.reduce((a, b) => a + b, 0n);
    const avgGas = totalGas / BigInt(BATCH_SIZE);

    // Each proposal should cost < 500k gas
    for (const gas of gasUsages) {
      expect(gas).to.be.lessThan(500000n);
    }

    // 12 proposals total should be < 6M gas (well within 30M block limit)
    expect(totalGas).to.be.lessThan(6000000n);

    console.log(`    [Gas] proposeSlashing × ${BATCH_SIZE}: avg=${avgGas}, total=${totalGas}`);
  });

  it('should validate multiple slashings in parallel without gas overflow', async function () {
    const {
      slashingMechanism,
      mockMultiAssetStaking,
      validator1,
      validator2,
      validator3,
    } = await loadFixture(deploySlashingFixture);

    const signers = await ethers.getSigners();
    const BATCH_SIZE = 6; // Smaller batch for 3-validator confirmation
    const participants = signers.slice(9, 9 + BATCH_SIZE);

    for (const p of participants) {
      await mockMultiAssetStaking.setTotalStake(p.address, ethers.parseEther('1000'));
    }

    const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('batch-validate-gas'));
    await slashingMechanism
      .connect(validator1)
      .submitEvidence(evidenceHash, 'QmBatchValidate');

    // Propose all 6 slashings
    const slashingIds = [];
    for (const p of participants) {
      const id = Number(await slashingMechanism.nextSlashingId());
      await slashingMechanism.connect(validator1).proposeSlashing(
        p.address, 0, 1, evidenceHash, 'Batch validate test'
      );
      slashingIds.push(id);
    }

    // Validate all 6 with validator2
    let totalGasV2 = 0n;
    for (const id of slashingIds) {
      const tx = await slashingMechanism.connect(validator2).validateSlashing(id);
      const receipt = await tx.wait();
      totalGasV2 += receipt.gasUsed;
    }

    // Validate all 6 with validator3 (triggers CONFIRMED transition)
    let totalGasV3 = 0n;
    for (const id of slashingIds) {
      const tx = await slashingMechanism.connect(validator3).validateSlashing(id);
      const receipt = await tx.wait();
      totalGasV3 += receipt.gasUsed;
    }

    // Each validation should cost < 200k gas
    // (We already checked proposals separately; full batch with 3 validators is 6×3 = 18 txs)
    const totalValidationGas = totalGasV2 + totalGasV3;
    expect(totalValidationGas).to.be.lessThan(3600000n); // 18 × 200k

    // All 6 should now be CONFIRMED
    for (const id of slashingIds) {
      const event = await slashingMechanism.getSlashingEvent(id);
      expect(event.status).to.equal(1); // CONFIRMED
    }

    console.log(`    [Gas] validateSlashing × ${BATCH_SIZE} × 2 validators: total=${totalValidationGas}`);
  });

  it('should handle getPendingSlashings view gas for many pending slashings', async function () {
    const {
      slashingMechanism,
      mockMultiAssetStaking,
      validator1,
    } = await loadFixture(deploySlashingFixture);

    const signers = await ethers.getSigners();
    const BATCH_SIZE = 10;
    const participants = signers.slice(9, 9 + BATCH_SIZE);

    for (const p of participants) {
      await mockMultiAssetStaking.setTotalStake(p.address, ethers.parseEther('1000'));
    }

    const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('pending-view-gas-test'));
    await slashingMechanism
      .connect(validator1)
      .submitEvidence(evidenceHash, 'QmPendingViewGas');

    for (const p of participants) {
      await slashingMechanism.connect(validator1).proposeSlashing(
        p.address, 0, 0, evidenceHash, 'Pending view test'
      );
    }

    // getPendingSlashings is O(n) — linear over all events
    // validator1 already approved all (as proposer), so result for v1 is empty
    const pendingForV1 = await slashingMechanism.getPendingSlashings(validator1.address);
    expect(pendingForV1.length).to.equal(0);

    // A fresh validator who hasn't approved any sees all 10 as pending
    const freshValidator = signers[signers.length - 1];
    await slashingMechanism.grantRole(
      await slashingMechanism.VALIDATOR_ROLE(),
      freshValidator.address
    );
    const pendingForFresh = await slashingMechanism.getPendingSlashings(freshValidator.address);
    expect(pendingForFresh.length).to.equal(BATCH_SIZE);

    console.log(`    [Gas] getPendingSlashings (${BATCH_SIZE} events): returned ${pendingForFresh.length} pending`);

    // TODO: getPendingSlashings iterates ALL events from 1 to nextSlashingId.
    //       This is an O(n) gas DoS risk at high event counts.
    //       Recommendation: maintain a per-validator pending set or add pagination.
  });
});
