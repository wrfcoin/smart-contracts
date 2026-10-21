'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonCreditAMMFactory — focused coverage', function () {
  async function deployFixture() {
    const [admin, creator, outsider] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const tokenA = await MockERC20.deploy('Token A', 'TKA', 18);
    const tokenB = await MockERC20.deploy('Token B', 'TKB', 18);

    const tokenAAddr = await tokenA.getAddress();
    const tokenBAddr = await tokenB.getAddress();
    const [token0, token1] =
      tokenAAddr.toLowerCase() < tokenBAddr.toLowerCase()
        ? [tokenAAddr, tokenBAddr]
        : [tokenBAddr, tokenAAddr];

    const Factory = await ethers.getContractFactory('CarbonCreditAMMFactory');
    const factory = await Factory.deploy();

    return {
      admin,
      creator,
      outsider,
      factory,
      token0,
      token1,
      token0Addr: token0,
      token1Addr: token1,
    };
  }

  it('requires pool creator role for pool creation and canonical input validation', async function () {
    const { factory, token0, token1, creator, outsider, admin } = await loadFixture(deployFixture);
    const feeBasisPoints = 30n;

    await expect(
      factory.connect(outsider).createPool(token0, token1, feeBasisPoints),
    ).to.be.revertedWith('CarbonCreditAMMFactory: FORBIDDEN');

    await expect(
      factory.connect(admin).createPool(token0, token1, feeBasisPoints),
    ).to.not.be.reverted;
    expect(await factory.connect(admin).poolExists(token0, token1, feeBasisPoints)).to.be.true;

    await expect(
      factory.connect(admin).createPool(token0, token1, feeBasisPoints),
    ).to.be.revertedWith('CarbonCreditAMMFactory: POOL_EXISTS');

    await expect(
      factory.connect(admin).createPool(token0, token1, 9999n),
    ).to.be.revertedWith('CarbonCreditAMMFactory: INVALID_FEE_TIER');

    await expect(
      factory.connect(admin).createPool(token0, token0, feeBasisPoints),
    ).to.be.revertedWith('CarbonCreditAMMFactory: IDENTICAL_ADDRESSES');

    await expect(
      factory.connect(admin).createPool(ethers.ZeroAddress, token1, feeBasisPoints),
    ).to.be.revertedWith('CarbonCreditAMMFactory: ZERO_ADDRESS');
  });

  it('guards pause state and pause-role control', async function () {
    const { factory, token0, token1, admin, outsider } = await loadFixture(deployFixture);

    // pause() is onlyRole(DEFAULT_ADMIN_ROLE) — CarbonCreditAMMFactory.sol:355.
    await expect(factory.connect(outsider).pause())
      .to.be.revertedWithCustomError(factory, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await factory.DEFAULT_ADMIN_ROLE());

    await factory.connect(admin).pause();
    // This is the assertion carrying this test's actual claim, and it was the
    // least pinned one in the file. createPool is `nonReentrant whenNotPaused`
    // and then a body `require(hasRole(...), "...FORBIDDEN")` plus checks for
    // IDENTICAL_ADDRESSES and the fee tier (:77-82). A bare `.to.be.reverted`
    // could not tell the pause guard from any of those, so deleting
    // whenNotPaused would not necessarily have failed this test. OpenZeppelin
    // v5 Pausable raises EnforcedPause(), and the modifier runs before the body,
    // so naming it pins the pause guard specifically. The unpause half below
    // uses identical arguments, which is what establishes they are otherwise
    // valid.
    await expect(
      factory.connect(admin).createPool(token0, token1, 30),
    ).to.be.revertedWithCustomError(factory, 'EnforcedPause');

    await factory.connect(admin).unpause();
    await expect(
      factory.connect(admin).createPool(token0, token1, 30),
    ).to.not.be.reverted;
  });

  it('requires fee-setter role for fee tier administration and validates mutation order', async function () {
    const { factory, creator, outsider, admin } = await loadFixture(deployFixture);
    const newFee = 200n;
    const tickSpacing = 300n;
    const existing = 30n;

    // Both are onlyRole(FEE_SETTER_ROLE) — CarbonCreditAMMFactory.sol:170, :210.
    // Pinning the role distinguishes these from the DEFAULT_ADMIN_ROLE gates
    // elsewhere in this file; the factory has three distinct roles.
    const FEE_SETTER_ROLE = await factory.FEE_SETTER_ROLE();

    await expect(factory.connect(outsider).addFeeTier(newFee, tickSpacing))
      .to.be.revertedWithCustomError(factory, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, FEE_SETTER_ROLE);

    // `existing` (30) IS a registered tier, so updateFeeTier's own
    // `require(feeTiers[...] != 0, FEE_TIER_NOT_EXISTS)` (:211) would pass —
    // deleting the role modifier would let this call succeed rather than revert
    // for the other reason. That is what keeps this assertion able to fail.
    await expect(factory.connect(outsider).updateFeeTier(existing, false))
      .to.be.revertedWithCustomError(factory, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, FEE_SETTER_ROLE);

    await factory.connect(admin).addFeeTier(newFee, tickSpacing);
    expect(await factory.feeTiers(newFee)).to.deep.equal([
      newFee,
      tickSpacing,
      true,
    ]);

    await expect(factory.connect(admin).addFeeTier(newFee, tickSpacing))
      .to.be.revertedWith('CarbonCreditAMMFactory: FEE_TIER_EXISTS');

    await expect(factory.connect(admin).updateFeeTier(777n, true))
      .to.be.revertedWith('CarbonCreditAMMFactory: FEE_TIER_NOT_EXISTS');
  });

  it('guards governance and pool-status state transitions', async function () {
    const { factory, token0, token1, admin, outsider, creator } = await loadFixture(deployFixture);

    const validFee = 30n;
    await factory.connect(admin).createPool(token0, token1, validFee);
    const pool = await factory.getPool(token0, token1, validFee);
    expect(pool).to.not.equal(ethers.ZeroAddress);

    // setGovernance and setPoolStatus are both onlyRole(DEFAULT_ADMIN_ROLE) —
    // CarbonCreditAMMFactory.sol:231, :253. Note the contrast with the assertion
    // immediately below: the same function reverts with a STRING for a zero
    // address but a CUSTOM ERROR for an unauthorized caller, which is exactly
    // the distinction a bare `.to.be.reverted` erased.
    const DEFAULT_ADMIN_ROLE = await factory.DEFAULT_ADMIN_ROLE();

    await expect(factory.connect(outsider).setGovernance(creator.address))
      .to.be.revertedWithCustomError(factory, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);

    await expect(factory.connect(admin).setGovernance(ethers.ZeroAddress))
      .to.be.revertedWith('CarbonCreditAMMFactory: ZERO_ADDRESS');

    await expect(factory.connect(admin).setGovernance(creator.address)).to.not.be.reverted;

    await expect(factory.connect(outsider).setPoolStatus(pool, false))
      .to.be.revertedWithCustomError(factory, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);

    await expect(factory.connect(admin).setPoolStatus(pool, false))
      .to.not.be.reverted;
    expect(await factory.isPoolActive(pool)).to.be.false;
  });
});
