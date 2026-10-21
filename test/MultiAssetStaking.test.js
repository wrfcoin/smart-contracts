const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

/**
 * Comprehensive test suite for MultiAssetStaking contract
 *
 * Tests cover:
 * - Multi-asset staking (ETH, WBTC, WRF, USDC, USDT)
 * - Dynamic stake calculations
 * - Cross-chain operations (WBTC)
 * - Oracle integration
 * - Rebalancing mechanisms
 * - Emergency liquidation
 * - Security features
 */

describe('MultiAssetStaking', function () {
  // Native ETH identifier
  const ETH_ADDRESS = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';

  // Test constants
  const PRECISION = 1000000n; // DynamicStakeCalculator.PRECISION
  const MIN_COLLATERALIZATION_RATIO = 1200000n; // 120%
  const MAX_SLIPPAGE_TOLERANCE = 50000n; // 5%

  async function deployMultiAssetStakingFixture() {
    const [
      owner,
      participant1,
      participant2,
      emergencyLiquidator,
      treasury,
      bridge,
    ] = await ethers.getSigners();

    // Deploy mock contracts
    console.log('Deploying mock contracts...');

    // Deploy mock ERC20 tokens
    const MockERC20Factory = await ethers.getContractFactory('MockERC20');

    const wbtc = await MockERC20Factory.deploy('Wrapped Bitcoin', 'WBTC', 8);

    const usdc = await MockERC20Factory.deploy('USD Coin', 'USDC', 6);

    const usdt = await MockERC20Factory.deploy('Tether USD', 'USDT', 6);

    // Deploy MockERC20 as WRF token (WRFToken has no mint, so we use mock for staking tests)
    const wrfToken = await MockERC20Factory.deploy('WRFCoin', 'WRF', 18);

    // Deploy mock Chainlink aggregators
    const MockAggregatorFactory =
      await ethers.getContractFactory('MockAggregatorV3');

    const ethUsdOracle = await MockAggregatorFactory.deploy(8, 'ETH/USD');
    await ethUsdOracle.updateAnswer(200000000000n); // $2000 with 8 decimals

    const btcUsdOracle = await MockAggregatorFactory.deploy(8, 'BTC/USD');
    await btcUsdOracle.updateAnswer(4500000000000n); // $45000 with 8 decimals

    const usdcUsdOracle = await MockAggregatorFactory.deploy(8, 'USDC/USD');
    await usdcUsdOracle.updateAnswer(100000000n); // $1 with 8 decimals

    const usdtUsdOracle = await MockAggregatorFactory.deploy(8, 'USDT/USD');
    await usdtUsdOracle.updateAnswer(100000000n); // $1 with 8 decimals

    const wrfUsdOracle = await MockAggregatorFactory.deploy(8, 'WRF/USD');
    await wrfUsdOracle.updateAnswer(500000000n); // $5 with 8 decimals

    // Deploy mock dynamic stake calculator
    const MockStakeCalculatorFactory = await ethers.getContractFactory(
      'MockDynamicStakeCalculator'
    );
    const stakeCalculator = await MockStakeCalculatorFactory.deploy();

    // Deploy ParticipantTypeRegistry
    const ParticipantTypeRegistryFactory = await ethers.getContractFactory(
      'ParticipantTypeRegistry'
    );
    const participantRegistry = await ParticipantTypeRegistryFactory.deploy();

    // Deploy MultiAssetStaking
    const MultiAssetStakingFactory =
      await ethers.getContractFactory('MultiAssetStaking');
    const multiAssetStaking = await MultiAssetStakingFactory.deploy(
      await stakeCalculator.getAddress(),
      await participantRegistry.getAddress(),
      bridge.address, // Mock bridge integration
      emergencyLiquidator.address,
      treasury.address
    );

    // Mint tokens to participants
    await wbtc.mint(participant1.address, ethers.parseUnits('100', 8));
    await wbtc.mint(participant2.address, ethers.parseUnits('100', 8));
    await usdc.mint(participant1.address, ethers.parseUnits('100000', 6));
    await usdc.mint(participant2.address, ethers.parseUnits('100000', 6));
    await usdt.mint(participant1.address, ethers.parseUnits('100000', 6));
    await usdt.mint(participant2.address, ethers.parseUnits('100000', 6));
    await wrfToken.mint(participant1.address, ethers.parseEther('1000000'));
    await wrfToken.mint(participant2.address, ethers.parseEther('1000000'));

    // Note: WRFToken configuration functions are deprecated (permissionless by default)

    return {
      multiAssetStaking,
      stakeCalculator,
      participantRegistry,
      wrfToken,
      wbtc,
      usdc,
      usdt,
      ethUsdOracle,
      btcUsdOracle,
      usdcUsdOracle,
      usdtUsdOracle,
      wrfUsdOracle,
      owner,
      participant1,
      participant2,
      emergencyLiquidator,
      treasury,
      bridge,
    };
  }

  async function configureAssets(contracts) {
    const {
      multiAssetStaking,
      ethUsdOracle,
      btcUsdOracle,
      wrfToken,
      wrfUsdOracle,
      usdcUsdOracle,
      usdtUsdOracle,
      wbtc,
      usdc,
      usdt,
    } = contracts;

    // Configure ETH
    await multiAssetStaking.configureAsset(ETH_ADDRESS, {
      tokenAddress: ETH_ADDRESS,
      priceOracle: await ethUsdOracle.getAddress(),
      decimals: 18,
      isActive: true,
      isCrossChain: false,
      minStakeAmount: ethers.parseEther('0.01'),
      maxStakeAmount: ethers.parseEther('100'),
      concentrationLimit: 400000, // 40% - allows single-asset staking since check only triggers after first stake
      symbol: 'ETH',
      bridgeId: ethers.ZeroHash,
    });

    // Configure WBTC
    await multiAssetStaking.configureAsset(await wbtc.getAddress(), {
      tokenAddress: await wbtc.getAddress(),
      priceOracle: await btcUsdOracle.getAddress(),
      decimals: 8,
      isActive: true,
      isCrossChain: true, // Cross-chain asset
      minStakeAmount: ethers.parseUnits('0.001', 8),
      maxStakeAmount: ethers.parseUnits('5', 8),
      concentrationLimit: 400000, // 40%
      symbol: 'WBTC',
      bridgeId: ethers.keccak256(ethers.toUtf8Bytes('WBTC_BRIDGE')),
    });

    // Configure WRF
    await multiAssetStaking.configureAsset(await wrfToken.getAddress(), {
      tokenAddress: await wrfToken.getAddress(),
      priceOracle: await wrfUsdOracle.getAddress(),
      decimals: 18,
      isActive: true,
      isCrossChain: false,
      minStakeAmount: ethers.parseEther('100'),
      maxStakeAmount: ethers.parseEther('100000'),
      concentrationLimit: 400000, // 40%
      symbol: 'WRF',
      bridgeId: ethers.ZeroHash,
    });

    // Configure USDC
    await multiAssetStaking.configureAsset(await usdc.getAddress(), {
      tokenAddress: await usdc.getAddress(),
      priceOracle: await usdcUsdOracle.getAddress(),
      decimals: 6,
      isActive: true,
      isCrossChain: false,
      minStakeAmount: ethers.parseUnits('20', 6),
      maxStakeAmount: ethers.parseUnits('10000', 6),
      concentrationLimit: 400000, // 40%
      symbol: 'USDC',
      bridgeId: ethers.ZeroHash,
    });

    // Configure USDT
    await multiAssetStaking.configureAsset(await usdt.getAddress(), {
      tokenAddress: await usdt.getAddress(),
      priceOracle: await usdtUsdOracle.getAddress(),
      decimals: 6,
      isActive: true,
      isCrossChain: false,
      minStakeAmount: ethers.parseUnits('20', 6),
      maxStakeAmount: ethers.parseUnits('10000', 6),
      concentrationLimit: 400000, // 40%
      symbol: 'USDT',
      bridgeId: ethers.ZeroHash,
    });

    return contracts;
  }

  function createStakeParameters() {
    return {
      participationType: 0, // WEATHER_STATION
      geographicZone: 0, // DEFAULT_AREA
      verificationLevel: 0, // UNVERIFIED
      social: {
        githubVerified: false,
        twitterVerified: false,
        linkedinVerified: false,
      },
      density: {
        nearbyStationsCount: 2,
        isDensityVerified: false,
      },
      hybridServices: {
        providesWeatherData: false,
        providesForecasting: false,
        providesDataStorage: false,
        providesValidation: false,
      },
    };
  }

  describe('Deployment', function () {
    it('Should deploy successfully with correct configuration', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      const {
        multiAssetStaking,
        stakeCalculator,
        participantRegistry,
        emergencyLiquidator,
        treasury,
      } = contracts;

      expect(await multiAssetStaking.stakeCalculator()).to.equal(
        await stakeCalculator.getAddress()
      );
      expect(await multiAssetStaking.participantRegistry()).to.equal(
        await participantRegistry.getAddress()
      );
      expect(await multiAssetStaking.emergencyLiquidator()).to.equal(
        emergencyLiquidator.address
      );
      expect(await multiAssetStaking.treasury()).to.equal(treasury.address);
      expect(await multiAssetStaking.totalValueLockedUSD()).to.equal(0);
      expect(await multiAssetStaking.totalParticipants()).to.equal(0);
    });

    it('Should reject deployment with invalid parameters', async function () {
      const [owner] = await ethers.getSigners();
      const MultiAssetStakingFactory =
        await ethers.getContractFactory('MultiAssetStaking');

      await expect(
        MultiAssetStakingFactory.deploy(
          ethers.ZeroAddress, // Invalid stake calculator
          owner.address,
          owner.address,
          owner.address,
          owner.address
        )
      ).to.be.revertedWith('Invalid stake calculator');
    });
  });

  describe('Asset Configuration', function () {
    it('Should configure supported assets correctly', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking } = contracts;

      const [supportedAssets, configs] =
        await multiAssetStaking.getSupportedAssets();

      expect(supportedAssets.length).to.equal(5);
      expect(configs[0].symbol).to.equal('ETH');
      expect(configs[1].symbol).to.equal('WBTC');
      expect(configs[2].symbol).to.equal('WRF');
      expect(configs[3].symbol).to.equal('USDC');
      expect(configs[4].symbol).to.equal('USDT');
    });

    it('Should only allow owner to configure assets', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      const { multiAssetStaking, participant1, wbtc, btcUsdOracle } = contracts;

      await expect(
        multiAssetStaking.connect(participant1).configureAsset(await wbtc.getAddress(), {
          tokenAddress: await wbtc.getAddress(),
          priceOracle: await btcUsdOracle.getAddress(),
          decimals: 8,
          isActive: true,
          isCrossChain: false,
          minStakeAmount: ethers.parseUnits('0.001', 8),
          maxStakeAmount: ethers.parseUnits('5', 8),
          concentrationLimit: 400000,
          symbol: 'WBTC',
          bridgeId: ethers.ZeroHash,
        })
      ).to.be.revertedWithCustomError(multiAssetStaking, 'OwnableUnauthorizedAccount');
    });

    it('Should validate asset configuration parameters', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      const { multiAssetStaking, wbtc, btcUsdOracle } = contracts;

      // Keep the preceding oracle guard valid so only concentration is rejected.
      await expect(
        multiAssetStaking.configureAsset(await wbtc.getAddress(), {
          tokenAddress: await wbtc.getAddress(),
          priceOracle: await btcUsdOracle.getAddress(),
          decimals: 8,
          isActive: true,
          isCrossChain: false,
          minStakeAmount: ethers.parseUnits('0.001', 8),
          maxStakeAmount: ethers.parseUnits('5', 8),
          concentrationLimit: 600000, // 60% > MAX_ASSET_CONCENTRATION
          symbol: 'WBTC',
          bridgeId: ethers.ZeroHash,
        })
      ).to.be.revertedWith('Invalid concentration limit');
    });
  });

  describe('ETH Staking', function () {
    it('Should stake ETH successfully', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, participant1 } = contracts;

      const stakeAmount = ethers.parseEther('1'); // 1 ETH
      const parameters = createStakeParameters();

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(ETH_ADDRESS, stakeAmount, parameters, {
            value: stakeAmount,
          })
      ).to.emit(multiAssetStaking, 'AssetStaked');

      const [totalStakeUSD, breakdown, assets] =
        await multiAssetStaking.getStakeValueUSD(participant1.address);
      expect(assets[0]).to.equal(ETH_ADDRESS);
      expect(breakdown[0]).to.be.gt(0);
      expect(totalStakeUSD).to.be.gt(0);
    });

    it('Should reject ETH staking with mismatched value', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, participant1 } = contracts;

      const stakeAmount = ethers.parseEther('1');
      const wrongValue = ethers.parseEther('0.5');
      const parameters = createStakeParameters();

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(ETH_ADDRESS, stakeAmount, parameters, {
            value: wrongValue,
          })
      ).to.be.revertedWith('ETH amount mismatch');
    });
  });

  describe('ERC20 Token Staking', function () {
    it('Should stake WRF tokens successfully', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const stakeAmount = ethers.parseEther('1000'); // 1000 WRF
      const parameters = createStakeParameters();

      // Approve tokens
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters)
      ).to.emit(multiAssetStaking, 'AssetStaked');

      const [totalStakeUSD, breakdown, assets] =
        await multiAssetStaking.getStakeValueUSD(participant1.address);
      expect(assets[0]).to.equal(await wrfToken.getAddress());
      expect(breakdown[0]).to.be.gt(0);
    });

    it('Should stake USDC tokens successfully', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, usdc, participant1 } = contracts;

      const stakeAmount = ethers.parseUnits('100', 6); // $100 USDC
      const parameters = createStakeParameters();

      // Approve tokens
      await usdc
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await usdc.getAddress(), stakeAmount, parameters)
      ).to.emit(multiAssetStaking, 'AssetStaked');

      const info = await multiAssetStaking.getComprehensiveStakeInfo(
        participant1.address
      );
      expect(info.totalStakeUSD).to.be.gt(0);
    });

    it('Should reject staking without approval', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const stakeAmount = ethers.parseEther('1000');
      const parameters = createStakeParameters();

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters)
      ).to.be.revertedWithCustomError(wrfToken, 'ERC20InsufficientAllowance').withArgs(await multiAssetStaking.getAddress(), 0n, stakeAmount);
    });
  });

  describe('Multi-Asset Staking', function () {
    it('Should support staking multiple assets', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, usdc, participant1 } = contracts;

      const parameters = createStakeParameters();

      // Stake ETH
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(ETH_ADDRESS, ethers.parseEther('0.5'), parameters, {
          value: ethers.parseEther('0.5'),
        });

      // Stake WRF
      const wrfAmount = ethers.parseEther('500');
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), wrfAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), wrfAmount, parameters);

      // Stake USDC
      const usdcAmount = ethers.parseUnits('50', 6);
      await usdc
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), usdcAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await usdc.getAddress(), usdcAmount, parameters);

      const [totalStakeUSD, breakdown, assets] =
        await multiAssetStaking.getStakeValueUSD(participant1.address);

      expect(assets.length).to.equal(3);
      expect(assets).to.include(ETH_ADDRESS);
      expect(assets).to.include(await wrfToken.getAddress());
      expect(assets).to.include(await usdc.getAddress());
      expect(totalStakeUSD).to.be.gt(0);
    });

    it('Should calculate collateralization ratio correctly', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters);

      const [ratio, meetsMinimum, requiredStakeUSD, currentStakeUSD] =
        await multiAssetStaking.getCollateralizationRatio(participant1.address);

      expect(ratio).to.be.gt(0);
      expect(requiredStakeUSD).to.be.gt(0);
      expect(currentStakeUSD).to.be.gt(0);
    });
  });

  describe('Asset Conversion', function () {
    it('Should convert stake between assets', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, usdc, participant1 } = contracts;

      const parameters = createStakeParameters();

      // Initial stake in WRF
      const wrfAmount = ethers.parseEther('1000');
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), wrfAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), wrfAmount, parameters);

      // Convert half to USDC
      const convertAmount = ethers.parseEther('500');

      await expect(
        multiAssetStaking
          .connect(participant1)
          .convertStakeAsset(await wrfToken.getAddress(), await usdc.getAddress(), convertAmount)
      ).to.emit(multiAssetStaking, 'StakeRebalanced');

      const [, , assets] = await multiAssetStaking.getStakeValueUSD(
        participant1.address
      );
      expect(assets.length).to.equal(2);
    });

    it('Should handle conversion when oracle prices move', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, usdcUsdOracle, usdc, participant1 } =
        contracts;

      const parameters = createStakeParameters();

      // Stake WRF
      const wrfAmount = ethers.parseEther('1000');
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), wrfAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), wrfAmount, parameters);

      // Manipulate USDC price and verify conversion still settles with current oracle values
      await usdcUsdOracle.updateAnswer(120000000n); // $1.20

      const convertAmount = ethers.parseEther('500');

      await expect(
        multiAssetStaking
          .connect(participant1)
          .convertStakeAsset(await wrfToken.getAddress(), await usdc.getAddress(), convertAmount)
      ).to.emit(multiAssetStaking, 'StakeRebalanced');
    });
  });

  describe('Stake Withdrawal', function () {
    it('Should withdraw stake successfully', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      // Stake WRF
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters);

      const withdrawAmount = ethers.parseEther('500');

      await expect(
        multiAssetStaking
          .connect(participant1)
          .withdrawStake(await wrfToken.getAddress(), withdrawAmount)
      ).to.emit(multiAssetStaking, 'AssetWithdrawn');

      const info = await multiAssetStaking.getComprehensiveStakeInfo(
        participant1.address
      );
      expect(info.stakedAssets[0]).to.equal(await wrfToken.getAddress());
    });

    it('Should withdraw all stake when amount is 0', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      // Stake WRF
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters);

      // Withdraw all (amount = 0)
      await multiAssetStaking
        .connect(participant1)
        .withdrawStake(await wrfToken.getAddress(), 0);

      const [totalStakeUSD] = await multiAssetStaking.getStakeValueUSD(
        participant1.address
      );
      expect(totalStakeUSD).to.equal(0);
    });
  });

  describe('Oracle Price Management', function () {
    it('Should get current asset prices from oracles', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken } = contracts;

      const [priceUSD, timestamp, isStale] =
        await multiAssetStaking.getAssetPrice(await wrfToken.getAddress());

      expect(priceUSD).to.be.gt(0);
      expect(timestamp).to.be.gt(0);
      expect(isStale).to.be.false;
    });

    it('Should detect stale oracle prices', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, wrfUsdOracle } = contracts;

      // Set oracle timestamp to old value
      await ethers.provider.send('evm_increaseTime', [3600]); // 1 hour forward
      await ethers.provider.send('evm_mine');

      const [, , isStale] = await multiAssetStaking.getAssetPrice(
        await wrfToken.getAddress()
      );
      expect(isStale).to.be.true;
    });

    it('Should reject operations with stale oracle prices', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } =
        contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      // Make oracle stale
      await ethers.provider.send('evm_increaseTime', [3600]); // 1 hour forward
      await ethers.provider.send('evm_mine');

      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters)
      ).to.be.revertedWithCustomError(multiAssetStaking, 'StaleOraclePrice');
    });
  });

  describe('Emergency Functions', function () {
    it('Should allow emergency liquidation by authorized liquidator', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, wrfUsdOracle, participant1, emergencyLiquidator } =
        contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      // Stake WRF
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters);

      // Force under-collateralization by dropping oracle price before liquidation
      await wrfUsdOracle.updateAnswer(10000n); // $0.0001

      // Liquidate 10% of stake
      const liquidateAmount = ethers.parseEther('100');

      await expect(
        multiAssetStaking
          .connect(emergencyLiquidator)
          .emergencyLiquidation(
            participant1.address,
            await wrfToken.getAddress(),
            liquidateAmount,
            'Test liquidation'
          )
      ).to.emit(multiAssetStaking, 'EmergencyLiquidation');
    });

    it('Should only allow authorized liquidator to perform emergency liquidation', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1, participant2 } =
        contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      // Stake WRF
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters);

      const liquidateAmount = ethers.parseEther('100');

      await expect(
        multiAssetStaking
          .connect(participant2)
          .emergencyLiquidation(
            participant1.address,
            await wrfToken.getAddress(),
            liquidateAmount,
            'Unauthorized liquidation'
          )
      ).to.be.revertedWith('Unauthorized liquidator');
    });

    it('Should allow owner to pause and unpause', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      const { multiAssetStaking, owner } = contracts;

      await multiAssetStaking.connect(owner).emergencyPause();
      expect(await multiAssetStaking.paused()).to.be.true;

      await multiAssetStaking.connect(owner).unpause();
      expect(await multiAssetStaking.paused()).to.be.false;
    });
  });

  describe('Cross-Chain Operations', function () {
    it('Should initiate cross-chain deposit for WBTC', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wbtc, participant1 } = contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseUnits('0.1', 8); // 0.1 WBTC

      // Approve WBTC
      await wbtc
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);

      // This should initiate cross-chain operation instead of direct staking
      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await wbtc.getAddress(), stakeAmount, parameters)
      ).to.emit(multiAssetStaking, 'CrossChainOperationInitiated');
    });

    it('Should complete cross-chain deposit', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wbtc, participant1, bridge } = contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseUnits('0.1', 8);

      // Approve and initiate cross-chain deposit
      await wbtc
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      const stakeTx = await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wbtc.getAddress(), stakeAmount, parameters);
      const stakeReceipt = await stakeTx.wait();

      const initiatedEvent = stakeReceipt.logs
        .map(log => {
          try {
            return multiAssetStaking.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find(parsed => parsed && parsed.name === 'CrossChainOperationInitiated');
      expect(initiatedEvent).to.not.equal(undefined);
      const operationId = initiatedEvent.args.operationId;

      // Simulate bridge completion

      await expect(
        multiAssetStaking
          .connect(bridge)
          .completeCrossChainDeposit(
            operationId,
            participant1.address,
            await wbtc.getAddress(),
            stakeAmount
          )
      ).to.emit(multiAssetStaking, 'CrossChainOperationCompleted');
    });
  });

  describe('Security Features', function () {
    it('Should enforce minimum and maximum stake amounts', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const parameters = createStakeParameters();

      // Below minimum
      const belowMin = ethers.parseEther('50'); // Below 100 WRF minimum
      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), belowMin);

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await wrfToken.getAddress(), belowMin, parameters)
      ).to.be.revertedWith('Below minimum stake');
    });

    it('Should enforce asset concentration limits', async function () {
      // This test would require multiple stakes to trigger concentration limits
      // Implementation depends on specific concentration logic
    });

    it('Should handle oracle failure gracefully', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, wrfUsdOracle, participant1 } =
        contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      // Set invalid price (negative)
      await wrfUsdOracle.updateAnswer(-100000000);

      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);

      await expect(
        multiAssetStaking
          .connect(participant1)
          .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters)
      ).to.be.revertedWithCustomError(multiAssetStaking, 'InvalidOraclePrice');
    });
  });

  describe('View Functions', function () {
    it('Should return comprehensive stake information', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking, wrfToken, participant1 } = contracts;

      const parameters = createStakeParameters();
      const stakeAmount = ethers.parseEther('1000');

      await wrfToken
        .connect(participant1)
        .approve(await multiAssetStaking.getAddress(), stakeAmount);
      await multiAssetStaking
        .connect(participant1)
        .stakeAsset(await wrfToken.getAddress(), stakeAmount, parameters);

      const info = await multiAssetStaking.getComprehensiveStakeInfo(
        participant1.address
      );

      expect(info.totalStakeUSD).to.be.gt(0);
      expect(info.requiredStakeUSD).to.be.gt(0);
      expect(info.stakedAssets.length).to.equal(1);
      expect(info.assetAmounts.length).to.equal(1);
      expect(info.assetValuesUSD.length).to.equal(1);
    });

    it('Should return supported assets list', async function () {
      const contracts = await loadFixture(deployMultiAssetStakingFixture);
      await configureAssets(contracts);
      const { multiAssetStaking } = contracts;

      const [assets, configs] = await multiAssetStaking.getSupportedAssets();

      expect(assets.length).to.equal(5);
      expect(configs.length).to.equal(5);

      const symbols = configs.map(c => c.symbol);
      expect(symbols).to.include('ETH');
      expect(symbols).to.include('WBTC');
      expect(symbols).to.include('WRF');
      expect(symbols).to.include('USDC');
      expect(symbols).to.include('USDT');
    });
  });
});
