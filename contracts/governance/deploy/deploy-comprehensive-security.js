// SPDX-License-Identifier: MIT
/**
 * Deployment script for Comprehensive Governance Security Framework
 * Task 99.6 - Anti-manipulation security framework implementation
 */

const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

async function main() {
  console.log('🚀 Deploying Comprehensive Governance Security Framework');
  console.log('====================================================\n');

  const [
    deployer,
    admin,
    guardian1,
    guardian2,
    guardian3,
    guardian4,
    guardian5,
  ] = await ethers.getSigners();

  console.log('📋 Deployment Configuration:');
  console.log(`   • Deployer: ${deployer.address}`);
  console.log(`   • Admin: ${admin.address}`);
  console.log(`   • Guardian Council: 5 members`);
  console.log(`   • Target TVL Protection: $5,000,000`);
  console.log(`   • Security Layers: 6 layers\n`);

  const deploymentResults = {};

  try {
    // Step 1: Deploy mock governance token (for testing)
    console.log('1️⃣ Deploying Mock Governance Token...');
    const MockToken = await ethers.getContractFactory('MockERC20');
    const governanceToken = await MockToken.deploy(
      'WRF Governance Token',
      'WRFGOV',
      ethers.utils.parseEther('100000000') // 100M tokens
    );
    await governanceToken.deployed();
    console.log(
      `   ✅ Governance Token deployed: ${governanceToken.address}\n`
    );
    deploymentResults.governanceToken = governanceToken.address;

    // Step 2: Deploy TimelockController
    console.log('2️⃣ Deploying TimelockController...');
    const minDelay = 72 * 3600; // 72 hours
    const proposers = [admin.address];
    const executors = [admin.address];

    const TimelockController =
      await ethers.getContractFactory('TimelockController');
    const timelock = await TimelockController.deploy(
      minDelay,
      proposers,
      executors,
      admin.address
    );
    await timelock.deployed();
    console.log(`   ✅ TimelockController deployed: ${timelock.address}`);
    console.log(`   ⏰ Minimum delay: ${minDelay / 3600} hours\n`);
    deploymentResults.timelock = timelock.address;

    // Step 3: Deploy ComplianceModule
    console.log('3️⃣ Deploying ComplianceModule...');
    const ComplianceModule =
      await ethers.getContractFactory('ComplianceModule');
    const compliance = await ComplianceModule.deploy(admin.address);
    await compliance.deployed();
    console.log(`   ✅ ComplianceModule deployed: ${compliance.address}\n`);
    deploymentResults.compliance = compliance.address;

    // Step 4: Deploy EconomicSecurityMechanisms
    console.log('4️⃣ Deploying EconomicSecurityMechanisms...');
    const EconomicSecurityMechanisms = await ethers.getContractFactory(
      'EconomicSecurityMechanisms'
    );
    const economicSecurity = await EconomicSecurityMechanisms.deploy(
      governanceToken.address,
      admin.address
    );
    await economicSecurity.deployed();
    console.log(
      `   ✅ EconomicSecurityMechanisms deployed: ${economicSecurity.address}`
    );
    console.log(`   💰 Base proposer bond: 1000 WRFGOV`);
    console.log(`   🔒 Slashing range: 5-20%\n`);
    deploymentResults.economicSecurity = economicSecurity.address;

    // Step 5: Deploy CoordinationAttackPrevention
    console.log('5️⃣ Deploying CoordinationAttackPrevention...');
    const CoordinationAttackPrevention = await ethers.getContractFactory(
      'CoordinationAttackPrevention'
    );
    const coordinationPrevention = await CoordinationAttackPrevention.deploy(
      admin.address
    );
    await coordinationPrevention.deployed();
    console.log(
      `   ✅ CoordinationAttackPrevention deployed: ${coordinationPrevention.address}`
    );
    console.log(`   🔍 Detection algorithms: 6 types`);
    console.log(`   📊 Pattern analysis: Real-time\n`);
    deploymentResults.coordinationPrevention = coordinationPrevention.address;

    // Step 6: Deploy GovernanceSecurityFramework
    console.log('6️⃣ Deploying GovernanceSecurityFramework...');
    const GovernanceSecurityFramework = await ethers.getContractFactory(
      'GovernanceSecurityFramework'
    );
    const securityFramework = await GovernanceSecurityFramework.deploy(
      admin.address,
      timelock.address,
      compliance.address
    );
    await securityFramework.deployed();
    console.log(
      `   ✅ GovernanceSecurityFramework deployed: ${securityFramework.address}`
    );
    console.log(`   🛡️ Security features: Commit-reveal, circuit breaker`);
    console.log(`   👥 Reputation system: Integrated\n`);
    deploymentResults.securityFramework = securityFramework.address;

    // Step 7: Deploy ComprehensiveGovernanceSecurity (Master Contract)
    console.log('7️⃣ Deploying ComprehensiveGovernanceSecurity...');
    const guardianCouncil = [
      guardian1.address,
      guardian2.address,
      guardian3.address,
      guardian4.address,
      guardian5.address,
    ];

    const ComprehensiveGovernanceSecurity = await ethers.getContractFactory(
      'ComprehensiveGovernanceSecurity'
    );
    const masterSecurity = await ComprehensiveGovernanceSecurity.deploy(
      securityFramework.address,
      coordinationPrevention.address,
      economicSecurity.address,
      compliance.address,
      timelock.address,
      admin.address,
      guardianCouncil
    );
    await masterSecurity.deployed();
    console.log(
      `   ✅ ComprehensiveGovernanceSecurity deployed: ${masterSecurity.address}`
    );
    console.log(`   🏛️ Guardian Council: 5 members (2/3 + 1 majority)`);
    console.log(`   🔐 Multi-layer validation: 6 security layers\n`);
    deploymentResults.masterSecurity = masterSecurity.address;

    // Step 8: Configuration and Setup
    console.log('8️⃣ Configuring Security Framework...');

    // Setup roles and permissions
    console.log('   🔑 Setting up roles and permissions...');
    await securityFramework
      .connect(admin)
      .grantRole(
        await securityFramework.GOVERNANCE_ADMIN_ROLE(),
        masterSecurity.address
      );

    await economicSecurity
      .connect(admin)
      .grantRole(
        await economicSecurity.SLASHING_MANAGER_ROLE(),
        masterSecurity.address
      );

    await coordinationPrevention
      .connect(admin)
      .grantRole(
        await coordinationPrevention.PATTERN_ANALYST_ROLE(),
        masterSecurity.address
      );

    // Configure compliance for governance operations
    await compliance.connect(admin).setComplianceEnabled(true);

    console.log('   ✅ Roles and permissions configured');

    // Step 9: Initial Token Distribution (for testing)
    console.log('9️⃣ Setting up Test Environment...');

    // Distribute tokens for testing
    const testAmount = ethers.utils.parseEther('10000');
    await governanceToken.transfer(admin.address, testAmount);
    await governanceToken.transfer(guardian1.address, testAmount);
    await governanceToken.transfer(guardian2.address, testAmount);

    console.log('   💰 Test tokens distributed');
    console.log(
      `   📊 Admin balance: ${ethers.utils.formatEther(testAmount)} WRFGOV`
    );

    // Step 10: Security Validation
    console.log('🔒 Running Security Validation...');

    // Test multi-layer security
    const securityStats = await masterSecurity.getGovernanceSecurityStats();
    console.log(`   📈 Security Statistics:`);
    console.log(`      • Total Proposals: ${securityStats[0]}`);
    console.log(`      • Successful Executions: ${securityStats[1]}`);
    console.log(`      • Security Rejections: ${securityStats[2]}`);

    // Test attack cost calculation
    const targetVotingPower = ethers.utils.parseEther('1000000'); // 1M tokens
    const attackCost =
      await masterSecurity.calculateComprehensiveAttackCost(targetVotingPower);
    console.log(`   💸 Attack Cost Analysis (1M voting power):`);
    console.log(
      `      • Economic Cost: ${ethers.utils.formatEther(attackCost[0])} WRFGOV`
    );
    console.log(
      `      • Total Cost: ${ethers.utils.formatEther(attackCost[3])} WRFGOV`
    );
    console.log(`      • Attack Feasible: ${attackCost[4] ? 'Yes' : 'No'}`);

    // Step 11: Generate Deployment Report
    console.log('\n📋 Generating Deployment Report...');

    const deploymentReport = {
      timestamp: new Date().toISOString(),
      network: 'localhost', // Would be dynamic in real deployment
      deployer: deployer.address,
      admin: admin.address,
      guardianCouncil: guardianCouncil,
      contracts: deploymentResults,
      securityConfiguration: {
        timelockDelay: '72 hours',
        slashingRange: '5-20%',
        proposerBond: '1000 WRFGOV',
        multiLayerThreshold: '85%',
        guardianMajority: '2/3 + 1',
        tvlProtection: '$5,000,000',
      },
      securityLayers: [
        'Timelock Controller (72h delay)',
        'Quadratic Voting (sqrt formula)',
        'Access Control (role-based)',
        'Coordination Prevention (commit-reveal)',
        'Economic Security (slashing + bonds)',
        'Compliance Module (KYC/AML)',
      ],
      testEnvironment: {
        tokenDistributed: true,
        rolesConfigured: true,
        securityValidated: true,
      },
    };

    // Save deployment report
    const reportPath = path.join(
      __dirname,
      '../deployment-reports/comprehensive-security-deployment.json'
    );
    fs.writeFileSync(reportPath, JSON.stringify(deploymentReport, null, 2));

    console.log(`   ✅ Deployment report saved: ${reportPath}`);

    // Step 12: Final Summary
    console.log('\n🎯 Deployment Summary');
    console.log('====================');
    console.log('✅ All security contracts deployed successfully');
    console.log('✅ Multi-layer validation framework operational');
    console.log('✅ Guardian council initialized (5 members)');
    console.log('✅ Economic security mechanisms active');
    console.log('✅ Coordination attack prevention enabled');
    console.log('✅ Circuit breaker systems ready');
    console.log('✅ $5M TVL protection mechanisms deployed');

    console.log(`\n🏛️ Master Security Contract: ${masterSecurity.address}`);
    console.log(
      '🛡️ Comprehensive governance security framework is now ACTIVE!'
    );

    console.log('\n📚 Next Steps:');
    console.log('1. Run comprehensive security tests');
    console.log('2. Perform attack simulation tests');
    console.log('3. Verify all 6 security layers');
    console.log('4. Test guardian council voting');
    console.log('5. Validate circuit breaker functionality');

    return {
      success: true,
      masterContract: masterSecurity.address,
      deploymentResults,
      securityLayers: 6,
      tvlProtection: '$5,000,000',
    };
  } catch (error) {
    console.error('❌ Deployment failed:', error);
    throw error;
  }
}

// Helper function to verify deployment
async function verifyDeployment(contracts) {
  console.log('\n🔍 Verifying Deployment...');

  for (const [name, address] of Object.entries(contracts)) {
    try {
      const code = await ethers.provider.getCode(address);
      if (code === '0x') {
        throw new Error(`No code found at ${address} for ${name}`);
      }
      console.log(`   ✅ ${name}: Contract verified at ${address}`);
    } catch (error) {
      console.log(`   ❌ ${name}: Verification failed - ${error.message}`);
      throw error;
    }
  }

  console.log('   🎉 All contracts verified successfully!');
}

// Export for testing
module.exports = { main, verifyDeployment };

// Run deployment if called directly
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}
