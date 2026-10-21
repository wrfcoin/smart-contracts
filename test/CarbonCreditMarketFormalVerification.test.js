'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonCreditMarketFormalVerification', function () {
  const FEE_BASIS_POINTS = 30;
  const LIQUIDITY = ethers.parseEther('100000');
  const SAMPLE_AMOUNT_IN = ethers.parseEther('250');

  async function deployMarketFixture() {
    const [deployer] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const usdc = await MockERC20.deploy('USD Coin', 'USDC', 18);
    const carbon = await MockERC20.deploy('Carbon Basket Token', 'CBT', 18);

    const usdcAddress = await usdc.getAddress();
    const carbonAddress = await carbon.getAddress();
    const [token0Address, token1Address] =
      usdcAddress.toLowerCase() < carbonAddress.toLowerCase()
        ? [usdcAddress, carbonAddress]
        : [carbonAddress, usdcAddress];

    const token0 = token0Address === usdcAddress ? usdc : carbon;
    const token1 = token1Address === usdcAddress ? usdc : carbon;

    const CarbonCreditAMMFormalHarness = await ethers.getContractFactory(
      'CarbonCreditAMMFormalHarness'
    );
    const amm = await CarbonCreditAMMFormalHarness.deploy(deployer.address);
    const poolAddress = await amm.getAddress();

    await amm.initialize(
      token0Address,
      token1Address,
      deployer.address,
      FEE_BASIS_POINTS
    );
    await amm.seedReserves(LIQUIDITY, LIQUIDITY);

    const LiquidityPoolManager = await ethers.getContractFactory(
      'LiquidityPoolManager'
    );
    const manager = await LiquidityPoolManager.deploy(
      usdcAddress,
      usdcAddress,
      deployer.address
    );

    const CarbonPoolRouter = await ethers.getContractFactory('CarbonPoolRouter');
    const router = await CarbonPoolRouter.deploy(
      await manager.getAddress(),
      deployer.address,
      usdcAddress
    );

    await router.addPool(poolAddress, 2, token0Address, token1Address);

    const FormalVerification = await ethers.getContractFactory(
      'CarbonCreditMarketFormalVerification'
    );
    const verifier = await FormalVerification.deploy();

    return {
      deployer,
      poolAddress,
      router,
      token0Address,
      token1Address,
      usdcAddress,
      verifier,
    };
  }

  it('confirms AMM configuration and pricing bounds', async function () {
    const { verifier, poolAddress } = await loadFixture(deployMarketFixture);

    expect(await verifier.verifyAmmConfiguration(poolAddress)).to.equal(true);
    expect(
      await verifier.verifyAmmPricingBounds(poolAddress, SAMPLE_AMOUNT_IN)
    ).to.equal(true);
  });

  it('confirms router pair symmetry and route shape', async function () {
    const { router, token0Address, token1Address, verifier } = await loadFixture(
      deployMarketFixture
    );

    expect(
      await verifier.verifyRouterPairSymmetry(
        await router.getAddress(),
        token0Address,
        token1Address
      )
    ).to.equal(true);

    expect(
      await verifier.verifyRouterRouteShape(
        await router.getAddress(),
        token0Address,
        token1Address,
        SAMPLE_AMOUNT_IN
      )
    ).to.equal(true);
  });

  it('rejects invalid inputs as counterexamples', async function () {
    const { router, token0Address, token1Address, verifier } = await loadFixture(
      deployMarketFixture
    );

    expect(
      await verifier.verifyAmmConfiguration(ethers.ZeroAddress)
    ).to.equal(false);

    expect(
      await verifier.verifyRouterRouteShape(
        await router.getAddress(),
        token0Address,
        token1Address,
        0
      )
    ).to.equal(false);
  });
});
