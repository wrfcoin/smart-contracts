'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('EnhancedCarbonCredits — focused coverage', function () {
  async function deployFixture() {
    const [admin, issuer, connector, outsider, beneficiary] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const wrfToken = await MockERC20.deploy('WRF', 'WRF', 18);

    const mintAmount = 1_000_000n * 10n ** 18n;
    await wrfToken.mint(admin.address, mintAmount);
    await wrfToken.mint(issuer.address, mintAmount);
    await wrfToken.mint(beneficiary.address, mintAmount);

    const EnhancedCarbonCredits = await ethers.getContractFactory('EnhancedCarbonCredits');
    const credits = await EnhancedCarbonCredits.deploy(await wrfToken.getAddress());

    return {
      admin,
      issuer,
      connector,
      outsider,
      beneficiary,
      wrfToken,
      credits,
    };
  }

  async function createBatchFixture(credits, creator, projectId = 'project-1', certHash = 'cert-1') {
    const block = await ethers.provider.getBlock('latest');
    const expiryDate = BigInt(block.timestamp) + 24n * 60n * 60n;
    const params = {
      totalSupplyKg: ethers.parseEther('1000'),
      projectId,
      vintage: 2025n,
      methodology: 'VM0006',
      projectType: 'renewable-energy',
      registryStandard: 'VCS',
      location: 'US-WA',
      expiryDate,
      certificationHash: certHash,
      registryUrl: 'https://metadata.invalid/enhanced',
      metadataUri: '',
    };
    const tx = await credits.connect(creator).createBatch(params);
    const receipt = await tx.wait();
    return {
      tokenId: 1n,
      receipt,
      params,
    };
  }

  it('requires issuer role and enforces issuance identifier uniqueness', async function () {
    const { admin, issuer, outsider, credits } = await loadFixture(deployFixture);

    const issuerRole = await credits.AUTHORIZED_ISSUER_ROLE();
    const block = await ethers.provider.getBlock('latest');
    const expiryDate = BigInt(block.timestamp) + 24n * 60n * 60n;

    const validBatch = {
      totalSupplyKg: ethers.parseEther('1000'),
      projectId: 'project-1',
      vintage: 2025n,
      methodology: 'VM0006',
      projectType: 'renewable-energy',
      registryStandard: 'VCS',
      location: 'US-WA',
      expiryDate,
      certificationHash: 'cert-1',
      registryUrl: 'https://metadata.invalid/enhanced',
      metadataUri: '',
    };

    // onlyRole(AUTHORIZED_ISSUER_ROLE) — EnhancedCarbonCredits.sol:160. The batch is
    // the VALID one (the invalid-supply case is asserted separately below), so every
    // body require would pass and only the role gate can reject this.
    await expect(
      credits.connect(outsider).createBatch(validBatch)
    )
      .to.be.revertedWithCustomError(credits, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await credits.AUTHORIZED_ISSUER_ROLE());

    await credits.connect(admin).grantRole(issuerRole, issuer.address);
    await credits.connect(issuer).createBatch(validBatch);

    await expect(
      credits.connect(issuer).createBatch({
        totalSupplyKg: ethers.parseEther('2000'),
        projectId: 'project-1',
        vintage: 2025n,
        methodology: 'VM0006',
        projectType: 'forestry',
        registryStandard: 'VCS',
        location: 'US-WA',
        expiryDate: expiryDate + 8000n,
        certificationHash: 'cert-alt',
        registryUrl: 'https://metadata.invalid/enhanced',
        metadataUri: '',
      })
    ).to.be.revertedWith('EnhancedCarbonCredits: Project already tokenized');

    const duplicateCert = {
      totalSupplyKg: ethers.parseEther('1500'),
      projectId: 'project-2',
      vintage: 2026n,
      methodology: 'VM0006',
      projectType: 'forestry',
      registryStandard: 'VCS',
      location: 'US-WA',
      expiryDate: expiryDate + 3600n,
      certificationHash: 'cert-1',
      registryUrl: 'https://metadata.invalid/enhanced',
      metadataUri: '',
    };
    await expect(
      credits.connect(issuer).createBatch(duplicateCert)
    ).to.be.revertedWith('EnhancedCarbonCredits: Hash already used');

    const invalidSupply = {
      totalSupplyKg: 0n,
      projectId: 'project-3',
      vintage: 2025n,
      methodology: 'VM0006',
      projectType: 'renewable-energy',
      registryStandard: 'VCS',
      location: 'US-WA',
      expiryDate: expiryDate + 7200n,
      certificationHash: 'cert-3',
      registryUrl: 'https://metadata.invalid/enhanced',
      metadataUri: '',
    };
    await expect(
      credits.connect(issuer).createBatch(invalidSupply)
    ).to.be.revertedWith('EnhancedCarbonCredits: Invalid supply');
  });

  it('guards immobilization with token-id validity and connector role', async function () {
    const { admin, issuer, connector, beneficiary, credits } = await loadFixture(deployFixture);

    const issuerRole = await credits.AUTHORIZED_ISSUER_ROLE();
    await credits.connect(admin).grantRole(issuerRole, issuer.address);
    const { tokenId } = await createBatchFixture(credits, issuer);

    const outlierTokenId = tokenId + 1n;
    // NAMING TRAP: the signer is called `connector`, but it does NOT hold
    // REGISTRY_CONNECTOR_ROLE — the fixture never grants it, which is why the very
    // next assertion has `admin` succeed on the identical call. immobilizeCredits is
    // onlyRole(REGISTRY_CONNECTOR_ROLE) validTokenId(tokenId) (:220-224); tokenId is
    // the batch just created, so validTokenId passes and the role gate is the only
    // rejection. Pinning the role records that the signer's name is not its authority.
    await expect(
      credits.connect(connector).immobilizeCredits(tokenId, 1n, beneficiary.address)
    )
      .to.be.revertedWithCustomError(credits, 'AccessControlUnauthorizedAccount')
      .withArgs(connector.address, await credits.REGISTRY_CONNECTOR_ROLE());

    await expect(
      credits.connect(admin).immobilizeCredits(tokenId, 1n, beneficiary.address)
    ).to.not.be.reverted;

    await expect(
      credits.connect(admin).immobilizeCredits(outlierTokenId, 1n, beneficiary.address)
    ).to.be.revertedWith('EnhancedCarbonCredits: Invalid token ID');

    await expect(
      credits.connect(admin).immobilizeCredits(tokenId, ethers.parseEther('1001'), beneficiary.address)
    ).to.be.revertedWith('EnhancedCarbonCredits: Exceeds total supply');
  });

  it('pauses sensitive paths and enforces pause permissions', async function () {
    const { admin, issuer, outsider, beneficiary, credits } = await loadFixture(deployFixture);

    // onlyRole(PAUSER_ROLE) — EnhancedCarbonCredits.sol:400. A THIRD distinct role in
    // this one file, alongside AUTHORIZED_ISSUER_ROLE and REGISTRY_CONNECTOR_ROLE.
    await expect(
      credits.connect(outsider).pause()
    )
      .to.be.revertedWithCustomError(credits, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await credits.PAUSER_ROLE());

    const issuerRole = await credits.AUTHORIZED_ISSUER_ROLE();
    await credits.connect(admin).grantRole(issuerRole, issuer.address);
    const { tokenId } = await createBatchFixture(credits, issuer, 'pause-project', 'pause-cert');

    const registryConnectorRole = await credits.REGISTRY_CONNECTOR_ROLE();
    await credits.connect(admin).grantRole(registryConnectorRole, admin.address);
    await credits.connect(admin).immobilizeCredits(tokenId, 1n, beneficiary.address);

    await credits.connect(admin).pause();
    await expect(
      credits.connect(beneficiary).retireCredits(tokenId, 1n, 'retirement during pause')
    ).to.be.revertedWithCustomError(credits, 'EnforcedPause');

    await credits.connect(admin).unpause();
    await credits.connect(beneficiary).retireCredits(tokenId, 1n, 'retire after pause');
    expect(await credits.balanceOf(beneficiary.address, tokenId)).to.equal(0n);
  });

  it('protects balance/amount constraints and batch liveness for retirement', async function () {
    const { admin, issuer, beneficiary, wrfToken, credits } = await loadFixture(deployFixture);
    const issuerRole = await credits.AUTHORIZED_ISSUER_ROLE();
    await credits.connect(admin).grantRole(issuerRole, issuer.address);
    const { tokenId } = await createBatchFixture(credits, issuer, 'retire-project', 'retire-cert');

    await credits.connect(admin).immobilizeCredits(tokenId, 1_000n, beneficiary.address);
    await wrfToken.connect(beneficiary).approve(await credits.getAddress(), ethers.parseEther('1000'));
    await expect(
      credits.connect(beneficiary).retireCredits(tokenId, 0n, 'zero retire')
    ).to.be.revertedWith('EnhancedCarbonCredits: Invalid amount');

    await expect(
      credits.connect(beneficiary).retireCredits(tokenId, 2_000n, 'too much')
    ).to.be.revertedWith('EnhancedCarbonCredits: Insufficient balance');
  });

  it('enforces admin-only withdrawals and batch status controls', async function () {
    const { admin, outsider, issuer, beneficiary, credits } = await loadFixture(deployFixture);

    const issuerRole = await credits.AUTHORIZED_ISSUER_ROLE();
    await credits.connect(admin).grantRole(issuerRole, issuer.address);
    const { tokenId } = await createBatchFixture(credits, issuer, 'withdraw-project', 'withdraw-cert');

    await expect(
      credits.connect(outsider).withdrawFees(beneficiary.address, 1n)
    ).to.be.revertedWithCustomError(credits, 'AccessControlUnauthorizedAccount');

    await credits.connect(admin).immobilizeCredits(tokenId, 500n, beneficiary.address);

    await credits.connect(admin).setBatchStatus(tokenId, false);
    await expect(
      credits.connect(beneficiary).retireCredits(tokenId, 1n, 'retirement paused batch')
    ).to.be.revertedWith('EnhancedCarbonCredits: Batch not active');
  });
});
