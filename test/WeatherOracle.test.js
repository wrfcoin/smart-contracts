'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('WeatherOracle', function () {
  async function deployFixture() {
    const [admin, forecastSigner, relayer, outsider] = await ethers.getSigners();
    const WeatherOracle = await ethers.getContractFactory('WeatherOracle');
    const oracle = await WeatherOracle.deploy();

    await oracle.connect(admin).setForecastSigner(await forecastSigner.getAddress(), true);

    return { admin, forecastSigner, relayer, outsider, oracle };
  }

  function buildForecastInput() {
    return {
      latitudeE6: 34_052_200,
      longitudeE6: -118_243_700,
      forecastTime: 1_710_000_000,
      gridPointId: ethers.id('wrf-grid-point-123'),
      variable: ethers.encodeBytes32String('temperature'),
      value: -325n,
      confidenceBps: 9_450,
      compressedPayloadHash: ethers.id('compressed-wrf-blob-v1'),
    };
  }

  async function signForecast(forecastSigner, oracle, input) {
    const digest = await oracle.getForecastDigest(input);
    return forecastSigner.signMessage(ethers.getBytes(digest));
  }

  it('stores a signed forecast and returns it by coordinates and time', async function () {
    const { oracle, forecastSigner, relayer } = await loadFixture(deployFixture);
    const input = buildForecastInput();
    const signature = await signForecast(forecastSigner, oracle, input);

    await expect(oracle.connect(relayer).submitForecast(input, signature))
      .to.emit(oracle, 'ForecastSubmitted')
      .withArgs(
        await oracle.forecastKey(input.latitudeE6, input.longitudeE6, input.forecastTime),
        input.gridPointId,
        input.variable,
        await forecastSigner.getAddress(),
        input.value,
        input.forecastTime,
        input.confidenceBps
      );

    const record = await oracle.getForecast(
      input.latitudeE6,
      input.longitudeE6,
      input.forecastTime
    );

    expect(record.latitudeE6).to.equal(input.latitudeE6);
    expect(record.longitudeE6).to.equal(input.longitudeE6);
    expect(record.forecastTime).to.equal(input.forecastTime);
    expect(record.gridPointId).to.equal(input.gridPointId);
    expect(record.variable).to.equal(input.variable);
    expect(record.value).to.equal(input.value);
    expect(record.confidenceBps).to.equal(input.confidenceBps);
    expect(record.compressedPayloadHash).to.equal(input.compressedPayloadHash);
    expect(record.signer).to.equal(await forecastSigner.getAddress());
    expect(record.submittedAt).to.be.gt(0n);
  });

  it('rejects submissions signed by an unauthorized signer', async function () {
    const { oracle, outsider, relayer } = await loadFixture(deployFixture);
    const input = buildForecastInput();
    const signature = await signForecast(outsider, oracle, input);

    await expect(oracle.connect(relayer).submitForecast(input, signature))
      .to.be.revertedWithCustomError(oracle, 'UnauthorizedForecastSigner');
  });

  it('rejects invalid forecast payloads', async function () {
    const { oracle, forecastSigner, relayer } = await loadFixture(deployFixture);
    const input = buildForecastInput();
    input.latitudeE6 = 120_000_000;
    const signature = await signForecast(forecastSigner, oracle, input);

    await expect(oracle.connect(relayer).submitForecast(input, signature))
      .to.be.revertedWithCustomError(oracle, 'InvalidCoordinate');
  });

  it('reports whether a forecast exists before and after submission', async function () {
    const { oracle, forecastSigner, relayer } = await loadFixture(deployFixture);
    const input = buildForecastInput();

    expect(
      await oracle.hasForecast(input.latitudeE6, input.longitudeE6, input.forecastTime)
    ).to.equal(false);

    const signature = await signForecast(forecastSigner, oracle, input);
    await oracle.connect(relayer).submitForecast(input, signature);

    expect(
      await oracle.hasForecast(input.latitudeE6, input.longitudeE6, input.forecastTime)
    ).to.equal(true);
  });
});
