const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('NFTCrossChainBridge — NFT Valuation (#50)', function () {
  async function deployFixture() {
    const [owner, admin, user, attacker] = await ethers.getSigners();

    const FixedNFTValuation = await ethers.getContractFactory('FixedNFTValuation');
    const valuation = await FixedNFTValuation.deploy(admin.address);

    return { valuation, owner, admin, user, attacker };
  }

  describe('FixedNFTValuation', function () {
    it('admin can set collection floor value', async function () {
      const { valuation, admin } = await deployFixture();
      const collection = ethers.Wallet.createRandom().address;

      await valuation.connect(admin).setCollectionFloorValue(collection, ethers.parseEther('10'));
      expect(await valuation.collectionFloorValues(collection)).to.equal(ethers.parseEther('10'));
    });

    it('returns floor value regardless of tokenId', async function () {
      const { valuation, admin } = await deployFixture();
      const collection = ethers.Wallet.createRandom().address;
      const floor = ethers.parseEther('5');

      await valuation.connect(admin).setCollectionFloorValue(collection, floor);

      // tokenId should not affect the value
      expect(await valuation.getNFTValue(collection, 0)).to.equal(floor);
      expect(await valuation.getNFTValue(collection, 999)).to.equal(floor);
      expect(await valuation.getNFTValue(collection, 1000)).to.equal(floor);
      expect(await valuation.getNFTValue(collection, 123456)).to.equal(floor);
    });

    it('reverts for unconfigured collection', async function () {
      const { valuation } = await deployFixture();
      const unconfigured = ethers.Wallet.createRandom().address;

      await expect(valuation.getNFTValue(unconfigured, 1))
        .to.be.revertedWith('FixedNFTValuation: collection not configured');
    });

    it('non-admin cannot set floor value', async function () {
      const { valuation, attacker } = await deployFixture();
      const collection = ethers.Wallet.createRandom().address;

      await expect(
        valuation.connect(attacker).setCollectionFloorValue(collection, ethers.parseEther('1'))
      ).to.be.revertedWithCustomError(valuation, 'AccessControlUnauthorizedAccount').withArgs(attacker.address, await valuation.VALUATION_ADMIN_ROLE());
    });

    it('rejects zero address collection', async function () {
      const { valuation, admin } = await deployFixture();

      await expect(
        valuation.connect(admin).setCollectionFloorValue(ethers.ZeroAddress, ethers.parseEther('1'))
      ).to.be.revertedWith('FixedNFTValuation: zero address');
    });

    it('emits CollectionFloorValueSet event', async function () {
      const { valuation, admin } = await deployFixture();
      const collection = ethers.Wallet.createRandom().address;
      const floor = ethers.parseEther('42');

      await expect(valuation.connect(admin).setCollectionFloorValue(collection, floor))
        .to.emit(valuation, 'CollectionFloorValueSet')
        .withArgs(collection, floor);
    });
  });
});
