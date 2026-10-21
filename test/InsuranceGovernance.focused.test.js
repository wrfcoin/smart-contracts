const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('InsuranceGovernance — focused guard tests', function () {
  async function deployFixture() {
    const [admin, outsider] = await ethers.getSigners();

    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();

    const InsuranceGovernance = await ethers.getContractFactory(
      'InsuranceGovernance'
    );
    const insuranceGovernance = await InsuranceGovernance.deploy(
      await wrfToken.getAddress()
    );

    return { insuranceGovernance, wrfToken, admin, outsider };
  }

  it('rejects constructor with zero token address', async function () {
    const InsuranceGovernance = await ethers.getContractFactory(
      'InsuranceGovernance'
    );

    await expect(
      InsuranceGovernance.deploy(ethers.ZeroAddress)
    ).to.be.revertedWith('Invalid WRF token address');
  });

  it('rejects proposals from accounts without proposal-creator role', async function () {
    const { insuranceGovernance, outsider } = await loadFixture(deployFixture);

    // onlyRole(PROPOSAL_CREATOR_ROLE) — InsuranceGovernance.sol:237-242. The
    // description is non-empty so the first body require would pass.
    await expect(
      insuranceGovernance
        .connect(outsider)
        .propose(1, 0, 'Policy terms update', 'evidence ipfs')
    )
      .to.be.revertedWithCustomError(insuranceGovernance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await insuranceGovernance.PROPOSAL_CREATOR_ROLE());
  });

  it('requires non-empty proposal description', async function () {
    const { insuranceGovernance, admin } = await loadFixture(deployFixture);

    await expect(
      insuranceGovernance
        .connect(admin)
        .propose(1, 0, '', 'evidence ipfs')
    ).to.be.revertedWith('Empty description');
  });

  it('rejects execution from non-executor role', async function () {
    const { insuranceGovernance, admin, outsider } = await loadFixture(deployFixture);

    await insuranceGovernance
      .connect(admin)
      .propose(1, 0, 'Policy terms update', 'evidence ipfs');

    // execute is validProposal(proposalId) onlyRole(EXECUTOR_ROLE)
    // riskCommitteeApproval(proposalId) — InsuranceGovernance.sol:315. Modifiers run
    // left to right, so validProposal is checked FIRST: the proposal created on the
    // line above is what makes it pass and lets the role gate be reached. That
    // ordering is load-bearing — without the preceding propose() this assertion would
    // be satisfied by validProposal instead, and would not test the role at all.
    await expect(
      insuranceGovernance.connect(outsider).execute(1)
    )
      .to.be.revertedWithCustomError(insuranceGovernance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await insuranceGovernance.EXECUTOR_ROLE());
  });

  it('rejects voting from non-stakeholders', async function () {
    const { insuranceGovernance, admin, outsider } = await loadFixture(deployFixture);

    await insuranceGovernance
      .connect(admin)
      .propose(1, 0, 'Policy terms update', 'evidence ipfs');

    await expect(
      insuranceGovernance.connect(outsider).vote(1, true, 'no stake')
    ).to.be.revertedWith('Must be a stakeholder');
  });
});
