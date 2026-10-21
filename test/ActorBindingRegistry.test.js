'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('ActorBindingRegistry', function () {
  const ActorClass = { Human: 0, AI: 1, Robot: 2 };
  const ATTESTATION_HASH = ethers.keccak256(ethers.toUtf8Bytes('attestation-001'));
  const ATTESTATION_HASH_2 = ethers.keccak256(ethers.toUtf8Bytes('attestation-002'));
  const THIRTY_DAYS = 30 * 24 * 60 * 60;

  async function deployFixture() {
    const [owner, admin, actor, actor2, actor3, other] = await ethers.getSigners();
    const ActorBindingRegistry = await ethers.getContractFactory('ActorBindingRegistry');
    const registry = await ActorBindingRegistry.deploy();
    const BINDING_ADMIN_ROLE = await registry.BINDING_ADMIN_ROLE();
    await registry.grantRole(BINDING_ADMIN_ROLE, admin.address);
    return { registry, owner, admin, actor, actor2, actor3, other };
  }

  async function bindInEpochOneFixture() {
    const base = await deployFixture();
    await base.registry
      .connect(base.admin)
      .bindActor(base.actor.address, ActorClass.Human, ATTESTATION_HASH, THIRTY_DAYS);
    return base;
  }

  it('binds an attestation to the current epoch', async function () {
    const { registry, admin, actor } = await loadFixture(deployFixture);

    await expect(
      registry
        .connect(admin)
        .bindActor(actor.address, ActorClass.AI, ATTESTATION_HASH, THIRTY_DAYS)
    )
      .to.emit(registry, 'ActorBound')
      .withArgs(actor.address, ActorClass.AI, 1n, ATTESTATION_HASH);

    const binding = await registry.getBinding(actor.address);
    expect(binding.epoch).to.equal(1n);
    expect(await registry.isActiveBound(actor.address)).to.equal(true);
    expect(await registry.isBindingValidForCurrentEpoch(actor.address)).to.equal(true);
  });

  it('rejects a second active attestation in the same epoch', async function () {
    const { registry, admin, actor } = await loadFixture(bindInEpochOneFixture);

    await expect(
      registry
        .connect(admin)
        .bindActor(actor.address, ActorClass.AI, ATTESTATION_HASH_2, THIRTY_DAYS)
    ).to.be.revertedWith('ActorBindingRegistry: already bound');
  });

  it('marks the prior attestation invalid after epoch rotation', async function () {
    const { registry, admin, actor } = await loadFixture(bindInEpochOneFixture);

    await registry.connect(admin).advanceEpoch();

    const binding = await registry.getBinding(actor.address);
    expect(binding.epoch).to.equal(1n);
    expect(await registry.isActiveBound(actor.address)).to.equal(false);
    expect(await registry.isBindingValidForCurrentEpoch(actor.address)).to.equal(false);
  });

  it('allows re-attestation in the new epoch without manual deactivation', async function () {
    const { registry, admin, actor } = await loadFixture(bindInEpochOneFixture);

    await registry.connect(admin).advanceEpoch();

    await expect(
      registry
        .connect(admin)
        .bindActor(actor.address, ActorClass.Robot, ATTESTATION_HASH_2, THIRTY_DAYS)
    )
      .to.emit(registry, 'ActorBound')
      .withArgs(actor.address, ActorClass.Robot, 2n, ATTESTATION_HASH_2);

    const binding = await registry.getBinding(actor.address);
    expect(binding.epoch).to.equal(2n);
    expect(binding.actorClass).to.equal(ActorClass.Robot);
    expect(await registry.isActiveBound(actor.address)).to.equal(true);
  });

  it('preserves old epoch history after re-attestation', async function () {
    const { registry, admin, actor } = await loadFixture(bindInEpochOneFixture);

    await registry.connect(admin).advanceEpoch();
    await registry
      .connect(admin)
      .bindActor(actor.address, ActorClass.AI, ATTESTATION_HASH_2, THIRTY_DAYS);

    expect(await registry.getEpochActors(1n)).to.deep.equal([actor.address]);
    expect(await registry.getEpochActors(2n)).to.deep.equal([actor.address]);
  });

  it('expires bindings by time even within the current epoch', async function () {
    const { registry, actor } = await loadFixture(bindInEpochOneFixture);

    await time.increase(THIRTY_DAYS + 1);
    expect(await registry.isActiveBound(actor.address)).to.equal(false);
  });

  it('treats all actor classes identically for current-epoch validity', async function () {
    const { registry, admin, actor, actor2, actor3 } = await loadFixture(deployFixture);

    await registry
      .connect(admin)
      .bindActor(actor.address, ActorClass.Human, ATTESTATION_HASH, THIRTY_DAYS);
    await registry
      .connect(admin)
      .bindActor(actor2.address, ActorClass.AI, ATTESTATION_HASH, THIRTY_DAYS);
    await registry
      .connect(admin)
      .bindActor(actor3.address, ActorClass.Robot, ATTESTATION_HASH, THIRTY_DAYS);

    expect(await registry.isActiveBound(actor.address)).to.equal(true);
    expect(await registry.isActiveBound(actor2.address)).to.equal(true);
    expect(await registry.isActiveBound(actor3.address)).to.equal(true);
  });
});
