'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('PlausibilityAttestationRegistry (#160)', function () {
  const frame = (name) => ethers.keccak256(ethers.toUtf8Bytes(`frame:${name}`));
  const policy = ethers.keccak256(ethers.toUtf8Bytes('SIM-FLUID-V1-policy'));

  async function deployFixture() {
    const [owner, attesterOne, attesterTwo, attesterThree, attesterFour, outsider] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory('PlausibilityAttestationRegistry');
    const registry = await Registry.deploy(owner.address);
    await registry.waitForDeployment();
    await registry.addAttester(attesterOne.address);
    await registry.addAttester(attesterTwo.address);
    await registry.addAttester(attesterThree.address);
    await registry.addAttester(attesterFour.address);
    await registry.setMinimumAttestations(2);
    return { registry, owner, attesterOne, attesterTwo, attesterThree, attesterFour, outsider };
  }

  async function expiry() {
    return BigInt((await time.latest()) + 3600);
  }

  it('requires two distinct positive attestations before a frame is plausible', async function () {
    const { registry, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('positive');
    const validUntil = await expiry();

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    expect(await registry.isPlausible(hash)).to.equal(false);
    await registry.connect(attesterTwo).attest(hash, policy, validUntil, true);
    expect(await registry.isPlausible(hash)).to.equal(true);
  });

  it('mutation: count a caller-selected work factor as quorum reverts for an unregistered caller', async function () {
    const { registry, outsider } = await deployFixture();
    await expect(registry.connect(outsider).attest(frame('forged'), policy, await expiry(), true))
      .to.be.revertedWith('PlausibilityRegistry: not attester');
  });

  it('mutation: count a duplicate attestation twice toward quorum reverts', async function () {
    const { registry, attesterOne } = await deployFixture();
    const hash = frame('duplicate');
    const validUntil = await expiry();
    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    await expect(registry.connect(attesterOne).attest(hash, policy, validUntil, true))
      .to.be.revertedWith('PlausibilityRegistry: duplicate attestation');
    expect(await registry.isPlausible(hash)).to.equal(false);
  });

  it('mutation: accept a mismatched policy for one frame reverts', async function () {
    const { registry, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('policy');
    const validUntil = await expiry();
    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    await expect(
      registry.connect(attesterTwo).attest(hash, frame('other-policy'), validUntil, true),
    ).to.be.revertedWith('PlausibilityRegistry: policy mismatch');
  });

  it('mutation: ignore negative quorum leaves the frame quarantined', async function () {
    const { registry, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('negative');
    const validUntil = await expiry();
    await registry.connect(attesterOne).attest(hash, policy, validUntil, false);
    await registry.connect(attesterTwo).attest(hash, policy, validUntil, false);
    expect(await registry.isQuarantined(hash)).to.equal(true);
    expect(await registry.isPlausible(hash)).to.equal(false);
  });

  it('mutation: let owner remove an attester below quorum reverts', async function () {
    const [owner, attesterOne, attesterTwo] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory('PlausibilityAttestationRegistry');
    const registry = await Registry.deploy(owner.address);
    await registry.waitForDeployment();
    await registry.addAttester(attesterOne.address);
    await registry.addAttester(attesterTwo.address);
    await registry.setMinimumAttestations(2);

    await expect(registry.connect(owner).removeAttester(attesterOne.address))
      .to.be.revertedWith('PlausibilityRegistry: below quorum');
  });

  it('removing attesters subtracts their prior plausibility and implausibility votes', async function () {
    const { registry, owner, attesterOne, attesterTwo, attesterThree, attesterFour } = await deployFixture();
    const hash = frame('revocation-votes');
    const validUntil = await expiry();

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    await registry.connect(attesterTwo).attest(hash, policy, validUntil, false);
    await registry.connect(attesterThree).attest(hash, policy, validUntil, true);
    await registry.connect(attesterFour).attest(hash, policy, validUntil, false);

    let tally = await registry.getTally(hash);
    expect(tally.plausibleCount).to.equal(2n);
    expect(tally.implausibleCount).to.equal(2n);
    expect(await registry.isPlausible(hash)).to.equal(false);

    await registry.connect(owner).removeAttester(attesterOne.address);
    tally = await registry.getTally(hash);
    expect(tally.plausibleCount).to.equal(1n);
    expect(tally.implausibleCount).to.equal(2n);

    await registry.connect(owner).removeAttester(attesterTwo.address);
    tally = await registry.getTally(hash);
    expect(tally.plausibleCount).to.equal(1n);
    expect(tally.implausibleCount).to.equal(1n);

    expect(await registry.isPlausible(hash)).to.equal(false);
  });

  it('bounded removeAttester is safe after many historical attestations', async function () {
    const { registry, owner, attesterOne } = await deployFixture();
    const validUntil = await expiry();

    for (let i = 0; i < 1800; i++) {
      await registry.connect(attesterOne).attest(frame(`revocation-gas-${i}`), policy, validUntil, true);
    }

    const tx = await registry.connect(owner).removeAttester(attesterOne.address);
    const receipt = await tx.wait();
    expect(receipt.status).to.equal(1);
    expect(receipt.gasUsed).to.be.lt(1_000_000n);
  });

  it('revoked attesters can be re-added and attest again with a clean per-frame vote', async function () {
    const { registry, owner, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('readded-attester');
    const validUntil = await expiry();

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    let tally = await registry.getTally(hash);
    expect(tally.plausibleCount).to.equal(1n);
    expect(tally.implausibleCount).to.equal(0n);

    await registry.connect(owner).removeAttester(attesterOne.address);
    expect(await registry.getTally(hash).then((t) => t.plausibleCount)).to.equal(0n);
    await registry.addAttester(attesterOne.address);
    expect(await registry.minimumAttestations()).to.equal(2);

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    const finalTally = await registry.getTally(hash);
    expect(finalTally.plausibleCount).to.equal(1n);
    expect(finalTally.implausibleCount).to.equal(0n);
    expect(await registry.isPlausible(hash)).to.equal(false);
  });

  it('freezes the frame quorum at first attestation and ignores later global quorum changes', async function () {
    const { registry, owner, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('quorum-snapshot');
    const validUntil = await expiry();

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    await registry.connect(attesterTwo).attest(hash, policy, validUntil, true);
    expect(await registry.isPlausible(hash)).to.equal(true);

    await registry.connect(owner).setMinimumAttestations(1);
    expect(await registry.minimumAttestations()).to.equal(1);
    expect(await registry.isPlausible(hash)).to.equal(true);

    await registry.connect(owner).setMinimumAttestations(4);
    expect(await registry.minimumAttestations()).to.equal(4);
    expect(await registry.isPlausible(hash)).to.equal(true);
  });

  it('lets an owner reset a maliciously anchored frame for recovery', async function () {
    const { registry, owner, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('reset-frame');
    const goodUntil = await expiry();
    const badPolicy = frame('bad-policy');

    await registry.connect(attesterOne).attest(hash, badPolicy, goodUntil, true);
    await expect(registry.connect(attesterTwo).attest(hash, policy, goodUntil, true))
      .to.be.revertedWith('PlausibilityRegistry: policy mismatch');

    await registry.connect(owner).resetFrameTally(hash);
    await registry.connect(attesterOne).attest(hash, policy, goodUntil, true);
    await registry.connect(attesterTwo).attest(hash, policy, goodUntil, true);
    expect(await registry.isPlausible(hash)).to.equal(true);
  });

  it('requires negative-vote threshold to stay below snapshot quorum even when plausible threshold is met', async function () {
    const { registry, owner, attesterOne, attesterTwo, attesterThree, attesterFour } = await deployFixture();
    const hash = frame('mixed-opinion');
    const validUntil = await expiry();

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    await registry.connect(attesterTwo).attest(hash, policy, validUntil, true);
    await registry.connect(attesterThree).attest(hash, policy, validUntil, false);
    await registry.connect(attesterFour).attest(hash, policy, validUntil, false);
    expect(await registry.isPlausible(hash)).to.equal(false);
    expect(await registry.isQuarantined(hash)).to.equal(true);
  });

  it('revokes plausibility for stale attestations after validUntil expires', async function () {
    const { registry, attesterOne, attesterTwo } = await deployFixture();
    const hash = frame('expired-attempt');
    const validUntil = await expiry();

    await registry.connect(attesterOne).attest(hash, policy, validUntil, true);
    await registry.connect(attesterTwo).attest(hash, policy, validUntil, true);
    await time.increaseTo(validUntil + 1n);
    expect(await registry.isPlausible(hash)).to.equal(false);
  });
});
