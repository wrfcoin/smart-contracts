const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('WeatherDAOGrants', function () {
  let grants, mockToken;
  let owner, daoAdmin, oracle, proposer, voter1, voter2, treasury, other;

  const VOTING_PERIOD   = 7 * 24 * 60 * 60; // 7 days in seconds
  const PROPOSAL_DEPOSIT = ethers.parseEther('100');
  const GRANT_AMOUNT    = ethers.parseEther('1000');

  const MILESTONE_DESCS    = ['Deploy 10 stations', 'Submit first 1 000 readings'];
  const MILESTONE_AMOUNTS  = [ethers.parseEther('600'), ethers.parseEther('400')];

  async function mintAndApprove(signer, amount) {
    await mockToken.mintForTesting(signer.address, amount);
    await mockToken.connect(signer).approve(await grants.getAddress(), amount);
  }

  async function fundTreasury(amount) {
    await mintAndApprove(owner, amount);
    await grants.connect(owner).deposit(amount);
  }

  async function submitProposal(signer) {
    await mintAndApprove(signer, PROPOSAL_DEPOSIT);
    return grants.connect(signer).submitProposal(
      'Deploy stations in Sahel',
      'Qm123',
      'Sub-Saharan Africa',
      GRANT_AMOUNT,
      MILESTONE_DESCS,
      MILESTONE_AMOUNTS,
    );
  }

  beforeEach(async function () {
    [owner, daoAdmin, oracle, proposer, voter1, voter2, treasury, other] =
      await ethers.getSigners();

    // Use the existing timestamp-clock IVotes token; a plain ERC-20 cannot vote.
    const MockToken = await ethers.getContractFactory('WRFTokenTestnet');
    mockToken = await MockToken.deploy();
    await mockToken.waitForDeployment();

    const Factory = await ethers.getContractFactory('WeatherDAOGrants');
    grants = await Factory.deploy(
      await mockToken.getAddress(),
      daoAdmin.address,
      oracle.address,
    );
    await grants.waitForDeployment();

    // Fund the treasury
    await fundTreasury(ethers.parseEther('10000'));
  });

  // -------------------------------------------------------------------------
  // Deposit
  // -------------------------------------------------------------------------
  describe('deposit', function () {
    it('increases treasuryBalance', async function () {
      const prev = await grants.treasuryBalance();
      await fundTreasury(ethers.parseEther('500'));
      expect(await grants.treasuryBalance()).to.equal(prev + ethers.parseEther('500'));
    });

    it('emits Deposited', async function () {
      await mintAndApprove(other, ethers.parseEther('50'));
      await expect(grants.connect(other).deposit(ethers.parseEther('50')))
        .to.emit(grants, 'Deposited');
    });

    it('reverts for zero amount', async function () {
      await expect(grants.connect(other).deposit(0n))
        .to.be.revertedWithCustomError(grants, 'InvalidAmount');
    });
  });

  // -------------------------------------------------------------------------
  // submitProposal
  // -------------------------------------------------------------------------
  describe('submitProposal', function () {
    it('creates a proposal and emits event', async function () {
      await expect(submitProposal(proposer))
        .to.emit(grants, 'ProposalSubmitted')
        .withArgs(1n, proposer.address, 'Deploy stations in Sahel', GRANT_AMOUNT);
    });

    it('stores proposal data correctly', async function () {
      await submitProposal(proposer);
      const p = await grants.getProposal(1n);
      expect(p.proposer).to.equal(proposer.address);
      expect(p.totalAmount).to.equal(GRANT_AMOUNT);
      expect(p.status).to.equal(0n); // Active
      expect(p.milestoneCount).to.equal(2n);
    });

    it('reserves grant amount from treasury', async function () {
      const before = await grants.treasuryBalance();
      await submitProposal(proposer);
      expect(await grants.treasuryBalance()).to.equal(before - GRANT_AMOUNT);
    });

    it('stores milestones correctly', async function () {
      await submitProposal(proposer);
      const m0 = await grants.getMilestone(1n, 0n);
      expect(m0.description).to.equal(MILESTONE_DESCS[0]);
      expect(m0.releaseAmount).to.equal(MILESTONE_AMOUNTS[0]);
      expect(m0.verified).to.be.false;
      expect(m0.released).to.be.false;
    });

    it('reverts when treasury is insufficient', async function () {
      // Request 40 000 WRF (within MAX_GRANT_AMOUNT=50 000) but treasury only
      // has ~9 000 WRF left after the first GRANT_AMOUNT (1 000) was reserved.
      // We submit a first proposal to drain most of the treasury first.
      await submitProposal(proposer); // reserves 1 000 WRF from 10 000 → 9 000 left

      const large = ethers.parseEther('40000');
      await mintAndApprove(proposer, PROPOSAL_DEPOSIT);
      await expect(
        grants.connect(proposer).submitProposal(
          'Big grant', 'Qm', 'Global', large,
          MILESTONE_DESCS, [ethers.parseEther('20000'), ethers.parseEther('20000')],
        ),
      ).to.be.revertedWithCustomError(grants, 'TreasuryInsufficient');
    });

    it('reverts when milestone sum mismatches total', async function () {
      await mintAndApprove(proposer, PROPOSAL_DEPOSIT);
      await expect(
        grants.connect(proposer).submitProposal(
          'Bad sum', 'Qm', 'Africa', GRANT_AMOUNT,
          MILESTONE_DESCS,
          [ethers.parseEther('400'), ethers.parseEther('400')], // sum != 1000
        ),
      ).to.be.revertedWithCustomError(grants, 'MilestoneSumMismatch');
    });
  });

  // -------------------------------------------------------------------------
  // Voting
  // -------------------------------------------------------------------------
  describe('vote', function () {
    beforeEach(async function () {
      // Establish delegated voting checkpoints before proposal creation.
      await mockToken.mintForTesting(voter1.address, ethers.parseEther('100'));  // sqrt = 10
      await mockToken.mintForTesting(voter2.address, ethers.parseEther('400'));  // sqrt = 20
      await mockToken.connect(voter1).delegate(voter1.address);
      await mockToken.connect(voter2).delegate(voter2.address);
      await time.increase(1);
      await submitProposal(proposer);
    });

    it('records vote weight as floor(sqrt(balance))', async function () {
      await grants.connect(voter1).vote(1n, true);
      const p = await grants.getProposal(1n);
      // sqrt(100 WRF in wei) — the weight is over the raw balance in wei units
      expect(p.votesFor).to.equal(10_000_000_000n);
    });

    it('uses the proposal checkpoint after balances change', async function () {
      await mockToken.connect(voter1).transfer(voter2.address, ethers.parseEther('100'));
      await grants.connect(voter1).vote(1n, true);
      await grants.connect(voter2).vote(1n, false);
      const p = await grants.getProposal(1n);
      expect(p.votesFor).to.equal(10_000_000_000n);
      expect(p.votesAgainst).to.equal(20_000_000_000n);
    });

    it('reverts on double vote', async function () {
      await grants.connect(voter1).vote(1n, true);
      await expect(grants.connect(voter1).vote(1n, false))
        .to.be.revertedWithCustomError(grants, 'AlreadyVoted');
    });

    it('reverts after voting period ends', async function () {
      await time.increase(VOTING_PERIOD + 1);
      await expect(grants.connect(voter1).vote(1n, true))
        .to.be.revertedWithCustomError(grants, 'VotingClosed');
    });

    it('tracks hasVoted', async function () {
      expect(await grants.hasVoted(1n, voter1.address)).to.be.false;
      await grants.connect(voter1).vote(1n, true);
      expect(await grants.hasVoted(1n, voter1.address)).to.be.true;
    });
  });

  // -------------------------------------------------------------------------
  // executeProposal
  // -------------------------------------------------------------------------
  describe('executeProposal', function () {
    beforeEach(async function () {
      await submitProposal(proposer);
      await time.increase(VOTING_PERIOD + 1);
    });

    it('approves and sets status to Approved', async function () {
      await expect(grants.connect(daoAdmin).executeProposal(1n, true))
        .to.emit(grants, 'ProposalApproved').withArgs(1n, daoAdmin.address);
      const p = await grants.getProposal(1n);
      expect(p.status).to.equal(1n); // Approved
    });

    it('rejects, restores treasury, and refunds deposit', async function () {
      const treasuryBefore = await grants.treasuryBalance();
      const depositorBefore = await mockToken.balanceOf(proposer.address);

      await expect(grants.connect(daoAdmin).executeProposal(1n, false))
        .to.emit(grants, 'ProposalRejected').withArgs(1n, daoAdmin.address);

      expect(await grants.treasuryBalance()).to.equal(treasuryBefore + GRANT_AMOUNT);
      expect(await mockToken.balanceOf(proposer.address))
        .to.equal(depositorBefore + PROPOSAL_DEPOSIT);
    });

    it('reverts if voting period still open', async function () {
      // Submit a fresh proposal whose voting hasn't ended
      await mintAndApprove(proposer, PROPOSAL_DEPOSIT);
      await grants.connect(proposer).submitProposal(
        'Another grant', 'Qm', 'Asia', GRANT_AMOUNT,
        MILESTONE_DESCS, MILESTONE_AMOUNTS,
      );
      await expect(grants.connect(daoAdmin).executeProposal(2n, true))
        .to.be.revertedWithCustomError(grants, 'VotingStillOpen');
    });

    it('reverts for non-DAO-admin', async function () {
      await expect(grants.connect(other).executeProposal(1n, true)).to.be.revertedWithCustomError(grants, 'AccessControlUnauthorizedAccount').withArgs(other.address, await grants.DAO_ADMIN_ROLE());
    });
  });

  // -------------------------------------------------------------------------
  // cancelProposal
  // -------------------------------------------------------------------------
  describe('cancelProposal', function () {
    beforeEach(async function () {
      await submitProposal(proposer);
    });

    it('cancels and returns grant funds (not deposit)', async function () {
      const treasuryBefore = await grants.treasuryBalance();
      await expect(grants.connect(proposer).cancelProposal(1n))
        .to.emit(grants, 'ProposalCancelled').withArgs(1n, proposer.address);
      expect(await grants.treasuryBalance()).to.equal(treasuryBefore + GRANT_AMOUNT);
    });

    it('reverts for non-proposer', async function () {
      await expect(grants.connect(other).cancelProposal(1n))
        .to.be.revertedWithCustomError(grants, 'NotProposer');
    });

    it('reverts after voting ends', async function () {
      await time.increase(VOTING_PERIOD + 1);
      await expect(grants.connect(proposer).cancelProposal(1n))
        .to.be.revertedWithCustomError(grants, 'VotingClosed');
    });
  });

  // -------------------------------------------------------------------------
  // Milestone verification + release
  // -------------------------------------------------------------------------
  describe('milestone flow', function () {
    beforeEach(async function () {
      await submitProposal(proposer);
      await time.increase(VOTING_PERIOD + 1);
      await grants.connect(daoAdmin).executeProposal(1n, true);
    });

    it('oracle verifies a milestone', async function () {
      await expect(grants.connect(oracle).verifyMilestone(1n, 0n))
        .to.emit(grants, 'MilestoneVerified').withArgs(1n, 0n, oracle.address);
      const m = await grants.getMilestone(1n, 0n);
      expect(m.verified).to.be.true;
    });

    it('releases funds after verification', async function () {
      await grants.connect(oracle).verifyMilestone(1n, 0n);
      const before = await mockToken.balanceOf(proposer.address);
      await expect(grants.connect(other).releaseMilestone(1n, 0n))
        .to.emit(grants, 'MilestoneReleased').withArgs(1n, 0n, MILESTONE_AMOUNTS[0]);
      expect(await mockToken.balanceOf(proposer.address))
        .to.equal(before + MILESTONE_AMOUNTS[0]);
    });

    it('marks proposal Completed and refunds deposit when all milestones released', async function () {
      const depositorBefore = await mockToken.balanceOf(proposer.address);
      await grants.connect(oracle).verifyMilestone(1n, 0n);
      await grants.connect(other).releaseMilestone(1n, 0n);
      await grants.connect(oracle).verifyMilestone(1n, 1n);
      await grants.connect(other).releaseMilestone(1n, 1n);

      const p = await grants.getProposal(1n);
      expect(p.status).to.equal(3n); // Completed
      // Proposer got both tranches + deposit back
      expect(await mockToken.balanceOf(proposer.address))
        .to.equal(depositorBefore + GRANT_AMOUNT + PROPOSAL_DEPOSIT);
    });

    it('reverts release before verification', async function () {
      await expect(grants.connect(other).releaseMilestone(1n, 0n))
        .to.be.revertedWithCustomError(grants, 'MilestoneNotVerified');
    });

    it('reverts double-release', async function () {
      await grants.connect(oracle).verifyMilestone(1n, 0n);
      await grants.connect(other).releaseMilestone(1n, 0n);
      await expect(grants.connect(other).releaseMilestone(1n, 0n))
        .to.be.revertedWithCustomError(grants, 'MilestoneAlreadyReleased');
    });

    it('reverts double-verify', async function () {
      await grants.connect(oracle).verifyMilestone(1n, 0n);
      await expect(grants.connect(oracle).verifyMilestone(1n, 0n))
        .to.be.revertedWithCustomError(grants, 'MilestoneAlreadyVerified');
    });

    it('reverts out-of-range milestone index', async function () {
      await expect(grants.connect(oracle).verifyMilestone(1n, 5n))
        .to.be.revertedWithCustomError(grants, 'InvalidMilestone');
    });
  });

  // -------------------------------------------------------------------------
  // recoverFunds
  // -------------------------------------------------------------------------
  describe('recoverFunds', function () {
    it('allows treasury manager to recover', async function () {
      const before = await mockToken.balanceOf(treasury.address);
      const recover = ethers.parseEther('100');
      await grants.connect(owner).recoverFunds(treasury.address, recover);
      expect(await mockToken.balanceOf(treasury.address)).to.equal(before + recover);
    });

    it('reverts for non-manager', async function () {
      await expect(
        grants.connect(other).recoverFunds(other.address, ethers.parseEther('1')),
      ).to.be.revertedWithCustomError(grants, 'AccessControlUnauthorizedAccount').withArgs(other.address, await grants.TREASURY_MANAGER_ROLE());
    });

    it('reverts when amount exceeds balance', async function () {
      await expect(
        grants.connect(owner).recoverFunds(treasury.address, ethers.parseEther('99999999')),
      ).to.be.revertedWithCustomError(grants, 'TreasuryInsufficient');
    });
  });
});
