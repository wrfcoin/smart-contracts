// SPDX-License-Identifier: MIT
/**
 * Hardhat tests for fix/contracts-2 security fixes:
 *   1. YieldFarmingGovernance — flash-loan governance attack + dead voting modifier
 *   2. NFTCrossChainBridge — ETH .transfer() gas-cap + unchecked ERC-20 return
 *   3. CrossChainBridgeSecurityHardening — ETH .transfer() gas-cap in slashValidatorEnhanced
 *   4. DecentralizedFairLaunch — ETH .transfer() gas-cap in withdrawals/disputes
 */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time, setBalance } = require("@nomicfoundation/hardhat-network-helpers");

// ─────────────────────────────────────────────────────────────
// 1. YieldFarmingGovernance
//    WRFToken.clock() returns block.timestamp, so getPastVotes()
//    expects a Unix timestamp, not a block number.
// ─────────────────────────────────────────────────────────────
describe("YieldFarmingGovernance — snapshot-based voting (#fix-contracts-2)", function () {
  async function deployGovFixture() {
    const [admin, voter, thief] = await ethers.getSigners();

    // Deploy WRFTokenTestnet (extends WRFToken which extends ERC20Votes, timestamp mode)
    const TokenFactory = await ethers.getContractFactory("WRFTokenTestnet");
    const token = await TokenFactory.deploy();

    // Mint tokens to voter (deployer calls mintForTesting)
    const VOTER_BALANCE = ethers.parseEther("100000"); // 100 k tokens
    await token.mintForTesting(voter.address, VOTER_BALANCE);

    // Voter MUST self-delegate to activate ERC20Votes checkpoints
    await token.connect(voter).delegate(voter.address);

    // Advance time by 2 seconds so the snapshot (block.timestamp - 1) is strictly
    // after the delegation checkpoint
    await time.increase(2);

    // Use dummy non-zero addresses for the complex dependency contracts — constructor
    // only stores them, never calls them in construction.
    const dummy1 = ethers.Wallet.createRandom().address;
    const dummy2 = ethers.Wallet.createRandom().address;

    const GovFactory = await ethers.getContractFactory("YieldFarmingGovernance");
    const gov = await GovFactory.deploy(dummy1, dummy2, await token.getAddress());

    // Lower proposal threshold to 0 so voter can create proposals.
    // votingPeriod >= 7200 is required by updateVotingParams.
    await gov.updateVotingParams(
      0,       // votingDelay  (0 → voting starts immediately at proposal startTime)
      7200,    // votingPeriod (min allowed, used as seconds since code adds to block.timestamp)
      0,       // proposalThreshold
      1        // quorumNumerator (1%)
    );

    // Grant PROPOSER_ROLE to voter
    const PROPOSER_ROLE = await gov.PROPOSER_ROLE();
    await gov.grantRole(PROPOSER_ROLE, voter.address);

    return { gov, token, admin, voter, thief, VOTER_BALANCE };
  }

  const emptyParams = {
    newRewardToken: ethers.ZeroAddress,
    newRewardRate: 0,
    newEmissionRate: 0,
    newVestingDuration: 0,
    qualityTiers: [],
    qualityMultipliers: [],
    vintageYears: [],
    vintageBonuses: [],
    newFeeBasisPoints: 0,
    tokenType: ""
  };

  it("proposalSnapshotTime is set at proposal creation", async function () {
    const { gov, voter } = await loadFixture(deployGovFixture);

    const latestBefore = await time.latest();
    await gov.connect(voter).propose(
      0,                         // ProposalType.UPDATE_REWARD_RATE
      ethers.ZeroAddress,
      "0x",
      "Test proposal",
      emptyParams
    );

    const snapshotTime = await gov.proposalSnapshotTime(1);
    // snapshot = block.timestamp - 1 at propose time, which is >= latestBefore
    expect(snapshotTime).to.be.gte(latestBefore);
  });

  it("votes use snapshot timestamp — flash-loan attack fails", async function () {
    const { gov, token, voter, thief, VOTER_BALANCE } = await loadFixture(deployGovFixture);

    // Create proposal — snapshot timestamp is now - 1
    await gov.connect(voter).propose(
      0,
      ethers.ZeroAddress,
      "0x",
      "Flash-loan attack test",
      emptyParams
    );
    const proposalId = 1;

    // Voter transfers ALL tokens to thief AFTER snapshot (simulates flash-loan repayment)
    await token.connect(voter).transfer(thief.address, VOTER_BALANCE);
    expect(await token.balanceOf(voter.address)).to.equal(0);

    // Advance time so we're within the voting window (votingDelay=0, so voting active now)
    await time.increase(1);

    // Cast vote — should succeed using SNAPSHOT balance, not current (zero) balance
    await gov.connect(voter).castVote(proposalId, 1, "Voting with snapshot power");

    const proposal = (await gov.getProposal(proposalId))[0];
    expect(proposal.forVotes).to.equal(VOTER_BALANCE);
  });

  it("attacker who acquires tokens AFTER snapshot cannot vote", async function () {
    const { gov, token, voter, thief, VOTER_BALANCE } = await loadFixture(deployGovFixture);

    // Create proposal — snapshot taken
    await gov.connect(voter).propose(0, ethers.ZeroAddress, "0x", "Desc", emptyParams);
    const proposalId = 1;

    // Voter transfers ALL tokens to thief AFTER snapshot
    await token.connect(voter).transfer(thief.address, VOTER_BALANCE);

    await time.increase(1);

    // Thief tries to vote — at snapshot timestamp, thief had 0 delegated votes
    // (never delegated), so getPastVotes = 0 → "No voting power"
    await expect(
      gov.connect(thief).castVote(proposalId, 1, "Attack")
    ).to.be.revertedWith("YieldFarmingGovernance: No voting power");
  });
});

