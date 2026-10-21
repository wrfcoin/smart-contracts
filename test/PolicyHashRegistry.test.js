const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('PolicyHashRegistry', function () {
  const DOC_1 = 'compiled-policy-v1';
  const DOC_2 = 'compiled-policy-v2';
  const DOC_1_TAMPERED = 'compiled-policy-v1-tampered';

  const HASH_1 = ethers.keccak256(ethers.toUtf8Bytes(DOC_1));
  const HASH_2 = ethers.keccak256(ethers.toUtf8Bytes(DOC_2));

  async function deployFixture() {
    const [owner, anchor, other] = await ethers.getSigners();
    const PolicyHashRegistry = await ethers.getContractFactory('PolicyHashRegistry');
    const registry = await PolicyHashRegistry.deploy();
    const POLICY_ANCHOR_ROLE = await registry.POLICY_ANCHOR_ROLE();
    await registry.grantRole(POLICY_ANCHOR_ROLE, anchor.address);
    return { registry, owner, anchor, other };
  }

  async function signAnchor(registry, signer, hash, version) {
    const digest = await registry.anchorDigest(hash, version);
    return signer.signMessage(ethers.getBytes(digest));
  }

  it('anchors a policy hash with signer metadata and verifies a matching document', async function () {
    const { registry, anchor } = await loadFixture(deployFixture);
    const signature = await signAnchor(registry, anchor, HASH_1, 1);

    await expect(registry.connect(anchor).anchorPolicyHash(HASH_1, 1, signature))
      .to.emit(registry, 'PolicyHashAnchored')
      .withArgs(HASH_1, await ethers.provider.getBlockNumber() + 1, 1, anchor.address);

    const active = await registry.getActivePolicy();
    expect(active.policyHash).to.equal(HASH_1);
    expect(active.version).to.equal(1);
    expect(active.adminSigner).to.equal(anchor.address);
    expect(active.adminSignature).to.equal(signature);
    expect(await registry.verifyPolicyDocument(ethers.toUtf8Bytes(DOC_1))).to.equal(true);
    expect(
      await registry.verifyPolicyDocumentForVersion(1, ethers.toUtf8Bytes(DOC_1))
    ).to.equal(true);
  });

  it('rejects tampered documents', async function () {
    const { registry, anchor } = await loadFixture(deployFixture);
    const signature = await signAnchor(registry, anchor, HASH_1, 1);
    await registry.connect(anchor).anchorPolicyHash(HASH_1, 1, signature);

    expect(
      await registry.verifyPolicyDocument(ethers.toUtf8Bytes(DOC_1_TAMPERED))
    ).to.equal(false);
  });

  it('version upgrade replaces the active hash and preserves historical lookup', async function () {
    const { registry, anchor } = await loadFixture(deployFixture);
    const signature1 = await signAnchor(registry, anchor, HASH_1, 1);
    const signature2 = await signAnchor(registry, anchor, HASH_2, 2);

    await registry.connect(anchor).anchorPolicyHash(HASH_1, 1, signature1);
    await registry.connect(anchor).anchorPolicyHash(HASH_2, 2, signature2);

    const previous = await registry.getPolicyByVersion(1);
    const active = await registry.getActivePolicy();

    expect(previous.policyHash).to.equal(HASH_1);
    expect(previous.deactivationBlock).to.be.gt(0n);
    expect(active.policyHash).to.equal(HASH_2);
    expect(active.version).to.equal(2);
    expect(await registry.verifyPolicyDocument(ethers.toUtf8Bytes(DOC_2))).to.equal(true);
    expect(await registry.validateEnforcementReference(HASH_1)).to.equal(false);
    expect(await registry.validateEnforcementReference(HASH_2)).to.equal(true);
  });

  it('rejects invalid admin signatures', async function () {
    const { registry, anchor, other } = await loadFixture(deployFixture);
    const badSignature = await signAnchor(registry, other, HASH_1, 1);

    await expect(
      registry.connect(anchor).anchorPolicyHash(HASH_1, 1, badSignature)
    ).to.be.revertedWith('PolicyHashRegistry: invalid admin signature');
  });
});
