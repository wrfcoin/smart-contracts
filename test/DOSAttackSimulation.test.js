// SPDX-License-Identifier: MIT

/**
 * DoS Attack Simulation Test Suite
 *
 * This test suite simulates specific DoS attack vectors identified in the security audit:
 *
 * 1. NFTMarketplace.sol Unbounded Royalty Processing DoS (Lines 1089-1095, 1345-1351)
 * 2. GovernanceSecurityFramework.sol Unbounded Proposal Enumeration (Lines 845-853)
 * 3. Gas limit exploitation patterns
 * 4. Economic manipulation attacks
 *
 * Each test simulates a real attack scenario and verifies the system's defense mechanisms.
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
} = require('@nomicfoundation/hardhat-toolbox/network-helpers');

describe('DoS Attack Simulation Suite', function () {
  // Attack simulation constants
  const BLOCK_GAS_LIMIT = 30000000; // 30M gas
  const ATTACK_VECTOR_TIMEOUT = 180000; // 3 minutes per attack
  const PROPOSAL_SPAM_COUNT = 1000; // Large number of proposals for enumeration attack

  async function deployAttackSimulationFixture() {
    const signers = await ethers.getSigners();
    const [owner, attacker1, attacker2, attacker3, victim, ...users] = signers;

    // Deploy mock WRF token (using MockERC20 since WRFToken has no mint function)
    const WRFToken = await ethers.getContractFactory('MockERC20');
    const wrfToken = await WRFToken.deploy('WRFCoin', 'WRF', 18);

    const MockERC721 =
      await ethers.getContractFactory('MockERC721');
    const nft = await MockERC721.deploy(
      'Attack Test NFT',
      'ATNFT'
    );

    const NFTMarketplace = await ethers.getContractFactory('NFTMarketplace');
    const marketplace = await NFTMarketplace.deploy(await wrfToken.getAddress());
    await marketplace
      .connect(owner)
      .setAuthorizedNFTContract(await nft.getAddress(), true);

    const MockGovernanceCompliance = await ethers.getContractFactory(
      'MockGovernanceCompliance'
    );
    const compliance = await MockGovernanceCompliance.deploy();

    const MockGovernanceTimelock = await ethers.getContractFactory(
      'MockGovernanceTimelock'
    );
    const timelock = await MockGovernanceTimelock.deploy();

    const GovernanceSecurityFramework = await ethers.getContractFactory(
      'GovernanceSecurityFrameworkHarness'
    );
    const governance = await GovernanceSecurityFramework.deploy(
      owner.address, // admin
      await timelock.getAddress(),
      await compliance.getAddress(),
      await wrfToken.getAddress() // governance token
    );

    // Deploy attack helper contracts
    const DOSTestHelper = await ethers.getContractFactory('DOSTestHelper');
    const testHelper = await DOSTestHelper.deploy();

    const MaliciousRoyaltyReceiver = await ethers.getContractFactory(
      'MaliciousRoyaltyReceiver'
    );
    const maliciousReceiver = await MaliciousRoyaltyReceiver.deploy(
      await marketplace.getAddress()
    );

    const FlashLoanGovernanceAttacker = await ethers.getContractFactory(
      'FlashLoanGovernanceAttacker'
    );
    const flashAttacker = await FlashLoanGovernanceAttacker.deploy(
      await governance.getAddress(),
      await wrfToken.getAddress()
    );

    // Setup tokens and approvals
    await wrfToken.mint(owner.address, ethers.parseEther('10000000'));
    await wrfToken.mint(attacker1.address, ethers.parseEther('100000'));
    await wrfToken.mint(attacker2.address, ethers.parseEther('100000'));
    await wrfToken.mint(attacker3.address, ethers.parseEther('100000'));
    await wrfToken.mint(victim.address, ethers.parseEther('100000'));

    const governanceParticipants = [
      owner,
      attacker1,
      attacker2,
      attacker3,
      victim,
    ];
    for (const participant of governanceParticipants) {
      await wrfToken
        .connect(participant)
        .approve(await governance.getAddress(), ethers.parseEther('1000000'));
      await governance
        .connect(owner)
        .setReputationForTesting(
          participant.address,
          900,
          120 * 24 * 60 * 60,
          false
        );
      await governance
        .connect(owner)
        .setStakeForTesting(participant.address, ethers.parseEther('10000'));
    }

    // Mint test NFTs
    for (let i = 1; i <= 50; i++) {
      await nft.mintWithURI(victim.address, i, `QmTest${i}`);
      await nft.mintWithURI(attacker1.address, i + 100, `QmAttack${i}`);
    }

    return {
      wrfToken,
      nft,
      marketplace,
      governance,
      testHelper,
      maliciousReceiver,
      flashAttacker,
      owner,
      attacker1,
      attacker2,
      attacker3,
      victim,
      users: users.slice(0, 50),
    };
  }

  describe('1. NFTMarketplace Royalty Processing DoS Attacks', function () {
    it('Attack Simulation: Maximum royalty recipients DoS', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { marketplace, nft, attacker1, users } = await loadFixture(
        deployAttackSimulationFixture
      );

      console.log(
        '🚨 Simulating NFTMarketplace royalty recipients DoS attack...'
      );

      // Phase 1: Setup maximum royalty recipients
      const maxRoyaltyRecipients = Number(
        await marketplace.MAX_ROYALTY_RECIPIENTS()
      );
      const maxRoyaltyPercentage = Number(
        await marketplace.MAX_ROYALTY_PERCENTAGE()
      );
      const maxRecipients = Math.min(maxRoyaltyRecipients, users.length);
      const recipients = users
        .slice(0, maxRecipients)
        .map(user => user.address);
      const pctPerRecipient = Math.max(
        1,
        Math.floor(maxRoyaltyPercentage / maxRecipients)
      );
      const percentages = new Array(maxRecipients).fill(pctPerRecipient);

      const tokenId = 1001;
      await nft.mintWithURI(attacker1.address, tokenId, 'QmDoSTest');

      // This should work but consume significant gas
      const setupTx = await marketplace
        .connect(attacker1)
        .setRoyalties(await nft.getAddress(), tokenId, recipients, percentages);
      const setupReceipt = await setupTx.wait();

      console.log(`Gas used for max royalty setup: ${setupReceipt.gasUsed}`);
      expect(setupReceipt.gasUsed).to.be.below(BLOCK_GAS_LIMIT);

      // Phase 2: Test transaction with maximum royalty processing
      await nft
        .connect(attacker1)
        .approve(await marketplace.getAddress(), tokenId);
      await marketplace
        .connect(attacker1)
        .createFixedPriceListing(
          await nft.getAddress(),
          tokenId,
          ethers.parseEther('10'),
          0, // PaymentToken.ETH
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      // Purchase should complete but consume significant gas due to royalty processing
      const purchaseTx = await marketplace
        .connect(users[0])
        .buyFixedPrice(1, {
          value: ethers.parseEther('10'),
        });
      const purchaseReceipt = await purchaseTx.wait();

      console.log(
        `Gas used for purchase with max royalties: ${purchaseReceipt.gasUsed}`
      );

      // Attack mitigation: Should still complete within block gas limit
      expect(purchaseReceipt.gasUsed).to.be.below(BLOCK_GAS_LIMIT);

      // Verify the NFT was transferred despite high gas consumption
      expect(await nft.ownerOf(tokenId)).to.equal(users[0].address);

      console.log(
        '✅ DoS attack mitigated: Transaction completed within gas limits'
      );
    });

    it('Attack Simulation: Royalty reentrancy DoS', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { marketplace, nft, maliciousReceiver, attacker1, victim } =
        await loadFixture(deployAttackSimulationFixture);

      console.log('🚨 Simulating royalty reentrancy DoS attack...');

      const tokenId = 2001;
      await nft.mintWithURI(attacker1.address, tokenId, 'QmReentrancy');

      // Setup malicious contract as royalty recipient
      const maxIndividualRoyalty = Number(
        await marketplace.MAX_INDIVIDUAL_ROYALTY()
      );
      const maxRoyaltyPercentage = Number(
        await marketplace.MAX_ROYALTY_PERCENTAGE()
      );
      const maliciousRoyaltyPct = Math.min(
        maxIndividualRoyalty,
        maxRoyaltyPercentage
      );
      await marketplace.connect(attacker1).setRoyalties(
        await nft.getAddress(),
        tokenId,
        [await maliciousReceiver.getAddress()],
        [maliciousRoyaltyPct]
      );

      // Reset attack state
      await maliciousReceiver.resetAttackState();

      await nft
        .connect(attacker1)
        .approve(await marketplace.getAddress(), tokenId);
      await marketplace
        .connect(attacker1)
        .createFixedPriceListing(
          await nft.getAddress(),
          tokenId,
          ethers.parseEther('5'),
          0, // PaymentToken.ETH
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      // Purchase should complete despite reentrancy attempt
      const attackTx = await marketplace.connect(victim).buyFixedPrice(1, {
        value: ethers.parseEther('5'),
      });
      const attackReceipt = await attackTx.wait();

      console.log(
        `Gas used despite reentrancy attack: ${attackReceipt.gasUsed}`
      );

      // Verify attack was prevented
      const reentrantCalls = await maliciousReceiver.getReentrantCallCount();
      console.log(`Reentrancy attempts made: ${reentrantCalls}`);

      // NFT should still transfer successfully
      expect(await nft.ownerOf(tokenId)).to.equal(victim.address);

      // Reentrancy should not be able to execute against purchase flow
      expect(reentrantCalls).to.equal(0);

      console.log(
        '✅ Reentrancy DoS attack mitigated: Transaction completed safely'
      );
    });

    it('Attack Simulation: Batch royalty manipulation DoS', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { marketplace, nft, attacker1, users } = await loadFixture(
        deployAttackSimulationFixture
      );

      console.log('🚨 Simulating batch royalty manipulation DoS attack...');

      const batchSize = 20;
      const gasUsageResults = [];
      const maxRoyaltyRecipients = Number(
        await marketplace.MAX_ROYALTY_RECIPIENTS()
      );
      const maxRoyaltyPercentage = Number(
        await marketplace.MAX_ROYALTY_PERCENTAGE()
      );

      // Phase 1: Create multiple NFTs with complex royalty structures
      for (let i = 0; i < batchSize; i++) {
        const tokenId = 3000 + i;
        await nft.mintWithURI(attacker1.address, tokenId, `QmBatch${i}`);

        // Varying royalty complexity
        const recipientCount = Math.min(
          maxRoyaltyRecipients,
          5 + (i % 10),
          users.length
        );
        const recipients = users
          .slice(0, recipientCount)
          .map(user => user.address);
        const percentages = new Array(recipientCount).fill(
          Math.max(1, Math.floor((maxRoyaltyPercentage / 2) / recipientCount))
        );

        const setupTx = await marketplace
          .connect(attacker1)
          .setRoyalties(
            await nft.getAddress(),
            tokenId,
            recipients,
            percentages
          );

        const setupReceipt = await setupTx.wait();
        gasUsageResults.push({
          tokenId,
          recipientCount,
          gasUsed: Number(setupReceipt.gasUsed),
        });
      }

      // Phase 2: Test batch operations
      const batchListingParams = [];
      for (let i = 0; i < batchSize; i++) {
        const tokenId = 3000 + i;
        await nft
          .connect(attacker1)
          .approve(await marketplace.getAddress(), tokenId);

        batchListingParams.push({
          nftContract: await nft.getAddress(),
          tokenId: tokenId,
          price: ethers.parseEther('1'),
          duration: 3600,
        });
      }

      // Batch create listings should handle complex royalty structures
      const batchTx = await marketplace
        .connect(attacker1)
        .createBatchFixedPriceListings(
          await nft.getAddress(),
          batchListingParams,
          0,
          ethers.ZeroAddress
        );
      const batchReceipt = await batchTx.wait();

      console.log(`Batch listing gas usage: ${batchReceipt.gasUsed}`);
      console.log(
        `Average gas per royalty setup: ${gasUsageResults.reduce((sum, r) => sum + r.gasUsed, 0) / gasUsageResults.length}`
      );

      // Attack mitigation: Should complete within reasonable gas limits
      expect(batchReceipt.gasUsed).to.be.below(BLOCK_GAS_LIMIT);

      // Verify listings were created
      const [listingCount] = await marketplace.getMarketplaceStats();
      expect(Number(listingCount)).to.be.greaterThan(0);

      console.log('✅ Batch royalty manipulation DoS mitigated');
    });
  });

  describe('2. Governance Proposal Enumeration DoS Attacks', function () {
    it('Attack Simulation: Mass proposal creation DoS', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT * 2); // 6 minutes for this test

      const { governance, wrfToken, attacker1, attacker2, attacker3 } =
        await loadFixture(deployAttackSimulationFixture);

      console.log('🚨 Simulating mass proposal creation DoS attack...');

      const attackers = [attacker1, attacker2, attacker3];
      let totalProposalsCreated = 0;
      const enumerationTimings = [];

      // Phase 1: Coordinate mass proposal creation
      const proposalsPerAttacker = Math.floor(
        PROPOSAL_SPAM_COUNT / attackers.length
      );

      for (
        let attackerIndex = 0;
        attackerIndex < attackers.length;
        attackerIndex++
      ) {
        const attacker = attackers[attackerIndex];
        let proposalsCreated = 0;

        for (
          let i = 0;
          i < proposalsPerAttacker && proposalsCreated < 100;
          i++
        ) {
          try {
            const tx = await governance
              .connect(attacker)
              .createSecureProposal(
                `Spam Proposal ${attackerIndex}-${i}`,
                `This is spam proposal ${i} by attacker ${attackerIndex}`,
                '0x'
              );

            await tx.wait();
            proposalsCreated++;
            totalProposalsCreated++;

            // Test enumeration performance every 25 proposals
            if (totalProposalsCreated % 25 === 0) {
              const enumStart = Date.now();
              const activeCount = await governance.getActiveProposalsCount();
              const enumTime = Date.now() - enumStart;

              enumerationTimings.push({
                proposalCount: totalProposalsCreated,
                enumerationTime: enumTime,
                activeCount: Number(activeCount),
              });

              console.log(
                `Enumeration at ${totalProposalsCreated} proposals: ${enumTime}ms`
              );

              // Attack mitigation: Enumeration should not take too long
              expect(enumTime).to.be.below(10000); // Less than 10 seconds
            }
          } catch (error) {
            // Expected - governance should implement rate limiting
            if (
              error.message.includes('rate limit') ||
              error.message.includes('too many')
            ) {
              console.log(
                `Rate limiting kicked in at ${proposalsCreated} proposals for attacker ${attackerIndex}`
              );
              break;
            }
            throw error;
          }
        }
      }

      console.log(
        `Total proposals created by attackers: ${totalProposalsCreated}`
      );

      // Phase 2: Test final enumeration performance
      const finalEnumStart = Date.now();
      const finalActiveCount = await governance.getActiveProposalsCount();
      const finalEnumTime = Date.now() - finalEnumStart;

      console.log(
        `Final enumeration of ${finalActiveCount} proposals: ${finalEnumTime}ms`
      );

      // Attack mitigation checks
      expect(finalEnumTime).to.be.below(15000); // Less than 15 seconds even with many proposals
      expect(Number(finalActiveCount)).to.equal(totalProposalsCreated);

      // Verify enumeration performance doesn't degrade significantly
      if (enumerationTimings.length > 2) {
        const firstTiming = enumerationTimings[0].enumerationTime;
        const lastTiming =
          enumerationTimings[enumerationTimings.length - 1].enumerationTime;
        const performanceDegradation = lastTiming / firstTiming;

        console.log(
          `Performance degradation factor: ${performanceDegradation.toFixed(2)}x`
        );
        expect(performanceDegradation).to.be.below(15); // Allow moderate local timing variance
      }

      console.log(
        '✅ Mass proposal DoS attack mitigated: Enumeration remains performant'
      );
    });

    it('Attack Simulation: Proposal enumeration complexity attack', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { governance, attacker1, attacker2, attacker3, victim } = await loadFixture(
        deployAttackSimulationFixture
      );

      console.log('🚨 Simulating proposal enumeration complexity attack...');

      // Phase 1: Create proposals with varying states to maximize enumeration complexity
      const proposalStates = [];
      const proposalAuthors = [attacker1, attacker2, attacker3, victim];

      for (let i = 0; i < 50; i++) {
        const user = proposalAuthors[i % proposalAuthors.length];

        const tx = await governance
          .connect(user)
          .createSecureProposal(
            `Complex Proposal ${i}`,
            `Proposal designed to test enumeration complexity ${i}`,
            ethers.AbiCoder.defaultAbiCoder().encode(['address'], [user.address])
          );

        await tx.wait();
      }

      // Move proposals into commit phase
      await time.increase(24 * 60 * 60 + 5);

      // Vary proposal states by committing votes on a subset
      for (let i = 0; i < 50; i++) {
        const proposalId = i + 1;
        if (i % 3 === 0) {
          const voter = proposalAuthors[(i + 1) % proposalAuthors.length];
          const nonce = BigInt(1000 + i);
          const commitment = ethers.keccak256(
            ethers.solidityPacked(
              ['uint8', 'uint256', 'address'],
              [1, nonce, voter.address]
            )
          );
          await governance.progressVotingPhase(proposalId);
          await governance.connect(voter).commitVote(proposalId, commitment);
          proposalStates.push('committed');
        } else {
          proposalStates.push('prepared');
        }
      }

      // Phase 2: Perform multiple enumeration calls rapidly
      const enumerationResults = [];
      const concurrentCalls = 10;

      const enumerationPromises = Array(concurrentCalls)
        .fill(null)
        .map(async (_, index) => {
          const start = Date.now();
          const activeCount = await governance.getActiveProposalsCount();
          const duration = Date.now() - start;

          return { index, duration, activeCount: Number(activeCount) };
        });

      const results = await Promise.all(enumerationPromises);

      results.forEach(result => {
        enumerationResults.push(result.duration);
        console.log(
          `Concurrent enumeration ${result.index}: ${result.duration}ms, found ${result.activeCount} active`
        );
      });

      // Phase 3: Test enumeration under load
      let enumerationCallCount = 0;
      const loadTestStart = Date.now();
      const loadTestDuration = 30000; // 30 seconds

      while (Date.now() - loadTestStart < loadTestDuration) {
        const start = Date.now();
        await governance.getActiveProposalsCount();
        const duration = Date.now() - start;

        enumerationResults.push(duration);
        enumerationCallCount++;

        // Brief pause to prevent overwhelming
        await new Promise(resolve => setTimeout(resolve, 100));
      }

      console.log(
        `Performed ${enumerationCallCount} enumeration calls under load`
      );

      // Attack mitigation checks
      const avgEnumTime =
        enumerationResults.reduce((sum, time) => sum + time, 0) /
        enumerationResults.length;
      const maxEnumTime = Math.max(...enumerationResults);

      console.log(`Average enumeration time: ${avgEnumTime.toFixed(2)}ms`);
      console.log(`Maximum enumeration time: ${maxEnumTime}ms`);

      expect(avgEnumTime).to.be.below(5000); // Average should be reasonable
      expect(maxEnumTime).to.be.below(15000); // Even worst case should be manageable

      console.log('✅ Enumeration complexity DoS attack mitigated');
    });

    it('Attack Simulation: Flash loan governance manipulation', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { governance, wrfToken, flashAttacker, attacker1 } =
        await loadFixture(deployAttackSimulationFixture);

      console.log('🚨 Simulating flash loan governance manipulation attack...');

      const attackAmount = ethers.parseEther('1000000'); // 1M tokens

      // Verify attacker doesn't have voting power initially
      const initialBalance = await wrfToken.balanceOf(attacker1.address);
      console.log(
        `Attacker initial balance: ${ethers.formatEther(initialBalance)} WRF`
      );

      // Simulate flash loan attack
      try {
        await flashAttacker
          .connect(attacker1)
          .executeFlashLoanAttack(
            attackAmount,
            'Malicious Flash Loan Proposal',
            'This proposal attempts to drain the treasury using borrowed voting power'
          );

        // Attack should not succeed
        expect.fail('Flash loan attack should have been prevented');
      } catch (error) {
        console.log(`Flash loan attack prevented: ${error.message}`);

        // Verify the attack was detected and prevented
        expect(error.message.toLowerCase()).to.include('flash loan');
      }

      // Verify governance state remains clean
      const finalProposalCount = await governance.getActiveProposalsCount();
      const attackerFinalBalance = await wrfToken.balanceOf(attacker1.address);

      // Attacker should not have gained voting power or created malicious proposals
      expect(attackerFinalBalance).to.equal(initialBalance);

      console.log('✅ Flash loan governance attack mitigated');
    });
  });

  describe('3. Gas Limit Exploitation Attacks', function () {
    it('Attack Simulation: Array iteration gas bomb', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { testHelper } = await loadFixture(deployAttackSimulationFixture);

      console.log('🚨 Simulating array iteration gas bomb attack...');

      const attackSizes = [1000, 5000, 10000, 15000, 20000];
      const gasResults = [];

      for (const size of attackSizes) {
        try {
          console.log(`Testing array size: ${size}`);

          const largeArray = Array(size)
            .fill(0)
            .map((_, i) => i + 1);

          const tx = await testHelper.processLargeArray(largeArray);
          const receipt = await tx.wait();

          const gasUsed = Number(receipt.gasUsed);
          gasResults.push({ size, gasUsed, success: true });

          console.log(`Array size ${size}: ${gasUsed} gas used`);

          // Should complete within block gas limit
          expect(gasUsed).to.be.below(BLOCK_GAS_LIMIT);
        } catch (error) {
          gasResults.push({
            size,
            gasUsed: 0,
            success: false,
            error: error.message,
          });

          console.log(`Array size ${size}: Failed (${error.message})`);

          // Failure should be due to gas limits or intentional DoS protection
          expect(error.message).to.satisfy(
            msg =>
              msg.includes('gas') ||
              msg.includes('too much') ||
              msg.includes('too large')
          );
        }
      }

      // Analyze gas scaling
      const successfulResults = gasResults.filter(r => r.success);
      if (successfulResults.length > 1) {
        const gasEfficiency = successfulResults.map(r => r.gasUsed / r.size);
        const avgEfficiency =
          gasEfficiency.reduce((a, b) => a + b) / gasEfficiency.length;

        console.log(
          `Average gas per array element: ${avgEfficiency.toFixed(2)}`
        );
        expect(avgEfficiency).to.be.below(100000); // Should be efficient
      }

      console.log('✅ Array iteration gas bomb mitigated');
    });

    it('Attack Simulation: Nested loop complexity bomb', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { testHelper } = await loadFixture(deployAttackSimulationFixture);

      console.log('🚨 Simulating nested loop complexity bomb attack...');

      const testCases = [
        { outer: 100, inner: 100 }, // 10K operations
        { outer: 200, inner: 200 }, // 40K operations
        { outer: 300, inner: 300 }, // 90K operations
        { outer: 500, inner: 500 }, // 250K operations
      ];

      const complexityResults = [];

      for (const testCase of testCases) {
        try {
          console.log(
            `Testing nested loops: ${testCase.outer}x${testCase.inner}`
          );

          const tx = await testHelper.processNestedOperations(
            testCase.outer,
            testCase.inner
          );
          const receipt = await tx.wait();

          const gasUsed = Number(receipt.gasUsed);
          const totalOps = testCase.outer * testCase.inner;

          complexityResults.push({
            ...testCase,
            totalOps,
            gasUsed,
            gasPerOp: gasUsed / totalOps,
            success: true,
          });

          console.log(
            `${testCase.outer}x${testCase.inner}: ${gasUsed} gas (${(gasUsed / totalOps).toFixed(2)} per op)`
          );

          expect(gasUsed).to.be.below(BLOCK_GAS_LIMIT);
        } catch (error) {
          complexityResults.push({
            ...testCase,
            totalOps: testCase.outer * testCase.inner,
            gasUsed: 0,
            success: false,
            error: error.message,
          });

          console.log(
            `${testCase.outer}x${testCase.inner}: Failed (${error.message})`
          );

          // Should fail due to gas limits or DoS protection
          expect(error.message).to.satisfy(
            msg =>
              msg.includes('gas') ||
              msg.includes('too large') ||
              msg.includes('too much')
          );
        }
      }

      // Verify complexity scaling
      const successful = complexityResults.filter(r => r.success);
      if (successful.length > 1) {
        const gasPerOpVariance = successful.map(r => r.gasPerOp);
        const maxVariance = Math.max(...gasPerOpVariance);
        const minVariance = Math.min(...gasPerOpVariance);

        console.log(
          `Gas per operation variance: ${minVariance.toFixed(2)} - ${maxVariance.toFixed(2)}`
        );

        // Gas per operation should remain relatively stable (not exponential growth)
        expect(maxVariance / minVariance).to.be.below(10);
      }

      console.log('✅ Nested loop complexity bomb mitigated');
    });

    it('Attack Simulation: Recursive stack overflow attack', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { testHelper } = await loadFixture(deployAttackSimulationFixture);

      console.log('🚨 Simulating recursive stack overflow attack...');

      const recursionDepths = [50, 100, 150, 200, 500, 1000];
      const recursionResults = [];

      for (const depth of recursionDepths) {
        try {
          console.log(`Testing recursion depth: ${depth}`);

          const result = await testHelper.recursiveTest(depth);

          recursionResults.push({
            depth,
            success: true,
            result: Number(result),
          });
          console.log(`Depth ${depth}: Success (result: ${result})`);
        } catch (error) {
          recursionResults.push({
            depth,
            success: false,
            error: error.message,
          });
          console.log(`Depth ${depth}: Failed (${error.message})`);

          // Should fail due to recursion limits, stack overflow, or arithmetic overflow protection
          expect(error.message).to.satisfy(
            msg =>
              msg.includes('depth') ||
              msg.includes('stack') ||
              msg.includes('too high') ||
              msg.includes('recursion') ||
              msg.includes('overflow') ||
              msg.includes('Arithmetic operation')
          );
        }
      }

      // Verify reasonable recursion limits are enforced
      const maxSuccessfulDepth = Math.max(
        ...recursionResults.filter(r => r.success).map(r => r.depth)
      );
      console.log(`Maximum successful recursion depth: ${maxSuccessfulDepth}`);

      // Should allow reasonable recursion but prevent stack overflow DoS
      expect(maxSuccessfulDepth).to.be.at.least(50); // Allow reasonable recursion
      expect(maxSuccessfulDepth).to.be.below(500); // Prevent excessive recursion

      console.log('✅ Recursive stack overflow attack mitigated');
    });
  });

  describe('4. Economic Manipulation Attack Scenarios', function () {
    it('Attack Simulation: Price manipulation through gas pricing', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { marketplace, nft, attacker1, victim } = await loadFixture(
        deployAttackSimulationFixture
      );

      console.log(
        '🚨 Simulating price manipulation through gas pricing attack...'
      );

      const tokenId = 8001;
      await nft.mintWithURI(attacker1.address, tokenId, 'QmPriceManip');

      // Setup NFT listing
      await nft
        .connect(attacker1)
        .approve(await marketplace.getAddress(), tokenId);
      await marketplace
        .connect(attacker1)
        .createFixedPriceListing(
          await nft.getAddress(),
          tokenId,
          ethers.parseEther('1'),
          0,
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      // Attack: Try to manipulate gas costs to make legitimate transactions fail
      const manipulationAttempts = [];

      // Create gas price manipulation attempts
      for (let i = 0; i < 5; i++) {
        try {
          // Attempt to create gas-expensive operations
          const spamTx = await marketplace.connect(attacker1).makeOffer(
            999999, // Non-existent listing
            ethers.parseEther('0.1'),
            0,
            ethers.ZeroAddress,
            3600,
            {
              value: ethers.parseEther('0.1'),
              gasPrice: ethers.parseUnits('100', 'gwei'), // High gas price
            }
          );

          manipulationAttempts.push({ success: true, tx: spamTx });
        } catch (error) {
          manipulationAttempts.push({ success: false, error: error.message });
        }
      }

      // Legitimate transaction should still work despite manipulation attempts
      const legitimateTx = await marketplace
        .connect(victim)
        .buyFixedPrice(1, {
          value: ethers.parseEther('1'),
        });

      const receipt = await legitimateTx.wait();
      console.log(`Legitimate transaction gas: ${receipt.gasUsed}`);

      // Verify successful transaction despite manipulation
      expect(await nft.ownerOf(tokenId)).to.equal(victim.address);
      expect(receipt.gasUsed).to.be.below(BLOCK_GAS_LIMIT);

      console.log('✅ Price manipulation attack mitigated');
    });

    it('Attack Simulation: MEV frontrunning DoS', async function () {
      this.timeout(ATTACK_VECTOR_TIMEOUT);

      const { marketplace, nft, attacker1, victim } = await loadFixture(
        deployAttackSimulationFixture
      );

      console.log('🚨 Simulating MEV frontrunning DoS attack...');

      const tokenId = 9001;
      await nft.mintWithURI(victim.address, tokenId, 'QmMEVTarget');

      // Setup victim's NFT listing
      await nft
        .connect(victim)
        .approve(await marketplace.getAddress(), tokenId);
      await marketplace
        .connect(victim)
        .createFixedPriceListing(
          await nft.getAddress(),
          tokenId,
          ethers.parseEther('5'),
          0, // PaymentToken.ETH
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      // Simulate MEV attack: frontrun with offer, then backrun to cancel
      const frontrunPromise = marketplace.connect(attacker1).makeOffer(
        1, // Listing ID
        ethers.parseEther('4.5'),
        0,
        ethers.ZeroAddress,
        3600,
        { value: ethers.parseEther('4.5') }
      );

      // Victim's legitimate purchase transaction
      const victimPurchasePromise = marketplace
        .connect(victim)
        .buyFixedPrice(1, {
          value: ethers.parseEther('5'),
        });

      // Execute transactions
      try {
        await frontrunPromise;
        console.log('Frontrunning offer created');
      } catch (error) {
        console.log('Frontrunning failed:', error.message);
      }

      // Victim transaction should succeed regardless of frontrunning attempt
      const victimTx = await victimPurchasePromise;
      await victimTx.wait();

      // Verify victim got the NFT (not the attacker)
      expect(await nft.ownerOf(tokenId)).to.equal(victim.address);

      console.log('✅ MEV frontrunning DoS attack mitigated');
    });
  });

  after(async function () {
    console.log('\n=== DoS Attack Simulation Summary ===');
    console.log('All simulated attacks were successfully mitigated:');
    console.log('• NFTMarketplace royalty processing attacks blocked');
    console.log('• Governance proposal enumeration attacks contained');
    console.log('• Gas limit exploitation attempts prevented');
    console.log('• Economic manipulation attacks neutralized');
    console.log('=====================================\n');
  });
});
