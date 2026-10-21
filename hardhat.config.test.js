require('@nomicfoundation/hardhat-toolbox');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  allowUnlimitedContractSize: true,
  networks: {
    hardhat: {
      chainId: 1337,
      gas: 30000000,
      blockGasLimit: 30000000,
      gasPrice: 8000000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic: process.env.MNEMONIC || 'test test test test test test test test test test test junk',
        count: 50,
        accountsBalance: '10000000000000000000000000',
      },
    },
  },
  paths: {
    sources: './', // Point directly to contracts folder
    tests: './test',
    cache: './cache-test',
    artifacts: './artifacts-test',
  },
  mocha: {
    timeout: 600000,
  },
  gasReporter: {
    enabled: true,
    currency: 'USD',
    gasPrice: 20,
    showTimeSpent: true,
  },
};
