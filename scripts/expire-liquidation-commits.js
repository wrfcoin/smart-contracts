'use strict';

/**
 * Permissionless liquidation-commit cleanup keeper (#153).
 *
 * Required: RPC_URL, DERIVATIVES_ENGINE_ADDRESS, KEEPER_START_BLOCK.
 * Dry-run is the default. Set KEEPER_SEND=true and KEEPER_PRIVATE_KEY only
 * after reviewing the discovered commit set for the target chain.
 */
const { ethers } = require('ethers');

const ABI = [
  'event LiquidationCommitted(address indexed liquidator, bytes32 indexed commitHash, uint256 timestamp)',
  'function COMMIT_REVEAL_WINDOW() view returns (uint256)',
  'function getLiquidationCommit(address liquidator, bytes32 commitHash) view returns (uint256)',
  'function expireCommit(address liquidator, bytes32 commitHash)',
];

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseStartBlock(value) {
  if (!/^[0-9]+$/.test(value)) throw new Error('KEEPER_START_BLOCK must be a non-negative integer');
  return BigInt(value);
}

async function getCommitEvents(contract, startBlock, endBlock) {
  const events = [];
  const chunk = 2_000n;
  for (let from = startBlock; from <= endBlock; from += chunk) {
    const to = from + chunk - 1n > endBlock ? endBlock : from + chunk - 1n;
    events.push(...await contract.queryFilter(contract.filters.LiquidationCommitted(), from, to));
  }
  return events;
}

async function main() {
  const rpcUrl = required('RPC_URL');
  const engineAddress = required('DERIVATIVES_ENGINE_ADDRESS');
  const startBlock = parseStartBlock(required('KEEPER_START_BLOCK'));
  const send = process.env.KEEPER_SEND === 'true';
  if (send) required('KEEPER_PRIVATE_KEY');

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const latest = await provider.getBlock('latest');
  if (!latest) throw new Error('RPC returned no latest block');
  const endBlock = BigInt(latest.number);
  if (startBlock > endBlock) throw new Error('KEEPER_START_BLOCK is after the chain head');

  const signer = send
    ? new ethers.NonceManager(new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider))
    : null;
  const contract = new ethers.Contract(engineAddress, ABI, signer || provider);
  const revealWindow = await contract.COMMIT_REVEAL_WINDOW();
  const events = await getCommitEvents(contract, startBlock, endBlock);
  const seen = new Set();
  let submittedCount = 0;
  let failureCount = 0;

  console.log(`mode=${send ? 'send' : 'dry-run'} head=${endBlock} commits=${events.length}`);
  for (const event of events) {
    const liquidator = event.args.liquidator;
    const commitHash = event.args.commitHash;
    const key = `${liquidator}:${commitHash}`;
    if (seen.has(key)) continue;
    seen.add(key);

    const committedAt = await contract.getLiquidationCommit(liquidator, commitHash);
    if (committedAt === 0n || BigInt(latest.timestamp) <= committedAt + revealWindow) continue;

    if (!send) {
      console.log(`would-expire liquidator=${liquidator} hash=${commitHash} committedAt=${committedAt}`);
      continue;
    }

    try {
      const tx = await contract.expireCommit(liquidator, commitHash);
      console.log(`submitted ${tx.hash} liquidator=${liquidator} hash=${commitHash}`);
      if (send) {
        await tx.wait();
      }
      if (send) {
        submittedCount += 1;
      }
    } catch (error) {
      failureCount += 1;
      console.error(`failed to expire liquidator=${liquidator} hash=${commitHash}: ${error.message}`);
    }
  }

  if (send) {
    console.log(`submitted count = ${submittedCount}`);
    if (failureCount > 0) process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`liquidation-commit keeper failed: ${error.message}`);
  process.exitCode = 1;
});
