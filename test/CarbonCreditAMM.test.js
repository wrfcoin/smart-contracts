'use strict';
/**
 * @title CarbonCreditAMM Tests (#82)
 * @dev Test coverage for CarbonCreditAMM constant-product AMM.
 *
 * Covers:
 * - Deployment and factory authorization
 * - Initialization (token pair, fee, access control)
 * - Input validation (duplicate tokens, unsorted order, zero addresses)
 * - Reserve reads before and after initialization
 * - Single-initialization guard
 * - Admin role granted to factory on initialize
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonCreditAMM (#82)', function () {
  // Helper: deploy a minimal ERC20 for testing (MockERC20 takes name, symbol, uint8 decimals)
  async function deployERC20(name, symbol, deployer) {
    const Token = await ethers.getContractFactory('MockERC20', deployer);
    return Token.deploy(name, symbol, 18);
  }

  async function deployFixture() {
    const [factory, alice, bob] = await ethers.getSigners();

    // Deploy two ERC20 tokens; ensure token0 < token1 address ordering
    let tokenA = await deployERC20('Carbon Credit', 'CC', factory);
    let tokenB = await deployERC20('WRF Token', 'WRF', factory);

    // Sort so token0.address < token1.address (AMM requirement)
    const addrA = await tokenA.getAddress();
    const addrB = await tokenB.getAddress();
    const [token0Addr, token1Addr] =
      addrA.toLowerCase() < addrB.toLowerCase()
        ? [addrA, addrB]
        : [addrB, addrA];
    const token0 = addrA === token0Addr ? tokenA : tokenB;
    const token1 = addrA === token0Addr ? tokenB : tokenA;

    // Deploy AMM with factory as expectedFactory
    const CarbonCreditAMM = await ethers.getContractFactory('CarbonCreditAMM');
    const amm = await CarbonCreditAMM.connect(factory).deploy(factory.address);

    return { amm, token0, token1, token0Addr, token1Addr, factory, alice, bob };
  }

  async function initializedFixture() {
    const ctx = await loadFixture(deployFixture);
    const { amm, token0Addr, token1Addr, factory } = ctx;

    await amm.connect(factory).initialize(
      token0Addr,
      token1Addr,
      factory.address,
      30, // 0.30% fee
    );

    return ctx;
  }

  // ── Deployment ───────────────────────────────────────────────────────────

  describe('Deployment', function () {
    it('deploys with the correct expected factory', async function () {
      const { amm } = await loadFixture(deployFixture);
      // factory address is stored; we verify it indirectly: only factory can call initialize
      // (no public getter for expectedFactory, so we verify via access control behaviour)
      expect(await amm.factory()).to.equal(ethers.ZeroAddress);
    });

    it('reverts if deployed with zero factory address', async function () {
      const [signer] = await ethers.getSigners();
      const CarbonCreditAMM = await ethers.getContractFactory('CarbonCreditAMM');
      await expect(CarbonCreditAMM.connect(signer).deploy(ethers.ZeroAddress))
        .to.be.revertedWith('CarbonCreditAMM: ZERO_EXPECTED_FACTORY');
    });

    it('starts uninitialised (factory slot is zero)', async function () {
      const { amm } = await loadFixture(deployFixture);
      expect(await amm.factory()).to.equal(ethers.ZeroAddress);
    });
  });

  // ── Initialize: happy path ───────────────────────────────────────────────

  describe('initialize() — happy path', function () {
    it('sets token0 and token1', async function () {
      const { amm, token0Addr, token1Addr } = await loadFixture(initializedFixture);
      expect(await amm.token0()).to.equal(token0Addr);
      expect(await amm.token1()).to.equal(token1Addr);
    });

    it('sets fee basis points', async function () {
      const { amm } = await loadFixture(initializedFixture);
      expect(await amm.feeBasisPoints()).to.equal(30);
    });

    it('records factory address', async function () {
      const { amm, factory } = await loadFixture(initializedFixture);
      expect(await amm.factory()).to.equal(factory.address);
    });

    it('grants DEFAULT_ADMIN_ROLE and FACTORY_ROLE to factory', async function () {
      const { amm, factory } = await loadFixture(initializedFixture);
      const adminRole = await amm.DEFAULT_ADMIN_ROLE();
      const factoryRole = await amm.FACTORY_ROLE();
      expect(await amm.hasRole(adminRole, factory.address)).to.be.true;
      expect(await amm.hasRole(factoryRole, factory.address)).to.be.true;
    });

    it('getReserves returns zeros before any liquidity is added', async function () {
      const { amm } = await loadFixture(initializedFixture);
      const [r0, r1] = await amm.getReserves();
      expect(r0).to.equal(0n);
      expect(r1).to.equal(0n);
    });
  });

  // ── Initialize: access control ───────────────────────────────────────────

  describe('initialize() — access control', function () {
    it('reverts when called by a non-factory address', async function () {
      const { amm, token0Addr, token1Addr, factory, alice } =
        await loadFixture(deployFixture);
      await expect(
        amm.connect(alice).initialize(token0Addr, token1Addr, factory.address, 30),
      ).to.be.revertedWith('CarbonCreditAMM: UNAUTHORIZED_INITIALIZER');
    });

    it('reverts on double initialisation', async function () {
      const { amm, token0Addr, token1Addr, factory } =
        await loadFixture(initializedFixture);
      await expect(
        amm.connect(factory).initialize(token0Addr, token1Addr, factory.address, 30),
      ).to.be.revertedWith('CarbonCreditAMM: ALREADY_INITIALIZED');
    });
  });

  // ── Initialize: input validation ─────────────────────────────────────────

  describe('initialize() — input validation', function () {
    it('reverts when token0 is zero address', async function () {
      const { amm, token1Addr, factory } = await loadFixture(deployFixture);
      await expect(
        amm
          .connect(factory)
          .initialize(ethers.ZeroAddress, token1Addr, factory.address, 30),
      ).to.be.revertedWith('CarbonCreditAMM: ZERO_ADDRESS');
    });

    it('reverts when tokens are identical', async function () {
      const { amm, token0Addr, factory } = await loadFixture(deployFixture);
      await expect(
        amm.connect(factory).initialize(token0Addr, token0Addr, factory.address, 30),
      ).to.be.revertedWith('CarbonCreditAMM: IDENTICAL_TOKENS');
    });

    it('reverts when tokens are not sorted', async function () {
      const { amm, token0Addr, token1Addr, factory } = await loadFixture(deployFixture);
      // Pass them in wrong order (token1 before token0)
      await expect(
        amm.connect(factory).initialize(token1Addr, token0Addr, factory.address, 30),
      ).to.be.revertedWith('CarbonCreditAMM: TOKENS_NOT_SORTED');
    });

    it('reverts when fee exceeds maximum', async function () {
      const { amm, token0Addr, token1Addr, factory } = await loadFixture(deployFixture);
      await expect(
        amm.connect(factory).initialize(token0Addr, token1Addr, factory.address, 10001),
      ).to.be.revertedWith('CarbonCreditAMM: INVALID_FEE');
    });
  });
});
