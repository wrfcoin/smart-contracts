const { ethers, network } = require('hardhat');
const fs = require('fs');
const path = require('path');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('../scripts/lib/launchReadiness');

/**
 * Comprehensive NFT Marketplace Deployment Script
 *
 * This script deploys the complete NFT marketplace ecosystem including:
 * - WRFToken (if not already deployed)
 * - ComputationalNFT (if not already deployed)
 * - NFTMarketplace
 * - NFTCrossChainBridge
 * - Configuration and verification
 */

// Deployment configuration
const DEPLOYMENT_CONFIG = {
  // Token configurations
  INITIAL_WRF_SUPPLY: ethers.parseEther('100000000'), // 100M tokens

  // Marketplace configurations
  MARKETPLACE_FEE_BASE: 250, // 2.5%
  MAX_ROYALTY_PERCENTAGE: 1000, // 10%
  AUCTION_EXTENSION_TIME: 600, // 10 minutes
  MIN_BID_INCREMENT: 100, // 1%

  // Bridge configurations
  MIN_VALIDATOR_STAKE: ethers.parseEther('10000'), // 10,000 WRF
  VALIDATOR_REWARD_RATE: ethers.parseEther('10'), // 10 WRF per validation
  MAX_TRANSFER_FEE: ethers.parseEther('1000'), // 1,000 WRF max fee
  REQUIRED_VALIDATIONS: 3,

  // Cross-chain configurations
  SUPPORTED_CHAINS: {
    ETHEREUM: {
      name: 'Ethereum',
      baseFee: ethers.parseEther('50'),
      gasMultiplier: 150,
      confirmationsRequired: 12,
    },
    POLYGON: {
      name: 'Polygon',
      baseFee: ethers.parseEther('10'),
      gasMultiplier: 100,
      confirmationsRequired: 50,
    },
    BSC: {
      name: 'BSC',
      baseFee: ethers.parseEther('20'),
      gasMultiplier: 110,
      confirmationsRequired: 15,
    },
    AVALANCHE: {
      name: 'Avalanche',
      baseFee: ethers.parseEther('15'),
      gasMultiplier: 120,
      confirmationsRequired: 10,
    },
  },
};

