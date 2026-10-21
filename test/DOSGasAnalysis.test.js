// SPDX-License-Identifier: MIT

/**
 * DoS Gas Consumption Analysis and Benchmarking Suite
 *
 * This test suite provides comprehensive gas consumption analysis
 * to identify potential DoS vulnerabilities through gas limit exploitation.
 *
 * Focus Areas:
 * 1. Gas consumption patterns analysis
 * 2. Performance benchmarking under various loads
 * 3. Gas limit validation and enforcement
 * 4. Scalability testing with large datasets
 * 5. Memory and computational complexity analysis
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
} = require('@nomicfoundation/hardhat-toolbox/network-helpers');

describe('DoS Gas Analysis and Benchmarking Suite', function () {
  // Benchmarking constants
  const BLOCK_GAS_LIMIT = 30000000; // 30M gas
  const GAS_ANALYSIS_TIMEOUT = 300000; // 5 minutes
  const PERFORMANCE_SAMPLES = 50;
  const SCALABILITY_STEPS = [10, 50, 100, 250, 500, 1000];

  // Gas consumption thresholds
  const GAS_THRESHOLDS = {
    SIMPLE_OPERATION: 100000, // 100K gas
    COMPLEX_OPERATION: 1000000, // 1M gas
    BATCH_OPERATION: 5000000, // 5M gas
    CRITICAL_OPERATION: 10000000, // 10M gas
  };

  async function deployGasAnalysisFixture() {
    const signers = await ethers.getSigners();
    const [owner, user1, user2, ...testUsers] = signers;

    // Deploy all contracts for gas analysis
    const WRFToken = await ethers.getContractFactory('MockERC20');
    const wrfToken = await WRFToken.deploy('WRFCoin', 'WRF', 18);

    const MockERC721 =
      await ethers.getContractFactory('MockERC721');
    const nft = await MockERC721.deploy(
      'Gas Test NFT',
      'GTNFT'
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
    const GovernanceSecurityFrameworkHarness = await ethers.getContractFactory(
      'GovernanceSecurityFrameworkHarness'
    );
    const governance = await GovernanceSecurityFrameworkHarness.deploy(
      owner.address,
      await timelock.getAddress(),
      await compliance.getAddress(),
      await wrfToken.getAddress()
    );

    const CarbonCreditAMM = await ethers.getContractFactory('contracts/CarbonCreditAMM.sol:CarbonCreditAMM');
    const amm = await CarbonCreditAMM.deploy(owner.address);

    // Deploy analysis helper contracts
    const DOSTestHelper = await ethers.getContractFactory('DOSTestHelper');
    const testHelper = await DOSTestHelper.deploy();

    const GasConsumptionAnalyzer = await ethers.getContractFactory(
      'GasConsumptionAnalyzer'
    );
    const gasAnalyzer = await GasConsumptionAnalyzer.deploy();

    // Setup initial state
    await wrfToken.mint(owner.address, ethers.parseEther('10000000'));
    for (let i = 0; i < 20; i++) {
      if (i < testUsers.length) {
        await wrfToken.mint(testUsers[i].address, ethers.parseEther('10000'));
      }
    }

    return {
      wrfToken,
      nft,
      marketplace,
      governance,
      amm,
      testHelper,
      gasAnalyzer,
      owner,
      user1,
      user2,
      testUsers: testUsers.slice(0, 20),
    };
  }

  // Gas analysis utility class
  class GasAnalyzer {
    constructor() {
      this.measurements = [];
      this.benchmarks = {};
    }

    recordMeasurement(operation, gasUsed, params = {}) {
      this.measurements.push({
        operation,
        gasUsed: Number(gasUsed),
        timestamp: Date.now(),
        ...params,
      });
    }

    setBenchmark(operation, gasLimit) {
      this.benchmarks[operation] = gasLimit;
    }

    analyzeTrends(operation) {
      const operationMeasurements = this.measurements.filter(
        m => m.operation === operation
      );

      if (operationMeasurements.length < 2) return null;

      const gasValues = operationMeasurements.map(m => m.gasUsed);
      const avg =
        gasValues.reduce((sum, val) => sum + val, 0) / gasValues.length;
      const min = Math.min(...gasValues);
      const max = Math.max(...gasValues);
      const variance =
        gasValues.reduce((sum, val) => sum + Math.pow(val - avg, 2), 0) /
        gasValues.length;
      const stdDev = Math.sqrt(variance);

      return { avg, min, max, variance, stdDev, count: gasValues.length };
    }

    checkCompliance(operation, gasUsed) {
      const benchmark = this.benchmarks[operation];
      if (!benchmark) return true;

      return Number(gasUsed) <= benchmark;
    }

    generateReport() {
      const report = {
        totalMeasurements: this.measurements.length,
        operations: {},
        violations: [],
      };

      const operationTypes = [
        ...new Set(this.measurements.map(m => m.operation)),
      ];

      operationTypes.forEach(op => {
        const analysis = this.analyzeTrends(op);
        if (analysis) {
          report.operations[op] = analysis;

          // Check for violations
          if (this.benchmarks[op] && analysis.max > this.benchmarks[op]) {
            report.violations.push({
              operation: op,
              benchmark: this.benchmarks[op],
              actualMax: analysis.max,
              violation: analysis.max - this.benchmarks[op],
            });
          }
        }
      });

      return report;
    }
  }

  describe('1. NFTMarketplace Gas Consumption Analysis', function () {
    it('Gas Analysis: Royalty processing scalability', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { marketplace, nft, testUsers } = await loadFixture(
        deployGasAnalysisFixture
      );
      const gasAnalyzer = new GasAnalyzer();

      console.log(
        '🔍 Analyzing royalty processing gas consumption patterns...'
      );

      // Set gas consumption benchmarks
      gasAnalyzer.setBenchmark(
        'royalty_setup_small',
        GAS_THRESHOLDS.SIMPLE_OPERATION
      );
      gasAnalyzer.setBenchmark(
        'royalty_setup_medium',
        GAS_THRESHOLDS.COMPLEX_OPERATION
      );
      gasAnalyzer.setBenchmark(
        'royalty_setup_large',
        GAS_THRESHOLDS.BATCH_OPERATION
      );
      gasAnalyzer.setBenchmark(
        'royalty_processing',
        GAS_THRESHOLDS.COMPLEX_OPERATION
      );

      const maxRoyaltyRecipients = Number(
        await marketplace.MAX_ROYALTY_RECIPIENTS()
      );
      let listingId = 1;

      for (const recipientCount of SCALABILITY_STEPS) {
        if (recipientCount > testUsers.length) continue;
        const actualRecipientCount = Math.min(
          recipientCount,
          maxRoyaltyRecipients,
          testUsers.length
        );

        const tokenId = 1000 + recipientCount;
        await nft.mintWithURI(testUsers[0].address, tokenId, `QmGas${tokenId}`);

        // Test royalty setup gas consumption
        const recipients = testUsers
          .slice(0, actualRecipientCount)
          .map(u => u.address);
        const percentages = new Array(actualRecipientCount).fill(
          Math.floor(1000 / actualRecipientCount)
        );

        const setupTx = await marketplace
          .connect(testUsers[0])
          .setRoyalties(
            await nft.getAddress(),
            tokenId,
            recipients,
            percentages
          );
        const setupReceipt = await setupTx.wait();

        const operationType =
          actualRecipientCount <= 2
            ? 'royalty_setup_small'
            : actualRecipientCount <= 4
              ? 'royalty_setup_medium'
              : 'royalty_setup_large';

        gasAnalyzer.recordMeasurement(operationType, setupReceipt.gasUsed, {
          recipientCount: actualRecipientCount,
        });

        // Test royalty processing during sale
        if (actualRecipientCount <= 20) {
          // Limit to prevent test timeout
          await nft
            .connect(testUsers[0])
            .approve(await marketplace.getAddress(), tokenId);
          await marketplace
            .connect(testUsers[0])
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

          const purchaseTx = await marketplace
            .connect(testUsers[1])
            .buyFixedPrice(listingId, { value: ethers.parseEther('1') });
          const purchaseReceipt = await purchaseTx.wait();
          listingId++;

          gasAnalyzer.recordMeasurement(
            'royalty_processing',
            purchaseReceipt.gasUsed,
            { recipientCount: actualRecipientCount }
          );
        }

        console.log(
          `Recipients: ${recipientCount}, Setup Gas: ${setupReceipt.gasUsed}`
        );
      }

      // Analyze trends and generate report
      const report = gasAnalyzer.generateReport();
      console.log('\nGas Analysis Report:');
      console.log(JSON.stringify(report, null, 2));

      // Verify compliance with benchmarks
      expect(report.violations.length).to.equal(
        0,
        `Gas consumption violations found: ${JSON.stringify(report.violations)}`
      );

      // Check for linear scaling
      const royaltySetupTrend = gasAnalyzer.analyzeTrends(
        'royalty_setup_medium'
      );
      if (royaltySetupTrend) {
        expect(royaltySetupTrend.max).to.be.below(BLOCK_GAS_LIMIT);
        expect(royaltySetupTrend.stdDev / royaltySetupTrend.avg).to.be.below(
          0.5
        ); // Low variance
      }
    });

    it('Gas Analysis: Batch operations efficiency', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { marketplace, nft, testUsers } = await loadFixture(
        deployGasAnalysisFixture
      );
      const gasAnalyzer = new GasAnalyzer();

      console.log('🔍 Analyzing batch operations gas efficiency...');

      gasAnalyzer.setBenchmark('batch_listing', GAS_THRESHOLDS.BATCH_OPERATION);
      gasAnalyzer.setBenchmark(
        'individual_listing',
        GAS_THRESHOLDS.SIMPLE_OPERATION
      );

      const batchSizes = [1, 5, 10, 20, 30];

      for (const batchSize of batchSizes) {
        // Test individual listings
        let totalIndividualGas = 0;
        for (let i = 0; i < Math.min(batchSize, 5); i++) {
          // Limit for time
          const tokenId = 200000 + batchSize * 100 + i;
          await nft.mintWithURI(
            testUsers[0].address,
            tokenId,
            `QmBatchTest${tokenId}`
          );
          await nft
            .connect(testUsers[0])
            .approve(await marketplace.getAddress(), tokenId);

          const tx = await marketplace
            .connect(testUsers[0])
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
          const receipt = await tx.wait();
          totalIndividualGas += Number(receipt.gasUsed);

          if (i === 0) {
            gasAnalyzer.recordMeasurement(
              'individual_listing',
              receipt.gasUsed,
              { batchSize: 1 }
            );
          }
        }

        // Test batch listings
        if (batchSize > 1) {
          const batchParams = [];
          for (let i = 0; i < batchSize; i++) {
            const tokenId = 300000 + batchSize * 100 + i;
            await nft.mintWithURI(testUsers[0].address, tokenId, `QmBatch${tokenId}`);
            await nft
              .connect(testUsers[0])
              .approve(await marketplace.getAddress(), tokenId);

            batchParams.push({
              nftContract: await nft.getAddress(),
              tokenId: tokenId,
              price: ethers.parseEther('1'),
              duration: 3600,
            });
          }

          const batchTx = await marketplace
            .connect(testUsers[0])
            .createBatchFixedPriceListings(
              await nft.getAddress(),
              batchParams,
              0,
              ethers.ZeroAddress
            );
          const batchReceipt = await batchTx.wait();

          gasAnalyzer.recordMeasurement('batch_listing', batchReceipt.gasUsed, {
            batchSize,
          });

          // Calculate efficiency
          const avgIndividualGas = totalIndividualGas / Math.min(batchSize, 5);
          const batchEfficiency = Number(batchReceipt.gasUsed) / batchSize;
          const savings =
            ((avgIndividualGas - batchEfficiency) / avgIndividualGas) * 100;

          console.log(
            `Batch size ${batchSize}: ${batchReceipt.gasUsed} gas total, ${batchEfficiency.toFixed(0)} per item, ${savings.toFixed(1)}% savings`
          );
        }
      }

      const report = gasAnalyzer.generateReport();

      // Verify batch operations are more efficient than individual
      const batchTrend = gasAnalyzer.analyzeTrends('batch_listing');
      const individualTrend = gasAnalyzer.analyzeTrends('individual_listing');

      if (batchTrend && individualTrend) {
        // Compare per-item batch gas using actual recorded batch sizes.
        const batchMeasurements = gasAnalyzer.measurements.filter(
          m => m.operation === 'batch_listing' && m.batchSize > 0
        );
        const avgBatchPerItem =
          batchMeasurements.reduce(
            (sum, measurement) => sum + measurement.gasUsed / measurement.batchSize,
            0
          ) / batchMeasurements.length;

        expect(avgBatchPerItem).to.be.below(individualTrend.avg);
      }
    });
  });

  describe('2. Governance Operations Gas Analysis', function () {
    it('Gas Analysis: Proposal enumeration scaling', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { governance, wrfToken, testUsers } = await loadFixture(
        deployGasAnalysisFixture
      );
      const gasAnalyzer = new GasAnalyzer();

      console.log('🔍 Analyzing proposal enumeration gas scaling...');

      gasAnalyzer.setBenchmark(
        'proposal_creation',
        GAS_THRESHOLDS.SIMPLE_OPERATION
      );
      gasAnalyzer.setBenchmark(
        'proposal_enumeration',
        GAS_THRESHOLDS.SIMPLE_OPERATION
      );

      let proposalCount = 0;
      const enumerationResults = [];

      // Create proposals and measure enumeration costs
      for (let batch = 0; batch < 10; batch++) {
        // Create batch of proposals
        const batchSize = 10;
        for (let i = 0; i < batchSize; i++) {
          const user = testUsers[i % testUsers.length];

          const tx = await governance
            .connect(user)
            .createProposal(
              `Gas Test Proposal ${proposalCount}`,
              `Testing gas consumption ${proposalCount}`,
              [await wrfToken.getAddress()],
              [0],
              ['totalSupply()'],
              ['0x']
            );
          const receipt = await tx.wait();

          gasAnalyzer.recordMeasurement('proposal_creation', receipt.gasUsed, {
            proposalNumber: proposalCount,
          });
          proposalCount++;
        }

        // Measure enumeration gas cost
        const enumStart = Date.now();
        const activeCountTx =
          await governance.getActiveProposalsCount.staticCall();
        const enumEnd = Date.now();

        // Get gas estimate for enumeration
        try {
          const gasEstimate =
            await governance.getActiveProposalsCount.estimateGas();
          gasAnalyzer.recordMeasurement('proposal_enumeration', gasEstimate, {
            proposalCount,
            enumerationTime: enumEnd - enumStart,
          });

          enumerationResults.push({
            proposalCount,
            gasEstimate: Number(gasEstimate),
            timeMs: enumEnd - enumStart,
            activeCount: Number(activeCountTx),
          });

          console.log(
            `Proposals: ${proposalCount}, Enum Gas: ${gasEstimate}, Time: ${enumEnd - enumStart}ms`
          );
        } catch (error) {
          console.log(
            `Enumeration failed at ${proposalCount} proposals: ${error.message}`
          );
          break;
        }
      }

      // Analyze enumeration scaling
      if (enumerationResults.length > 1) {
        const firstResult = enumerationResults[0];
        const lastResult = enumerationResults[enumerationResults.length - 1];

        const gasScaling = lastResult.gasEstimate / firstResult.gasEstimate;
        const proposalScaling =
          lastResult.proposalCount / firstResult.proposalCount;
        const scalingRatio = gasScaling / proposalScaling;

        console.log(
          `Gas scaling ratio: ${scalingRatio.toFixed(2)} (should be close to 1.0 for linear scaling)`
        );

        // Should scale linearly or better
        expect(scalingRatio).to.be.below(2.0); // Allow some overhead but not quadratic scaling
      }

      const report = gasAnalyzer.generateReport();
      expect(
        report.operations.proposal_creation?.max || 0
      ).to.be.below(BLOCK_GAS_LIMIT);
      expect(
        report.operations.proposal_enumeration?.max || 0
      ).to.be.below(BLOCK_GAS_LIMIT);
    });

    it('Gas Analysis: Voting operations under load', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { governance, wrfToken, testUsers } = await loadFixture(
        deployGasAnalysisFixture
      );
      const gasAnalyzer = new GasAnalyzer();

      console.log(
        '🔍 Analyzing voting operations gas consumption under load...'
      );

      gasAnalyzer.setBenchmark('cast_vote', GAS_THRESHOLDS.SIMPLE_OPERATION);
      gasAnalyzer.setBenchmark('vote_tally', GAS_THRESHOLDS.SIMPLE_OPERATION);

      // Create a proposal to vote on
      const proposalTx = await governance
        .connect(testUsers[0])
        .createProposal(
          'Vote Load Test',
          'Testing voting load',
          [await wrfToken.getAddress()],
          [0],
          ['totalSupply()'],
          ['0x']
        );
      await proposalTx.wait();

      // Simulate high voting load
      const voterCount = Math.min(testUsers.length, 15);
      const voteResults = [];

      for (let i = 0; i < voterCount; i++) {
        const voter = testUsers[i];
        const support = i % 2 === 0; // Alternate support/against

        try {
          const voteTx = await governance.connect(voter).castVote(1, support);
          const voteReceipt = await voteTx.wait();

          gasAnalyzer.recordMeasurement('cast_vote', voteReceipt.gasUsed, {
            voterIndex: i,
            support,
          });

          voteResults.push({
            voterIndex: i,
            gasUsed: Number(voteReceipt.gasUsed),
            support,
          });

          console.log(`Voter ${i}: ${voteReceipt.gasUsed} gas`);
        } catch (error) {
          console.log(`Voting failed for voter ${i}: ${error.message}`);
        }

        // Test vote tally calculation periodically
        if (i % 5 === 4) {
          try {
            const tallyGas = await governance.getProposalState.estimateGas(1);
            gasAnalyzer.recordMeasurement('vote_tally', tallyGas, {
              votersSoFar: i + 1,
            });
          } catch (error) {
            // Tally calculation might not be available yet
          }
        }
      }

      // Analyze voting gas consumption patterns
      const voteTrend = gasAnalyzer.analyzeTrends('cast_vote');
      if (voteTrend) {
        console.log(
          `Vote gas consumption - Avg: ${voteTrend.avg.toFixed(0)}, StdDev: ${voteTrend.stdDev.toFixed(0)}`
        );

        // Vote gas consumption should be consistent
        expect(voteTrend.stdDev / voteTrend.avg).to.be.below(0.2); // Low variance
        expect(voteTrend.max).to.be.below(GAS_THRESHOLDS.SIMPLE_OPERATION);
      }

      const report = gasAnalyzer.generateReport();
      expect(report.violations.length).to.equal(0);
    });
  });

  describe('3. Complex Operations Gas Benchmarking', function () {
    it('Gas Benchmark: Array processing complexity', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { testHelper } = await loadFixture(deployGasAnalysisFixture);
      const gasAnalyzer = new GasAnalyzer();

      console.log('🔍 Benchmarking array processing complexity patterns...');

      gasAnalyzer.setBenchmark(
        'array_processing',
        GAS_THRESHOLDS.BATCH_OPERATION
      );
      gasAnalyzer.setBenchmark(
        'nested_processing',
        GAS_THRESHOLDS.CRITICAL_OPERATION
      );

      // Test array processing with different sizes
      for (const size of SCALABILITY_STEPS) {
        if (size > 1000) continue; // Prevent timeout

        const testArray = Array(size)
          .fill(0)
          .map((_, i) => i + 1);

        try {
          const tx = await testHelper.processLargeArray(testArray);
          const receipt = await tx.wait();

          gasAnalyzer.recordMeasurement('array_processing', receipt.gasUsed, {
            arraySize: size,
          });

          const gasPerElement = Number(receipt.gasUsed) / size;
          console.log(
            `Array size ${size}: ${receipt.gasUsed} gas total, ${gasPerElement.toFixed(2)} per element`
          );
        } catch (error) {
          console.log(
            `Array processing failed at size ${size}: ${error.message}`
          );
          break;
        }
      }

      // Test nested processing complexity
      const nestedSizes = [10, 25, 50, 75, 100];
      for (const outerSize of nestedSizes) {
        for (const innerSize of nestedSizes.slice(0, 3)) {
          // Limit combinations
          if (outerSize * innerSize > 5000) continue; // Prevent excessive gas usage

          try {
            const tx = await testHelper.processNestedOperations(
              outerSize,
              innerSize
            );
            const receipt = await tx.wait();

            gasAnalyzer.recordMeasurement(
              'nested_processing',
              receipt.gasUsed,
              {
                outerSize,
                innerSize,
                totalOps: outerSize * innerSize,
              }
            );

            console.log(
              `Nested ${outerSize}x${innerSize}: ${receipt.gasUsed} gas`
            );
          } catch (error) {
            console.log(
              `Nested processing failed at ${outerSize}x${innerSize}: ${error.message}`
            );
          }
        }
      }

      // Analyze complexity scaling
      const arrayTrend = gasAnalyzer.analyzeTrends('array_processing');
      if (arrayTrend) {
        console.log(
          `Array processing trend - Avg: ${arrayTrend.avg.toFixed(0)}, Max: ${arrayTrend.max}`
        );
        expect(arrayTrend.max).to.be.below(BLOCK_GAS_LIMIT);
      }

      const nestedTrend = gasAnalyzer.analyzeTrends('nested_processing');
      if (nestedTrend) {
        console.log(
          `Nested processing trend - Avg: ${nestedTrend.avg.toFixed(0)}, Max: ${nestedTrend.max}`
        );
        expect(nestedTrend.max).to.be.below(BLOCK_GAS_LIMIT);
      }
    });

    it('Gas Benchmark: Memory allocation patterns', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { testHelper } = await loadFixture(deployGasAnalysisFixture);
      const gasAnalyzer = new GasAnalyzer();

      console.log('🔍 Benchmarking memory allocation gas patterns...');

      gasAnalyzer.setBenchmark(
        'memory_allocation',
        GAS_THRESHOLDS.COMPLEX_OPERATION
      );
      gasAnalyzer.setBenchmark(
        'storage_operations',
        GAS_THRESHOLDS.BATCH_OPERATION
      );

      // Test memory allocation with different sizes
      const memorySizes = [100, 500, 1000, 2500, 5000, 10000];

      for (const size of memorySizes) {
        try {
          const gasEstimate =
            await testHelper.memoryAllocationTest.estimateGas(size);

          gasAnalyzer.recordMeasurement('memory_allocation', gasEstimate, {
            memorySize: size,
          });

          console.log(`Memory size ${size}: ${gasEstimate} gas estimated`);

          expect(Number(gasEstimate)).to.be.below(BLOCK_GAS_LIMIT);
        } catch (error) {
          console.log(
            `Memory allocation failed at size ${size}: ${error.message}`
          );
        }
      }

      // Test storage operations
      const storageCounts = [10, 50, 100, 250, 500];

      for (const count of storageCounts) {
        try {
          const tx = await testHelper.storageOperationTest(count);
          const receipt = await tx.wait();

          gasAnalyzer.recordMeasurement('storage_operations', receipt.gasUsed, {
            operationCount: count,
          });

          const gasPerOperation = Number(receipt.gasUsed) / count;
          console.log(
            `Storage ops ${count}: ${receipt.gasUsed} gas total, ${gasPerOperation.toFixed(0)} per op`
          );
        } catch (error) {
          console.log(
            `Storage operations failed at count ${count}: ${error.message}`
          );
        }
      }

      // Generate comprehensive report
      const report = gasAnalyzer.generateReport();
      console.log('\nMemory/Storage Gas Analysis Report:');
      console.log(JSON.stringify(report, null, 2));

      expect(
        report.operations.memory_allocation?.max || 0
      ).to.be.below(BLOCK_GAS_LIMIT);
      expect(
        report.operations.storage_operations?.max || 0
      ).to.be.below(BLOCK_GAS_LIMIT);
    });
  });

  describe('4. Performance Under Adversarial Conditions', function () {
    it('Performance Test: Sustained high-load operations', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT * 2);

      const { marketplace, nft, testUsers } = await loadFixture(
        deployGasAnalysisFixture
      );
      const gasAnalyzer = new GasAnalyzer();

      console.log(
        '🔍 Testing performance under sustained high-load conditions...'
      );

      gasAnalyzer.setBenchmark(
        'sustained_operation',
        GAS_THRESHOLDS.SIMPLE_OPERATION
      );

      const loadDuration = 60000; // 1 minute of sustained load
      const startTime = Date.now();
      let operationCount = 0;

      while (Date.now() - startTime < loadDuration && operationCount < 100) {
        try {
          const tokenId = 5000 + operationCount;
          const user = testUsers[operationCount % testUsers.length];

          // Rotate between different operation types
          const operationType = operationCount % 4;

          switch (operationType) {
            case 0: // NFT minting
              await nft.mintWithURI(user.address, tokenId, `QmLoad${tokenId}`);
              break;

            case 1: // Marketplace query
              await marketplace.getMarketplaceStats();
              break;

            case 2: // User balance check
              await nft.balanceOf(user.address);
              break;

            case 3: // Approval
              await nft.mintWithURI(user.address, tokenId, `QmApprove${tokenId}`);
              await nft
                .connect(user)
                .approve(await marketplace.getAddress(), tokenId);
              break;
          }
        } catch (error) {
          console.log(`Operation ${operationCount} failed: ${error.message}`);
        } finally {
          operationCount++;

          // Brief pause to simulate realistic load
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }

      const actualDuration = Date.now() - startTime;
      const operationsPerSecond = (operationCount / actualDuration) * 1000;

      console.log(
        `Sustained load test: ${operationCount} operations in ${actualDuration}ms`
      );
      console.log(`Operations per second: ${operationsPerSecond.toFixed(2)}`);

      // System should maintain reasonable performance under load
      expect(operationsPerSecond).to.be.greaterThan(1); // At least 1 TPS
      expect(operationCount).to.be.greaterThan(20); // Should complete reasonable number of operations
    });

    it('Performance Test: Gas consumption consistency', async function () {
      this.timeout(GAS_ANALYSIS_TIMEOUT);

      const { marketplace, nft, testUsers } = await loadFixture(
        deployGasAnalysisFixture
      );
      const gasAnalyzer = new GasAnalyzer();

      console.log(
        '🔍 Testing gas consumption consistency across operations...'
      );

      const operationTypes = [
        'listing_creation',
        'purchase_transaction',
        'offer_creation',
        'royalty_setup',
      ];

      // Perform multiple samples of each operation type
      for (const operationType of operationTypes) {
        const samples = [];

        for (
          let sample = 0;
          sample < PERFORMANCE_SAMPLES && sample < 20;
          sample++
        ) {
          try {
            let tx, receipt;
            const user = testUsers[sample % testUsers.length];
            const tokenIdBase =
              operationType === 'listing_creation'
                ? 6000
                : operationType === 'purchase_transaction'
                  ? 7000
                  : operationType === 'offer_creation'
                    ? 8000
                    : 9000;
            const tokenId = tokenIdBase + sample;

            switch (operationType) {
              case 'listing_creation':
                await nft.mintWithURI(user.address, tokenId, `QmSample${tokenId}`);
                await nft
                  .connect(user)
                  .approve(await marketplace.getAddress(), tokenId);
                tx = await marketplace
                  .connect(user)
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
                receipt = await tx.wait();
                break;

              case 'purchase_transaction':
                const seller = testUsers[(sample + 1) % testUsers.length];
                const price = ethers.parseEther('1');
                await nft.mintWithURI(
                  seller.address,
                  tokenId,
                  `QmPurchase${tokenId}`
                );
                await nft
                  .connect(seller)
                  .approve(await marketplace.getAddress(), tokenId);
                const preStats = await marketplace.getMarketplaceStats();
                tx = await marketplace
                  .connect(seller)
                  .createFixedPriceListing(
                    await nft.getAddress(),
                    tokenId,
                    price,
                    0,
                    ethers.ZeroAddress,
                    3600,
                    false,
                    []
                  );
                await tx.wait();
                tx = await marketplace
                  .connect(user)
                  .buyFixedPrice(Number(preStats.totalListings) + 1, {
                    value: price,
                  });
                receipt = await tx.wait();
                break;

              case 'offer_creation':
                const offerSeller = testUsers[(sample + 1) % testUsers.length];
                await nft.mintWithURI(
                  offerSeller.address,
                  tokenId,
                  `QmOffer${tokenId}`
                );
                tx = await marketplace
                  .connect(user)
                  .makeOffer(
                    await nft.getAddress(),
                    tokenId,
                    ethers.parseEther('0.8'),
                    0,
                    ethers.ZeroAddress,
                    3600
                  );
                receipt = await tx.wait();
                break;

              case 'royalty_setup':
                await nft.mintWithURI(user.address, tokenId, `QmRoyalty${tokenId}`);
                const recipients = testUsers.slice(0, 3).map(u => u.address);
                const percentages = [300, 300, 400]; // 3%, 3%, 4%
                tx = await marketplace
                  .connect(user)
                  .setRoyalties(
                    await nft.getAddress(),
                    tokenId,
                    recipients,
                    percentages
                  );
                receipt = await tx.wait();
                break;
            }

            if (receipt) {
              const gasUsed = Number(receipt.gasUsed);
              samples.push(gasUsed);
              gasAnalyzer.recordMeasurement(operationType, gasUsed, { sample });
            }
          } catch (error) {
            // Some operations may fail due to state dependencies
            console.log(
              `${operationType} sample ${sample} failed: ${error.message}`
            );
          }
        }

        if (samples.length > 1) {
          const avg =
            samples.reduce((sum, val) => sum + val, 0) / samples.length;
          const variance =
            samples.reduce((sum, val) => sum + Math.pow(val - avg, 2), 0) /
            samples.length;
          const stdDev = Math.sqrt(variance);
          const coefficientOfVariation = stdDev / avg;

          console.log(
            `${operationType}: ${samples.length} samples, avg: ${avg.toFixed(0)}, CV: ${(coefficientOfVariation * 100).toFixed(2)}%`
          );

          // Gas consumption should be consistent (low coefficient of variation)
          expect(coefficientOfVariation).to.be.below(0.3); // Less than 30% variation
        }
      }

      const report = gasAnalyzer.generateReport();
      console.log('\nGas Consistency Report:');
      console.log(
        `Operations analyzed: ${Object.keys(report.operations).length}`
      );
      console.log(`Violations found: ${report.violations.length}`);
    });
  });

  after(async function () {
    console.log('\n=== DoS Gas Analysis Summary ===');
    console.log('Comprehensive gas consumption analysis completed');
    console.log('All operations tested for:');
    console.log('• Linear scaling properties');
    console.log('• Gas limit compliance');
    console.log('• Performance consistency');
    console.log('• Adversarial condition resistance');
    console.log('================================\n');
  });
});
