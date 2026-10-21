// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
} = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonBasketToken — Fee Timelock (sc#33)', function () {
  const TIMELOCK_DELAY = 48 * 3600; // 48 hours
  const TIMELOCK_EXPIRY = 7 * 24 * 3600; // 7 days

  async function deployFixture() {
    const [owner, nonOwner, newRecipient] = await ethers.getSigners();

    const MockOracle = await ethers.getContractFactory('MockQualityOracleConcrete');
    const oracle = await MockOracle.deploy();

    const CarbonBasketToken = await ethers.getContractFactory('CarbonBasketToken');
    const basket = await CarbonBasketToken.deploy(
      await oracle.getAddress(),
      'Carbon Basket',
      'CBASKET'
    );

    return { owner, nonOwner, newRecipient, basket };
  }

  // ========== MANAGEMENT FEE ==========

  describe('Management fee timelock', function () {
    it('reverts when queuing fee above MAX_MANAGEMENT_FEE', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.queueManagementFeeRate(501))
        .to.be.revertedWith('CarbonBasketToken: Fee rate too high');
    });

    it('queues a valid management fee change', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.queueManagementFeeRate(200))
        .to.emit(basket, 'FeeUpdateQueued');

      const pending = await basket.pendingManagementFee();
      expect(pending.newRate).to.equal(200);
      expect(pending.exists).to.equal(true);
    });

    it('reverts execution before timelock elapses', async function () {
      const { basket } = await loadFixture(deployFixture);
      await basket.queueManagementFeeRate(200);

      // Try immediately
      await expect(basket.executeManagementFeeRate())
        .to.be.revertedWith('CarbonBasketToken: Timelock not elapsed');

      // Try at 47 hours
      await time.increase(47 * 3600);
      await expect(basket.executeManagementFeeRate())
        .to.be.revertedWith('CarbonBasketToken: Timelock not elapsed');
    });

    it('succeeds after timelock delay', async function () {
      const { basket } = await loadFixture(deployFixture);
      await basket.queueManagementFeeRate(200);

      await time.increase(TIMELOCK_DELAY);

      await expect(basket.executeManagementFeeRate())
        .to.emit(basket, 'FeeUpdateExecuted')
        .withArgs(1, 'management', 100, 200);

      expect(await basket.managementFeeRate()).to.equal(200);
    });

    it('reverts after expiry window', async function () {
      const { basket } = await loadFixture(deployFixture);
      await basket.queueManagementFeeRate(200);

      // Past timelock + expiry
      await time.increase(TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

      await expect(basket.executeManagementFeeRate())
        .to.be.revertedWith('CarbonBasketToken: Fee change expired');
    });

    it('reverts execution when nothing is queued', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.executeManagementFeeRate())
        .to.be.revertedWith('CarbonBasketToken: No pending fee change');
    });
  });

  // ========== PERFORMANCE FEE ==========

  describe('Performance fee timelock', function () {
    it('reverts when queuing fee above MAX_PERFORMANCE_FEE', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.queuePerformanceFeeRate(2001))
        .to.be.revertedWith('CarbonBasketToken: Fee rate too high');
    });

    it('queues a valid performance fee change', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.queuePerformanceFeeRate(1500))
        .to.emit(basket, 'FeeUpdateQueued');

      const pending = await basket.pendingPerformanceFee();
      expect(pending.newRate).to.equal(1500);
      expect(pending.exists).to.equal(true);
    });

    it('reverts execution before timelock elapses', async function () {
      const { basket } = await loadFixture(deployFixture);
      await basket.queuePerformanceFeeRate(1500);

      await expect(basket.executePerformanceFeeRate())
        .to.be.revertedWith('CarbonBasketToken: Timelock not elapsed');
    });

    it('succeeds after timelock delay', async function () {
      const { basket } = await loadFixture(deployFixture);
      await basket.queuePerformanceFeeRate(1500);

      await time.increase(TIMELOCK_DELAY);

      await expect(basket.executePerformanceFeeRate())
        .to.emit(basket, 'FeeUpdateExecuted')
        .withArgs(1, 'performance', 1000, 1500);

      expect(await basket.performanceFeeRate()).to.equal(1500);
    });

    it('reverts after expiry window', async function () {
      const { basket } = await loadFixture(deployFixture);
      await basket.queuePerformanceFeeRate(1500);

      await time.increase(TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

      await expect(basket.executePerformanceFeeRate())
        .to.be.revertedWith('CarbonBasketToken: Fee change expired');
    });

    it('reverts execution when nothing is queued', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.executePerformanceFeeRate())
        .to.be.revertedWith('CarbonBasketToken: No pending fee change');
    });
  });

  // ========== FEE RECIPIENT ==========

  describe('Fee recipient update', function () {
    it('emits FeeRecipientUpdated event', async function () {
      const { basket, owner, newRecipient } = await loadFixture(deployFixture);
      await expect(basket.setFeeRecipient(newRecipient.address))
        .to.emit(basket, 'FeeRecipientUpdated')
        .withArgs(owner.address, newRecipient.address);
    });

    it('updates the fee recipient', async function () {
      const { basket, newRecipient } = await loadFixture(deployFixture);
      await basket.setFeeRecipient(newRecipient.address);
      expect(await basket.feeRecipient()).to.equal(newRecipient.address);
    });

    it('reverts for zero address', async function () {
      const { basket } = await loadFixture(deployFixture);
      await expect(basket.setFeeRecipient(ethers.ZeroAddress))
        .to.be.revertedWith('CarbonBasketToken: Invalid recipient address');
    });
  });

  // ========== ACCESS CONTROL ==========

  describe('Access control', function () {
    it('non-owner cannot queue management fee', async function () {
      const { basket, nonOwner } = await loadFixture(deployFixture);
      await expect(basket.connect(nonOwner).queueManagementFeeRate(200))
        .to.be.revertedWithCustomError(basket, 'OwnableUnauthorizedAccount');
    });

    it('non-owner cannot execute management fee', async function () {
      const { basket, nonOwner } = await loadFixture(deployFixture);
      await basket.queueManagementFeeRate(200);
      await time.increase(TIMELOCK_DELAY);
      await expect(basket.connect(nonOwner).executeManagementFeeRate())
        .to.be.revertedWithCustomError(basket, 'OwnableUnauthorizedAccount');
    });

    it('non-owner cannot queue performance fee', async function () {
      const { basket, nonOwner } = await loadFixture(deployFixture);
      await expect(basket.connect(nonOwner).queuePerformanceFeeRate(1500))
        .to.be.revertedWithCustomError(basket, 'OwnableUnauthorizedAccount');
    });

    it('non-owner cannot execute performance fee', async function () {
      const { basket, nonOwner } = await loadFixture(deployFixture);
      await basket.queuePerformanceFeeRate(1500);
      await time.increase(TIMELOCK_DELAY);
      await expect(basket.connect(nonOwner).executePerformanceFeeRate())
        .to.be.revertedWithCustomError(basket, 'OwnableUnauthorizedAccount');
    });

    it('non-owner cannot set fee recipient', async function () {
      const { basket, nonOwner, newRecipient } = await loadFixture(deployFixture);
      await expect(basket.connect(nonOwner).setFeeRecipient(newRecipient.address))
        .to.be.revertedWithCustomError(basket, 'OwnableUnauthorizedAccount');
    });
  });

  // ========== EVENTS ==========

  describe('Event parameters', function () {
    it('FeeUpdateQueued includes correct parameters for management fee', async function () {
      const { basket } = await loadFixture(deployFixture);
      const tx = await basket.queueManagementFeeRate(300);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);

      await expect(tx)
        .to.emit(basket, 'FeeUpdateQueued')
        .withArgs(1, 'management', 100, 300, block.timestamp + TIMELOCK_DELAY);
    });

    it('FeeUpdateQueued includes correct parameters for performance fee', async function () {
      const { basket } = await loadFixture(deployFixture);
      const tx = await basket.queuePerformanceFeeRate(500);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);

      await expect(tx)
        .to.emit(basket, 'FeeUpdateQueued')
        .withArgs(1, 'performance', 1000, 500, block.timestamp + TIMELOCK_DELAY);
    });

    it('nonce increments across fee types', async function () {
      const { basket } = await loadFixture(deployFixture);

      await expect(basket.queueManagementFeeRate(200))
        .to.emit(basket, 'FeeUpdateQueued');

      await expect(basket.queuePerformanceFeeRate(1500))
        .to.emit(basket, 'FeeUpdateQueued');

      expect(await basket.feeChangeNonce()).to.equal(2);

      const pendingMgmt = await basket.pendingManagementFee();
      expect(pendingMgmt.nonce).to.equal(1);

      const pendingPerf = await basket.pendingPerformanceFee();
      expect(pendingPerf.nonce).to.equal(2);
    });
  });
});
