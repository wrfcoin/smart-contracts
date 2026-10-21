/**
 * @title StakeDelegation Deployment Script
 * @dev Deploys the StakeDelegation contract with proper configuration and integration
 * with existing WRFCoin fair launch system components
 */

const { ethers, network } = require('hardhat');
const fs = require('fs');
const path = require('path');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('../scripts/lib/launchReadiness');

/**
 * Deployment configuration and parameters
 */
const DEPLOYMENT_CONFIG = {
  // Gas settings
  gasLimit: 6000000,
  gasPrice: null, // Will use network default

  // Initial configuration
  initialRates: {
    stakeRepaymentRate: 3000, // 30%
    advocateBonusRate: 500, // 5%
    protocolFeeRate: 200, // 2%
  },

  // Platform parameters
  maxDelegationsPerAdvocate: 10,

  // Verification settings
  verify: true,

  // Save deployment info
  saveDeployment: true,
};

/**
 * Deployment addresses for different networks
 * Update these with actual deployed contract addresses
 */
const NETWORK_ADDRESSES = {
  hardhat: {
    multiAssetStaking: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
    participantTypeRegistry: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    dynamicStakeCalculator: '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
    wrfToken: '0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9',
    protocolTreasury: '0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9',
  },
  sepolia: {
    multiAssetStaking: '',
    participantTypeRegistry: '',
    dynamicStakeCalculator: '',
    wrfToken: '',
    protocolTreasury: '',
  },
  mainnet: {
    multiAssetStaking: '',
    participantTypeRegistry: '',
    dynamicStakeCalculator: '',
    wrfToken: '',
    protocolTreasury: '',
  },
};

/**
 * Deploy StakeDelegation contract
 */
