const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('OffenseRegistry', function () {
  const CANONICAL_OFFENSES = [
    { code: 'DATA-001', severity: 1, description: 'DataInvalidReveal' },
    { code: 'DATA-002', severity: 0, description: 'DataLowQuality' },
    { code: 'DATA-003', severity: 3, description: 'DataFabrication' },
    { code: 'CONS-001', severity: 3, description: 'ConsensusDoubleSign' },
    { code: 'CONS-002', severity: 3, description: 'ConsensusSurroundVote' },
    { code: 'CONS-003', severity: 1, description: 'ConsensusDowntime' },
    { code: 'CONS-004', severity: 2, description: 'ConsensusInvalidBlock' },
    { code: 'ORAC-001', severity: 3, description: 'OracleAttestationFraud' },
    { code: 'ORAC-002', severity: 1, description: 'OracleUnregistered' },
    { code: 'ORAC-003', severity: 2, description: 'OracleDoubleAttestation' },
    { code: 'GOVN-001', severity: 2, description: 'GovernanceVoteManipulation' },
    { code: 'GOVN-002', severity: 3, description: 'GovernanceBribery' },
    { code: 'OPER-001', severity: 1, description: 'OperationalRateLimitAbuse' },
    { code: 'OPER-002', severity: 0, description: 'OperationalSpam' },
    { code: 'ECON-001', severity: 2, description: 'EconomicWashTrading' },
    { code: 'ECON-002', severity: 3, description: 'EconomicMarketManipulation' },
  ];

  async function deployOffenseRegistryFixture() {
    const [owner, admin, user] = await ethers.getSigners();

    const OffenseRegistry = await ethers.getContractFactory('OffenseRegistry');
    const registry = await OffenseRegistry.deploy();

    const OFFENSE_ADMIN_ROLE = await registry.OFFENSE_ADMIN_ROLE();
    await registry.grantRole(OFFENSE_ADMIN_ROLE, admin.address);

    return { registry, owner, admin, user, OFFENSE_ADMIN_ROLE };
  }

  describe('Registration', function () {
    it('registers an offense with default policy ranges derived from severity', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await registry.registerOffense('DATA-001', 1, 'DataInvalidReveal');

      const record = await registry.getOffense('DATA-001');
      expect(record.code).to.equal('DATA-001');
      expect(record.severity).to.equal(1);
      expect(record.description).to.equal('DataInvalidReveal');
      expect(record.penalties.minSlashBps).to.equal(500);
      expect(record.penalties.maxSlashBps).to.equal(1500);
      expect(record.penalties.minLockDuration).to.equal(24 * 60 * 60);
      expect(record.penalties.maxLockDuration).to.equal(3 * 24 * 60 * 60);
      expect(record.version).to.equal(1);
      expect(record.deprecated).to.equal(false);
      expect(record.registeredAt).to.be.gt(0);
      expect(record.updatedAt).to.equal(record.registeredAt);
    });

    it('registers an offense with explicit custom penalty ranges', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await registry['registerOffense(string,uint8,string,uint16,uint16,uint32,uint32)'](
        'OPER-010',
        1,
        'Operational queue abuse',
        250,
        900,
        3600,
        7200
      );

      const penalties = await registry.getPenaltyRange('OPER-010');
      expect(penalties.minSlashBps).to.equal(250);
      expect(penalties.maxSlashBps).to.equal(900);
      expect(penalties.minLockDuration).to.equal(3600);
      expect(penalties.maxLockDuration).to.equal(7200);
    });

    it('rejects registration without OFFENSE_ADMIN_ROLE', async function () {
      const { registry, user } = await loadFixture(deployOffenseRegistryFixture);

      await expect(
        registry.connect(user).registerOffense('DATA-001', 1, 'DataInvalidReveal')
      ).to.be.revertedWithCustomError(registry, 'AccessControlUnauthorizedAccount').withArgs(user.address, await registry.OFFENSE_ADMIN_ROLE());
    });

    it('rejects duplicate registration', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await registry.registerOffense('DATA-001', 1, 'DataInvalidReveal');

      await expect(
        registry.registerOffense('DATA-001', 2, 'Duplicate')
      ).to.be.revertedWith('OffenseRegistry: duplicate code');
    });

    it('rejects empty code or description', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await expect(
        registry.registerOffense('', 1, 'Empty code')
      ).to.be.revertedWith('OffenseRegistry: empty code');

      await expect(
        registry.registerOffense('DATA-001', 1, '')
      ).to.be.revertedWith('OffenseRegistry: empty description');
    });

    it('rejects invalid severity and malformed custom ranges', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await expect(
        registry.registerOffense('DATA-001', 4, 'Bad severity')
      ).to.be.revertedWith('OffenseRegistry: invalid severity');

      await expect(
        registry['registerOffense(string,uint8,string,uint16,uint16,uint32,uint32)'](
          'DATA-999',
          2,
          'Bad slash range',
          700,
          600,
          3600,
          7200
        )
      ).to.be.revertedWith('OffenseRegistry: invalid slash range');

      await expect(
        registry['registerOffense(string,uint8,string,uint16,uint16,uint32,uint32)'](
          'DATA-998',
          2,
          'Bad lock range',
          600,
          700,
          7200,
          3600
        )
      ).to.be.revertedWith('OffenseRegistry: invalid lock range');
    });
  });

  describe('Update', function () {
    it('updates offense metadata and penalty ranges with a version bump', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await registry.registerOffense('DATA-001', 1, 'DataInvalidReveal');
      await registry['updateOffense(string,uint8,string,uint16,uint16,uint32,uint32)'](
        'DATA-001',
        2,
        'Updated description',
        1200,
        2600,
        7200,
        86400
      );

      const record = await registry.getOffense('DATA-001');
      expect(record.severity).to.equal(2);
      expect(record.description).to.equal('Updated description');
      expect(record.penalties.minSlashBps).to.equal(1200);
      expect(record.penalties.maxSlashBps).to.equal(2600);
      expect(record.penalties.minLockDuration).to.equal(7200);
      expect(record.penalties.maxLockDuration).to.equal(86400);
      expect(record.version).to.equal(2);
      expect(record.updatedAt).to.be.gte(record.registeredAt);
    });

    it('rejects updates on missing or deprecated offenses', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await expect(
        registry.updateOffense('FAKE-001', 1, 'Does not exist')
      ).to.be.revertedWith('OffenseRegistry: not found');

      await registry.registerOffense('DATA-001', 1, 'DataInvalidReveal');
      await registry.deprecateOffense('DATA-001');

      await expect(
        registry.updateOffense('DATA-001', 2, 'Should fail')
      ).to.be.revertedWith('OffenseRegistry: deprecated');
    });
  });

  describe('Deprecation and enumeration', function () {
    it('deprecates an offense and removes it from active lookups', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await registry.registerOffense('DATA-001', 1, 'DataInvalidReveal');
      await registry.deprecateOffense('DATA-001');

      const record = await registry.getOffense('DATA-001');
      expect(record.deprecated).to.equal(true);
      expect(record.version).to.equal(2);
      expect(await registry.isDeprecated('DATA-001')).to.equal(true);

      const [total, active] = await registry.getOffenseCount();
      expect(total).to.equal(1);
      expect(active).to.equal(0);

      const activeRecords = await registry.getAllActiveOffenses();
      expect(activeRecords.length).to.equal(0);
    });

    it('enumerates active offenses with human-readable metadata and ranges', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      await registry.registerOffense('DATA-001', 1, 'DataInvalidReveal');
      await registry.registerOffense('DATA-002', 0, 'DataLowQuality');
      await registry.registerOffense('DATA-003', 3, 'DataFabrication');
      await registry.deprecateOffense('DATA-002');

      const active = await registry.getAllActiveOffenses();
      expect(active.length).to.equal(2);

      const data001 = active.find((entry) => entry.code === 'DATA-001');
      expect(data001.description).to.equal('DataInvalidReveal');
      expect(data001.penalties.maxSlashBps).to.equal(1500);

      const codes = active.map((entry) => entry.code);
      expect(codes).to.include('DATA-001');
      expect(codes).to.include('DATA-003');
      expect(codes).to.not.include('DATA-002');
    });
  });

  describe('Canonical offense catalog', function () {
    it('registers all canonical offense codes with deterministic defaults', async function () {
      const { registry } = await loadFixture(deployOffenseRegistryFixture);

      for (const offense of CANONICAL_OFFENSES) {
        await registry.registerOffense(
          offense.code,
          offense.severity,
          offense.description
        );
      }

      const [total, active] = await registry.getOffenseCount();
      expect(total).to.equal(16);
      expect(active).to.equal(16);

      const allActive = await registry.getAllActiveOffenses();
      expect(allActive.length).to.equal(16);

      const econ002 = await registry.getOffense('ECON-002');
      expect(econ002.description).to.equal('EconomicMarketManipulation');
      expect(econ002.penalties.maxSlashBps).to.equal(10000);

      const oper002 = await registry.getOffense('OPER-002');
      expect(oper002.penalties.minLockDuration).to.equal(0);
      expect(oper002.penalties.maxLockDuration).to.equal(24 * 60 * 60);
    });
  });
});
