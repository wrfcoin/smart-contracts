'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('ParametricWeatherInsurance', function () {
  // ── Constants ──────────────────────────────────────────────────────────────

  const STATION_ID   = ethers.keccak256(ethers.toUtf8Bytes('station-sahel-001'));
  const FEE_BPS      = 200n;          // 2 %
  const NO_FEE       = 0n;
  const PREMIUM_A    = ethers.parseEther('300');
  const PREMIUM_B    = ethers.parseEther('200');
  const TOTAL        = PREMIUM_A + PREMIUM_B;

  // IWeatherOracle values are scaled ×100:
  //   5 000 = 50 mm rainfall   (50 × 100)
  //   2 000 = 20 °C            (20 × 100)
  const RAINFALL_ABOVE_THRESHOLD = 5_000n;  // trigger level: > 4 000 (40 mm)
  const RAINFALL_THRESHOLD       = 4_000n;
  const TEMP_BELOW_THRESHOLD     = -600n;   // -6 °C; trigger level: < -500 (-5 °C)
  const TEMP_THRESHOLD           = -500n;

  // WeatherType enum indices (mirror Solidity enum order)
  const WeatherType = { RAINFALL: 0, TEMPERATURE: 1, WIND_SPEED: 2, HUMIDITY: 3 };
  const ThresholdDirection = { ABOVE: 0, BELOW: 1 };

  // ── Fixture ────────────────────────────────────────────────────────────────

  async function deployFixture() {
    const [admin, buyer1, buyer2, oracle, treasury] = await ethers.getSigners();

    // ERC-20 premium token
    const Token = await ethers.getContractFactory('MockERC20');
    const token = await Token.deploy('WRF Token', 'WRF', 18);
    await token.waitForDeployment();

    // Weather oracle mock
    const OracleMock = await ethers.getContractFactory('MockWeatherOracle');
    const oracleMock = await OracleMock.deploy();
    await oracleMock.waitForDeployment();

    // Main contract
    const Insurance = await ethers.getContractFactory('ParametricWeatherInsurance');
    const insurance = await Insurance.deploy(
      await oracleMock.getAddress(),
      treasury.address,
    );
    await insurance.waitForDeployment();

    // Grant oracle role to oracle signer
    const oracleRole = await insurance.ORACLE_ROLE();
    await insurance.connect(admin).grantRole(oracleRole, oracle.address);

    // Mint and approve tokens for buyers
    for (const buyer of [buyer1, buyer2]) {
      await token.mint(buyer.address, ethers.parseEther('10000'));
      await token.connect(buyer).approve(await insurance.getAddress(), ethers.parseEther('10000'));
    }

    return { admin, buyer1, buyer2, oracle, treasury, token, oracleMock, insurance };
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /** Returns a pool window: starts 1 h from now, ends 2 days from now. */
  async function futureWindow() {
    const now = BigInt(await time.latest());
    return { windowStart: now + 3_600n, windowEnd: now + 3_600n + 86_400n * 2n };
  }

  async function createRainfallPool(insurance, { feeBps = NO_FEE, token } = {}) {
    const { windowStart, windowEnd } = await futureWindow();
    const tx = await insurance.createPool(
      STATION_ID,
      WeatherType.RAINFALL,
      ThresholdDirection.ABOVE,
      RAINFALL_THRESHOLD,
      windowStart,
      windowEnd,
      await token.getAddress(),
      feeBps,
    );
    await tx.wait();
    return { poolId: 1n, windowStart, windowEnd };
  }

  /** Sets up oracle mock with the given rainfall value, timestamped inside the window. */
  async function setOracleData(oracleMock, windowStart, windowEnd, { rainfall = 0n, temperature = 0n } = {}) {
    const midWindow = windowStart + (windowEnd - windowStart) / 2n;
    await oracleMock.setWeatherData(STATION_ID, {
      temperature,
      humidity:  5000n,
      pressure:  101_300n,
      windSpeed: 1000n,
      rainfall,
      timestamp: midWindow,
      stationId: STATION_ID,
      confidence: 95n,
    });
  }

  // ── 1. Pool creation ───────────────────────────────────────────────────────

  it('creates a pool and emits PoolCreated', async function () {
    const { insurance, token } = await loadFixture(deployFixture);
    const { windowStart, windowEnd } = await futureWindow();

    await expect(
      insurance.createPool(
        STATION_ID,
        WeatherType.RAINFALL,
        ThresholdDirection.ABOVE,
        RAINFALL_THRESHOLD,
        windowStart,
        windowEnd,
        await token.getAddress(),
        NO_FEE,
      ),
    )
      .to.emit(insurance, 'PoolCreated')
      .withArgs(1n, STATION_ID, WeatherType.RAINFALL, ThresholdDirection.ABOVE, RAINFALL_THRESHOLD, windowStart, windowEnd, NO_FEE);

    const pool = await insurance.getPool(1n);
    expect(pool.stationId).to.equal(STATION_ID);
    expect(pool.threshold).to.equal(RAINFALL_THRESHOLD);
    expect(pool.state).to.equal(0); // OPEN
  });

  it('rejects pool with windowStart in the past', async function () {
    const { insurance, token } = await loadFixture(deployFixture);
    const now = BigInt(await time.latest());
    await expect(
      insurance.createPool(STATION_ID, WeatherType.RAINFALL, ThresholdDirection.ABOVE, 0n,
        now - 1n, now + 86_400n, await token.getAddress(), NO_FEE),
    ).to.be.revertedWithCustomError(insurance, 'InvalidWindow');
  });

  it('rejects pool where windowEnd ≤ windowStart', async function () {
    const { insurance, token } = await loadFixture(deployFixture);
    const now = BigInt(await time.latest());
    await expect(
      insurance.createPool(STATION_ID, WeatherType.RAINFALL, ThresholdDirection.ABOVE, 0n,
        now + 3_600n, now + 3_600n, await token.getAddress(), NO_FEE),
    ).to.be.revertedWithCustomError(insurance, 'InvalidWindow');
  });

  it('rejects pool with feeBps exceeding MAX_FEE_BPS', async function () {
    const { insurance, token } = await loadFixture(deployFixture);
    const { windowStart, windowEnd } = await futureWindow();
    await expect(
      insurance.createPool(STATION_ID, WeatherType.RAINFALL, ThresholdDirection.ABOVE, 0n,
        windowStart, windowEnd, await token.getAddress(), 1_001n),
    ).to.be.revertedWithCustomError(insurance, 'InvalidFeeBps');
  });

  it('rejects createPool from non-creator account', async function () {
    const { insurance, token, buyer1 } = await loadFixture(deployFixture);
    const { windowStart, windowEnd } = await futureWindow();
    await expect(
      insurance.connect(buyer1).createPool(STATION_ID, WeatherType.RAINFALL, ThresholdDirection.ABOVE, 0n,
        windowStart, windowEnd, await token.getAddress(), NO_FEE),
    ).to.be.revertedWithCustomError(insurance, 'AccessControlUnauthorizedAccount');
  });

  // ── 2. Coverage purchase ───────────────────────────────────────────────────

  it('accepts premium and records coverage', async function () {
    const { insurance, token, buyer1 } = await loadFixture(deployFixture);
    const { poolId } = await createRainfallPool(insurance, { token });

    await expect(insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A))
      .to.emit(insurance, 'CoverageBought')
      .withArgs(poolId, buyer1.address, PREMIUM_A, 0n);

    expect(await insurance.coverageOf(poolId, buyer1.address)).to.equal(PREMIUM_A);
    const pool = await insurance.getPool(poolId);
    expect(pool.totalCoverage).to.equal(PREMIUM_A);
    expect(pool.netPremiums).to.equal(PREMIUM_A);
  });

  it('collects fee and forwards to treasury on coverage purchase', async function () {
    const { insurance, token, buyer1, treasury } = await loadFixture(deployFixture);
    const { poolId } = await createRainfallPool(insurance, { feeBps: FEE_BPS, token });

    const treasuryBefore = await token.balanceOf(treasury.address);
    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    const treasuryAfter = await token.balanceOf(treasury.address);

    const expectedFee = (PREMIUM_A * FEE_BPS) / 10_000n;
    expect(treasuryAfter - treasuryBefore).to.equal(expectedFee);

    const pool = await insurance.getPool(poolId);
    expect(pool.netPremiums).to.equal(PREMIUM_A - expectedFee);
  });

  it('blocks coverage purchase after window has started', async function () {
    const { insurance, token, buyer1 } = await loadFixture(deployFixture);
    const { poolId, windowStart } = await createRainfallPool(insurance, { token });

    await time.increaseTo(windowStart);
    await expect(insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A))
      .to.be.revertedWithCustomError(insurance, 'WindowAlreadyStarted');
  });

  it('rejects zero-amount coverage purchase', async function () {
    const { insurance, token, buyer1 } = await loadFixture(deployFixture);
    const { poolId } = await createRainfallPool(insurance, { token });
    await expect(insurance.connect(buyer1).buyCoverage(poolId, 0n))
      .to.be.revertedWithCustomError(insurance, 'ZeroAmount');
  });

  // ── 3. Oracle resolution — TRIGGERED ──────────────────────────────────────

  it('resolves TRIGGERED when oracle data exceeds threshold', async function () {
    const { insurance, token, buyer1, buyer2, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });

    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await insurance.connect(buyer2).buyCoverage(poolId, PREMIUM_B);

    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);

    await expect(insurance.connect(oracle).resolvePool(poolId))
      .to.emit(insurance, 'PoolResolved')
      .withArgs(poolId, 1 /* RESOLVED_TRIGGERED */, RAINFALL_ABOVE_THRESHOLD);

    const pool = await insurance.getPool(poolId);
    expect(pool.state).to.equal(1); // RESOLVED_TRIGGERED
    expect(pool.resolvedValue).to.equal(RAINFALL_ABOVE_THRESHOLD);
  });

  // ── 4. Oracle resolution — NOT_TRIGGERED ──────────────────────────────────

  it('resolves NOT_TRIGGERED when oracle data is below threshold', async function () {
    const { insurance, token, buyer1, oracle, oracleMock, treasury } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });

    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);

    const belowThreshold = RAINFALL_THRESHOLD - 1n;
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: belowThreshold });
    await time.increaseTo(windowEnd + 1n);

    const treasuryBefore = await token.balanceOf(treasury.address);
    await insurance.connect(oracle).resolvePool(poolId);
    const treasuryAfter = await token.balanceOf(treasury.address);

    const pool = await insurance.getPool(poolId);
    expect(pool.state).to.equal(2); // RESOLVED_NOT_TRIGGERED
    // Net premiums swept to treasury
    expect(treasuryAfter - treasuryBefore).to.equal(PREMIUM_A);
  });

  it('blocks resolvePool before window has closed', async function () {
    const { insurance, token, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    // Don't advance past windowEnd
    await expect(insurance.connect(oracle).resolvePool(poolId))
      .to.be.revertedWithCustomError(insurance, 'WindowNotClosed');
  });

  it('blocks resolvePool from non-oracle account', async function () {
    const { insurance, token, buyer1, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);
    await expect(insurance.connect(buyer1).resolvePool(poolId))
      .to.be.revertedWithCustomError(insurance, 'AccessControlUnauthorizedAccount');
  });

  it('blocks resolvePool if oracle data timestamp is outside window', async function () {
    const { insurance, token, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowEnd } = await createRainfallPool(insurance, { token });

    // Set oracle data with timestamp BEFORE the window
    const beforeWindow = 1n;
    await oracleMock.setWeatherData(STATION_ID, {
      temperature: 0n, humidity: 0n, pressure: 0n, windSpeed: 0n,
      rainfall: RAINFALL_ABOVE_THRESHOLD,
      timestamp: beforeWindow,
      stationId: STATION_ID,
      confidence: 95n,
    });
    await time.increaseTo(windowEnd + 1n);
    await expect(insurance.connect(oracle).resolvePool(poolId))
      .to.be.revertedWithCustomError(insurance, 'OracleDataOutsideWindow');
  });

  it('blocks double resolution', async function () {
    const { insurance, token, oracle, oracleMock, buyer1 } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });
    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);
    await insurance.connect(oracle).resolvePool(poolId);
    await expect(insurance.connect(oracle).resolvePool(poolId))
      .to.be.revertedWithCustomError(insurance, 'PoolAlreadyResolved');
  });

  // ── 5. Temperature BELOW threshold (negative values) ──────────────────────

  it('resolves TRIGGERED on negative-threshold BELOW condition (frost event)', async function () {
    const { insurance, token, buyer1, oracle, oracleMock } = await loadFixture(deployFixture);
    const now = BigInt(await time.latest());
    const windowStart = now + 3_600n;
    const windowEnd   = windowStart + 86_400n;

    await insurance.createPool(
      STATION_ID,
      WeatherType.TEMPERATURE,
      ThresholdDirection.BELOW,
      TEMP_THRESHOLD,          // trigger when temp < -5 °C
      windowStart,
      windowEnd,
      await token.getAddress(),
      NO_FEE,
    );

    await insurance.connect(buyer1).buyCoverage(1n, PREMIUM_A);
    const midWindow = windowStart + (windowEnd - windowStart) / 2n;
    await oracleMock.setWeatherData(STATION_ID, {
      temperature: TEMP_BELOW_THRESHOLD,   // -6 °C → triggered
      humidity: 0n, pressure: 0n, windSpeed: 0n, rainfall: 0n,
      timestamp: midWindow,
      stationId: STATION_ID,
      confidence: 90n,
    });
    await time.increaseTo(windowEnd + 1n);

    await expect(insurance.connect(oracle).resolvePool(1n))
      .to.emit(insurance, 'PoolResolved')
      .withArgs(1n, 1 /* TRIGGERED */, TEMP_BELOW_THRESHOLD);
  });

  // ── 6. Pro-rata claim math ─────────────────────────────────────────────────

  it('claimableAmount is proportional to coverage share', async function () {
    const { insurance, token, buyer1, buyer2, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });

    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A); // 300 / 500 = 60 %
    await insurance.connect(buyer2).buyCoverage(poolId, PREMIUM_B); // 200 / 500 = 40 %

    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);
    await insurance.connect(oracle).resolvePool(poolId);

    const claim1 = await insurance.claimableAmount(poolId, buyer1.address);
    const claim2 = await insurance.claimableAmount(poolId, buyer2.address);

    // 60 % and 40 % of net pool (= TOTAL since feeBps = 0)
    expect(claim1).to.equal((PREMIUM_A * TOTAL) / TOTAL);  // 300
    expect(claim2).to.equal((PREMIUM_B * TOTAL) / TOTAL);  // 200
    expect(claim1 + claim2).to.equal(TOTAL);
  });

  it('claim transfers payout and zeroes claimable balance', async function () {
    const { insurance, token, buyer1, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });

    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);
    await insurance.connect(oracle).resolvePool(poolId);

    const before = await token.balanceOf(buyer1.address);
    await expect(insurance.connect(buyer1).claim(poolId))
      .to.emit(insurance, 'Claimed')
      .withArgs(poolId, buyer1.address, PREMIUM_A);
    const after = await token.balanceOf(buyer1.address);
    expect(after - before).to.equal(PREMIUM_A);

    expect(await insurance.claimableAmount(poolId, buyer1.address)).to.equal(0n);
  });

  it('blocks double claim', async function () {
    const { insurance, token, buyer1, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });

    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);
    await insurance.connect(oracle).resolvePool(poolId);

    await insurance.connect(buyer1).claim(poolId);
    await expect(insurance.connect(buyer1).claim(poolId))
      .to.be.revertedWithCustomError(insurance, 'AlreadyClaimed');
  });

  it('blocks claim when pool is NOT_TRIGGERED', async function () {
    const { insurance, token, buyer1, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });

    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_THRESHOLD - 1n });
    await time.increaseTo(windowEnd + 1n);
    await insurance.connect(oracle).resolvePool(poolId);

    await expect(insurance.connect(buyer1).claim(poolId))
      .to.be.revertedWithCustomError(insurance, 'NotTriggered');
  });

  it('blocks claim before pool is resolved', async function () {
    const { insurance, token, buyer1 } = await loadFixture(deployFixture);
    const { poolId } = await createRainfallPool(insurance, { token });
    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await expect(insurance.connect(buyer1).claim(poolId))
      .to.be.revertedWithCustomError(insurance, 'PoolNotResolved');
  });

  it('blocks claim from account with no coverage', async function () {
    const { insurance, token, buyer1, buyer2, oracle, oracleMock } = await loadFixture(deployFixture);
    const { poolId, windowStart, windowEnd } = await createRainfallPool(insurance, { token });
    await insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A);
    await setOracleData(oracleMock, windowStart, windowEnd, { rainfall: RAINFALL_ABOVE_THRESHOLD });
    await time.increaseTo(windowEnd + 1n);
    await insurance.connect(oracle).resolvePool(poolId);
    await expect(insurance.connect(buyer2).claim(poolId))
      .to.be.revertedWithCustomError(insurance, 'NoCoverage');
  });

  // ── 7. Pause ───────────────────────────────────────────────────────────────

  it('pause blocks buyCoverage', async function () {
    const { insurance, token, buyer1, admin } = await loadFixture(deployFixture);
    const { poolId } = await createRainfallPool(insurance, { token });
    await insurance.connect(admin).pause();
    await expect(insurance.connect(buyer1).buyCoverage(poolId, PREMIUM_A))
      .to.be.revertedWithCustomError(insurance, 'EnforcedPause');
  });
});
