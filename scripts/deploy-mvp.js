/**
 * WRFCoin MVP Contract Deployment Script
 *
 * Deploys the 8 core contracts needed for the MVP value loop:
 * 1. WRFToken - Main token
 * 2. WRFTokenTestnet - Testnet token for development
 * 3. ProofOfPublishing - PoP consensus contract
 * 4. WeatherDataValidator - Weather data quality validation
 * 5. RewardDistributor - Token reward distribution
 * 6. CommunityGovernance - Basic governance (proposals/voting)
 * 7. NFTMarketplace - NFT listing and trading
 * 8. ComputationalNFT - Computational NFT minting
 *
 * Usage:
 *   npx hardhat run contracts/scripts/deploy-mvp.js --network localhost
 *   # Local simulation only; release-shaped external EVM deploys use
 *   # npm run deploy:evm:experimental after an approved decision record.
 */

const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");
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

  console.log("Deploying MVP contracts with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  const deployed = {};

  // 1. Deploy WRFToken
  console.log("\n1/8 Deploying WRFToken...");
  const WRFToken = await ethers.getContractFactory("WRFToken");
  const wrfToken = await WRFToken.deploy();
  await wrfToken.waitForDeployment();
  deployed.WRFToken = await wrfToken.getAddress();
  console.log("   WRFToken deployed to:", deployed.WRFToken);

  // 2. Deploy WRFTokenTestnet
  console.log("\n2/8 Deploying WRFTokenTestnet...");
  const WRFTokenTestnet = await ethers.getContractFactory("WRFTokenTestnet");
  const wrfTokenTestnet = await WRFTokenTestnet.deploy();
  await wrfTokenTestnet.waitForDeployment();
  deployed.WRFTokenTestnet = await wrfTokenTestnet.getAddress();
  console.log("   WRFTokenTestnet deployed to:", deployed.WRFTokenTestnet);

  // 3. Deploy ProofOfPublishing
  console.log("\n3/8 Deploying ProofOfPublishing...");
  const ProofOfPublishing = await ethers.getContractFactory("ProofOfPublishing");
  const proofOfPublishing = await ProofOfPublishing.deploy();
  await proofOfPublishing.waitForDeployment();
  deployed.ProofOfPublishing = await proofOfPublishing.getAddress();
  console.log("   ProofOfPublishing deployed to:", deployed.ProofOfPublishing);

  // 4. Deploy WeatherDataValidator
  console.log("\n4/8 Deploying WeatherDataValidator...");
  const WeatherDataValidator = await ethers.getContractFactory("WeatherDataValidator");
  const weatherDataValidator = await WeatherDataValidator.deploy();
  await weatherDataValidator.waitForDeployment();
  deployed.WeatherDataValidator = await weatherDataValidator.getAddress();
  console.log("   WeatherDataValidator deployed to:", deployed.WeatherDataValidator);

  // 5. Deploy RewardDistributor
  console.log("\n5/8 Deploying RewardDistributor...");
  const RewardDistributor = await ethers.getContractFactory("RewardDistributor");
  const rewardDistributor = await RewardDistributor.deploy(deployed.WRFToken);
  await rewardDistributor.waitForDeployment();
  deployed.RewardDistributor = await rewardDistributor.getAddress();
  console.log("   RewardDistributor deployed to:", deployed.RewardDistributor);

  // 6. Deploy CommunityGovernance
  console.log("\n6/8 Deploying CommunityGovernance...");
  const CommunityGovernance = await ethers.getContractFactory("CommunityGovernance");
  const communityGovernance = await CommunityGovernance.deploy(deployed.WRFToken);
  await communityGovernance.waitForDeployment();
  deployed.CommunityGovernance = await communityGovernance.getAddress();
  console.log("   CommunityGovernance deployed to:", deployed.CommunityGovernance);

  // 7. Deploy NFTMarketplace
  console.log("\n7/8 Deploying NFTMarketplace...");
  const NFTMarketplace = await ethers.getContractFactory("NFTMarketplace");
  const nftMarketplace = await NFTMarketplace.deploy();
  await nftMarketplace.waitForDeployment();
  deployed.NFTMarketplace = await nftMarketplace.getAddress();
  console.log("   NFTMarketplace deployed to:", deployed.NFTMarketplace);

  // 8. Deploy ComputationalNFT
  console.log("\n8/8 Deploying ComputationalNFT...");
  const ComputationalNFT = await ethers.getContractFactory("ComputationalNFT");
  const computationalNFT = await ComputationalNFT.deploy();
  await computationalNFT.waitForDeployment();
  deployed.ComputationalNFT = await computationalNFT.getAddress();
  console.log("   ComputationalNFT deployed to:", deployed.ComputationalNFT);

  // Save deployment addresses
  const outputDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  const deploymentData = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: deployed,
  };

  const outputPath = path.join(outputDir, "mvp-addresses.json");
  fs.writeFileSync(outputPath, JSON.stringify(deploymentData, null, 2));
  console.log("\nDeployment addresses saved to:", outputPath);

  console.log("\n--- MVP Deployment Summary ---");
  console.log("Contracts deployed:", Object.keys(deployed).length);
  Object.entries(deployed).forEach(([name, address]) => {
    console.log(`  ${name}: ${address}`);
  });
  console.log("-----------------------------\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("MVP deployment failed:", error);
    process.exit(1);
  });
