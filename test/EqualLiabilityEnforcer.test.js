'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('EqualLiabilityEnforcer', function () {
  // ── Constants ────────────────────────────────────────────────────────────

  const OFFENSE_CODE = 'CONS-001';
  const SEVERITY = 3;
  const SLASH_AMOUNT = ethers.parseEther('500');
  const LOCK_DURATION = 86400n; // 1 day in seconds

  // ActorClass enum values (must match the Solidity enum order)
  const ActorClass = { Human: 0, AI: 1, Robot: 2 };

  // ── Fixture ──────────────────────────────────────────────────────────────

  async function deployEqualLiabilityEnforcerFixture() {
    const [owner, enforcer, governor, other] = await ethers.getSigners();

    const EqualLiabilityEnforcer = await ethers.getContractFactory(
      'EqualLiabilityEnforcer'
    );
    const enforcer_contract = await EqualLiabilityEnforcer.deploy();

    const ENFORCER_ROLE = await enforcer_contract.ENFORCER_ROLE();
    const GOVERNANCE_OVERRIDE_ROLE =
      await enforcer_contract.GOVERNANCE_OVERRIDE_ROLE();

    // Grant ENFORCER_ROLE to the dedicated enforcer signer
    await enforcer_contract.grantRole(ENFORCER_ROLE, enforcer.address);
    await enforcer_contract.grantRole(GOVERNANCE_OVERRIDE_ROLE, governor.address);

    return {
      enforcer_contract,
      owner,
      enforcer,
      governor,
      other,
      ENFORCER_ROLE,
      GOVERNANCE_OVERRIDE_ROLE,
    };
  }

  // Helper: deploy with a schedule already registered
  async function deployWithScheduleFixture() {
    const base = await deployEqualLiabilityEnforcerFixture();
    await base.enforcer_contract.registerSchedule(
      OFFENSE_CODE,
      SEVERITY,
      SLASH_AMOUNT,
      LOCK_DURATION
    );
    return base;
  }

  // ── Access Control ───────────────────────────────────────────────────────

  describe('Access control', function () {
    it('constructor grants DEFAULT_ADMIN_ROLE and ENFORCER_ROLE to deployer', async function () {
      const { enforcer_contract, owner } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      const DEFAULT_ADMIN_ROLE = await enforcer_contract.DEFAULT_ADMIN_ROLE();
      const ENFORCER_ROLE = await enforcer_contract.ENFORCER_ROLE();
      const GOVERNANCE_OVERRIDE_ROLE =
        await enforcer_contract.GOVERNANCE_OVERRIDE_ROLE();

      expect(
        await enforcer_contract.hasRole(DEFAULT_ADMIN_ROLE, owner.address)
      ).to.equal(true);
      expect(
        await enforcer_contract.hasRole(ENFORCER_ROLE, owner.address)
      ).to.equal(true);
      expect(
        await enforcer_contract.hasRole(GOVERNANCE_OVERRIDE_ROLE, owner.address)
      ).to.equal(true);
    });

    it('rejects registerSchedule from unauthorized caller', async function () {
      const { enforcer_contract, other } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract
          .connect(other)
          .registerSchedule(OFFENSE_CODE, SEVERITY, SLASH_AMOUNT, LOCK_DURATION)
      ).to.be.revertedWithCustomError(enforcer_contract, 'AccessControlUnauthorizedAccount').withArgs(other.address, await enforcer_contract.ENFORCER_ROLE());
    });

    it('rejects updateSchedule from unauthorized caller', async function () {
      const { enforcer_contract, other } = await loadFixture(
        deployWithScheduleFixture
      );

      await expect(
        enforcer_contract
          .connect(other)
          .updateSchedule(OFFENSE_CODE, 2, ethers.parseEther('250'), 3600n)
      ).to.be.revertedWithCustomError(enforcer_contract, 'AccessControlUnauthorizedAccount').withArgs(other.address, await enforcer_contract.ENFORCER_ROLE());
    });

    it('rejects applyGovernanceOverride from unauthorized caller', async function () {
      const { enforcer_contract, other } = await loadFixture(
        deployWithScheduleFixture
      );

      await expect(
        enforcer_contract
          .connect(other)
          .applyGovernanceOverride(
            OFFENSE_CODE,
            1,
            ethers.parseEther('250'),
            3600n,
            'adjusted by governance'
          )
      ).to.be.revertedWithCustomError(enforcer_contract, 'AccessControlUnauthorizedAccount').withArgs(other.address, await enforcer_contract.GOVERNANCE_OVERRIDE_ROLE());
    });
  });

  // ── registerSchedule ─────────────────────────────────────────────────────

  describe('registerSchedule', function () {
    it('registers a schedule and stores all fields correctly', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.registerSchedule(
          OFFENSE_CODE,
          SEVERITY,
          SLASH_AMOUNT,
          LOCK_DURATION
        )
      )
        .to.emit(enforcer_contract, 'ScheduleRegistered')
        .withArgs(OFFENSE_CODE, SEVERITY, SLASH_AMOUNT, LOCK_DURATION);

      const schedule = await enforcer_contract.getSchedule(OFFENSE_CODE);
      expect(schedule.offenseCode).to.equal(OFFENSE_CODE);
      expect(schedule.severity).to.equal(SEVERITY);
      expect(schedule.slashAmount).to.equal(SLASH_AMOUNT);
      expect(schedule.lockDuration).to.equal(LOCK_DURATION);
      expect(schedule.active).to.equal(true);
      expect(schedule.registeredAt).to.be.gt(0n);
      expect(schedule.updatedAt).to.equal(schedule.registeredAt);
    });

    it('rejects empty offense code', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.registerSchedule('', SEVERITY, SLASH_AMOUNT, LOCK_DURATION)
      ).to.be.revertedWith('EqualLiabilityEnforcer: empty offense code');
    });

    it('rejects invalid severity (> 3)', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.registerSchedule(
          OFFENSE_CODE,
          4,
          SLASH_AMOUNT,
          LOCK_DURATION
        )
      ).to.be.revertedWith('EqualLiabilityEnforcer: invalid severity');
    });

    it('rejects zero slash amount', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.registerSchedule(OFFENSE_CODE, SEVERITY, 0n, LOCK_DURATION)
      ).to.be.revertedWith('EqualLiabilityEnforcer: zero slash amount');
    });

    it('rejects duplicate offense code', async function () {
      const { enforcer_contract } = await loadFixture(
        deployWithScheduleFixture
      );

      await expect(
        enforcer_contract.registerSchedule(
          OFFENSE_CODE,
          SEVERITY,
          SLASH_AMOUNT,
          LOCK_DURATION
        )
      ).to.be.revertedWith('EqualLiabilityEnforcer: duplicate offense code');
    });

    it('allows zero lockDuration (immediate unlock)', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await enforcer_contract.registerSchedule(OFFENSE_CODE, 0, SLASH_AMOUNT, 0n);

      const schedule = await enforcer_contract.getSchedule(OFFENSE_CODE);
      expect(schedule.lockDuration).to.equal(0n);
    });
  });

  // ── updateSchedule ───────────────────────────────────────────────────────

  describe('updateSchedule', function () {
    it('updates an existing schedule and emits ScheduleUpdated', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const newSeverity = 2;
      const newSlashAmount = ethers.parseEther('250');
      const newLockDuration = 3600n;

      await expect(
        enforcer_contract.updateSchedule(
          OFFENSE_CODE,
          newSeverity,
          newSlashAmount,
          newLockDuration
        )
      )
        .to.emit(enforcer_contract, 'ScheduleUpdated')
        .withArgs(OFFENSE_CODE, newSeverity, newSlashAmount, newLockDuration);

      const schedule = await enforcer_contract.getSchedule(OFFENSE_CODE);
      expect(schedule.severity).to.equal(newSeverity);
      expect(schedule.slashAmount).to.equal(newSlashAmount);
      expect(schedule.lockDuration).to.equal(newLockDuration);
      expect(schedule.updatedAt).to.be.gte(schedule.registeredAt);
    });

    it('rejects update on non-existent schedule', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.updateSchedule(
          'FAKE-999',
          1,
          SLASH_AMOUNT,
          LOCK_DURATION
        )
      ).to.be.revertedWith('EqualLiabilityEnforcer: schedule not found');
    });

    it('rejects update with invalid severity', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      await expect(
        enforcer_contract.updateSchedule(OFFENSE_CODE, 5, SLASH_AMOUNT, LOCK_DURATION)
      ).to.be.revertedWith('EqualLiabilityEnforcer: invalid severity');
    });

    it('rejects update with zero slash amount', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      await expect(
        enforcer_contract.updateSchedule(OFFENSE_CODE, SEVERITY, 0n, LOCK_DURATION)
      ).to.be.revertedWith('EqualLiabilityEnforcer: zero slash amount');
    });
  });

  describe('applyGovernanceOverride', function () {
    it('updates a schedule through the dedicated governance override role', async function () {
      const { enforcer_contract, governor } = await loadFixture(
        deployWithScheduleFixture
      );

      const newSeverity = 1;
      const newSlashAmount = ethers.parseEther('125');
      const newLockDuration = 7200n;
      const rationale = 'governance calibration after policy review';

      await expect(
        enforcer_contract
          .connect(governor)
          .applyGovernanceOverride(
            OFFENSE_CODE,
            newSeverity,
            newSlashAmount,
            newLockDuration,
            rationale
          )
      )
        .to.emit(enforcer_contract, 'GovernanceOverrideApplied')
        .withArgs(
          OFFENSE_CODE,
          newSeverity,
          newSlashAmount,
          newLockDuration,
          rationale
        );

      const schedule = await enforcer_contract.getSchedule(OFFENSE_CODE);
      expect(schedule.severity).to.equal(newSeverity);
      expect(schedule.slashAmount).to.equal(newSlashAmount);
      expect(schedule.lockDuration).to.equal(newLockDuration);
    });

    it('rejects an empty governance rationale', async function () {
      const { enforcer_contract, governor } = await loadFixture(
        deployWithScheduleFixture
      );

      await expect(
        enforcer_contract
          .connect(governor)
          .applyGovernanceOverride(OFFENSE_CODE, 1, SLASH_AMOUNT, LOCK_DURATION, '')
      ).to.be.revertedWith('EqualLiabilityEnforcer: empty rationale');
    });

    it('preserves identical outcomes across actor classes after governance override', async function () {
      const { enforcer_contract, governor } = await loadFixture(
        deployWithScheduleFixture
      );

      const newSlashAmount = ethers.parseEther('275');
      const newLockDuration = 14400n;

      await enforcer_contract
        .connect(governor)
        .applyGovernanceOverride(
          OFFENSE_CODE,
          2,
          newSlashAmount,
          newLockDuration,
          'harmonize sanction schedule'
        );

      for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
        const [parity, slashAmount, lockDuration] =
          await enforcer_contract.verifyParity.staticCall(OFFENSE_CODE, actorClass);

        expect(parity).to.equal(true);
        expect(slashAmount).to.equal(newSlashAmount);
        expect(lockDuration).to.equal(newLockDuration);
      }
    });
  });

  // ── getSchedule ──────────────────────────────────────────────────────────

  describe('getSchedule', function () {
    it('reverts for unknown offense code', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.getSchedule('UNKNOWN-001')
      ).to.be.revertedWith('EqualLiabilityEnforcer: schedule not found');
    });

    it('returns the same schedule regardless of caller identity', async function () {
      const { enforcer_contract, other } = await loadFixture(
        deployWithScheduleFixture
      );

      const scheduleByOwner = await enforcer_contract.getSchedule(OFFENSE_CODE);
      const scheduleByOther = await enforcer_contract
        .connect(other)
        .getSchedule(OFFENSE_CODE);

      expect(scheduleByOwner.slashAmount).to.equal(scheduleByOther.slashAmount);
      expect(scheduleByOwner.lockDuration).to.equal(scheduleByOther.lockDuration);
      expect(scheduleByOwner.severity).to.equal(scheduleByOther.severity);
    });
  });

  // ── EQUAL LIABILITY: verifyParity ─────────────────────────────────────────

  describe('verifyParity — equal-liability proof', function () {
    it('returns identical slashAmount for Human, AI, and Robot', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const [, slashHuman] = await enforcer_contract.verifyParity.staticCall(
        OFFENSE_CODE,
        ActorClass.Human
      );
      const [, slashAI] = await enforcer_contract.verifyParity.staticCall(
        OFFENSE_CODE,
        ActorClass.AI
      );
      const [, slashRobot] = await enforcer_contract.verifyParity.staticCall(
        OFFENSE_CODE,
        ActorClass.Robot
      );

      expect(slashHuman).to.equal(SLASH_AMOUNT);
      expect(slashAI).to.equal(SLASH_AMOUNT);
      expect(slashRobot).to.equal(SLASH_AMOUNT);
      expect(slashHuman).to.equal(slashAI);
      expect(slashAI).to.equal(slashRobot);
    });

    it('returns identical lockDuration for Human, AI, and Robot', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const [, , lockHuman] = await enforcer_contract.verifyParity.staticCall(
        OFFENSE_CODE,
        ActorClass.Human
      );
      const [, , lockAI] = await enforcer_contract.verifyParity.staticCall(
        OFFENSE_CODE,
        ActorClass.AI
      );
      const [, , lockRobot] = await enforcer_contract.verifyParity.staticCall(
        OFFENSE_CODE,
        ActorClass.Robot
      );

      expect(lockHuman).to.equal(LOCK_DURATION);
      expect(lockAI).to.equal(LOCK_DURATION);
      expect(lockRobot).to.equal(LOCK_DURATION);
      expect(lockHuman).to.equal(lockAI);
      expect(lockAI).to.equal(lockRobot);
    });

    it('returns parity=true for every actor class', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
        const [parity] = await enforcer_contract.verifyParity.staticCall(
          OFFENSE_CODE,
          actorClass
        );
        expect(parity).to.equal(true, `parity should be true for actorClass=${actorClass}`);
      }
    });

    it('emits LiabilityVerified with parity=true for each actor class', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
        await expect(enforcer_contract.verifyParity(OFFENSE_CODE, actorClass))
          .to.emit(enforcer_contract, 'LiabilityVerified')
          .withArgs(OFFENSE_CODE, actorClass, true);
      }
    });

    it('reverts for unknown offense code', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await expect(
        enforcer_contract.verifyParity('UNKNOWN-999', ActorClass.Human)
      ).to.be.revertedWith('EqualLiabilityEnforcer: schedule not found');
    });

    it('verifyParity results match getSchedule — no actor-class branching', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const schedule = await enforcer_contract.getSchedule(OFFENSE_CODE);

      for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
        const [parity, slashAmount, lockDuration] =
          await enforcer_contract.verifyParity.staticCall(OFFENSE_CODE, actorClass);

        expect(parity).to.equal(true);
        expect(slashAmount).to.equal(schedule.slashAmount);
        expect(lockDuration).to.equal(schedule.lockDuration);
      }
    });
  });

  // ── hasActorClassOverride ─────────────────────────────────────────────────

  describe('hasActorClassOverride — always false', function () {
    it('returns false for Human on a registered schedule', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      expect(
        await enforcer_contract.hasActorClassOverride(OFFENSE_CODE, ActorClass.Human)
      ).to.equal(false);
    });

    it('returns false for AI on a registered schedule', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      expect(
        await enforcer_contract.hasActorClassOverride(OFFENSE_CODE, ActorClass.AI)
      ).to.equal(false);
    });

    it('returns false for Robot on a registered schedule', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      expect(
        await enforcer_contract.hasActorClassOverride(OFFENSE_CODE, ActorClass.Robot)
      ).to.equal(false);
    });

    it('returns false for all actor classes on an unregistered code', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
        expect(
          await enforcer_contract.hasActorClassOverride('UNKNOWN-000', actorClass)
        ).to.equal(false);
      }
    });

    it('remains false after schedule update', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      await enforcer_contract.updateSchedule(
        OFFENSE_CODE,
        1,
        ethers.parseEther('100'),
        7200n
      );

      for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
        expect(
          await enforcer_contract.hasActorClassOverride(OFFENSE_CODE, actorClass)
        ).to.equal(false);
      }
    });
  });

  // ── getScheduleCount ─────────────────────────────────────────────────────

  describe('getScheduleCount', function () {
    it('returns (0, 0) when no schedules registered', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      const [total, active] = await enforcer_contract.getScheduleCount();
      expect(total).to.equal(0n);
      expect(active).to.equal(0n);
    });

    it('returns correct total and active counts after registrations', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await enforcer_contract.registerSchedule(
        'DATA-001',
        1,
        ethers.parseEther('100'),
        3600n
      );
      await enforcer_contract.registerSchedule(
        'DATA-003',
        3,
        ethers.parseEther('1000'),
        604800n
      );

      const [total, active] = await enforcer_contract.getScheduleCount();
      expect(total).to.equal(2n);
      expect(active).to.equal(2n);
    });
  });

  // ── getAllActiveSchedules ─────────────────────────────────────────────────

  describe('getAllActiveSchedules', function () {
    it('returns empty array when no schedules exist', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      const schedules = await enforcer_contract.getAllActiveSchedules();
      expect(schedules.length).to.equal(0);
    });

    it('returns only active schedules', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      await enforcer_contract.registerSchedule(
        'DATA-001',
        1,
        ethers.parseEther('100'),
        3600n
      );
      await enforcer_contract.registerSchedule(
        'DATA-003',
        3,
        ethers.parseEther('1000'),
        604800n
      );
      await enforcer_contract.registerSchedule(
        'CONS-001',
        3,
        ethers.parseEther('500'),
        86400n
      );

      const schedules = await enforcer_contract.getAllActiveSchedules();
      expect(schedules.length).to.equal(3);

      const codes = schedules.map((s) => s.offenseCode);
      expect(codes).to.include('DATA-001');
      expect(codes).to.include('DATA-003');
      expect(codes).to.include('CONS-001');
    });

    it('each active schedule has all fields populated correctly', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const schedules = await enforcer_contract.getAllActiveSchedules();
      expect(schedules.length).to.equal(1);

      const s = schedules[0];
      expect(s.offenseCode).to.equal(OFFENSE_CODE);
      expect(s.severity).to.equal(SEVERITY);
      expect(s.slashAmount).to.equal(SLASH_AMOUNT);
      expect(s.lockDuration).to.equal(LOCK_DURATION);
      expect(s.active).to.equal(true);
      expect(s.registeredAt).to.be.gt(0n);
    });
  });

  // ── No actor-class-specific function signatures ───────────────────────────

  describe('No actor-class branching in public interface', function () {
    it('function signatures that accept ActorClass do NOT change sanction outcome', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      // verifyParity accepts ActorClass but must return identical outcomes
      const results = await Promise.all(
        [ActorClass.Human, ActorClass.AI, ActorClass.Robot].map((ac) =>
          enforcer_contract.verifyParity.staticCall(OFFENSE_CODE, ac)
        )
      );

      const [parityH, slashH, lockH] = results[0];
      const [parityAI, slashAI, lockAI] = results[1];
      const [parityR, slashR, lockR] = results[2];

      // All three must be identical
      expect(parityH).to.equal(parityAI).and.to.equal(parityR).and.to.equal(true);
      expect(slashH).to.equal(slashAI).and.to.equal(slashR);
      expect(lockH).to.equal(lockAI).and.to.equal(lockR);
    });

    it('hasActorClassOverride accepts ActorClass but always returns false', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const overrides = await Promise.all(
        [ActorClass.Human, ActorClass.AI, ActorClass.Robot].map((ac) =>
          enforcer_contract.hasActorClassOverride(OFFENSE_CODE, ac)
        )
      );

      for (const override of overrides) {
        expect(override).to.equal(false);
      }
    });
  });

  // ── Multiple offense codes ────────────────────────────────────────────────

  describe('Multiple offense codes — cross-code isolation', function () {
    it('different offense codes have independent schedules', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      const codes = [
        { code: 'DATA-001', severity: 1, slash: ethers.parseEther('100'), lock: 3600n },
        { code: 'CONS-001', severity: 3, slash: ethers.parseEther('500'), lock: 86400n },
        { code: 'GOVN-002', severity: 3, slash: ethers.parseEther('2000'), lock: 604800n },
      ];

      for (const c of codes) {
        await enforcer_contract.registerSchedule(c.code, c.severity, c.slash, c.lock);
      }

      for (const c of codes) {
        const schedule = await enforcer_contract.getSchedule(c.code);
        expect(schedule.slashAmount).to.equal(c.slash);
        expect(schedule.lockDuration).to.equal(c.lock);
        expect(schedule.severity).to.equal(c.severity);
      }

      const [total, active] = await enforcer_contract.getScheduleCount();
      expect(total).to.equal(3n);
      expect(active).to.equal(3n);
    });

    it('equal-liability holds across multiple offense codes for all actor classes', async function () {
      const { enforcer_contract } = await loadFixture(
        deployEqualLiabilityEnforcerFixture
      );

      const codes = [
        { code: 'DATA-001', severity: 1, slash: ethers.parseEther('100'), lock: 3600n },
        { code: 'CONS-001', severity: 3, slash: ethers.parseEther('500'), lock: 86400n },
      ];

      for (const c of codes) {
        await enforcer_contract.registerSchedule(c.code, c.severity, c.slash, c.lock);
      }

      for (const c of codes) {
        for (const actorClass of [ActorClass.Human, ActorClass.AI, ActorClass.Robot]) {
          const [parity, slashAmount, lockDuration] =
            await enforcer_contract.verifyParity.staticCall(c.code, actorClass);

          expect(parity).to.equal(true);
          expect(slashAmount).to.equal(c.slash);
          expect(lockDuration).to.equal(c.lock);
        }
      }
    });
  });

  // ── updateSchedule inactive guard ────────────────────────────────────────

  describe('updateSchedule inactive guard', function () {
    it('registers a schedule and confirms it is active before update', async function () {
      const { enforcer_contract } = await loadFixture(deployWithScheduleFixture);

      const before = await enforcer_contract.getSchedule(OFFENSE_CODE);
      expect(before.active).to.equal(true);

      // Update should succeed because schedule is active
      await enforcer_contract.updateSchedule(
        OFFENSE_CODE,
        2,
        ethers.parseEther('300'),
        7200n
      );

      const after = await enforcer_contract.getSchedule(OFFENSE_CODE);
      expect(after.slashAmount).to.equal(ethers.parseEther('300'));
      expect(after.lockDuration).to.equal(7200n);
    });
  });
});
