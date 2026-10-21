const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

// =============================================================================
// RewardDistributor — vesting-merge lifetime conservation (#176)
//
// #176 reported that `_createVestingSchedule`'s merge (else) branch conflated
// two meanings of `vestedAmount`: the *claimed watermark* (advanced only in
// claimRewards/claimEarlyVesting/emergency) versus *time-vested-to-date*. The
// vulnerable code set `schedule.vestedAmount = _calculateVestedAmount(...)`
// (time-vested) while also resetting startTime, so a 2nd distribution before
// claiming permanently locked `(timeVested - claimedSoFar)` of the reward and
// could underflow-revert claimRewards.
//
// The fix (PR #169, commit 0e575cf) makes the merge exclude everything already
// CLAIMED from the carried-forward total and reset the claimed watermark to 0:
//     totalAmount = totalAmount - vestedAmount(=claimedSoFar) + amount
//     vestedAmount = 0; startTime = now
// which conserves lifetime claimable. These tests pin that invariant with the
// exact repro from the issue.
// =============================================================================
describe('RewardDistributor — vesting merge lifetime conservation (#176)', function () {
  const DURATION = 100 * 24 * 60 * 60; // "over 100" (days), within [7d, 365d]
  const ANTI_GAMING_DELAY = 60 * 60; // 1 hour

  async function deployFixture() {
    const [admin, user, feeRecipient] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory('MockERC20');
    const token = await Mock.deploy('Reward', 'RWD', 18);
    await token.waitForDeployment();

    // Oracle = address(0) so finalAmount == baseAmount (no quality multiplier).
    const Factory = await ethers.getContractFactory('RewardDistributor');
    const rd = await Factory.deploy(feeRecipient.address, ethers.ZeroAddress);
    await rd.waitForDeployment();

    const allocated = ethers.parseEther('100000');
    await token.mint(await rd.getAddress(), ethers.parseEther('1000000'));

    // tokenType "governance" => no vintage/sustainability bonus.
    await rd.configureRewardToken(
      await token.getAddress(),
      allocated,
      0,
      DURATION,
      'governance'
    );

    return { rd, token, admin, user, feeRecipient };
  }

  it('exact issue repro: 1000 over 100, claim 0, +200 at t=50 → lifetime 1200 (no lock)', async function () {
    const { rd, token, user } = await loadFixture(deployFixture);
    const tokenAddr = await token.getAddress();
    const D1 = ethers.parseEther('1000');
    const D2 = ethers.parseEther('200');

    // Grant 1000 over the full duration.
    await rd.distributeRewards(user.address, tokenAddr, D1);

    // Advance to t=50 (half the duration). 500 is time-vested, 0 claimed.
    await time.increase(DURATION / 2);

    // Second distribution of 200 BEFORE any claim — hits the merge branch.
    await rd.distributeRewards(user.address, tokenAddr, D2);

    // Fast-forward past the full (restarted) duration so everything vests.
    await time.increase(DURATION + ANTI_GAMING_DELAY + 1);

    const before = await token.balanceOf(user.address);
    await rd.connect(user).claimRewards(tokenAddr);
    const received = (await token.balanceOf(user.address)) - before;

    // Correct lifetime claimable is D1 + D2 = 1200. The old bug capped this at
    // ~700 (stranding ~500 already-vested-but-unclaimed tokens).
    expect(received).to.equal(D1 + D2);
  });

  it('claimed watermark is preserved: partial claim, then top-up, conserves lifetime total', async function () {
    const { rd, token, user } = await loadFixture(deployFixture);
    const tokenAddr = await token.getAddress();
    const D1 = ethers.parseEther('1000');
    const D2 = ethers.parseEther('200');

    await rd.distributeRewards(user.address, tokenAddr, D1);

    // Vest ~half then claim what has vested so far (a real claimed watermark).
    await time.increase(DURATION / 2);
    await time.increase(ANTI_GAMING_DELAY + 1);

    const beforeClaim1 = await token.balanceOf(user.address);
    await rd.connect(user).claimRewards(tokenAddr);
    const firstClaim = (await token.balanceOf(user.address)) - beforeClaim1;
    expect(firstClaim).to.be.gt(0n);

    // Top-up distribution AFTER a partial claim: the merge must carry forward
    // (D1 - firstClaim) + D2 and NOT double-count or strand the claimed portion.
    await rd.distributeRewards(user.address, tokenAddr, D2);

    // Fully vest the merged schedule and claim the remainder.
    await time.increase(DURATION + ANTI_GAMING_DELAY + 1);
    const beforeClaim2 = await token.balanceOf(user.address);
    await rd.connect(user).claimRewards(tokenAddr);
    const secondClaim = (await token.balanceOf(user.address)) - beforeClaim2;

    // Conservation across the whole lifetime: everything distributed (1200) is
    // eventually paid out, split across the two claims.
    expect(firstClaim + secondClaim).to.equal(D1 + D2);
  });

  it('a claim immediately after a top-up does not revert (no underflow DoS)', async function () {
    const { rd, token, user } = await loadFixture(deployFixture);
    const tokenAddr = await token.getAddress();

    await rd.distributeRewards(user.address, tokenAddr, ethers.parseEther('1000'));
    await time.increase(DURATION / 2);
    await rd.distributeRewards(user.address, tokenAddr, ethers.parseEther('200'));

    // Under the old bug, claimRewards computed claimable = 0 - watermark and
    // reverted on underflow, bricking claims for the full new duration.
    await time.increase(ANTI_GAMING_DELAY + 1);
    await expect(rd.connect(user).claimRewards(tokenAddr)).to.not.be.reverted;
  });
});
