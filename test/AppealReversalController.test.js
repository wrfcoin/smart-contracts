'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
} = require('@nomicfoundation/hardhat-network-helpers');

describe('AppealReversalController', function () {
  // ── Constants ────────────────────────────────────────────────────────────

  const SLASH_ID      = ethers.keccak256(ethers.toUtf8Bytes('slash-001'));
  const SLASH_ID_2    = ethers.keccak256(ethers.toUtf8Bytes('slash-002'));
  const REASON        = 'False positive — consensus equivocation';
  const ONE_DAY       = 86400;
  const SEVEN_DAYS    = 7 * ONE_DAY;
  const THIRTY_DAYS   = 30 * ONE_DAY;

  // ── Fixture ──────────────────────────────────────────────────────────────

  async function deployFixture() {
    const [owner, admin, appellant, other] = await ethers.getSigners();

    const AppealReversalController = await ethers.getContractFactory(
      'AppealReversalController'
    );
    const controller = await AppealReversalController.deploy();

    const APPEAL_ADMIN_ROLE = await controller.APPEAL_ADMIN_ROLE();

    // Grant admin role to the dedicated admin signer
    await controller.grantRole(APPEAL_ADMIN_ROLE, admin.address);

    return { controller, owner, admin, appellant, other, APPEAL_ADMIN_ROLE };
  }

  async function deployIntegratedFixture() {
    const base = await deployFixture();

    const SlashingController = await ethers.getContractFactory('SlashingController');
    const slashController = await SlashingController.deploy();
    const ParticipationLock = await ethers.getContractFactory('ParticipationLock');
    const lockController = await ParticipationLock.deploy();

    const SLASH_ADMIN_ROLE = await slashController.SLASH_ADMIN_ROLE();
    const LOCK_ADMIN_ROLE = await lockController.LOCK_ADMIN_ROLE();

    await slashController.grantRole(SLASH_ADMIN_ROLE, await base.controller.getAddress());
    await lockController.grantRole(LOCK_ADMIN_ROLE, await base.controller.getAddress());

    await base.controller
      .connect(base.admin)
      .setAppealControllers(
        await slashController.getAddress(),
        await lockController.getAddress()
      );

    return { ...base, slashController, lockController };
  }

  // Helper: fetch the most recent AppealFiled event and return the appealId
  async function getLatestAppealId(controller) {
    const filter = controller.filters.AppealFiled();
    const events = await controller.queryFilter(filter);
    if (events.length === 0) throw new Error('No AppealFiled events found');
    return events[events.length - 1].args.appealId;
  }

  async function getLatestSlashId(controller) {
    const filter = controller.filters.Slashed();
    const events = await controller.queryFilter(filter);
    if (events.length === 0) throw new Error('No Slashed events found');
    return events[events.length - 1].args.slashId;
  }

  // ── Constructor / Access Control ─────────────────────────────────────────

  describe('Deployment', function () {
    it('sets default appeal window to 7 days', async function () {
      const { controller } = await loadFixture(deployFixture);
      expect(await controller.appealWindowDuration()).to.equal(SEVEN_DAYS);
    });

    it('grants DEFAULT_ADMIN_ROLE and APPEAL_ADMIN_ROLE to deployer', async function () {
      const { controller, owner } = await loadFixture(deployFixture);
      const DEFAULT_ADMIN_ROLE = await controller.DEFAULT_ADMIN_ROLE();
      const APPEAL_ADMIN_ROLE  = await controller.APPEAL_ADMIN_ROLE();
      expect(await controller.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.equal(true);
      expect(await controller.hasRole(APPEAL_ADMIN_ROLE,  owner.address)).to.equal(true);
    });
  });

  // ── fileAppeal ────────────────────────────────────────────────────────────

  describe('fileAppeal', function () {
    it('files an appeal and emits AppealFiled', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);

      const tx = await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const receipt = await tx.wait();
      const block   = await ethers.provider.getBlock(receipt.blockNumber);
      const expectedWindowCloses = block.timestamp + SEVEN_DAYS;

      const appealId = await getLatestAppealId(controller);
      await expect(tx)
        .to.emit(controller, 'AppealFiled')
        .withArgs(appealId, SLASH_ID, appellant.address, expectedWindowCloses);
    });

    it('stores all AppealRecord fields correctly', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);
      const record   = await controller.getAppeal(appealId);

      expect(record.slashId).to.equal(SLASH_ID);
      expect(record.appellant).to.equal(appellant.address);
      expect(record.reason).to.equal(REASON);
      expect(record.filedAt).to.be.gt(0n);
      expect(record.windowCloses).to.be.gt(record.filedAt);
      expect(record.decided).to.equal(false);
      expect(record.approved).to.equal(false);
      expect(record.decidedAt).to.equal(0n);
      expect(record.reversedAmount).to.equal(0n);
    });

    it('allows any address to file an appeal (no role required)', async function () {
      const { controller, other } = await loadFixture(deployFixture);
      // 'other' has no special role
      await expect(
        controller.connect(other).fileAppeal(SLASH_ID, REASON)
      ).to.not.be.reverted;
    });

    it('rejects zero slash id', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);
      await expect(
        controller.connect(appellant).fileAppeal(ethers.ZeroHash, REASON)
      ).to.be.revertedWith('AppealReversalController: zero slash id');
    });

    it('rejects empty reason', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);
      await expect(
        controller.connect(appellant).fileAppeal(SLASH_ID, '')
      ).to.be.revertedWith('AppealReversalController: empty reason');
    });

    it('registers the appeal under the correct slash id', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      const ids = await controller.getAppealsBySlash(SLASH_ID);
      expect(ids).to.include(appealId);
    });

    it('allows multiple distinct appeals for the same slash from the same address across blocks', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const id1 = await getLatestAppealId(controller);

      // Advance time so the keccak key differs (block.timestamp changes)
      await time.increase(60);

      await controller.connect(appellant).fileAppeal(SLASH_ID, 'second reason');
      const id2 = await getLatestAppealId(controller);

      expect(id1).to.not.equal(id2);
      const ids = await controller.getAppealsBySlash(SLASH_ID);
      expect(ids.length).to.equal(2);
    });
  });

  // ── decideAppeal ──────────────────────────────────────────────────────────

  describe('decideAppeal', function () {
    it('approves an appeal within the window and emits AppealDecided', async function () {
      const { controller, admin, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      const reversalAmount = ethers.parseEther('50');
      await expect(controller.connect(admin).decideAppeal(appealId, true, reversalAmount))
        .to.emit(controller, 'AppealDecided')
        .withArgs(appealId, true, reversalAmount);

      const record = await controller.getAppeal(appealId);
      expect(record.decided).to.equal(true);
      expect(record.approved).to.equal(true);
      expect(record.reversedAmount).to.equal(reversalAmount);
      expect(record.decidedAt).to.be.gt(0n);
    });

    it('rejects an appeal and sets reversedAmount to 0', async function () {
      const { controller, admin, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      await controller.connect(admin).decideAppeal(appealId, false, ethers.parseEther('999'));

      const record = await controller.getAppeal(appealId);
      expect(record.decided).to.equal(true);
      expect(record.approved).to.equal(false);
      expect(record.reversedAmount).to.equal(0n);
    });

    it('reverts when window has closed', async function () {
      const { controller, admin, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      // Advance past the 7-day window
      await time.increase(SEVEN_DAYS + 1);

      await expect(
        controller.connect(admin).decideAppeal(appealId, true, 0)
      ).to.be.revertedWith('AppealReversalController: window closed');
    });

    it('reverts on double decision', async function () {
      const { controller, admin, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      await controller.connect(admin).decideAppeal(appealId, true, 0);
      await expect(
        controller.connect(admin).decideAppeal(appealId, true, 0)
      ).to.be.revertedWith('AppealReversalController: already decided');
    });

    it('reverts for unknown appeal id', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      await expect(
        controller.connect(admin).decideAppeal(ethers.ZeroHash, true, 0)
      ).to.be.revertedWith('AppealReversalController: appeal not found');
    });

    it('reverts when caller lacks APPEAL_ADMIN_ROLE', async function () {
      const { controller, appellant, other } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      await expect(
        controller.connect(other).decideAppeal(appealId, true, 0)
      ).to.be.revertedWithCustomError(controller, 'AccessControlUnauthorizedAccount').withArgs(other.address, await controller.APPEAL_ADMIN_ROLE());
    });
  });

  // ── setAppealWindow ───────────────────────────────────────────────────────

  describe('setAppealWindow', function () {
    it('updates window duration and emits AppealWindowUpdated', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      const newDuration = 14 * ONE_DAY;

      await expect(controller.connect(admin).setAppealWindow(newDuration))
        .to.emit(controller, 'AppealWindowUpdated')
        .withArgs(SEVEN_DAYS, newDuration);

      expect(await controller.appealWindowDuration()).to.equal(newDuration);
    });

    it('accepts minimum duration (1 day)', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      await expect(controller.connect(admin).setAppealWindow(ONE_DAY)).to.not.be.reverted;
      expect(await controller.appealWindowDuration()).to.equal(ONE_DAY);
    });

    it('accepts maximum duration (30 days)', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      await expect(controller.connect(admin).setAppealWindow(THIRTY_DAYS)).to.not.be.reverted;
      expect(await controller.appealWindowDuration()).to.equal(THIRTY_DAYS);
    });

    it('rejects duration below 1 day', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      await expect(
        controller.connect(admin).setAppealWindow(ONE_DAY - 1)
      ).to.be.revertedWith('AppealReversalController: window too short');
    });

    it('rejects duration above 30 days', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      await expect(
        controller.connect(admin).setAppealWindow(THIRTY_DAYS + 1)
      ).to.be.revertedWith('AppealReversalController: window too long');
    });

    it('reverts when caller lacks APPEAL_ADMIN_ROLE', async function () {
      const { controller, other } = await loadFixture(deployFixture);
      await expect(
        controller.connect(other).setAppealWindow(ONE_DAY)
      ).to.be.revertedWithCustomError(controller, 'AccessControlUnauthorizedAccount').withArgs(other.address, await controller.APPEAL_ADMIN_ROLE());
    });
  });

  describe('setAppealControllers', function () {
    it('updates linked controller addresses and emits AppealControllersUpdated', async function () {
      const { controller, admin } = await loadFixture(deployFixture);
      const SlashingController = await ethers.getContractFactory('SlashingController');
      const slashController = await SlashingController.deploy();
      const ParticipationLock = await ethers.getContractFactory('ParticipationLock');
      const lockController = await ParticipationLock.deploy();

      await expect(
        controller
          .connect(admin)
          .setAppealControllers(
            await slashController.getAddress(),
            await lockController.getAddress()
          )
      )
        .to.emit(controller, 'AppealControllersUpdated')
        .withArgs(await slashController.getAddress(), await lockController.getAddress());

      expect(await controller.slashingController()).to.equal(
        await slashController.getAddress()
      );
      expect(await controller.participationLock()).to.equal(
        await lockController.getAddress()
      );
    });
  });

  // ── isWithinWindow ────────────────────────────────────────────────────────

  describe('isWithinWindow', function () {
    it('returns true immediately after filing', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      expect(await controller.isWithinWindow(appealId)).to.equal(true);
    });

    it('returns false after window expires', async function () {
      const { controller, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);

      await time.increase(SEVEN_DAYS + 1);

      expect(await controller.isWithinWindow(appealId)).to.equal(false);
    });

    it('returns false for unknown appeal id', async function () {
      const { controller } = await loadFixture(deployFixture);
      expect(await controller.isWithinWindow(ethers.ZeroHash)).to.equal(false);
    });

    it('returns false after the appeal is decided', async function () {
      const { controller, admin, appellant } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const appealId = await getLatestAppealId(controller);
      await controller.connect(admin).decideAppeal(appealId, false, 0);

      expect(await controller.isWithinWindow(appealId)).to.equal(false);
    });
  });

  // ── getAppealCount ────────────────────────────────────────────────────────

  describe('getAppealCount', function () {
    it('returns (0,0,0,0) with no appeals', async function () {
      const { controller } = await loadFixture(deployFixture);
      const [total, pending, approved, rejected] = await controller.getAppealCount();
      expect(total).to.equal(0n);
      expect(pending).to.equal(0n);
      expect(approved).to.equal(0n);
      expect(rejected).to.equal(0n);
    });

    it('tracks pending, approved, and rejected correctly', async function () {
      const { controller, admin, appellant, other } = await loadFixture(deployFixture);

      // Appeal 1 — approve
      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const id1 = await getLatestAppealId(controller);
      await controller.connect(admin).decideAppeal(id1, true, 0);

      // Appeal 2 — reject
      await time.increase(1);
      await controller.connect(appellant).fileAppeal(SLASH_ID_2, REASON);
      const id2 = await getLatestAppealId(controller);
      await controller.connect(admin).decideAppeal(id2, false, 0);

      // Appeal 3 — left pending
      await time.increase(1);
      await controller.connect(other).fileAppeal(SLASH_ID, 'pending reason');

      const [total, pending, approved, rejected] = await controller.getAppealCount();
      expect(total).to.equal(3n);
      expect(pending).to.equal(1n);
      expect(approved).to.equal(1n);
      expect(rejected).to.equal(1n);
    });
  });

  // ── getAppealsBySlash ─────────────────────────────────────────────────────

  describe('getAppealsBySlash', function () {
    it('returns empty array for slash with no appeals', async function () {
      const { controller } = await loadFixture(deployFixture);
      const ids = await controller.getAppealsBySlash(SLASH_ID);
      expect(ids.length).to.equal(0);
    });

    it('returns all appeal ids for a given slash', async function () {
      const { controller, appellant, other } = await loadFixture(deployFixture);

      await controller.connect(appellant).fileAppeal(SLASH_ID, REASON);
      const id1 = await getLatestAppealId(controller);

      await time.increase(1);
      await controller.connect(other).fileAppeal(SLASH_ID, 'another reason');
      const id2 = await getLatestAppealId(controller);

      // Different slash id — should NOT appear
      await controller.connect(appellant).fileAppeal(SLASH_ID_2, REASON);

      const ids = await controller.getAppealsBySlash(SLASH_ID);
      expect(ids.length).to.equal(2);
      expect(ids).to.include(id1);
      expect(ids).to.include(id2);
    });
  });

  describe('approved appeal execution', function () {
    it('fully reverses a slash and releases the participant lock when approved for the full amount', async function () {
      const { controller, admin, appellant, slashController, lockController } =
        await loadFixture(deployIntegratedFixture);

      const slashAmount = ethers.parseEther('80');
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('appeal-execution-1'));

      await slashController.slash(
        appellant.address,
        'CONS-001',
        slashAmount,
        evidenceHash
      );
      const slashId = await getLatestSlashId(slashController);

      await lockController.lock(appellant.address, 'lock pending appeal', ONE_DAY);
      await controller.connect(appellant).fileAppeal(slashId, REASON);
      const appealId = await getLatestAppealId(controller);

      await expect(controller.connect(admin).decideAppeal(appealId, true, slashAmount))
        .to.emit(controller, 'AppealExecutionApplied')
        .withArgs(appealId, true, true, 0);

      const slashRecord = await slashController.getSlash(slashId);
      expect(slashRecord.reversed).to.equal(true);
      expect(await slashController.getTotalSlashed(appellant.address)).to.equal(0n);
      expect(await lockController.isLocked(appellant.address)).to.equal(false);
    });

    it('applies a partial reversal by reducing the slash amount and releasing the lock', async function () {
      const { controller, admin, appellant, slashController, lockController } =
        await loadFixture(deployIntegratedFixture);

      const slashAmount = ethers.parseEther('100');
      const reversalAmount = ethers.parseEther('25');
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('appeal-execution-2'));

      await slashController.slash(
        appellant.address,
        'CONS-002',
        slashAmount,
        evidenceHash
      );
      const slashId = await getLatestSlashId(slashController);

      await lockController.lock(appellant.address, 'lock pending partial appeal', ONE_DAY);
      await controller.connect(appellant).fileAppeal(slashId, REASON);
      const appealId = await getLatestAppealId(controller);

      await expect(controller.connect(admin).decideAppeal(appealId, true, reversalAmount))
        .to.emit(controller, 'AppealExecutionApplied')
        .withArgs(appealId, true, true, slashAmount - reversalAmount);

      const slashRecord = await slashController.getSlash(slashId);
      expect(slashRecord.reversed).to.equal(false);
      expect(slashRecord.amount).to.equal(slashAmount - reversalAmount);
      expect(await slashController.getTotalSlashed(appellant.address)).to.equal(
        slashAmount - reversalAmount
      );
      expect(await lockController.isLocked(appellant.address)).to.equal(false);
    });
  });
});
