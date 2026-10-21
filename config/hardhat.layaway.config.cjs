require('@nomicfoundation/hardhat-toolbox');
require('@openzeppelin/hardhat-upgrades');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      evmVersion: 'paris',
      viaIR: true,
    },
  },

  // Only include specific contracts to avoid compilation issues
  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },

  // Only compile LayawayRegistration and dependencies
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: false,
  },

  networks: {
    hardhat: {
      chainId: 1337,
      gas: 12000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic: 'test test test test test test test test test test test junk',
        count: 20,
      },
    },
    localhost: {
      url: 'http://localhost:8545',
    },
    sepolia: {
      url: process.env.SEPOLIA_URL || '',
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
  },

  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: 'USD',
  },

  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};
