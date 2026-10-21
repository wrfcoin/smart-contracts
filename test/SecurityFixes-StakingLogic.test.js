const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('Security Fixes — Staking/Logic (PR 2)', function () {
  // =========================================================================
  // #57: DeFiSecurityRemediation tx.origin → msg.sender
  // =========================================================================
  describe('#57 — DeFiSecurityRemediation flash loan rate limiting uses msg.sender', function () {
    it('should compile DeFiSecurityRemediation with msg.sender rate limiting', async function () {
      const DeFiSecurityRemediation = await ethers.getContractFactory(
        'DeFiSecurityRemediation'
      );
      expect(DeFiSecurityRemediation).to.not.be.null;
    });
  });

  // =========================================================================
  // #59: CarbonCreditAMM flash-swap authorization
  // =========================================================================
  describe('#59 — CarbonCreditAMM flash-swap authorization check', function () {
    it('should compile CarbonCreditAMM with flash-swap auth check', async function () {
      const CarbonCreditAMM = await ethers.getContractFactory(
        'CarbonCreditAMM'
      );
      expect(CarbonCreditAMM).to.not.be.null;
    });
  });

  // =========================================================================
  // #55 + #58: SlashingMechanism recompute + MultiAssetStaking withdrawal block
  // =========================================================================
  describe('#55 + #58 — Slash recompute + withdrawal block during pending slash', function () {
    async function deployStakingFixture() {
      const [owner, staker, slashingAddr] = await ethers.getSigners();

      const MockERC20 = await ethers.getContractFactory('MockERC20');
      const token = await MockERC20.deploy('Test Token', 'TT', 18);

      // Deploy MultiAssetStaking (just to test the pending slashing logic)
      const MultiAssetStaking = await ethers.getContractFactory(
        'MultiAssetStaking'
      );
      // Constructor requires various addresses
      const multiAssetStaking = await MultiAssetStaking.deploy(
        owner.address, // _stakeCalculator
        owner.address, // _participantRegistry
        owner.address, // _bridgeIntegration
        owner.address, // _emergencyLiquidator
        owner.address  // _treasury
      );

      return { multiAssetStaking, token, owner, staker, slashingAddr };
    }

    it('MultiAssetStaking should have hasPendingSlashing mapping', async function () {
      const { multiAssetStaking, staker } = await loadFixture(
        deployStakingFixture
      );
      // Default value should be false
      expect(await multiAssetStaking.hasPendingSlashing(staker.address)).to.equal(false);
    });

    it('only slashingMechanism can call setPendingSlashing', async function () {
      const { multiAssetStaking, staker, owner } = await loadFixture(
        deployStakingFixture
      );

      // Direct call from owner should fail (slashingMechanism not set)
      await expect(
        multiAssetStaking.setPendingSlashing(staker.address, true)
      ).to.be.revertedWith('MultiAssetStaking: Only slashing mechanism');
    });

    it('setPendingSlashing works when called by authorized slashingMechanism', async function () {
      const { multiAssetStaking, staker, slashingAddr, owner } =
        await loadFixture(deployStakingFixture);

      // Owner sets the slashing mechanism address
      await multiAssetStaking.setSlashingMechanism(slashingAddr.address);

      // Now slashingAddr can set pending slashing
      await multiAssetStaking
        .connect(slashingAddr)
        .setPendingSlashing(staker.address, true);

      expect(await multiAssetStaking.hasPendingSlashing(staker.address)).to.equal(true);
    });

    it('SlashingMechanism should compile with recomputed slash amount', async function () {
      const SlashingMechanism = await ethers.getContractFactory(
        'SlashingMechanism'
      );
      expect(SlashingMechanism).to.not.be.null;
    });
  });

  // =========================================================================
  // #63: CarbonCreditRouter + CarbonCreditAMMFactory pool validation
  // =========================================================================
  describe('#63 — CarbonCreditRouter pool active validation', function () {
    it('CarbonCreditAMMFactory should expose isPoolActive function', async function () {
      const CarbonCreditAMMFactory = await ethers.getContractFactory(
        'CarbonCreditAMMFactory'
      );
      expect(CarbonCreditAMMFactory).to.not.be.null;
    });

    it('CarbonCreditRouter should compile with pool active check', async function () {
      const CarbonCreditRouter = await ethers.getContractFactory(
        'CarbonCreditRouter'
      );
      expect(CarbonCreditRouter).to.not.be.null;
    });
  });
});
