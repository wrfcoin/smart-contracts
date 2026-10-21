const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SovereignIPAuthority", function () {
  const GITHUB_RELEASE = 1;
  const MEDIA_PUBLICATION = 2;
  const assetId = ethers.id("wrfcoin-corpus-v1");
  const corpusCommitment = ethers.id("ipfs://corpus-manifest-v1");
  const keyFingerprint = ethers.id("dao-release-key-v1");
  const rotatedKeyFingerprint = ethers.id("dao-release-key-v2");

  async function deploy() {
    const [dao, human, aiAgent, outsider] = await ethers.getSigners();
    const Authority = await ethers.getContractFactory("SovereignIPAuthority");
    const authority = await Authority.deploy(dao.address);
    await authority.registerAsset(assetId, corpusCommitment, keyFingerprint);
    return { authority, dao, human, aiAgent, outsider };
  }

  it("allows equivalent DAO grants to a human and an AI address", async function () {
    const { authority, human, aiAgent } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);
    await authority.setPublicationGrant(assetId, aiAgent.address, MEDIA_PUBLICATION, expiry);

    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(true);
    expect(await authority.isAuthorized(assetId, aiAgent.address, MEDIA_PUBLICATION)).to.equal(true);
  });

  it("mutation: remove DAO publication-admin guard lets an outsider grant a release and must revert", async function () {
    const { authority, outsider, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await expect(authority.connect(outsider).setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry))
      .to.be.revertedWithCustomError(authority, 'AccessControlUnauthorizedAccount').withArgs(outsider.address, await authority.PUBLICATION_ADMIN_ROLE());
  });

  it("mutation: omit capability-bit check lets a media-only operator publish a GitHub release and must revert", async function () {
    const { authority, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, MEDIA_PUBLICATION, expiry);
    await expect(authority.requireAuthorized(assetId, human.address, GITHUB_RELEASE))
      .to.be.revertedWith("SovereignIPAuthority: operator not authorized");
  });

  it("mutation: omit revocation lets a revoked operator publish and must revert", async function () {
    const { authority, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);
    await authority.revokePublicationGrant(assetId, human.address);
    await expect(authority.requireAuthorized(assetId, human.address, GITHUB_RELEASE))
      .to.be.revertedWith("SovereignIPAuthority: operator not authorized");
  });

  it("invalidates all grants when the DAO revokes the corpus asset", async function () {
    const { authority, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);
    await authority.revokeAsset(assetId);
    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(false);
  });

  it("reactivates a revoked asset without changing assetId", async function () {
    const { authority, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);
    await authority.revokeAsset(assetId);
    await authority.reactivateAsset(assetId);
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);

    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(true);
  });

  it("invalidates previous grants when key fingerprint rotates", async function () {
    const { authority, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);
    await authority.rotateAssetKeyFingerprint(assetId, rotatedKeyFingerprint);
    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(false);
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);
    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(true);
  });

  it("treats grants as valid through the declared boundary but invalid after expiry", async function () {
    const { authority, human } = await deploy();
    const current = (await ethers.provider.getBlock("latest")).timestamp;
    const expiry = current + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);

    await time.setNextBlockTimestamp(expiry);
    await ethers.provider.send("evm_mine");
    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(true);

    await time.increase(1);
    expect(await authority.isAuthorized(assetId, human.address, GITHUB_RELEASE)).to.equal(false);
    await expect(authority.requireAuthorized(assetId, human.address, GITHUB_RELEASE))
      .to.be.revertedWith("SovereignIPAuthority: operator not authorized");
  });

  it("enforces payload-bound authorization when payload hash is provided", async function () {
    const { authority, human } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);

    expect(await authority.isAuthorizedForContent(assetId, corpusCommitment, human.address, GITHUB_RELEASE)).to.equal(true);
    expect(await authority.isAuthorizedForContent(assetId, ethers.id("ipfs://other"), human.address, GITHUB_RELEASE)).to.equal(false);
    await expect(
      authority.requireAuthorizedForContent(assetId, ethers.id("ipfs://other"), human.address, GITHUB_RELEASE),
    ).to.be.revertedWith("SovereignIPAuthority: operator not authorized for payload");
  });

  it("requires an existing grant to revoke", async function () {
    const { authority, human, outsider } = await deploy();
    const expiry = (await ethers.provider.getBlock("latest")).timestamp + 3600;
    await authority.setPublicationGrant(assetId, human.address, GITHUB_RELEASE, expiry);

    await expect(authority.revokePublicationGrant(assetId, outsider.address))
      .to.be.revertedWith("SovereignIPAuthority: unknown grant");
  });
});
