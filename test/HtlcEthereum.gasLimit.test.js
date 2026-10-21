'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('HtlcEthereum hardcoded gas regression', function () {
  async function deployFixture() {
    const [owner, sender, recipient] = await ethers.getSigners();

    const HtlcEthereum = await ethers.getContractFactory('HtlcEthereum');
    const htlc = await HtlcEthereum.deploy(owner.address);

    const GasHeavyHtlcActor = await ethers.getContractFactory('GasHeavyHtlcActor');
    const actor = await GasHeavyHtlcActor.deploy();

    return { owner, sender, recipient, htlc, actor };
  }

  function secretHash(secret) {
    return ethers.sha256(ethers.solidityPacked(['bytes32'], [secret]));
  }

  it('claims ETH to a recipient contract that needs more than the stipend', async function () {
    const { sender, htlc, actor } = await loadFixture(deployFixture);
    const contractId = ethers.keccak256(ethers.toUtf8Bytes('claim-heavy-recipient'));
    const secret = ethers.encodeBytes32String('claim-secret');
    const amount = ethers.parseEther('1');
    const timeLock = (await time.latest()) + 3600 + 60;

    await htlc.connect(sender).createHtlc(
      contractId,
      secretHash(secret),
      0,
      timeLock,
      await actor.getAddress(),
      ethers.ZeroAddress,
      amount,
      '0x',
      { value: amount }
    );

    await expect(actor.claim(await htlc.getAddress(), contractId, secret))
      .to.emit(htlc, 'HtlcClaimed')
      .withArgs(contractId, secret, await actor.getAddress(), amount);

    expect(await actor.receiveCount()).to.equal(1n);
    expect(await actor.lastValueReceived()).to.equal(amount);
  });

  it('refunds ETH to a sender contract that needs more than the stipend', async function () {
    const { recipient, htlc, actor } = await loadFixture(deployFixture);
    const contractId = ethers.keccak256(ethers.toUtf8Bytes('refund-heavy-sender'));
    const amount = ethers.parseEther('1');
    const timeLock = (await time.latest()) + 3600 + 60;

    await actor.createEthHtlc(
      await htlc.getAddress(),
      contractId,
      secretHash(ethers.encodeBytes32String('refund-secret')),
      0,
      timeLock,
      recipient.address,
      amount,
      { value: amount }
    );

    await time.increaseTo(timeLock + 300);

    await expect(actor.refund(await htlc.getAddress(), contractId))
      .to.emit(htlc, 'HtlcRefunded')
      .withArgs(contractId, await actor.getAddress(), amount);

    expect(await actor.receiveCount()).to.equal(1n);
    expect(await actor.lastValueReceived()).to.equal(amount);
  });
});
