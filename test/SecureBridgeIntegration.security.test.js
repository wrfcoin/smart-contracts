// SPDX-License-Identifier: MIT
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SecureBridgeIntegration - Security Bypass Hardening", function () {
  async function deployFixture() {
    const [admin, user] = await ethers.getSigners();
    const SecureBridgeIntegration = await ethers.getContractFactory("SecureBridgeIntegration");
    const bridge = await SecureBridgeIntegration.deploy(admin.address, user.address);
    await bridge.waitForDeployment();

    return { bridge, admin, user };
  }

  it("keeps bypass permanently disabled", async function () {
    const { bridge } = await deployFixture();

    expect(await bridge.bypassSecurityForWhitelisted()).to.equal(false);

    await expect(bridge.setSecurityBypassEnabled(true)).to.be.revertedWith(
      "SecureBridge: Security bypass disabled"
    );

    expect(await bridge.bypassSecurityForWhitelisted()).to.equal(false);

    await expect(bridge.setSecurityBypassEnabled(false)).to.not.be.reverted;
    expect(await bridge.bypassSecurityForWhitelisted()).to.equal(false);
  });

  it("rejects whitelist additions and leaves user unwhitelisted", async function () {
    const { bridge, user } = await deployFixture();

    await expect(bridge.addToSecurityBypass(user.address)).to.be.revertedWith(
      "SecureBridge: Security bypass disabled"
    );

    expect(await bridge.isSecurityBypassWhitelisted(user.address)).to.equal(false);
  });

  it("keeps admin-only guard on bypass controls", async function () {
    const { bridge, user } = await deployFixture();

    await expect(
      bridge.connect(user).setSecurityBypassEnabled(false)
    )
      .to.be.revertedWithCustomError(bridge, "AccessControlUnauthorizedAccount");
  });
});
