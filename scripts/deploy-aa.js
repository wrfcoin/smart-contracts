const hre = require('hardhat');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('./lib/launchReadiness');

async function main() {
  requireLiveDeployConfig(hre.network);

  const [deployer] = await hre.ethers.getSigners();
  const entryPointAddress =
    process.env.ENTRY_POINT_ADDRESS || '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789';
  const ownerAddress = process.env.PAYMASTER_OWNER || deployer.address;
  const stakeEth = process.env.AA_PAYMASTER_STAKE_ETH || '1';
  const depositEth = process.env.AA_PAYMASTER_DEPOSIT_ETH || '1';
  const requiredFunding =
    hre.ethers.parseEther(stakeEth) + hre.ethers.parseEther(depositEth);

  await requireMinimumBalance(
    hre.ethers,
    deployer.address,
    hre.ethers.formatEther(requiredFunding)
  );

  console.log(`Deployer: ${deployer.address}`);
  console.log(`EntryPoint: ${entryPointAddress}`);
  console.log(`Owner: ${ownerAddress}`);
  console.log(`Paymaster stake: ${stakeEth} ETH`);
  console.log(`Paymaster deposit: ${depositEth} ETH`);

  const Paymaster = await hre.ethers.getContractFactory('WrfcoinPaymaster');
  const paymaster = await Paymaster.deploy(entryPointAddress, ownerAddress);
  await paymaster.waitForDeployment();

  console.log(`WrfcoinPaymaster deployed: ${await paymaster.getAddress()}`);

  const stakeTx = await paymaster.addStake(86400, {
    value: hre.ethers.parseEther(stakeEth),
  });
  await stakeTx.wait();
  console.log(`Stake added: ${stakeEth} ETH / 86400 seconds`);

  const depositTx = await paymaster.deposit({
    value: hre.ethers.parseEther(depositEth),
  });
  await depositTx.wait();
  console.log(`Deposit added: ${depositEth} ETH`);

  console.log(`Paymaster address for backend config: ${await paymaster.getAddress()}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
