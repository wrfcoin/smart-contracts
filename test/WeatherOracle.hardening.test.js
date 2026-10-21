'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

/**
 * Hardening tests for WeatherOracle — issue #45
 *
 * Covers:
 *  1. Access control: admin-only functions reject non-admins
 *  2. Staleness checks: getForecast reverts when record age > maxAge
 *  3. Multi-sig threshold: forecast only accepted after M distinct signer confirmations
 *  4. Circuit-breaker: range bounds and deviation limits
 */
describe('WeatherOracle — hardening (#45)', function () {
  async function deployFixture() {
    const [admin, signer1, signer2, signer3, relayer, outsider] = await ethers.getSigners();
    const WeatherOracle = await ethers.getContractFactory('WeatherOracle');
    const oracle = await WeatherOracle.deploy();

    await oracle.connect(admin).setForecastSigner(await signer1.getAddress(), true);
    await oracle.connect(admin).setForecastSigner(await signer2.getAddress(), true);
    await oracle.connect(admin).setForecastSigner(await signer3.getAddress(), true);

    return { admin, signer1, signer2, signer3, relayer, outsider, oracle };
  }

  function buildInput(overrides = {}) {
    return {
      latitudeE6: 34_052_200,
      longitudeE6: -118_243_700,
      forecastTime: 1_710_000_000,
      gridPointId: ethers.id('wrf-grid-point-123'),
      variable: ethers.encodeBytes32String('temperature'),
      value: -325n,
      confidenceBps: 9_450,
      compressedPayloadHash: ethers.id('compressed-wrf-blob-v1'),
      ...overrides,
    };
  }

  async function sign(signer, oracle, input) {
    const digest = await oracle.getForecastDigest(input);
    return signer.signMessage(ethers.getBytes(digest));
  }

  // ---------------------------------------------------------------------------
  // 1. Access control
  // ---------------------------------------------------------------------------
  describe('access control', function () {
    it('non-admin cannot call setMaxAge', async function () {
      const { oracle, outsider } = await loadFixture(deployFixture);
      await expect(oracle.connect(outsider).setMaxAge(7200))
        .to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');
    });

    it('non-admin cannot call setSignerThreshold', async function () {
      const { oracle, outsider } = await loadFixture(deployFixture);
      await expect(oracle.connect(outsider).setSignerThreshold(2))
        .to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');
    });

    it('non-admin cannot call setValueBounds', async function () {
      const { oracle, outsider } = await loadFixture(deployFixture);
      await expect(oracle.connect(outsider).setValueBounds(-500, 500))
        .to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');
    });

    it('non-admin cannot call setMaxDeviationBps', async function () {
      const { oracle, outsider } = await loadFixture(deployFixture);
      await expect(oracle.connect(outsider).setMaxDeviationBps(5000))
        .to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');
    });

    it('non-admin cannot call setForecastSigner', async function () {
      const { oracle, outsider, relayer } = await loadFixture(deployFixture);
      await expect(
        oracle.connect(outsider).setForecastSigner(await relayer.getAddress(), true)
      ).to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');
    });

    it('admin can update all hardening config and events are emitted', async function () {
      const { oracle, admin } = await loadFixture(deployFixture);
      await expect(oracle.connect(admin).setMaxAge(7200)).to.emit(oracle, 'MaxAgeUpdated').withArgs(7200);
      await expect(oracle.connect(admin).setSignerThreshold(2)).to.emit(oracle, 'SignerThresholdUpdated').withArgs(2);
      await expect(oracle.connect(admin).setValueBounds(-500, 500)).to.emit(oracle, 'ValueBoundsUpdated').withArgs(-500, 500);
      await expect(oracle.connect(admin).setMaxDeviationBps(5000)).to.emit(oracle, 'MaxDeviationUpdated').withArgs(5000);
    });

    it('setSignerThreshold rejects zero threshold', async function () {
      const { oracle, admin } = await loadFixture(deployFixture);
      await expect(oracle.connect(admin).setSignerThreshold(0))
        .to.be.revertedWithCustomError(oracle, 'InvalidThreshold');
    });

    it('setValueBounds rejects min > max', async function () {
      const { oracle, admin } = await loadFixture(deployFixture);
      await expect(oracle.connect(admin).setValueBounds(100, -100))
        .to.be.revertedWithCustomError(oracle, 'InvalidValueBounds');
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Staleness checks
  // ---------------------------------------------------------------------------
  describe('staleness checks', function () {
    it('getForecast reverts with ForecastStale after maxAge seconds', async function () {
      const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
      // Set a short maxAge so we can expire it easily
      await oracle.connect(admin).setMaxAge(60); // 60 seconds

      const input = buildInput();
      const sig = await sign(signer1, oracle, input);
      await oracle.connect(relayer).submitForecast(input, sig);

      // Advance time past maxAge
      await time.increase(61);

      await expect(
        oracle.getForecast(input.latitudeE6, input.longitudeE6, input.forecastTime)
      ).to.be.revertedWithCustomError(oracle, 'ForecastStale');
    });

    it('getForecast succeeds when record is within maxAge', async function () {
      const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
      await oracle.connect(admin).setMaxAge(3600);

      const input = buildInput();
      const sig = await sign(signer1, oracle, input);
      await oracle.connect(relayer).submitForecast(input, sig);

      // Only 30 seconds elapsed — should not be stale
      await time.increase(30);

      const record = await oracle.getForecast(input.latitudeE6, input.longitudeE6, input.forecastTime);
      expect(record.value).to.equal(input.value);
    });

    it('staleness check is skipped when maxAge is 0', async function () {
      const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
      await oracle.connect(admin).setMaxAge(0); // disabled

      const input = buildInput();
      const sig = await sign(signer1, oracle, input);
      await oracle.connect(relayer).submitForecast(input, sig);

      // Advance time a long way
      await time.increase(10 * 365 * 24 * 3600); // 10 years

      const record = await oracle.getForecast(input.latitudeE6, input.longitudeE6, input.forecastTime);
      expect(record.value).to.equal(input.value);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Multi-sig threshold
  // ---------------------------------------------------------------------------
  describe('multi-sig threshold', function () {
    it('forecast is not accepted until threshold is reached (2-of-3)', async function () {
      const { oracle, admin, signer1, signer2, relayer } = await loadFixture(deployFixture);
      await oracle.connect(admin).setSignerThreshold(2);

      const input = buildInput();

      // First confirmation — not yet accepted
      const sig1 = await sign(signer1, oracle, input);
      await expect(oracle.connect(relayer).submitForecast(input, sig1))
        .to.emit(oracle, 'ForecastConfirmationAdded')
        .withArgs(
          await oracle.forecastKey(input.latitudeE6, input.longitudeE6, input.forecastTime),
          await signer1.getAddress(),
          1,
          2
        );

      expect(
        await oracle.hasForecast(input.latitudeE6, input.longitudeE6, input.forecastTime)
      ).to.equal(false);

      // Second confirmation — threshold reached, ForecastSubmitted emitted
      const sig2 = await sign(signer2, oracle, input);
      await expect(oracle.connect(relayer).submitForecast(input, sig2))
        .to.emit(oracle, 'ForecastSubmitted');

      expect(
        await oracle.hasForecast(input.latitudeE6, input.longitudeE6, input.forecastTime)
      ).to.equal(true);
    });

    it('duplicate signer is rejected with AlreadySigned', async function () {
      const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
      await oracle.connect(admin).setSignerThreshold(2);

      const input = buildInput();
      const sig1 = await sign(signer1, oracle, input);
      await oracle.connect(relayer).submitForecast(input, sig1);

      // Same signer tries again
      await expect(oracle.connect(relayer).submitForecast(input, sig1))
        .to.be.revertedWithCustomError(oracle, 'AlreadySigned');
    });

    it('conflicting value resets the pending slot', async function () {
      const { oracle, admin, signer1, signer2, signer3, relayer } = await loadFixture(deployFixture);
      await oracle.connect(admin).setSignerThreshold(2);

      const input = buildInput();
      const conflictInput = buildInput({ value: -300n }); // different value

      const sig1 = await sign(signer1, oracle, input);
      await oracle.connect(relayer).submitForecast(input, sig1);

      // signer2 submits a conflicting value — resets pending, starts fresh
      const sig2conflict = await sign(signer2, oracle, conflictInput);
      await oracle.connect(relayer).submitForecast(conflictInput, sig2conflict);

      // Forecast should still not be accepted
      expect(
        await oracle.hasForecast(input.latitudeE6, input.longitudeE6, input.forecastTime)
      ).to.equal(false);
    });

    it('pendingConfirmations reflects current count', async function () {
      const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
      await oracle.connect(admin).setSignerThreshold(3);

      const input = buildInput();
      const key = await oracle.forecastKey(input.latitudeE6, input.longitudeE6, input.forecastTime);

      expect(await oracle.pendingConfirmations(key)).to.equal(0);

      const sig1 = await sign(signer1, oracle, input);
      await oracle.connect(relayer).submitForecast(input, sig1);

      expect(await oracle.pendingConfirmations(key)).to.equal(1);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Circuit-breaker
  // ---------------------------------------------------------------------------
  describe('circuit-breaker', function () {
    describe('value range bounds', function () {
      it('rejects value below minValue', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        await oracle.connect(admin).setValueBounds(-300n, 300n);

        const input = buildInput({ value: -400n });
        const sig = await sign(signer1, oracle, input);

        await expect(oracle.connect(relayer).submitForecast(input, sig))
          .to.be.revertedWithCustomError(oracle, 'ValueOutOfRange');
      });

      it('rejects value above maxValue', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        await oracle.connect(admin).setValueBounds(-300n, 300n);

        const input = buildInput({ value: 400n });
        const sig = await sign(signer1, oracle, input);

        await expect(oracle.connect(relayer).submitForecast(input, sig))
          .to.be.revertedWithCustomError(oracle, 'ValueOutOfRange');
      });

      it('accepts value exactly at bounds', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        await oracle.connect(admin).setValueBounds(-400n, 400n);

        const inputLow = buildInput({ value: -400n });
        const sigLow = await sign(signer1, oracle, inputLow);
        await expect(oracle.connect(relayer).submitForecast(inputLow, sigLow)).not.to.be.reverted;
      });
    });

    describe('deviation limits', function () {
      it('rejects value that deviates more than maxDeviationBps from last accepted', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        // maxDeviationBps = 1000 bps = 10%
        await oracle.connect(admin).setMaxDeviationBps(1000);

        const input = buildInput({ value: 1000n });
        const sig = await sign(signer1, oracle, input);
        await oracle.connect(relayer).submitForecast(input, sig);

        // Now submit a value that deviates >10% from 1000: anything < 900 or > 1100
        const badInput = buildInput({
          value: 500n,
          forecastTime: 1_710_001_000,
          gridPointId: ethers.id('wrf-grid-point-456'),
        });
        // Use same lat/lon but different forecastTime to get a different key — actually deviation
        // check compares against the SAME key's last accepted value. Use same forecastTime.
        const badInput2 = buildInput({ value: 500n });
        const badSig = await sign(signer1, oracle, badInput2);
        await expect(oracle.connect(relayer).submitForecast(badInput2, badSig))
          .to.be.revertedWithCustomError(oracle, 'ValueDeviationExceeded');
      });

      it('accepts value within deviation limit', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        await oracle.connect(admin).setMaxDeviationBps(1000); // 10%

        // First submission
        const input = buildInput({ value: 1000n });
        const sig = await sign(signer1, oracle, input);
        await oracle.connect(relayer).submitForecast(input, sig);

        // Second submission within 10%: 1050 (5% deviation)
        const input2 = buildInput({ value: 1050n });
        const sig2 = await sign(signer1, oracle, input2);
        await expect(oracle.connect(relayer).submitForecast(input2, sig2)).not.to.be.reverted;
      });

      it('deviation check is skipped when maxDeviationBps is 0', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        await oracle.connect(admin).setMaxDeviationBps(0); // disabled

        const input = buildInput({ value: 1000n });
        const sig = await sign(signer1, oracle, input);
        await oracle.connect(relayer).submitForecast(input, sig);

        // Wildly different value — should be accepted
        const input2 = buildInput({ value: -5000n });
        // But -5000 is within default bounds (-10000, 10000)
        const sig2 = await sign(signer1, oracle, input2);
        await expect(oracle.connect(relayer).submitForecast(input2, sig2)).not.to.be.reverted;
      });

      it('deviation check is skipped when last accepted value is 0', async function () {
        const { oracle, admin, signer1, relayer } = await loadFixture(deployFixture);
        await oracle.connect(admin).setMaxDeviationBps(100); // 1%

        const input = buildInput({ value: 0n });
        const sig = await sign(signer1, oracle, input);
        await oracle.connect(relayer).submitForecast(input, sig);

        // Any value should be accepted since last is 0
        const input2 = buildInput({ value: 9000n });
        const sig2 = await sign(signer1, oracle, input2);
        await expect(oracle.connect(relayer).submitForecast(input2, sig2)).not.to.be.reverted;
      });
    });
  });
});
