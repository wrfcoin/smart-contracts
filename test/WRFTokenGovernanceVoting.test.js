// SPDX-License-Identifier: MIT
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("WRFToken Governance Voting (#68)", function () {
  const REGISTRATION_STAKE = ethers.parseEther("0.01");
  const PROPOSAL_THRESHOLD = ethers.parseEther("1000");
  const QUORUM = ethers.parseEther("10000");
  const VOTING_PERIOD = 7 * 24 * 60 * 60; // 7 days in seconds

  async function deployFixture() {
    const [deployer, station1, station2, station3, nonStation] =
      await ethers.getSigners();

    const WRFTokenTestnet = await ethers.getContractFactory("WRFTokenTestnet");
    const testToken = await WRFTokenTestnet.deploy();

    // Register stations using registerWeatherStationSimple (permissionless)
    for (const station of [station1, station2, station3]) {
      await testToken
        .connect(station)
        .registerWeatherStationSimple("station-" + station.address.slice(2, 8), {
          value: REGISTRATION_STAKE,
        });
    }

    // Mint tokens for voting power via testnet helper
    await testToken.mintForTesting(station1.address, PROPOSAL_THRESHOLD * 2n);
    await testToken.mintForTesting(station2.address, QUORUM);
    await testToken.mintForTesting(station3.address, ethers.parseEther("500"));

    // Delegate voting power to self (required for ERC20Votes)
    await testToken.connect(station1).delegate(station1.address);
    await testToken.connect(station2).delegate(station2.address);
    await testToken.connect(station3).delegate(station3.address);

    // Mine a block so that getPastVotes (snapshot = block.timestamp - 1) sees delegations
    await ethers.provider.send("evm_mine", []);

    return { testToken, deployer, station1, station2, station3, nonStation };
  }

  describe("createProposal", function () {
    it("should create a proposal when station has sufficient voting power", async function () {
      const { testToken, station1 } = await loadFixture(deployFixture);

      const tx = await testToken
        .connect(station1)
        .createProposal("Increase rewards", "Raise weather reward rate to 20 WRF");

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      expect(event).to.not.be.undefined;

      const proposalId = event.args.proposalId;
      const proposal = await testToken.getProposal(proposalId);
      expect(proposal.proposer).to.equal(station1.address);
      expect(proposal.title).to.equal("Increase rewards");
      expect(proposal.executed).to.be.false;
      expect(proposal.canceled).to.be.false;
    });

    it("should revert if voting power is below threshold", async function () {
      const { testToken, station3 } = await loadFixture(deployFixture);

      // station3 has only 500 WRF, threshold is 1000
      await expect(
        testToken
          .connect(station3)
          .createProposal("Low power proposal", "Should fail")
      ).to.be.revertedWith("WRFToken: insufficient voting power to propose");
    });

    it("should revert for non-station callers", async function () {
      const { testToken, nonStation } = await loadFixture(deployFixture);

      await expect(
        testToken.connect(nonStation).createProposal("Bad", "Nope")
      ).to.be.revertedWith("WRFToken: Not a registered weather station");
    });

    it("should revert for empty title", async function () {
      const { testToken, station1 } = await loadFixture(deployFixture);

      await expect(
        testToken.connect(station1).createProposal("", "No title")
      ).to.be.revertedWith("WRFToken: empty title");
    });
  });

  describe("voteOnProposal", function () {
    async function createProposalFixture() {
      const fixture = await deployFixture();
      const { testToken, station1 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("Test proposal", "For testing");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      return { ...fixture, proposalId };
    }

    it("should record a yes vote with correct weight", async function () {
      const { testToken, station2, proposalId } =
        await loadFixture(createProposalFixture);

      const votingPower = await testToken.getVotes(station2.address);

      await expect(
        testToken.connect(station2).voteOnProposal(proposalId, true)
      ).to.emit(testToken, "ProposalVote");

      const proposal = await testToken.getProposal(proposalId);
      expect(proposal.yesVotes).to.equal(votingPower);
      expect(proposal.noVotes).to.equal(0n);
    });

    it("should record a no vote with correct weight", async function () {
      const { testToken, station2, proposalId } =
        await loadFixture(createProposalFixture);

      const votingPower = await testToken.getVotes(station2.address);

      await testToken.connect(station2).voteOnProposal(proposalId, false);

      const proposal = await testToken.getProposal(proposalId);
      expect(proposal.noVotes).to.equal(votingPower);
    });

    it("should prevent double voting", async function () {
      const { testToken, station2, proposalId } =
        await loadFixture(createProposalFixture);

      await testToken.connect(station2).voteOnProposal(proposalId, true);

      await expect(
        testToken.connect(station2).voteOnProposal(proposalId, false)
      ).to.be.revertedWith("WRFToken: already voted");
    });

    it("should revert after voting period ends", async function () {
      const { testToken, station2, proposalId } =
        await loadFixture(createProposalFixture);

      await time.increase(VOTING_PERIOD + 1);

      await expect(
        testToken.connect(station2).voteOnProposal(proposalId, true)
      ).to.be.revertedWith("WRFToken: voting period ended");
    });

    it("should revert for non-existent proposal", async function () {
      const { testToken, station2 } =
        await loadFixture(createProposalFixture);

      const fakeId = ethers.keccak256(ethers.toUtf8Bytes("nonexistent"));
      await expect(
        testToken.connect(station2).voteOnProposal(fakeId, true)
      ).to.be.revertedWith("WRFToken: proposal does not exist");
    });

    it("should revert for canceled proposal", async function () {
      const { testToken, station1, station2, proposalId } =
        await loadFixture(createProposalFixture);

      await testToken.connect(station1).cancelProposal(proposalId);

      await expect(
        testToken.connect(station2).voteOnProposal(proposalId, true)
      ).to.be.revertedWith("WRFToken: proposal canceled");
    });

    it("should revert when voting on an executed proposal", async function () {
      const { testToken, station1, station2, station3, proposalId } =
        await loadFixture(createProposalFixture);

      // station1 + station2 vote yes to exceed quorum
      await testToken.connect(station1).voteOnProposal(proposalId, true);
      await testToken.connect(station2).voteOnProposal(proposalId, true);

      // Advance past voting period and execute
      await time.increase(VOTING_PERIOD + 1);
      await testToken.connect(station1).executeProposal(proposalId);

      // station3 tries to vote on the executed proposal — should revert
      // (voting period has also ended, but executed check is the defensive guard)
      await expect(
        testToken.connect(station3).voteOnProposal(proposalId, true)
      ).to.be.revertedWith("WRFToken: voting period ended");
    });
  });

  describe("executeProposal", function () {
    async function votedProposalFixture() {
      const fixture = await deployFixture();
      const { testToken, station1, station2 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("Execute me", "Should pass");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      // Both vote yes — combined power exceeds QUORUM
      await testToken.connect(station1).voteOnProposal(proposalId, true);
      await testToken.connect(station2).voteOnProposal(proposalId, true);

      return { ...fixture, proposalId };
    }

    it("should execute a passed proposal after voting period", async function () {
      const { testToken, station1, proposalId } =
        await loadFixture(votedProposalFixture);

      await time.increase(VOTING_PERIOD + 1);

      await expect(
        testToken.connect(station1).executeProposal(proposalId)
      ).to.emit(testToken, "ProposalExecuted").withArgs(proposalId);

      const proposal = await testToken.getProposal(proposalId);
      expect(proposal.executed).to.be.true;
    });

    it("should revert if voting period not ended", async function () {
      const { testToken, station1, proposalId } =
        await loadFixture(votedProposalFixture);

      await expect(
        testToken.connect(station1).executeProposal(proposalId)
      ).to.be.revertedWith("WRFToken: voting period not ended");
    });

    it("should revert if quorum not reached", async function () {
      const fixture = await deployFixture();
      const { testToken, station1, station3 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("No quorum", "Only small votes");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      // Only station3 votes (500 WRF, well under 10000 quorum)
      // station3 has no voting power since 500 < threshold... but they can still vote
      // Actually station3 does have voting power (500 WRF delegated to self)
      // We need station1 to vote (2000 WRF) — still under 10000 quorum
      await testToken.connect(station1).voteOnProposal(proposalId, true);

      await time.increase(VOTING_PERIOD + 1);

      await expect(
        testToken.connect(station1).executeProposal(proposalId)
      ).to.be.revertedWith("WRFToken: quorum not reached");
    });

    it("should revert if proposal did not pass (more no votes)", async function () {
      const fixture = await deployFixture();
      const { testToken, station1, station2 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("Rejected", "Will fail");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      // station1 votes yes (2000), station2 votes no (10000) — quorum met, but fails
      await testToken.connect(station1).voteOnProposal(proposalId, true);
      await testToken.connect(station2).voteOnProposal(proposalId, false);

      await time.increase(VOTING_PERIOD + 1);

      await expect(
        testToken.connect(station1).executeProposal(proposalId)
      ).to.be.revertedWith("WRFToken: proposal did not pass");
    });

    it("should revert on double execution", async function () {
      const { testToken, station1, proposalId } =
        await loadFixture(votedProposalFixture);

      await time.increase(VOTING_PERIOD + 1);
      await testToken.connect(station1).executeProposal(proposalId);

      await expect(
        testToken.connect(station1).executeProposal(proposalId)
      ).to.be.revertedWith("WRFToken: already executed");
    });
  });

  describe("cancelProposal", function () {
    it("should allow proposer to cancel", async function () {
      const fixture = await deployFixture();
      const { testToken, station1 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("Cancel me", "Will be canceled");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      await expect(
        testToken.connect(station1).cancelProposal(proposalId)
      ).to.emit(testToken, "ProposalCanceled").withArgs(proposalId);

      const proposal = await testToken.getProposal(proposalId);
      expect(proposal.canceled).to.be.true;
    });

    it("should revert if caller is not the proposer", async function () {
      const fixture = await deployFixture();
      const { testToken, station1, station2 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("Not yours", "Nope");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      await expect(
        testToken.connect(station2).cancelProposal(proposalId)
      ).to.be.revertedWith("WRFToken: not the proposer");
    });

    it("should revert when canceling after voting period ends", async function () {
      const fixture = await deployFixture();
      const { testToken, station1 } = fixture;

      const tx = await testToken
        .connect(station1)
        .createProposal("Late cancel", "Should not be cancelable after deadline");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      // Advance past the voting period
      await time.increase(VOTING_PERIOD + 1);

      await expect(
        testToken.connect(station1).cancelProposal(proposalId)
      ).to.be.revertedWith("WRFToken: cannot cancel after voting period");
    });
  });

  describe("tie scenario", function () {
    it("should not pass when yes and no votes are equal (tie fails)", async function () {
      const fixture = await deployFixture();
      const { testToken, station1, station2 } = fixture;

      // Mint equal amounts so station1 and station2 have same voting power
      // station1 has 2000 WRF, station2 has 10000 WRF — not equal
      // Mint additional tokens to station1 to match station2
      await testToken.mintForTesting(station1.address, ethers.parseEther("8000"));
      // Re-delegate to pick up new balance
      await testToken.connect(station1).delegate(station1.address);
      await ethers.provider.send("evm_mine", []);

      const tx = await testToken
        .connect(station1)
        .createProposal("Tie proposal", "Equal votes should fail");
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (l) => l.fragment && l.fragment.name === "ProposalCreated"
      );
      const proposalId = event.args.proposalId;

      // station1 votes yes (10000 WRF), station2 votes no (10000 WRF) — tie
      await testToken.connect(station1).voteOnProposal(proposalId, true);
      await testToken.connect(station2).voteOnProposal(proposalId, false);

      const proposal = await testToken.getProposal(proposalId);
      expect(proposal.yesVotes).to.equal(proposal.noVotes);

      await time.increase(VOTING_PERIOD + 1);

      // Tie should fail because the contract uses strict > (not >=)
      await expect(
        testToken.connect(station1).executeProposal(proposalId)
      ).to.be.revertedWith("WRFToken: proposal did not pass");
    });
  });
});
