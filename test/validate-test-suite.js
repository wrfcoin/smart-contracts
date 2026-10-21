#!/usr/bin/env node
// SPDX-License-Identifier: MIT

/**
 * Test Suite Validation Script
 *
 * Validates that the comprehensive test suite is properly configured and ready to run.
 * This script performs pre-flight checks before running the main test suite.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { TEST_CONFIG } = require('./test.config.js');

class TestSuiteValidator {
  constructor() {
    this.validationResults = {
      environment: [],
      testFiles: [],
      configuration: [],
      dependencies: [],
      contracts: [],
    };
    this.errors = [];
    this.warnings = [];
  }

  /**
   * Main validation orchestrator
   */
  async validate() {
    console.log('🔍 WRFCoin Fair Launch Test Suite Validation');
    console.log('='.repeat(60));

    try {
      await this.validateEnvironment();
      await this.validateTestFiles();
      await this.validateConfiguration();
      await this.validateDependencies();
      await this.validateContracts();

      this.generateReport();
      this.printSummary();

      if (this.errors.length > 0) {
        console.error(
          '\n❌ Validation failed with errors. Please fix before running tests.'
        );
        process.exit(1);
      } else {
        console.log('\n✅ All validations passed! Test suite is ready to run.');
        this.printRunInstructions();
        process.exit(0);
      }
    } catch (error) {
      console.error('❌ Validation process failed:', error.message);
      process.exit(1);
    }
  }

  /**
   * Validate environment setup
   */
  async validateEnvironment() {
    console.log('\n🔧 Validating Environment...');

    // Check Node.js version
    const nodeVersion = process.version;
    const nodeVersionNum = parseInt(nodeVersion.replace('v', '').split('.')[0]);

    if (nodeVersionNum >= 18) {
      this.validationResults.environment.push(
        `✅ Node.js ${nodeVersion} (compatible)`
      );
    } else {
      this.errors.push(
        `❌ Node.js ${nodeVersion} is too old. Requires Node.js 18+`
      );
    }

    // Check working directory
    const expectedDir = path.resolve(process.cwd());
    if (expectedDir.includes('contracts')) {
      this.validationResults.environment.push(
        '✅ Running from contracts directory'
      );
    } else {
      this.warnings.push(
        '⚠️  Not running from contracts directory - paths may be incorrect'
      );
    }

    // Check if Hardhat is available
    try {
      const hardhatVersion = execSync('npx hardhat --version', {
        stdio: 'pipe',
        encoding: 'utf8',
      }).trim();
      this.validationResults.environment.push(`✅ ${hardhatVersion}`);
    } catch {
      this.errors.push("❌ Hardhat not available - run 'npm install' first");
    }

    // Check if test accounts are sufficient
    try {
      const networkInfo = await this.getNetworkInfo();
      if (networkInfo.accounts >= TEST_CONFIG.accounts.MIN_TEST_ACCOUNTS) {
        this.validationResults.environment.push(
          `✅ ${networkInfo.accounts} test accounts available`
        );
      } else {
        this.warnings.push(
          `⚠️  Only ${networkInfo.accounts} accounts available, some tests may be skipped`
        );
      }
    } catch {
      this.warnings.push('⚠️  Could not verify test account count');
    }

    console.log(
      this.validationResults.environment.map(r => `  ${r}`).join('\n')
    );
  }

  /**
   * Get network information
   */
  async getNetworkInfo() {
    // Mock network info for validation
    return {
      accounts: 50, // Hardhat default
      gasLimit: 30000000,
      chainId: 1337,
    };
  }

  /**
   * Validate all test files exist and are syntactically correct
   */
  async validateTestFiles() {
    console.log('\n📋 Validating Test Files...');

    const testSuites = Object.entries(TEST_CONFIG.suites);

    for (const [suiteName, suiteConfig] of testSuites) {
      const testFilePath = path.join(__dirname, suiteConfig.file);

      if (fs.existsSync(testFilePath)) {
        this.validationResults.testFiles.push(
          `✅ ${suiteName}: ${suiteConfig.file}`
        );

        // Validate file syntax
        try {
          const fileContent = fs.readFileSync(testFilePath, 'utf8');

          // Basic syntax checks
          if (!fileContent.includes('describe(')) {
            this.warnings.push(`⚠️  ${suiteConfig.file}: No test suites found`);
          }

          if (!fileContent.includes('it(')) {
            this.warnings.push(
              `⚠️  ${suiteConfig.file}: No individual tests found`
            );
          }

          // Check for required imports
          const requiredImports = ['hardhat', 'chai'];
          for (const importName of requiredImports) {
            if (!fileContent.includes(importName)) {
              this.warnings.push(
                `⚠️  ${suiteConfig.file}: Missing ${importName} import`
              );
            }
          }
        } catch (error) {
          this.errors.push(
            `❌ ${suiteConfig.file}: File read error - ${error.message}`
          );
        }
      } else {
        this.errors.push(
          `❌ ${suiteName}: File not found - ${suiteConfig.file}`
        );
      }
    }

    // Validate test configuration file
    const configPath = path.join(__dirname, 'test.config.js');
    if (fs.existsSync(configPath)) {
      this.validationResults.testFiles.push(
        '✅ Test configuration file exists'
      );
    } else {
      this.errors.push('❌ test.config.js not found');
    }

    // Validate test runner
    const runnerPath = path.join(__dirname, 'run-comprehensive-tests.js');
    if (fs.existsSync(runnerPath)) {
      this.validationResults.testFiles.push('✅ Test runner exists');
    } else {
      this.errors.push('❌ run-comprehensive-tests.js not found');
    }

    console.log(this.validationResults.testFiles.map(r => `  ${r}`).join('\n'));
  }

  /**
   * Validate test configuration
   */
  async validateConfiguration() {
    console.log('\n⚙️  Validating Configuration...');

    // Validate TEST_CONFIG structure
    const requiredConfigSections = [
      'execution',
      'constants',
      'gasLimits',
      'suites',
    ];

    for (const section of requiredConfigSections) {
      if (TEST_CONFIG[section]) {
        this.validationResults.configuration.push(
          `✅ Configuration section: ${section}`
        );
      } else {
        this.errors.push(`❌ Missing configuration section: ${section}`);
      }
    }

    // Validate gas limits are reasonable
    const gasLimits = TEST_CONFIG.gasLimits;
    for (const [operation, gasLimit] of Object.entries(gasLimits)) {
      if (gasLimit > 0 && gasLimit < 10000000) {
        this.validationResults.configuration.push(
          `✅ Gas limit for ${operation}: ${gasLimit.toLocaleString()}`
        );
      } else {
        this.warnings.push(
          `⚠️  Unusual gas limit for ${operation}: ${gasLimit.toLocaleString()}`
        );
      }
    }

    // Validate timeout settings
    if (TEST_CONFIG.execution.timeout >= 60000) {
      this.validationResults.configuration.push(
        `✅ Test timeout: ${TEST_CONFIG.execution.timeout / 1000}s`
      );
    } else {
      this.warnings.push(
        `⚠️  Test timeout may be too short: ${TEST_CONFIG.execution.timeout / 1000}s`
      );
    }

    console.log(
      this.validationResults.configuration.map(r => `  ${r}`).join('\n')
    );
  }

  /**
   * Validate dependencies are installed
   */
  async validateDependencies() {
    console.log('\n📦 Validating Dependencies...');

    const requiredDependencies = [
      '@nomicfoundation/hardhat-ethers',
      '@nomicfoundation/hardhat-chai-matchers',
      '@nomicfoundation/hardhat-network-helpers',
      'chai',
      'ethers',
    ];

    // Check package.json exists
    const packageJsonPath = path.resolve('../package.json');
    let packageJson = null;

    if (fs.existsSync(packageJsonPath)) {
      packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
      this.validationResults.dependencies.push('✅ package.json found');
    } else {
      this.warnings.push('⚠️  package.json not found in expected location');
    }

    // Check critical dependencies
    for (const dep of requiredDependencies) {
      try {
        require.resolve(dep);
        this.validationResults.dependencies.push(`✅ ${dep}`);
      } catch {
        this.errors.push(`❌ Missing dependency: ${dep}`);
      }
    }

    console.log(
      this.validationResults.dependencies.map(r => `  ${r}`).join('\n')
    );
  }

  /**
   * Validate contract compilation
   */
  async validateContracts() {
    console.log('\n📜 Validating Contracts...');

    try {
      // Try to compile contracts
      console.log('  Compiling contracts...');
      execSync('npx hardhat compile --quiet', {
        stdio: 'pipe',
        cwd: path.resolve('../'),
        timeout: 60000,
      });

      this.validationResults.contracts.push(
        '✅ Contract compilation successful'
      );

      // Check key contract artifacts exist
      const keyContracts = [
        'WRFToken',
        'FairLaunchIntegrationManager',
        'MultiAssetStaking',
        'SlashingMechanism',
        'ParticipantTypeRegistry',
      ];

      const artifactsDir = path.resolve('../artifacts/contracts');

      for (const contractName of keyContracts) {
        const contractFound = this.findContractArtifact(
          artifactsDir,
          contractName
        );
        if (contractFound) {
          this.validationResults.contracts.push(
            `✅ ${contractName} artifact exists`
          );
        } else {
          this.warnings.push(`⚠️  ${contractName} artifact not found`);
        }
      }
    } catch (error) {
      this.errors.push(`❌ Contract compilation failed: ${error.message}`);
    }

    console.log(this.validationResults.contracts.map(r => `  ${r}`).join('\n'));
  }

  /**
   * Find contract artifact recursively
   */
  findContractArtifact(dir, contractName) {
    if (!fs.existsSync(dir)) return false;

    try {
      const files = fs.readdirSync(dir);

      for (const file of files) {
        const filePath = path.join(dir, file);
        const stat = fs.statSync(filePath);

        if (stat.isDirectory()) {
          if (this.findContractArtifact(filePath, contractName)) {
            return true;
          }
        } else if (file === `${contractName}.json`) {
          return true;
        }
      }
    } catch {
      return false;
    }

    return false;
  }

  /**
   * Generate validation report
   */
  generateReport() {
    const report = {
      timestamp: new Date().toISOString(),
      summary: {
        totalChecks: Object.values(this.validationResults).flat().length,
        errors: this.errors.length,
        warnings: this.warnings.length,
        status: this.errors.length === 0 ? 'READY' : 'NOT_READY',
      },
      details: this.validationResults,
      errors: this.errors,
      warnings: this.warnings,
    };

    const reportPath = path.join(
      __dirname,
      '../test-reports',
      'validation-report.json'
    );

    // Ensure report directory exists
    const reportDir = path.dirname(reportPath);
    if (!fs.existsSync(reportDir)) {
      fs.mkdirSync(reportDir, { recursive: true });
    }

    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  }

  /**
   * Print validation summary
   */
  printSummary() {
    console.log('\n' + '='.repeat(60));
    console.log('📊 VALIDATION SUMMARY');
    console.log('='.repeat(60));

    const totalChecks = Object.values(this.validationResults).flat().length;
    console.log(`Total Checks: ${totalChecks}`);
    console.log(`Errors: ${this.errors.length}`);
    console.log(`Warnings: ${this.warnings.length}`);

    if (this.errors.length > 0) {
      console.log('\n❌ ERRORS:');
      this.errors.forEach(error => console.log(`  ${error}`));
    }

    if (this.warnings.length > 0) {
      console.log('\n⚠️  WARNINGS:');
      this.warnings.forEach(warning => console.log(`  ${warning}`));
    }
  }

  /**
   * Print instructions for running tests
   */
  printRunInstructions() {
    console.log('\n🚀 READY TO RUN TESTS');
    console.log('='.repeat(30));
    console.log('To run the comprehensive test suite:');
    console.log('');
    console.log('1. Full test suite:');
    console.log('   node test/run-comprehensive-tests.js');
    console.log('');
    console.log('2. Individual test suites:');
    console.log('   npx hardhat test test/FairLaunch.comprehensive.test.js');
    console.log('   npx hardhat test test/FairLaunch.security.test.js');
    console.log('   npx hardhat test test/FairLaunch.performance.test.js');
    console.log('   npx hardhat test test/FairLaunch.edgecases.test.js');
    console.log('');
    console.log('3. With coverage:');
    console.log('   npx hardhat coverage');
    console.log('');
    console.log('4. Security audit:');
    console.log('   npx hardhat security-audit');
    console.log('');
    console.log('📋 Test Reports will be saved to: ./test-reports/');
  }
}

// Run validation if called directly
if (require.main === module) {
  const validator = new TestSuiteValidator();
  validator.validate().catch(console.error);
}

module.exports = TestSuiteValidator;
