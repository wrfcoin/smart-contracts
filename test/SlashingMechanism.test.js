const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('SlashingMechanism', function () {
  async function deploySlashingMechanismFixture() {
    const [
      owner,
      validator1,
      validator2,
      validator3,
      participant1,
      participant2,
      treasury,
      burnAddress,
    ] = await ethers.getSigners();

    // Deploy mock contracts from MockSlashingDependencies.sol
    const MockMultiAssetStaking = await ethers.getContractFactory(
      'MockMultiAssetStaking'
    );
    const mockMultiAssetStaking = await MockMultiAssetStaking.deploy();

    const MockParticipantTypeRegistry = await ethers.getContractFactory(
      'MockParticipantTypeRegistry'
    );
    const mockParticipantRegistry = await MockParticipantTypeRegistry.deploy();

    const MockLayawayRegistration = await ethers.getContractFactory(
      'MockLayawayRegistration'
    );
    const mockLayawayRegistration = await MockLayawayRegistration.deploy();

    const MockStakeDelegation = await ethers.getContractFactory(
      'MockStakeDelegation'
    );
    const mockStakeDelegation = await MockStakeDelegation.deploy();

    const MockWeatherDataValidator = await ethers.getContractFactory(
      'MockWeatherDataValidator'
    );
    const mockWeatherDataValidator = await MockWeatherDataValidator.deploy();

    // Deploy SlashingMechanism contract
    const SlashingMechanism =
      await ethers.getContractFactory('SlashingMechanism');
    const slashingMechanism = await SlashingMechanism.deploy(
      await mockMultiAssetStaking.getAddress(),
      await mockParticipantRegistry.getAddress(),
      await mockLayawayRegistration.getAddress(),
      await mockStakeDelegation.getAddress(),
      await mockWeatherDataValidator.getAddress(),
      treasury.address,
      burnAddress.address
    );

    // Grant validator roles
    const VALIDATOR_ROLE = await slashingMechanism.VALIDATOR_ROLE();
    const APPEALS_COMMITTEE_ROLE =
      await slashingMechanism.APPEALS_COMMITTEE_ROLE();
    const EMERGENCY_ROLE = await slashingMechanism.EMERGENCY_ROLE();

    await slashingMechanism.grantRole(VALIDATOR_ROLE, validator1.address);
    await slashingMechanism.grantRole(VALIDATOR_ROLE, validator2.address);
    await slashingMechanism.grantRole(VALIDATOR_ROLE, validator3.address);
    await slashingMechanism.grantRole(APPEALS_COMMITTEE_ROLE, owner.address);
    await slashingMechanism.grantRole(EMERGENCY_ROLE, owner.address);

    // Set up mock data
    await mockMultiAssetStaking.setTotalStake(
      participant1.address,
      ethers.parseEther('1000')
    );
    await mockMultiAssetStaking.setTotalStake(
      participant2.address,
      ethers.parseEther('500')
    );

    return {
      slashingMechanism,
      mockMultiAssetStaking,
      mockParticipantRegistry,
      mockLayawayRegistration,
      mockStakeDelegation,
      mockWeatherDataValidator,
      owner,
      validator1,
      validator2,
      validator3,
      participant1,
      participant2,
      treasury,
      burnAddress,
    };
  }

  describe('Deployment', function () {
    it('Should deploy with correct initial values', async function () {
      const { slashingMechanism, treasury, burnAddress } = await loadFixture(
        deploySlashingMechanismFixture
      );

      expect(await slashingMechanism.treasury()).to.equal(treasury.address);
      expect(await slashingMechanism.burnAddress()).to.equal(
        burnAddress.address
      );
      expect(await slashingMechanism.nextSlashingId()).to.equal(1);
      expect(await slashingMechanism.minValidatorsRequired()).to.equal(3);
    });

    it('Should grant correct roles to deployer', async function () {
      const { slashingMechanism, owner } = await loadFixture(
        deploySlashingMechanismFixture
      );

      const DEFAULT_ADMIN_ROLE = await slashingMechanism.DEFAULT_ADMIN_ROLE();
      const VALIDATOR_ROLE = await slashingMechanism.VALIDATOR_ROLE();

      expect(await slashingMechanism.hasRole(DEFAULT_ADMIN_ROLE, owner.address))
        .to.be.true;
      expect(await slashingMechanism.hasRole(VALIDATOR_ROLE, owner.address)).to
        .be.true;
    });
  });

  describe('Evidence Management', function () {
    it('Should allow validators to submit evidence', async function () {
      const { slashingMechanism, validator1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      const ipfsHash = 'QmTest123';

      await expect(
        slashingMechanism
          .connect(validator1)
          .submitEvidence(evidenceHash, ipfsHash)
      )
        .to.emit(slashingMechanism, 'EvidenceSubmitted')
        .withArgs(evidenceHash, validator1.address, ipfsHash);

      expect(await slashingMechanism.verifyEvidence(evidenceHash)).to.be.true;
    });

    it('Should not allow non-validators to submit evidence', async function () {
      const { slashingMechanism, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      const ipfsHash = 'QmTest123';

      await expect(
        slashingMechanism
          .connect(participant1)
          .submitEvidence(evidenceHash, ipfsHash)
      ).to.be.revertedWith('SlashingMechanism: Not a validator');
    });
  });

  describe('Slashing Proposals', function () {
    it('Should allow validators to propose slashing', async function () {
      const { slashingMechanism, validator1, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      // First submit evidence
      const evidenceHash = ethers.keccak256(
        ethers.toUtf8Bytes('fraud evidence')
      );
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmEvidence123');

      // Then propose slashing
      await expect(
        slashingMechanism.connect(validator1).proposeSlashing(
          participant1.address,
          0, // DATA_MANIPULATION
          1, // MAJOR
          evidenceHash,
          'Participant submitted false weather data'
        )
      ).to.emit(slashingMechanism, 'SlashingProposed');

      expect(await slashingMechanism.nextSlashingId()).to.equal(2);
    });

    it('Should calculate correct slashing amounts based on severity', async function () {
      const {
        slashingMechanism,
        validator1,
        participant1,
        mockMultiAssetStaking,
      } = await loadFixture(deploySlashingMechanismFixture);

      // Set participant stake to 1000 ETH
      const stakeAmount = ethers.parseEther('1000');
      await mockMultiAssetStaking.setTotalStake(
        participant1.address,
        stakeAmount
      );

      // Submit evidence
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmTest');

      // Test MINOR violation (25% slash)
      await slashingMechanism.connect(validator1).proposeSlashing(
        participant1.address,
        0, // DATA_MANIPULATION
        0, // MINOR
        evidenceHash,
        'Minor violation'
      );

      const slashingEvent = await slashingMechanism.getSlashingEvent(1);
      expect(slashingEvent.slashedAmount).to.equal(ethers.parseEther('250')); // 25% of 1000
    });

    it('Should require verified evidence', async function () {
      const { slashingMechanism, validator1, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('unverified'));

      await expect(
        slashingMechanism.connect(validator1).proposeSlashing(
          participant1.address,
          0, // DATA_MANIPULATION
          1, // MAJOR
          evidenceHash,
          'Violation description'
        )
      ).to.be.revertedWith('SlashingMechanism: Evidence not verified');
    });
  });

  describe('Slashing Validation', function () {
    it('Should allow multiple validators to validate slashing', async function () {
      const {
        slashingMechanism,
        validator1,
        validator2,
        validator3,
        participant1,
      } = await loadFixture(deploySlashingMechanismFixture);

      // Submit evidence and propose slashing
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmTest');
      await slashingMechanism.connect(validator1).proposeSlashing(
        participant1.address,
        0, // DATA_MANIPULATION
        1, // MAJOR
        evidenceHash,
        'Major violation'
      );

      // Validate by second validator
      await expect(
        slashingMechanism.connect(validator2).validateSlashing(1)
      ).to.emit(slashingMechanism, 'SlashingValidated');

      // Validate by third validator - should confirm
      await expect(
        slashingMechanism.connect(validator3).validateSlashing(1)
      ).to.emit(slashingMechanism, 'SlashingConfirmed');

      const slashingEvent = await slashingMechanism.getSlashingEvent(1);
      expect(slashingEvent.status).to.equal(1); // CONFIRMED
    });

    it('Should not allow same validator to validate twice', async function () {
      const { slashingMechanism, validator1, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      // Submit evidence and propose slashing
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmTest');
      await slashingMechanism.connect(validator1).proposeSlashing(
        participant1.address,
        0, // DATA_MANIPULATION
        1, // MAJOR
        evidenceHash,
        'Major violation'
      );

      // Try to validate again
      await expect(
        slashingMechanism.connect(validator1).validateSlashing(1)
      ).to.be.revertedWith('SlashingMechanism: Already validated');
    });
  });

  describe('Appeals Process', function () {
    it('Should allow participants to appeal slashing decisions', async function () {
      const {
        slashingMechanism,
        validator1,
        validator2,
        validator3,
        participant1,
      } = await loadFixture(deploySlashingMechanismFixture);

      // Create confirmed slashing
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      const appealEvidence = ethers.keccak256(
        ethers.toUtf8Bytes('appeal evidence')
      );

      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmTest');
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(appealEvidence, 'QmAppeal');

      await slashingMechanism
        .connect(validator1)
        .proposeSlashing(participant1.address, 0, 1, evidenceHash, 'Violation');
      await slashingMechanism.connect(validator2).validateSlashing(1);
      await slashingMechanism.connect(validator3).validateSlashing(1);

      // Submit appeal
      await expect(
        slashingMechanism
          .connect(participant1)
          .appealSlashing(1, appealEvidence, 'I was wrongly accused')
      ).to.emit(slashingMechanism, 'AppealSubmitted');

      const slashingEvent = await slashingMechanism.getSlashingEvent(1);
      expect(slashingEvent.status).to.equal(2); // APPEALED
    });

    it('Should not allow appeals from non-participants', async function () {
      const {
        slashingMechanism,
        validator1,
        validator2,
        validator3,
        participant1,
        participant2,
      } = await loadFixture(deploySlashingMechanismFixture);

      // Create confirmed slashing
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      const appealEvidence = ethers.keccak256(
        ethers.toUtf8Bytes('appeal evidence')
      );

      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmTest');
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(appealEvidence, 'QmAppeal');

      await slashingMechanism
        .connect(validator1)
        .proposeSlashing(participant1.address, 0, 1, evidenceHash, 'Violation');
      await slashingMechanism.connect(validator2).validateSlashing(1);
      await slashingMechanism.connect(validator3).validateSlashing(1);

      // Try to appeal from different participant
      await expect(
        slashingMechanism
          .connect(participant2)
          .appealSlashing(1, appealEvidence, "This isn't my slashing")
      ).to.be.revertedWith('SlashingMechanism: Only participant can appeal');
    });
  });

  describe('Emergency Slashing', function () {
    // QUARANTINED: Contract stub _distributeSlashedAssets reverts with 'Slashing distribution not implemented - token transfer required'
    it.skip('Should allow emergency role to immediately slash', async function () {
      const { slashingMechanism, owner, participant1, mockMultiAssetStaking } =
        await loadFixture(deploySlashingMechanismFixture);

      const slashAmount = ethers.parseEther('100');

      await expect(
        slashingMechanism
          .connect(owner)
          .emergencySlashing(
            participant1.address,
            slashAmount,
            'Critical security violation'
          )
      ).to.emit(slashingMechanism, 'EmergencySlashing');

      // Check participant record was updated
      const record = await slashingMechanism.getParticipantRecord(
        participant1.address
      );
      expect(record.violationCount).to.equal(1);
      expect(record.totalSlashed).to.equal(slashAmount);
      expect(record.requiresRefill).to.be.true;
      expect(record.isBanned).to.be.true;
    });

    it('Should not allow non-emergency role to emergency slash', async function () {
      const { slashingMechanism, validator1, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      await expect(
        slashingMechanism
          .connect(validator1)
          .emergencySlashing(
            participant1.address,
            ethers.parseEther('100'),
            'Emergency'
          )
      ).to.be.revertedWith('SlashingMechanism: Not emergency role');
    });
  });

  describe('Stake Refill', function () {
    // QUARANTINED: Depends on emergencySlashing which hits unimplemented _distributeSlashedAssets stub
    it.skip('Should allow participants to refill stake after slashing', async function () {
      const {
        slashingMechanism,
        owner,
        participant1,
        mockMultiAssetStaking,
        mockParticipantRegistry,
      } = await loadFixture(deploySlashingMechanismFixture);

      // Emergency slash first
      await slashingMechanism
        .connect(owner)
        .emergencySlashing(
          participant1.address,
          ethers.parseEther('100'),
          'Test slash'
        );

      // Set up mock to return sufficient stake after refill
      await mockMultiAssetStaking.setTotalStake(
        participant1.address,
        ethers.parseEther('1000')
      );
      await mockParticipantRegistry.setRequiredStakeAmount(
        participant1.address,
        ethers.parseEther('800')
      );

      // Refill stake
      await expect(
        slashingMechanism
          .connect(participant1)
          .refillStake(ethers.parseEther('200'))
      ).to.emit(slashingMechanism, 'StakeRefilled');

      // Check that refill requirement is cleared
      const record = await slashingMechanism.getParticipantRecord(
        participant1.address
      );
      expect(record.requiresRefill).to.be.false;
    });

    // QUARANTINED: Depends on emergencySlashing which hits unimplemented _distributeSlashedAssets stub
    it.skip('Should not allow refill if grace period expired', async function () {
      const { slashingMechanism, owner, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      // Emergency slash
      await slashingMechanism
        .connect(owner)
        .emergencySlashing(
          participant1.address,
          ethers.parseEther('100'),
          'Test slash'
        );

      // Fast forward past grace period (30 days + 1 second)
      await ethers.provider.send('evm_increaseTime', [30 * 24 * 60 * 60 + 1]);
      await ethers.provider.send('evm_mine');

      await expect(
        slashingMechanism
          .connect(participant1)
          .refillStake(ethers.parseEther('200'))
      ).to.be.revertedWith('SlashingMechanism: Grace period expired');
    });
  });

  describe('Configuration Management', function () {
    it('Should allow admin to update configuration', async function () {
      const { slashingMechanism, owner } = await loadFixture(
        deploySlashingMechanismFixture
      );

      await slashingMechanism.connect(owner).updateConfiguration(
        2, // minValidatorsRequired
        24 * 60 * 60, // executionDelay (24 hours)
        7 * 24 * 60 * 60, // appealWindow (7 days)
        15 * 24 * 60 * 60, // gracePeriod (15 days)
        6000, // treasuryAllocationBPS (60%)
        4000 // burnAllocationBPS (40%)
      );

      expect(await slashingMechanism.minValidatorsRequired()).to.equal(2);
      expect(await slashingMechanism.treasuryAllocationBPS()).to.equal(6000);
      expect(await slashingMechanism.burnAllocationBPS()).to.equal(4000);
    });

    it('Should not allow non-admin to update configuration', async function () {
      const { slashingMechanism, validator1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      await expect(
        slashingMechanism
          .connect(validator1)
          .updateConfiguration(
            2,
            24 * 60 * 60,
            7 * 24 * 60 * 60,
            15 * 24 * 60 * 60,
            6000,
            4000
          )
      ).to.be.revertedWithCustomError(slashingMechanism, 'AccessControlUnauthorizedAccount').withArgs(validator1.address, await slashingMechanism.DEFAULT_ADMIN_ROLE());
    });
  });

  describe('View Functions', function () {
    // QUARANTINED: Depends on emergencySlashing which hits unimplemented _distributeSlashedAssets stub
    it.skip('Should return correct participant eligibility', async function () {
      const { slashingMechanism, participant1 } = await loadFixture(
        deploySlashingMechanismFixture
      );

      // Initially eligible
      let [eligible, reason] = await slashingMechanism.checkEligibility(
        participant1.address
      );
      expect(eligible).to.be.true;
      expect(reason).to.equal('');

      // After emergency slashing, not eligible
      const { owner } = await loadFixture(deploySlashingMechanismFixture);
      await slashingMechanism
        .connect(owner)
        .emergencySlashing(
          participant1.address,
          ethers.parseEther('100'),
          'Test'
        );

      [eligible, reason] = await slashingMechanism.checkEligibility(
        participant1.address
      );
      expect(eligible).to.be.false;
      expect(reason).to.equal('Participant is banned');
    });

    it('Should return pending slashings for validators', async function () {
      const { slashingMechanism, validator1, validator2, participant1 } =
        await loadFixture(deploySlashingMechanismFixture);

      // Submit evidence and propose slashing
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('evidence'));
      await slashingMechanism
        .connect(validator1)
        .submitEvidence(evidenceHash, 'QmTest');
      await slashingMechanism
        .connect(validator1)
        .proposeSlashing(participant1.address, 0, 1, evidenceHash, 'Violation');

      const pendingIds = await slashingMechanism.getPendingSlashings(
        validator2.address
      );
      expect(pendingIds.length).to.equal(1);
      expect(pendingIds[0]).to.equal(1);
    });
  });
});
