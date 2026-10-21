'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('WeightedCarbonPool — focused coverage', function () {
  const ZERO_ADDRESS = ethers.ZeroAddress;
  const LOCKED_LIQUIDITY_ADDRESS = '0x000000000000000000000000000000000000dEaD';
  const BONE = 10n ** 18n;
  const MIN_LIQUIDITY_REQUIRED = 1000n * 10n ** 6n;
  const MIN_LIQUIDITY = 1000n;

  async function deployFixture() {
    const [admin, provider, outsider] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);
    const cbt = await MockERC20.deploy('Carbon Basket Token', 'CBT', 6);

    const pool = await ethers.getContractFactory('WeightedCarbonPool');
    const weightedPool = await pool.deploy();

    await weightedPool.initialize(
      await usdc.getAddress(),
      await cbt.getAddress(),
      5n * 10n ** 17n,
      5n * 10n ** 17n,
      30n,
      ZERO_ADDRESS,
      ZERO_ADDRESS,
      admin.address
    );

    return {
      admin,
      provider,
      outsider,
      usdc,
      cbt,
      weightedPool,
    };
  }

  async function fundForInitialLiquidity({ weightedPool, provider, usdc, cbt, usdcAmount, cbtAmount }) {
    await usdc.mint(await provider.getAddress(), usdcAmount);
    await cbt.mint(await provider.getAddress(), cbtAmount);
    await usdc.connect(provider).approve(await weightedPool.getAddress(), usdcAmount);
    await cbt.connect(provider).approve(await weightedPool.getAddress(), cbtAmount);
  }

  it('validates initializer inputs and records critical configuration', async function () {
    const { admin, usdc, cbt } = await loadFixture(deployFixture);
    const pool = await ethers.getContractFactory('WeightedCarbonPool');
    const weightedPool = await pool.deploy();

    await expect(
      weightedPool.initialize(
        ZERO_ADDRESS,
        await cbt.getAddress(),
        5n * 10n ** 17n,
        5n * 10n ** 17n,
        30n,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        admin.address
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid USDC');

    await expect(
      weightedPool.initialize(
        await usdc.getAddress(),
        ZERO_ADDRESS,
        5n * 10n ** 17n,
        5n * 10n ** 17n,
        30n,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        admin.address
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid CBT');

    await expect(
      weightedPool.initialize(
        await usdc.getAddress(),
        await cbt.getAddress(),
        0n,
        5n * 10n ** 17n,
        30n,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        admin.address
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid weights');

    await expect(
      weightedPool.initialize(
        await usdc.getAddress(),
        await cbt.getAddress(),
        5n * 10n ** 17n,
        5n * 10n ** 17n,
        4n,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        admin.address
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid fee');
  });

  it('requires manager-only access to admin controls', async function () {
    const { admin, outsider, weightedPool } = await loadFixture(deployFixture);

    await expect(
      weightedPool.connect(outsider).updateWeights(6n * 10n ** 17n, 4n * 10n ** 17n)
    ).to.be.revertedWith('WeightedCarbonPool: Only manager');

    await weightedPool.connect(admin).updateWeights(6n * 10n ** 17n, 4n * 10n ** 17n);
    expect(await weightedPool.getWeights()).to.deep.equal([6n * 10n ** 17n, 4n * 10n ** 17n]);

    await expect(
      weightedPool.connect(outsider).setSwapFee(60n)
    ).to.be.revertedWith('WeightedCarbonPool: Only manager');

    await weightedPool.connect(admin).setSwapFee(60n);
    expect(await weightedPool.swapFee()).to.equal(60n);

    await expect(
      weightedPool.connect(outsider).pause()
    ).to.be.revertedWith('WeightedCarbonPool: Only manager');

    await expect(
      weightedPool.connect(outsider).collectProtocolFees(admin.address)
    ).to.be.revertedWith('WeightedCarbonPool: Only manager');
  });

  it('rejects invalid admin recipient for protocol fee collection', async function () {
    const { admin, weightedPool } = await loadFixture(deployFixture);

    await expect(
      weightedPool.connect(admin).collectProtocolFees(ZERO_ADDRESS)
    ).to.be.revertedWith('WeightedCarbonPool: Invalid recipient');
  });

  it('enforces first-liquidity invariants on addLiquidity', async function () {
    const { provider, usdc, cbt, weightedPool } = await loadFixture(deployFixture);

    const block = await ethers.provider.getBlock('latest');
    const deadline = BigInt(block.timestamp) + 3600n;

    await fundForInitialLiquidity({
      weightedPool,
      provider,
      usdc,
      cbt,
      usdcAmount: MIN_LIQUIDITY_REQUIRED - 1n,
      cbtAmount: MIN_LIQUIDITY_REQUIRED - 1n,
    });

    await expect(
      weightedPool.connect(provider).addLiquidity(
        MIN_LIQUIDITY_REQUIRED - 1n,
        MIN_LIQUIDITY_REQUIRED - 1n,
        1n,
        deadline
      )
    ).to.be.revertedWith('WeightedCarbonPool: Insufficient initial liquidity');

    await fundForInitialLiquidity({
      weightedPool,
      provider,
      usdc,
      cbt,
      usdcAmount: MIN_LIQUIDITY_REQUIRED,
      cbtAmount: 0n,
    });

    await expect(
      weightedPool.connect(provider).addLiquidity(MIN_LIQUIDITY_REQUIRED, 0n, 1n, deadline)
    ).to.be.revertedWith('WeightedCarbonPool: Both tokens required');

    await expect(
      weightedPool.connect(provider).addLiquidity(
        0n,
        0n,
        1n,
        deadline
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid amounts');
  });

  it('bootstraps the pool while permanently locking the minimum liquidity', async function () {
    const { provider, usdc, cbt, weightedPool } = await loadFixture(deployFixture);
    const providerAddress = await provider.getAddress();
    const poolAddress = await weightedPool.getAddress();
    const expectedSupply = MIN_LIQUIDITY_REQUIRED;
    const expectedProviderLiquidity = expectedSupply - MIN_LIQUIDITY;
    const block = await ethers.provider.getBlock('latest');
    const deadline = BigInt(block.timestamp) + 3600n;

    await fundForInitialLiquidity({
      weightedPool,
      provider,
      usdc,
      cbt,
      usdcAmount: MIN_LIQUIDITY_REQUIRED,
      cbtAmount: MIN_LIQUIDITY_REQUIRED,
    });

    await expect(
      weightedPool.connect(provider).addLiquidity(
        MIN_LIQUIDITY_REQUIRED,
        MIN_LIQUIDITY_REQUIRED,
        expectedProviderLiquidity,
        deadline
      )
    )
      .to.emit(weightedPool, 'LiquidityAdded')
      .withArgs(
        providerAddress,
        MIN_LIQUIDITY_REQUIRED,
        MIN_LIQUIDITY_REQUIRED,
        expectedProviderLiquidity
      );

    expect(await weightedPool.balanceOf(ZERO_ADDRESS)).to.equal(0n);
    expect(await weightedPool.balanceOf(LOCKED_LIQUIDITY_ADDRESS)).to.equal(MIN_LIQUIDITY);
    expect(await weightedPool.balanceOf(providerAddress)).to.equal(expectedProviderLiquidity);
    expect(await weightedPool.totalSupply()).to.equal(expectedSupply);
    expect(await weightedPool.totalLiquidity()).to.equal(expectedSupply);

    await weightedPool.connect(provider).removeLiquidity(
      expectedProviderLiquidity,
      0n,
      0n,
      deadline
    );

    expect(await weightedPool.totalSupply()).to.equal(MIN_LIQUIDITY);
    expect(await weightedPool.balanceOf(LOCKED_LIQUIDITY_ADDRESS)).to.equal(MIN_LIQUIDITY);
    expect(await usdc.balanceOf(poolAddress)).to.be.greaterThan(0n);
    expect(await cbt.balanceOf(poolAddress)).to.be.greaterThan(0n);
  });

  it('preserves LP supply accounting across subsequent proportional deposits', async function () {
    const { provider, outsider, usdc, cbt, weightedPool } = await loadFixture(deployFixture);
    const initialSupply = MIN_LIQUIDITY_REQUIRED;
    const subsequentAmount = 100n * 10n ** 6n;
    const block = await ethers.provider.getBlock('latest');
    const deadline = BigInt(block.timestamp) + 3600n;

    await fundForInitialLiquidity({
      weightedPool,
      provider,
      usdc,
      cbt,
      usdcAmount: MIN_LIQUIDITY_REQUIRED,
      cbtAmount: MIN_LIQUIDITY_REQUIRED,
    });
    await weightedPool.connect(provider).addLiquidity(
      MIN_LIQUIDITY_REQUIRED,
      MIN_LIQUIDITY_REQUIRED,
      initialSupply - MIN_LIQUIDITY,
      deadline
    );

    await fundForInitialLiquidity({
      weightedPool,
      provider: outsider,
      usdc,
      cbt,
      usdcAmount: subsequentAmount,
      cbtAmount: subsequentAmount,
    });
    await weightedPool.connect(outsider).addLiquidity(
      subsequentAmount,
      subsequentAmount,
      subsequentAmount,
      deadline
    );

    expect(await weightedPool.balanceOf(outsider.address)).to.equal(subsequentAmount);
    expect(await weightedPool.totalSupply()).to.equal(initialSupply + subsequentAmount);
    expect(await weightedPool.totalLiquidity()).to.equal(await weightedPool.totalSupply());
    expect(
      await weightedPool.balanceOf(provider.address) +
        await weightedPool.balanceOf(outsider.address) +
        await weightedPool.balanceOf(LOCKED_LIQUIDITY_ADDRESS)
    ).to.equal(await weightedPool.totalSupply());
  });

  it('binds pause to all state-mutating protected operations', async function () {
    const { admin, outsider, provider, usdc, cbt, weightedPool } = await loadFixture(deployFixture);

    await fundForInitialLiquidity({
      weightedPool,
      provider,
      usdc,
      cbt,
      usdcAmount: MIN_LIQUIDITY_REQUIRED,
      cbtAmount: MIN_LIQUIDITY_REQUIRED,
    });

    await weightedPool.connect(admin).pause();
    expect(await weightedPool.paused()).to.equal(true);

    await expect(
      weightedPool.connect(outsider).pause()
    ).to.be.revertedWith('WeightedCarbonPool: Only manager');

    await weightedPool.connect(admin).unpause();
    expect(await weightedPool.paused()).to.equal(false);

    const block = await ethers.provider.getBlock('latest');
    const deadline = BigInt(block.timestamp) + 3600n;

    await expect(
      weightedPool.connect(provider).addLiquidity(MIN_LIQUIDITY_REQUIRED, MIN_LIQUIDITY_REQUIRED, 1n, deadline)
    ).to.emit(weightedPool, 'LiquidityAdded');

    await expect(
      weightedPool.connect(outsider).unpause()
    ).to.be.revertedWith('WeightedCarbonPool: Only manager');
  });

  it('rejects swap calls from outside token path assumptions', async function () {
    const { outsider, weightedPool, usdc } = await loadFixture(deployFixture);

    const block = await ethers.provider.getBlock('latest');
    const deadline = BigInt(block.timestamp) + 3600n;

    await expect(
      weightedPool.connect(outsider).swapExactTokensForTokens(
        await usdc.getAddress(),
        outsider.address,
        1n,
        1n,
        outsider.address,
        deadline
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid token pair');
  });
});
