const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

// =============================================================================
// CommunityGovernance — quorum enforcement (#175)
//
// #175: `totalStakeParticipating` was declared but NEVER assigned, so
// `requiredQuorum = totalStakeParticipating * QUORUM_PERCENTAGE / BASIS_POINTS`
// was always 0 and `finalizeVoting` never enforced quorum — a single voter
// could pass ANY proposal (including treasury spends).
//
// Fix: quorum is now measured as the raw participating stake of a proposal
// against QUORUM_PERCENTAGE (20%) of the total staked supply reported by the
// security engine (`totalSecurityStake`). These tests prove a below-quorum
// proposal is rejected and an at/above-quorum one passes.
// =============================================================================
describe('CommunityGovernance — quorum enforcement (#175)', function () {
  const ONE_DAY = 24 * 60 * 60;
  const VOTING_PERIOD = 7 * ONE_DAY;
  const DEPOSIT = ethers.parseEther('0.1'); // MIN_PROPOSAL_DEPOSIT

  // Enum ProposalStatus { PENDING, ACTIVE, PASSED, EXECUTED, REJECTED, ... }
  const STATUS_PASSED = 2n;
  const STATUS_REJECTED = 4n;

  async function deployFixture() {
    const [proposer, voterB, dummyFairLaunch] = await ethers.getSigners();

    const SE = await ethers.getContractFactory('MockSecurityEngineForGovernance');
    const se = await SE.deploy();
    await se.waitForDeployment();

    const Gov = await ethers.getContractFactory('CommunityGovernance');
    const gov = await Gov.deploy(await se.getAddress(), dummyFairLaunch.address);
    await gov.waitForDeployment();

    return { gov, se, proposer, voterB };
  }

  async function createParamProposal(gov, proposer) {
    const tx = await gov
      .connect(proposer)
      .createParameterProposal(
        'Title',
        'Description',
        'someParam',
        5, // proposedValue within [0,10]
        0,
        10,
        'rationale',
        { value: DEPOSIT }
      );
    await tx.wait();
    // First proposal in a fresh fixture => id 1.
    return 1n;
  }

  it('rejects a below-quorum proposal (participating stake < 20% of total staked)', async function () {
    const { gov, se, proposer } = await loadFixture(deployFixture);

    // Voters stake 100 ETH each, but total staked supply is 2000 ETH.
    // Required quorum = 20% of 2000 = 400 ETH participating stake.
    await se.setStake(proposer.address, ethers.parseEther('100'));
    await se.setTotalSecurityStake(ethers.parseEther('2000'));

    const id = await createParamProposal(gov, proposer);

    // Enter the voting window.
    await time.increase(ONE_DAY + 60);

    // Only the proposer (100 ETH stake) votes → participatingStake = 100 < 400.
    await gov.connect(proposer).vote(id, true);

    // End the voting window and finalize.
    await time.increase(VOTING_PERIOD + 60);
    await expect(gov.finalizeVoting(id)).to.emit(gov, 'ProposalRejected');

    const p = await gov.getProposal(id);
    expect(p.status).to.equal(STATUS_REJECTED);
  });

  it('passes an at/above-quorum proposal with a yes majority', async function () {
    const { gov, se, proposer, voterB } = await loadFixture(deployFixture);

    // Two voters stake 300 ETH each (600 total participating); total staked
    // supply 2000 ETH → required quorum = 400 ETH. 600 >= 400 → quorum met.
    await se.setStake(proposer.address, ethers.parseEther('300'));
    await se.setStake(voterB.address, ethers.parseEther('300'));
    await se.setTotalSecurityStake(ethers.parseEther('2000'));

    const id = await createParamProposal(gov, proposer);

    await time.increase(ONE_DAY + 60);
    await gov.connect(proposer).vote(id, true);
    await gov.connect(voterB).vote(id, true);

    await time.increase(VOTING_PERIOD + 60);
    await expect(gov.finalizeVoting(id)).to.emit(gov, 'ProposalPassed');

    const p = await gov.getProposal(id);
    expect(p.status).to.equal(STATUS_PASSED);
  });

  it('a lone voter can no longer pass a proposal when total staked supply is large', async function () {
    // Regression guard for the core exploit: pre-fix, requiredQuorum was always
    // 0 so this lone below-threshold vote would have PASSED. Now it is rejected.
    const { gov, se, proposer } = await loadFixture(deployFixture);

    await se.setStake(proposer.address, ethers.parseEther('1'));
    await se.setTotalSecurityStake(ethers.parseEther('1000')); // quorum = 200 ETH

    const id = await createParamProposal(gov, proposer);
    await time.increase(ONE_DAY + 60);
    await gov.connect(proposer).vote(id, true);
    await time.increase(VOTING_PERIOD + 60);
    await gov.finalizeVoting(id);

    const p = await gov.getProposal(id);
    expect(p.status).to.equal(STATUS_REJECTED);
  });
});
