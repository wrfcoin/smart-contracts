const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
} = require('@nomicfoundation/hardhat-network-helpers');

describe('ParticipationLock', function () {
  const ONE_DAY = 86400; // seconds
  const ONE_HOUR = 3600;
  const REASON = 'Consensus downtime violation';

  async function deployParticipationLockFixture() {
    const [owner, admin, target, other] = await ethers.getSigners();

    const ParticipationLock = await ethers.getContractFactory('ParticipationLock');
    const locker = await ParticipationLock.deploy();

    const LOCK_ADMIN_ROLE = await locker.LOCK_ADMIN_ROLE();

    // Grant admin role to the admin signer as well
    await locker.grantRole(LOCK_ADMIN_ROLE, admin.address);

    return { locker, owner, admin, target, other, LOCK_ADMIN_ROLE };
  }

  describe('Lock', function () {
    it('should lock a participant and emit ParticipantLocked', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      const now = await time.latest();
      const expectedExpiry = now + ONE_DAY + 1; // +1 for block advance

      await expect(locker.lock(target.address, REASON, ONE_DAY))
        .to.emit(locker, 'ParticipantLocked');

      expect(await locker.isLocked(target.address)).to.equal(true);

      const record = await locker.getLock(target.address);
      expect(record.target).to.equal(target.address);
      expect(record.reason).to.equal(REASON);
      expect(record.lockedAt).to.be.gt(0);
      expect(record.expiresAt).to.be.gte(expectedExpiry - 2);
      expect(record.releasedEarly).to.equal(false);
      expect(record.releasedAt).to.equal(0);
    });

    it('should increment lockCount on each lock', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      expect(await locker.getLockCount(target.address)).to.equal(0);

      await locker.lock(target.address, REASON, ONE_DAY);
      expect(await locker.getLockCount(target.address)).to.equal(1);

      // Let the first lock expire naturally
      await time.increase(ONE_DAY + 1);

      await locker.lock(target.address, 'Second violation', ONE_HOUR);
      expect(await locker.getLockCount(target.address)).to.equal(2);
    });

    it('should reject zero address target', async function () {
      const { locker } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.lock(ethers.ZeroAddress, REASON, ONE_DAY)
      ).to.be.revertedWith('ParticipationLock: zero address');
    });

    it('should reject empty reason', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.lock(target.address, '', ONE_DAY)
      ).to.be.revertedWith('ParticipationLock: empty reason');
    });

    it('should reject zero duration', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.lock(target.address, REASON, 0)
      ).to.be.revertedWith('ParticipationLock: zero duration');
    });

    it('should reject locking an already active lock', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);

      await expect(
        locker.lock(target.address, 'Second lock', ONE_HOUR)
      ).to.be.revertedWith('ParticipationLock: already locked');
    });

    it('should reject unauthorized caller', async function () {
      const { locker, target, other } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.connect(other).lock(target.address, REASON, ONE_DAY)
      ).to.be.revertedWithCustomError(locker, 'AccessControlUnauthorizedAccount').withArgs(other.address, await locker.LOCK_ADMIN_ROLE());
    });
  });

  describe('Unlock (early release)', function () {
    it('should unlock a participant early and emit ParticipantUnlocked', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);

      await expect(locker.unlock(target.address))
        .to.emit(locker, 'ParticipantUnlocked')
        .withArgs(target.address, true);

      expect(await locker.isLocked(target.address)).to.equal(false);

      const record = await locker.getLock(target.address);
      expect(record.releasedEarly).to.equal(true);
      expect(record.releasedAt).to.be.gt(0);
    });

    it('should reject unlock when no lock exists', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.unlock(target.address)
      ).to.be.revertedWith('ParticipationLock: no lock found');
    });

    it('should reject double unlock', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);
      await locker.unlock(target.address);

      await expect(
        locker.unlock(target.address)
      ).to.be.revertedWith('ParticipationLock: already released');
    });

    it('should reject unlock after natural expiry', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      await time.increase(ONE_HOUR + 1);

      await expect(
        locker.unlock(target.address)
      ).to.be.revertedWith('ParticipationLock: already expired');
    });

    it('should reject unauthorized unlock', async function () {
      const { locker, target, other } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);

      await expect(
        locker.connect(other).unlock(target.address)
      ).to.be.revertedWithCustomError(locker, 'AccessControlUnauthorizedAccount').withArgs(other.address, await locker.LOCK_ADMIN_ROLE());
    });
  });

  describe('Expiry behavior', function () {
    it('should return false from isLocked after natural expiry', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      expect(await locker.isLocked(target.address)).to.equal(true);

      await time.increase(ONE_HOUR + 1);
      expect(await locker.isLocked(target.address)).to.equal(false);
      expect(await locker.canReleaseExpiredLock(target.address)).to.equal(true);
    });

    it('should finalize an expired lock and emit ParticipantUnlocked with early=false', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      await time.increase(ONE_HOUR + 1);

      await expect(locker.releaseExpiredLock(target.address))
        .to.emit(locker, 'ParticipantUnlocked')
        .withArgs(target.address, false);

      const record = await locker.getLock(target.address);
      expect(record.releasedEarly).to.equal(true);
      expect(record.releasedAt).to.be.gt(0);
      expect(await locker.canReleaseExpiredLock(target.address)).to.equal(false);
    });

    it('should reject releaseExpiredLock before expiry', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);

      await expect(
        locker.releaseExpiredLock(target.address)
      ).to.be.revertedWith('ParticipationLock: not expired');
    });

    it('should reject replaying releaseExpiredLock after finalization', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      await time.increase(ONE_HOUR + 1);
      await locker.releaseExpiredLock(target.address);

      await expect(
        locker.releaseExpiredLock(target.address)
      ).to.be.revertedWith('ParticipationLock: already released');
    });

    it('should allow re-lock after natural expiry', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      await time.increase(ONE_HOUR + 1);

      // Should succeed without revert
      await locker.lock(target.address, 'Re-lock after expiry', ONE_HOUR);
      expect(await locker.isLocked(target.address)).to.equal(true);
      expect(await locker.getLockCount(target.address)).to.equal(2);
    });

    it('should allow re-lock after early release', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);
      await locker.unlock(target.address);

      await locker.lock(target.address, 'Re-lock after early release', ONE_HOUR);
      expect(await locker.isLocked(target.address)).to.equal(true);
      expect(await locker.getLockCount(target.address)).to.equal(2);
    });
  });

  describe('ExtendLock', function () {
    it('should extend an active lock and emit LockExtended', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      const before = await locker.getLock(target.address);

      await expect(locker.extendLock(target.address, ONE_DAY))
        .to.emit(locker, 'LockExtended')
        .withArgs(target.address, before.expiresAt + BigInt(ONE_DAY));

      const after = await locker.getLock(target.address);
      expect(after.expiresAt).to.equal(before.expiresAt + BigInt(ONE_DAY));
    });

    it('should reject extend when no lock exists', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.extendLock(target.address, ONE_HOUR)
      ).to.be.revertedWith('ParticipationLock: no lock found');
    });

    it('should reject extend after early release', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);
      await locker.unlock(target.address);

      await expect(
        locker.extendLock(target.address, ONE_HOUR)
      ).to.be.revertedWith('ParticipationLock: already released');
    });

    it('should reject extend after natural expiry', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_HOUR);
      await time.increase(ONE_HOUR + 1);

      await expect(
        locker.extendLock(target.address, ONE_HOUR)
      ).to.be.revertedWith('ParticipationLock: already expired');
    });

    it('should reject extend with zero duration', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);

      await expect(
        locker.extendLock(target.address, 0)
      ).to.be.revertedWith('ParticipationLock: zero duration');
    });

    it('should reject unauthorized extend', async function () {
      const { locker, target, other } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);

      await expect(
        locker.connect(other).extendLock(target.address, ONE_HOUR)
      ).to.be.revertedWithCustomError(locker, 'AccessControlUnauthorizedAccount').withArgs(other.address, await locker.LOCK_ADMIN_ROLE());
    });
  });

  describe('getLock', function () {
    it('should revert for address that was never locked', async function () {
      const { locker, other } = await loadFixture(deployParticipationLockFixture);

      await expect(
        locker.getLock(other.address)
      ).to.be.revertedWith('ParticipationLock: no lock found');
    });
  });

  describe('getLockCount', function () {
    it('should return zero for unlocked address', async function () {
      const { locker, other } = await loadFixture(deployParticipationLockFixture);
      expect(await locker.getLockCount(other.address)).to.equal(0);
    });
  });

  describe('canReleaseExpiredLock', function () {
    it('should return false for an address that was never locked', async function () {
      const { locker, other } = await loadFixture(deployParticipationLockFixture);
      expect(await locker.canReleaseExpiredLock(other.address)).to.equal(false);
    });

    it('should return false after early unlock', async function () {
      const { locker, target } = await loadFixture(deployParticipationLockFixture);

      await locker.lock(target.address, REASON, ONE_DAY);
      await locker.unlock(target.address);

      expect(await locker.canReleaseExpiredLock(target.address)).to.equal(false);
    });
  });
});