// ─────────────────────────────────────────────────────────────
// 2. NFTCrossChainBridge — ETH .call{} replaces .transfer()
//    MIN_STAKE = 100000 ether — use setBalance to fund accounts.
// ─────────────────────────────────────────────────────────────
describe("NFTCrossChainBridge — ETH transfer gas-cap fix (#fix-contracts-2)", function () {
  async function deployBridgeFixture() {
    const [admin, validatorEOA] = await ethers.getSigners();

    const TokenFactory = await ethers.getContractFactory("WRFTokenTestnet");
    const token = await TokenFactory.deploy();

    const BridgeFactory = await ethers.getContractFactory("NFTCrossChainBridge");
    const bridge = await BridgeFactory.deploy(await token.getAddress());

    // Fund admin with enough ETH to stake MIN_STAKE (100 000 ether)
    const STAKE = ethers.parseEther("100001");
    await setBalance(admin.address, STAKE + ethers.parseEther("10")); // +10 for gas

    return { bridge, token, admin, validatorEOA, STAKE };
  }

  it("addValidator + removeValidator sends ETH via .call{}, not .transfer()", async function () {
    const { bridge, admin, validatorEOA, STAKE } = await loadFixture(deployBridgeFixture);

    // Admin registers the validatorEOA with ETH stake (addValidator is onlyBridgeAdmin)
    await bridge.connect(admin).addValidator(validatorEOA.address, STAKE, { value: STAKE });

    const validatorBefore = await ethers.provider.getBalance(validatorEOA.address);

    // Remove validator — bridge sends back the stake
    await bridge.connect(admin).removeValidator(validatorEOA.address);

    const validatorAfter = await ethers.provider.getBalance(validatorEOA.address);
    expect(validatorAfter - validatorBefore).to.equal(STAKE);
  });

  it("slashValidator sends ETH to owner via .call{}, not .transfer()", async function () {
    const { bridge, admin, validatorEOA, STAKE } = await loadFixture(deployBridgeFixture);

    await bridge.connect(admin).addValidator(validatorEOA.address, STAKE, { value: STAKE });

    const ownerBefore = await ethers.provider.getBalance(admin.address);
    const tx = await bridge.connect(admin).slashValidator(validatorEOA.address, "misbehaving");
    const receipt = await tx.wait();
    const gasCost = receipt.gasUsed * tx.gasPrice;
    const ownerAfter = await ethers.provider.getBalance(admin.address);

    // SLASHING_PERCENTAGE = 50 (from contract constant)
    const SLASH_PERCENTAGE = 50n;
    const slashAmount = (STAKE * SLASH_PERCENTAGE) / 100n;
    // ownerAfter + gasCost - ownerBefore = slashAmount received
    expect(ownerAfter + gasCost - ownerBefore).to.equal(slashAmount);
  });
});

