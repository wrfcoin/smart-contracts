'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('ComplianceModule — focused coverage', function () {
  async function deployFixture() {
    const [admin, provider, complianceOfficer, outsider, user] = await ethers.getSigners();

    const ComplianceModule = await ethers.getContractFactory('ComplianceModule');
    const compliance = await ComplianceModule.deploy(admin.address);

    return {
      admin,
      provider,
      complianceOfficer,
      outsider,
      user,
      compliance,
    };
  }

  it('requires a non-zero admin address and seeds initial roles', async function () {
    const { admin, compliance } = await loadFixture(deployFixture);

    const ComplianceModule = await ethers.getContractFactory('ComplianceModule');
    await expect(
      ComplianceModule.deploy(ethers.ZeroAddress)
    ).to.be.revertedWith('CM: Invalid admin address');

    expect(await compliance.hasRole(await compliance.DEFAULT_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await compliance.hasRole(await compliance.COMPLIANCE_OFFICER_ROLE(), admin.address)).to.equal(true);
    expect(await compliance.hasRole(await compliance.DATA_PROTECTION_OFFICER_ROLE(), admin.address)).to.equal(true);
  });

  it('restricts KYC updates to KYC providers and validates provider registration', async function () {
    const { admin, compliance, outsider } = await loadFixture(deployFixture);
    const ComplianceModule = await ethers.getContractFactory('ComplianceModule');

    await expect(
      compliance.connect(outsider).updateKYCStatus(
        outsider.address,
        2n,
        1n,
        'provider-1',
        ethers.encodeBytes32String('doc'),
        0n
      )
    ).to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount');

    await compliance.connect(admin).registerKYCProvider('provider-1', admin.address);
    await compliance.connect(admin).grantRole(await compliance.KYC_PROVIDER_ROLE(), admin.address);

    await expect(
      compliance.connect(admin).updateKYCStatus(
        ethers.ZeroAddress,
        2n,
        1n,
        'provider-1',
        ethers.encodeBytes32String('doc'),
        0n
      )
    ).to.be.revertedWith('CM: Invalid user address');

    await expect(
      compliance.connect(admin).updateKYCStatus(
        outsider.address,
        2n,
        1n,
        'unknown-provider',
        ethers.encodeBytes32String('doc'),
        0n
      )
    ).to.be.revertedWith('CM: Invalid KYC provider');
  });

  it('restricts compliance-officer controls to the correct role', async function () {
    const { admin, outsider, user, compliance } = await loadFixture(deployFixture);

    // All three calls are guarded by onlyRole(COMPLIANCE_OFFICER_ROLE)
    // (ComplianceModule.sol:443, :639, :649). Naming the error *and* pinning the
    // role is what makes these able to fail: a bare `.to.be.reverted` accepts any
    // revert on the path, and an unpinned AccessControlUnauthorizedAccount would
    // still pass if a different role gate fired — this contract has five roles.
    const COMPLIANCE_OFFICER_ROLE = await compliance.COMPLIANCE_OFFICER_ROLE();

    await expect(
      compliance.connect(outsider).setJurisdictionCompliance(
        user.address,
        0n,
        true
      )
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, COMPLIANCE_OFFICER_ROLE);

    await compliance.connect(admin).setJurisdictionCompliance(user.address, 0n, true);
    expect(await compliance.checkJurisdictionCompliance(user.address, 0n)).to.equal(true);

    await expect(
      compliance.connect(outsider).addToBlacklist(user.address, 'blocked')
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, COMPLIANCE_OFFICER_ROLE);

    await compliance.connect(admin).addToBlacklist(user.address, 'blocked');
    expect(await compliance.blacklistedAddresses(user.address)).to.equal(true);

    // Ordering here is load-bearing. removeFromBlacklist also carries
    // `require(blacklistedAddresses[_address], "CM: Address not blacklisted")`
    // (ComplianceModule.sol:650). The admin call above blacklists `user` first,
    // so deleting the role modifier would let this call SUCCEED rather than
    // revert for the other reason — which is what keeps this assertion able to
    // fail. Reordering these two statements would silently make it vacuous.
    await expect(
      compliance.connect(outsider).removeFromBlacklist(user.address, 'clear')
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, COMPLIANCE_OFFICER_ROLE);
  });

  it('restricts risk/audit/reporting gates to scoped roles', async function () {
    const { admin, outsider, compliance, user } = await loadFixture(deployFixture);

    // Three DIFFERENT roles guard these three calls, which is the whole point of
    // this test and exactly what a bare `.to.be.reverted` could not express.
    const COMPLIANCE_OFFICER_ROLE = await compliance.COMPLIANCE_OFFICER_ROLE();
    const AUDITOR_ROLE = await compliance.AUDITOR_ROLE();
    const SANCTIONS_OFFICER_ROLE = await compliance.SANCTIONS_OFFICER_ROLE();

    // onlyRole(COMPLIANCE_OFFICER_ROLE) — ComplianceModule.sol:708
    await expect(
      compliance.connect(outsider).updateRiskAssessment(user.address, 1n, 2n, 3n, 4n, 'factors')
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, COMPLIANCE_OFFICER_ROLE);

    // onlyRole(AUDITOR_ROLE) — ComplianceModule.sol:798. A different role from
    // the call above, so an unpinned assertion would not distinguish them.
    await expect(
      compliance.connect(outsider).generateComplianceReport(0n, 0n)
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, AUDITOR_ROLE);

    // The caller here is ADMIN, not outsider, and that is deliberate:
    // performSanctionsCheck requires onlyRole(SANCTIONS_OFFICER_ROLE)
    // (ComplianceModule.sol:664), which the constructor never grants — it grants
    // only DEFAULT_ADMIN_ROLE, COMPLIANCE_OFFICER_ROLE and
    // DATA_PROTECTION_OFFICER_ROLE (:319-321). So even the admin is unauthorized
    // here. Pinning the role is what proves that is the reason, rather than the
    // assertion silently passing because admin happens to lack some other role.
    await expect(
      compliance.connect(admin).performSanctionsCheck(user.address, 'default')
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(admin.address, SANCTIONS_OFFICER_ROLE);

    await expect(
      compliance.connect(admin).setComplianceEnabled(false)
    ).to.not.be.reverted;
  });

  it('enforces transaction validation guards and returns rejections cleanly', async function () {
    const { admin, compliance, outsider, user } = await loadFixture(deployFixture);
    const ComplianceModule = await ethers.getContractFactory('ComplianceModule');

    // validateTransaction stacks FOUR modifiers (ComplianceModule.sol:460-463):
    // onlyRole(COMPLIANCE_OFFICER_ROLE), notBlacklisted, allowedJurisdiction and
    // validTransactionVelocity. Solidity runs them left to right, so the role
    // gate fires first for an unauthorized caller. Naming it is what separates
    // this from the three string-revert guards behind it — a bare assertion here
    // was satisfied by any of the four.
    await expect(
      compliance.connect(outsider).validateTransaction(user.address, 'mint', 1n, 0n)
    )
      .to.be.revertedWithCustomError(compliance, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await compliance.COMPLIANCE_OFFICER_ROLE());

    await compliance.connect(admin).addToBlacklist(user.address, 'blocked');
    await expect(
      compliance.connect(admin).validateTransaction(user.address, 'mint', 1n, 0n)
    ).to.be.revertedWith('CM: Address blacklisted');
  });
});
