/**
 * @title StakeDelegation Edge Case Tests (Issue #78)
 * @dev Tests the edge cases not covered by the happy-path test suite:
 *   1. Stake-during-slash balance isolation
 *   2. Unstake-below-minimum (minimum stake enforcement)
 *   3. Delegation chain depth (per-advocate limits, multi-hop chains)
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
} = require('@nomicfoundation/hardhat-network-helpers');

// ─────────────────────────────────────────────────────────────────────────────
//  Shared fixture
// ─────────────────────────────────────────────────────────────────────────────

async function deployStakeDelegationFixture() {
  const [
    owner,
    advocate1,
    advocate2,
    advocate3,
    recruit1,
    recruit2,
    recruit3,
    protocolTreasury,
    malicious,
  ] = await ethers.getSigners();

  const TestERC20 = await ethers.getContractFactory('TestERC20');
  const wrfToken = await TestERC20.deploy(
    'WRF Token',
    'WRF',
    ethers.parseEther('10000000')
  );

  const TestMultiAssetStaking = await ethers.getContractFactory('TestMultiAssetStaking');
  const multiAssetStaking = await TestMultiAssetStaking.deploy();

  const TestParticipantTypeRegistry = await ethers.getContractFactory('TestParticipantTypeRegistry');
  const participantTypeRegistry = await TestParticipantTypeRegistry.deploy();

  const TestDynamicStakeCalculator = await ethers.getContractFactory('TestDynamicStakeCalculator');
  const dynamicStakeCalculator = await TestDynamicStakeCalculator.deploy();

  const StakeDelegation = await ethers.getContractFactory('StakeDelegation');
  const stakeDelegation = await StakeDelegation.deploy(
    await multiAssetStaking.getAddress(),
    await participantTypeRegistry.getAddress(),
    await dynamicStakeCalculator.getAddress(),
    await wrfToken.getAddress(),
    protocolTreasury.address
  );

  const stakeDelegationAddr = await stakeDelegation.getAddress();
  const initialBalance = ethers.parseEther('100000');

  for (const signer of [advocate1, advocate2, advocate3, recruit1, recruit2, recruit3]) {
    await wrfToken.transfer(signer.address, initialBalance);
    await wrfToken.connect(signer).approve(stakeDelegationAddr, initialBalance);
  }

  const EARNINGS_DISTRIBUTOR_ROLE = await stakeDelegation.EARNINGS_DISTRIBUTOR_ROLE();
  await stakeDelegation.connect(owner).grantRole(EARNINGS_DISTRIBUTOR_ROLE, owner.address);

  return {
    stakeDelegation,
    wrfToken,
    multiAssetStaking,
    participantTypeRegistry,
    dynamicStakeCalculator,
    owner,
    advocate1,
    advocate2,
    advocate3,
    recruit1,
    recruit2,
    recruit3,
    protocolTreasury,
    malicious,
  };
}

/**
 * Helper: creates a delegation from advocate to recruit.
 * Uses the exact EIP-712 signing pattern from happy-path tests.
 */