async function main() {
  requireLiveDeployConfig(network);

  console.log('🚀 Starting NFT Marketplace Deployment...');

  const [deployer] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  console.log('📱 Deploying with account:', deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log('💰 Account balance:', ethers.formatEther(balance), 'ETH');

  const deploymentResults = {
    network: await ethers.provider.getNetwork(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {},
    transactions: [],
  };

  try {
    // Step 1: Deploy or get WRFToken
    console.log('\n📋 Step 1: WRFToken Deployment');
    const wrfToken = await deployWRFToken(deployer, deploymentResults);

    // Step 2: Deploy or get ComputationalNFT
    console.log('\n📋 Step 2: ComputationalNFT Deployment');
    const computationalNFT = await deployComputationalNFT(
      deployer,
      wrfToken,
      deploymentResults
    );

    // Step 3: Deploy NFTMarketplace
    console.log('\n📋 Step 3: NFTMarketplace Deployment');
    const marketplace = await deployNFTMarketplace(
      deployer,
      wrfToken,
      deploymentResults
    );

    // Step 4: Deploy NFTCrossChainBridge
    console.log('\n📋 Step 4: NFTCrossChainBridge Deployment');
    const bridge = await deployNFTCrossChainBridge(
      deployer,
      wrfToken,
      deploymentResults
    );

    // Step 5: Configure contracts
    console.log('\n📋 Step 5: Contract Configuration');
    await configureContracts(
      deployer,
      {
        wrfToken,
        computationalNFT,
        marketplace,
        bridge,
      },
      deploymentResults
    );

    // Step 6: Verify deployments
    console.log('\n📋 Step 6: Deployment Verification');
    await verifyDeployments(
      {
        wrfToken,
        computationalNFT,
        marketplace,
        bridge,
      },
      deploymentResults
    );

    // Step 7: Save deployment results
    console.log('\n📋 Step 7: Saving Deployment Results');
    await saveDeploymentResults(deploymentResults);

    console.log('\n✅ NFT Marketplace Deployment Complete!');
    console.log('📄 Deployment report saved to deployment-results/');
  } catch (error) {
    console.error('\n❌ Deployment failed:', error);

    // Save partial results even on failure
    deploymentResults.error = {
      message: error.message,
      stack: error.stack,
    };
    await saveDeploymentResults(deploymentResults);

    process.exit(1);
  }
}

async function deployWRFToken(deployer, deploymentResults) {
  console.log('   🔸 Checking for existing WRFToken deployment...');

  // Check if WRFToken is already deployed
  const existingAddress = await getExistingContractAddress('WRFToken');

  if (existingAddress && (await isValidContract(existingAddress))) {
    console.log('   ✅ Using existing WRFToken at:', existingAddress);
    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = WRFToken.attach(existingAddress);

    deploymentResults.contracts.WRFToken = {
      address: existingAddress,
      existing: true,
    };

    return wrfToken;
  }

  console.log('   🔸 Deploying new WRFToken...');

  const WRFToken = await ethers.getContractFactory('WRFToken');
  const wrfToken = await WRFToken.deploy();
  await wrfToken.waitForDeployment();

  const address = await wrfToken.getAddress();
  console.log('   ✅ WRFToken deployed to:', address);

  deploymentResults.contracts.WRFToken = {
    address: address,
    deploymentTx: wrfToken.deploymentTransaction().hash,
    gasUsed: await getGasUsed(wrfToken.deploymentTransaction().hash),
    existing: false,
  };

  return wrfToken;
}

async function deployComputationalNFT(deployer, wrfToken, deploymentResults) {
  console.log('   🔸 Checking for existing ComputationalNFT deployment...');

  const existingAddress = await getExistingContractAddress('ComputationalNFT');

  if (existingAddress && (await isValidContract(existingAddress))) {
    console.log('   ✅ Using existing ComputationalNFT at:', existingAddress);
    const ComputationalNFT =
      await ethers.getContractFactory('ComputationalNFT');
    const computationalNFT = ComputationalNFT.attach(existingAddress);

    deploymentResults.contracts.ComputationalNFT = {
      address: existingAddress,
      existing: true,
    };

    return computationalNFT;
  }

  console.log('   🔸 Deploying new ComputationalNFT...');

  const ComputationalNFT = await ethers.getContractFactory('ComputationalNFT');
  const computationalNFT = await ComputationalNFT.deploy(
    await wrfToken.getAddress()
  );
  await computationalNFT.waitForDeployment();

  const address = await computationalNFT.getAddress();
  console.log('   ✅ ComputationalNFT deployed to:', address);

  deploymentResults.contracts.ComputationalNFT = {
    address: address,
    deploymentTx: computationalNFT.deploymentTransaction().hash,
    gasUsed: await getGasUsed(computationalNFT.deploymentTransaction().hash),
    existing: false,
  };

  return computationalNFT;
}

async function deployNFTMarketplace(deployer, wrfToken, deploymentResults) {
  console.log('   🔸 Deploying NFTMarketplace...');

  const NFTMarketplace = await ethers.getContractFactory('NFTMarketplace');
  const marketplace = await NFTMarketplace.deploy(await wrfToken.getAddress());
  await marketplace.waitForDeployment();

  const address = await marketplace.getAddress();
  console.log('   ✅ NFTMarketplace deployed to:', address);

  deploymentResults.contracts.NFTMarketplace = {
    address: address,
    deploymentTx: marketplace.deploymentTransaction().hash,
    gasUsed: await getGasUsed(marketplace.deploymentTransaction().hash),
    existing: false,
  };

  return marketplace;
}

async function deployNFTCrossChainBridge(
  deployer,
  wrfToken,
  deploymentResults
) {
  console.log('   🔸 Deploying NFTCrossChainBridge...');

  const NFTCrossChainBridge = await ethers.getContractFactory(
    'NFTCrossChainBridge'
  );
  const bridge = await NFTCrossChainBridge.deploy(await wrfToken.getAddress());
  await bridge.waitForDeployment();

  const address = await bridge.getAddress();
  console.log('   ✅ NFTCrossChainBridge deployed to:', address);

  deploymentResults.contracts.NFTCrossChainBridge = {
    address: address,
    deploymentTx: bridge.deploymentTransaction().hash,
    gasUsed: await getGasUsed(bridge.deploymentTransaction().hash),
    existing: false,
  };

  return bridge;
}

async function configureContracts(deployer, contracts, deploymentResults) {
  const { wrfToken, computationalNFT, marketplace, bridge } = contracts;
  const configTxs = [];

  try {
    // Configure marketplace
    console.log('   🔸 Configuring NFTMarketplace...');

    // Authorize ComputationalNFT contract
    const computationalNFTAddress = await computationalNFT.getAddress();
    const authTx = await marketplace.setAuthorizedNFTContract(
      computationalNFTAddress,
      true
    );
    await authTx.wait();
    configTxs.push({
      description: 'Authorize ComputationalNFT in marketplace',
      hash: authTx.hash,
    });
    console.log('   ✅ Authorized ComputationalNFT in marketplace');

    // Configure cross-chain bridges
    console.log('   🔸 Configuring cross-chain bridges...');
    const bridgeAddress = await bridge.getAddress();

    for (const [chainKey, chainConfig] of Object.entries(
      DEPLOYMENT_CONFIG.SUPPORTED_CHAINS
    )) {
      const chainType = getChainTypeEnum(chainKey);

      const bridgeConfigTx = await marketplace.setCrossChainBridge(
        bridgeAddress,
        chainConfig.name,
        chainConfig.baseFee,
        true // isActive
      );
      await bridgeConfigTx.wait();
      configTxs.push({
        description: `Configure ${chainConfig.name} bridge`,
        hash: bridgeConfigTx.hash,
      });
      console.log(`   ✅ Configured ${chainConfig.name} bridge`);
    }

    // Configure bridge for marketplace
    console.log('   🔸 Configuring bridge contracts...');

    // Authorize ComputationalNFT in bridge
    const bridgeAuthTx = await bridge.setAuthorizedNFTContract(
      computationalNFTAddress,
      true
    );
    await bridgeAuthTx.wait();
    configTxs.push({
      description: 'Authorize ComputationalNFT in bridge',
      hash: bridgeAuthTx.hash,
    });
    console.log('   ✅ Authorized ComputationalNFT in bridge');

    // Set required validations
    const validationsTx = await bridge.setRequiredValidations(
      DEPLOYMENT_CONFIG.REQUIRED_VALIDATIONS
    );
    await validationsTx.wait();
    configTxs.push({
      description: 'Set required validations',
      hash: validationsTx.hash,
    });
    console.log('   ✅ Set required validations');

    deploymentResults.configuration = {
      transactions: configTxs,
      success: true,
    };
  } catch (error) {
    console.error('   ❌ Configuration failed:', error.message);
    deploymentResults.configuration = {
      transactions: configTxs,
      success: false,
      error: error.message,
    };
    throw error;
  }
}

async function verifyDeployments(contracts, deploymentResults) {
  const { wrfToken, computationalNFT, marketplace, bridge } = contracts;
  const verificationResults = {};

  try {
    // Verify WRFToken
    console.log('   🔸 Verifying WRFToken...');
    const wrfSymbol = await wrfToken.symbol();
    const wrfTotalSupply = await wrfToken.totalSupply();
    verificationResults.WRFToken = {
      symbol: wrfSymbol,
      totalSupply: ethers.formatEther(wrfTotalSupply),
      valid: wrfSymbol === 'WRF',
    };
    console.log(
      `   ✅ WRFToken verified - Symbol: ${wrfSymbol}, Supply: ${ethers.formatEther(wrfTotalSupply)}`
    );

    // Verify ComputationalNFT
    console.log('   🔸 Verifying ComputationalNFT...');
    const nftName = await computationalNFT.name();
    const nftSymbol = await computationalNFT.symbol();
    const nftWrfToken = await computationalNFT.wrfToken();
    verificationResults.ComputationalNFT = {
      name: nftName,
      symbol: nftSymbol,
      wrfTokenAddress: nftWrfToken,
      valid:
        nftSymbol === 'WCNFT' && nftWrfToken === (await wrfToken.getAddress()),
    };
    console.log(
      `   ✅ ComputationalNFT verified - Name: ${nftName}, Symbol: ${nftSymbol}`
    );

    // Verify NFTMarketplace
    console.log('   🔸 Verifying NFTMarketplace...');
    const marketplaceWrfToken = await marketplace.wrfToken();
    const marketplaceStats = await marketplace.getGlobalStats();
    verificationResults.NFTMarketplace = {
      wrfTokenAddress: marketplaceWrfToken,
      totalSales: marketplaceStats.totalSales.toString(),
      valid: marketplaceWrfToken === (await wrfToken.getAddress()),
    };
    console.log('   ✅ NFTMarketplace verified');

    // Verify NFTCrossChainBridge
    console.log('   🔸 Verifying NFTCrossChainBridge...');
    const bridgeWrfToken = await bridge.wrfToken();
    const bridgeStats = await bridge.getBridgeStats();
    verificationResults.NFTCrossChainBridge = {
      wrfTokenAddress: bridgeWrfToken,
      totalTransfers: bridgeStats.total.toString(),
      activeValidators: bridgeStats.activeValidators.toString(),
      valid: bridgeWrfToken === (await wrfToken.getAddress()),
    };
    console.log('   ✅ NFTCrossChainBridge verified');

    deploymentResults.verification = {
      results: verificationResults,
      success: true,
      allValid: Object.values(verificationResults).every(
        result => result.valid
      ),
    };

    if (deploymentResults.verification.allValid) {
      console.log('   ✅ All contracts verified successfully');
    } else {
      console.log('   ⚠️  Some contracts failed verification');
    }
  } catch (error) {
    console.error('   ❌ Verification failed:', error.message);
    deploymentResults.verification = {
      results: verificationResults,
      success: false,
      error: error.message,
    };
  }
}

// Helper functions

async function getExistingContractAddress(contractName) {
  try {
    const deploymentPath = path.join(__dirname, '../deployment-reports');
    if (!fs.existsSync(deploymentPath)) {
      return null;
    }

    const files = fs.readdirSync(deploymentPath);
    const latestFile = files
      .filter(f => f.includes('deployment-results'))
      .sort()
      .pop();

    if (!latestFile) {
      return null;
    }

    const deploymentData = JSON.parse(
      fs.readFileSync(path.join(deploymentPath, latestFile))
    );
    return deploymentData.contracts?.[contractName]?.address || null;
  } catch (error) {
    return null;
  }
}

async function isValidContract(address) {
  try {
    const code = await ethers.provider.getCode(address);
    return code !== '0x';
  } catch (error) {
    return false;
  }
}

async function getGasUsed(txHash) {
  try {
    const receipt = await ethers.provider.getTransactionReceipt(txHash);
    return receipt.gasUsed.toString();
  } catch (error) {
    return 'unknown';
  }
}

function getChainTypeEnum(chainKey) {
  const chainTypeMap = {
    ETHEREUM: 0,
    POLYGON: 1,
    BSC: 2,
    AVALANCHE: 3,
    ARBITRUM: 4,
    OPTIMISM: 5,
  };
  return chainTypeMap[chainKey] || 0;
}

async function saveDeploymentResults(deploymentResults) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const resultsDir = path.join(__dirname, '../deployment-reports');

  // Ensure directory exists
  if (!fs.existsSync(resultsDir)) {
    fs.mkdirSync(resultsDir, { recursive: true });
  }

  // Save detailed results
  const detailedFile = path.join(
    resultsDir,
    `nft-marketplace-deployment-${timestamp}.json`
  );
  fs.writeFileSync(detailedFile, JSON.stringify(deploymentResults, null, 2));

  // Save summary
  const summary = {
    network: deploymentResults.network,
    timestamp: deploymentResults.timestamp,
    contracts: Object.fromEntries(
      Object.entries(deploymentResults.contracts).map(([name, data]) => [
        name,
        { address: data.address, existing: data.existing },
      ])
    ),
    success: !deploymentResults.error,
    verification: deploymentResults.verification?.allValid || false,
  };

  const summaryFile = path.join(
    resultsDir,
    `nft-marketplace-summary-${timestamp}.json`
  );
  fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2));

  console.log(`   📄 Detailed results: ${detailedFile}`);
  console.log(`   📄 Summary: ${summaryFile}`);
}

// Execute deployment
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = {
  main,
  DEPLOYMENT_CONFIG,
};
