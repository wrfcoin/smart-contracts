const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

// =============================================================================
// RewardDistributor vesting/rewards arithmetic fixes
//   #146 — claimEarlyVesting strands already-vested-but-unclaimed tokens
//   #147 — distributeRewards to an existing schedule → underflow DoS on claim
// =============================================================================
describe('RewardDistributor — vesting fixes (#146, #147)', function () {
  const DURATION = 30 * 24 * 60 * 60; // 30 days (within [7d, 365d])
  const ANTI_GAMING_DELAY = 60 * 60; // 1 hour
  const FEE_BP = 2000n; // 20% default early-exit fee
  const BP = 10000n;

  async function deployFixture() {
    const [admin, user, feeRecipient] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory('MockERC20');
    const token = await Mock.deploy('Reward', 'RWD', 18);
    await token.waitForDeployment();

    // Oracle = address(0) so finalAmount == baseAmount (no quality multiplier).
    const Factory = await ethers.getContractFactory('RewardDistributor');
    const rd = await Factory.deploy(feeRecipient.address, ethers.ZeroAddress);
    await rd.waitForDeployment();

    // Fund the distributor generously (configureRewardToken needs balance >=
    // totalAllocated * 110%; claims transfer out of this balance).
    const allocated = ethers.parseEther('100000');
    await token.mint(await rd.getAddress(), ethers.parseEther('1000000'));

    // tokenType "governance" => no vintage/sustainability bonus.
    await rd.configureRewardToken(
      await token.getAddress(),
      allocated,
      0, // emissionRate (unused by these paths)
      DURATION,
      'governance'
    );

    return { rd, token, admin, user, feeRecipient };
  }

  describe('#147 — second distribution must not cause underflow DoS on claim', function () {
    it('a claim after a top-up distribution succeeds (no underflow revert)', async function () {
      const { rd, token, user } = await loadFixture(deployFixture);
      const tokenAddr = await token.getAddress();
      const D1 = ethers.parseEther('300');
      const D2 = ethers.parseEther('600');

      // First distribution.
      await rd.distributeRewards(user.address, tokenAddr, D1);

      // Let ~1/3 of the first schedule vest, then top up (hits the else branch
      // of _createVestingSchedule that reset the claimed watermark wrong).
      await time.increase(DURATION / 3);
      await rd.distributeRewards(user.address, tokenAddr, D2);

      // A short time later the user claims. Under the old bug this reverted with
      // an arithmetic underflow (claimable = 0 - watermark) and stayed bricked
      // for the full new duration.
      await time.increase(ANTI_GAMING_DELAY + 1);
      await expect(rd.connect(user).claimRewards(tokenAddr)).to.not.be.reverted;
    });

    it('the full combined amount is eventually claimable (nothing locked)', async function () {
      const { rd, token, user } = await loadFixture(deployFixture);
      const tokenAddr = await token.getAddress();
      const D1 = ethers.parseEther('300');
      const D2 = ethers.parseEther('600');

      await rd.distributeRewards(user.address, tokenAddr, D1);
      await time.increase(DURATION / 3);
      await rd.distributeRewards(user.address, tokenAddr, D2);

      // Fast-forward well past the new schedule's full duration.
      await time.increase(DURATION + ANTI_GAMING_DELAY + 1);

      const before = await token.balanceOf(user.address);
      await rd.connect(user).claimRewards(tokenAddr);
      const received = (await token.balanceOf(user.address)) - before;

      // The combined schedule = remaining-of-D1 (all of it, nothing claimed yet)
      // + D2 = D1 + D2. After full vesting the user can claim the whole thing.
      expect(received).to.equal(D1 + D2);
    });
  });

  describe('#146 — early vesting must not strand already-vested tokens', function () {
    it('pays out the vested portion (fee-free) plus the discounted unvested portion', async function () {
      const { rd, token, user, feeRecipient } = await loadFixture(deployFixture);
      const tokenAddr = await token.getAddress();
      const D = ethers.parseEther('1000');

      await rd.distributeRewards(user.address, tokenAddr, D);

      // Advance to ~halfway so a substantial portion is already vested but
      // unclaimed (the exact fraction floats by a few seconds — assertions use
      // invariants, not exact equality).
      await time.increase(DURATION / 2);

      const userBefore = await token.balanceOf(user.address);
      const feeBefore = await token.balanceOf(feeRecipient.address);

      const tx = await rd.connect(user).claimEarlyVesting(tokenAddr);
      const rcpt = await tx.wait();

      const userReceived = (await token.balanceOf(user.address)) - userBefore;
      const feeReceived = (await token.balanceOf(feeRecipient.address)) - feeBefore;

      // Invariant 1 — conservation: the whole schedule (D) leaves the contract,
      // split between the user and the fee recipient. The old bug transferred
      // only ~unvested*(1-fee) and stranded the vested-but-unclaimed portion, so
      // user+fee summed to ~D/2, NOT D.
      expect(userReceived + feeReceived).to.equal(D);

      // Invariant 2 — the fee is charged ONLY on the unvested portion, i.e.
      // fee = unvested * 20%, and unvested < D (some had vested). So the fee
      // must be strictly less than a 20% fee on the whole D.
      expect(feeReceived).to.be.gt(0n);
      expect(feeReceived).to.be.lt((D * FEE_BP) / BP);

      // Invariant 3 — the user received the fee-free vested portion too. With
      // ~50% vested and 20% fee on the other ~50%, the user gets ~0.9D, which is
      // far more than the buggy ~0.4D. Assert > 0.8D to prove the vested portion
      // was included.
      expect(userReceived).to.be.gt((D * 80n) / 100n);
    });

    it('leaves no schedule balance behind after early vesting', async function () {
      const { rd, token, user } = await loadFixture(deployFixture);
      const tokenAddr = await token.getAddress();
      const D = ethers.parseEther('1000');

      await rd.distributeRewards(user.address, tokenAddr, D);
      await time.increase(DURATION / 2);
      await rd.connect(user).claimEarlyVesting(tokenAddr);

      // Schedule is now fully settled: vestedAmount == totalAmount, so a
      // subsequent claimRewards has nothing to give.
      const schedule = await rd.vestingSchedules(user.address, tokenAddr);
      expect(schedule.vestedAmount).to.equal(schedule.totalAmount);

      await time.increase(DURATION + ANTI_GAMING_DELAY + 1);
      await expect(rd.connect(user).claimRewards(tokenAddr)).to.be.revertedWith(
        'RewardDistributor: Nothing to claim'
      );
    });
  });
});