async function createDelegation({
  stakeDelegation,
  advocate,
  recruit,
  wrfToken,
  referralCode,
  stakeAmount,
  maxUsage = 5,
}) {
  if (bytes8(referralCode) !== referralCode) {
    throw new Error(`referralCode must be exactly 8 chars, got: "${referralCode}"`);
  }

  await stakeDelegation
    .connect(advocate)
    .createReferralLink(referralCode, stakeAmount, await wrfToken.getAddress(), maxUsage);

  const linkDetails = await stakeDelegation.getReferralLink(referralCode);
  const nonce = await stakeDelegation.nonces(advocate.address);

  const domain = {
    name: 'WRFCoin StakeDelegation',
    version: '1',
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: await stakeDelegation.getAddress(),
  };

  const types = {
    ReferralLink: [
      { name: 'advocate', type: 'address' },
      { name: 'referralCode', type: 'string' },
      { name: 'nonce', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
      { name: 'stakeAmount', type: 'uint256' },
      { name: 'stakeAsset', type: 'address' },
    ],
  };

  const value = {
    advocate: advocate.address,
    referralCode,
    nonce,
    deadline: linkDetails.expiresAt,
    stakeAmount,
    stakeAsset: await wrfToken.getAddress(),
  };

  const signature = await advocate.signTypedData(domain, types, value);
  await stakeDelegation.connect(recruit).useReferralLink(referralCode, signature);

  const { delegationId } = await stakeDelegation.getRecruitDelegation(recruit.address);
  return delegationId;
}

// Ensure referral code is exactly 8 chars (used for validation in helper above)
function bytes8(s) {
  return s.length === 8 ? s : null;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Edge Case 1 — Stake-during-slash: balance isolation
// ─────────────────────────────────────────────────────────────────────────────

describe('StakeDelegation edge cases: stake-during-slash balance isolation', function () {
  /**
   * StakeDelegation delegates stake accounting to TestMultiAssetStaking via stakeAsset().
   * TestMultiAssetStaking.stakeAsset() records _totalStakes[msg.sender], where msg.sender
   * is the StakeDelegation contract itself — NOT the advocate. Therefore getTotalStake(advocate)
   * returns 0 from the perspective of the staking contract.
   *
   * This is a significant design gap: the staking contract tracks per-delegationContract
   * totals rather than per-advocate totals. A slash via SlashingMechanism would call
   * getTotalStake(advocate) and find 0, making slashing impossible.
   *
   * The tests below document this gap and verify what IS tracked.
   */

  it('should document gap: StakeDelegation holds tokens directly, not via MultiAssetStaking', async function () {
    /**
     * StakeDelegation._transferStakeToContract() calls safeTransferFrom(advocate, address(this), amount)
     * It does NOT call multiAssetStaking.stakeAsset(). The WRF tokens land in the
     * StakeDelegation contract itself, not in the MultiAssetStaking mock.
     *
     * Implication: getTotalStake(advocate) returns 0 in MockMultiAssetStaking because
     * stakeAsset() is never invoked. SlashingMechanism cannot slash delegated advocate
     * stake via the multiAssetStaking getTotalStake route — the stake is held in
     * StakeDelegation's own ERC20 balance.
     *
     * The IStakeDelegation.slashDelegatedStake() function is the intended mechanism
     * for slashing delegated stake, but it is not connected to the MultiAssetStaking pool.
     *
     * TODO: StakeDelegation should register staked amounts with MultiAssetStaking
     *       so the SlashingMechanism can access them via getTotalStake(advocate).
     */
    const { stakeDelegation, wrfToken, multiAssetStaking, advocate1, recruit1 } =
      await loadFixture(deployStakeDelegationFixture);

    const stakeAmount = ethers.parseEther('1000');

    // Advocate's WRF balance before delegation
    const advocateBalanceBefore = await wrfToken.balanceOf(advocate1.address);

    await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'PRESLSH1',
      stakeAmount,
    });

    // After delegation: stake is held by the StakeDelegation contract directly
    const contractWRFBalance = await wrfToken.balanceOf(await stakeDelegation.getAddress());
    expect(contractWRFBalance).to.equal(stakeAmount);

    // Advocate's balance reduced by stakeAmount
    const advocateBalanceAfter = await wrfToken.balanceOf(advocate1.address);
    expect(advocateBalanceBefore - advocateBalanceAfter).to.equal(stakeAmount);

    // MultiAssetStaking mock has 0 for both advocate and the contract — never called
    const advocateMASStake = await multiAssetStaking.getTotalStake(advocate1.address);
    const contractMASStake = await multiAssetStaking.getTotalStake(await stakeDelegation.getAddress());
    expect(advocateMASStake).to.equal(0n);
    expect(contractMASStake).to.equal(0n);
    // TODO: connect StakeDelegation to MultiAssetStaking so slash routing works
  });

  it('should record stakeAmount at delegation creation time (immutable from that point)', async function () {
    /**
     * Each delegation records its stakeAmount at creation. Adding a second delegation
     * does not alter the first delegation's stakeAmount. The WRF balance of the
     * StakeDelegation contract grows cumulatively (tokens are held directly by the contract).
     */
    const { stakeDelegation, wrfToken, advocate1, recruit1 } =
      await loadFixture(deployStakeDelegationFixture);

    const initialStake = ethers.parseEther('1000');

    const delegationId = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'PRESLSH2',
      stakeAmount: initialStake,
    });

    const delegationAtCreation = await stakeDelegation.getDelegation(delegationId);
    expect(delegationAtCreation.stakeAmount).to.equal(initialStake);

    // StakeDelegation holds WRF tokens directly (not via MultiAssetStaking)
    const contractWRFBefore = await wrfToken.balanceOf(await stakeDelegation.getAddress());
    expect(contractWRFBefore).to.equal(initialStake);

    // Advocate adds MORE stake for a second recruit (simulating "stake during slash window")
    const [, , , , , , , , , extraRecruit] = await ethers.getSigners();
    const extraStake = ethers.parseEther('500');
    await wrfToken.transfer(advocate1.address, extraStake);
    await wrfToken.connect(advocate1).approve(await stakeDelegation.getAddress(), extraStake);

    await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: extraRecruit,
      wrfToken,
      referralCode: 'PRESLSH3',
      stakeAmount: extraStake,
      maxUsage: 1,
    });

    // Original delegation's stakeAmount is unchanged (snapshot at creation)
    const delegationAfterNewStake = await stakeDelegation.getDelegation(delegationId);
    expect(delegationAfterNewStake.stakeAmount).to.equal(initialStake);

    // Total WRF held by contract has grown
    const contractWRFAfter = await wrfToken.balanceOf(await stakeDelegation.getAddress());
    expect(contractWRFAfter).to.equal(initialStake + extraStake);

    // The slash gap: SlashingMechanism uses getTotalStake(advocate) which is 0 here —
    // it cannot slash this stake through the MultiAssetStaking route.
    // Only slashDelegatedStake() on StakeDelegation would affect this balance.
  });

  it('should correctly attribute delegation stake amounts independently', async function () {
    const { stakeDelegation, wrfToken, advocate1, recruit1, recruit2 } =
      await loadFixture(deployStakeDelegationFixture);

    const stake1 = ethers.parseEther('1000');
    const stake2 = ethers.parseEther('750');

    const d1 = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'ATTRIB01',
      stakeAmount: stake1,
    });

    await wrfToken.transfer(advocate1.address, stake2);
    await wrfToken.connect(advocate1).approve(await stakeDelegation.getAddress(), stake2);

    const d2 = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit2,
      wrfToken,
      referralCode: 'ATTRIB02',
      stakeAmount: stake2,
    });

    // Each delegation independently records its own stakeAmount
    const del1 = await stakeDelegation.getDelegation(d1);
    const del2 = await stakeDelegation.getDelegation(d2);
    expect(del1.stakeAmount).to.equal(stake1);
    expect(del2.stakeAmount).to.equal(stake2);

    // Platform stats reflect cumulative staked amount
    const stats = await stakeDelegation.getPlatformStats();
    expect(stats.totalStaked).to.equal(stake1 + stake2);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
