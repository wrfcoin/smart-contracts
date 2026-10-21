'use strict';

const crypto = require('crypto');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');

const SCHEMA_PATH = path.resolve(
  __dirname,
  '..',
  '..',
  'deployment-manifest.schema.json'
);
const SCHEMA = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
const RELEASE_INVENTORY = Object.freeze(
  SCHEMA['x-releaseInventory'].map(entry =>
    Object.freeze({
      name: entry.name,
      dependencies: Object.freeze([...entry.dependencies]),
    })
  )
);
const ZERO_ADDRESS = `0x${'0'.repeat(40)}`;

function artifactHash(artifact) {
  return `0x${crypto.createHash('sha256').update(JSON.stringify(artifact)).digest('hex')}`;
}

function manifestPathFor(
  networkName,
  root = path.resolve(__dirname, '..', '..', 'deployments')
) {
  return path.join(root, networkName, 'release-manifest.json');
}

async function writeManifestAtomic(manifestPath, manifest) {
  const directory = path.dirname(manifestPath);
  await fsp.mkdir(directory, { recursive: true });
  const temporaryPath = path.join(
    directory,
    `.${path.basename(manifestPath)}.${process.pid}.${Date.now()}.tmp`
  );
  await fsp.writeFile(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
  });
  await fsp.rename(temporaryPath, manifestPath);
}

function requireField(condition, message) {
  if (!condition) throw new Error(`Invalid deployment manifest: ${message}`);
}

async function validateManifest(
  manifest,
  { provider, artifacts, networkName }
) {
  requireField(
    manifest && typeof manifest === 'object',
    'root must be an object'
  );
  requireField(manifest.schemaVersion === 1, 'unsupported schemaVersion');
  requireField(
    Number.isInteger(manifest.chainId) && manifest.chainId > 0,
    'chainId must be positive'
  );
  requireField(
    manifest.network === networkName,
    `network must be ${networkName}`
  );
  requireField(
    /^0x[0-9a-fA-F]{40}$/.test(manifest.deployer),
    'deployer must be an address'
  );
  requireField(
    /^[0-9a-f]{40}$/.test(manifest.sourceRevision),
    'sourceRevision must be a full git SHA'
  );
  requireField(
    !Number.isNaN(Date.parse(manifest.createdAt)),
    'createdAt must be an ISO timestamp'
  );
  requireField(Array.isArray(manifest.contracts), 'contracts must be an array');

  const providerNetwork = await provider.getNetwork();
  requireField(
    Number(providerNetwork.chainId) === manifest.chainId,
    'chainId does not match provider'
  );

  const expectedNames = RELEASE_INVENTORY.map(entry => entry.name);
  const actualNames = manifest.contracts.map(entry => entry.name);
  requireField(
    new Set(actualNames).size === actualNames.length,
    'duplicate contract name'
  );
  requireField(
    actualNames.length === expectedNames.length &&
      expectedNames.every(name => actualNames.includes(name)),
    `required inventory is ${expectedNames.join(', ')}`
  );

  const byName = new Map(manifest.contracts.map(entry => [entry.name, entry]));
  const addresses = new Set();
  const currentBlock = await provider.getBlockNumber();

  for (const inventoryEntry of RELEASE_INVENTORY) {
    const entry = byName.get(inventoryEntry.name);
    requireField(
      /^0x[0-9a-fA-F]{40}$/.test(entry.address),
      `${entry.name} has invalid address`
    );
    requireField(
      entry.address.toLowerCase() !== ZERO_ADDRESS,
      `${entry.name} has zero address`
    );
    requireField(
      !addresses.has(entry.address.toLowerCase()),
      `${entry.name} has duplicate address`
    );
    addresses.add(entry.address.toLowerCase());
    requireField(
      /^0x[0-9a-fA-F]{64}$/.test(entry.transactionHash),
      `${entry.name} has invalid transaction hash`
    );
    requireField(
      Number.isInteger(entry.blockNumber),
      `${entry.name} has invalid block number`
    );
    requireField(
      entry.blockNumber <= currentBlock,
      `${entry.name} has future block number`
    );
    requireField(
      /^0x[0-9a-fA-F]{64}$/.test(entry.artifactHash),
      `${entry.name} has invalid artifact hash`
    );

    const artifact = await artifacts.readArtifact(entry.name);
    requireField(
      artifactHash(artifact) === entry.artifactHash,
      `${entry.name} artifact hash is stale`
    );
    requireField(
      (await provider.getCode(entry.address)) !== '0x',
      `${entry.name} has no deployed code`
    );

    const receipt = await provider.getTransactionReceipt(entry.transactionHash);
    requireField(
      receipt && Number(receipt.status) === 1,
      `${entry.name} deployment receipt is missing or failed`
    );
    requireField(
      receipt.blockNumber === entry.blockNumber,
      `${entry.name} block number does not match receipt`
    );
    requireField(
      receipt.contractAddress &&
        receipt.contractAddress.toLowerCase() === entry.address.toLowerCase(),
      `${entry.name} address does not match deployment receipt`
    );

    const dependencyNames = Object.keys(entry.dependencies || {}).sort();
    requireField(
      JSON.stringify(dependencyNames) ===
        JSON.stringify([...inventoryEntry.dependencies].sort()),
      `${entry.name} dependency set does not match schema`
    );
    for (const dependencyName of inventoryEntry.dependencies) {
      requireField(
        entry.dependencies[dependencyName]?.toLowerCase() ===
          byName.get(dependencyName).address.toLowerCase(),
        `${entry.name} dependency ${dependencyName} does not match manifest address`
      );
    }
  }

  return manifest;
}

async function loadAndValidateManifest(manifestPath, options) {
  let manifest;
  try {
    manifest = JSON.parse(await fsp.readFile(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error(
      `Cannot read deployment manifest ${manifestPath}: ${error.message}`
    );
  }
  return validateManifest(manifest, options);
}

module.exports = {
  RELEASE_INVENTORY,
  SCHEMA,
  artifactHash,
  loadAndValidateManifest,
  manifestPathFor,
  validateManifest,
  writeManifestAtomic,
};
