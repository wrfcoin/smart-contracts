const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonVerificationOracle', function () {
  async function deployCarbonVerificationFixture() {
    const [owner, oracle, issuer, user1, user2, disputer] =
      await ethers.getSigners();

    // Deploy CarbonCreditTracker
    const CarbonCreditTracker =
      await ethers.getContractFactory('CarbonCreditTracker');
    const tracker = await CarbonCreditTracker.deploy();

    // Deploy CarbonVerificationOracle
    const CarbonVerificationOracle = await ethers.getContractFactory(
      'CarbonVerificationOracle'
    );
    const oracleContract = await CarbonVerificationOracle.deploy(
      await tracker.getAddress()
    );

    // Set up verification oracle on tracker
    await tracker.setVerificationOracle(await oracleContract.getAddress());

    // Grant oracle role to oracle signer on the oracle contract
    const VERIFICATION_ORACLE_ROLE =
      await oracleContract.VERIFICATION_ORACLE_ROLE();
    await oracleContract.grantRole(VERIFICATION_ORACLE_ROLE, oracle.address);

    // Grant issuer role on tracker
    const AUTHORIZED_ISSUER_ROLE = await tracker.AUTHORIZED_ISSUER_ROLE();
    await tracker.grantRole(AUTHORIZED_ISSUER_ROLE, issuer.address);

    // Grant registry connector role for retirement tests
    const REGISTRY_CONNECTOR_ROLE = await tracker.REGISTRY_CONNECTOR_ROLE();
    await tracker.grantRole(REGISTRY_CONNECTOR_ROLE, user1.address);

    // Create a sample lifecycle
    const tx = await tracker
      .connect(issuer)
      .createLifecycle(1, 'PROJECT-001', 'SN-001', 'VCS', issuer.address, ethers.parseEther('1000'));
    const receipt = await tx.wait();
    const event = receipt.logs
      .map((log) => {
        try {
          return tracker.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((parsed) => parsed && parsed.name === 'CreditLifecycleCreated');
    const lifecycleId = event.args.lifecycleId;

    return {
      tracker,
      oracleContract,
      owner,
      oracle,
      issuer,
      user1,
      user2,
      disputer,
      lifecycleId,
      VERIFICATION_ORACLE_ROLE,
    };
  }

  async function signAttestation(signer, lifecycleId, verified) {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const messageHash = ethers.solidityPackedKeccak256(
      ['bytes32', 'bool', 'uint256'],
      [lifecycleId, verified, chainId]
    );
    return signer.signMessage(ethers.getBytes(messageHash));
  }

  describe('Deployment', function () {
    it('Should deploy with correct tracker reference', async function () {
      const { oracleContract, tracker } = await loadFixture(
        deployCarbonVerificationFixture
      );
      expect(await oracleContract.carbonCreditTracker()).to.equal(
        await tracker.getAddress()
      );
    });

    it('Should grant admin and oracle roles to deployer', async function () {
      const { oracleContract, owner } = await loadFixture(
        deployCarbonVerificationFixture
      );
      const DEFAULT_ADMIN_ROLE = await oracleContract.DEFAULT_ADMIN_ROLE();
      const VERIFICATION_ORACLE_ROLE =
        await oracleContract.VERIFICATION_ORACLE_ROLE();
      expect(await oracleContract.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to
        .be.true;
      expect(
        await oracleContract.hasRole(VERIFICATION_ORACLE_ROLE, owner.address)
      ).to.be.true;
    });

    it('Should revert deployment with zero address tracker', async function () {
      const CarbonVerificationOracle = await ethers.getContractFactory(
        'CarbonVerificationOracle'
      );
      await expect(
        CarbonVerificationOracle.deploy(ethers.ZeroAddress)
      ).to.be.revertedWith('CarbonVerificationOracle: Invalid tracker');
    });
  });

  describe('Verification Request', function () {
    it('Should request verification for ISSUED credit', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      const request =
        await oracleContract.getVerificationRequest(lifecycleId);
      expect(request.status).to.equal(1); // PENDING
      expect(request.requester).to.equal(user1.address);
    });

    it('Should emit VerificationRequested event', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await expect(
        oracleContract.connect(user1).requestVerification(lifecycleId)
      )
        .to.emit(oracleContract, 'VerificationRequested')
        .withArgs(lifecycleId, user1.address, await time.latest().then(t => t + 1).catch(() => undefined));
    });

    it('Should transition credit to PENDING_VERIFICATION', async function () {
      const { oracleContract, tracker, lifecycleId, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(1); // PENDING_VERIFICATION
    });

    it('Should increment totalRequests', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      expect(await oracleContract.totalRequests()).to.equal(1);
    });

    it('Should reject duplicate request', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await expect(
        oracleContract.connect(user1).requestVerification(lifecycleId)
      ).to.be.revertedWith('CarbonVerificationOracle: Request already exists');
    });
  });

  describe('Verification Confirmation', function () {
    it('Should confirm with valid oracle attestation', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      const request =
        await oracleContract.getVerificationRequest(lifecycleId);
      expect(request.status).to.equal(2); // CONFIRMED
    });

    it('Should set credit to ACTIVE and isVerified=true', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(2); // ACTIVE
      expect(lifecycle.isVerified).to.be.true;
    });

    it('Should set dispute deadline correctly', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      const request =
        await oracleContract.getVerificationRequest(lifecycleId);
      const DISPUTE_WINDOW = await oracleContract.DISPUTE_WINDOW();
      expect(request.disputeDeadline).to.equal(
        request.confirmationTimestamp + DISPUTE_WINDOW
      );
    });

    it('Should emit VerificationConfirmed event', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);

      await expect(
        oracleContract
          .connect(oracle)
          .confirmVerification(lifecycleId, attestation)
      ).to.emit(oracleContract, 'VerificationConfirmed');
    });

    it('Should reject from non-oracle caller', async function () {
      const { oracleContract, lifecycleId, user1, user2 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(user2, lifecycleId, true);

      await expect(
        oracleContract
          .connect(user2)
          .confirmVerification(lifecycleId, attestation)
      ).to.be.revertedWithCustomError(oracleContract, 'AccessControlUnauthorizedAccount').withArgs(user2.address, await oracleContract.VERIFICATION_ORACLE_ROLE());
    });

    it('Should reject for non-pending request', async function () {
      const { oracleContract, lifecycleId, oracle } = await loadFixture(
        deployCarbonVerificationFixture
      );

      const attestation = await signAttestation(oracle, lifecycleId, true);

      await expect(
        oracleContract
          .connect(oracle)
          .confirmVerification(lifecycleId, attestation)
      ).to.be.revertedWith('CarbonVerificationOracle: Not pending');
    });

    it('Should increment totalConfirmed', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      expect(await oracleContract.totalConfirmed()).to.equal(1);
    });
  });

  describe('Verification Rejection', function () {
    it('Should reject with reason string', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      await oracleContract
        .connect(oracle)
        .rejectVerification(lifecycleId, 'Invalid offset data');

      const request =
        await oracleContract.getVerificationRequest(lifecycleId);
      expect(request.status).to.equal(3); // REJECTED
      expect(request.rejectionReason).to.equal('Invalid offset data');
    });

    it('Should set credit to CANCELLED', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      await oracleContract
        .connect(oracle)
        .rejectVerification(lifecycleId, 'Rejected');

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(7); // CANCELLED
    });

    it('Should emit VerificationRejected event', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await expect(
        oracleContract
          .connect(oracle)
          .rejectVerification(lifecycleId, 'Bad data')
      )
        .to.emit(oracleContract, 'VerificationRejected')
        .withArgs(lifecycleId, oracle.address, 'Bad data');
    });

    it('Should reject from non-oracle caller', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await expect(
        oracleContract
          .connect(user1)
          .rejectVerification(lifecycleId, 'Reason')
      ).to.be.revertedWithCustomError(oracleContract, 'AccessControlUnauthorizedAccount').withArgs(user1.address, await oracleContract.VERIFICATION_ORACLE_ROLE());
    });

    it('Should increment totalRejected', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      await oracleContract
        .connect(oracle)
        .rejectVerification(lifecycleId, 'Rejected');

      expect(await oracleContract.totalRejected()).to.equal(1);
    });
  });

  describe('Transfer Guards', function () {
    it('Should block transfer for ISSUED credits', async function () {
      const { tracker, lifecycleId, user1, user2 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await expect(
        tracker
          .connect(user1)
          .recordTransfer(
            lifecycleId,
            user1.address,
            user2.address,
            ethers.parseEther('100'),
            'test'
          )
      ).to.be.revertedWith(
        'CarbonCreditTracker: Credit not in transferable status'
      );
    });

    it('Should block transfer for PENDING_VERIFICATION credits', async function () {
      const { oracleContract, tracker, lifecycleId, user1, user2 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await expect(
        tracker
          .connect(user1)
          .recordTransfer(
            lifecycleId,
            user1.address,
            user2.address,
            ethers.parseEther('100'),
            'test'
          )
      ).to.be.revertedWith(
        'CarbonCreditTracker: Credit not in transferable status'
      );
    });

    it('Should allow transfer for ACTIVE (verified) credits', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1, user2 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      await expect(
        tracker
          .connect(user1)
          .recordTransfer(
            lifecycleId,
            user1.address,
            user2.address,
            ethers.parseEther('100'),
            'test transfer'
          )
      ).to.emit(tracker, 'CreditTransferred');
    });
  });

  describe('Retirement Guards', function () {
    it('Should block retirement for ISSUED credits', async function () {
      const { tracker, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await expect(
        tracker
          .connect(user1)
          .recordRetirement(
            lifecycleId,
            user1.address,
            ethers.parseEther('100'),
            'retire'
          )
      ).to.be.revertedWith(
        'CarbonCreditTracker: Credit not verified for retirement'
      );
    });

    it('Should block retirement for PENDING_VERIFICATION credits', async function () {
      const { oracleContract, tracker, lifecycleId, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await expect(
        tracker
          .connect(user1)
          .recordRetirement(
            lifecycleId,
            user1.address,
            ethers.parseEther('100'),
            'retire'
          )
      ).to.be.revertedWith(
        'CarbonCreditTracker: Credit not verified for retirement'
      );
    });

    it('Should allow retirement for verified credits', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      await expect(
        tracker
          .connect(user1)
          .recordRetirement(
            lifecycleId,
            user1.address,
            ethers.parseEther('100'),
            'retire for climate'
          )
      ).to.emit(tracker, 'CreditRetired');
    });
  });

  describe('Dispute Mechanism', function () {
    it('Should allow dispute during dispute window', async function () {
      const { oracleContract, lifecycleId, oracle, user1, disputer } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      await oracleContract
        .connect(disputer)
        .disputeVerification(lifecycleId);

      const request =
        await oracleContract.getVerificationRequest(lifecycleId);
      expect(request.status).to.equal(4); // DISPUTED
    });

    it('Should emit VerificationDisputed event', async function () {
      const { oracleContract, lifecycleId, oracle, user1, disputer } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      await expect(
        oracleContract.connect(disputer).disputeVerification(lifecycleId)
      ).to.emit(oracleContract, 'VerificationDisputed');
    });

    it('Should set credit to DISPUTED status', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1, disputer } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);
      await oracleContract
        .connect(disputer)
        .disputeVerification(lifecycleId);

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(6); // DISPUTED
    });

    it('Should reject dispute after window closes', async function () {
      const { oracleContract, lifecycleId, oracle, user1, disputer } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      // Advance time past dispute window (3 days + 1 second)
      await time.increase(3 * 24 * 60 * 60 + 1);

      await expect(
        oracleContract.connect(disputer).disputeVerification(lifecycleId)
      ).to.be.revertedWith('CarbonVerificationOracle: Dispute window closed');
    });

    it('Should reject dispute for unconfirmed credits', async function () {
      const { oracleContract, lifecycleId, disputer } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await expect(
        oracleContract.connect(disputer).disputeVerification(lifecycleId)
      ).to.be.revertedWith('CarbonVerificationOracle: Not confirmed');
    });

    it('Should increment totalDisputed', async function () {
      const { oracleContract, lifecycleId, oracle, user1, disputer } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);
      await oracleContract
        .connect(disputer)
        .disputeVerification(lifecycleId);

      expect(await oracleContract.totalDisputed()).to.equal(1);
    });
  });

  describe('Dispute Resolution', function () {
    async function deployAndDisputeFixture() {
      const fixture = await deployCarbonVerificationFixture();
      const { oracleContract, lifecycleId, oracle, user1, disputer } = fixture;

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);
      await oracleContract
        .connect(disputer)
        .disputeVerification(lifecycleId);

      return fixture;
    }

    it('Should resolve dispute in favor (credit returns to ACTIVE)', async function () {
      const { oracleContract, tracker, lifecycleId, oracle } =
        await loadFixture(deployAndDisputeFixture);

      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .resolveDispute(lifecycleId, true, attestation);

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(2); // ACTIVE
      expect(lifecycle.isVerified).to.be.true;
    });

    it('Should resolve dispute against (credit goes to CANCELLED)', async function () {
      const { oracleContract, tracker, lifecycleId, oracle } =
        await loadFixture(deployAndDisputeFixture);

      const attestation = await signAttestation(oracle, lifecycleId, false);
      await oracleContract
        .connect(oracle)
        .resolveDispute(lifecycleId, false, attestation);

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(7); // CANCELLED
      expect(lifecycle.isVerified).to.be.false;
    });

    it('Should emit DisputeResolved event', async function () {
      const { oracleContract, lifecycleId, oracle } = await loadFixture(
        deployAndDisputeFixture
      );

      const attestation = await signAttestation(oracle, lifecycleId, true);

      await expect(
        oracleContract
          .connect(oracle)
          .resolveDispute(lifecycleId, true, attestation)
      )
        .to.emit(oracleContract, 'DisputeResolved')
        .withArgs(lifecycleId, oracle.address, true);
    });

    it('Should reject from non-oracle caller', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployAndDisputeFixture
      );

      const attestation = await signAttestation(user1, lifecycleId, true);

      await expect(
        oracleContract
          .connect(user1)
          .resolveDispute(lifecycleId, true, attestation)
      ).to.be.revertedWithCustomError(oracleContract, 'AccessControlUnauthorizedAccount').withArgs(user1.address, await oracleContract.VERIFICATION_ORACLE_ROLE());
    });

    it('Should reject for non-disputed request', async function () {
      const { oracleContract, oracle, issuer, tracker } = await loadFixture(
        deployCarbonVerificationFixture
      );

      // Create a new lifecycle that is just pending (not disputed)
      const tx = await tracker
        .connect(issuer)
        .createLifecycle(99, 'PROJ-99', 'SN-99', 'GS', issuer.address, ethers.parseEther('500'));
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log) => {
          try {
            return tracker.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((parsed) => parsed && parsed.name === 'CreditLifecycleCreated');
      const newLifecycleId = event.args.lifecycleId;

      await oracleContract.connect(oracle).requestVerification(newLifecycleId);
      const attestation = await signAttestation(oracle, newLifecycleId, true);

      await expect(
        oracleContract
          .connect(oracle)
          .resolveDispute(newLifecycleId, true, attestation)
      ).to.be.revertedWith('CarbonVerificationOracle: Not disputed');
    });
  });

  describe('Timeout Handling', function () {
    it('Should allow timeout after VERIFICATION_TIMEOUT', async function () {
      const { oracleContract, tracker, lifecycleId, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      // Advance time past 7 days
      await time.increase(7 * 24 * 60 * 60 + 1);

      await oracleContract.connect(user1).handleTimeout(lifecycleId);

      const request =
        await oracleContract.getVerificationRequest(lifecycleId);
      expect(request.status).to.equal(6); // TIMED_OUT

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(7); // CANCELLED
    });

    it('Should reject timeout before deadline', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await expect(
        oracleContract.connect(user1).handleTimeout(lifecycleId)
      ).to.be.revertedWith('CarbonVerificationOracle: Not timed out yet');
    });

    it('Should emit VerificationTimedOut event', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await time.increase(7 * 24 * 60 * 60 + 1);

      await expect(
        oracleContract.connect(user1).handleTimeout(lifecycleId)
      ).to.emit(oracleContract, 'VerificationTimedOut');
    });

    it('Should reject timeout for non-pending request', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      await time.increase(7 * 24 * 60 * 60 + 1);

      await expect(
        oracleContract.connect(user1).handleTimeout(lifecycleId)
      ).to.be.revertedWith('CarbonVerificationOracle: Not pending');
    });
  });

  describe('Full Lifecycle Integration', function () {
    it('ISSUED -> PENDING -> CONFIRMED(ACTIVE) -> transfer works', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1, user2 } =
        await loadFixture(deployCarbonVerificationFixture);

      // Verify lifecycle starts as ISSUED
      let lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(0); // ISSUED

      // Request verification
      await oracleContract.connect(user1).requestVerification(lifecycleId);
      lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(1); // PENDING_VERIFICATION

      // Confirm verification
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);
      lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(2); // ACTIVE
      expect(lifecycle.isVerified).to.be.true;

      // Transfer should now work
      await tracker
        .connect(user1)
        .recordTransfer(
          lifecycleId,
          user1.address,
          user2.address,
          ethers.parseEther('100'),
          'sale'
        );
    });

    it('ISSUED -> PENDING -> REJECTED(CANCELLED)', async function () {
      const { oracleContract, tracker, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      await oracleContract
        .connect(oracle)
        .rejectVerification(lifecycleId, 'Fraudulent claim');

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(7); // CANCELLED
      expect(lifecycle.isVerified).to.be.false;
    });

    it('ISSUED -> PENDING -> CONFIRMED -> DISPUTED -> resolved true -> ACTIVE', async function () {
      const {
        oracleContract,
        tracker,
        lifecycleId,
        oracle,
        user1,
        disputer,
      } = await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      let attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      // Dispute
      await oracleContract
        .connect(disputer)
        .disputeVerification(lifecycleId);
      let lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(6); // DISPUTED
      expect(lifecycle.isVerified).to.be.false;

      // Resolve in favor
      attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .resolveDispute(lifecycleId, true, attestation);

      lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(2); // ACTIVE
      expect(lifecycle.isVerified).to.be.true;
    });

    it('ISSUED -> PENDING -> timeout -> CANCELLED', async function () {
      const { oracleContract, tracker, lifecycleId, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      await time.increase(7 * 24 * 60 * 60 + 1);

      await oracleContract.connect(user1).handleTimeout(lifecycleId);

      const lifecycle = await tracker.getLifecycle(lifecycleId);
      expect(lifecycle.status).to.equal(7); // CANCELLED
    });
  });

  describe('View Functions', function () {
    it('Should return correct stats', async function () {
      const { oracleContract, lifecycleId, oracle, user1 } =
        await loadFixture(deployCarbonVerificationFixture);

      await oracleContract.connect(user1).requestVerification(lifecycleId);
      const attestation = await signAttestation(oracle, lifecycleId, true);
      await oracleContract
        .connect(oracle)
        .confirmVerification(lifecycleId, attestation);

      const [requests, confirmed, rejected, disputed] =
        await oracleContract.getStats();
      expect(requests).to.equal(1);
      expect(confirmed).to.equal(1);
      expect(rejected).to.equal(0);
      expect(disputed).to.equal(0);
    });

    it('Should return verification status', async function () {
      const { oracleContract, lifecycleId, user1 } = await loadFixture(
        deployCarbonVerificationFixture
      );

      expect(await oracleContract.getVerificationStatus(lifecycleId)).to.equal(
        0
      ); // NONE

      await oracleContract.connect(user1).requestVerification(lifecycleId);

      expect(await oracleContract.getVerificationStatus(lifecycleId)).to.equal(
        1
      ); // PENDING
    });
  });
});
