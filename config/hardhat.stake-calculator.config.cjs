require('@nomicfoundation/hardhat-ethers');
require('@nomicfoundation/hardhat-chai-matchers');

module.exports = {
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },
  // Only include specific files for testing the DynamicStakeCalculator
  contracts: [
    'contracts/libraries/DynamicStakeCalculator.sol',
    'contracts/test/DynamicStakeCalculatorTest.sol',
    'contracts/FairLaunchStakeManager.sol',
  ],
};