//  Edge Case 2 — Unstake-below-minimum
// ─────────────────────────────────────────────────────────────────────────────

describe('StakeDelegation edge cases: unstake-below-minimum behavior', function () {
  /**
   * StakeDelegation has NO direct unstake(amount) function.
   * Stake is returned via terminateDelegation (all-or-nothing of unrepaid portion).
   * There is no mechanism to partially withdraw stake below a minimum threshold.
   *
   * The "minimum stake" enforcement gap is:
   * - createReferralLink enforces the protocol minimum stake floor.
   * - A 1 wei delegation is technically valid
   *
   * We test:
   * (a) Partial earnings do not trigger partial principal withdrawal.
   * (b) terminateDelegation returns the entire unrepaid amount (no partial unstake).
   * (c) Zero earnings are rejected (the only way to "unstake" is termination).
   * (d) No minStake floor is enforced — document the gap.
   */

  it('should not allow below-minimum partial unstake via processRecruitEarnings', async function () {
    const { stakeDelegation, wrfToken, advocate1, recruit1, owner } =
      await loadFixture(deployStakeDelegationFixture);

    const stakeAmount = ethers.parseEther('1000');

    const delegationId = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'MINTEST1',
      stakeAmount,
    });

    // Process a small amount — repays 30% of 100 = 30 WRF (leaving 970 WRF unrepaid)
    const smallEarnings = ethers.parseEther('100');
    await wrfToken.mint(await stakeDelegation.getAddress(), smallEarnings);
    await stakeDelegation.connect(owner).processRecruitEarnings(recruit1.address, smallEarnings);

    const delegation = await stakeDelegation.getDelegation(delegationId);
    const expectedRepayment = (smallEarnings * 3000n) / 10000n; // 30 WRF
    expect(delegation.stakeRepaid).to.equal(expectedRepayment);
    expect(delegation.stakeAmount - delegation.stakeRepaid).to.be.greaterThan(0n);

    // Status remains ACTIVE — partial repayment does NOT trigger independence or unlocking
    expect(delegation.status).to.equal(0); // ACTIVE

    // No advocate can call "unstake(smallAmount)" — terminateDelegation is all-or-nothing
    // Verify advocate cannot re-use the delegation (still ACTIVE, no partial withdraw)
    const profile = await stakeDelegation.getAdvocateProfile(advocate1.address);
    expect(profile.activeDelegations).to.equal(1n);
  });

  it('should return FULL unrepaid stake on termination (no partial below-minimum unstake)', async function () {
    const { stakeDelegation, wrfToken, advocate1, recruit1, owner } =
      await loadFixture(deployStakeDelegationFixture);

    const stakeAmount = ethers.parseEther('1000');

    const delegationId = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'MINTEST2',
      stakeAmount,
    });

    // Partially repay 30 WRF (from 100 WRF earnings)
    const partialEarnings = ethers.parseEther('100');
    await wrfToken.mint(await stakeDelegation.getAddress(), partialEarnings);
    await stakeDelegation.connect(owner).processRecruitEarnings(recruit1.address, partialEarnings);

    const delegationBefore = await stakeDelegation.getDelegation(delegationId);
    const unrepaid = delegationBefore.stakeAmount - delegationBefore.stakeRepaid;
    expect(unrepaid).to.be.greaterThan(0n);

    // Recruit terminates — advocate recovers entire unrepaid amount (all-or-nothing)
    await expect(
      stakeDelegation.connect(recruit1).terminateDelegation(delegationId, 'Exiting network')
    )
      .to.emit(stakeDelegation, 'DelegationTerminated')
      .to.emit(stakeDelegation, 'StakeRecovered');

    const delegationAfter = await stakeDelegation.getDelegation(delegationId);
    expect(delegationAfter.status).to.equal(2); // DEFAULTED (recruit initiated)

    // Cannot terminate an already-terminated delegation
    await expect(
      stakeDelegation.connect(recruit1).terminateDelegation(delegationId, 'Again')
    ).to.be.revertedWith('Delegation not active');
  });

  it('should reject zero earnings (the only stake-release trigger)', async function () {
    const { stakeDelegation, wrfToken, advocate1, recruit1, owner } =
      await loadFixture(deployStakeDelegationFixture);

    await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'MINTEST3',
      stakeAmount: ethers.parseEther('1000'),
    });

    // Zero earnings are rejected
    await expect(
      stakeDelegation.connect(owner).processRecruitEarnings(recruit1.address, 0)
    ).to.be.revertedWith('Earnings must be greater than 0');
  });

  it('should enforce minimum stake floor at createReferralLink', async function () {
    /**
     * PR #107 added the protocol floor; tiny stake referral links should now
     * fail instead of documenting an accepted gap.
     */
    const { stakeDelegation, wrfToken, advocate1 } =
      await loadFixture(deployStakeDelegationFixture);

    const tinyStake = 1n; // 1 wei

    await expect(
      stakeDelegation
        .connect(advocate1)
        .createReferralLink('TINY1234', tinyStake, await wrfToken.getAddress(), 0)
    ).to.be.revertedWith('StakeDelegation: stake below protocol minimum');
  });

  it('should achieve independence and release stake when fully repaid', async function () {
    const { stakeDelegation, wrfToken, advocate1, recruit1, owner } =
      await loadFixture(deployStakeDelegationFixture);

    const stakeAmount = ethers.parseEther('1000');

    const delegationId = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'MINTEST5',
      stakeAmount,
    });

    // Process enough earnings to fully repay (30% of earnings = stake => earnings = 1000/0.3)
    const earningsNeeded = (stakeAmount * 10000n + 2999n) / 3000n;
    await wrfToken.mint(await stakeDelegation.getAddress(), earningsNeeded);

    await expect(
      stakeDelegation.connect(owner).processRecruitEarnings(recruit1.address, earningsNeeded)
    ).to.emit(stakeDelegation, 'IndependenceAchieved');

    const delegation = await stakeDelegation.getDelegation(delegationId);
    expect(delegation.status).to.equal(1); // COMPLETED
    expect(delegation.stakeRepaid).to.be.greaterThanOrEqual(stakeAmount);

    // After independence, active delegation count drops
    const profile = await stakeDelegation.getAdvocateProfile(advocate1.address);
    expect(profile.activeDelegations).to.equal(0n);
    expect(profile.successfulDelegations).to.equal(1n);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
