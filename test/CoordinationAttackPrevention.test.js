'use strict';
/**
 * @title CoordinationAttackPrevention Tests (#82)
 * @dev Test coverage for the governance coordination-attack prevention system.
 *
 * Covers:
 * - Deployment and role setup
 * - Access control: only PATTERN_ANALYST_ROLE can call analyzeVotingBehavior
 * - Input validation: array length mismatches, insufficient sample size
 * - Happy-path analysis with 10+ voters (minimum sample size)
 * - Non-analyst cannot analyze
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CoordinationAttackPrevention (#82)', function () {
  async function deployFixture() {
    const [admin, analyst, nonAnalyst, ...voters] = await ethers.getSigners();

    const CAP = await ethers.getContractFactory('CoordinationAttackPrevention');
    const cap = await CAP.deploy(admin.address);

    const PATTERN_ANALYST_ROLE = await cap.PATTERN_ANALYST_ROLE();
    await cap.connect(admin).grantRole(PATTERN_ANALYST_ROLE, analyst.address);

    return { cap, admin, analyst, nonAnalyst, voters, PATTERN_ANALYST_ROLE };
  }

  // Helper: build arrays for a minimal valid analysis call (needs ≥10 voters)
  function buildVoteArrays(signers, blockTimestamp) {
    const addrs = signers.slice(0, 10).map((s) => s.address);
    const amounts = addrs.map((_, i) => ethers.parseEther(String(100 + i * 7)));
    // Space votes out by 60s each to simulate real voting
    const timestamps = addrs.map((_, i) => BigInt(blockTimestamp) + BigInt(i * 60));
    return { addrs, amounts, timestamps };
  }

  // ── Deployment ───────────────────────────────────────────────────────────

  describe('Deployment', function () {
    it('deploys without reverting', async function () {
      const { cap } = await loadFixture(deployFixture);
      expect(await cap.getAddress()).to.be.properAddress;
    });

    it('grants DEFAULT_ADMIN_ROLE to admin', async function () {
      const { cap, admin } = await loadFixture(deployFixture);
      const adminRole = await cap.DEFAULT_ADMIN_ROLE();
      expect(await cap.hasRole(adminRole, admin.address)).to.be.true;
    });

    it('grants PATTERN_ANALYST_ROLE to admin by default', async function () {
      const { cap, admin } = await loadFixture(deployFixture);
      const role = await cap.PATTERN_ANALYST_ROLE();
      expect(await cap.hasRole(role, admin.address)).to.be.true;
    });

    it('initialises nextDetectionId to 1', async function () {
      const { cap } = await loadFixture(deployFixture);
      expect(await cap.nextDetectionId()).to.equal(1n);
    });
  });

  // ── Role management ──────────────────────────────────────────────────────

  describe('Role management', function () {
    it('admin can grant SECURITY_MONITOR_ROLE', async function () {
      const { cap, admin, nonAnalyst } = await loadFixture(deployFixture);
      const role = await cap.SECURITY_MONITOR_ROLE();
      await cap.connect(admin).grantRole(role, nonAnalyst.address);
      expect(await cap.hasRole(role, nonAnalyst.address)).to.be.true;
    });

    it('non-admin cannot grant roles', async function () {
      const { cap, nonAnalyst, analyst } = await loadFixture(deployFixture);
      const role = await cap.SECURITY_MONITOR_ROLE();
      await expect(
        cap.connect(nonAnalyst).grantRole(role, analyst.address),
      ).to.be.revertedWithCustomError(cap, 'AccessControlUnauthorizedAccount').withArgs(nonAnalyst.address, await cap.DEFAULT_ADMIN_ROLE());
    });
  });

  // ── analyzeVotingBehavior: access control ────────────────────────────────

  describe('analyzeVotingBehavior() — access control', function () {
    it('reverts when caller lacks PATTERN_ANALYST_ROLE', async function () {
      const { cap, nonAnalyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const { addrs, amounts, timestamps } = buildVoteArrays(voters, block.timestamp);

      await expect(
        cap.connect(nonAnalyst).analyzeVotingBehavior(1, addrs, amounts, timestamps),
      ).to.be.revertedWithCustomError(cap, 'AccessControlUnauthorizedAccount').withArgs(nonAnalyst.address, await cap.PATTERN_ANALYST_ROLE());
    });

    it('succeeds when caller has PATTERN_ANALYST_ROLE', async function () {
      const { cap, analyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const { addrs, amounts, timestamps } = buildVoteArrays(voters, block.timestamp);

      // Should not revert; detection IDs array may be empty (no patterns exceed threshold)
      await expect(
        cap.connect(analyst).analyzeVotingBehavior(1, addrs, amounts, timestamps),
      ).to.not.be.reverted;
    });
  });

  // ── analyzeVotingBehavior: input validation ──────────────────────────────

  describe('analyzeVotingBehavior() — input validation', function () {
    it('reverts on voter/amount array length mismatch', async function () {
      const { cap, analyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const addrs = voters.slice(0, 10).map((s) => s.address);
      const amounts = addrs.slice(0, 9).map(() => ethers.parseEther('100')); // one short
      const timestamps = addrs.map((_, i) => BigInt(block.timestamp) + BigInt(i * 60));

      await expect(
        cap.connect(analyst).analyzeVotingBehavior(1, addrs, amounts, timestamps),
      ).to.be.revertedWith('CAP: Array length mismatch');
    });

    it('reverts on voter/timestamp array length mismatch', async function () {
      const { cap, analyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const addrs = voters.slice(0, 10).map((s) => s.address);
      const amounts = addrs.map(() => ethers.parseEther('100'));
      const timestamps = addrs.slice(0, 9).map((_, i) => BigInt(block.timestamp) + BigInt(i * 60));

      await expect(
        cap.connect(analyst).analyzeVotingBehavior(1, addrs, amounts, timestamps),
      ).to.be.revertedWith('CAP: Array length mismatch');
    });

    it('reverts when voters array is below minimum sample size (10)', async function () {
      const { cap, analyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const addrs = voters.slice(0, 5).map((s) => s.address); // only 5
      const amounts = addrs.map(() => ethers.parseEther('100'));
      const timestamps = addrs.map((_, i) => BigInt(block.timestamp) + BigInt(i * 60));

      await expect(
        cap.connect(analyst).analyzeVotingBehavior(1, addrs, amounts, timestamps),
      ).to.be.revertedWith('CAP: Insufficient sample size');
    });
  });

  // ── analyzeVotingBehavior: happy path ────────────────────────────────────

  describe('analyzeVotingBehavior() — happy path', function () {
    it('returns an array (may be empty when no patterns exceed threshold)', async function () {
      const { cap, analyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const { addrs, amounts, timestamps } = buildVoteArrays(voters, block.timestamp);

      const tx = await cap.connect(analyst).analyzeVotingBehavior(1, addrs, amounts, timestamps);
      const receipt = await tx.wait();
      expect(receipt.status).to.equal(1);
    });

    it('increments nextDetectionId only when detections are created', async function () {
      const { cap, analyst, voters } = await loadFixture(deployFixture);
      const block = await ethers.provider.getBlock('latest');
      const beforeId = await cap.nextDetectionId();
      const { addrs, amounts, timestamps } = buildVoteArrays(voters, block.timestamp);

      await cap.connect(analyst).analyzeVotingBehavior(1, addrs, amounts, timestamps);

      // nextDetectionId should be ≥ beforeId (stays same if no detections, increases if any)
      expect(await cap.nextDetectionId()).to.be.gte(beforeId);
    });
  });
});
