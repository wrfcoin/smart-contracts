const { ethers, network } = require('hardhat');
const fs = require('fs');
const path = require('path');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('../scripts/lib/launchReadiness');

/**
 * Deploy SlashingMechanism contract for WRFCoin fair launch
 * Handles fraud detection, stake slashing, and penalty enforcement
 */
async function deploySlashingMechanism() {
  requireLiveDeployConfig(network);

  const [deployer] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  console.log('🚀 Deploying SlashingMechanism contract...');
  console.log('📝 Deployer address:', deployer.address);
  console.log(
    '💰 Deployer balance:',
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    'ETH'
  );

  // Configuration - Update these addresses for your deployment
  const config = {
    // Contract addresses (replace with actual deployed addresses)
    multiAssetStaking:
      process.env.MULTI_ASSET_STAKING_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    participantRegistry:
      process.env.PARTICIPANT_REGISTRY_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    layawayRegistration:
      process.env.LAYAWAY_REGISTRATION_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    stakeDelegation:
      process.env.STAKE_DELEGATION_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    weatherDataValidator:
      process.env.WEATHER_DATA_VALIDATOR_ADDRESS ||
      '0x0000000000000000000000000000000000000000',

    // Treasury and burn addresses
    treasury:
      process.env.TREASURY_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    burnAddress:
      process.env.BURN_ADDRESS || '0x000000000000000000000000000000000000dEaD',

    // Validator addresses
    validators: [
      process.env.VALIDATOR_1_ADDRESS || deployer.address,
      process.env.VALIDATOR_2_ADDRESS || deployer.address,
      process.env.VALIDATOR_3_ADDRESS || deployer.address,
      process.env.VALIDATOR_4_ADDRESS || deployer.address,
      process.env.VALIDATOR_5_ADDRESS || deployer.address,
    ],

    // Appeals committee
    appealsCommittee: [
      process.env.APPEALS_MEMBER_1_ADDRESS || deployer.address,
      process.env.APPEALS_MEMBER_2_ADDRESS || deployer.address,
      process.env.APPEALS_MEMBER_3_ADDRESS || deployer.address,
    ],

    // Emergency role
    emergencyRole: process.env.EMERGENCY_ROLE_ADDRESS || deployer.address,
  };

  // Validate configuration
  console.log('🔍 Validating configuration...');

  const requiredAddresses = [
    'multiAssetStaking',
    'participantRegistry',
    'layawayRegistration',
    'stakeDelegation',
    'weatherDataValidator',
    'treasury',
  ];

  for (const key of requiredAddresses) {
    if (config[key] === '0x0000000000000000000000000000000000000000') {
      console.log(
        `⚠️  Warning: ${key} address not configured, using zero address`
      );
    }
  }

  try {
    // Deploy SlashingMechanism contract
    console.log('\n📦 Deploying SlashingMechanism...');

    const SlashingMechanism =
      await ethers.getContractFactory('SlashingMechanism');
    const slashingMechanism = await SlashingMechanism.deploy(
      config.multiAssetStaking,
      config.participantRegistry,
      config.layawayRegistration,
      config.stakeDelegation,
      config.weatherDataValidator,
      config.treasury,
      config.burnAddress
    );

    await slashingMechanism.waitForDeployment();
    const slashingAddress = await slashingMechanism.getAddress();

    console.log('✅ SlashingMechanism deployed to:', slashingAddress);

    // Configure roles
    console.log('\n🔐 Configuring access roles...');

    const VALIDATOR_ROLE = await slashingMechanism.VALIDATOR_ROLE();
    const APPEALS_COMMITTEE_ROLE =
      await slashingMechanism.APPEALS_COMMITTEE_ROLE();
    const EMERGENCY_ROLE = await slashingMechanism.EMERGENCY_ROLE();

    // Grant validator roles
    for (let i = 0; i < config.validators.length; i++) {
      if (config.validators[i] !== deployer.address) {
        console.log(`👤 Granting VALIDATOR_ROLE to: ${config.validators[i]}`);
        await slashingMechanism.grantRole(VALIDATOR_ROLE, config.validators[i]);
      } else {
        console.log(`👤 Validator ${i + 1} already has role (deployer)`);
      }
    }

    // Grant appeals committee roles
    for (let i = 0; i < config.appealsCommittee.length; i++) {
      if (config.appealsCommittee[i] !== deployer.address) {
        console.log(
          `👨‍⚖️ Granting APPEALS_COMMITTEE_ROLE to: ${config.appealsCommittee[i]}`
        );
        await slashingMechanism.grantRole(
          APPEALS_COMMITTEE_ROLE,
          config.appealsCommittee[i]
        );
      } else {
        console.log(`👨‍⚖️ Appeals member ${i + 1} already has role (deployer)`);
      }
    }

    // Grant emergency role
    if (config.emergencyRole !== deployer.address) {
      console.log(`🚨 Granting EMERGENCY_ROLE to: ${config.emergencyRole}`);
      await slashingMechanism.grantRole(EMERGENCY_ROLE, config.emergencyRole);
    } else {
      console.log('🚨 Emergency role already granted (deployer)');
    }

    // Verify deployment
    console.log('\n🔍 Verifying deployment...');

    const nextSlashingId = await slashingMechanism.nextSlashingId();
    const minValidators = await slashingMechanism.minValidatorsRequired();
    const executionDelay = await slashingMechanism.executionDelay();
    const appealWindow = await slashingMechanism.appealWindow();
    const treasuryAddress = await slashingMechanism.treasury();
    const burnAddressStored = await slashingMechanism.burnAddress();

    console.log('📊 Contract state:');
    console.log(`   Next slashing ID: ${nextSlashingId}`);
    console.log(`   Min validators required: ${minValidators}`);
    console.log(
      `   Execution delay: ${executionDelay} seconds (${executionDelay / 3600} hours)`
    );
    console.log(
      `   Appeal window: ${appealWindow} seconds (${appealWindow / 86400} days)`
    );
    console.log(`   Treasury address: ${treasuryAddress}`);
    console.log(`   Burn address: ${burnAddressStored}`);

    // Prepare deployment report
    const deploymentInfo = {
      network: await ethers.provider.getNetwork(),
      timestamp: new Date().toISOString(),
      deployer: deployer.address,
      contracts: {
        SlashingMechanism: {
          address: slashingAddress,
          constructorArgs: [
            config.multiAssetStaking,
            config.participantRegistry,
            config.layawayRegistration,
            config.stakeDelegation,
            config.weatherDataValidator,
            config.treasury,
            config.burnAddress,
          ],
          roles: {
            validators: config.validators,
            appealsCommittee: config.appealsCommittee,
            emergencyRole: config.emergencyRole,
          },
        },
      },
      configuration: {
        minValidatorsRequired: minValidators.toString(),
        executionDelay: executionDelay.toString(),
        appealWindow: appealWindow.toString(),
        gracePeriod: '2592000', // 30 days
        treasuryAllocationBPS: '5000', // 50%
        burnAllocationBPS: '5000', // 50%
      },
      gasUsed: 'N/A', // Will be filled by actual deployment
      transactionHash: slashingMechanism.deploymentTransaction()?.hash || 'N/A',
    };

    // Save deployment report
    const reportsDir = path.join(__dirname, '../deployment-reports');
    if (!fs.existsSync(reportsDir)) {
      fs.mkdirSync(reportsDir, { recursive: true });
    }

    const reportPath = path.join(
      reportsDir,
      `slashing-mechanism-deployment-${Date.now()}.json`
    );
    fs.writeFileSync(reportPath, JSON.stringify(deploymentInfo, null, 2));

    console.log(`\n📄 Deployment report saved to: ${reportPath}`);

    // Display next steps
    console.log('\n✨ Deployment completed successfully!');
    console.log('\n📋 Next Steps:');
    console.log(
      '1. Update your environment variables with the contract address:'
    );
    console.log(`   SLASHING_MECHANISM_ADDRESS=${slashingAddress}`);
    console.log(
      '\n2. Verify contract on block explorer (if on mainnet/testnet):'
    );
    console.log(
      `   npx hardhat verify --network <network> ${slashingAddress} \\`
    );
    console.log(
      `     "${config.multiAssetStaking}" "${config.participantRegistry}" \\`
    );
    console.log(
      `     "${config.layawayRegistration}" "${config.stakeDelegation}" \\`
    );
    console.log(
      `     "${config.weatherDataValidator}" "${config.treasury}" "${config.burnAddress}"`
    );
    console.log('\n3. Test the contract functionality:');
    console.log('   - Submit test evidence');
    console.log('   - Create test slashing proposal');
    console.log('   - Validate multi-signature requirements');
    console.log('   - Test appeals process');
    console.log('\n4. Configure integration with other contracts:');
    console.log(
      '   - Update MultiAssetStaking with slashing mechanism address'
    );
    console.log('   - Configure WeatherDataValidator to report violations');
    console.log('   - Set up monitoring and alerting for slashing events');

    console.log('\n🔒 Security Reminders:');
    console.log('- Review all validator addresses before mainnet deployment');
    console.log('- Test emergency procedures with testnet deployment');
    console.log('- Set up monitoring for all slashing events');
    console.log('- Verify appeals committee member availability');
    console.log('- Implement rate limiting for validator actions');

    return {
      slashingMechanism,
      deploymentInfo,
      address: slashingAddress,
    };
  } catch (error) {
    console.error('❌ Deployment failed:', error);

    if (error.code === 'INSUFFICIENT_FUNDS') {
      console.error(
        '💸 Insufficient funds for deployment. Please fund the deployer account.'
      );
    } else if (error.code === 'NETWORK_ERROR') {
      console.error(
        '🌐 Network error. Please check your connection and RPC endpoint.'
      );
    } else if (error.code === 'CONTRACT_SIZE_EXCEED') {
      console.error(
        '📏 Contract size exceeds limit. Consider optimization or splitting.'
      );
    }

    throw error;
  }
}

// Run deployment if called directly
if (require.main === module) {
  deploySlashingMechanism()
    .then(() => process.exit(0))
    .catch(error => {
      console.error('❌ Fatal error:', error);
      process.exit(1);
    });
}

module.exports = {
  deploySlashingMechanism,
};
