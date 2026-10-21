'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('SecureVotingSystem — focused coverage', function () {

  async function deployFixture() {
    const [admin, validator1, validator2, validator3, guardian1, guardian2, guardian3, user] =
      await ethers.getSigners();

    const WRFToken = await ethers.getContractFactory('WRFToken');
    const token = await WRFToken.deploy();

    const TimelockController = await ethers.getContractFactory('TimelockController');
    const timelock = await TimelockController.deploy(
      0,
      [admin.address],
      [admin.address],
      admin.address
    );

    const SecureVotingSystem = await ethers.getContractFactory('SecureVotingSystem');
    const secureVotingSystem = await SecureVotingSystem.deploy(
      await token.getAddress(),
      await timelock.getAddress(),
      admin.address,
      [validator1.address, validator2.address, validator3.address]
    );

    return {
      admin,
      validator1,
      validator2,
      validator3,
      guardian1,
      guardian2,
      guardian3,
      user,
      token,
      timelock,
      secureVotingSystem,
    };
  }

  it('constructor requires at least three validators', async function () {
    const { admin, token, timelock } = await loadFixture(deployFixture);

    const [_, v1, v2] = await ethers.getSigners();
    const TimelockController = await ethers.getContractFactory('TimelockController');
    const secureVotingSystem = await ethers.getContractFactory('SecureVotingSystem');

    await expect(
      secureVotingSystem.deploy(await token.getAddress(), await timelock.getAddress(), admin.address, [
        v1.address,
        v2.address,
      ])
    ).to.be.revertedWith('Minimum 3 validators required');
  });

  it('validates validator-only gates for timestamp approval', async function () {
    const {
      validator1,
      user,
      secureVotingSystem,
    } = await loadFixture(deployFixture);

    await expect(
      secureVotingSystem.connect(user).validateProposalTimestamps(1n, true, 'not allowed')
    ).to.be.revertedWithCustomError(secureVotingSystem, 'UnauthorizedValidator');

    await expect(
      secureVotingSystem.connect(validator1).validateProposalTimestamps(1n, true, 'proposal missing')
    ).to.be.revertedWith('Proposal not found');
  });

  it('rejects emergency pause from non-guardians and requires threshold signatures', async function () {
    const {
      admin,
      guardian1,
      guardian2,
      guardian3,
      user,
      secureVotingSystem,
    } = await loadFixture(deployFixture);

    const GUARDIAN_ROLE = await secureVotingSystem.GUARDIAN_ROLE();

    // onlyRole(GUARDIAN_ROLE) — SecureVotingSystem.sol:692. The system is not already
    // in global pause, so the `Already in global pause` require (:693) cannot fire.
    // GUARDIAN_ROLE is already read into scope on the line above.
    await expect(secureVotingSystem.connect(user).activateGlobalEmergencyPause('manual panic'))
      .to.be.revertedWithCustomError(secureVotingSystem, 'AccessControlUnauthorizedAccount')
      .withArgs(user.address, GUARDIAN_ROLE);

    await secureVotingSystem.connect(admin).grantRole(GUARDIAN_ROLE, guardian1.address);
    await secureVotingSystem.connect(admin).grantRole(GUARDIAN_ROLE, guardian2.address);
    await secureVotingSystem.connect(admin).grantRole(GUARDIAN_ROLE, guardian3.address);

    await secureVotingSystem.connect(guardian1).activateGlobalEmergencyPause('manual pause');
    await secureVotingSystem.connect(guardian2).activateGlobalEmergencyPause('manual pause');
    expect(await secureVotingSystem.paused()).to.equal(false);

    await secureVotingSystem.connect(guardian3).activateGlobalEmergencyPause('manual pause');
    expect(await secureVotingSystem.paused()).to.equal(true);

    const emergency = await secureVotingSystem.emergencySystem();
    expect(emergency.globalPause).to.equal(true);
  });

  it('blocks oracle registration from non-managers and caps tolerance', async function () {
    const { admin, validator1, user, secureVotingSystem } = await loadFixture(deployFixture);

    // onlyRole(ORACLE_MANAGER_ROLE) — SecureVotingSystem.sol:714-718. validator1 is a
    // non-zero address and tolerance 60 is under the cap, so both body requires would
    // pass and the role gate is the only rejection. A different role from the
    // GUARDIAN_ROLE gate in the test above.
    await expect(
      secureVotingSystem.connect(user).addTimeOracle(validator1.address, 60, 1)
    )
      .to.be.revertedWithCustomError(secureVotingSystem, 'AccessControlUnauthorizedAccount')
      .withArgs(user.address, await secureVotingSystem.ORACLE_MANAGER_ROLE());

    await expect(
      secureVotingSystem
        .connect(admin)
        .addTimeOracle(validator1.address, 2_000_000_000n, 1)
    ).to.be.revertedWith('Tolerance too high');
  });
});
