const { ethers, network } = require('hardhat');
require('dotenv').config();
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('../scripts/lib/launchReadiness');

/**
 * Deployment script for MultiAssetStaking contract
 *
 * This script deploys the MultiAssetStaking contract and configures it with:
 * - ETH (native Ethereum)
 * - WBTC (Wrapped Bitcoin)
 * - WRF (WRFCoin native token)
 * - USDC (USD Coin)
 * - USDT (Tether USD)
 *
 * It also sets up Chainlink price oracles for each asset and configures
 * cross-chain bridge integrations for WBTC.
 */

// Asset addresses - these would be mainnet addresses in production
const ASSET_ADDRESSES = {
  // Native ETH represented by special address
  ETH: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',

  // Mainnet addresses (examples - update for specific network)
  WBTC:
    process.env.WBTC_ADDRESS || '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
  USDC:
    process.env.USDC_ADDRESS || '0xA0b86a33E6441E5040dc2e0c9EF5C87dC5a3b79e',
  USDT:
    process.env.USDT_ADDRESS || '0xdAC17F958D2ee523a2206206994597C13D831ec7',
  WRF: null, // Will be set after WRFToken deployment
};

// Chainlink Price Feed addresses (Ethereum mainnet)
const PRICE_FEEDS = {
  ETH_USD:
    process.env.ETH_USD_FEED || '0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419',
  BTC_USD:
    process.env.BTC_USD_FEED || '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c',
  USDC_USD:
    process.env.USDC_USD_FEED || '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6',
  USDT_USD:
    process.env.USDT_USD_FEED || '0x3E7d1eAB13ad0104d2750B8863b489D65364e32D',
};

// Bridge IDs for cross-chain assets
const BRIDGE_IDS = {
  WBTC: ethers.utils.keccak256(ethers.utils.toUtf8Bytes('WBTC_BRIDGE')),
  // Future bridge IDs can be added here
};

