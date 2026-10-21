'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { anyValue } = require('@nomicfoundation/hardhat-chai-matchers/withArgs');

describe('DerivativesEngine liquidation commits', function () {
  async function deployFixture() {
    const [owner, liquidator, attacker, carbonCredits, wrfToken, qualityOracle, amm] =
      await ethers.getSigners();

    const DerivativesEngine = await ethers.getContractFactory('DerivativesEngine');
    // Deployed by `owner` (signers[0]) → owner holds DEFAULT_ADMIN_ROLE and all roles.
    const engine = await DerivativesEngine.deploy(
      carbonCredits.address,
      wrfToken.address,
      qualityOracle.address,
      amm.address
    );

    // commitLiquidation is gated by LIQUIDATOR_ROLE (#149). Grant it to the
    // designated liquidator; `attacker` is intentionally left without the role.
    const LIQUIDATOR_ROLE = await engine.LIQUIDATOR_ROLE();
    await engine.connect(owner).grantRole(LIQUIDATOR_ROLE, liquidator.address);

    return { engine, owner, liquidator, attacker, LIQUIDATOR_ROLE };
  }

  function commitHash(seed = 'position-1:nonce-1:max-price-100') {
    return ethers.keccak256(ethers.toUtf8Bytes(seed));
  }

  // ── #149: access control on commitLiquidation ──────────────────────────────

  it('reverts commitLiquidation for callers without LIQUIDATOR_ROLE (#149)', async function () {
    const { engine, attacker, LIQUIDATOR_ROLE } = await deployFixture();
    const hash = commitHash();

    // Unauthorized EOA can no longer spam unique commit hashes to bloat storage.
    await expect(engine.connect(attacker).commitLiquidation(hash))
      .to.be.revertedWithCustomError(engine, 'AccessControlUnauthorizedAccount')
      .withArgs(attacker.address, LIQUIDATOR_ROLE);

    // Nothing was written for the unauthorized caller.
    expect(await engine.getLiquidationCommit(attacker.address, hash)).to.equal(0n);
  });

  it('allows an authorized liquidator to commit (#149)', async function () {
    const { engine, liquidator } = await deployFixture();
    const hash = commitHash();

    await expect(engine.connect(liquidator).commitLiquidation(hash))
      .to.emit(engine, 'LiquidationCommitted')
      .withArgs(liquidator.address, hash, anyValue);

    expect(await engine.getLiquidationCommit(liquidator.address, hash)).to.not.equal(0n);
  });

  it('reverts commitLiquidation while paused (#149)', async function () {
    const { engine, owner, liquidator } = await deployFixture();
    const hash = commitHash();

    // owner holds EMERGENCY_ROLE → can pause.
    await engine.connect(owner).pause();

    await expect(
      engine.connect(liquidator).commitLiquidation(hash)
    ).to.be.revertedWithCustomError(engine, 'EnforcedPause');

    // Unpausing restores the ability to commit.
    await engine.connect(owner).unpause();
    await expect(engine.connect(liquidator).commitLiquidation(hash))
      .to.emit(engine, 'LiquidationCommitted')
      .withArgs(liquidator.address, hash, anyValue);
  });

  // ── Existing behavior (now under LIQUIDATOR_ROLE) ──────────────────────────

  it('rejects zero liquidation commit hashes', async function () {
    const { engine, liquidator } = await deployFixture();

    await expect(engine.connect(liquidator).commitLiquidation(ethers.ZeroHash)).to.be.revertedWith(
      'Invalid commit hash'
    );
  });

  it('rejects duplicate commits from the same liquidator', async function () {
    const { engine, liquidator } = await deployFixture();
    const hash = commitHash();

    await expect(engine.connect(liquidator).commitLiquidation(hash))
      .to.emit(engine, 'LiquidationCommitted')
      .withArgs(liquidator.address, hash, anyValue);

    await expect(engine.connect(liquidator).commitLiquidation(hash)).to.be.revertedWith(
      'Commit already exists'
    );
  });

  it('keeps commits caller-scoped between two authorized liquidators', async function () {
    const { engine, owner, liquidator, attacker, LIQUIDATOR_ROLE } = await deployFixture();
    const hash = commitHash();

    // Promote `attacker` to a second *authorized* liquidator for this scenario.
    await engine.connect(owner).grantRole(LIQUIDATOR_ROLE, attacker.address);

    await engine.connect(attacker).commitLiquidation(hash);

    // A distinct authorized liquidator committing the same hash is not blocked
    // (commits are keyed per caller), and both records coexist.
    await expect(engine.connect(liquidator).commitLiquidation(hash))
      .to.emit(engine, 'LiquidationCommitted')
      .withArgs(liquidator.address, hash, anyValue);

    expect(await engine.getLiquidationCommit(attacker.address, hash)).to.not.equal(0n);
    expect(await engine.getLiquidationCommit(liquidator.address, hash)).to.not.equal(0n);
  });
});