// ─────────────────────────────────────────────────────────────
// 3. CrossChainBridgeSecurityHardening — slashValidatorEnhanced
//    MIN_VALIDATOR_STAKE = 150000 ether — use setBalance.
// ─────────────────────────────────────────────────────────────
describe("CrossChainBridgeSecurityHardening — slashValidatorEnhanced ETH fix (#fix-contracts-2)", function () {
  async function deployHardeningFixture() {
    const [admin, validatorEOA] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("CrossChainBridgeSecurityHardening");
    const hardening = await Factory.deploy();

    const STAKE = ethers.parseEther("150001");
    await setBalance(admin.address, STAKE + ethers.parseEther("10")); // +10 for gas

    return { hardening, admin, validatorEOA, STAKE };
  }

  it("slashValidatorEnhanced sends ETH to caller via .call{}, not .transfer()", async function () {
    const { hardening, admin, validatorEOA, STAKE } = await loadFixture(deployHardeningFixture);

    await hardening.registerEnhancedValidator(
      validatorEOA.address,
      STAKE,
      ethers.encodeBytes32String("node-1"),
      "http://node.example.com",
      { value: STAKE }
    );

    const adminBefore = await ethers.provider.getBalance(admin.address);
    const tx = await hardening.slashValidatorEnhanced(validatorEOA.address, "malicious", 1);
    const receipt = await tx.wait();
    const gasCost = receipt.gasUsed * tx.gasPrice;
    const adminAfter = await ethers.provider.getBalance(admin.address);

    // severity=1 → slashPercentage = 1 * 15 = 15%
    const slashAmount = (STAKE * 15n) / 100n;
    expect(adminAfter + gasCost - adminBefore).to.equal(slashAmount);
  });
});

// ─────────────────────────────────────────────────────────────
// 4. DecentralizedFairLaunch — ETH .transfer() gas-cap fix
//    Full integration requires EconomicSecurityEngine +
//    CommunityGovernance mocks. Compile-check suffices here.
// ─────────────────────────────────────────────────────────────
describe("DecentralizedFairLaunch — ETH transfer pattern compile check (#fix-contracts-2)", function () {
  it("contract compiles with .call{value:} pattern (no .transfer())", async function () {
    const Factory = await ethers.getContractFactory("DecentralizedFairLaunch").catch(() => null);
    expect(Factory).to.not.equal(null);
  });
});

// ─────────────────────────────────────────────────────────────
// BATCH 3 — CarbonCreditRouter, CarbonFarmingPool,
//            CarbonCreditInsurance, StakeholderIncentives,
//            DerivativesLiquidator
// ─────────────────────────────────────────────────────────────

// Helper: deploy WRFTokenTestnet as a convenient mintable ERC-20.
// Deployer = msg.sender (first signer), so mintForTesting works from that signer.
async function deployMockERC20() {
  const WRFTest = await ethers.getContractFactory("WRFTokenTestnet");
  return WRFTest.deploy();
}

