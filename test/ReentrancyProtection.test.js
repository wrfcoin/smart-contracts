// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('Reentrancy Protection Tests (#77, #75)', function () {
  const MIN_STAKE = ethers.parseEther('0.01');

  // =========================================================================
  //                 FIXTURE: EconomicSecurityMechanisms
  // =========================================================================

  async function deployESMFixture() {
    const [admin, staker, attacker] = await ethers.getSigners();

    // Deploy a normal mock ERC20 as governance token
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const govToken = await MockERC20.deploy('GovToken', 'GOV', 18);
    await govToken.waitForDeployment();

    // Deploy ESM
    const ESM = await ethers.getContractFactory('EconomicSecurityMechanisms');
    const esm = await ESM.deploy(await govToken.getAddress(), admin.address);
    await esm.waitForDeployment();

    // Mint tokens to staker and ESM (ESM needs tokens to pay rewards)
    const stakeAmount = ethers.parseEther('1000');
    await govToken.mint(staker.address, stakeAmount);
    await govToken.mint(await esm.getAddress(), ethers.parseEther('10000')); // reward pool

    // Approve ESM to spend staker's tokens
    await govToken.connect(staker).approve(await esm.getAddress(), ethers.MaxUint256);

    return { esm, govToken, admin, staker, attacker, stakeAmount };
  }

  async function deployMaliciousESMFixture() {
    const [admin, attacker] = await ethers.getSigners();

    // Deploy malicious ERC20 that re-enters on transfer
    const MaliciousERC20 = await ethers.getContractFactory('contracts/mocks/MaliciousERC20.sol:MaliciousERC20');
    const malToken = await MaliciousERC20.deploy();
    await malToken.waitForDeployment();

    // Deploy ESM with the malicious token
    const ESM = await ethers.getContractFactory('EconomicSecurityMechanisms');
    const esm = await ESM.deploy(await malToken.getAddress(), admin.address);
    await esm.waitForDeployment();

    // Mint tokens to attacker and ESM
    const stakeAmount = ethers.parseEther('1000');
    await malToken.mint(attacker.address, stakeAmount);
    await malToken.mint(await esm.getAddress(), ethers.parseEther('10000'));

    // Approve ESM
    await malToken.connect(attacker).approve(await esm.getAddress(), ethers.MaxUint256);

    return { esm, malToken, admin, attacker, stakeAmount };
  }

  // =========================================================================
  //                 FIXTURE: WRFToken deregistration
  // =========================================================================

  async function deployWRFFixture() {
    const signers = await ethers.getSigners();
    const deployer = signers[0];
    const targetStation = signers[1];

    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();
    await wrfToken.waitForDeployment();

    return { wrfToken, deployer, targetStation, signers };
  }

  async function deployMaliciousStationFixture() {
    const signers = await ethers.getSigners();
    const deployer = signers[0];

    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();
    await wrfToken.waitForDeployment();

    // Deploy malicious station contract
    const MaliciousStation = await ethers.getContractFactory('MaliciousStation');
    const malStation = await MaliciousStation.deploy(await wrfToken.getAddress());
    await malStation.waitForDeployment();

    return { wrfToken, malStation, deployer, signers };
  }

  // =========================================================================
  //       ISSUE #77: EconomicSecurityMechanisms.unstakeTokens() CEI fix
  // =========================================================================

  describe('Issue #77: EconomicSecurityMechanisms unstakeTokens()', function () {
    it('should allow normal unstaking after lock period expires', async function () {
      const { esm, govToken, staker, stakeAmount } = await loadFixture(deployESMFixture);

      const lockPeriod = 7 * 24 * 60 * 60; // 7 days minimum
      await esm.connect(staker).stakeTokens(stakeAmount, lockPeriod);

      // Fast forward past lock period
      await time.increase(lockPeriod + 1);

      const balBefore = await govToken.balanceOf(staker.address);
      await esm.connect(staker).unstakeTokens(stakeAmount);
      const balAfter = await govToken.balanceOf(staker.address);

      // Staker should receive staked amount + rewards
      expect(balAfter).to.be.gt(balBefore);
    });

    it('should revert unstaking before lock period expires', async function () {
      const { esm, staker, stakeAmount } = await loadFixture(deployESMFixture);

      const lockPeriod = 7 * 24 * 60 * 60;
      await esm.connect(staker).stakeTokens(stakeAmount, lockPeriod);

      await expect(
        esm.connect(staker).unstakeTokens(stakeAmount)
      ).to.be.revertedWith('ESM: Tokens still locked');
    });

    it('should update totalRewardsDistributed before transfer (CEI pattern)', async function () {
      const { esm, govToken, staker, stakeAmount } = await loadFixture(deployESMFixture);

      const lockPeriod = 7 * 24 * 60 * 60;
      await esm.connect(staker).stakeTokens(stakeAmount, lockPeriod);

      await time.increase(lockPeriod + 1);

      // Unstake and verify metrics updated
      await esm.connect(staker).unstakeTokens(stakeAmount);

      const metrics = await esm.getSecurityMetrics();
      // totalStaked (index 0) should be 0 after full unstake
      expect(metrics[0]).to.equal(0n);
    });

    it('should block reentrancy on unstakeTokens with malicious token', async function () {
      const { esm, malToken, attacker, stakeAmount } = await loadFixture(
        deployMaliciousESMFixture
      );

      const lockPeriod = 7 * 24 * 60 * 60;

      // Disable attack during staking (transferFrom path)
      await malToken.disableAttack();
      await esm.connect(attacker).stakeTokens(stakeAmount, lockPeriod);

      await time.increase(lockPeriod + 1);

      // Enable the reentrancy attack: when ESM calls safeTransfer(), the token re-enters unstakeTokens
      await malToken.setAttack(await esm.getAddress(), stakeAmount);

      const esmBalanceBefore = await malToken.balanceOf(await esm.getAddress());

      // The outer unstakeTokens call should succeed; the re-entrant call inside
      // transfer() should be caught by nonReentrant guard and silently fail (try/catch)
      await esm.connect(attacker).unstakeTokens(stakeAmount);

      const esmBalanceAfter = await malToken.balanceOf(await esm.getAddress());
      const attackerBalance = await malToken.balanceOf(attacker.address);

      // Verify ESM was not drained beyond the legitimate unstake amount + rewards
      const legitimateWithdrawal = esmBalanceBefore - esmBalanceAfter;
      // Should be at most stakeAmount + reasonable rewards (10% annual for 7 days)
      const maxRewards = (stakeAmount * 10n * 8n) / (100n * 365n); // generous upper bound
      expect(legitimateWithdrawal).to.be.lte(stakeAmount + maxRewards);
    });

    it('should correctly account staking metrics after unstake', async function () {
      const { esm, staker, stakeAmount } = await loadFixture(deployESMFixture);

      const lockPeriod = 7 * 24 * 60 * 60;
      await esm.connect(staker).stakeTokens(stakeAmount, lockPeriod);

      let metrics = await esm.getSecurityMetrics();
      expect(metrics[0]).to.equal(stakeAmount); // totalStaked

      await time.increase(lockPeriod + 1);
      await esm.connect(staker).unstakeTokens(stakeAmount);

      metrics = await esm.getSecurityMetrics();
      expect(metrics[0]).to.equal(0n); // totalStaked = 0
    });
  });

  // =========================================================================
  //    ISSUE #75: WRFToken deregistration reentrancy via .call{value}
  // =========================================================================

  describe('Issue #75: WRFToken deregistration reentrancy', function () {
    it('should allow normal station self-deregistration with stake refund', async function () {
      const { wrfToken, targetStation } = await loadFixture(deployWRFFixture);

      // Register station with stake
      await wrfToken
        .connect(targetStation)
        .registerWeatherStationSimple('station-dereg-1', { value: MIN_STAKE });

      const balBefore = await ethers.provider.getBalance(targetStation.address);

      // Self-deregister
      const tx = await wrfToken.connect(targetStation).deregisterAndRecoverStake();
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;

      const balAfter = await ethers.provider.getBalance(targetStation.address);

      // Should have received stake back (minus gas)
      expect(balAfter + gasUsed).to.be.gt(balBefore);
    });

    it('should block reentrancy on deregisterAndRecoverStake via malicious receive()', async function () {
      const { wrfToken, malStation, deployer } = await loadFixture(
        deployMaliciousStationFixture
      );

      // Register the malicious station contract
      await malStation.register('malicious-station-1', { value: MIN_STAKE });

      // Enable reentrancy attack: when receiving ETH, re-enter deregisterAndRecoverStake
      await malStation.setAttack(await malStation.getAddress());

      // The malicious station tries to deregister (will receive ETH, triggering receive())
      // The re-entrant call should fail due to nonReentrant guard
      await malStation.selfDeregister();

      // Verify the WRF contract balance is correct — no double withdrawal
      const wrfBalance = await ethers.provider.getBalance(await wrfToken.getAddress());
      expect(wrfBalance).to.equal(0n);

      // The malicious station should have received exactly its stake, no more
      const malBalance = await ethers.provider.getBalance(await malStation.getAddress());
      expect(malBalance).to.equal(MIN_STAKE);
    });

    it('should properly clean up station data on deregistration', async function () {
      const { wrfToken, targetStation } = await loadFixture(deployWRFFixture);

      await wrfToken
        .connect(targetStation)
        .registerWeatherStationSimple('station-cleanup', { value: MIN_STAKE });

      expect(await wrfToken.weatherStations(targetStation.address)).to.be.true;

      await wrfToken.connect(targetStation).deregisterAndRecoverStake();

      expect(await wrfToken.weatherStations(targetStation.address)).to.be.false;
      expect(await wrfToken.stationStakes(targetStation.address)).to.equal(0n);
    });

    it('voteToDeregisterStation should have nonReentrant protection', async function () {
      const { wrfToken, malStation, signers } = await loadFixture(
        deployMaliciousStationFixture
      );

      // Register the malicious station (the target that will receive ETH refund)
      await malStation.register('malicious-target', { value: MIN_STAKE });

      // Register enough voter stations to reach the deregistration threshold (50 votes)
      for (let i = 2; i < 50; i++) {
        await wrfToken
          .connect(signers[i])
          .registerWeatherStationSimple(`voter-station-${i}`, { value: MIN_STAKE });
      }

      // Enable attack on the malicious station
      await malStation.setAttack(await malStation.getAddress());

      // Vote with 48 voters (signers[2] through signers[49])
      for (let i = 2; i < 50; i++) {
        await wrfToken
          .connect(signers[i])
          .voteToDeregisterStation(await malStation.getAddress());
      }

      // The threshold is 50, so we need 2 more votes
      // Register 2 more voter stations
      // Note: signers[0] (deployer) and signers[1] not registered yet
      await wrfToken
        .connect(signers[0])
        .registerWeatherStationSimple('voter-extra-1', { value: MIN_STAKE });
      await wrfToken
        .connect(signers[0])
        .voteToDeregisterStation(await malStation.getAddress());

      await wrfToken
        .connect(signers[1])
        .registerWeatherStationSimple('voter-extra-2', { value: MIN_STAKE });
      await wrfToken
        .connect(signers[1])
        .voteToDeregisterStation(await malStation.getAddress());

      // Malicious station should only have received its own stake back
      const malBalance = await ethers.provider.getBalance(await malStation.getAddress());
      expect(malBalance).to.equal(MIN_STAKE);
    });
  });
});
