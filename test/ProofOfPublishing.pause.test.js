'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

// #165 — ProofOfPublishing emergency-stop / pause coverage.
describe('ProofOfPublishing emergency pause (#165)', function () {
  async function deployFixture() {
    const [deployer, governance, oracle, publisher, outsider] = await ethers.getSigners();

    const PoP = await ethers.getContractFactory('ProofOfPublishing');
    // constructor(oracleNetwork, governance)
    const pop = await PoP.deploy(oracle.address, governance.address);
    await pop.waitForDeployment();

    return { pop, governance, oracle, publisher, outsider };
  }

  async function futureTs(deltaSeconds = 3600) {
    return (await time.latest()) + deltaSeconds;
  }

  // ── pause() / unpause() authorization ──────────────────────────────────────

  it('lets governance pause and unpause', async function () {
    const { pop, governance } = await deployFixture();

    expect(await pop.paused()).to.equal(false);

    await expect(pop.connect(governance).pause())
      .to.emit(pop, 'Paused')
      .withArgs(governance.address);
    expect(await pop.paused()).to.equal(true);

    await expect(pop.connect(governance).unpause())
      .to.emit(pop, 'Unpaused')
      .withArgs(governance.address);
    expect(await pop.paused()).to.equal(false);
  });

  it('reverts pause for non-governance callers', async function () {
    const { pop, oracle, outsider } = await deployFixture();

    await expect(pop.connect(outsider).pause()).to.be.revertedWith('Only governance can execute');
    // Even the oracle (the other privileged address) cannot pause.
    await expect(pop.connect(oracle).pause()).to.be.revertedWith('Only governance can execute');
  });

  it('reverts unpause for non-governance callers', async function () {
    const { pop, governance, outsider } = await deployFixture();
    await pop.connect(governance).pause();

    await expect(pop.connect(outsider).unpause()).to.be.revertedWith(
      'Only governance can execute'
    );
  });

  // ── gated value-flow functions revert while paused ─────────────────────────

  it('blocks fundRewardPool while paused and allows it after unpause', async function () {
    const { pop, governance, outsider } = await deployFixture();
    await pop.connect(governance).pause();

    await expect(
      pop.connect(outsider).fundRewardPool({ value: ethers.parseEther('1') })
    ).to.be.revertedWithCustomError(pop, 'EnforcedPause');

    await pop.connect(governance).unpause();
    await expect(
      pop.connect(outsider).fundRewardPool({ value: ethers.parseEther('1') })
    ).to.not.be.reverted;
    expect(await pop.rewardPool()).to.equal(ethers.parseEther('1'));
  });

  it('blocks publishForecast while paused and allows it after unpause', async function () {
    const { pop, governance, publisher } = await deployFixture();
    // Other suites can advance the EVM clock far beyond wall time.
    await time.increase(365 * 24 * 60 * 60);
    await pop.connect(governance).pause();

    await expect(
      pop.connect(publisher).publishForecast('NYC', 'temperature', 'ipfs://hash', await futureTs())
    ).to.be.revertedWithCustomError(pop, 'EnforcedPause');

    await pop.connect(governance).unpause();
    await expect(
      pop.connect(publisher).publishForecast('NYC', 'temperature', 'ipfs://hash', await futureTs())
    ).to.emit(pop, 'ForecastPublished');
  });

  it('blocks the oracle reward path (verifyAndReward) while paused', async function () {
    const { pop, governance, oracle } = await deployFixture();
    await pop.connect(governance).pause();

    // whenNotPaused runs after onlyOracle, so an authorized oracle still hits
    // EnforcedPause before the function body executes.
    await expect(
      pop.connect(oracle).verifyAndReward(ethers.ZeroHash, 8000, [])
    ).to.be.revertedWithCustomError(pop, 'EnforcedPause');
  });
});
