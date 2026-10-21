'use strict';

/**
 * Scoped Hardhat config for ParametricWeatherInsurance tests.
 *
 * Uses an isolated source directory (contracts-insurance/) containing only the
 * contracts required for this feature, sidestep the pre-existing compile errors
 * in CarbonCreditAMM and fraud-detection contracts (commit 591ea32) without
 * touching those files.
 *
 * contracts-insurance/ holds symlinks that mirror the relative-path layout so
 * that intra-project imports resolve correctly.
 */

require('@nomicfoundation/hardhat-toolbox');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: '0.8.28',
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: 'cancun',
    },
  },
  allowUnlimitedContractSize: true,
  networks: {
    hardhat: {
      chainId: 1337,
      hardfork: 'cancun',
      gas: 'auto',
      blockGasLimit: 30000000,
      gasPrice: 8000000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic: process.env.MNEMONIC || 'test test test test test test test test test test test junk',
        count: 10,
        accountsBalance: '10000000000000000000000000',
      },
    },
  },
  paths: {
    sources: './contracts-insurance',
    tests: './test',
    cache: './cache-insurance',
    artifacts: './artifacts-insurance',
  },
  mocha: { timeout: 120000 },
};
