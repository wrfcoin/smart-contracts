// SPDX-License-Identifier: MIT
'use strict';

/**
 * #152 — a HIGH-or-above security transfer must fail closed against an EMPTY
 * validator registry.
 *
 * Before the fix, `_selectValidators` returned silently when
 * `getValidatorList()` was empty — the state every fresh deployment starts in —
 * so the transfer proceeded with no validators assigned. The existing
 * `require(activeCount > 0)` only fired when the list was non-empty but all
 * inactive.
 *
 * #222 extends the same fail-closed invariant to every advertised quorum and
 * consumes the selected set in the approval/execution path.
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, setBalance, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('SecureBridgeIntegration — #152 validator registration fail-closed', function () {
  async function deployBridgeStack() {
    const [admin, user, v1, v2, v3, v4] = await ethers.getSigners();

    const Hardening = await ethers.getContractFactory('CrossChainBridgeSecurityHardening');
    const hardening = await Hardening.connect(admin).deploy();
    await hardening.waitForDeployment();

    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.connect(admin).deploy();
    await wrfToken.waitForDeployment();

    const Bridge = await ethers.getContractFactory('NFTCrossChainBridge');
    const nftBridge = await Bridge.connect(admin).deploy(await wrfToken.getAddress());
    await nftBridge.waitForDeployment();

    const SBI = await ethers.getContractFactory('SecureBridgeIntegration');
    const sbi = await SBI.connect(admin).deploy(
      await nftBridge.getAddress(),
      await hardening.getAddress(),
    );
    await sbi.waitForDeployment();

    const Oracle = await ethers.getContractFactory('MockNFTValueOracle');
    const oracle = await Oracle.connect(admin).deploy();
    await oracle.waitForDeployment();
    await sbi.connect(admin).setNFTValueOracle(await oracle.getAddress());

    return { hardening, nftBridge, sbi, oracle, admin, user, v1, v2, v3, v4 };
  }

  async function quoteAndInitiate(sbi, oracle, user, valueWei) {
    const nftAddr = ethers.Wallet.createRandom().address;
    const now = await time.latest();
    await oracle.setQuote(nftAddr, 1, valueWei, now);
    return sbi.connect(user).initiateSecureTransfer(nftAddr, 1, 0, user.address, 'meta');
  }

  it('reverts a HIGH-security transfer when zero validators are registered', async function () {
    const { sbi, oracle, user } = await loadFixture(deployBridgeStack);

    // 25000 ether => determineSecurityLevel(value, low-risk) === HIGH.
    await expect(quoteAndInitiate(sbi, oracle, user, ethers.parseEther('25000')))
      .to.be.revertedWith(
        'SecureBridge: Transfer blocked - Insufficient active validators for high-security transfer',
      );
  });

  it('lets the same HIGH-security transfer through once its full validator strength is registered', async function () {
    const { hardening, sbi, oracle, admin, user, v1, v2, v3, v4 } =
      await loadFixture(deployBridgeStack);

    const stake = ethers.parseEther('150000');
    await setBalance(admin.address, stake * 6n);
    for (const [index, validator] of [v1, v2, v3, v4].entries()) {
      await hardening.connect(admin).registerEnhancedValidator(
        validator.address,
        stake,
        ethers.encodeBytes32String(`node-${index + 1}`),
        `https://v${index + 1}.example.com`,
        { value: stake },
      );
    }

    await expect(quoteAndInitiate(sbi, oracle, user, ethers.parseEther('25000')))
      .to.emit(sbi, 'SecureTransferInitiated');
  });

  it('fails closed for a LOW-tier transfer with an empty registry', async function () {
    const { sbi, oracle, user } = await loadFixture(deployBridgeStack);

    await expect(quoteAndInitiate(sbi, oracle, user, ethers.parseEther('1')))
      .to.be.revertedWith('SecureBridge: Insufficient active validators');
  });
});