//  Edge Case 3 — Delegation chain depth
// ─────────────────────────────────────────────────────────────────────────────

describe('StakeDelegation edge cases: delegation chain depth', function () {
  /**
   * StakeDelegation models pairwise advocate→recruit relationships.
   * There is no built-in support for recursive chains (A→B→C→D).
   * We test:
   * (a) Per-advocate limit (DEFAULT_MAX_DELEGATIONS_PER_ADVOCATE = 10).
   * (b) Attempting delegation beyond the limit is rejected.
   * (c) A completed recruit CAN become an advocate (2-hop chain is possible).
   * (d) Slashing does NOT propagate through multi-hop chains (documented gap).
   */

  it('should enforce DEFAULT_MAX_DELEGATIONS_PER_ADVOCATE limit of 10', async function () {
    const { stakeDelegation, wrfToken, owner } =
      await loadFixture(deployStakeDelegationFixture);

    const allSigners = await ethers.getSigners();
    // Use a dedicated advocate (signer index 10) to avoid conflicts
    const adv = allSigners[10];

    const stakePerDel = ethers.parseEther('100');
    const totalNeeded = stakePerDel * 12n; // enough for 12 attempts
    await wrfToken.transfer(adv.address, totalNeeded);
    await wrfToken.connect(adv).approve(await stakeDelegation.getAddress(), totalNeeded);

    // Create 10 delegations (at the limit)
    // Recruits: signers 11-20
    const recruits = allSigners.slice(11, 21);
    for (let i = 0; i < 10; i++) {
      const code = `REC${String(i).padStart(5, '0')}`; // 8 chars: "REC00000" etc.
      await createDelegation({
        stakeDelegation,
        advocate: adv,
        recruit: recruits[i],
        wrfToken,
        referralCode: code,
        stakeAmount: stakePerDel,
        maxUsage: 1,
      });
    }

    const profile = await stakeDelegation.getAdvocateProfile(adv.address);
    expect(profile.activeDelegations).to.equal(10n);
    expect(profile.maxDelegations).to.equal(10n);

    // 11th referral link creation should fail: "Advocate delegation limit reached"
    await expect(
      stakeDelegation
        .connect(adv)
        .createReferralLink('OVERLMT1', stakePerDel, await wrfToken.getAddress(), 1)
    ).to.be.revertedWith('Advocate delegation limit reached');
  });

  it('should allow a completed recruit to become an advocate (2-hop chain)', async function () {
    const { stakeDelegation, wrfToken, advocate1, recruit1, recruit2, owner } =
      await loadFixture(deployStakeDelegationFixture);

    // Step 1: advocate1 → recruit1
    const stakeAB = ethers.parseEther('1000');
    const d_AB = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'CHAIN001',
      stakeAmount: stakeAB,
    });

    // Step 2: recruit1 earns independence
    const earningsNeeded = (stakeAB * 10000n + 2999n) / 3000n;
    await wrfToken.mint(await stakeDelegation.getAddress(), earningsNeeded);
    await stakeDelegation.connect(owner).processRecruitEarnings(recruit1.address, earningsNeeded);

    const del_AB = await stakeDelegation.getDelegation(d_AB);
    expect(del_AB.status).to.equal(1); // COMPLETED

    // Step 3: recruit1 becomes advocate for recruit2 (2nd hop)
    const stakeBC = ethers.parseEther('500');
    await wrfToken.transfer(recruit1.address, stakeBC);
    await wrfToken.connect(recruit1).approve(await stakeDelegation.getAddress(), stakeBC);

    const d_BC = await createDelegation({
      stakeDelegation,
      advocate: recruit1,   // B (formerly recruit, now advocate)
      recruit: recruit2,    // C
      wrfToken,
      referralCode: 'CHAIN002',
      stakeAmount: stakeBC,
      maxUsage: 1,
    });

    const del_BC = await stakeDelegation.getDelegation(d_BC);
    expect(del_BC.advocate).to.equal(recruit1.address);
    expect(del_BC.recruit).to.equal(recruit2.address);
    expect(del_BC.status).to.equal(0); // ACTIVE
  });

  it('should document gap: slash does NOT propagate through multi-hop delegation chain', async function () {
    /**
     * Gap: When B is slashed (the middle of A→B→C), the B→C delegation is not affected.
     * SlashingMechanism calls slashDelegatedStake(B, amount) which reduces B's stake
     * in the slashDelegation contract, but does NOT reduce B's obligation to C or
     * A's effective exposure through B.
     *
     * TODO: Implement recursive slash propagation:
     * If B is slashed, B's delegations to downstream recruits should be reduced proportionally.
     */

    const { stakeDelegation, wrfToken, advocate1, recruit1, recruit2, owner } =
      await loadFixture(deployStakeDelegationFixture);

    // A → B
    const stakeAB = ethers.parseEther('1000');
    await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'CHAINAX1',
      stakeAmount: stakeAB,
    });

    // B earns independence, becomes advocate for C
    const earningsNeeded = (stakeAB * 10000n + 2999n) / 3000n;
    await wrfToken.mint(await stakeDelegation.getAddress(), earningsNeeded);
    await stakeDelegation.connect(owner).processRecruitEarnings(recruit1.address, earningsNeeded);

    const stakeBC = ethers.parseEther('500');
    await wrfToken.transfer(recruit1.address, stakeBC);
    await wrfToken.connect(recruit1).approve(await stakeDelegation.getAddress(), stakeBC);

    const d_BC = await createDelegation({
      stakeDelegation,
      advocate: recruit1,
      recruit: recruit2,
      wrfToken,
      referralCode: 'CHAINBX1',
      stakeAmount: stakeBC,
      maxUsage: 1,
    });

    // Snapshot B→C delegation before simulated slash
    const del_BC_before = await stakeDelegation.getDelegation(d_BC);
    expect(del_BC_before.stakeAmount).to.equal(stakeBC);
    expect(del_BC_before.status).to.equal(0); // ACTIVE

    // Simulate slash: even if slashDelegatedStake is called on B, the B→C delegation
    // stakeAmount and status are NOT changed (no propagation)
    // (slashDelegatedStake is not access-gated in the interface, but may revert —
    //  we catch both cases and verify no propagation occurs either way)
    const slashOnB = ethers.parseEther('250');
    try {
      await stakeDelegation
        .connect(owner)
        .slashDelegatedStake(recruit1.address, slashOnB);
    } catch {
      // Slash call reverted (e.g., access control) — that's also fine for this test
    }

    // B→C delegation is unaffected regardless of whether slash succeeded
    const del_BC_after = await stakeDelegation.getDelegation(d_BC);
    expect(del_BC_after.stakeAmount).to.equal(stakeBC);    // unchanged
    expect(del_BC_after.status).to.equal(0);              // still ACTIVE
    // TODO: chain propagation should reduce del_BC.stakeAmount proportionally
  });

  it('should allow admin to increase max delegations per advocate globally', async function () {
    const { stakeDelegation, owner } =
      await loadFixture(deployStakeDelegationFixture);

    // Default is 10
    expect(await stakeDelegation.maxDelegationsPerAdvocate()).to.equal(10n);

    // Admin updates global default
    await stakeDelegation.connect(owner).updateMaxDelegationsPerAdvocate(20);
    expect(await stakeDelegation.maxDelegationsPerAdvocate()).to.equal(20n);

    // Non-admin cannot update
    const allSigners = await ethers.getSigners();
    const notAdmin = allSigners[8];
    await expect(
      stakeDelegation.connect(notAdmin).updateMaxDelegationsPerAdvocate(50)
    ).to.be.revertedWithCustomError(stakeDelegation, 'AccessControlUnauthorizedAccount').withArgs(notAdmin.address, await stakeDelegation.ADMIN_ROLE());
  });

  it('should handle concurrent delegations from different advocates independently', async function () {
    const { stakeDelegation, wrfToken, advocate1, advocate2, recruit1, recruit2 } =
      await loadFixture(deployStakeDelegationFixture);

    // advocate1 → recruit1 with 1000 WRF
    const d1 = await createDelegation({
      stakeDelegation,
      advocate: advocate1,
      recruit: recruit1,
      wrfToken,
      referralCode: 'CONCUR01',
      stakeAmount: ethers.parseEther('1000'),
    });

    // advocate2 → recruit2 with 500 WRF (independent)
    const d2 = await createDelegation({
      stakeDelegation,
      advocate: advocate2,
      recruit: recruit2,
      wrfToken,
      referralCode: 'CONCUR02',
      stakeAmount: ethers.parseEther('500'),
    });

    const del1 = await stakeDelegation.getDelegation(d1);
    const del2 = await stakeDelegation.getDelegation(d2);

    // Each delegation is independent
    expect(del1.advocate).to.equal(advocate1.address);
    expect(del2.advocate).to.equal(advocate2.address);
    expect(del1.stakeAmount).to.not.equal(del2.stakeAmount);

    // Terminating d1 does not affect d2
    await stakeDelegation
      .connect(advocate1)
      .terminateDelegation(d1, 'Advocate1 exits');

    const del1After = await stakeDelegation.getDelegation(d1);
    const del2After = await stakeDelegation.getDelegation(d2);
    expect(del1After.status).to.equal(3); // TERMINATED
    expect(del2After.status).to.equal(0); // ACTIVE — unaffected
  });
});
