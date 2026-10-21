'use strict';

/**
 * Compatibility wrapper for the legacy WRFCoin deploy entrypoint.
 *
 * The previous implementation only simulated deployments and defaulted to a
 * localhost RPC plus an all-zero deployer key. Keep this file callable for old
 * operator muscle memory, but route every real deployment through the canonical
 * Hardhat script at scripts/deploy.js.
 */

const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.join(__dirname, '..');
const LOCAL_URLS = new Set(['http://127.0.0.1:8545', 'http://localhost:8545']);
const ZERO_PRIVATE_KEY = `0x${'0'.repeat(64)}`;

const NETWORKS = {
  wrfcoin_external_evm: {
    hardhatNetwork: 'external_evm',
    rpcEnv: 'WRFCOIN_EXTERNAL_EVM_RPC',
    targetRpcEnv: 'EXTERNAL_EVM_RPC_URL',
    chainIdEnv: 'WRFCOIN_EXTERNAL_EVM_CHAIN_ID',
    targetChainIdEnv: 'EXTERNAL_EVM_CHAIN_ID',
    allowLocalDefaults: false,
  },
  wrfcoin_mainnet: {
    hardhatNetwork: 'mainnet',
    rpcEnv: 'WRFCOIN_MAINNET_RPC',
    targetRpcEnv: 'MAINNET_RPC_URL',
    chainIdEnv: 'WRFCOIN_MAINNET_CHAIN_ID',
    targetChainIdEnv: 'MAINNET_CHAIN_ID',
    allowLocalDefaults: false,
  },
  wrfcoin_local: {
    hardhatNetwork: 'testnet_local',
    rpcEnv: 'WRFCOIN_LOCAL_RPC',
    targetRpcEnv: 'TESTNET_LOCAL_RPC_URL',
    chainIdEnv: 'WRFCOIN_LOCAL_CHAIN_ID',
    targetChainIdEnv: 'TESTNET_LOCAL_CHAIN_ID',
    allowLocalDefaults: true,
  },
};

function normalizePrivateKey(value) {
  return value ? value.trim() : '';
}

function requireExplicitLiveConfig(networkName, config, env) {
  const rpcUrl = env[config.rpcEnv] || env[config.targetRpcEnv];
  const privateKey = normalizePrivateKey(env.WRFCOIN_DEPLOYER_KEY || env.PRIVATE_KEY);
  const mnemonic = env.MNEMONIC;

  if (!rpcUrl || LOCAL_URLS.has(rpcUrl)) {
    throw new Error(
      `${networkName} requires ${config.rpcEnv} or ${config.targetRpcEnv}; refusing localhost fallback`
    );
  }

  if (!privateKey && !mnemonic) {
    throw new Error(
      `${networkName} requires WRFCOIN_DEPLOYER_KEY, PRIVATE_KEY, or MNEMONIC`
    );
  }

  if (privateKey === ZERO_PRIVATE_KEY) {
    throw new Error(`${networkName} deployer key is the all-zero placeholder`);
  }
}

function buildHardhatEnv(networkName, config, env = process.env) {
  if (!config.allowLocalDefaults) {
    requireExplicitLiveConfig(networkName, config, env);
  }

  const hardhatEnv = { ...env };

  if (env[config.rpcEnv]) {
    hardhatEnv[config.targetRpcEnv] = env[config.rpcEnv];
  }

  if (env[config.chainIdEnv]) {
    hardhatEnv[config.targetChainIdEnv] = env[config.chainIdEnv];
  }

  if (env.WRFCOIN_DEPLOYER_KEY) {
    hardhatEnv.PRIVATE_KEY = env.WRFCOIN_DEPLOYER_KEY;
  }

  return hardhatEnv;
}

function hardhatBin() {
  return path.join(
    REPO_ROOT,
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'hardhat.cmd' : 'hardhat'
  );
}

function deployWithHardhat(networkName, env = process.env) {
  if (networkName === 'wrfcoin_testnet') {
    throw new Error(
      'wrfcoin_testnet EVM deployment is NOT_APPLICABLE/PARKED; use wrfcoin_external_evm only after an approved decision record'
    );
  }
  const config = NETWORKS[networkName];

  if (!config) {
    throw new Error(
      `Unknown WRFCoin network "${networkName}". Expected one of: ${Object.keys(NETWORKS).join(', ')}`
    );
  }

  const result = spawnSync(
    hardhatBin(),
    [
      '--config',
      './hardhat.config.js',
      'run',
      'scripts/deploy.js',
      '--network',
      config.hardhatNetwork,
    ],
    {
      cwd: REPO_ROOT,
      env: buildHardhatEnv(networkName, config, env),
      stdio: 'inherit',
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`Hardhat deploy failed with exit code ${result.status}`);
  }
}

function main() {
  const networkName = process.env.WRFCOIN_NETWORK || 'wrfcoin_testnet';
  deployWithHardhat(networkName);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error('Deployment aborted:', error.message);
    process.exit(1);
  }
}

module.exports = {
  NETWORKS,
  buildHardhatEnv,
  deployWithHardhat,
  requireExplicitLiveConfig,
};
