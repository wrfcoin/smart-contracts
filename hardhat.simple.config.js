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
    },
  },
  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },
  mocha: {
    timeout: 600000,
  },
  gasReporter: {
    enabled: false,
    currency: 'USD',
    gasPrice: 20,
  },
};
