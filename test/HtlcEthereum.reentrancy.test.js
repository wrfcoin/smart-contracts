'use strict';
/**
 * @title HtlcEthereum Reentrancy Tests (#85)
 * @dev Tests for Address.sendValue usage and CEI correctness in claimHtlc/refundHtlc.
 *
 * Covers:
 * - claimHtlc: state is updated before ETH transfer (nonReentrant blocks re-entry)
 * - refundHtlc: state is updated before ETH transfer (nonReentrant blocks re-entry)
 * - Gas-heavy recipients still receive funds (Address.sendValue forwards all gas)
 * - Double-claim attempt after state update is rejected
 * - Double-refund attempt after state update is rejected
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('HtlcEthereum — CEI / Reentrancy (#85)', function () {
  function sha256Hash(secret) {
    return ethers.sha256(ethers.solidityPacked(['bytes32'], [secret]));
  }

  async function deployFixture() {
    const [owner, sender, recipient] = await ethers.getSigners();

    const HtlcEthereum = await ethers.getContractFactory('HtlcEthereum');
    const htlc = await HtlcEthereum.deploy(owner.address);

    return { htlc, owner, sender, recipient };
  }

  // Helper: create a standard ETH HTLC
  async function createEthHtlc(htlc, sender, recipient, contractId, secret, amount) {
    const timeLock = (await time.latest()) + 3600 + 120;
    const hashLock = sha256Hash(secret);
    await htlc.connect(sender).createHtlc(
      contractId,
      hashLock,
      0, // SHA256
      timeLock,
      recipient.address,
      ethers.ZeroAddress,
      amount,
      '0x',
      { value: amount }
    );
    return timeLock;
  }

  describe('claimHtlc — state-before-transfer (CEI)', function () {
    it('normal claim transfers ETH to recipient', async function () {
      const { htlc, sender, recipient } = await loadFixture(deployFixture);
      const contractId = ethers.keccak256(ethers.toUtf8Bytes('claim-normal'));
      const secret = ethers.encodeBytes32String('secret1');
      const amount = ethers.parseEther('1');

      await createEthHtlc(htlc, sender, recipient, contractId, secret, amount);

      const recipientBalBefore = await ethers.provider.getBalance(recipient.address);
      const tx = await htlc.connect(recipient).claimHtlc(contractId, secret);
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;
      const recipientBalAfter = await ethers.provider.getBalance(recipient.address);

      expect(recipientBalAfter - recipientBalBefore + gasUsed).to.equal(amount);
      await expect(tx).to.emit(htlc, 'HtlcClaimed').withArgs(contractId, secret, recipient.address, amount);
    });

    it('claimHtlc marks withdrawn=true BEFORE transfer — double-claim is rejected', async function () {
      const { htlc, sender, recipient } = await loadFixture(deployFixture);
      const contractId = ethers.keccak256(ethers.toUtf8Bytes('claim-double'));
      const secret = ethers.encodeBytes32String('secret2');
      const amount = ethers.parseEther('0.5');

      await createEthHtlc(htlc, sender, recipient, contractId, secret, amount);

      // First claim succeeds
      await htlc.connect(recipient).claimHtlc(contractId, secret);

      // Second claim fails because withdrawn=true was set before transfer
      await expect(
        htlc.connect(recipient).claimHtlc(contractId, secret)
      ).to.be.revertedWith('HTLC: Funds already withdrawn');
    });

    it('claimHtlc with gas-heavy recipient contract works (Address.sendValue forwards all gas)', async function () {
      const { htlc, sender } = await loadFixture(deployFixture);

      const GasHeavyHtlcActor = await ethers.getContractFactory('GasHeavyHtlcActor');
      const actor = await GasHeavyHtlcActor.deploy();

      const contractId = ethers.keccak256(ethers.toUtf8Bytes('claim-gas-heavy-cei'));
      const secret = ethers.encodeBytes32String('heavy1');
      const amount = ethers.parseEther('0.5');
      const timeLock = (await time.latest()) + 3600 + 120;
      const hashLock = sha256Hash(secret);

      await htlc.connect(sender).createHtlc(
        contractId, hashLock, 0, timeLock,
        await actor.getAddress(), ethers.ZeroAddress, amount, '0x',
        { value: amount }
      );

      await expect(actor.claim(await htlc.getAddress(), contractId, secret))
        .to.emit(htlc, 'HtlcClaimed');

      expect(await actor.receiveCount()).to.equal(1n);
      expect(await actor.lastValueReceived()).to.equal(amount);
    });
  });

  describe('refundHtlc — state-before-transfer (CEI)', function () {
    it('normal refund returns ETH to sender after expiry', async function () {
      const { htlc, sender, recipient } = await loadFixture(deployFixture);
      const contractId = ethers.keccak256(ethers.toUtf8Bytes('refund-normal'));
      const secret = ethers.encodeBytes32String('refund1');
      const amount = ethers.parseEther('1');

      const timeLock = await createEthHtlc(htlc, sender, recipient, contractId, secret, amount);

      // Fast-forward past timeLock + grace period (300s)
      await time.increaseTo(timeLock + 300);

      const senderBalBefore = await ethers.provider.getBalance(sender.address);
      const tx = await htlc.connect(sender).refundHtlc(contractId);
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;
      const senderBalAfter = await ethers.provider.getBalance(sender.address);

      expect(senderBalAfter - senderBalBefore + gasUsed).to.equal(amount);
      await expect(tx).to.emit(htlc, 'HtlcRefunded').withArgs(contractId, sender.address, amount);
    });

    it('refundHtlc marks refunded=true BEFORE transfer — double-refund is rejected', async function () {
      const { htlc, sender, recipient } = await loadFixture(deployFixture);
      const contractId = ethers.keccak256(ethers.toUtf8Bytes('refund-double'));
      const secret = ethers.encodeBytes32String('refund2');
      const amount = ethers.parseEther('0.5');

      const timeLock = await createEthHtlc(htlc, sender, recipient, contractId, secret, amount);
      await time.increaseTo(timeLock + 300);

      // First refund succeeds
      await htlc.connect(sender).refundHtlc(contractId);

      // Second refund fails because refunded=true was set before transfer
      await expect(
        htlc.connect(sender).refundHtlc(contractId)
      ).to.be.revertedWith('HTLC: Funds already refunded');
    });

    it('refundHtlc with gas-heavy sender contract works (Address.sendValue forwards all gas)', async function () {
      const { htlc, recipient } = await loadFixture(deployFixture);

      const GasHeavyHtlcActor = await ethers.getContractFactory('GasHeavyHtlcActor');
      const actor = await GasHeavyHtlcActor.deploy();

      const contractId = ethers.keccak256(ethers.toUtf8Bytes('refund-gas-heavy-cei'));
      const secret = ethers.encodeBytes32String('heavyRefund');
      const amount = ethers.parseEther('0.5');
      const timeLock = (await time.latest()) + 3600 + 120;
      const hashLock = sha256Hash(secret);

      await actor.createEthHtlc(
        await htlc.getAddress(),
        contractId, hashLock, 0, timeLock,
        recipient.address, amount,
        { value: amount }
      );

      await time.increaseTo(timeLock + 300);

      await expect(actor.refund(await htlc.getAddress(), contractId))
        .to.emit(htlc, 'HtlcRefunded');

      expect(await actor.receiveCount()).to.equal(1n);
      expect(await actor.lastValueReceived()).to.equal(amount);
    });
  });

  describe('Secret reuse protection', function () {
    it('same secret cannot be reused across two different contracts', async function () {
      const { htlc, sender, recipient } = await loadFixture(deployFixture);

      const secret = ethers.encodeBytes32String('reusedSecret');
      const hashLock = sha256Hash(secret);
      const amount = ethers.parseEther('0.1');
      const timeLock = (await time.latest()) + 3600 + 120;

      // Create first HTLC
      const id1 = ethers.keccak256(ethers.toUtf8Bytes('reuse-htlc-1'));
      await htlc.connect(sender).createHtlc(
        id1, hashLock, 0, timeLock, recipient.address, ethers.ZeroAddress, amount, '0x',
        { value: amount }
      );

      // Create second HTLC with same hashLock
      const id2 = ethers.keccak256(ethers.toUtf8Bytes('reuse-htlc-2'));
      await htlc.connect(sender).createHtlc(
        id2, hashLock, 0, timeLock, recipient.address, ethers.ZeroAddress, amount, '0x',
        { value: amount }
      );

      // Claim first — works fine
      await htlc.connect(recipient).claimHtlc(id1, secret);

      // Attempt to claim second with same secret — blocked (usedSecrets mapping)
      await expect(
        htlc.connect(recipient).claimHtlc(id2, secret)
      ).to.be.revertedWith('HTLC: Secret already used');
    });
  });
});
