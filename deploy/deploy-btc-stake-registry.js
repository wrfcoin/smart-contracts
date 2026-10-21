const { ethers, network } = require('hardhat');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('../scripts/lib/launchReadiness');

/**
 * Deployment script for BTCStakeRegistry contract
 * Includes mock contracts for testing and production deployment configurations
 */
async function main() {
  requireLiveDeployConfig(network);

  const [deployer] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  console.log('Deploying BTCStakeRegistry with account:', deployer.address);
  console.log(
    'Account balance:',
    ethers.formatEther(await ethers.provider.getBalance(deployer.address))
  );

  // Configuration
  const config = {
    // Production addresses (update for mainnet deployment)
    production: {
      wbtcToken: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599', // Mainnet WBTC
      wbtcPriceFeed: '0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c', // Chainlink WBTC/USD
      usdPriceFeed: '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6', // Chainlink USD/USD
    },
    // Testnet addresses (for testing)
    testnet: {
      // Will deploy mocks
    },
  };

  const network = await ethers.provider.getNetwork();
  const isMainnet = network.chainId === 1n;
  const isTestnet = network.chainId === 11155111n; // Sepolia

  console.log(
    `Deploying to ${isMainnet ? 'Mainnet' : isTestnet ? 'Testnet' : 'Local'} (Chain ID: ${network.chainId})`
  );

  let wbtcToken, wbtcPriceFeed, usdPriceFeed, multiAssetStaking;

  if (isMainnet) {
    // Use production addresses
    wbtcToken = config.production.wbtcToken;
    wbtcPriceFeed = config.production.wbtcPriceFeed;
    usdPriceFeed = config.production.usdPriceFeed;

    // Deploy or get MultiAssetStaking address
    console.log('⚠️  Production deployment - please verify all addresses!');
    console.log('WBTC Token:', wbtcToken);
    console.log('WBTC Price Feed:', wbtcPriceFeed);
    console.log('USD Price Feed:', usdPriceFeed);

    // You would need to provide the actual MultiAssetStaking address for production
    throw new Error(
      'Please provide MultiAssetStaking address for production deployment'
    );
  } else {
    // Deploy mock contracts for testing
    console.log('Deploying mock contracts for testing...');

    // Deploy MockERC20 for WBTC
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const wbtcTokenContract = await MockERC20.deploy(
      'Wrapped Bitcoin',
      'WBTC',
      8
    );
    await wbtcTokenContract.waitForDeployment();
    wbtcToken = await wbtcTokenContract.getAddress();
    console.log('Mock WBTC deployed to:', wbtcToken);

    // Deploy MockAggregatorV3 for price feeds
    const MockAggregatorV3 =
      await ethers.getContractFactory('MockAggregatorV3');

    const wbtcPriceFeedContract = await MockAggregatorV3.deploy(
      8, // decimals
      'WBTC/USD', // description
      1 // version
    );
    await wbtcPriceFeedContract.waitForDeployment();
    wbtcPriceFeed = await wbtcPriceFeedContract.getAddress();
    console.log('Mock WBTC Price Feed deployed to:', wbtcPriceFeed);

    const usdPriceFeedContract = await MockAggregatorV3.deploy(
      8, // decimals
      'USD/USD', // description
      1 // version
    );
    await usdPriceFeedContract.waitForDeployment();
    usdPriceFeed = await usdPriceFeedContract.getAddress();
    console.log('Mock USD Price Feed deployed to:', usdPriceFeed);

    // Set initial prices
    await wbtcPriceFeedContract.updateAnswer(4500000000000); // $45,000 with 8 decimals
    await usdPriceFeedContract.updateAnswer(100000000); // $1.00 with 8 decimals
    console.log('Price feeds initialized with test data');

    // Deploy MockMultiAssetStaking
    const MockMultiAssetStaking = await ethers.getContractFactory(
      'MockMultiAssetStaking'
    );
    const multiAssetStakingContract = await MockMultiAssetStaking.deploy();
    await multiAssetStakingContract.waitForDeployment();
    multiAssetStaking = await multiAssetStakingContract.getAddress();
    console.log('Mock MultiAssetStaking deployed to:', multiAssetStaking);
  }

  // Deploy BTCStakeRegistry
  console.log('\nDeploying BTCStakeRegistry...');
  const BTCStakeRegistry = await ethers.getContractFactory('BTCStakeRegistry');

  const btcStakeRegistry = await BTCStakeRegistry.deploy(
    wbtcToken,
    wbtcPriceFeed,
    usdPriceFeed,
    multiAssetStaking,
    deployer.address // admin
  );

  await btcStakeRegistry.waitForDeployment();
  const btcStakeRegistryAddress = await btcStakeRegistry.getAddress();

  console.log('BTCStakeRegistry deployed to:', btcStakeRegistryAddress);

  // Setup roles and permissions
  console.log('\nSetting up roles and permissions...');

  const BRIDGE_OPERATOR_ROLE = await btcStakeRegistry.BRIDGE_OPERATOR_ROLE();
  const EMERGENCY_ROLE = await btcStakeRegistry.EMERGENCY_ROLE();
  const ORACLE_MANAGER_ROLE = await btcStakeRegistry.ORACLE_MANAGER_ROLE();

  // Grant roles to deployer for initial setup (should be changed for production)
  await btcStakeRegistry.grantRole(BRIDGE_OPERATOR_ROLE, deployer.address);
  await btcStakeRegistry.grantRole(ORACLE_MANAGER_ROLE, deployer.address);
  console.log('Roles granted to deployer');

  // Deploy and setup mock bridge for testing
  if (!isMainnet) {
    console.log('\nDeploying mock bridge for testing...');
    const MockCrossChainBridge = await ethers.getContractFactory(
      'MockCrossChainBridge'
    );
    const mockBridge = await MockCrossChainBridge.deploy();
    await mockBridge.waitForDeployment();
    const mockBridgeAddress = await mockBridge.getAddress();
    console.log('Mock CrossChain Bridge deployed to:', mockBridgeAddress);

    // Add bridge as supported
    await btcStakeRegistry.addSupportedBridge(mockBridgeAddress);
    console.log('Mock bridge added as supported');
  }

  // Verify deployment
  console.log('\nVerifying deployment...');
  const healthStatus = await btcStakeRegistry.getHealthStatus();
  console.log('Contract health status:', {
    isHealthy: healthStatus[0],
    tvlUtilization: healthStatus[1].toString(),
    failedOperationRate: healthStatus[2].toString(),
  });

  // Save deployment info
  const deploymentInfo = {
    network: network.name,
    chainId: network.chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      BTCStakeRegistry: btcStakeRegistryAddress,
      wbtcToken: wbtcToken,
      wbtcPriceFeed: wbtcPriceFeed,
      usdPriceFeed: usdPriceFeed,
      multiAssetStaking: multiAssetStaking,
    },
    roles: {
      BRIDGE_OPERATOR_ROLE: BRIDGE_OPERATOR_ROLE,
      EMERGENCY_ROLE: EMERGENCY_ROLE,
      ORACLE_MANAGER_ROLE: ORACLE_MANAGER_ROLE,
    },
  };

  console.log('\n' + '='.repeat(50));
  console.log('DEPLOYMENT COMPLETE');
  console.log('='.repeat(50));
  console.log('BTCStakeRegistry:', btcStakeRegistryAddress);
  console.log('Network:', network.name, `(${network.chainId})`);
  console.log('Gas used: Check transaction receipts');
  console.log('='.repeat(50));

  // Write deployment info to file
  const fs = require('fs');
  const path = require('path');
  const deploymentDir = path.join(__dirname, '../deployment-reports');

  if (!fs.existsSync(deploymentDir)) {
    fs.mkdirSync(deploymentDir, { recursive: true });
  }

  const filename = `btc-stake-registry-deployment-${network.name}-${Date.now()}.json`;
  const filepath = path.join(deploymentDir, filename);

  fs.writeFileSync(filepath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`Deployment info saved to: ${filepath}`);

  return {
    btcStakeRegistry: btcStakeRegistryAddress,
    deploymentInfo,
  };
}

