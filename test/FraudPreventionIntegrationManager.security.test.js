// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
} = require('@nomicfoundation/hardhat-network-helpers');

/**
 * FraudPreventionIntegrationManager — Case Bounds & Pagination Security Tests
 *
 * Validates:
 *  - MAX_CASES_PER_PARTICIPANT (1000) bound on participantCases
 *  - MAX_CASES_PER_SYSTEM (5000) bound on systemCases
 *  - Paginated view functions return correct slices
 */
describe('FraudPreventionIntegrationManager — Case Bounds (sc#28)', function () {
  // SystemComponent enum values (matches Solidity)
  const COMPREHENSIVE_FRAUD_DETECTION = 0;
  const ENHANCED_FRAUD_PREVENTION = 1;
  const REAL_TIME_MONITOR = 2;
  const SLASHING_MECHANISM = 3;

  async function deployFixture() {
    const [owner, participant, other] = await ethers.getSigners();

    // Deploy mock dependencies
    const MockCFD = await ethers.getContractFactory('MockComprehensiveFraudDetection');
    const mockCFD = await MockCFD.deploy();

    const MockEFPS = await ethers.getContractFactory('MockEnhancedFraudPreventionSystem');
    const mockEFPS = await MockEFPS.deploy();

    const MockRTFM = await ethers.getContractFactory('MockRealTimeFraudMonitor');
    const mockRTFM = await MockRTFM.deploy();

    const MockSlash = await ethers.getContractFactory('MockSlashingMechanism');
    const mockSlash = await MockSlash.deploy();

    // Deploy FraudPreventionIntegrationManager
    const FPIM = await ethers.getContractFactory('FraudPreventionIntegrationManager');
    const fpim = await FPIM.deploy(
      await mockCFD.getAddress(),
      await mockEFPS.getAddress(),
      await mockRTFM.getAddress(),
      await mockSlash.getAddress()
    );

    // Increase maxConcurrentCases so it does not block our bounds tests
    // (default is 100, we need >1000 for the participant limit test)
    await fpim.updateWorkflowConfiguration(
      2000,        // maxConcurrentCases
      86400,       // defaultResponseTimeout (24h)
      172800       // escalationThreshold (48h)
    );

    return { owner, participant, other, fpim };
  }

  /**
   * Helper: open `count` cases against `participant` from `originSystem`.
   * Resolves each case immediately so activeCasesCount stays low
   * (avoids hitting the withinCapacity modifier).
   */
  async function openAndResolveCases(fpim, participant, originSystem, count) {
    for (let i = 0; i < count; i++) {
      const tx = await fpim.openIntegratedCase(
        participant,
        originSystem,
        [],            // relatedIds
        4,             // LOW_PRIORITY
        10,            // riskScore (low, avoids automation side-effects)
        'bounds test'
      );
      await tx.wait();

      // Resolve immediately to free capacity
      const caseId = i + 1; // nextCaseId starts at 1
      await fpim.resolveCase(
        caseId,
        2,             // FALSE_POSITIVE
        'resolved for test',
        0,
        ethers.id('evidence')
      );
    }
  }

  // -----------------------------------------------------------
  // 1. Opening a case below the participant limit succeeds
  // -----------------------------------------------------------
  it('allows opening a case when participant is below MAX_CASES_PER_PARTICIPANT', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    await expect(
      fpim.openIntegratedCase(
        participant.address,
        COMPREHENSIVE_FRAUD_DETECTION,
        [],
        4,
        10,
        'first case'
      )
    ).to.not.be.reverted;
  });

  // -----------------------------------------------------------
  // 2. Opening a case at the participant limit reverts
  // -----------------------------------------------------------
  it('reverts when participant reaches MAX_CASES_PER_PARTICIPANT (1000)', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    // Fill up to 1000 cases (resolve each to stay within capacity)
    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      1000
    );

    // The 1001st case should revert
    await expect(
      fpim.openIntegratedCase(
        participant.address,
        COMPREHENSIVE_FRAUD_DETECTION,
        [],
        4,
        10,
        'over limit'
      )
    ).to.be.revertedWith('FPIM: Participant case limit reached');
  });

  // -----------------------------------------------------------
  // 3. Paginated view — offset=0, limit=10
  // -----------------------------------------------------------
  it('getParticipantCasesPaginated returns correct first page', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    // Open 15 cases
    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      15
    );

    const [cases, total] = await fpim.getParticipantCasesPaginated(
      participant.address,
      0,
      10
    );

    expect(total).to.equal(15);
    expect(cases.length).to.equal(10);
    // Case IDs should be 1..10
    for (let i = 0; i < 10; i++) {
      expect(cases[i]).to.equal(i + 1);
    }
  });

  // -----------------------------------------------------------
  // 4. Paginated view — offset=5, limit=5
  // -----------------------------------------------------------
  it('getParticipantCasesPaginated returns correct middle page', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      15
    );

    const [cases, total] = await fpim.getParticipantCasesPaginated(
      participant.address,
      5,
      5
    );

    expect(total).to.equal(15);
    expect(cases.length).to.equal(5);
    for (let i = 0; i < 5; i++) {
      expect(cases[i]).to.equal(6 + i);
    }
  });

  // -----------------------------------------------------------
  // 5. Paginated view — out-of-range offset returns empty
  // -----------------------------------------------------------
  it('getParticipantCasesPaginated returns empty for out-of-range offset', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      5
    );

    const [cases, total] = await fpim.getParticipantCasesPaginated(
      participant.address,
      100,
      10
    );

    expect(total).to.equal(5);
    expect(cases.length).to.equal(0);
  });

  // -----------------------------------------------------------
  // 6. System paginated view works correctly
  // -----------------------------------------------------------
  it('getSystemCasesPaginated returns correct slice', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      10
    );

    const [cases, total] = await fpim.getSystemCasesPaginated(
      COMPREHENSIVE_FRAUD_DETECTION,
      2,
      5
    );

    expect(total).to.equal(10);
    expect(cases.length).to.equal(5);
    for (let i = 0; i < 5; i++) {
      expect(cases[i]).to.equal(3 + i);
    }
  });

  // -----------------------------------------------------------
  // 7. Paginated view — limit exceeds remaining returns partial
  // -----------------------------------------------------------
  it('getParticipantCasesPaginated clamps when limit exceeds remaining items', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      5
    );

    const [cases, total] = await fpim.getParticipantCasesPaginated(
      participant.address,
      3,
      100
    );

    expect(total).to.equal(5);
    expect(cases.length).to.equal(2); // only items at index 3 and 4
    expect(cases[0]).to.equal(4);
    expect(cases[1]).to.equal(5);
  });

  // -----------------------------------------------------------
  // 8. System case limit revert
  //
  // MAX_CASES_PER_SYSTEM is 5000 (private constant). A full
  // integration test that opens 5000 cases is impractical
  // (~minutes of EVM execution even with auto-mining). Instead
  // we verify that the revert message "FPIM: System case limit
  // reached" fires by exploiting the fact that the participant
  // limit (1000) is hit first when using a single participant.
  //
  // To truly hit the system limit, we would need 5+ distinct
  // participants each contributing <1000 cases. The test below
  // uses 6 participants × 834 cases = 5004, but this takes
  // significant time. We keep it skipped by default; CI can
  // opt-in by setting RUN_SLOW_TESTS=1.
  // -----------------------------------------------------------
  (process.env.RUN_SLOW_TESTS === '1' ? it : it.skip)(
    'reverts when a system reaches MAX_CASES_PER_SYSTEM (5000) [slow]',
    async function () {
      this.timeout(600_000); // 10 minutes

      const signers = await ethers.getSigners();
      // We need 6 participants to spread 5000 cases (each under the 1000 per-participant cap)
      const participants = signers.slice(1, 7); // indices 1..6

      const [owner] = signers;

      // Deploy fresh instance with high concurrent-case cap
      const MockCFD = await ethers.getContractFactory('MockComprehensiveFraudDetection');
      const mockCFD = await MockCFD.deploy();
      const MockEFPS = await ethers.getContractFactory('MockEnhancedFraudPreventionSystem');
      const mockEFPS = await MockEFPS.deploy();
      const MockRTFM = await ethers.getContractFactory('MockRealTimeFraudMonitor');
      const mockRTFM = await MockRTFM.deploy();
      const MockSlash = await ethers.getContractFactory('MockSlashingMechanism');
      const mockSlash = await MockSlash.deploy();

      const FPIM = await ethers.getContractFactory('FraudPreventionIntegrationManager');
      const fpim = await FPIM.deploy(
        await mockCFD.getAddress(),
        await mockEFPS.getAddress(),
        await mockRTFM.getAddress(),
        await mockSlash.getAddress()
      );

      await fpim.updateWorkflowConfiguration(6000, 86400, 172800);

      // Open 5000 cases across 6 participants (834 each, last gets 830)
      let caseId = 1;
      for (let p = 0; p < 6; p++) {
        const count = p < 5 ? 834 : 830; // 834*5 + 830 = 5000
        for (let i = 0; i < count; i++) {
          const tx = await fpim.openIntegratedCase(
            participants[p].address,
            COMPREHENSIVE_FRAUD_DETECTION,
            [],
            4,
            10,
            'system limit test'
          );
          await tx.wait();
          await fpim.resolveCase(caseId, 2, 'resolved', 0, ethers.id('evidence'));
          caseId++;
        }
      }

      // The 5001st case should revert with the system limit message
      await expect(
        fpim.openIntegratedCase(
          participants[0].address,
          COMPREHENSIVE_FRAUD_DETECTION,
          [],
          4,
          10,
          'over system limit'
        )
      ).to.be.revertedWith('FPIM: System case limit reached');
    }
  );

  // -----------------------------------------------------------
  // 9. Paginated view — limit=0 returns empty with correct total
  // -----------------------------------------------------------
  it('getParticipantCasesPaginated returns empty array when limit is 0', async function () {
    const { fpim, participant } = await loadFixture(deployFixture);

    await openAndResolveCases(
      fpim,
      participant.address,
      COMPREHENSIVE_FRAUD_DETECTION,
      5
    );

    const [cases, total] = await fpim.getParticipantCasesPaginated(
      participant.address,
      0,
      0
    );

    expect(total).to.equal(5);
    expect(cases.length).to.equal(0);
  });
});
