// SPDX-License-Identifier: MIT
/**
 * Regression test for issue #164:
 *   WRFTokenTestnet.updateTestnetQualityScore self-auth bypass.
 *
 * The quality score feeds calculateGenesisAirdrop, so it must only be
 * settable by the trusted testnet deployer (operator/oracle role) — never
 * by an arbitrary caller passing `station = msg.sender`.
 */
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("WRFTokenTestnet — updateTestnetQualityScore access control (#164)", function () {
  let token, deployer, station, attacker;

  beforeEach(async function () {
    [deployer, station, attacker] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("WRFTokenTestnet", deployer);
    token = await Factory.deploy();
    await token.waitForDeployment();

    // Register `station` as a legitimate weather station so we also prove a
    // registered station cannot set scores either (only the deployer can).
    await token
      .connect(station)
      .registerWeatherStationWithStake("station-1", {
        value: await token.TESTNET_REGISTRATION_STAKE(),
      });
  });

  it("lets the testnet deployer set a station's quality score", async function () {
    await token.connect(deployer).updateTestnetQualityScore(station.address, 80);
    expect(await token.testnetQualityScore(station.address)).to.equal(80n);
  });

  it("reverts when an attacker tries to set its OWN quality score (the bypass)", async function () {
    await expect(
      token.connect(attacker).updateTestnetQualityScore(attacker.address, 100)
    ).to.be.revertedWith("WRFToken: Only deployer can update quality score");
    expect(await token.testnetQualityScore(attacker.address)).to.equal(0n);
  });

  it("reverts when a registered weather station tries to set its own score", async function () {
    await expect(
      token.connect(station).updateTestnetQualityScore(station.address, 100)
    ).to.be.revertedWith("WRFToken: Only deployer can update quality score");
    expect(await token.testnetQualityScore(station.address)).to.equal(0n);
  });

  it("reverts when an attacker tries to set another address's score", async function () {
    await expect(
      token.connect(attacker).updateTestnetQualityScore(station.address, 50)
    ).to.be.revertedWith("WRFToken: Only deployer can update quality score");
  });

  it("reverts when a registered station tries to set ANOTHER station's score", async function () {
    // Closes the second bypass path in the old guard: a registered station
    // (weatherStations[msg.sender] == true) previously satisfied the `&&` and
    // could write any other station's score. Now only the deployer can.
    await token
      .connect(attacker)
      .registerWeatherStationWithStake("station-2", {
        value: await token.TESTNET_REGISTRATION_STAKE(),
      });
    await expect(
      token.connect(station).updateTestnetQualityScore(attacker.address, 99)
    ).to.be.revertedWith("WRFToken: Only deployer can update quality score");
    expect(await token.testnetQualityScore(attacker.address)).to.equal(0n);
  });

  it("still validates the 0-100 score bound for the deployer", async function () {
    await expect(
      token.connect(deployer).updateTestnetQualityScore(station.address, 101)
    ).to.be.revertedWith("WRFToken: Invalid quality score - must be <= 100");
  });

  it("prevents an attacker from inflating its own genesis airdrop via quality score", async function () {
    // Give the attacker some baseline participation so qualityBonus is non-trivial.
    await token
      .connect(attacker)
      .registerWeatherStationWithStake("attacker-station", {
        value: await token.TESTNET_REGISTRATION_STAKE(),
      });

    const before = await token.calculateGenesisAirdrop(attacker.address);

    // Attacker attempts to max its own quality score — must fail.
    await expect(
      token.connect(attacker).updateTestnetQualityScore(attacker.address, 100)
    ).to.be.revertedWith('WRFToken: Only deployer can update quality score');

    const after = await token.calculateGenesisAirdrop(attacker.address);
    expect(after).to.equal(before); // airdrop weighting unchanged
  });
});
