'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('StormChaserNFT', function () {
  async function deployFixture() {
    const [owner, oracleOperator, oracle, collector] = await ethers.getSigners();

    const MockExtremeWeatherOracle = await ethers.getContractFactory('MockExtremeWeatherOracle');
    const eventOracle = await MockExtremeWeatherOracle.deploy();

    const WeatherSVG = await ethers.getContractFactory('WeatherSVG');
    const weatherSvg = await WeatherSVG.deploy();

    const StormChaserNFT = await ethers.getContractFactory('StormChaserNFT', {
      libraries: {
        WeatherSVG: await weatherSvg.getAddress(),
      },
    });
    const nft = await StormChaserNFT.deploy(
      oracleOperator.address,
      await eventOracle.getAddress()
    );

    return { owner, oracleOperator, oracle, collector, eventOracle, weatherSvg, nft };
  }

  async function stormFactory(extremeWeatherOracleAddress) {
    const [owner, oracleOperator] = await ethers.getSigners();
    const WeatherSVG = await ethers.getContractFactory('WeatherSVG');
    const weatherSvg = await WeatherSVG.deploy();
    const StormChaserNFT = await ethers.getContractFactory('StormChaserNFT', {
      libraries: {
        WeatherSVG: await weatherSvg.getAddress(),
      },
    });

    return {
      owner,
      oracleOperator,
      StormChaserNFT,
      deploy: () => StormChaserNFT.deploy(oracleOperator.address, extremeWeatherOracleAddress),
    };
  }

  it('mints for an extreme weather event with the expected severity', async function () {
    const { oracleOperator, oracle, eventOracle, nft } = await loadFixture(deployFixture);
    const eventId = ethers.id('event-hurricane-1');
    await eventOracle.setEventClassification(eventId, true, 4, 'Hurricane');

    await expect(nft.connect(oracleOperator).mintForEvent(oracle.address, eventId))
      .to.emit(nft, 'Transfer')
      .withArgs(ethers.ZeroAddress, oracle.address, 1n);

    const record = await nft.storms(1n);
    expect(record.eventId).to.equal(eventId);
    expect(record.severity).to.equal(4n);
    expect(record.eventType).to.equal('Hurricane');
  });

  it('rejects duplicate submissions for the same event and oracle', async function () {
    const { oracleOperator, oracle, eventOracle, nft } = await loadFixture(deployFixture);
    const eventId = ethers.id('event-duplicate');
    await eventOracle.setEventClassification(eventId, true, 3, 'Blizzard');

    await nft.connect(oracleOperator).mintForEvent(oracle.address, eventId);
    await expect(
      nft.connect(oracleOperator).mintForEvent(oracle.address, eventId)
    ).to.be.revertedWithCustomError(nft, 'DuplicateStormSubmission');
  });

  it('rejects non-extreme events', async function () {
    const { oracleOperator, oracle, eventOracle, nft } = await loadFixture(deployFixture);
    const eventId = ethers.id('event-not-extreme');
    await eventOracle.setEventClassification(eventId, false, 1, 'Rain');

    await expect(
      nft.connect(oracleOperator).mintForEvent(oracle.address, eventId)
    ).to.be.revertedWithCustomError(nft, 'EventNotExtreme');
  });

  it('updates accuracy and emits a metadata refresh event', async function () {
    const { oracleOperator, oracle, eventOracle, nft } = await loadFixture(deployFixture);
    const eventId = ethers.id('event-accuracy');
    await eventOracle.setEventClassification(eventId, true, 5, 'Tornado');
    await nft.connect(oracleOperator).mintForEvent(oracle.address, eventId);

    await expect(nft.connect(oracleOperator).updateAccuracy(1n, 91))
      .to.emit(nft, 'AccuracyUpdated')
      .withArgs(1n, 0n, 91n)
      .and.to.emit(nft, 'MetadataUpdate')
      .withArgs(1n);
  });

  it('blocks transfer during the 48 hour verification window', async function () {
    const { oracleOperator, oracle, collector, eventOracle, nft } = await loadFixture(
      deployFixture
    );
    const eventId = ethers.id('event-transfer-lock');
    await eventOracle.setEventClassification(eventId, true, 2, 'Storm');
    await nft.connect(oracleOperator).mintForEvent(oracle.address, eventId);

    await expect(
      nft.connect(oracle).transferFrom(oracle.address, collector.address, 1n)
    ).to.be.revertedWithCustomError(nft, 'TransferLocked');
  });

  it('allows transfer after the 48 hour verification window', async function () {
    const { oracleOperator, oracle, collector, eventOracle, nft } = await loadFixture(
      deployFixture
    );
    const eventId = ethers.id('event-transfer-open');
    await eventOracle.setEventClassification(eventId, true, 1, 'Blizzard');
    await nft.connect(oracleOperator).mintForEvent(oracle.address, eventId);

    await time.increase(49 * 60 * 60);
    await nft.connect(oracle).transferFrom(oracle.address, collector.address, 1n);
    expect(await nft.ownerOf(1n)).to.equal(collector.address);
  });

  it('returns svg metadata that reflects severity and accuracy', async function () {
    const { oracleOperator, oracle, eventOracle, nft } = await loadFixture(deployFixture);
    const eventId = ethers.id('event-uri');
    await eventOracle.setEventClassification(eventId, true, 5, 'Cyclone');
    await nft.connect(oracleOperator).mintForEvent(oracle.address, eventId);
    await nft.connect(oracleOperator).updateAccuracy(1n, 88);

    const uri = await nft.tokenURI(1n);
    expect(uri.startsWith('data:application/json;base64,')).to.equal(true);
    const decoded = Buffer.from(uri.split(',')[1], 'base64').toString('utf8');
    expect(decoded).to.include('Cyclone');
    expect(decoded).to.include('Accuracy Score');
  });

  it('rejects accuracy updates from non-oracle callers', async function () {
    const { oracleOperator, oracle, collector, eventOracle, nft } = await loadFixture(
      deployFixture
    );
    const eventId = ethers.id('event-unauthorized-accuracy');
    await eventOracle.setEventClassification(eventId, true, 2, 'Storm');
    await nft.connect(oracleOperator).mintForEvent(oracle.address, eventId);

    await expect(
      nft.connect(collector).updateAccuracy(1n, 50)
    ).to.be.revertedWithCustomError(nft, 'UnauthorizedOracle');
  });

  it('lets the owner update the extreme weather oracle', async function () {
    const { owner, eventOracle, nft } = await loadFixture(deployFixture);
    const MockExtremeWeatherOracle = await ethers.getContractFactory('MockExtremeWeatherOracle');
    const replacementOracle = await MockExtremeWeatherOracle.deploy();

    await expect(nft.connect(owner).setExtremeWeatherOracle(await replacementOracle.getAddress()))
      .to.emit(nft, 'ExtremeWeatherOracleUpdated')
      .withArgs(await eventOracle.getAddress(), await replacementOracle.getAddress());
  });

  it('rejects zero-address deployment and oracle updates', async function () {
    const MockExtremeWeatherOracle = await ethers.getContractFactory('MockExtremeWeatherOracle');
    const eventOracle = await MockExtremeWeatherOracle.deploy();
    const { owner, StormChaserNFT, deploy } = await stormFactory(await eventOracle.getAddress());
    const deployed = await deploy();

    await expect(
      StormChaserNFT.deploy(ethers.ZeroAddress, await eventOracle.getAddress())
    ).to.be.revertedWithCustomError(StormChaserNFT, 'ZeroAddress');
    await expect(
      StormChaserNFT.deploy(owner.address, ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(StormChaserNFT, 'ZeroAddress');
    await expect(
      deployed.connect(owner).setExtremeWeatherOracle(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(deployed, 'ZeroAddress');
  });
});