async function deployStakeDelegation() {
  requireLiveDeployConfig(network);

  console.log('🚀 Deploying WRFCoin StakeDelegation Contract');
  console.log('============================================');

  // Get network information
  const network = await ethers.provider.getNetwork();
  const networkName = network.name === 'unknown' ? 'hardhat' : network.name;
  console.log(`📡 Network: ${networkName} (Chain ID: ${network.chainId})`);

  // Get signers
  const [deployer, protocolTreasury, ...others] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`💰 Protocol Treasury: ${protocolTreasury.address}`);

  // Check deployer balance
  const deployerBalance = await ethers.provider.getBalance(deployer.address);
  console.log(
    `💎 Deployer Balance: ${ethers.formatEther(deployerBalance)} ETH`
  );

  if (deployerBalance < ethers.parseEther('0.1')) {
    console.warn('⚠️  Low deployer balance, deployment may fail');
  }

  // Get network addresses
  const addresses = NETWORK_ADDRESSES[networkName];
  if (!addresses) {
    throw new Error(`❌ No addresses configured for network: ${networkName}`);
  }

  // Validate required addresses
  const requiredContracts = [
    'multiAssetStaking',
    'participantTypeRegistry',
    'dynamicStakeCalculator',
    'wrfToken',
  ];

  for (const contract of requiredContracts) {
    if (!addresses[contract] || addresses[contract] === '') {
      console.warn(
        `⚠️  ${contract} address not set for ${networkName}, using deployer address`
      );
      addresses[contract] = deployer.address;
    }
  }

  // Use provided treasury or deployer
  const treasuryAddress =
    addresses.protocolTreasury || protocolTreasury.address;

  console.log('\n📋 Contract Dependencies:');
  console.log(`  MultiAssetStaking: ${addresses.multiAssetStaking}`);
  console.log(
    `  ParticipantTypeRegistry: ${addresses.participantTypeRegistry}`
  );
  console.log(`  DynamicStakeCalculator: ${addresses.dynamicStakeCalculator}`);
  console.log(`  WRFToken: ${addresses.wrfToken}`);
  console.log(`  Protocol Treasury: ${treasuryAddress}`);

  try {
    // Deploy StakeDelegation contract
    console.log('\n🏗️  Deploying StakeDelegation contract...');

    const StakeDelegation = await ethers.getContractFactory('StakeDelegation');

    const stakeDelegation = await StakeDelegation.deploy(
      addresses.multiAssetStaking,
      addresses.participantTypeRegistry,
      addresses.dynamicStakeCalculator,
      addresses.wrfToken,
      treasuryAddress,
      {
        gasLimit: DEPLOYMENT_CONFIG.gasLimit,
        gasPrice: DEPLOYMENT_CONFIG.gasPrice,
      }
    );

    // Wait for deployment
    await stakeDelegation.waitForDeployment();
    const stakeDelegationAddress = await stakeDelegation.getAddress();

    console.log(`✅ StakeDelegation deployed at: ${stakeDelegationAddress}`);

    // Verify deployment
    const deployedBytecode = await ethers.provider.getCode(
      stakeDelegationAddress
    );
    if (deployedBytecode === '0x') {
      throw new Error('❌ Contract deployment failed - no bytecode at address');
    }

    // Get deployment transaction details
    const deploymentTx = stakeDelegation.deploymentTransaction();
    console.log(`📄 Deployment Transaction: ${deploymentTx.hash}`);

    const receipt = await deploymentTx.wait();
    console.log(`⛽ Gas Used: ${receipt.gasUsed.toLocaleString()}`);
    console.log(
      `💰 Transaction Cost: ${ethers.formatEther(receipt.gasUsed * receipt.gasPrice)} ETH`
    );

    // Initialize contract parameters
    console.log('\n⚙️  Initializing contract parameters...');

    // Set earning rates (if different from defaults)
    const currentRates = {
      stakeRepayment: await stakeDelegation.stakeRepaymentRate(),
      advocateBonus: await stakeDelegation.advocateBonusRate(),
      protocolFee: await stakeDelegation.protocolFeeRate(),
    };

    console.log('📊 Current Earning Rates:');
    console.log(`  Stake Repayment: ${currentRates.stakeRepayment / 100}%`);
    console.log(`  Advocate Bonus: ${currentRates.advocateBonus / 100}%`);
    console.log(`  Protocol Fee: ${currentRates.protocolFee / 100}%`);

    // Grant initial roles
    console.log('\n🔐 Setting up access control...');

    const roles = {
      EARNINGS_DISTRIBUTOR_ROLE:
        await stakeDelegation.EARNINGS_DISTRIBUTOR_ROLE(),
      ADMIN_ROLE: await stakeDelegation.ADMIN_ROLE(),
      EMERGENCY_ROLE: await stakeDelegation.EMERGENCY_ROLE(),
      REFERRAL_MANAGER_ROLE: await stakeDelegation.REFERRAL_MANAGER_ROLE(),
    };

    // Grant roles to deployer initially
    for (const [roleName, roleHash] of Object.entries(roles)) {
      const hasRole = await stakeDelegation.hasRole(roleHash, deployer.address);
      if (!hasRole) {
        await stakeDelegation.grantRole(roleHash, deployer.address);
        console.log(`✅ Granted ${roleName} to deployer`);
      }
    }

    // Verify contract functions
    console.log('\n🔍 Verifying contract functions...');

    // Test view functions
    const precision = await stakeDelegation.PRECISION();
    const maxDelegations = await stakeDelegation.maxDelegationsPerAdvocate();
    const protocolTreasuryAddr = await stakeDelegation.protocolTreasury();

    console.log(`  PRECISION: ${precision}`);
    console.log(`  Max Delegations: ${maxDelegations}`);
    console.log(`  Protocol Treasury: ${protocolTreasuryAddr}`);

    // Get platform stats (should be all zeros for new deployment)
    const stats = await stakeDelegation.getPlatformStats();
    console.log(
      `  Platform Stats: ${stats.totalDelegations} delegations, ${stats.activeAdvocateCount} advocates`
    );

    // Create deployment summary
    const deploymentSummary = {
      network: networkName,
      chainId: Number(network.chainId),
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
      contracts: {
        stakeDelegation: {
          address: stakeDelegationAddress,
          deploymentTx: deploymentTx.hash,
          gasUsed: receipt.gasUsed.toString(),
          blockNumber: receipt.blockNumber,
        },
      },
      dependencies: addresses,
      configuration: {
        protocolTreasury: treasuryAddress,
        maxDelegationsPerAdvocate: Number(maxDelegations),
        earningRates: {
          stakeRepayment: Number(currentRates.stakeRepayment),
          advocateBonus: Number(currentRates.advocateBonus),
          protocolFee: Number(currentRates.protocolFee),
        },
      },
      roles: Object.fromEntries(
        Object.entries(roles).map(([name, hash]) => [name, hash])
      ),
    };

    // Save deployment information
    if (DEPLOYMENT_CONFIG.saveDeployment) {
      console.log('\n💾 Saving deployment information...');

      const deploymentsDir = path.join(__dirname, '../deployment-reports');
      if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
      }

      const deploymentFile = path.join(
        deploymentsDir,
        `stake-delegation-deployment-${networkName}-${Date.now()}.json`
      );

      fs.writeFileSync(
        deploymentFile,
        JSON.stringify(deploymentSummary, null, 2)
      );
      console.log(`📁 Deployment info saved to: ${deploymentFile}`);
    }

    // Contract verification
    if (DEPLOYMENT_CONFIG.verify && networkName !== 'hardhat') {
      console.log('\n🔍 Verifying contract on block explorer...');

      try {
        await run('verify:verify', {
          address: stakeDelegationAddress,
          constructorArguments: [
            addresses.multiAssetStaking,
            addresses.participantTypeRegistry,
            addresses.dynamicStakeCalculator,
            addresses.wrfToken,
            treasuryAddress,
          ],
        });
        console.log('✅ Contract verified successfully');
      } catch (error) {
        console.warn('⚠️  Contract verification failed:', error.message);
      }
    }

    // Display deployment success
    console.log('\n🎉 StakeDelegation Deployment Complete!');
    console.log('=====================================');
    console.log(`📍 Contract Address: ${stakeDelegationAddress}`);
    console.log(`🌐 Network: ${networkName}`);
    console.log(`🏗️  Deployer: ${deployer.address}`);
    console.log(`💰 Treasury: ${treasuryAddress}`);
    console.log(`⛽ Gas Used: ${receipt.gasUsed.toLocaleString()}`);

    console.log('\n📋 Next Steps:');
    console.log('1. Configure earning distribution roles');
    console.log('2. Integrate with existing fair launch contracts');
    console.log('3. Set up monitoring and analytics');
    console.log('4. Create advocate onboarding documentation');
    console.log('5. Run integration tests with MultiAssetStaking');

    console.log('\n🔗 Integration Commands:');
    console.log(`export STAKE_DELEGATION_ADDRESS="${stakeDelegationAddress}"`);
    console.log(
      `npx hardhat run examples/stake-delegation-usage.js --network ${networkName}`
    );

    return {
      stakeDelegation: stakeDelegation,
      address: stakeDelegationAddress,
      deploymentSummary: deploymentSummary,
    };
  } catch (error) {
    console.error('\n❌ Deployment failed:');
    console.error(error.message);

    if (error.transaction) {
      console.error(`Transaction: ${error.transaction.hash}`);
    }

    throw error;
  }
}

/**
 * Deploy and configure additional components if needed
 */
async function deployAdditionalComponents() {
  console.log('\n🔧 Checking additional components...');

  // Could deploy related contracts like:
  // - Referral link tracking oracle
  // - Advanced analytics contracts
  // - Cross-chain delegation bridges

  console.log('ℹ️  No additional components needed for basic deployment');
}

/**
 * Main deployment function
 */
async function main() {
  try {
    console.log('🚀 WRFCoin StakeDelegation Deployment Process');
    console.log('============================================');

    // Deploy main contract
    const deployment = await deployStakeDelegation();

    // Deploy additional components
    await deployAdditionalComponents();

    console.log('\n✅ All deployments completed successfully!');
    console.log(`🎯 StakeDelegation Address: ${deployment.address}`);

    return deployment;
  } catch (error) {
    console.error('\n❌ Deployment process failed:');
    console.error(error);
    process.exit(1);
  }
}

// Export for use in other scripts
module.exports = {
  deployStakeDelegation,
  deployAdditionalComponents,
  DEPLOYMENT_CONFIG,
  NETWORK_ADDRESSES,
};

// Run deployment if called directly
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}
