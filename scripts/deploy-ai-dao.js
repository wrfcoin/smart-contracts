'use strict';

const { ethers, network } = require('hardhat');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('./lib/launchReadiness');

async function main() {
  requireLiveDeployConfig(network);

  const [deployer] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  const guardian = process.env.AI_DAO_GUARDIAN || deployer.address;
  const secureVotingSystem = process.env.SECURE_VOTING_SYSTEM_ADDRESS;
  const emissionController = process.env.EMISSION_CONTROLLER_ADDRESS || ethers.ZeroAddress;
  const timelockSeconds = Number(process.env.AI_DAO_TIMELOCK_SECONDS || 172800);

  if (!secureVotingSystem) {
    throw new Error('SECURE_VOTING_SYSTEM_ADDRESS is required');
  }

  const AiDaoExecutor = await ethers.getContractFactory('AiDaoExecutor');
  const aiDaoExecutor = await AiDaoExecutor.deploy(
    deployer.address,
    guardian,
    secureVotingSystem,
    emissionController,
    timelockSeconds
  );
  await aiDaoExecutor.waitForDeployment();

  console.log('AiDaoExecutor deployed');
  console.log('  address:', await aiDaoExecutor.getAddress());
  console.log('  owner:', deployer.address);
  console.log('  guardian:', guardian);
  console.log('  secureVotingSystem:', secureVotingSystem);
  console.log('  emissionController:', emissionController);
  console.log('  timelockSeconds:', timelockSeconds);
}

main().catch((error) => {
  console.error('AiDaoExecutor deployment failed:', error);
  process.exitCode = 1;
});
