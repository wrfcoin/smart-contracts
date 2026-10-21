// SPDX-License-Identifier: MIT

/**
 * Comprehensive Fair Launch Test Configuration
 *
 * Configuration file for running the complete WRFCoin fair launch test suite
 * including integration tests, security tests, performance tests, and edge cases.
 */

const { ethers } = require('hardhat');

// Test suite configuration
const TEST_CONFIG = {
  // Test execution settings
  execution: {
    timeout: 300000, // 5 minutes per test
    retries: 2, // Retry failed tests
    parallel: false, // Run tests sequentially for reliability
    bail: false, // Continue running tests even if some fail
    verbose: true, // Detailed logging
    gasReporting: true, // Enable gas reporting
  },

  // Network settings for testing
  network: {
    blockTime: 1, // 1 second block time for testing
    gasLimit: 30000000, // 30M gas limit
    gasPrice: ethers.parseUnits('20', 'gwei'),
    initialBalance: ethers.parseEther('10000'), // 10,000 ETH per test account
  },

  // Test data constants
  constants: {
    // Token constants
    MAX_SUPPLY: ethers.parseEther('1000000000'), // 1B tokens
    WEATHER_REWARD_RATE: ethers.parseEther('17.5'),
    REGISTRATION_STAKE: ethers.parseEther('0.1'),
    MAX_DAILY_REWARD: ethers.parseEther('420'),

    // Price oracle constants
    ETH_PRICE_USD: ethers.parseEther('2000'),
    WBTC_PRICE_USD: ethers.parseEther('40000'),
    WRF_PRICE_USD: ethers.parseEther('1'),
    USDC_PRICE_USD: ethers.parseEther('1'),

    // Staking constants
    MIN_COLLATERALIZATION_RATIO: 1200000, // 120%
    PRECISION: 1000000, // 1e6
    MAX_ORACLE_AGE: 1800, // 30 minutes

    // Time constants
    REWARD_COOLDOWN: 3600, // 1 hour
    MIN_LAYAWAY_PERIOD: 7 * 24 * 3600, // 7 days
    MAX_LAYAWAY_PERIOD: 365 * 24 * 3600, // 1 year
    CROSS_CHAIN_TIMEOUT: 86400, // 24 hours
  },

  // Gas limits for different operations
  gasLimits: {
    REGISTRATION: 350000,
    REWARD_CLAIM: 150000,
    MULTI_ASSET_STAKE: 400000,
    BATCH_MINT_PER_ITEM: 50000,
    LAYAWAY_REGISTRATION: 300000,
    DELEGATION_REGISTRATION: 450000,
    SLASHING_OPERATION: 200000,
    COMPLEX_INTERACTION: 500000,
  },

  // Performance benchmarks
  performance: {
    MAX_BATCH_SIZE: 100,
    MAX_STATIONS_PER_USER: 10,
    MAX_CONCURRENT_OPERATIONS: 1000,
    MIN_TPS: 10, // Transactions per second
    MAX_STATE_SIZE: 10000,
    MAX_REGISTRATION_TIME_MS: 5000,
    MAX_QUERY_TIME_MS: 2000,
  },

  // Security test parameters
  security: {
    MAX_SYBIL_ATTEMPTS: 100,
    MAX_REENTRANCY_DEPTH: 10,
    PRICE_MANIPULATION_FACTOR: 1000, // 1000x price change
    MAX_ORACLE_STALENESS: 7200, // 2 hours
    FLASH_LOAN_AMOUNT: ethers.parseEther('1000000'),
  },

  // Edge case test values
  edgeCases: {
    MIN_VALUE: 1,
    MAX_UINT256: 2n ** 256n - 1n,
    MIN_TIMESTAMP: 1,
    MAX_TIMESTAMP: 2n ** 32n - 1n,
    EXTREME_PRICE_HIGH: ethers.parseEther('1000000'),
    EXTREME_PRICE_LOW: 1,
    MAX_PRECISION_DECIMALS: 18,
    ZERO_ADDRESS: ethers.ZeroAddress,
  },

  // Test accounts configuration
  accounts: {
    OWNER: 0,
    STATION_1: 1,
    STATION_2: 2,
    STATION_3: 3,
    MALICIOUS_ACTOR: 4,
    ADVOCATE: 5,
    ORACLE: 6,
    BRIDGE_OPERATOR: 7,
    SLASHING_ADMIN: 8,
    TEST_USERS_START: 9,
    MIN_TEST_ACCOUNTS: 50,
  },

  // Test suite organization
  suites: {
    comprehensive: {
      file: 'FairLaunch.comprehensive.test.js',
      description: 'End-to-end integration tests',
      priority: 1,
      estimatedTime: '30 minutes',
    },
    security: {
      file: 'FairLaunch.security.test.js',
      description: 'Security vulnerability tests',
      priority: 2,
      estimatedTime: '45 minutes',
    },
    performance: {
      file: 'FairLaunch.performance.test.js',
      description: 'Gas optimization and scalability tests',
      priority: 3,
      estimatedTime: '20 minutes',
    },
    edgeCases: {
      file: 'FairLaunch.edgecases.test.js',
      description: 'Boundary conditions and edge cases',
      priority: 4,
      estimatedTime: '25 minutes',
    },
  },

  // Coverage requirements
  coverage: {
    statements: 95,
    branches: 90,
    functions: 95,
    lines: 95,
  },

  // Reporting configuration
  reporting: {
    formats: ['html', 'json', 'text'],
    outputDir: './test-reports',
    includeGasReports: true,
    includeCoverage: true,
    includeSecurityAnalysis: true,
  },
};

