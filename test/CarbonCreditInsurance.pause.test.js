// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
} = require('@nomicfoundation/hardhat-network-helpers');

/**
 * CarbonCreditInsurance — M-of-N Multisig Pause Tests (sc#34)
 *
 * Validates that emergency pause/unpause requires approval from
 * PAUSE_THRESHOLD (2) guardians before executing, eliminating
 * the single-EOA point of failure.
 */
describe('CarbonCreditInsurance — Multisig Pause (sc#34)', function () {
  async function deployFixture() {
    const [owner, guardian1, guardian2, guardian3, nonGuardian] =
      await ethers.getSigners();

    // Deploy WRFToken
    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();

    // Deploy EnhancedCarbonCredits
    const EnhancedCarbonCredits = await ethers.getContractFactory(
      'EnhancedCarbonCredits'
    );
    const carbonCredits = await EnhancedCarbonCredits.deploy(
      await wrfToken.getAddress()
    );

    // Deploy mock oracles
    const MockQualityOracle = await ethers.getContractFactory(
      'MockQualityOracleConcrete'
    );
    const qualityOracle = await MockQualityOracle.deploy();

    const MockVolatilityOracle = await ethers.getContractFactory(
      'MockVolatilityOracleConcrete'
    );
    const volatilityOracle = await MockVolatilityOracle.deploy();

    // Deploy CarbonCreditInsurance
    const CarbonCreditInsurance = await ethers.getContractFactory(
      'CarbonCreditInsurance'
    );
    const insurance = await CarbonCreditInsurance.deploy(
      await carbonCredits.getAddress(),
      await wrfToken.getAddress(),
      await qualityOracle.getAddress(),
      await volatilityOracle.getAddress()
    );

    // Grant PAUSE_GUARDIAN_ROLE to guardian1, guardian2, guardian3
    const PAUSE_GUARDIAN_ROLE = await insurance.PAUSE_GUARDIAN_ROLE();
    await insurance.grantRole(PAUSE_GUARDIAN_ROLE, guardian1.address);
    await insurance.grantRole(PAUSE_GUARDIAN_ROLE, guardian2.address);
    await insurance.grantRole(PAUSE_GUARDIAN_ROLE, guardian3.address);

    return {
      owner,
      guardian1,
      guardian2,
      guardian3,
      nonGuardian,
      insurance,
      PAUSE_GUARDIAN_ROLE,
    };
  }

  describe('requestPause', function () {
    it('single guardian cannot pause alone (below threshold)', async function () {
      const { guardian1, insurance } = await loadFixture(deployFixture);

      await insurance.connect(guardian1).requestPause();

      // Contract should NOT be paused yet
      expect(await insurance.paused()).to.equal(false);
      expect(await insurance.pauseApprovalCount()).to.equal(1);
    });

    it('2 guardians can pause (meets threshold)', async function () {
      const { guardian1, guardian2, insurance } =
        await loadFixture(deployFixture);

      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();

      expect(await insurance.paused()).to.equal(true);
    });

    it('duplicate approval from same guardian reverts', async function () {
      const { guardian1, insurance } = await loadFixture(deployFixture);

      await insurance.connect(guardian1).requestPause();

      await expect(
        insurance.connect(guardian1).requestPause()
      ).to.be.revertedWith('Already approved pause');
    });

    it('non-guardian cannot request pause', async function () {
      const { nonGuardian, insurance } = await loadFixture(deployFixture);

      await expect(
        insurance.connect(nonGuardian).requestPause()
      ).to.be.revertedWithCustomError(insurance, 'AccessControlUnauthorizedAccount').withArgs(nonGuardian.address, await insurance.PAUSE_GUARDIAN_ROLE());
    });

    it('emits PauseRequested per approval and EmergencyPaused when threshold met', async function () {
      const { guardian1, guardian2, insurance } =
        await loadFixture(deployFixture);

      await expect(insurance.connect(guardian1).requestPause())
        .to.emit(insurance, 'PauseRequested')
        .withArgs(guardian1.address);

      await expect(insurance.connect(guardian2).requestPause())
        .to.emit(insurance, 'PauseRequested')
        .withArgs(guardian2.address)
        .and.to.emit(insurance, 'EmergencyPaused')
        .withArgs(2);
    });

    it('approval state resets after successful pause', async function () {
      const { guardian1, guardian2, insurance } =
        await loadFixture(deployFixture);

      // Pause
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();
      expect(await insurance.paused()).to.equal(true);

      // Count should be reset
      expect(await insurance.pauseApprovalCount()).to.equal(0);
    });

    it('requestPause reverts when already paused', async function () {
      const { guardian1, guardian2, guardian3, insurance } =
        await loadFixture(deployFixture);

      // Pause the contract
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();
      expect(await insurance.paused()).to.equal(true);

      // Further requestPause should revert (whenNotPaused)
      await expect(
        insurance.connect(guardian3).requestPause()
      ).to.be.revertedWithCustomError(insurance, 'EnforcedPause');
    });
  });

  describe('requestUnpause', function () {
    it('unpause requires same threshold', async function () {
      const { guardian1, guardian2, guardian3, insurance } =
        await loadFixture(deployFixture);

      // First, pause
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();
      expect(await insurance.paused()).to.equal(true);

      // Single guardian cannot unpause
      await insurance.connect(guardian1).requestUnpause();
      expect(await insurance.paused()).to.equal(true);
      expect(await insurance.unpauseApprovalCount()).to.equal(1);

      // Second guardian unpause
      await insurance.connect(guardian2).requestUnpause();
      expect(await insurance.paused()).to.equal(false);
    });

    it('duplicate unpause approval from same guardian reverts', async function () {
      const { guardian1, guardian2, insurance } =
        await loadFixture(deployFixture);

      // Pause first
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();

      await insurance.connect(guardian1).requestUnpause();

      await expect(
        insurance.connect(guardian1).requestUnpause()
      ).to.be.revertedWith('Already approved unpause');
    });

    it('non-guardian cannot request unpause', async function () {
      const { guardian1, guardian2, nonGuardian, insurance } =
        await loadFixture(deployFixture);

      // Pause first
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();

      await expect(
        insurance.connect(nonGuardian).requestUnpause()
      ).to.be.revertedWithCustomError(insurance, 'AccessControlUnauthorizedAccount').withArgs(nonGuardian.address, await insurance.PAUSE_GUARDIAN_ROLE());
    });

    it('emits UnpauseRequested and EmergencyUnpaused events', async function () {
      const { guardian1, guardian2, guardian3, insurance } =
        await loadFixture(deployFixture);

      // Pause
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();

      await expect(insurance.connect(guardian1).requestUnpause())
        .to.emit(insurance, 'UnpauseRequested')
        .withArgs(guardian1.address);

      await expect(insurance.connect(guardian2).requestUnpause())
        .to.emit(insurance, 'UnpauseRequested')
        .withArgs(guardian2.address)
        .and.to.emit(insurance, 'EmergencyUnpaused')
        .withArgs(2);
    });

    it('unpause approval state resets after successful unpause', async function () {
      const { guardian1, guardian2, insurance } =
        await loadFixture(deployFixture);

      // Pause
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();

      // Unpause
      await insurance.connect(guardian1).requestUnpause();
      await insurance.connect(guardian2).requestUnpause();
      expect(await insurance.paused()).to.equal(false);

      expect(await insurance.unpauseApprovalCount()).to.equal(0);
    });

    it('requestUnpause reverts when not paused', async function () {
      const { guardian1, insurance } = await loadFixture(deployFixture);

      await expect(
        insurance.connect(guardian1).requestUnpause()
      ).to.be.revertedWithCustomError(insurance, 'ExpectedPause');
    });
  });

  describe('full cycle: pause -> unpause -> pause again', function () {
    it('guardians can pause again after unpause (nonce reset)', async function () {
      const { guardian1, guardian2, insurance } =
        await loadFixture(deployFixture);

      // First cycle: pause
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();
      expect(await insurance.paused()).to.equal(true);

      // Unpause
      await insurance.connect(guardian1).requestUnpause();
      await insurance.connect(guardian2).requestUnpause();
      expect(await insurance.paused()).to.equal(false);

      // Second cycle: same guardians can pause again
      await insurance.connect(guardian1).requestPause();
      await insurance.connect(guardian2).requestPause();
      expect(await insurance.paused()).to.equal(true);
    });
  });
});
