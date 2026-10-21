'use strict';
/**
 * @title CarbonFarmingPool Tests (#82)
 * @dev Test coverage for CarbonFarmingPool initialize + stake/unstake flows.
 *
 * Covers:
 * - Deployment (constructor is empty — proxy pattern)
 * - initialize(): happy path, zero-address guards, double-init guard
 * - handleStake(): onlyFarmingManager access control + basic stake accounting
 * - emergencyWithdraw(): farming manager can trigger emergency withdrawal
 * - getPendingRewards(): returns 0 for a brand-new stake
 * - getUserStakeInfo(): reflects staked amount after handleStake
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonFarmingPool (#82)', function () {
  async function deployFixture() {
    const [deployer, farmingManager, lpPool, rewardDistributorAcct, user, other] =
      await ethers.getSigners();

    // CarbonFarmingPool only stores rewardDistributor as an address for token transfers;
    // it does not call any interface methods on it during the flows we test here.
    const CarbonFarmingPool = await ethers.getContractFactory('CarbonFarmingPool');
    const pool = await CarbonFarmingPool.deploy();

    const BASE_REWARD_RATE = ethers.parseEther('1'); // 1 WRF / second (test param)
    const MIN_STAKE = 1n;           // 1 second min
    const MAX_STAKE = 365n * 86400n; // 1 year max

    return {
      pool,
      rewardDistributorAcct,
      farmingManager,
      lpPool,
      user,
      other,
      BASE_REWARD_RATE,
      MIN_STAKE,
      MAX_STAKE,
    };
  }

  async function initializedFixture() {
    const ctx = await loadFixture(deployFixture);
    const { pool, farmingManager, lpPool, rewardDistributorAcct, BASE_REWARD_RATE, MIN_STAKE, MAX_STAKE } = ctx;

    await pool.initialize(
      lpPool.address,
      farmingManager.address,
      rewardDistributorAcct.address,
      BASE_REWARD_RATE,
      MIN_STAKE,
      MAX_STAKE,
    );

    return ctx;
  }

  // ── Deployment ───────────────────────────────────────────────────────────

  describe('Deployment', function () {
    it('deploys without reverting', async function () {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getAddress()).to.be.properAddress;
    });
  });

  // ── initialize() ─────────────────────────────────────────────────────────

  describe('initialize()', function () {
    it('sets farmingManager, liquidityPool, and rewardDistributor', async function () {
      const { pool, farmingManager, lpPool, rewardDistributorAcct } =
        await loadFixture(initializedFixture);

      expect(await pool.farmingManager()).to.equal(farmingManager.address);
      expect(await pool.liquidityPool()).to.equal(lpPool.address);
      expect(await pool.rewardDistributor()).to.equal(rewardDistributorAcct.address);
    });

    it('sets baseRewardRate', async function () {
      const { pool, BASE_REWARD_RATE } = await loadFixture(initializedFixture);
      expect(await pool.baseRewardRate()).to.equal(BASE_REWARD_RATE);
    });

    it('reverts when farmingManager is zero address', async function () {
      const { pool, lpPool, rewardDistributorAcct, BASE_REWARD_RATE, MIN_STAKE, MAX_STAKE } =
        await loadFixture(deployFixture);
      await expect(
        pool.initialize(
          lpPool.address,
          ethers.ZeroAddress,
          rewardDistributorAcct.address,
          BASE_REWARD_RATE,
          MIN_STAKE,
          MAX_STAKE,
        ),
      ).to.be.revertedWith('CarbonFarmingPool: Invalid farming manager');
    });

    it('reverts when liquidityPool is zero address', async function () {
      const { pool, farmingManager, rewardDistributorAcct, BASE_REWARD_RATE, MIN_STAKE, MAX_STAKE } =
        await loadFixture(deployFixture);
      await expect(
        pool.initialize(
          ethers.ZeroAddress,
          farmingManager.address,
          rewardDistributorAcct.address,
          BASE_REWARD_RATE,
          MIN_STAKE,
          MAX_STAKE,
        ),
      ).to.be.revertedWith('CarbonFarmingPool: Invalid liquidity pool');
    });

    it('reverts when baseRewardRate is 0', async function () {
      const { pool, farmingManager, lpPool, rewardDistributorAcct, MIN_STAKE, MAX_STAKE } =
        await loadFixture(deployFixture);
      await expect(
        pool.initialize(
          lpPool.address,
          farmingManager.address,
          rewardDistributorAcct.address,
          0,
          MIN_STAKE,
          MAX_STAKE,
        ),
      ).to.be.revertedWith('CarbonFarmingPool: Invalid reward rate');
    });

    it('reverts on double initialisation (Initializable guard)', async function () {
      const { pool, farmingManager, lpPool, rewardDistributorAcct, BASE_REWARD_RATE, MIN_STAKE, MAX_STAKE } =
        await loadFixture(initializedFixture);
      await expect(
        pool.initialize(
          lpPool.address,
          farmingManager.address,
          rewardDistributorAcct.address,
          BASE_REWARD_RATE,
          MIN_STAKE,
          MAX_STAKE,
        ),
      ).to.be.revertedWithCustomError(pool, 'InvalidInitialization'); // InvalidInitialization from Initializable
    });
  });

  // ── handleStake() ─────────────────────────────────────────────────────────

  describe('handleStake()', function () {
    it('reverts when called by a non-farmingManager', async function () {
      const { pool, user } = await loadFixture(initializedFixture);
      await expect(
        pool.connect(user).handleStake(user.address, ethers.parseEther('10')),
      ).to.be.revertedWith('CarbonFarmingPool: Only farming manager');
    });

    it('reverts when user address is zero', async function () {
      const { pool, farmingManager } = await loadFixture(initializedFixture);
      await expect(
        pool
          .connect(farmingManager)
          .handleStake(ethers.ZeroAddress, ethers.parseEther('10')),
      ).to.be.revertedWith('CarbonFarmingPool: Invalid user address');
    });

    it('records staked amount in getUserStakeInfo', async function () {
      const { pool, farmingManager, user } = await loadFixture(initializedFixture);
      const stakeAmount = ethers.parseEther('50');

      await pool.connect(farmingManager).handleStake(user.address, stakeAmount);

      const info = await pool.getUserStakeInfo(user.address);
      expect(info.amount).to.equal(stakeAmount);
    });

    it('getPendingRewards returns 0 immediately after staking', async function () {
      const { pool, farmingManager, user } = await loadFixture(initializedFixture);
      await pool.connect(farmingManager).handleStake(user.address, ethers.parseEther('50'));
      expect(await pool.getPendingRewards(user.address)).to.equal(0n);
    });
  });

  // ── emergencyWithdraw() ───────────────────────────────────────────────────

  describe('emergencyWithdraw()', function () {
    it('reverts when called by a non-farmingManager', async function () {
      const { pool, user } = await loadFixture(initializedFixture);
      await expect(
        pool.connect(user).emergencyWithdraw(user.address, ethers.parseEther('10')),
      ).to.be.revertedWith('CarbonFarmingPool: Only farming manager');
    });

    it('reverts when amount is 0 (even for farming manager)', async function () {
      const { pool, farmingManager, user } = await loadFixture(initializedFixture);
      await expect(
        pool.connect(farmingManager).emergencyWithdraw(user.address, 0),
      ).to.be.revertedWith('CarbonFarmingPool: Invalid withdrawal amount');
    });

    it('reverts when user has no stake to withdraw', async function () {
      const { pool, farmingManager, user } = await loadFixture(initializedFixture);
      await expect(
        pool.connect(farmingManager).emergencyWithdraw(user.address, ethers.parseEther('1')),
      ).to.be.revertedWith('CarbonFarmingPool: Insufficient stake');
    });
  });
});