// Helper functions for test setup
const TEST_HELPERS = {
  /**
   * Get standard test accounts configuration
   */
  getTestAccounts: function (signers) {
    return {
      owner: signers[TEST_CONFIG.accounts.OWNER],
      station1: signers[TEST_CONFIG.accounts.STATION_1],
      station2: signers[TEST_CONFIG.accounts.STATION_2],
      station3: signers[TEST_CONFIG.accounts.STATION_3],
      maliciousActor: signers[TEST_CONFIG.accounts.MALICIOUS_ACTOR],
      advocate: signers[TEST_CONFIG.accounts.ADVOCATE],
      oracle: signers[TEST_CONFIG.accounts.ORACLE],
      bridgeOperator: signers[TEST_CONFIG.accounts.BRIDGE_OPERATOR],
      slashingAdmin: signers[TEST_CONFIG.accounts.SLASHING_ADMIN],
      testUsers: signers.slice(TEST_CONFIG.accounts.TEST_USERS_START),
    };
  },

  /**
   * Get standard stake parameters for testing
   */
  getStandardStakeParams: function () {
    return {
      participationType: 0, // WEATHER_STATION_BASIC
      geographicZone: 0, // DEVELOPED_MARKET
      verificationLevel: 1, // BASIC_KYC
      social: {
        githubVerified: false,
        twitterVerified: false,
        linkedinVerified: false,
      },
      density: {
        nearbyStationsCount: 5,
        isDensityVerified: false,
      },
      hybridServices: {
        providesWeatherData: false,
        providesForecasting: false,
        providesDataStorage: false,
        providesValidation: false,
      },
    };
  },

  /**
   * Get extreme stake parameters for edge case testing
   */
  getExtremeStakeParams: function () {
    return {
      participationType: 4, // Most complex
      geographicZone: 2, // FRONTIER_MARKET
      verificationLevel: 3, // FULL_KYC
      social: {
        githubVerified: true,
        twitterVerified: true,
        linkedinVerified: true,
      },
      density: {
        nearbyStationsCount: 1000,
        isDensityVerified: true,
      },
      hybridServices: {
        providesWeatherData: true,
        providesForecasting: true,
        providesDataStorage: true,
        providesValidation: true,
      },
    };
  },

  /**
   * Calculate expected gas usage
   */
  calculateExpectedGas: function (operationType, batchSize = 1) {
    const baseGas = TEST_CONFIG.gasLimits[operationType] || 100000;
    return baseGas * batchSize;
  },

  /**
   * Generate test station ID
   */
  generateStationId: function (testName, index = 0) {
    return `${testName}_station_${index}_${Date.now()}`;
  },

  /**
   * Check if test should be skipped based on network conditions
   */
  shouldSkipTest: function (testType, networkConditions) {
    // Skip performance tests on slow networks
    if (testType === 'performance' && networkConditions.slow) {
      return true;
    }

    // Skip large-scale tests with insufficient accounts
    if (testType === 'largescale' && networkConditions.accountCount < 50) {
      return true;
    }

    return false;
  },
};

// Export configuration and helpers
module.exports = {
  TEST_CONFIG,
  TEST_HELPERS,
};

// Console logging for test configuration
if (require.main === module) {
  console.log('WRFCoin Fair Launch Test Configuration');
  console.log('=====================================');
  console.log(`Total test suites: ${Object.keys(TEST_CONFIG.suites).length}`);
  console.log(
    `Estimated total runtime: ${Object.values(TEST_CONFIG.suites).reduce(
      (total, suite) => total + parseInt(suite.estimatedTime),
      0
    )} minutes`
  );
  console.log(
    `Coverage targets: ${TEST_CONFIG.coverage.statements}% statements, ${TEST_CONFIG.coverage.branches}% branches`
  );
  console.log(
    `Gas limits configured for ${Object.keys(TEST_CONFIG.gasLimits).length} operation types`
  );
  console.log(
    `Performance benchmarks: ${TEST_CONFIG.performance.MIN_TPS} TPS minimum, ${TEST_CONFIG.performance.MAX_STATE_SIZE} max entities`
  );
}
