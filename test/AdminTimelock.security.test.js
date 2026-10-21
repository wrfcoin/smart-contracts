const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('Admin Timelock Security Tests', function () {
  const TIMELOCK_DELAY = 48 * 60 * 60; // 48 hours in seconds

  // ======== PeerReviewIncentives ========

  describe('PeerReviewIncentives', function () {
    async function deployPeerReviewFixture() {
      const [admin, reviewer1, reviewer2, nonAdmin] = await ethers.getSigners();

      const PeerReview = await ethers.getContractFactory('PeerReviewIncentives');
      const peerReview = await PeerReview.deploy();

      // Register a reviewer
      await peerReview.connect(reviewer1).registerReviewer('PhD Climate Science', 1);

      return { peerReview, admin, reviewer1, reviewer2, nonAdmin };
    }

    describe('Reputation Score Timelock', function () {
      it('should queue a reputation change, not apply immediately', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        // Queue a reputation change
        const tx = await peerReview.queueReputationChange(reviewer1.address, true);
        const receipt = await tx.wait();

        // Get the changeId from the event
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const parsed = peerReview.interface.parseLog(event);
        const changeId = parsed.args.changeId;

        // Verify the reputation was NOT changed yet (still at initial 100)
        const stats = await peerReview.getReviewerStats(reviewer1.address);
        expect(stats.reputationScore).to.equal(100);

        // Verify the pending change exists
        const pending = await peerReview.pendingReputationChanges(changeId);
        expect(pending.reviewer).to.equal(reviewer1.address);
        expect(pending.accurate).to.equal(true);
        expect(pending.executed).to.equal(false);
        expect(pending.cancelled).to.equal(false);
      });

      it('should revert execution before timelock delay expires', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        const tx = await peerReview.queueReputationChange(reviewer1.address, true);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        // Try to execute immediately - should revert
        await expect(peerReview.executeReputationChange(changeId)).to.be.revertedWith(
          'Timelock not expired'
        );

        // Advance time but not enough (only 24 hours)
        await time.increase(24 * 60 * 60);
        await expect(peerReview.executeReputationChange(changeId)).to.be.revertedWith(
          'Timelock not expired'
        );
      });

      it('should succeed execution after timelock delay expires', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        // Use accurate=false so score decreases: (100 * 90) / 100 = 90
        const tx = await peerReview.queueReputationChange(reviewer1.address, false);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        // Advance time past the timelock
        await time.increase(TIMELOCK_DELAY + 1);

        // Execute should succeed
        await expect(peerReview.executeReputationChange(changeId))
          .to.emit(peerReview, 'ReputationChangeExecuted');

        // Verify reputation was decreased: (100 * 90) / 100 = 90
        const stats = await peerReview.getReviewerStats(reviewer1.address);
        expect(stats.reputationScore).to.equal(90);
      });

      it('should not allow double execution', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        const tx = await peerReview.queueReputationChange(reviewer1.address, true);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        await time.increase(TIMELOCK_DELAY + 1);
        await peerReview.executeReputationChange(changeId);

        // Try executing again
        await expect(peerReview.executeReputationChange(changeId)).to.be.revertedWith(
          'Change already executed'
        );
      });

      it('should allow cancelling a queued change', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        const tx = await peerReview.queueReputationChange(reviewer1.address, true);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        await expect(peerReview.cancelReputationChange(changeId))
          .to.emit(peerReview, 'ReputationChangeCancelled')
          .withArgs(changeId, admin.address);

        // Cannot execute after cancelling
        await time.increase(TIMELOCK_DELAY + 1);
        await expect(peerReview.executeReputationChange(changeId)).to.be.revertedWith(
          'Change was cancelled'
        );
      });

      it('should revert for non-admin callers', async function () {
        const { peerReview, reviewer1, nonAdmin } = await loadFixture(deployPeerReviewFixture);

        await expect(
          peerReview.connect(nonAdmin).queueReputationChange(reviewer1.address, true)
        ).to.be.revertedWithCustomError(peerReview, 'AccessControlUnauthorizedAccount').withArgs(nonAdmin.address, await peerReview.DEFAULT_ADMIN_ROLE());
      });
    });

    describe('Reputation Score Bounds', function () {
      it('should clamp reputation to minimum 10 (cannot go below)', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        // Repeatedly apply inaccurate changes to drive score toward 0
        // Starting at 100, each iteration does score = (score * 90) / 100
        // After ~25 iterations the score should hit the floor of 10
        for (let i = 0; i < 30; i++) {
          const tx = await peerReview.queueReputationChange(reviewer1.address, false);
          const receipt = await tx.wait();
          const event = receipt.logs.find(
            (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
          );
          const changeId = peerReview.interface.parseLog(event).args.changeId;

          await time.increase(TIMELOCK_DELAY + 1);
          await peerReview.executeReputationChange(changeId);
        }

        const stats = await peerReview.getReviewerStats(reviewer1.address);
        expect(stats.reputationScore).to.equal(10);
      });

      it('should clamp reputation to maximum 1000 (cannot go above)', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        // Directly set reviewers[reviewer1].reputationScore to 2000 via storage manipulation
        // reviewers mapping is at storage slot 4 in the contract layout
        // For mapping(address => Reviewer), base = keccak256(abi.encode(address, 4))
        // reputationScore is at offset +4 in the Reviewer struct
        const slot = ethers.keccak256(
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address', 'uint256'],
            [reviewer1.address, 4]
          )
        );
        const reputationSlot = ethers.toBeHex(BigInt(slot) + 4n, 32);
        await ethers.provider.send('hardhat_setStorageAt', [
          await peerReview.getAddress(),
          reputationSlot,
          ethers.toBeHex(2000, 32),
        ]);

        // Verify it was set
        let stats = await peerReview.getReviewerStats(reviewer1.address);
        expect(stats.reputationScore).to.equal(2000);

        // Queue and execute an accurate change: (2000 * 95 + 500) / 100 = 1905 -> clamped to 1000
        const tx = await peerReview.queueReputationChange(reviewer1.address, true);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        await time.increase(TIMELOCK_DELAY + 1);
        await peerReview.executeReputationChange(changeId);

        stats = await peerReview.getReviewerStats(reviewer1.address);
        expect(stats.reputationScore).to.equal(1000);
      });
    });

    describe('Reputation Change Expiry', function () {
      it('should revert execution after expiry window (7 days past timelock)', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        const tx = await peerReview.queueReputationChange(reviewer1.address, true);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        // Advance past timelock + 7 days expiry
        await time.increase(TIMELOCK_DELAY + 7 * 24 * 60 * 60 + 1);

        await expect(peerReview.executeReputationChange(changeId)).to.be.revertedWith(
          'Change expired'
        );
      });

      it('should allow execution within expiry window', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        const tx = await peerReview.queueReputationChange(reviewer1.address, false);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        // Advance to just within the expiry window (timelock + 6 days)
        await time.increase(TIMELOCK_DELAY + 6 * 24 * 60 * 60);

        await expect(peerReview.executeReputationChange(changeId))
          .to.emit(peerReview, 'ReputationChangeExecuted');
      });
    });

    describe('Admin Action Events', function () {
      it('should emit ReviewerVerified event on verifyReviewer', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        await expect(peerReview.verifyReviewer(reviewer1.address))
          .to.emit(peerReview, 'ReviewerVerified')
          .withArgs(reviewer1.address, admin.address);
      });

      it('should emit ReputationChangeQueued event on queue', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        await expect(peerReview.queueReputationChange(reviewer1.address, true)).to.emit(
          peerReview,
          'ReputationChangeQueued'
        );
      });

      it('should emit both ReputationChangeExecuted and ReputationUpdated on execute', async function () {
        const { peerReview, admin, reviewer1 } = await loadFixture(deployPeerReviewFixture);

        const tx = await peerReview.queueReputationChange(reviewer1.address, false);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => peerReview.interface.parseLog(l)?.name === 'ReputationChangeQueued'
        );
        const changeId = peerReview.interface.parseLog(event).args.changeId;

        await time.increase(TIMELOCK_DELAY + 1);

        const execTx = peerReview.executeReputationChange(changeId);
        await expect(execTx).to.emit(peerReview, 'ReputationChangeExecuted');
        await expect(execTx).to.emit(peerReview, 'ReputationUpdated');
      });
    });
  });

  // ======== ModelTrainingRewards ========

  describe('ModelTrainingRewards', function () {
    async function deployModelTrainingFixture() {
      const [admin, contributor1, contributor2, nonAdmin] = await ethers.getSigners();

      // Deploy mock ERC20 token
      const MockToken = await ethers.getContractFactory('MockERC20');
      const token = await MockToken.deploy('WRF Token', 'WRF', 18);

      const ModelTraining = await ethers.getContractFactory('ModelTrainingRewards');
      const modelTraining = await ModelTraining.deploy(await token.getAddress());

      // Register a contributor
      await modelTraining.connect(contributor1).registerContributor('Contributor1', [0]); // FLUX

      return { modelTraining, token, admin, contributor1, contributor2, nonAdmin };
    }

    describe('Network Multiplier Timelock', function () {
      it('should queue a multiplier change, not apply immediately', async function () {
        const { modelTraining, admin } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200); // FLUX -> 200
        const receipt = await tx.wait();

        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const parsed = modelTraining.interface.parseLog(event);
        const changeId = parsed.args.changeId;

        // Verify multiplier was NOT changed yet
        const currentMultiplier = await modelTraining.networkRewardMultipliers(0);
        expect(currentMultiplier).to.equal(110); // Original FLUX value

        // Verify pending change exists
        const pending = await modelTraining.pendingMultiplierChanges(changeId);
        expect(pending.newMultiplier).to.equal(200);
        expect(pending.executed).to.equal(false);
      });

      it('should revert execution before timelock delay expires', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        // Try immediate execution
        await expect(modelTraining.executeNetworkMultiplierChange(changeId)).to.be.revertedWith(
          'Timelock not expired'
        );

        // Try after partial delay
        await time.increase(24 * 60 * 60);
        await expect(modelTraining.executeNetworkMultiplierChange(changeId)).to.be.revertedWith(
          'Timelock not expired'
        );
      });

      it('should succeed execution after timelock delay expires', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        await time.increase(TIMELOCK_DELAY + 1);

        await expect(modelTraining.executeNetworkMultiplierChange(changeId))
          .to.emit(modelTraining, 'NetworkMultiplierChangeExecuted')
          .withArgs(changeId, 0, 110, 200);

        // Verify the multiplier was updated
        const newMultiplier = await modelTraining.networkRewardMultipliers(0);
        expect(newMultiplier).to.equal(200);
      });

      it('should not allow double execution', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        await time.increase(TIMELOCK_DELAY + 1);
        await modelTraining.executeNetworkMultiplierChange(changeId);

        await expect(modelTraining.executeNetworkMultiplierChange(changeId)).to.be.revertedWith(
          'Change already executed'
        );
      });

      it('should allow cancelling a queued change', async function () {
        const { modelTraining, admin } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        await expect(modelTraining.cancelNetworkMultiplierChange(changeId))
          .to.emit(modelTraining, 'NetworkMultiplierChangeCancelled')
          .withArgs(changeId, admin.address);

        await time.increase(TIMELOCK_DELAY + 1);
        await expect(modelTraining.executeNetworkMultiplierChange(changeId)).to.be.revertedWith(
          'Change was cancelled'
        );
      });

      it('should enforce bounds on multiplier values', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        // Zero multiplier
        await expect(modelTraining.queueNetworkMultiplierChange(0, 0)).to.be.revertedWith(
          'Multiplier must be positive'
        );

        // Exceeds max
        await expect(modelTraining.queueNetworkMultiplierChange(0, 501)).to.be.revertedWith(
          'Multiplier exceeds maximum'
        );

        // Max value should work
        await expect(modelTraining.queueNetworkMultiplierChange(0, 500)).to.not.be.reverted;
      });

      it('should revert for non-admin callers', async function () {
        const { modelTraining, nonAdmin } = await loadFixture(deployModelTrainingFixture);

        await expect(
          modelTraining.connect(nonAdmin).queueNetworkMultiplierChange(0, 200)
        ).to.be.revertedWithCustomError(modelTraining, 'AccessControlUnauthorizedAccount').withArgs(nonAdmin.address, await modelTraining.DEFAULT_ADMIN_ROLE());
      });
    });

    describe('Network Multiplier Change Expiry', function () {
      it('should revert execution after expiry window (7 days past timelock)', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        // Advance past timelock + 7 days expiry
        await time.increase(TIMELOCK_DELAY + 7 * 24 * 60 * 60 + 1);

        await expect(modelTraining.executeNetworkMultiplierChange(changeId)).to.be.revertedWith(
          'Change expired'
        );
      });

      it('should allow execution within expiry window', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        // Advance to just within the expiry window (timelock + 6 days)
        await time.increase(TIMELOCK_DELAY + 6 * 24 * 60 * 60);

        await expect(modelTraining.executeNetworkMultiplierChange(changeId))
          .to.emit(modelTraining, 'NetworkMultiplierChangeExecuted');
      });
    });

    describe('Admin Action Events', function () {
      it('should emit ContributorVerifiedByAdmin event on verifyContributor', async function () {
        const { modelTraining, admin, contributor1 } = await loadFixture(
          deployModelTrainingFixture
        );

        await expect(modelTraining.verifyContributor(contributor1.address))
          .to.emit(modelTraining, 'ContributorVerifiedByAdmin')
          .withArgs(contributor1.address, admin.address);
      });

      it('should emit NetworkMultiplierChangeQueued event on queue', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        await expect(modelTraining.queueNetworkMultiplierChange(0, 200)).to.emit(
          modelTraining,
          'NetworkMultiplierChangeQueued'
        );
      });

      it('should emit NetworkMultiplierChangeExecuted event on execute', async function () {
        const { modelTraining } = await loadFixture(deployModelTrainingFixture);

        const tx = await modelTraining.queueNetworkMultiplierChange(0, 200);
        const receipt = await tx.wait();
        const event = receipt.logs.find(
          (l) => modelTraining.interface.parseLog(l)?.name === 'NetworkMultiplierChangeQueued'
        );
        const changeId = modelTraining.interface.parseLog(event).args.changeId;

        await time.increase(TIMELOCK_DELAY + 1);

        await expect(modelTraining.executeNetworkMultiplierChange(changeId)).to.emit(
          modelTraining,
          'NetworkMultiplierChangeExecuted'
        );
      });
    });
  });
});
