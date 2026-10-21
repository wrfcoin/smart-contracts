'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('QualityOracle focused guard coverage', function () {
  async function deployFixture() {
    const [admin, updater, other] = await ethers.getSigners();
    const QualityOracle = await ethers.getContractFactory('QualityOracle');
    const oracle = await QualityOracle.deploy();

    const QUALITY_UPDATER_ROLE = await oracle.QUALITY_UPDATER_ROLE();
    await oracle.connect(admin).grantRole(QUALITY_UPDATER_ROLE, updater.address);

    return { admin, updater, other, oracle, QUALITY_UPDATER_ROLE };
  }

  const feedId = ethers.encodeBytes32String('quality-feed');
  const provider = 0; // OracleProvider.CHAINLINK
  const validConfig = {
    provider,
    oracleAddress: ethers.getAddress('0x1111111111111111111111111111111111111111'),
    weight: 10000,
    maxStaleness: 3600,
    minConfidence: 70,
    isActive: true,
    endpoint: 'https://api.example/oracle',
  };

  it('rejects oracle management calls without ORACLE_ADMIN_ROLE', async function () {
    const { oracle, other } = await loadFixture(deployFixture);

    await expect(
      oracle.connect(other).addOracle(feedId, validConfig)
    ).to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');

    const token = ethers.Wallet.createRandom().address;
    await expect(
      oracle.connect(other).setQualityThreshold(50)
    ).to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');

    await expect(
      oracle.connect(other).enableCircuitBreaker(feedId)
    ).to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');
  });

  it('validates inbound oracle config at the policy seam', async function () {
    const { oracle, admin } = await loadFixture(deployFixture);

    await expect(
      oracle.connect(admin).addOracle(feedId, {
        ...validConfig,
        oracleAddress: ethers.ZeroAddress,
      })
    ).to.be.revertedWith('Invalid oracle address');

    await expect(
      oracle.connect(admin).addOracle(feedId, {
        ...validConfig,
        minConfidence: 0,
      })
    ).to.be.revertedWith('Confidence below minimum');

    await expect(
      oracle.connect(admin).addOracle(feedId, {
        ...validConfig,
        maxStaleness: 24 * 60 * 60 + 1,
      })
    ).to.be.revertedWith('Staleness exceeds maximum');

    await expect(
      oracle.connect(admin).addOracle(feedId, {
        ...validConfig,
        weight: 10001,
      })
    ).to.be.revertedWith('Weight exceeds maximum');
  });

  it('adds and removes an oracle only when active and authorized', async function () {
    const { oracle, admin } = await loadFixture(deployFixture);

    await expect(oracle.connect(admin).addOracle(feedId, validConfig))
      .to.emit(oracle, 'OracleAdded')
      .withArgs(feedId, validConfig.provider, validConfig.oracleAddress);

    const activeAfterAdd = await oracle.oracleConfigs(feedId, validConfig.provider);
    expect(activeAfterAdd.isActive).to.equal(true);

    await expect(
      oracle.connect(admin).removeOracle(feedId, validConfig.provider)
    ).to.emit(oracle, 'OracleRemoved')
      .withArgs(feedId, validConfig.provider, validConfig.oracleAddress);

    const activeAfterRemove = await oracle.oracleConfigs(feedId, validConfig.provider);
    expect(activeAfterRemove.isActive).to.equal(false);

    // Removing again must be rejected by the oracleExists modifier, not merely
    // be a no-op -- this is the "only when active" half of this test's name.
    await expect(
      oracle.connect(admin).removeOracle(feedId, validConfig.provider)
    ).to.be.revertedWith('Oracle not found or inactive');
  });

  it('rejects quality updates from non-updaters and out-of-range scores', async function () {
    const { oracle, updater, other } = await loadFixture(deployFixture);
    const token = ethers.Wallet.createRandom().address;

    await expect(
      oracle.connect(other).updateQualityScore(token, 55)
    ).to.be.revertedWithCustomError(oracle, 'AccessControlUnauthorizedAccount');

    await expect(
      oracle.connect(updater).updateQualityScore(token, 101)
    ).to.be.revertedWith('QualityOracle: Score exceeds maximum');
  });

  it('supports quality score freshness guard and threshold checks', async function () {
    const { oracle, admin, updater } = await loadFixture(deployFixture);
    const token = ethers.Wallet.createRandom().address;

    await oracle.connect(updater).updateQualityScore(token, 92);
    expect(await oracle.getQualityScore(token)).to.equal(92n);
    expect(await oracle.meetsQualityThreshold(token)).to.equal(true);

    await oracle.connect(admin).setQualityThreshold(93);
    expect(await oracle.meetsQualityThreshold(token)).to.equal(false);

    await time.increase(24 * 60 * 60 + 1);
    expect(await oracle.getQualityScore(token)).to.equal(0n);
  });

  it('enforces basket-token self-update identity and batched-array invariants', async function () {
    const { oracle, updater } = await loadFixture(deployFixture);
    const token = ethers.Wallet.createRandom().address;
    const metrics = {
      overallScore: 42,
      vintageScore: 30,
      projectTypeScore: 31,
      verificationScore: 32,
      additionalityScore: 33,
      permanenceScore: 34,
      cobenefitsScore: 35,
      timestamp: 0n,
    };

    await expect(
      oracle.connect(updater).updateFromBasketToken(ethers.Wallet.createRandom().address, 42, metrics)
    ).to.be.revertedWith('QualityOracle: Only token can update itself');

    await expect(
      oracle.connect(updater).batchUpdateQuality([token], [])
    ).to.be.revertedWith('QualityOracle: Array length mismatch');

    await oracle.connect(updater).batchUpdateQuality([token, token], [60, 61]);
    expect(await oracle.getQualityHistoryLength(token)).to.equal(2n);
    expect(await oracle.getQualityHistoryLength(ethers.getAddress('0x0000000000000000000000000000000000000001'))).to.equal(0n);
  });
});
