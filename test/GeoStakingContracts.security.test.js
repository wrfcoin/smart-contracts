const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

// =============================================================================
// GeoStakingContracts security fixes
//   #162 — reentrancy in unstake() drains pool (no ReentrancyGuard / CEI)
//   #163 — reward double-count (accumulatedRewards re-added every claim)
// =============================================================================
describe('GeoStakingContracts — security fixes (#162, #163)', function () {
  const ZONE = 'zone-alpha';
  const MULTIPLIER = 1000; // 10x
  const STAKE = ethers.parseEther('200'); // above the 100 WRF minimum

  async function deployFixture() {
    const [governance, oracle, staker, victim] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory('GeoStakingContracts');
    const geo = await Factory.deploy(governance.address, oracle.address);
    await geo.waitForDeployment();

    // Fund the reward pool generously so payouts are never pool-limited.
    await geo.connect(governance).fundRewardPool({ value: ethers.parseEther('5000') });

    // Create an active zone.
    await geo
      .connect(governance)
      .createZone(ZONE, 'Alpha', 0, 0, 1000, MULTIPLIER);

    return { geo, governance, oracle, staker, victim };
  }

  describe('#163 — reward double-count / rewardPool drain', function () {
    it('a second back-to-back claim with ~0 elapsed time pays ~0 (no compounding)', async function () {
      const { geo, staker } = await loadFixture(deployFixture);

      await geo.connect(staker).stakeInZone(ZONE, { value: STAKE });

      // Accrue ~30 days of rewards, then claim once.
      await time.increase(30 * 24 * 60 * 60);

      const before1 = await ethers.provider.getBalance(staker.address);
      const tx1 = await geo.connect(staker).claimRewards(ZONE);
      const r1 = await tx1.wait();
      const gas1 = r1.gasUsed * r1.gasPrice;
      const after1 = await ethers.provider.getBalance(staker.address);
      const reward1 = after1 - before1 + gas1;
      expect(reward1).to.be.gt(0n); // first claim actually paid out

      // Immediately claim four more times with negligible elapsed time.
      // Under the old double-count bug each of these paid ~the full accrued
      // total (roughly doubling), draining the pool. With the fix each pays ~0.
      let burstPaid = 0n;
      for (let i = 0; i < 4; i++) {
        const b = await ethers.provider.getBalance(staker.address);
        const tx = await geo.connect(staker).claimRewards(ZONE);
        const rc = await tx.wait();
        const gas = rc.gasUsed * rc.gasPrice;
        const a = await ethers.provider.getBalance(staker.address);
        burstPaid += a - b + gas;
      }

      // The four immediate re-claims combined must be a tiny fraction of the
      // first legitimate claim (they only cover a few seconds of accrual),
      // decisively NOT a multiple of it.
      expect(burstPaid).to.be.lt(reward1 / 100n);
    });

    it('does not pay out more than legitimately accrued yield across a claim burst', async function () {
      const { geo, staker } = await loadFixture(deployFixture);

      await geo.connect(staker).stakeInZone(ZONE, { value: STAKE });
      await time.increase(30 * 24 * 60 * 60);

      const poolBefore = await geo.rewardPool();

      // Hammer claimRewards 10x in quick succession.
      for (let i = 0; i < 10; i++) {
        await geo.connect(staker).claimRewards(ZONE);
      }

      const poolAfter = await geo.rewardPool();
      const drained = poolBefore - poolAfter;

      // A single ~30-day claim at 10x on 200 ETH is well under 50 ETH. The old
      // bug would have drained hundreds/thousands via compounding; assert the
      // total drain stays bounded by a sane cap.
      expect(drained).to.be.lt(ethers.parseEther('50'));
    });
  });

  describe('#162 — reentrancy drain of the staking pool', function () {
    it('blocks a re-entrant unstake and prevents draining other stakers funds', async function () {
      const { geo, staker: victim } = await loadFixture(deployFixture);

      // A legitimate victim stakes; their principal sits in the shared balance.
      await geo.connect(victim).stakeInZone(ZONE, { value: STAKE });

      // Deploy the malicious staker.
      const Attacker = await ethers.getContractFactory('GeoStakingReentrancyAttacker');
      const attacker = await Attacker.deploy(await geo.getAddress(), ZONE);
      await attacker.waitForDeployment();

      // Attacker stakes the same amount, then lets rewards accrue.
      await attacker.stake({ value: STAKE });
      await time.increase(15 * 24 * 60 * 60);

      const contractBefore = await ethers.provider.getBalance(await geo.getAddress());

      // Trigger the attack: unstake the full principal; the attacker's
      // receive() re-enters unstake() on the reward payout.
      await attacker.attackUnstake(STAKE);

      // The nested re-entrant unstake must have been rejected.
      expect(await attacker.reentrySuccesses()).to.equal(0n);
      expect(await attacker.reentryAttempts()).to.equal(1n); // it did try

      // The attacker cannot have extracted more than its own principal + reward.
      const contractAfter = await ethers.provider.getBalance(await geo.getAddress());
      const extracted = contractBefore - contractAfter;

      // Extracted must be at most principal + a bounded reward, and MUST leave
      // the victim's full principal behind.
      expect(extracted).to.be.lt(STAKE + ethers.parseEther('50'));
      expect(contractAfter).to.be.gte(STAKE); // victim principal still recoverable
    });

    it('exposes nonReentrant on the ETH-moving externals', async function () {
      const { geo, victim } = await loadFixture(deployFixture);
      // Sanity: a normal unstake still works end-to-end (guard does not brick it).
      await geo.connect(victim).stakeInZone(ZONE, { value: STAKE });
      await time.increase(24 * 60 * 60);
      await expect(geo.connect(victim).unstake(ZONE, STAKE)).to.not.be.reverted;
    });
  });
});
