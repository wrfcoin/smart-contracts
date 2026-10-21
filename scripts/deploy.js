const { execFileSync } = require('child_process');
const { ethers, network, artifacts } = require('hardhat');
const {
  describeExperimentalEvmTarget,
  isLocalNetwork,
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('./lib/launchReadiness');
const {
  RELEASE_INVENTORY,
  artifactHash,
  manifestPathFor,
  validateManifest,
  writeManifestAtomic,
} = require('./lib/deploymentManifest');

async function deployContract(name, args = []) {
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log(`${name}: ${address}`);
  const transaction = contract.deploymentTransaction();
  if (!transaction)
    throw new Error(`${name} did not expose a deployment transaction`);
  const receipt = await transaction.wait();
  if (!receipt || Number(receipt.status) !== 1) {
    throw new Error(`${name} deployment transaction did not succeed`);
  }
  return { contract, address, receipt, transactionHash: transaction.hash };
}

function sourceRevision() {
  return execFileSync('git', ['rev-parse', 'HEAD'], {
    encoding: 'utf8',
  }).trim();
}

async function deployRelease(options = {}) {
  requireLiveDeployConfig(network);

  if (network.name === 'external_evm') {
    const providerNetwork = await ethers.provider.getNetwork();
    const target = describeExperimentalEvmTarget(network, providerNetwork.chainId);
    console.log(`EVIDENCE_CLASS=${target.evidenceClass}`);
    console.log(`TARGET_RPC=${target.target}`);
    console.log(`TARGET_CHAIN_ID=${target.chainId}`);
    console.log(`DECISION_RECORD=${target.decisionRecord}`);
    console.log(`NATIVE_TESTNET_EVM=${target.nativeTestnet}`);
  } else if (isLocalNetwork(network.name)) {
    console.log('EVIDENCE_CLASS=SIMULATED_LOCAL_EVM_NON_RELEASE');
  } else {
    throw new Error(
      `Release deployment requires --network external_evm; ${network.name} is not an approved release target`
    );
  }

  const [deployer] = await ethers.getSigners();
  const deployments = new Map();
  const deployerBalance = await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  console.log(`Deploying WRFCoin contracts on ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Deployer balance: ${ethers.formatEther(deployerBalance)} ETH`);

  const wrf = await deployContract('WRFToken');
  deployments.set('WRFToken', wrf);

  const testnetWrf = await deployContract('WRFTokenTestnet');
  deployments.set('WRFTokenTestnet', testnetWrf);

  const qualityOracle = await deployContract('QualityOracle');
  deployments.set('QualityOracle', qualityOracle);

  const proofOfPublishing = await deployContract('ProofOfPublishing', [
    deployer.address,
    deployer.address,
  ]);
  deployments.set('ProofOfPublishing', proofOfPublishing);

  const weatherDataValidator = await deployContract('WeatherDataValidator');
  deployments.set('WeatherDataValidator', weatherDataValidator);

  const rewardDistributor = await deployContract('RewardDistributor', [
    deployer.address,
    qualityOracle.address,
  ]);
  deployments.set('RewardDistributor', rewardDistributor);

  const communityGovernance = await deployContract('CommunityGovernance', [
    deployer.address,
    deployer.address,
  ]);
  deployments.set('CommunityGovernance', communityGovernance);

  const nftMarketplace = await deployContract('NFTMarketplace', [wrf.address]);
  deployments.set('NFTMarketplace', nftMarketplace);

  const computationalNft = await deployContract('ComputationalNFT', [
    wrf.address,
    weatherDataValidator.address,
  ]);
  deployments.set('ComputationalNFT', computationalNft);

  const manifest = {
    schemaVersion: 1,
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    network: network.name,
    deployer: deployer.address,
    sourceRevision: options.sourceRevision || sourceRevision(),
    createdAt: new Date().toISOString(),
    contracts: [],
  };

  for (const inventoryEntry of RELEASE_INVENTORY) {
    const deployed = deployments.get(inventoryEntry.name);
    const artifact = await artifacts.readArtifact(inventoryEntry.name);
    manifest.contracts.push({
      name: inventoryEntry.name,
      address: deployed.address,
      transactionHash: deployed.transactionHash,
      blockNumber: deployed.receipt.blockNumber,
      artifactHash: artifactHash(artifact),
      dependencies: Object.fromEntries(
        inventoryEntry.dependencies.map(name => [
          name,
          deployments.get(name).address,
        ])
      ),
    });
  }

  await validateManifest(manifest, {
    provider: ethers.provider,
    artifacts,
    networkName: network.name,
  });
  const outputPath = options.manifestPath || manifestPathFor(network.name);
  await writeManifestAtomic(outputPath, manifest);
  console.log(`Canonical deployment manifest: ${outputPath}`);
  console.log(JSON.stringify(manifest, null, 2));
  return { manifest, manifestPath: outputPath };
}

async function main() {
  await deployRelease();
}

if (require.main === module) {
  main().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = { deployContract, deployRelease, main };
