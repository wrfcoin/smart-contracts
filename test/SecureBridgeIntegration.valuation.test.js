'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { setBalance, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('SecureBridgeIntegration NFT valuation oracle (#151)', function () {
  async function deployFixture() {
    const [admin, user, outsider, v1, v2, v3] = await ethers.getSigners();

    const Hardening = await ethers.getContractFactory('CrossChainBridgeSecurityHardening');
    const hardening = await Hardening.connect(admin).deploy();
    await hardening.waitForDeployment();

    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.connect(admin).deploy();
    await wrfToken.waitForDeployment();

    const NFTBridge = await ethers.getContractFactory('NFTCrossChainBridge');
    const nftBridge = await NFTBridge.connect(admin).deploy(await wrfToken.getAddress());
    await nftBridge.waitForDeployment();

    const Integration = await ethers.getContractFactory('SecureBridgeIntegration');
    const integration = await Integration.connect(admin).deploy(
      await nftBridge.getAddress(),
      await hardening.getAddress(),
    );
    await integration.waitForDeployment();

    const Oracle = await ethers.getContractFactory('MockNFTValueOracle');
    const oracle = await Oracle.connect(admin).deploy();
    await oracle.waitForDeployment();

    return { admin, user, outsider, v1, v2, v3, hardening, integration, oracle };
  }

  async function registerLowTierQuorum(hardening, admin, validators) {
    const stake = ethers.parseEther('150000');
    await setBalance(admin.address, stake * 5n);
    for (let i = 0; i < validators.length; i++) {
      await hardening.connect(admin).registerEnhancedValidator(
        validators[i].address,
        stake,
        ethers.encodeBytes32String(`valuation-${i + 1}`),
        `https://valuation-${i + 1}.example.com`,
        { value: stake },
      );
    }
  }

  async function initiate(integration, user, tokenId = 1) {
    return integration.connect(user).initiateSecureTransfer(
      ethers.Wallet.createRandom().address,
      tokenId,
      0,
      user.address,
      'valuation-test',
    );
  }

  it('mutation: remove missing-oracle guard reverts rather than using the old 1 ether floor', async function () {
    const { integration, user } = await deployFixture();

    await expect(initiate(integration, user)).to.be.revertedWith(
      'SecureBridge: NFT value oracle unavailable',
    );
  });

  it('mutation: replace the oracle with an EOA reverts', async function () {
    const { integration, admin, outsider } = await deployFixture();

    await expect(integration.connect(admin).setNFTValueOracle(outsider.address)).to.be.revertedWith(
      'SecureBridge: Invalid NFT value oracle',
    );
  });

  it('mutation: let a non-admin configure the oracle reverts', async function () {
    const { integration, oracle, outsider } = await deployFixture();

    await expect(
      integration.connect(outsider).setNFTValueOracle(await oracle.getAddress()),
    ).to.be.revertedWithCustomError(integration, 'AccessControlUnauthorizedAccount');
  });

  it('accepts a configured fresh nonzero quote and stores its real value', async function () {
    const { integration, oracle, hardening, admin, user, v1, v2, v3 } = await deployFixture();
    const nft = ethers.Wallet.createRandom().address;
    const now = await time.latest();
    const value = ethers.parseEther('1');

    await integration.connect(admin).setNFTValueOracle(await oracle.getAddress());
    await registerLowTierQuorum(hardening, admin, [v1, v2, v3]);
    await oracle.setQuote(nft, 1, value, now);

    await expect(
      integration.connect(user).initiateSecureTransfer(nft, 1, 0, user.address, 'fresh-value'),
    ).to.emit(integration, 'SecureTransferInitiated');
  });

  it('mutation: accept a zero quote reverts', async function () {
    const { integration, oracle, admin, user } = await deployFixture();
    const now = await time.latest();
    await integration.connect(admin).setNFTValueOracle(await oracle.getAddress());
    await oracle.setQuote(ethers.Wallet.createRandom().address, 2, 0, now);

    await expect(initiate(integration, user, 2)).to.be.revertedWith(
      'SecureBridge: NFT value unavailable',
    );
  });

  it('mutation: accept a stale quote reverts', async function () {
    const { integration, oracle, admin, user } = await deployFixture();
    const now = await time.latest();
    const nft = ethers.Wallet.createRandom().address;
    await integration.connect(admin).setNFTValueOracle(await oracle.getAddress());
    await oracle.setQuote(nft, 3, ethers.parseEther('2'), now - 3601);

    await expect(
      integration.connect(user).initiateSecureTransfer(nft, 3, 0, user.address, 'stale-value'),
    ).to.be.revertedWith('SecureBridge: NFT value stale');
  });

  it('mutation: accept a future-dated quote reverts', async function () {
    const { integration, oracle, admin, user } = await deployFixture();
    const now = await time.latest();
    const nft = ethers.Wallet.createRandom().address;
    await integration.connect(admin).setNFTValueOracle(await oracle.getAddress());
    await oracle.setQuote(nft, 4, ethers.parseEther('2'), now + 3600);

    await expect(
      integration.connect(user).initiateSecureTransfer(nft, 4, 0, user.address, 'future-value'),
    ).to.be.revertedWith('SecureBridge: NFT value timestamp invalid');
  });

  it('mutation: ignore an oracle revert reverts', async function () {
    const { integration, oracle, admin, user } = await deployFixture();
    await integration.connect(admin).setNFTValueOracle(await oracle.getAddress());
    await oracle.setShouldRevert(true);

    await expect(initiate(integration, user, 5)).to.be.revertedWith(
      'SecureBridge: NFT value oracle failed',
    );
  });
});
