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

  const depositToken = process.env.DEPOSIT_TOKEN_ADDRESS;
  const yieldSource = process.env.YIELD_SOURCE_ADDRESS;
  const carbonTreasury = process.env.CARBON_TREASURY_ADDRESS;
  const epochDuration = Number(process.env.CARBON_EPOCH_DURATION_SECONDS || 604800);
  const donationBps = Number(process.env.CARBON_DONATION_BPS || 1000);

  if (!depositToken || !yieldSource || !carbonTreasury) {
    throw new Error(
      'DEPOSIT_TOKEN_ADDRESS, YIELD_SOURCE_ADDRESS, and CARBON_TREASURY_ADDRESS are required'
    );
  }

  const CarbonLottery = await ethers.getContractFactory('CarbonLottery');
  const carbonLottery = await CarbonLottery.deploy(
    deployer.address,
    depositToken,
    yieldSource,
    carbonTreasury,
    epochDuration,
    donationBps
  );
  await carbonLottery.waitForDeployment();

  console.log('CarbonLottery deployed');
  console.log('  address:', await carbonLottery.getAddress());
  console.log('  owner:', deployer.address);
  console.log('  depositToken:', depositToken);
  console.log('  yieldSource:', yieldSource);
  console.log('  carbonTreasury:', carbonTreasury);
  console.log('  epochDuration:', epochDuration);
  console.log('  donationBps:', donationBps);
}

main().catch((error) => {
  console.error('CarbonLottery deployment failed:', error);
  process.exitCode = 1;
});
