'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('ParametricInsurance', function () {
  const REGION_ID = ethers.id('texas-hill-country');
  const STATION_ID = ethers.id('station-austin-1');
  const ONE_DAY = 24 * 60 * 60;

  function weatherData(overrides = {}) {
    return {
      temperature: 3100,
      humidity: 5400,
      pressure: 100950,
      windSpeed: 2200,
      rainfall: 0,
      timestamp: overrides.timestamp ?? 0,
      stationId: STATION_ID,
      confidence: 95,
      ...overrides,
    };
  }

  async function deployFixture() {
    const [admin, poolManager, liquidityProvider, buyer, stranger] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const token = await MockERC20.deploy('Wrapped WRF', 'wWRF', 18);

    const WeatherDataValidator = await ethers.getContractFactory('WeatherDataValidator');
    const oracle = await WeatherDataValidator.deploy();

    const ParametricInsurance = await ethers.getContractFactory('ParametricInsurance');
    const insurance = await ParametricInsurance.deploy(await token.getAddress(), admin.address);

    await insurance.connect(admin).grantRole(await insurance.POOL_MANAGER_ROLE(), poolManager.address);

    const mintAmount = ethers.parseEther('100000');
    await token.mint(liquidityProvider.address, mintAmount);
    await token.mint(buyer.address, mintAmount);

    await oracle.addWeatherStation(STATION_ID, 'Austin, TX');
    await oracle.setStationCoordinates(STATION_ID, ethers.id('29.7604,-95.3698'));

    return {
      admin,
      poolManager,
      liquidityProvider,
      buyer,
      stranger,
      token,
      oracle,
      insurance,
    };
  }

  async function configurePoolFixture() {
    const ctx = await loadFixture(deployFixture);
    const { poolManager, liquidityProvider, token, oracle, insurance } = ctx;

    await insurance.connect(poolManager).createPool(
      REGION_ID,
      STATION_ID,
      await oracle.getAddress(),
      4500,
      3300,
      15000,
      500,
      ethers.parseEther('1000'),
      ONE_DAY,
      10
    );
    ctx.poolId = 1n;

    const fundAmount = ethers.parseEther('20000');
    await token.connect(liquidityProvider).approve(await insurance.getAddress(), fundAmount);
    await insurance.connect(liquidityProvider).fundPool(ctx.poolId, fundAmount);

    return ctx;
  }

  describe('pool creation', function () {
    it('creates a pool and exposes the configured thresholds', async function () {
      const { insurance, poolManager, oracle } = await loadFixture(deployFixture);

      await expect(
        insurance.connect(poolManager).createPool(
          REGION_ID,
          STATION_ID,
          await oracle.getAddress(),
          4500,
          3300,
          15000,
          500,
          ethers.parseEther('1000'),
          ONE_DAY,
          10
        )
      ).to.emit(insurance, 'PoolCreated');

      const [regionId, stationId, oracleAddress, tempThreshold, windThreshold, payoutBps, premiumBps] =
        await insurance.getPool(1);

      expect(regionId).to.equal(REGION_ID);
      expect(stationId).to.equal(STATION_ID);
      expect(oracleAddress).to.equal(await oracle.getAddress());
      expect(tempThreshold).to.equal(4500n);
      expect(windThreshold).to.equal(3300n);
      expect(payoutBps).to.equal(15000n);
      expect(premiumBps).to.equal(500n);
    });

    it('rejects invalid pool thresholds', async function () {
      const { insurance, poolManager, oracle } = await loadFixture(deployFixture);

      await expect(
        insurance.connect(poolManager).createPool(
          REGION_ID,
          STATION_ID,
          await oracle.getAddress(),
          0,
          0,
          15000,
          500,
          ethers.parseEther('1000'),
          ONE_DAY,
          10
        )
      ).to.be.revertedWithCustomError(insurance, 'ParametricInsuranceInvalidThreshold');
    });

    it('only the pool manager can create pools', async function () {
      const { insurance, stranger, oracle } = await loadFixture(deployFixture);

      await expect(
        insurance.connect(stranger).createPool(
          REGION_ID,
          STATION_ID,
          await oracle.getAddress(),
          4500,
          3300,
          15000,
          500,
          ethers.parseEther('1000'),
          ONE_DAY,
          10
        )
      ).to.be.revertedWithCustomError(insurance, 'AccessControlUnauthorizedAccount');
    });
  });

  describe('premium deposits', function () {
    it('accepts premium deposits and reserves payout capacity', async function () {
      const { insurance, buyer, token, poolId } = await loadFixture(configurePoolFixture);

      const coverageAmount = ethers.parseEther('1000');
      const premium = (coverageAmount * 500n) / 10_000n;
      const payout = (coverageAmount * 15000n) / 10_000n;

      await token.connect(buyer).approve(await insurance.getAddress(), premium);
      await expect(insurance.connect(buyer).buyCoverage(poolId, coverageAmount))
        .to.emit(insurance, 'CoveragePurchased')
        .withArgs(1, poolId, buyer.address, coverageAmount, premium, payout);

      const [, , , , , , , , , , liquidity, reservedLiability, totalPremiums, , policyCount] =
        await insurance.getPool(poolId);
      expect(liquidity).to.equal(ethers.parseEther('20000') + premium);
      expect(reservedLiability).to.equal(payout);
      expect(totalPremiums).to.equal(premium);
      expect(policyCount).to.equal(1n);
    });

    it('rejects coverage larger than the pool maximum', async function () {
      const { insurance, buyer, token, poolId } = await loadFixture(configurePoolFixture);
      const coverageAmount = ethers.parseEther('5000');

      await token.connect(buyer).approve(await insurance.getAddress(), ethers.parseEther('300'));
      await expect(insurance.connect(buyer).buyCoverage(poolId, coverageAmount))
        .to.be.revertedWithCustomError(insurance, 'ParametricInsuranceCoverageTooLarge');
    });
  });

  describe('automatic payout', function () {
    it('does not settle before the threshold is crossed', async function () {
      const { insurance, buyer, token, oracle, poolId } = await loadFixture(configurePoolFixture);

      const coverageAmount = ethers.parseEther('1000');
      const premium = (coverageAmount * 500n) / 10_000n;
      await token.connect(buyer).approve(await insurance.getAddress(), premium);
      await insurance.connect(buyer).buyCoverage(poolId, coverageAmount);

      await oracle.updateWeatherData(
        STATION_ID,
        weatherData({
          timestamp: await time.latest(),
          temperature: 3200,
          windSpeed: 2500,
        })
      );

      const result = await insurance.evaluateAndSettle.staticCall(poolId);
      expect(result[0]).to.equal(false);

      const [, , , , , , , , , , , , , , , , , active, settled] = await insurance.getPool(poolId);
      expect(active).to.equal(true);
      expect(settled).to.equal(false);
    });

    it('automatically pays out when temperature crosses the threshold', async function () {
      const { insurance, buyer, token, oracle, poolId } = await loadFixture(configurePoolFixture);

      const coverageAmount = ethers.parseEther('1000');
      const premium = (coverageAmount * 500n) / 10_000n;
      const payout = (coverageAmount * 15000n) / 10_000n;

      await token.connect(buyer).approve(await insurance.getAddress(), premium);
      await insurance.connect(buyer).buyCoverage(poolId, coverageAmount);

      const beforeBalance = await token.balanceOf(buyer.address);
      const observedAt = await time.latest();

      await oracle.updateWeatherData(
        STATION_ID,
        weatherData({
          timestamp: observedAt,
          temperature: 4600,
          windSpeed: 2500,
        })
      );

      await expect(insurance.evaluateAndSettle(poolId))
        .to.emit(insurance, 'PoolTriggered')
        .withArgs(poolId, 4600, 2500, observedAt, 1, payout);

      const afterBalance = await token.balanceOf(buyer.address);
      expect(afterBalance).to.equal(beforeBalance + payout);

      const [, , , , , , , , , , liquidity, reservedLiability, , totalPayouts, , , , active, settled] =
        await insurance.getPool(poolId);
      expect(liquidity).to.equal(ethers.parseEther('20000') + premium - payout);
      expect(reservedLiability).to.equal(0n);
      expect(totalPayouts).to.equal(payout);
      expect(active).to.equal(false);
      expect(settled).to.equal(true);
    });

    it('automatically pays out when wind crosses the threshold', async function () {
      const { insurance, buyer, token, oracle, poolId } = await loadFixture(configurePoolFixture);

      const coverageAmount = ethers.parseEther('1000');
      const premium = (coverageAmount * 500n) / 10_000n;
      const payout = (coverageAmount * 15000n) / 10_000n;

      await token.connect(buyer).approve(await insurance.getAddress(), premium);
      await insurance.connect(buyer).buyCoverage(poolId, coverageAmount);

      await time.increase(5 * 60 + 1);
      await oracle.updateWeatherData(
        STATION_ID,
        weatherData({
          timestamp: await time.latest(),
          temperature: 3200,
          windSpeed: 3400,
        })
      );

      await expect(insurance.evaluateAndSettle(poolId))
        .to.emit(insurance, 'PolicyPayoutExecuted')
        .withArgs(1, poolId, buyer.address, payout);
    });
  });
});
