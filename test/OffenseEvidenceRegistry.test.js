const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('OffenseEvidenceRegistry', function () {
  const OFFENSE_CODE = 'CONS-001';
  const PAYLOAD_HASH = ethers.keccak256(ethers.toUtf8Bytes('evidence-payload-v1'));
  const OBSERVED_AT = 1_710_000_100;
  const VALID_AFTER = 1_710_000_000;
  const EXPIRES_AT = 1_710_086_400;
  const VERSION = 1;

  async function deployOffenseEvidenceRegistryFixture() {
    const [owner, admin, reporter, witnessOne, witnessTwo, other] = await ethers.getSigners();

    const OffenseEvidenceRegistry = await ethers.getContractFactory(
      'OffenseEvidenceRegistry'
    );
    const registry = await OffenseEvidenceRegistry.deploy();

    const EVIDENCE_ADMIN_ROLE = await registry.EVIDENCE_ADMIN_ROLE();
    await registry.grantRole(EVIDENCE_ADMIN_ROLE, admin.address);

    return {
      registry,
      owner,
      admin,
      reporter,
      witnessOne,
      witnessTwo,
      other,
      EVIDENCE_ADMIN_ROLE,
    };
  }

  async function buildPacket(registry, reporter, witnesses, overrides = {}) {
    const basePacket = {
      evidenceHash: ethers.ZeroHash,
      offenseCode: OFFENSE_CODE,
      evidenceType: 1,
      reporter: reporter.address,
      payloadHash: PAYLOAD_HASH,
      observedAt: OBSERVED_AT,
      validAfter: VALID_AFTER,
      expiresAt: EXPIRES_AT,
      timestamp: 0,
      reporterSignature: '0x',
      witnesses: [],
      version: VERSION,
      ...overrides,
    };

    const digest = await registry.computeEvidenceHash(basePacket);
    const reporterSignature = await reporter.signMessage(ethers.getBytes(digest));
    const witnessAttestations = [];

    for (const witness of witnesses) {
      witnessAttestations.push({
        witness: witness.address,
        signature: await witness.signMessage(ethers.getBytes(digest)),
      });
    }

    return {
      ...basePacket,
      evidenceHash: digest,
      reporterSignature,
      witnesses: witnessAttestations,
    };
  }

  describe('Evidence submission', function () {
    it('submits a signed evidence packet and emits EvidenceSubmitted', async function () {
      const { registry, reporter, witnessOne, witnessTwo } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne, witnessTwo]);

      await expect(registry.submitEvidence(packet))
        .to.emit(registry, 'EvidenceSubmitted')
        .withArgs(packet.evidenceHash, OFFENSE_CODE, reporter.address);

      expect(await registry.getEvidenceCount()).to.equal(1);
    });

    it('stores canonical schema fields and witness attestations', async function () {
      const { registry, reporter, witnessOne, witnessTwo } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne, witnessTwo]);
      await registry.submitEvidence(packet);

      const stored = await registry.getEvidence(packet.evidenceHash);
      expect(stored.evidenceHash).to.equal(packet.evidenceHash);
      expect(stored.offenseCode).to.equal(OFFENSE_CODE);
      expect(stored.evidenceType).to.equal(1);
      expect(stored.payloadHash).to.equal(PAYLOAD_HASH);
      expect(stored.observedAt).to.equal(OBSERVED_AT);
      expect(stored.validAfter).to.equal(VALID_AFTER);
      expect(stored.expiresAt).to.equal(EXPIRES_AT);
      expect(stored.reporter).to.equal(reporter.address);
      expect(stored.version).to.equal(VERSION);
      expect(stored.witnesses.length).to.equal(2);
      expect(stored.witnesses[0].witness).to.equal(witnessOne.address);
      expect(stored.witnesses[1].witness).to.equal(witnessTwo.address);
      expect(stored.timestamp).to.be.gt(0);
    });

    it('rejects packets with hash mismatches', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne], {
        payloadHash: ethers.keccak256(ethers.toUtf8Bytes('tampered-payload')),
      });

      packet.evidenceHash = PAYLOAD_HASH;

      await expect(registry.submitEvidence(packet)).to.be.revertedWith(
        'OffenseEvidenceRegistry: hash mismatch'
      );
    });

    it('rejects packets with missing witness attestations', async function () {
      const { registry, reporter } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, []);

      await expect(registry.submitEvidence(packet)).to.be.revertedWith(
        'OffenseEvidenceRegistry: missing witness attestations'
      );
    });

    it('rejects packets with invalid reporter signatures', async function () {
      const { registry, reporter, witnessOne, other } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne]);
      packet.reporterSignature = await other.signMessage(
        ethers.getBytes(packet.evidenceHash)
      );

      await expect(registry.submitEvidence(packet)).to.be.revertedWith(
        'OffenseEvidenceRegistry: invalid reporter signature'
      );
    });

    it('rejects packets with duplicate witnesses', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne, witnessOne]);

      await expect(registry.submitEvidence(packet)).to.be.revertedWith(
        'OffenseEvidenceRegistry: duplicate witness'
      );
    });

    it('rejects packets with out-of-bounds observation timestamps', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne], {
        observedAt: EXPIRES_AT + 1,
      });

      await expect(registry.submitEvidence(packet)).to.be.revertedWith(
        'OffenseEvidenceRegistry: observedAt out of bounds'
      );
    });

    it('rejects packets with unsupported schema versions', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne], {
        version: 2,
      });

      await expect(registry.submitEvidence(packet)).to.be.revertedWith(
        'OffenseEvidenceRegistry: unsupported schema version'
      );
    });

    it('rejects unauthorized submission', async function () {
      const { registry, reporter, witnessOne, other } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne]);

      await expect(registry.connect(other).submitEvidence(packet)).to.be.revertedWithCustomError(registry, 'AccessControlUnauthorizedAccount').withArgs(other.address, await registry.EVIDENCE_ADMIN_ROLE());
    });
  });

  describe('Serialization and validation', function () {
    it('computes the same deterministic evidence hash for the same packet', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne]);

      const recomputed = await registry.computeEvidenceHash({
        ...packet,
        reporterSignature: '0x',
        witnesses: [],
      });

      expect(recomputed).to.equal(packet.evidenceHash);
    });

    it('returns valid=true for a stored well-formed packet', async function () {
      const { registry, reporter, witnessOne, witnessTwo } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne, witnessTwo]);
      await registry.submitEvidence(packet);

      const [valid, reason] = await registry.validateEvidence(packet.evidenceHash);
      expect(valid).to.equal(true);
      expect(reason).to.equal('');
    });

    it('returns valid=false for unknown evidence hashes', async function () {
      const { registry } = await loadFixture(deployOffenseEvidenceRegistryFixture);

      const [valid, reason] = await registry.validateEvidence(
        ethers.keccak256(ethers.toUtf8Bytes('ghost-evidence'))
      );

      expect(valid).to.equal(false);
      expect(reason).to.equal('OffenseEvidenceRegistry: not found');
    });
  });

  describe('Evidence status management', function () {
    it('starts with pending status and updates to validated', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne]);
      await registry.submitEvidence(packet);

      const [initialStatus] = await registry.getEvidenceStatus(packet.evidenceHash);
      expect(initialStatus).to.equal('pending');

      await expect(registry.setEvidenceStatus(packet.evidenceHash, 'validated'))
        .to.emit(registry, 'EvidenceValidated')
        .withArgs(packet.evidenceHash, true)
        .and.to.emit(registry, 'EvidenceStatusUpdated')
        .withArgs(packet.evidenceHash, 'validated');

      const [finalStatus] = await registry.getEvidenceStatus(packet.evidenceHash);
      expect(finalStatus).to.equal('validated');
    });

    it('updates to rejected and blocks invalid status values', async function () {
      const { registry, reporter, witnessOne } = await loadFixture(
        deployOffenseEvidenceRegistryFixture
      );
      const packet = await buildPacket(registry, reporter, [witnessOne]);
      await registry.submitEvidence(packet);

      await expect(registry.setEvidenceStatus(packet.evidenceHash, 'rejected'))
        .to.emit(registry, 'EvidenceValidated')
        .withArgs(packet.evidenceHash, false);

      await expect(
        registry.setEvidenceStatus(packet.evidenceHash, 'unknown_status')
      ).to.be.revertedWith('OffenseEvidenceRegistry: invalid status');
    });

    it('rejects status updates for unknown evidence hashes', async function () {
      const { registry } = await loadFixture(deployOffenseEvidenceRegistryFixture);

      await expect(
        registry.setEvidenceStatus(
          ethers.keccak256(ethers.toUtf8Bytes('ghost')),
          'validated'
        )
      ).to.be.revertedWith('OffenseEvidenceRegistry: not found');
    });
  });
});
