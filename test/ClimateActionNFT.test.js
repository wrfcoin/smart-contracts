const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('ClimateActionNFT', function () {
  let nft, owner, oracle, minter, verifier, contributor, other;
  const OFFSET_KG   = 1_000n;          // 1 000 kg (Silver tier)
  const VINTAGE     = 2025;
  const READINGS    = 500;

  beforeEach(async function () {
    [owner, oracle, minter, verifier, contributor, other] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory('ClimateActionNFT');
    nft = await Factory.deploy(oracle.address, minter.address);
    await nft.waitForDeployment();

    // Grant verifier role
    await nft.connect(owner).grantVerifierRole(verifier.address);
  });

  // -------------------------------------------------------------------------
  // Minting
  // -------------------------------------------------------------------------
  describe('mint', function () {
    it('mints a token with correct record', async function () {
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
      const rec = await nft.carbonRecords(1n);
      expect(rec.offsetKg).to.equal(OFFSET_KG);
      expect(rec.vintageYear).to.equal(VINTAGE);
      expect(rec.readingsCount).to.equal(READINGS);
      expect(rec.verified).to.be.false;
      expect(rec.retired).to.be.false;
    });

    it('emits ClimateNFTMinted', async function () {
      await expect(nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS))
        .to.emit(nft, 'ClimateNFTMinted')
        .withArgs(contributor.address, 1n, OFFSET_KG, VINTAGE, READINGS);
    });

    it('reverts for zero address', async function () {
      await expect(nft.connect(minter).mint(ethers.ZeroAddress, OFFSET_KG, VINTAGE, READINGS))
        .to.be.revertedWithCustomError(nft, 'ZeroAddress');
    });

    it('reverts for zero offset', async function () {
      await expect(nft.connect(minter).mint(contributor.address, 0n, VINTAGE, READINGS))
        .to.be.revertedWithCustomError(nft, 'ZeroOffset');
    });

    it('reverts for invalid vintage year', async function () {
      await expect(nft.connect(minter).mint(contributor.address, OFFSET_KG, 2015, READINGS))
        .to.be.revertedWithCustomError(nft, 'InvalidYear');
    });

    it('reverts when called by non-minter', async function () {
      await expect(nft.connect(other).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS))
        .to.be.revertedWithCustomError(nft, 'AccessControlUnauthorizedAccount').withArgs(other.address, await nft.MINTER_ROLE());
    });
  });

  // -------------------------------------------------------------------------
  // Tiers
  // -------------------------------------------------------------------------
  describe('tierOf', function () {
    it('returns Bronze below 500 kg', async function () {
      await nft.connect(minter).mint(contributor.address, 100n, VINTAGE, READINGS);
      expect(await nft.tierOf(1n)).to.equal(0n); // Bronze
    });

    it('returns Silver 500–1 999 kg', async function () {
      await nft.connect(minter).mint(contributor.address, 500n, VINTAGE, READINGS);
      expect(await nft.tierOf(1n)).to.equal(1n); // Silver
    });

    it('returns Gold 2 000–4 999 kg', async function () {
      await nft.connect(minter).mint(contributor.address, 2000n, VINTAGE, READINGS);
      expect(await nft.tierOf(1n)).to.equal(2n); // Gold
    });

    it('returns Diamond at 5 000 kg+', async function () {
      await nft.connect(minter).mint(contributor.address, 5000n, VINTAGE, READINGS);
      expect(await nft.tierOf(1n)).to.equal(3n); // Diamond
    });
  });

  // -------------------------------------------------------------------------
  // Oracle: updateOffset
  // -------------------------------------------------------------------------
  describe('updateOffset', function () {
    beforeEach(async function () {
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
    });

    it('updates offset and readings', async function () {
      await nft.connect(oracle).updateOffset(1n, 3000n, 900);
      const rec = await nft.carbonRecords(1n);
      expect(rec.offsetKg).to.equal(3000n);
      expect(rec.readingsCount).to.equal(900);
    });

    it('emits OffsetUpdated', async function () {
      await expect(nft.connect(oracle).updateOffset(1n, 3000n, 900))
        .to.emit(nft, 'OffsetUpdated').withArgs(1n, 3000n, 900);
    });

    it('reverts for non-oracle', async function () {
      await expect(nft.connect(other).updateOffset(1n, 3000n, 900)).to.be.revertedWithCustomError(nft, 'AccessControlUnauthorizedAccount').withArgs(other.address, await nft.ORACLE_ROLE());
    });

    it('reverts with zero offset', async function () {
      await expect(nft.connect(oracle).updateOffset(1n, 0n, 900))
        .to.be.revertedWithCustomError(nft, 'ZeroOffset');
    });
  });

  // -------------------------------------------------------------------------
  // Verification
  // -------------------------------------------------------------------------
  describe('verify', function () {
    beforeEach(async function () {
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
    });

    it('sets verified flag', async function () {
      await nft.connect(verifier).verify(1n);
      const rec = await nft.carbonRecords(1n);
      expect(rec.verified).to.be.true;
    });

    it('emits RecordVerified', async function () {
      await expect(nft.connect(verifier).verify(1n))
        .to.emit(nft, 'RecordVerified').withArgs(1n, verifier.address);
    });

    it('reverts on double-verify', async function () {
      await nft.connect(verifier).verify(1n);
      await expect(nft.connect(verifier).verify(1n))
        .to.be.revertedWithCustomError(nft, 'AlreadyVerified');
    });

    it('reverts for non-verifier', async function () {
      await expect(nft.connect(other).verify(1n)).to.be.revertedWithCustomError(nft, 'AccessControlUnauthorizedAccount').withArgs(other.address, await nft.VERIFIER_ROLE());
    });
  });

  // -------------------------------------------------------------------------
  // Retirement
  // -------------------------------------------------------------------------
  describe('retire', function () {
    beforeEach(async function () {
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
    });

    it('burns the token and sets retired flag', async function () {
      await nft.connect(contributor).retire(1n);
      const rec = await nft.carbonRecords(1n);
      expect(rec.retired).to.be.true;
      await expect(nft.ownerOf(1n)).to.be.revertedWithCustomError(nft, 'ERC721NonexistentToken').withArgs(1n); // burned
    });

    it('emits RecordRetired', async function () {
      await expect(nft.connect(contributor).retire(1n))
        .to.emit(nft, 'RecordRetired').withArgs(1n, contributor.address);
    });

    it('reverts for non-owner', async function () {
      await expect(nft.connect(other).retire(1n))
        .to.be.revertedWithCustomError(nft, 'NotTokenOwner');
    });

    it('reverts on double-retire attempt (token burned)', async function () {
      await nft.connect(contributor).retire(1n);
      // Token is burned, ownerOf reverts, retire should revert too
      await expect(nft.connect(contributor).retire(1n)).to.be.revertedWithCustomError(nft, 'ERC721NonexistentToken').withArgs(1n);
    });
  });

  // -------------------------------------------------------------------------
  // Metadata (smoke test: tokenURI must be non-empty base64 JSON)
  // -------------------------------------------------------------------------
  describe('tokenURI', function () {
    it('returns a data URI with base64 JSON', async function () {
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
      const uri = await nft.tokenURI(1n);
      expect(uri).to.match(/^data:application\/json;base64,/);
    });
  });

  // -------------------------------------------------------------------------
  // totalSupply
  // -------------------------------------------------------------------------
  describe('totalSupply', function () {
    it('increments on each mint', async function () {
      expect(await nft.totalSupply()).to.equal(0n);
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
      expect(await nft.totalSupply()).to.equal(1n);
      await nft.connect(minter).mint(contributor.address, OFFSET_KG, VINTAGE, READINGS);
      expect(await nft.totalSupply()).to.equal(2n);
    });
  });
});
