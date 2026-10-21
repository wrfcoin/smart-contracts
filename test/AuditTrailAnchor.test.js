'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('AuditTrailAnchor (#139)', function () {
  const CADENCE = 3600;
  const root = (label) => ethers.keccak256(ethers.toUtf8Bytes(label));

  async function deployFixture() {
    const [admin, anchor, outsider] = await ethers.getSigners();
    const Anchor = await ethers.getContractFactory('AuditTrailAnchor');
    const registry = await Anchor.connect(admin).deploy(CADENCE);
    await registry.waitForDeployment();
    await registry.grantRole(await registry.AUDIT_ANCHOR_ROLE(), anchor.address);
    return { registry, admin, anchor, outsider };
  }

  it('anchors a root and verifies the exact source range', async function () {
    const { registry, anchor } = await deployFixture();
    const auditRoot = root('paperclip-audit-1-100');

    await expect(registry.connect(anchor).anchorAuditRoot(auditRoot, 1, 100))
      .to.emit(registry, 'AuditRootAnchored');

    expect(await registry.auditEpochCount()).to.equal(1n);
    expect(await registry.verifyAuditRoot(0, auditRoot)).to.equal(true);
    expect(await registry.verifyAuditRoot(0, root('tampered'))).to.equal(false);
  });

  it('mutation: remove anchor-role guard reverts for an unauthorized submitter', async function () {
    const { registry, outsider } = await deployFixture();
    await expect(registry.connect(outsider).anchorAuditRoot(root('unauthorized'), 1, 1))
      .to.be.revertedWithCustomError(registry, 'AccessControlUnauthorizedAccount');
  });

  it('mutation: accept a zero root reverts', async function () {
    const { registry, anchor } = await deployFixture();
    await expect(registry.connect(anchor).anchorAuditRoot(ethers.ZeroHash, 1, 1))
      .to.be.revertedWith('AuditTrailAnchor: zero root');
  });

  it('mutation: accept an inverted source range reverts', async function () {
    const { registry, anchor } = await deployFixture();
    await expect(registry.connect(anchor).anchorAuditRoot(root('inverted'), 10, 9))
      .to.be.revertedWith('AuditTrailAnchor: invalid record range');
  });

  it('mutation: omit cadence guard reverts for immediate successive anchors', async function () {
    const { registry, anchor } = await deployFixture();
    await registry.connect(anchor).anchorAuditRoot(root('first'), 1, 100);
    await expect(registry.connect(anchor).anchorAuditRoot(root('second'), 101, 200))
      .to.be.revertedWith('AuditTrailAnchor: cadence not reached');
  });

  it('mutation: allow an overlapping range reverts after cadence', async function () {
    const { registry, anchor } = await deployFixture();
    await registry.connect(anchor).anchorAuditRoot(root('first'), 1, 100);
    await time.increase(CADENCE);
    await expect(registry.connect(anchor).anchorAuditRoot(root('overlap'), 100, 200))
      .to.be.revertedWith('AuditTrailAnchor: non-monotonic record range');
  });

  it('anchors the next non-overlapping range after its cadence', async function () {
    const { registry, anchor } = await deployFixture();
    await registry.connect(anchor).anchorAuditRoot(root('first'), 1, 100);
    await time.increase(CADENCE);
    const next = root('second');
    await expect(registry.connect(anchor).anchorAuditRoot(next, 101, 200))
      .to.emit(registry, 'AuditRootAnchored');
    expect(await registry.verifyAuditRoot(1, next)).to.equal(true);
  });
});
