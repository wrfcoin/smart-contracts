const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');
const { anyValue } = require('@nomicfoundation/hardhat-chai-matchers/withArgs');

describe('SlashingController', function () {
  const OFFENSE_CODE = 'CONS-001';
  const AMOUNT = ethers.parseEther('100');
  const EVIDENCE_HASH = ethers.keccak256(ethers.toUtf8Bytes('evidence-payload-1'));

  async function deploySlashingControllerFixture() {
    const [owner, admin, target, other] = await ethers.getSigners();

    const SlashingController = await ethers.getContractFactory('SlashingController');
    const controller = await SlashingController.deploy();

    const SLASH_ADMIN_ROLE = await controller.SLASH_ADMIN_ROLE();

    // Grant admin role to the admin signer as well
    await controller.grantRole(SLASH_ADMIN_ROLE, admin.address);

    return { controller, owner, admin, target, other, SLASH_ADMIN_ROLE };
  }

  // Helper: read slashId from the most recent Slashed event.
  // The contract emits slashId as the last (non-indexed) argument so ethers
  // returns it as a plain bytes32, even though offenseCode is indexed.
  async function getLatestSlashId(controller) {
    const filter = controller.filters.Slashed();
    const events = await controller.queryFilter(filter);
    if (events.length === 0) throw new Error('No Slashed events found');
    const ev = events[events.length - 1];
    return ev.args.slashId;
  }

  describe('Slashing', function () {
    it('should create a slash record and emit Slashed event', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await expect(controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH))
        .to.emit(controller, 'Slashed')
        .withArgs(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH, anyValue);

      expect(await controller.getTotalSlashed(target.address)).to.equal(AMOUNT);
      expect(await controller.isSlashed(target.address)).to.equal(true);
    });

    it('should accumulate totalSlashed across multiple slashes', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      const ev1Hash = ethers.keccak256(ethers.toUtf8Bytes('evidence-1'));
      const ev2Hash = ethers.keccak256(ethers.toUtf8Bytes('evidence-2'));

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, ev1Hash);

      // Mine a block so the second slash has a different timestamp
      await ethers.provider.send('evm_mine', []);

      await controller.slash(target.address, 'DATA-003', AMOUNT, ev2Hash);

      const total = await controller.getTotalSlashed(target.address);
      expect(total).to.equal(AMOUNT * 2n);
    });

    it('should reject zero address target', async function () {
      const { controller } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.slash(ethers.ZeroAddress, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH)
      ).to.be.revertedWith('SlashingController: zero address');
    });

    it('should reject empty offense code', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.slash(target.address, '', AMOUNT, EVIDENCE_HASH)
      ).to.be.revertedWith('SlashingController: empty offense code');
    });

    it('should reject zero amount', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.slash(target.address, OFFENSE_CODE, 0, EVIDENCE_HASH)
      ).to.be.revertedWith('SlashingController: zero amount');
    });

    it('should reject zero evidence hash', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.slash(target.address, OFFENSE_CODE, AMOUNT, ethers.ZeroHash)
      ).to.be.revertedWith('SlashingController: zero evidence hash');
    });

    it('should reject unauthorized caller', async function () {
      const { controller, target, other } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.connect(other).slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH)
      ).to.be.revertedWithCustomError(controller, 'AccessControlUnauthorizedAccount').withArgs(other.address, await controller.SLASH_ADMIN_ROLE());
    });
  });

  describe('Slash lookup', function () {
    it('should return the slash record via getSlash', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);

      const record = await controller.getSlash(slashId);
      expect(record.target).to.equal(target.address);
      expect(record.offenseCode).to.equal(OFFENSE_CODE);
      expect(record.amount).to.equal(AMOUNT);
      expect(record.evidenceHash).to.equal(EVIDENCE_HASH);
      expect(record.reversed).to.equal(false);
      expect(record.reversedAt).to.equal(0);
      expect(record.slashedAt).to.be.gt(0);
      expect(record.blockNumber).to.be.gt(0);
    });

    it('should revert getSlash for unknown id', async function () {
      const { controller } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.getSlash(ethers.ZeroHash)
      ).to.be.revertedWith('SlashingController: slash not found');
    });
  });

  describe('Slash count', function () {
    it('should return correct total and active counts', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      const ev1Hash = ethers.keccak256(ethers.toUtf8Bytes('ev-count-1'));
      const ev2Hash = ethers.keccak256(ethers.toUtf8Bytes('ev-count-2'));

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, ev1Hash);
      await ethers.provider.send('evm_mine', []);
      await controller.slash(target.address, 'DATA-003', AMOUNT, ev2Hash);

      const [total, active] = await controller.getSlashCount();
      expect(total).to.equal(2);
      expect(active).to.equal(2);
    });
  });

  describe('Reversal', function () {
    it('should reverse a slash and update cumulative total', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);

      await expect(controller.reverseSlash(slashId))
        .to.emit(controller, 'SlashReversed')
        .withArgs(slashId, target.address, AMOUNT);

      const record = await controller.getSlash(slashId);
      expect(record.reversed).to.equal(true);
      expect(record.reversedAt).to.be.gt(0);

      expect(await controller.getTotalSlashed(target.address)).to.equal(0);
      expect(await controller.isSlashed(target.address)).to.equal(false);
    });

    it('should decrease active count after reversal', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);

      await controller.reverseSlash(slashId);

      const [total, active] = await controller.getSlashCount();
      expect(total).to.equal(1);
      expect(active).to.equal(0);
    });

    it('should reject double reversal', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);
      await controller.reverseSlash(slashId);

      await expect(
        controller.reverseSlash(slashId)
      ).to.be.revertedWith('SlashingController: already reversed');
    });

    it('should reject reversal of unknown slash id', async function () {
      const { controller } = await loadFixture(deploySlashingControllerFixture);

      await expect(
        controller.reverseSlash(ethers.ZeroHash)
      ).to.be.revertedWith('SlashingController: slash not found');
    });

    it('should reject unauthorized reversal', async function () {
      const { controller, target, other } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);

      await expect(
        controller.connect(other).reverseSlash(slashId)
      ).to.be.revertedWithCustomError(controller, 'AccessControlUnauthorizedAccount').withArgs(other.address, await controller.SLASH_ADMIN_ROLE());
    });
  });

  describe('Amount update', function () {
    it('should update slash amount and emit SlashAmountUpdated', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);

      const newAmount = ethers.parseEther('200');
      await expect(controller.updateSlashAmount(slashId, newAmount))
        .to.emit(controller, 'SlashAmountUpdated')
        .withArgs(slashId, AMOUNT, newAmount);

      const record = await controller.getSlash(slashId);
      expect(record.amount).to.equal(newAmount);
      expect(await controller.getTotalSlashed(target.address)).to.equal(newAmount);
    });

    it('should reject amount update on reversed slash', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);
      await controller.reverseSlash(slashId);

      await expect(
        controller.updateSlashAmount(slashId, ethers.parseEther('50'))
      ).to.be.revertedWith('SlashingController: already reversed');
    });

    it('should reject zero new amount', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);

      await expect(
        controller.updateSlashAmount(slashId, 0)
      ).to.be.revertedWith('SlashingController: zero amount');
    });
  });

  describe('isSlashed', function () {
    it('should return false for address with no slashes', async function () {
      const { controller, other } = await loadFixture(deploySlashingControllerFixture);
      expect(await controller.isSlashed(other.address)).to.equal(false);
    });

    it('should return false after all slashes reversed', async function () {
      const { controller, target } = await loadFixture(deploySlashingControllerFixture);

      await controller.slash(target.address, OFFENSE_CODE, AMOUNT, EVIDENCE_HASH);
      const slashId = await getLatestSlashId(controller);
      await controller.reverseSlash(slashId);

      expect(await controller.isSlashed(target.address)).to.equal(false);
    });
  });
});