// Production deployment verification function
async function verifyProduction(btcStakeRegistryAddress) {
  console.log('Running production verification checks...');

  const btcStakeRegistry = await ethers.getContractAt(
    'BTCStakeRegistry',
    btcStakeRegistryAddress
  );

  // Check critical parameters
  const maxTotalValueLocked = await btcStakeRegistry.maxTotalValueLocked();
  const dailyWithdrawalLimit = await btcStakeRegistry.dailyWithdrawalLimit();
  const emergencyShutdown = await btcStakeRegistry.emergencyShutdown();

  console.log('Production verification:');
  console.log('- Max TVL:', ethers.formatEther(maxTotalValueLocked));
  console.log(
    '- Daily withdrawal limit:',
    ethers.formatEther(dailyWithdrawalLimit)
  );
  console.log('- Emergency shutdown:', emergencyShutdown);

  // Verify price feeds are working
  try {
    const wbtcPrice = await btcStakeRegistry.getWBTCPrice();
    console.log('- WBTC price:', ethers.formatEther(wbtcPrice));
    console.log('✅ Price feeds operational');
  } catch (error) {
    console.log('❌ Price feeds not operational:', error.message);
  }

  // Check health status
  const [isHealthy, tvlUtilization, failedOperationRate] =
    await btcStakeRegistry.getHealthStatus();
  console.log('- Health status:', {
    healthy: isHealthy,
    tvlUtilization: tvlUtilization.toString() + '%',
    failedOperationRate: failedOperationRate.toString() + '%',
  });

  if (isHealthy) {
    console.log('✅ Contract is healthy and ready for production');
  } else {
    console.log(
      '❌ Contract health check failed - review before production use'
    );
  }
}

// Run deployment
if (require.main === module) {
  main()
    .then(result => {
      console.log('\nDeployment successful!');
      process.exit(0);
    })
    .catch(error => {
      console.error('Deployment failed:', error);
      process.exit(1);
    });
}

module.exports = { main, verifyProduction };
