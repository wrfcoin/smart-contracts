// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('WRFToken Security Hotfixes', function () {
  const MIN_STAKE = ethers.parseEther('0.01');

  async function deployFixture() {
    const [deployer, station1, station2, attacker] = await ethers.getSigners();
    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();
    await wrfToken.waitForDeployment();

    return { wrfToken, deployer, station1, station2, attacker };
  }

  it('blocks zero-stake registration and duplicate station IDs', async function () {
    const { wrfToken, station1, station2 } = await loadFixture(deployFixture);

    await expect(
      wrfToken.connect(station1).registerWeatherStationSimple('station-alpha')
    ).to.be.revertedWith('WRFToken: Minimum stake is 0.01 ETH for registration');

    await expect(
      wrfToken
        .connect(station1)
        .registerWeatherStationSimple('station-alpha', { value: MIN_STAKE })
    ).to.not.be.reverted;

    await expect(
      wrfToken
        .connect(station2)
        .registerWeatherStationSimple('station-alpha', { value: MIN_STAKE })
    ).to.be.revertedWith('WRFToken: Station ID already registered');
  });

  it('requires contribution proofs and prevents proof replay after claim', async function () {
    const { wrfToken, station1, station2 } = await loadFixture(deployFixture);

    await wrfToken
      .connect(station1)
      .registerWeatherStationSimple('station-proof-1', { value: MIN_STAKE });

    await wrfToken
      .connect(station2)
      .registerWeatherStationSimple('station-proof-2', { value: MIN_STAKE });

    await time.increase(24 * 60 * 60 + 1);

    await expect(wrfToken.connect(station1).claimWeatherReward()).to.be.revertedWith(
      'WRFToken: Contribution proof required'
    );

    const proofHash = ethers.id('weather-proof-1');
    await wrfToken.connect(station1).submitWeatherContributionProof(proofHash);

    await expect(wrfToken.connect(station1).claimWeatherReward()).to.emit(
      wrfToken,
      'WeatherRewardClaimed'
    );

    await expect(
      wrfToken.connect(station2).submitWeatherContributionProof(proofHash)
    ).to.be.revertedWith('WRFToken: Contribution proof already consumed');
  });

  it('rejects expired contribution proofs', async function () {
    const { wrfToken, station1 } = await loadFixture(deployFixture);

    await wrfToken
      .connect(station1)
      .registerWeatherStationSimple('station-expiry', { value: MIN_STAKE });

    await time.increase(24 * 60 * 60 + 1);

    await wrfToken
      .connect(station1)
      .submitWeatherContributionProof(ethers.id('weather-proof-expired'));

    await time.increase(2 * 60 * 60 + 1);

    await expect(wrfToken.connect(station1).claimWeatherReward()).to.be.revertedWith(
      'WRFToken: Contribution proof expired'
    );
  });
});
