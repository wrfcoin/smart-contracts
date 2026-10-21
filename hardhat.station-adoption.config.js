'use strict';

/**
 * Scoped Hardhat config for StationAdoption tests.
 *
 * Uses an isolated source directory (contracts-station/) containing only the
 * contracts required for StationAdoptionPool and its certificate NFT.  This
 * sidesteps the pre-existing compile-broken contracts left in a broken state
 * by commit 591ea32 (ICarbonCreditAMM type-mismatch) without touching them.
 *
 * contracts-station/ holds symlinks that mirror the relative-path layout so
 * that intra-project imports such as "./interfaces/IStationAdoptionCertificateNFT.sol"
 * resolve correctly.
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
    sources: './contracts-station',
    tests: './test',
    cache: './cache-station',
    artifacts: './artifacts-station',
  },
  mocha: { timeout: 120000 },
};
