// SPDX-License-Identifier: MIT
/**
 * Regression tests for issue #174:
 *   WRFTokenTestnet.claimWeatherReward bypassed the parent's anti-Sybil gates.
 *
 * The old override enforced only a per-station cooldown + per-station daily cap,
 * then minted 50 WRF and pumped testnetParticipationScore / testnetDataSubmissions
 * with NO contribution proof and NO per-address limits. Since the score feeds
 * calculateGenesisAirdrop, a Sybil farm could inflate its mainnet airdrop.
 *
 * These tests prove the override now enforces:
 *   - a contribution proof is required and consumed per claim (global replay lock)
 *   - the per-address reward cooldown (15 min) binds even past the 10-min per-station one
 */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('WRFTokenTestnet — claimWeatherReward anti-Sybil gates (#174)', function () {
  let token, deployer, station;
  const REWARD = 50n * 10n ** 18n; // TESTNET_WEATHER_REWARD_RATE

  beforeEach(async function () {
    [deployer, station] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory('WRFTokenTestnet', deployer);
    token = await Factory.deploy();
    await token.waitForDeployment();

    await token.connect(station).registerWeatherStationWithStake('station-1', {
      value: await token.TESTNET_REGISTRATION_STAKE(),
    });
  });

  it('reverts a claim with NO contribution proof (the core bypass)', async function () {
    await expect(token.connect(station).claimWeatherReward()).to.be.revertedWith(
      'WRFToken: Contribution proof required'
    );
  });

  it('mints once per submitted proof and consumes it (no proof-less re-claim)', async function () {
    const proof = ethers.id('contribution-1');
    await token.connect(station).submitWeatherContributionProof(proof);

    const scoreBefore = await token.testnetParticipationScore(station.address);
    await token.connect(station).claimWeatherReward();

    expect(await token.balanceOf(station.address)).to.equal(REWARD);
    expect(await token.testnetDataSubmissions(station.address)).to.equal(1n);
    expect(await token.testnetParticipationScore(station.address)).to.equal(scoreBefore + 50n);

    // The proof was consumed and the pending slot cleared → an immediate second
    // claim has no proof to spend and reverts.
    await expect(token.connect(station).claimWeatherReward()).to.be.revertedWith(
      'WRFToken: Contribution proof required'
    );

    // The same proof hash can never be re-submitted (global replay protection).
    await expect(
      token.connect(station).submitWeatherContributionProof(proof)
    ).to.be.revertedWith('WRFToken: Contribution proof already consumed');
  });

  it('enforces the per-ADDRESS 15-min cooldown even after the 10-min per-station cooldown clears', async function () {
    await token.connect(station).submitWeatherContributionProof(ethers.id('p-1'));
    await token.connect(station).claimWeatherReward(); // t0

    // Advance past the 10-min per-station cooldown but not the 15-min per-address one.
    await time.increase(10 * 60);
    await token.connect(station).submitWeatherContributionProof(ethers.id('p-2'));
    await expect(token.connect(station).claimWeatherReward()).to.be.revertedWith(
      'WRFToken: Per-address reward cooldown not met'
    );

    // Advance to the 15-min mark → the same still-pending proof now claims.
    await time.increase(5 * 60);
    await token.connect(station).claimWeatherReward();
    expect(await token.balanceOf(station.address)).to.equal(2n * REWARD);
    expect(await token.testnetDataSubmissions(station.address)).to.equal(2n);
  });

  it('a registered station can complete the legitimate proof→claim earn loop', async function () {
    // Sanity: the added gates do not brick the honest path.
    await token.connect(station).submitWeatherContributionProof(ethers.id('honest'));
    await expect(token.connect(station).claimWeatherReward()).to.not.be.reverted;
    expect(await token.balanceOf(station.address)).to.equal(REWARD);
  });
});
