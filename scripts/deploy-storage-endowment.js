const { ethers, network } = require("hardhat");
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require("./lib/launchReadiness");

async function main() {
  requireLiveDeployConfig(network);

  const [deployer] = await ethers.getSigners();
  await requireMinimumBalance(
    ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || "0.05"
  );

  const WRF_TOKEN = process.env.WRF_TOKEN_ADDRESS;

  if (!WRF_TOKEN) {
    throw new Error("WRF_TOKEN_ADDRESS is required");
  }

  const MAX_DAILY = ethers.parseEther(process.env.MAX_DAILY_CLAIM || "1000");
  const RATE_BPS = parseInt(process.env.ENDOWMENT_RATE_BPS || "50", 10);

  const Factory = await ethers.getContractFactory("StorageEndowment");
  const contract = await Factory.deploy(WRF_TOKEN, MAX_DAILY, RATE_BPS);
  await contract.waitForDeployment();

  console.log("Deployer:", deployer.address);
  console.log("StorageEndowment deployed to:", await contract.getAddress());
  console.log("Rate (bps):", RATE_BPS, "(", RATE_BPS / 100, "%)");
  console.log("Max daily claim:", ethers.formatEther(MAX_DAILY), "WRF");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
