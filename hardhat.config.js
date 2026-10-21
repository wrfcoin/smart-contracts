require('@nomicfoundation/hardhat-toolbox');
require('dotenv').config();

const DEFAULT_HARDHAT_MNEMONIC = 'test test test test test test test test test test test junk';
const DEFAULT_LOCAL_URL = 'http://127.0.0.1:8545';

function localAccounts() {
  return {
    mnemonic: process.env.MNEMONIC || DEFAULT_HARDHAT_MNEMONIC,
  };
}

function deployAccounts() {
  if (process.env.PRIVATE_KEY) {
    return [process.env.PRIVATE_KEY];
  }

  if (process.env.MNEMONIC) {
    return { mnemonic: process.env.MNEMONIC };
  }

  return [];
}

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
      evmVersion: 'cancun',
    },
  },
  allowUnlimitedContractSize: true,
  networks: {
    hardhat: {
      chainId: 1337,
      hardfork: 'cancun', // Use cancun to avoid EIP-7825 per-tx gas cap (16M) from osaka/fusaka
      gas: 'auto',
      blockGasLimit: 30000000,
      gasPrice: 8000000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic: process.env.MNEMONIC || DEFAULT_HARDHAT_MNEMONIC,
        count: 50,
        accountsBalance: '10000000000000000000000000',
      },
    },
    testnet_local: {
      url: process.env.TESTNET_LOCAL_RPC_URL || DEFAULT_LOCAL_URL,
      chainId: Number(process.env.TESTNET_LOCAL_CHAIN_ID || 1337),
      accounts: localAccounts(),
    },
    // Experimental external EVM only. This is not the native WRFCoin testnet.
    // The deployment guard requires an approved chain id and decision record,
    // and rejects this fail-closed placeholder before any transaction.
    external_evm: {
      url: process.env.EXTERNAL_EVM_RPC_URL || 'http://127.0.0.1:1',
      chainId: Number(process.env.EXTERNAL_EVM_CHAIN_ID || 0),
      accounts: deployAccounts(),
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || DEFAULT_LOCAL_URL,
      chainId: Number(process.env.SEPOLIA_CHAIN_ID || 11155111),
      accounts: deployAccounts(),
    },
    // NOTE (#234): 'mainnet' likewise defaults to localhost absent MAINNET_RPC_URL. Nothing has
    // ever been deployed to a real mainnet from this repo.
    mainnet: {
      url: process.env.MAINNET_RPC_URL || DEFAULT_LOCAL_URL,
      chainId: Number(process.env.MAINNET_CHAIN_ID || 1),
      accounts: deployAccounts(),
    },
  },
  paths: {
    sources: './contracts', // Look for contracts in contracts subdirectory
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },
  mocha: {
    timeout: 600000, // 10 minutes default timeout
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === 'true',
    currency: 'USD',
    gasPrice: 20,
    showTimeSpent: true,
  },
};
