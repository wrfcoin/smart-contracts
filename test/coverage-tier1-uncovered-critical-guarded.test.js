'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('coverage: critical uncovered contract guard coverage (tier 1)', function () {
  async function deployMockOracleSuite() {
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const MockAggregatorV3 = await ethers.getContractFactory('MockAggregatorV3');
    const MockVolatilityOracle = await ethers.getContractFactory('MockVolatilityOracleConcrete');
    const MockQualityOracle = await ethers.getContractFactory('MockQualityOracleConcrete');
    const MockMultiAssetStaking = await ethers.getContractFactory('MockMultiAssetStaking');

    const wbtc = await MockERC20.deploy('Wrapped Bitcoin', 'WBTC', 8);
    const wbtcFeed = await MockAggregatorV3.deploy(8, 'mock wbtc feed');
    const usdFeed = await MockAggregatorV3.deploy(8, 'mock usd feed');
    const staking = await MockMultiAssetStaking.deploy();

    const usdc = await MockERC20.deploy('USD Coin', 'USDC', 6);
    const cbt = await MockERC20.deploy('Carbon Basket Token', 'CBT', 18);
    const volatilityOracle = await MockVolatilityOracle.deploy();
    const qualityOracle = await MockQualityOracle.deploy();

    return {
      wbtc,
      wbtcFeed,
      usdFeed,
      staking,
      usdc,
      cbt,
      volatilityOracle,
      qualityOracle,
    };
  }

  it('BTCStakeRegistry rejects an invalid WBTC token dependency', async function () {
    const [admin] = await ethers.getSigners();
    const { wbtcFeed, usdFeed, staking } = await deployMockOracleSuite();

    const BTCStakeRegistry = await ethers.getContractFactory('BTCStakeRegistry');
    await expect(
      BTCStakeRegistry.deploy(
        ethers.ZeroAddress,
        await wbtcFeed.getAddress(),
        await usdFeed.getAddress(),
        await staking.getAddress(),
        await admin.getAddress()
      )
    ).to.be.revertedWith('Invalid WBTC token');
  });

  it('InsuranceGovernance rejects an invalid WRF token address', async function () {
    const InsuranceGovernance = await ethers.getContractFactory('InsuranceGovernance');
    await expect(InsuranceGovernance.deploy(ethers.ZeroAddress)).to.be.revertedWith(
      'Invalid WRF token address'
    );
  });

  it('WeightedCarbonPool initialize rejects invalid weight allocation', async function () {
    const [admin] = await ethers.getSigners();
    const { usdc, cbt, volatilityOracle, qualityOracle } = await deployMockOracleSuite();
    const WeightedCarbonPool = await ethers.getContractFactory('WeightedCarbonPool');
    const pool = await WeightedCarbonPool.deploy();

    await expect(
      pool.initialize(
        await usdc.getAddress(),
        await cbt.getAddress(),
        1n * 10n ** 18n + 1n,
        1n * 10n ** 18n,
        10,
        await volatilityOracle.getAddress(),
        await qualityOracle.getAddress(),
        await admin.getAddress()
      )
    ).to.be.revertedWith('WeightedCarbonPool: Invalid weights');
  });

  it('EnhancedTreasury constructor rejects zero admin', async function () {
    const [admin, timelock] = await ethers.getSigners();
    const EnhancedTreasury = await ethers.getContractFactory('EnhancedTreasury');

    await expect(
      EnhancedTreasury.deploy(
        ethers.ZeroAddress,
        await timelock.getAddress(),
        1000
      )
    ).to.be.revertedWith('ET: Invalid admin address');
  });

  it('EnhancedTreasury constructor rejects zero timelock', async function () {
    const [admin] = await ethers.getSigners();
    const EnhancedTreasury = await ethers.getContractFactory('EnhancedTreasury');

    await expect(
      EnhancedTreasury.deploy(
        await admin.getAddress(),
        ethers.ZeroAddress,
        1000
      )
    ).to.be.revertedWith('ET: Invalid timelock address');
  });

  it('EnhancedTreasury constructor enforces minimum emergency fund percentage', async function () {
    const [admin] = await ethers.getSigners();
    const EnhancedTreasury = await ethers.getContractFactory('EnhancedTreasury');

    await expect(
      EnhancedTreasury.deploy(
        await admin.getAddress(),
        await admin.getAddress(),
        999
      )
    ).to.be.revertedWith('ET: Emergency fund too low');
  });

  it('GovernanceAnalytics blocks non-manager snapshot updates', async function () {
    const [admin, outsider] = await ethers.getSigners();
    const GovernanceAnalytics = await ethers.getContractFactory('GovernanceAnalytics');
    const analytics = await GovernanceAnalytics.deploy(await admin.getAddress());
    await expect(analytics.connect(outsider).takeSnapshot()).to.be.revertedWithCustomError(
      analytics,
      'AccessControlUnauthorizedAccount'
    );
  });

  it('PollutionDataOracle constructor rejects invalid treasury address', async function () {
    const [admin] = await ethers.getSigners();
    const PollutionDataOracle = await ethers.getContractFactory('PollutionDataOracle');
    const rewardToken = await ethers.getContractFactory('MockERC20');
    const mockRewardToken = await rewardToken.deploy('Reward Token', 'RWT', 18);

    await expect(
      PollutionDataOracle.deploy(
        await mockRewardToken.getAddress(),
        ethers.ZeroAddress,
        await admin.getAddress()
      )
    ).to.be.revertedWith('PollutionOracle: invalid treasury');
  });

  it('ComprehensiveGovernanceSecurity requires at least three guardian members', async function () {
    const [admin] = await ethers.getSigners();
    const ComprehensiveGovernanceSecurity = await ethers.getContractFactory('ComprehensiveGovernanceSecurity');

    await expect(
      ComprehensiveGovernanceSecurity.deploy(
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        await admin.getAddress(),
        [await admin.getAddress()]
      )
    ).to.be.revertedWith('CGS: Minimum 3 guardians required');
  });

  it('SecureMultiSigWallet rejects duplicate owner addresses', async function () {
    const [admin] = await ethers.getSigners();
    const SecureMultiSigWallet = await ethers.getContractFactory('SecureMultiSigWallet');
    const adminAddress = await admin.getAddress();

    await expect(
      SecureMultiSigWallet.deploy(
        [adminAddress, adminAddress],
        2,
        1000,
        adminAddress
      )
    ).to.be.revertedWith('SecureMultiSigWallet: Duplicate owner');
  });
});
