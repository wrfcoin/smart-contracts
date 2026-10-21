const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('ComprehensiveGovernanceSecurity — focused guard tests', function () {
  async function deployFixture({
    timelockDelay = 72n * 60n * 60n,
    stakeProposer = true,
  } = {}) {
    const [
      admin,
      proposer,
      outsider,
      guardian1,
      guardian2,
      guardian3,
    ] = await ethers.getSigners();

    const TestERC20 = await ethers.getContractFactory('TestERC20');
    const governanceToken = await TestERC20.deploy(
      'WRF Governance Token',
      'WRF',
      ethers.parseEther('1000000')
    );

    const TimelockController = await ethers.getContractFactory(
      'TimelockController'
    );
    const timelock = await TimelockController.deploy(
      timelockDelay,
      [admin.address],
      [admin.address],
      admin.address
    );

    const ComplianceModule = await ethers.getContractFactory('ComplianceModule');
    const compliance = await ComplianceModule.deploy(admin.address);

    const EconomicSecurityMechanisms =
      await ethers.getContractFactory('EconomicSecurityMechanisms');
    const economicSecurity = await EconomicSecurityMechanisms.deploy(
      await governanceToken.getAddress(),
      admin.address
    );

    const CoordinationAttackPrevention =
      await ethers.getContractFactory('CoordinationAttackPrevention');
    const coordinationPrevention = await CoordinationAttackPrevention.deploy(
      admin.address
    );

    const GovernanceSecurityFramework =
      await ethers.getContractFactory('GovernanceSecurityFramework');
    const securityFramework = await GovernanceSecurityFramework.deploy(
      admin.address,
      await timelock.getAddress(),
      await compliance.getAddress(),
      await governanceToken.getAddress()
    );

    const ComprehensiveGovernanceSecurity = await ethers.getContractFactory(
      'ComprehensiveGovernanceSecurity'
    );
    const masterSecurity = await ComprehensiveGovernanceSecurity.deploy(
      await securityFramework.getAddress(),
      await coordinationPrevention.getAddress(),
      await economicSecurity.getAddress(),
      await compliance.getAddress(),
      await timelock.getAddress(),
      admin.address,
      [guardian1.address, guardian2.address, guardian3.address]
    );

    await securityFramework.bootstrapLaunchParticipant(
      await masterSecurity.getAddress(),
      500,
      ethers.parseEther('1')
    );

    await compliance.grantRole(
      await compliance.COMPLIANCE_OFFICER_ROLE(),
      await masterSecurity.getAddress()
    );
    await compliance.grantRole(
      await compliance.COMPLIANCE_OFFICER_ROLE(),
      await securityFramework.getAddress()
    );
    await economicSecurity.grantRole(
      await economicSecurity.SLASHING_MANAGER_ROLE(),
      await masterSecurity.getAddress()
    );

    const ONE_YEAR = 365n * 24n * 60n * 60n;
    const masterSecurityAddress = await masterSecurity.getAddress();
    await compliance.registerKYCProvider(
      'unit',
      admin.address
    );
    await compliance.updateKYCStatus(
      proposer.address,
      2, // VERIFIED
      1, // ENHANCED
      'unit',
      ethers.encodeBytes32String('kyc'),
      BigInt((await ethers.provider.getBlock('latest')).timestamp) + ONE_YEAR
    );
    await compliance.updateKYCStatus(
      masterSecurityAddress,
      2, // VERIFIED
      1, // ENHANCED
      'unit',
      ethers.encodeBytes32String('kyc-master'),
      BigInt((await ethers.provider.getBlock('latest')).timestamp) + ONE_YEAR
    );
    await compliance.setJurisdictionCompliance(
      proposer.address,
      0, // ComplianceModule.Jurisdiction.GLOBAL
      true
    );
    await compliance.setJurisdictionCompliance(
      masterSecurityAddress,
      0, // ComplianceModule.Jurisdiction.GLOBAL
      true
    );
    const proposalBond = 1000n * 10n ** 18n;
    const masterSecurityStake = 2000n * 10n ** 18n;
    await governanceToken.transfer(
      masterSecurityAddress,
      proposalBond
    );
    await governanceToken
      .connect(admin)
      .transfer(masterSecurityAddress, masterSecurityStake);
    await ethers.provider.send('hardhat_impersonateAccount', [
      masterSecurityAddress,
    ]);
    const masterSecuritySigner = await ethers.getSigner(masterSecurityAddress);
    await ethers.provider.send('hardhat_setBalance', [
      masterSecurityAddress,
      ethers.toQuantity(ethers.parseEther('10')),
    ]);
    await governanceToken
      .connect(masterSecuritySigner)
      .approve(await securityFramework.getAddress(), proposalBond);
    await governanceToken
      .connect(masterSecuritySigner)
      .approve(await economicSecurity.getAddress(), masterSecurityStake);
    await economicSecurity
      .connect(masterSecuritySigner)
      .stakeTokens(masterSecurityStake, 30n * 24n * 60n * 60n);
    const masterSecurityStakingInfo = await economicSecurity.getStakingInfo(
      masterSecurityAddress
    );
    expect(masterSecurityStakingInfo[0]).to.equal(masterSecurityStake);
    await compliance.updateRegulatoryFramework(
      0, // ComplianceModule.Jurisdiction.GLOBAL
      'GLOBAL',
      0, // NONE
      ethers.parseEther('1000000'),
      ethers.parseEther('10000000'),
      ethers.parseEther('10000000'),
      false,
      false
    );

    if (stakeProposer) {
      await securityFramework.bootstrapLaunchParticipant(
        proposer.address,
        500,
        ethers.parseEther('1')
      );
      await governanceToken.transfer(
        proposer.address,
        ethers.parseEther('3000')
      );
      await governanceToken
        .connect(proposer)
        .approve(
          await economicSecurity.getAddress(),
          ethers.parseEther('2000')
        );
      await economicSecurity.connect(proposer).stakeTokens(
        ethers.parseEther('2000'),
        30n * 24n * 60n * 60n
      );
      const stakingInfo = await economicSecurity.getStakingInfo(proposer.address);
      expect(stakingInfo[0]).to.equal(ethers.parseEther('2000'));
    }

    return {
      admin,
      proposer,
      outsider,
      guardian1,
      guardian2,
      guardian3,
      masterSecurity,
      timelock,
      compliance,
      securityFramework,
      economicSecurity,
      coordinationPrevention,
      governanceToken,
      proposer,
    };
  }

  async function createProposal(masterSecurity, proposer) {
    const tx = await masterSecurity
      .connect(proposer)
      .createSecureProposal('test', 'focused guard test', '0x');
    await tx.wait();
    return (await masterSecurity.nextProposalId()) - 1n;
  }

  async function defaultFixture() {
    return deployFixture();
  }

  async function unbondedFixture() {
    return deployFixture({ stakeProposer: false });
  }

  async function shortTimelockFixture() {
    return deployFixture({ timelockDelay: 60n * 60n });
  }

  async function installEmergencyOverrideRole(masterSecurity, admin) {
    const emergencyRole = await masterSecurity.EMERGENCY_OVERRIDE_ROLE();
    await masterSecurity.grantRole(emergencyRole, admin.address);
  }

  it('rejects proposal creation without proposer stake', async function () {
    const { masterSecurity, proposer } = await loadFixture(unbondedFixture);

    await expect(
      masterSecurity
        .connect(proposer)
        .createSecureProposal('test', 'no stake', '0x')
    ).to.be.revertedWith('CGS: Must stake tokens to propose');
  });

  it('allows a compliant staked proposer to create a secure proposal', async function () {
    const { masterSecurity, proposer, compliance } = await loadFixture(defaultFixture);
    const hasOfficerRole = await compliance.hasRole(
      await compliance.COMPLIANCE_OFFICER_ROLE(),
      await masterSecurity.getAddress()
    );
    expect(hasOfficerRole).to.equal(true);
    const proposalId = await createProposal(masterSecurity, proposer);

    expect(await masterSecurity.nextProposalId()).to.equal(proposalId + 1n);
    await expect(
      masterSecurity.getSecurityAnalysis(proposalId)
    ).to.not.be.reverted;
  });

  it('requires guard review contracts before guardian voting', async function () {
    const { masterSecurity, proposer, guardian1 } = await loadFixture(
      defaultFixture
    );
    const proposalId = await createProposal(masterSecurity, proposer);

    await expect(
      masterSecurity.connect(guardian1).guardianVote(proposalId, true)
    ).to.be.revertedWith('CGS: Guardian review not required');
  });

  it('enforces guardian single-vote invariant on review-required proposals', async function () {
    const { masterSecurity, proposer, guardian1, economicSecurity } =
      await loadFixture(shortTimelockFixture);

    await economicSecurity.connect(proposer).postProposerBond(1n, 0);
    const proposalId = await createProposal(masterSecurity, proposer);

    await masterSecurity.connect(guardian1).guardianVote(proposalId, true);
    await expect(
      masterSecurity.connect(guardian1).guardianVote(proposalId, true)
    ).to.be.revertedWith('CGS: Already voted');
  });

  it('restricts guardian voting to guardian council members', async function () {
    const { masterSecurity, proposer, outsider } = await loadFixture(
      defaultFixture
    );
    const proposalId = await createProposal(masterSecurity, proposer);

    // onlyRole(GUARDIAN_COUNCIL_ROLE) — ComprehensiveGovernanceSecurity.sol:552.
    //
    // Naming matters especially here. guardianVote also carries
    // `require(proposal.guardianReviewRequired, "CGS: Guardian review not
    // required")` (:556), and that flag is only set for proposals whose security
    // score lands in the narrow band at :504. So this call would very likely
    // revert even with the role modifier deleted — the bare assertion could not
    // detect that removal at all. Demanding this specific custom error fixes it:
    // the modifier runs before the body, so today it passes, and if the role
    // gate were removed the call would revert with the *string* above and this
    // assertion would go red.
    await expect(
      masterSecurity.connect(outsider).guardianVote(proposalId, true)
    )
      .to.be.revertedWithCustomError(masterSecurity, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await masterSecurity.GUARDIAN_COUNCIL_ROLE());
  });

  it('protects circuit-breaker activation with security-coordinator role', async function () {
    const { masterSecurity, proposer, outsider } = await loadFixture(
      defaultFixture
    );
    const proposalId = await createProposal(masterSecurity, proposer);

    // onlyRole(SECURITY_COORDINATOR_ROLE) — :631. The body is a pair of state
    // writes with no further requires, so deleting the role modifier makes this
    // call succeed and the assertion go red.
    await expect(
      masterSecurity.connect(outsider).activateCircuitBreaker(
        proposalId,
        'unauthorized override'
      )
    )
      .to.be.revertedWithCustomError(masterSecurity, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await masterSecurity.SECURITY_COORDINATOR_ROLE());
  });

  it('protects emergency override support with emergency-override role', async function () {
    const { masterSecurity, proposer, outsider } = await loadFixture(
      defaultFixture
    );
    const admin = proposer;
    await installEmergencyOverrideRole(masterSecurity, admin);
    const proposalId = await createProposal(masterSecurity, proposer);
    const tx = await masterSecurity
      .connect(proposer)
      .initiateEmergencyOverride(proposalId, 'ops');
    await tx.wait();
    const overrideId = (await masterSecurity.nextOverrideId()) - 1n;

    // onlyRole(EMERGENCY_OVERRIDE_ROLE) — :604. Its three body requires all pass
    // for this call: overrideId is the one just created (so < nextOverrideId),
    // the override is not executed, and `outsider` has not supported it. So the
    // role gate is the only thing that can reject this, and removing it makes
    // the call succeed.
    await expect(
      masterSecurity.connect(outsider).supportEmergencyOverride(overrideId)
    )
      .to.be.revertedWithCustomError(masterSecurity, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await masterSecurity.EMERGENCY_OVERRIDE_ROLE());
  });
});