async function main() {
  requireLiveDeployConfig(network);

  console.log('🚀 Starting MultiAssetStaking deployment...');

  const [deployer] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  console.log('Deploying contracts with account:', deployer.address);
  console.log(
    'Account balance:',
    ethers.utils.formatEther(await deployer.getBalance())
  );

  // ========== DEPLOY DEPENDENCIES ==========

  let stakeCalculator, participantRegistry, bridgeIntegration, wrfToken;

  try {
    // Check if DynamicStakeCalculator is deployed
    console.log('\n📋 Checking for existing DynamicStakeCalculator...');
    const StakeCalculatorFactory = await ethers.getContractFactory(
      'DynamicStakeCalculator'
    );

    if (process.env.STAKE_CALCULATOR_ADDRESS) {
      stakeCalculator = StakeCalculatorFactory.attach(
        process.env.STAKE_CALCULATOR_ADDRESS
      );
      console.log(
        '✅ Using existing DynamicStakeCalculator at:',
        stakeCalculator.address
      );
    } else {
      console.log(
        '⚠️  DynamicStakeCalculator not found, would need to deploy FairLaunchStakeManager first'
      );
      throw new Error(
        'Missing DynamicStakeCalculator - deploy FairLaunchStakeManager first'
      );
    }

    // Check for ParticipantTypeRegistry
    console.log('\n📋 Checking for existing ParticipantTypeRegistry...');
    const RegistryFactory = await ethers.getContractFactory(
      'ParticipantTypeRegistry'
    );

    if (process.env.PARTICIPANT_REGISTRY_ADDRESS) {
      participantRegistry = RegistryFactory.attach(
        process.env.PARTICIPANT_REGISTRY_ADDRESS
      );
      console.log(
        '✅ Using existing ParticipantTypeRegistry at:',
        participantRegistry.address
      );
    } else {
      console.log('🚀 Deploying ParticipantTypeRegistry...');
      participantRegistry = await RegistryFactory.deploy();
      await participantRegistry.deployed();
      console.log(
        '✅ ParticipantTypeRegistry deployed at:',
        participantRegistry.address
      );
    }

    // Check for SecureBridgeIntegration
    console.log('\n📋 Checking for existing SecureBridgeIntegration...');
    const BridgeFactory = await ethers.getContractFactory(
      'SecureBridgeIntegration'
    );

    if (process.env.BRIDGE_INTEGRATION_ADDRESS) {
      bridgeIntegration = BridgeFactory.attach(
        process.env.BRIDGE_INTEGRATION_ADDRESS
      );
      console.log(
        '✅ Using existing SecureBridgeIntegration at:',
        bridgeIntegration.address
      );
    } else {
      console.log(
        '⚠️  SecureBridgeIntegration not found, this needs to be deployed separately'
      );
      console.log(
        "💡 For now, we'll use the deployer address as a placeholder"
      );
      // In production, this should be the actual bridge integration contract
    }

    // Check for WRFToken
    console.log('\n📋 Checking for existing WRFToken...');
    const WRFTokenFactory = await ethers.getContractFactory('WRFToken');

    if (process.env.WRF_TOKEN_ADDRESS) {
      wrfToken = WRFTokenFactory.attach(process.env.WRF_TOKEN_ADDRESS);
      ASSET_ADDRESSES.WRF = wrfToken.address;
      console.log('✅ Using existing WRFToken at:', wrfToken.address);
    } else {
      console.log('🚀 Deploying WRFToken...');
      wrfToken = await WRFTokenFactory.deploy();
      await wrfToken.deployed();
      ASSET_ADDRESSES.WRF = wrfToken.address;
      console.log('✅ WRFToken deployed at:', wrfToken.address);
    }
  } catch (error) {
    console.error('❌ Error checking/deploying dependencies:', error.message);
    throw error;
  }

  // ========== DEPLOY MULTI-ASSET STAKING ==========

  console.log('\n🏗️  Deploying MultiAssetStaking...');

  const MultiAssetStakingFactory =
    await ethers.getContractFactory('MultiAssetStaking');

  // Constructor parameters
  const stakeCalculatorAddress =
    process.env.STAKE_CALCULATOR_ADDRESS ||
    process.env.FAIR_LAUNCH_STAKE_MANAGER_ADDRESS;
  const participantRegistryAddress = participantRegistry.address;
  const bridgeIntegrationAddress =
    process.env.BRIDGE_INTEGRATION_ADDRESS || deployer.address;
  const emergencyLiquidator =
    process.env.EMERGENCY_LIQUIDATOR || deployer.address;
  const treasury = process.env.TREASURY_ADDRESS || deployer.address;

  if (!stakeCalculatorAddress) {
    throw new Error(
      'Missing stake calculator address - set STAKE_CALCULATOR_ADDRESS or FAIR_LAUNCH_STAKE_MANAGER_ADDRESS'
    );
  }

  console.log('Constructor parameters:');
  console.log('  - stakeCalculator:', stakeCalculatorAddress);
  console.log('  - participantRegistry:', participantRegistryAddress);
  console.log('  - bridgeIntegration:', bridgeIntegrationAddress);
  console.log('  - emergencyLiquidator:', emergencyLiquidator);
  console.log('  - treasury:', treasury);

  const multiAssetStaking = await MultiAssetStakingFactory.deploy(
    stakeCalculatorAddress,
    participantRegistryAddress,
    bridgeIntegrationAddress,
    emergencyLiquidator,
    treasury
  );

  await multiAssetStaking.deployed();
  console.log('✅ MultiAssetStaking deployed at:', multiAssetStaking.address);

  // ========== CONFIGURE SUPPORTED ASSETS ==========

  console.log('\n⚙️  Configuring supported assets...');

  const assetConfigs = [
    {
      name: 'ETH',
      address: ASSET_ADDRESSES.ETH,
      config: {
        tokenAddress: ASSET_ADDRESSES.ETH,
        priceOracle: PRICE_FEEDS.ETH_USD,
        decimals: 18,
        isActive: true,
        isCrossChain: false,
        minStakeAmount: ethers.utils.parseEther('0.01'), // 0.01 ETH minimum
        maxStakeAmount: ethers.utils.parseEther('100'), // 100 ETH maximum
        concentrationLimit: 400000, // 40% max concentration
        symbol: 'ETH',
        bridgeId: ethers.constants.HashZero,
      },
    },
    {
      name: 'WBTC',
      address: ASSET_ADDRESSES.WBTC,
      config: {
        tokenAddress: ASSET_ADDRESSES.WBTC,
        priceOracle: PRICE_FEEDS.BTC_USD,
        decimals: 8,
        isActive: true,
        isCrossChain: true, // WBTC requires cross-chain operations
        minStakeAmount: ethers.utils.parseUnits('0.001', 8), // 0.001 WBTC minimum
        maxStakeAmount: ethers.utils.parseUnits('5', 8), // 5 WBTC maximum
        concentrationLimit: 500000, // 50% max concentration (Bitcoin is primary)
        symbol: 'WBTC',
        bridgeId: BRIDGE_IDS.WBTC,
      },
    },
    {
      name: 'WRF',
      address: ASSET_ADDRESSES.WRF,
      config: {
        tokenAddress: ASSET_ADDRESSES.WRF,
        priceOracle: PRICE_FEEDS.ETH_USD, // Placeholder - would need WRF/USD feed
        decimals: 18,
        isActive: true,
        isCrossChain: false,
        minStakeAmount: ethers.utils.parseEther('100'), // 100 WRF minimum
        maxStakeAmount: ethers.utils.parseEther('100000'), // 100K WRF maximum
        concentrationLimit: 300000, // 30% max concentration
        symbol: 'WRF',
        bridgeId: ethers.constants.HashZero,
      },
    },
    {
      name: 'USDC',
      address: ASSET_ADDRESSES.USDC,
      config: {
        tokenAddress: ASSET_ADDRESSES.USDC,
        priceOracle: PRICE_FEEDS.USDC_USD,
        decimals: 6,
        isActive: true,
        isCrossChain: false,
        minStakeAmount: ethers.utils.parseUnits('20', 6), // $20 minimum
        maxStakeAmount: ethers.utils.parseUnits('10000', 6), // $10K maximum
        concentrationLimit: 400000, // 40% max concentration
        symbol: 'USDC',
        bridgeId: ethers.constants.HashZero,
      },
    },
    {
      name: 'USDT',
      address: ASSET_ADDRESSES.USDT,
      config: {
        tokenAddress: ASSET_ADDRESSES.USDT,
        priceOracle: PRICE_FEEDS.USDT_USD,
        decimals: 6,
        isActive: true,
        isCrossChain: false,
        minStakeAmount: ethers.utils.parseUnits('20', 6), // $20 minimum
        maxStakeAmount: ethers.utils.parseUnits('10000', 6), // $10K maximum
        concentrationLimit: 400000, // 40% max concentration
        symbol: 'USDT',
        bridgeId: ethers.constants.HashZero,
      },
    },
  ];

  for (const asset of assetConfigs) {
    try {
      console.log(`📝 Configuring ${asset.name}...`);

      const tx = await multiAssetStaking.configureAsset(
        asset.address,
        asset.config
      );
      await tx.wait();

      console.log(`✅ ${asset.name} configured successfully`);
    } catch (error) {
      console.error(`❌ Failed to configure ${asset.name}:`, error.message);
      // Continue with other assets
    }
  }

  // ========== VERIFICATION AND SUMMARY ==========

  console.log('\n🔍 Verifying deployment...');

  try {
    // Check supported assets
    const [supportedAssets, configs] =
      await multiAssetStaking.getSupportedAssets();
    console.log(
      `✅ Successfully configured ${supportedAssets.length} supported assets`
    );

    for (let i = 0; i < supportedAssets.length; i++) {
      console.log(`   - ${configs[i].symbol}: ${supportedAssets[i]}`);
    }

    // Check protocol statistics
    const totalValueLocked = await multiAssetStaking.totalValueLockedUSD();
    const totalParticipants = await multiAssetStaking.totalParticipants();

    console.log(`📊 Initial stats:`);
    console.log(
      `   - Total Value Locked: $${ethers.utils.formatEther(totalValueLocked)}`
    );
    console.log(`   - Total Participants: ${totalParticipants}`);
  } catch (error) {
    console.error('❌ Verification failed:', error.message);
  }

  // ========== DEPLOYMENT SUMMARY ==========

  console.log('\n📋 DEPLOYMENT SUMMARY');
  console.log('========================');
  console.log(`MultiAssetStaking: ${multiAssetStaking.address}`);
  console.log(`ParticipantTypeRegistry: ${participantRegistryAddress}`);
  console.log(`StakeCalculator: ${stakeCalculatorAddress}`);
  if (wrfToken) console.log(`WRFToken: ${wrfToken.address}`);
  console.log('\nSupported Assets:');
  console.log(`  ETH: ${ASSET_ADDRESSES.ETH}`);
  console.log(`  WBTC: ${ASSET_ADDRESSES.WBTC}`);
  console.log(`  WRF: ${ASSET_ADDRESSES.WRF}`);
  console.log(`  USDC: ${ASSET_ADDRESSES.USDC}`);
  console.log(`  USDT: ${ASSET_ADDRESSES.USDT}`);

  console.log('\nPrice Oracles:');
  console.log(`  ETH/USD: ${PRICE_FEEDS.ETH_USD}`);
  console.log(`  BTC/USD: ${PRICE_FEEDS.BTC_USD}`);
  console.log(`  USDC/USD: ${PRICE_FEEDS.USDC_USD}`);
  console.log(`  USDT/USD: ${PRICE_FEEDS.USDT_USD}`);

  // Save deployment info
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      MultiAssetStaking: multiAssetStaking.address,
      ParticipantTypeRegistry: participantRegistryAddress,
      StakeCalculator: stakeCalculatorAddress,
      WRFToken: ASSET_ADDRESSES.WRF,
      BridgeIntegration: bridgeIntegrationAddress,
    },
    assets: ASSET_ADDRESSES,
    priceFeeds: PRICE_FEEDS,
    bridgeIds: BRIDGE_IDS,
  };

  console.log('\n💾 Saving deployment info...');
  const fs = require('fs');
  const path = require('path');

  const deploymentDir = path.join(__dirname, '../deployment-reports');
  if (!fs.existsSync(deploymentDir)) {
    fs.mkdirSync(deploymentDir, { recursive: true });
  }

  const filename = `multi-asset-staking-deployment-${Date.now()}.json`;
  const filepath = path.join(deploymentDir, filename);

  fs.writeFileSync(filepath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`✅ Deployment info saved to: ${filepath}`);

  // Environment variables for next deployments
  console.log('\n📝 Environment variables for .env file:');
  console.log(`MULTI_ASSET_STAKING_ADDRESS=${multiAssetStaking.address}`);
  console.log(`PARTICIPANT_REGISTRY_ADDRESS=${participantRegistryAddress}`);
  if (wrfToken) console.log(`WRF_TOKEN_ADDRESS=${wrfToken.address}`);

  console.log('\n🎉 MultiAssetStaking deployment completed successfully!');

  return {
    multiAssetStaking,
    participantRegistry,
    wrfToken,
    deploymentInfo,
  };
}

// Execute deployment
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error('💥 Deployment failed:', error);
      process.exit(1);
    });
}

module.exports = { main };
