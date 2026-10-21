'use strict';

const LOCAL_NETWORKS = new Set(['hardhat', 'localhost', 'testnet_local']);
const DEFAULT_LOCAL_URLS = new Set([
  'http://127.0.0.1:8545',
  'http://localhost:8545',
]);
const DEFAULT_HARDHAT_MNEMONIC = 'test test test test test test test test test test test junk';
const ZERO_PRIVATE_KEY = `0x${'0'.repeat(64)}`;
const NATIVE_CORE4_PORTS = new Set(['8080']);

function isLocalNetwork(networkName) {
  return LOCAL_NETWORKS.has(networkName);
}

function requireLiveDeployConfig(network, env = process.env) {
  if (isLocalNetwork(network.name)) {
    return;
  }

  if (!env.PRIVATE_KEY && !env.MNEMONIC) {
    throw new Error(
      `${network.name} deployment requires PRIVATE_KEY or MNEMONIC; refusing to use an implicit local account`
    );
  }

  if (env.MNEMONIC === DEFAULT_HARDHAT_MNEMONIC) {
    throw new Error(
      `${network.name} deployment refuses the default Hardhat mnemonic`
    );
  }

  if (env.PRIVATE_KEY === ZERO_PRIVATE_KEY) {
    throw new Error('PRIVATE_KEY is the all-zero placeholder; refusing deployment');
  }

  const rpcUrl = network.config?.url;
  if (!rpcUrl || DEFAULT_LOCAL_URLS.has(rpcUrl)) {
    throw new Error(
      `${network.name} deployment requires an explicit live RPC URL; refusing localhost fallback`
    );
  }

  if (network.name === 'external_evm') {
    requireExperimentalEvmApproval(network, env);
  }
}

function requireExperimentalEvmApproval(network, env = process.env) {
  const rpcUrl = network.config?.url;
  const parsed = new URL(rpcUrl);
  const configuredChainId = Number(network.config?.chainId);
  const approvedChainIds = new Set(
    (env.WRFCOIN_APPROVED_EVM_CHAIN_IDS || '')
      .split(',')
      .map(value => Number(value.trim()))
      .filter(Number.isSafeInteger)
  );
  const nativeApiUrls = [env.WRFCOIN_API_URL, env.WRFCOIN_NATIVE_API_URL]
    .filter(Boolean)
    .map(value => value.replace(/\/$/, ''));

  if (['localhost', '127.0.0.1', '::1', '0.0.0.0'].includes(parsed.hostname)) {
    throw new Error('external_evm rejects localhost; use an approved external EVM RPC');
  }
  if (NATIVE_CORE4_PORTS.has(parsed.port) || nativeApiUrls.includes(rpcUrl.replace(/\/$/, ''))) {
    throw new Error('external_evm rejects native Core4 API URLs');
  }
  if (!Number.isSafeInteger(configuredChainId) || configuredChainId <= 0) {
    throw new Error('external_evm requires EXTERNAL_EVM_CHAIN_ID');
  }
  if (!approvedChainIds.has(configuredChainId)) {
    throw new Error(
      `external_evm chain id ${configuredChainId} is not listed in WRFCOIN_APPROVED_EVM_CHAIN_IDS`
    );
  }
  if (!env.WRFCOIN_EVM_DECISION_RECORD) {
    throw new Error('external_evm requires WRFCOIN_EVM_DECISION_RECORD before reactivation');
  }
}

function describeExperimentalEvmTarget(network, actualChainId, env = process.env) {
  requireExperimentalEvmApproval(network, env);
  const configuredChainId = Number(network.config.chainId);
  if (Number(actualChainId) !== configuredChainId) {
    throw new Error(
      `external_evm RPC reports chain id ${actualChainId}, expected approved ${configuredChainId}`
    );
  }
  return {
    target: network.config.url,
    chainId: configuredChainId,
    decisionRecord: env.WRFCOIN_EVM_DECISION_RECORD,
    evidenceClass: 'EXPERIMENTAL_EXTERNAL_EVM_DEPLOYMENT_RECEIPTS_REQUIRED',
    nativeTestnet: 'NOT_APPLICABLE/PARKED',
  };
}

async function requireMinimumBalance(ethers, address, minimumEth) {
  const minimum = ethers.parseEther(minimumEth);
  const balance = await ethers.provider.getBalance(address);

  if (balance < minimum) {
    throw new Error(
      `Deployer ${address} balance ${ethers.formatEther(balance)} ETH is below required ${minimumEth} ETH`
    );
  }

  return balance;
}

module.exports = {
  isLocalNetwork,
  describeExperimentalEvmTarget,
  requireExperimentalEvmApproval,
  requireLiveDeployConfig,
  requireMinimumBalance,
};
