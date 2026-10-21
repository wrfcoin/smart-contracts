'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('WeatherStreakNFT', function () {
  async function deployFixture() {
    const [owner, oracleOperator, oracle, collector] = await ethers.getSigners();

    const WeatherSVG = await ethers.getContractFactory('WeatherSVG');
    const weatherSvg = await WeatherSVG.deploy();

    const WeatherStreakNFT = await ethers.getContractFactory('WeatherStreakNFT', {
      libraries: {
        WeatherSVG: await weatherSvg.getAddress(),
      },
    });
    const nft = await WeatherStreakNFT.deploy(oracleOperator.address);

    return { owner, oracleOperator, oracle, collector, weatherSvg, nft };
  }

  async function latestTimestamp() {
    return BigInt(await time.latest());
  }

  async function weatherStreakFactory() {
    const WeatherSVG = await ethers.getContractFactory('WeatherSVG');
    const weatherSvg = await WeatherSVG.deploy();
    return ethers.getContractFactory('WeatherStreakNFT', {
      libraries: {
        WeatherSVG: await weatherSvg.getAddress(),
      },
    });
  }

  it('mints on first submission and starts bronze streak state', async function () {
    const { oracleOperator, oracle, nft } = await loadFixture(deployFixture);
    const submittedAt = await latestTimestamp();

    await expect(nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt))
      .to.emit(nft, 'Transfer')
      .withArgs(ethers.ZeroAddress, oracle.address, 1n);

    const data = await nft.streakData(oracle.address);
    expect(data.tokenId).to.equal(1n);
    expect(data.streakDays).to.equal(1n);
    expect(data.tier).to.equal(0n);
  });

  it('keeps a streak active and emits metadata updates on day 7', async function () {
    const { oracleOperator, oracle, nft } = await loadFixture(deployFixture);
    let submittedAt = await latestTimestamp();

    for (let day = 0; day < 7; day += 1) {
      await expect(
        nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt)
      ).to.emit(nft, 'MetadataUpdate');
      submittedAt += 24n * 60n * 60n;
    }

    const data = await nft.streakData(oracle.address);
    expect(data.streakDays).to.equal(7n);
    expect(data.tier).to.equal(0n);
  });

  it('resets streak in place after a gap greater than 25 hours', async function () {
    const { oracleOperator, oracle, nft } = await loadFixture(deployFixture);
    let submittedAt = await latestTimestamp();

    await nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt);
    await nft
      .connect(oracleOperator)
      .recordSubmission(oracle.address, submittedAt + 24n * 60n * 60n);
    await nft
      .connect(oracleOperator)
      .recordSubmission(oracle.address, submittedAt + 52n * 60n * 60n);

    const data = await nft.streakData(oracle.address);
    expect(data.tokenId).to.equal(1n);
    expect(data.streakDays).to.equal(1n);
  });

  it('blocks transfers while the streak is active', async function () {
    const { oracleOperator, oracle, collector, nft } = await loadFixture(deployFixture);
    const submittedAt = await latestTimestamp();

    await nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt);

    await expect(
      nft.connect(oracle).transferFrom(oracle.address, collector.address, 1n)
    ).to.be.revertedWithCustomError(nft, 'ActiveStreakSoulbound');
  });

  it('allows transfer after the active streak window has elapsed', async function () {
    const { oracleOperator, oracle, collector, nft } = await loadFixture(deployFixture);
    const submittedAt = await latestTimestamp();

    await nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt);
    await time.increase(26 * 60 * 60);

    await nft.connect(oracle).transferFrom(oracle.address, collector.address, 1n);
    expect(await nft.ownerOf(1n)).to.equal(collector.address);
  });

  it('returns a base64 json data uri with embedded svg', async function () {
    const { oracleOperator, oracle, nft } = await loadFixture(deployFixture);
    const submittedAt = await latestTimestamp();

    await nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt);
    const uri = await nft.tokenURI(1n);
    expect(uri.startsWith('data:application/json;base64,')).to.equal(true);
    const decoded = Buffer.from(uri.split(',')[1], 'base64').toString('utf8');
    expect(decoded).to.include('data:image/svg+xml;base64,');
    expect(decoded).to.include('"Tier"');
  });

  it('progresses metadata through silver, gold, and diamond tiers', async function () {
    const { oracleOperator, oracle, nft } = await loadFixture(deployFixture);
    let submittedAt = await latestTimestamp();

    for (let day = 0; day < 365; day += 1) {
      await nft.connect(oracleOperator).recordSubmission(oracle.address, submittedAt);
      if (day === 29) {
        const uri = await nft.tokenURI(1n);
        const decoded = Buffer.from(uri.split(',')[1], 'base64').toString('utf8');
        expect(decoded).to.include('Silver');
      }
      if (day === 89) {
        const uri = await nft.tokenURI(1n);
        const decoded = Buffer.from(uri.split(',')[1], 'base64').toString('utf8');
        expect(decoded).to.include('Gold');
      }
      submittedAt += 24n * 60n * 60n;
    }

    const data = await nft.streakData(oracle.address);
    expect(data.streakDays).to.equal(365n);
    expect(data.tier).to.equal(3n);

    const uri = await nft.tokenURI(1n);
    const decoded = Buffer.from(uri.split(',')[1], 'base64').toString('utf8');
    expect(decoded).to.include('Diamond');
  });

  it('rejects submission updates from non-oracle callers', async function () {
    const { oracle, nft } = await loadFixture(deployFixture);

    await expect(
      nft.recordSubmission(oracle.address, await latestTimestamp())
    ).to.be.revertedWithCustomError(nft, 'UnauthorizedOracle');
  });

  it('lets the owner manage oracle roles', async function () {
    const { owner, oracle, nft } = await loadFixture(deployFixture);

    await nft.connect(owner).grantOracleRole(oracle.address);
    expect(await nft.hasRole(await nft.ORACLE_ROLE(), oracle.address)).to.equal(true);

    await nft.connect(owner).revokeOracleRole(oracle.address);
    expect(await nft.hasRole(await nft.ORACLE_ROLE(), oracle.address)).to.equal(false);
  });

  it('rejects zero-address deployment', async function () {
    const WeatherStreakNFT = await weatherStreakFactory();

    await expect(
      WeatherStreakNFT.deploy(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(WeatherStreakNFT, 'ZeroAddress');
  });
});