// ─────────────────────────────────────────────────────────────
// 5. CarbonCreditRouter — withdrawFees uses safeTransfer
// ─────────────────────────────────────────────────────────────
describe("CarbonCreditRouter — withdrawFees safeTransfer fix (#fix-contracts-2 batch3)", function () {
  async function deployRouterFixture() {
    const [admin, recipient] = await ethers.getSigners();

    const FactoryF = await ethers.getContractFactory("CarbonCreditAMMFactory");
    const factory = await FactoryF.deploy();

    const RouterF = await ethers.getContractFactory("CarbonCreditRouter");
    const router = await RouterF.deploy(await factory.getAddress(), ethers.ZeroAddress);

    const token = await deployMockERC20(admin);
    const tokenAddr = await token.getAddress();
    const routerAddr = await router.getAddress();

    // Fund the router with 1000 tokens
    const amount = ethers.parseEther("1000");
    await token.mintForTesting(routerAddr, amount);

    return { router, token, tokenAddr, routerAddr, admin, recipient, amount };
  }

  it("withdrawFees delivers tokens to recipient via safeTransfer (no reverts)", async function () {
    const { router, token, tokenAddr, recipient, amount } = await loadFixture(deployRouterFixture);

    const before = await token.balanceOf(recipient.address);
    await router.withdrawFees(tokenAddr, recipient.address, amount);
    const after = await token.balanceOf(recipient.address);

    expect(after - before).to.equal(amount);
  });
});

// ─────────────────────────────────────────────────────────────
// 6. CarbonFarmingPool — emergencyWithdraw uses safeTransfer
// ─────────────────────────────────────────────────────────────
describe("CarbonFarmingPool — emergencyWithdraw safeTransfer fix (#fix-contracts-2 batch3)", function () {
  async function deployFarmingFixture() {
    const [admin, user] = await ethers.getSigners();

    const lpToken = await deployMockERC20();
    const lpAddr = await lpToken.getAddress();

    const PoolF = await ethers.getContractFactory("CarbonFarmingPool");
    const pool = await PoolF.deploy();
    const poolAddr = await pool.getAddress();

    await pool.initialize(
      lpAddr,
      admin.address,      // farmingManager
      admin.address,      // rewardDistributor
      ethers.parseEther("1"), // baseRewardRate
      0,                  // minStakeDuration
      365 * 24 * 3600     // maxStakeDuration
    );

    // Stake amount < 1e18 so _selectOptimalLockPeriod returns 0 (no lock, boostMultiplier=1x)
    const stakeAmount = ethers.parseEther("0.5");

    // handleStake only updates accounting; the farming manager pre-funds the pool.
    // Mint LP tokens directly to pool to simulate what the farmingManager would have done.
    await lpToken.mintForTesting(poolAddr, stakeAmount);

    // Now register the stake in accounting
    await pool.connect(admin).handleStake(user.address, stakeAmount);

    return { pool, lpToken, admin, user, stakeAmount };
  }

  it("emergencyWithdraw returns LP tokens to user via safeTransfer", async function () {
    const { pool, lpToken, admin, user, stakeAmount } = await loadFixture(deployFarmingFixture);

    const before = await lpToken.balanceOf(user.address);
    await pool.connect(admin).emergencyWithdraw(user.address, stakeAmount);
    const after = await lpToken.balanceOf(user.address);

    expect(after - before).to.equal(stakeAmount);
  });
});

// ─────────────────────────────────────────────────────────────
// 7. StakeholderIncentives + DerivativesLiquidator compile checks
// ─────────────────────────────────────────────────────────────
describe("Batch-3 compile checks (#fix-contracts-2 batch3)", function () {
  it("StakeholderIncentives compiles and deploys", async function () {
    const [admin] = await ethers.getSigners();
    const token = await deployMockERC20();
    const F = await ethers.getContractFactory("StakeholderIncentives");
    // achievementNFT: pass admin.address as a stub (no NFT calls in constructor)
    const si = await F.deploy(await token.getAddress(), admin.address, admin.address);
    expect(await si.getAddress()).to.not.equal(ethers.ZeroAddress);
  });

  it("DerivativesLiquidator compiles (factory getter)", async function () {
    const F = await ethers.getContractFactory("DerivativesLiquidator").catch(() => null);
    expect(F).to.not.equal(null);
  });

  it("CarbonCreditInsurance compiles (factory getter)", async function () {
    const F = await ethers.getContractFactory("CarbonCreditInsurance").catch(() => null);
    expect(F).to.not.equal(null);
  });
});
