'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('GovernanceAnalytics — focused coverage', function () {
  async function deployFixture() {
    const [admin, dataProvider, reporter, outsider] = await ethers.getSigners();

    const GovernanceAnalytics = await ethers.getContractFactory('GovernanceAnalytics');
    const analytics = await GovernanceAnalytics.deploy(admin.address);

    const ANALYTICS_MANAGER_ROLE = await analytics.ANALYTICS_MANAGER_ROLE();
    const DATA_PROVIDER_ROLE = await analytics.DATA_PROVIDER_ROLE();

    return {
      admin,
      dataProvider,
      reporter,
      outsider,
      analytics,
      ANALYTICS_MANAGER_ROLE,
      DATA_PROVIDER_ROLE,
    };
  }

  it('grants bootstrap roles to deployment admin only', async function () {
    const { admin, outsider, analytics } = await loadFixture(deployFixture);

    const DEFAULT_ADMIN_ROLE = await analytics.DEFAULT_ADMIN_ROLE();
    const ANALYTICS_MANAGER_ROLE = await analytics.ANALYTICS_MANAGER_ROLE();

    expect(await analytics.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.equal(true);
    expect(await analytics.hasRole(ANALYTICS_MANAGER_ROLE, admin.address)).to.equal(true);
    expect(await analytics.hasRole(DEFAULT_ADMIN_ROLE, outsider.address)).to.equal(false);
  });

  it('restricts governance analytics ingestion to DATA_PROVIDER_ROLE', async function () {
    const {
      admin,
      dataProvider,
      outsider,
      analytics,
      DATA_PROVIDER_ROLE,
    } = await loadFixture(deployFixture);

    const proposalId = 1n;

    // onlyRole(DATA_PROVIDER_ROLE) — GovernanceAnalytics.sol:327-331.
    await expect(
      analytics.connect(outsider).recordProposal(proposalId, outsider.address, 'governance', 0n)
    )
      .to.be.revertedWithCustomError(analytics, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await analytics.DATA_PROVIDER_ROLE());

    await analytics.connect(admin).grantRole(DATA_PROVIDER_ROLE, dataProvider.address);

    await analytics.connect(dataProvider).recordProposal(proposalId, dataProvider.address, 'governance', 0n);
    const proposalAfter = await analytics.getProposalAnalytics(proposalId);
    expect(proposalAfter.proposer).to.equal(dataProvider.address);
    expect(proposalAfter.category).to.equal('governance');

    await analytics.connect(dataProvider).recordProposalExecution(proposalId, true, true, 900n);
    const proposalExecuted = await analytics.getProposalAnalytics(proposalId);
    expect(proposalExecuted.passed).to.equal(true);
    expect(proposalExecuted.executed).to.equal(true);
    expect(proposalExecuted.executionDelay).to.equal(900n);
  });

  it('binds recordVote to provider role and input constraints', async function () {
    const { admin, dataProvider, outsider, analytics, DATA_PROVIDER_ROLE } = await loadFixture(deployFixture);
    const proposalId = 2n;

    // onlyRole(DATA_PROVIDER_ROLE) nonReentrant — GovernanceAnalytics.sol:267-271.
    await expect(
      analytics.connect(outsider).recordVote(proposalId, outsider.address, 1, 100n)
    )
      .to.be.revertedWithCustomError(analytics, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await analytics.DATA_PROVIDER_ROLE());

    await analytics.connect(admin).grantRole(DATA_PROVIDER_ROLE, dataProvider.address);

    await expect(
      analytics.connect(dataProvider).recordVote(proposalId, ethers.ZeroAddress, 1, 100n)
    ).to.be.revertedWith('GA: Invalid voter address');

    await expect(
      analytics.connect(dataProvider).recordVote(proposalId, outsider.address, 99, 100n)
    ).to.be.revertedWith('GA: Invalid support value');

    await analytics.connect(dataProvider).recordVote(proposalId, outsider.address, 0, 100n);
    const pattern = await analytics.getVotingPattern(outsider.address);
    expect(pattern.totalVotes).to.equal(1n);
    expect(pattern.againstVotes).to.equal(1n);
  });

  it('restricts snapshot calls to analytics manager and enforces cadence', async function () {
    const { admin, outsider, analytics } = await loadFixture(deployFixture);

    await expect(
      analytics.connect(outsider).takeSnapshot()
    ).to.be.revertedWithCustomError(analytics, 'AccessControlUnauthorizedAccount');

    await expect(
      analytics.connect(admin).takeSnapshot()
    ).to.be.revertedWith('GA: Snapshot too early');

    await ethers.provider.send('evm_increaseTime', [60 * 60 + 1]);
    await ethers.provider.send('evm_mine');

    const tx = await analytics.connect(admin).takeSnapshot();
    const receipt = await tx.wait();
    const parsedEvent = receipt.logs
      .map((log) => {
        try {
          return analytics.interface.parseLog(log);
        } catch (_err) {
          return null;
        }
      })
      .find((event) => event && event.name === 'SnapshotTaken');

    expect(parsedEvent, 'SnapshotTaken event should be emitted').to.not.equal(null);
    const snapshotId = parsedEvent.args.snapshotId;

    const snapshot = await analytics.getGovernanceSnapshot(snapshotId);
    expect(snapshot.timestamp).to.equal(snapshotId);
    expect(snapshot.totalActiveStakeholders).to.equal(500n);
  });

  it('restricts health score calculation to analytics manager role', async function () {
    const { admin, outsider, analytics } = await loadFixture(deployFixture);

    // onlyRole(ANALYTICS_MANAGER_ROLE) — GovernanceAnalytics.sol:522. A DIFFERENT role
    // from the two DATA_PROVIDER_ROLE gates above in the same suite, which an unpinned
    // AccessControlUnauthorizedAccount could not have distinguished.
    await expect(
      analytics.connect(outsider).calculateNetworkHealth()
    )
      .to.be.revertedWithCustomError(analytics, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await analytics.ANALYTICS_MANAGER_ROLE());

    const healthScore = await analytics.connect(admin).calculateNetworkHealth.staticCall();
    await analytics.connect(admin).calculateNetworkHealth();
    expect(await analytics.networkHealthScore()).to.equal(healthScore);
  });
});
