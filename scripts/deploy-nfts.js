'use strict';

const hre = require('hardhat');
const {
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('./lib/launchReadiness');

async function main() {
  requireLiveDeployConfig(hre.network);

  const [deployer] = await hre.ethers.getSigners();
  await requireMinimumBalance(
    hre.ethers,
    deployer.address,
    process.env.MIN_DEPLOYER_BALANCE_ETH || '0.05'
  );

  const authorizedOracle =
    process.env.AUTHORIZED_ORACLE || deployer.address;
  const extremeWeatherOracle =
    process.env.EXTREME_WEATHER_ORACLE || hre.ethers.ZeroAddress;

  const WeatherSVG = await hre.ethers.getContractFactory('WeatherSVG');
  const weatherSvg = await WeatherSVG.deploy();
  await weatherSvg.waitForDeployment();

  const WeatherStreakNFT = await hre.ethers.getContractFactory('WeatherStreakNFT', {
    libraries: {
      WeatherSVG: await weatherSvg.getAddress(),
    },
  });
  const streak = await WeatherStreakNFT.deploy(authorizedOracle);
  await streak.waitForDeployment();

  const StormChaserNFT = await hre.ethers.getContractFactory('StormChaserNFT', {
    libraries: {
      WeatherSVG: await weatherSvg.getAddress(),
    },
  });
  const storm = await StormChaserNFT.deploy(
    authorizedOracle,
    extremeWeatherOracle
  );
  await storm.waitForDeployment();

  console.log('WeatherSVG:', await weatherSvg.getAddress());
  console.log('WeatherStreakNFT:', await streak.getAddress());
  console.log('StormChaserNFT:', await storm.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
