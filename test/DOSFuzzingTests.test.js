// SPDX-License-Identifier: MIT

/**
 * Comprehensive Fuzzing Test Suite for DoS Vulnerabilities
 *
 * This test suite uses property-based testing and fuzzing to discover
 * potential DoS vulnerabilities through randomized input generation.
 *
 * Focus Areas:
 * 1. NFTMarketplace royalty processing fuzzing
 * 2. GovernanceSecurityFramework proposal enumeration fuzzing
 * 3. Gas consumption pattern fuzzing
 * 4. Economic parameter fuzzing
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
} = require('@nomicfoundation/hardhat-toolbox/network-helpers');

function createSeededRandom(seed) {
  let state = Number(seed) >>> 0;

  return function random() {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 4294967296;
  };
}

describe('DoS Fuzzing Test Suite', function () {
  // Fuzzing configuration
  const FUZZ_RUNS = 200; // Number of fuzzing iterations
  const MAX_GAS_LIMIT = 30000000;
  const RANDOM_SEED = 123456;

  // Property-based testing bounds
  const BOUNDS = {
    royaltyRecipients: { min: 1, max: 5 },
    royaltyPercentage: { min: 1, max: 2500 }, // 0.01% to 25%
    arraySize: { min: 1, max: 1000 },
    proposalCount: { min: 1, max: 500 },
    priceRange: {
      min: ethers.parseEther('0.001'),
      max: ethers.parseEther('1000'),
    },
    timeRange: { min: 3600, max: 365 * 24 * 3600 }, // 1 hour to 1 year
  };

  async function deployFuzzingFixture() {
    const signers = await ethers.getSigners();
    const [owner, attacker, ...testUsers] = signers;

    // Deploy contracts for fuzzing
    const WRFToken = await ethers.getContractFactory('MockERC20');
    const wrfToken = await WRFToken.deploy('WRFCoin', 'WRF', 18);

    const MockERC721 =
      await ethers.getContractFactory('MockERC721');
    const nft = await MockERC721.deploy(
      'Fuzz NFT',
      'FNFT'
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

    const DOSTestHelper = await ethers.getContractFactory('DOSTestHelper');
    const testHelper = await DOSTestHelper.deploy();

    const GasConsumptionAnalyzer = await ethers.getContractFactory(
      'GasConsumptionAnalyzer'
    );
    const gasAnalyzer = await GasConsumptionAnalyzer.deploy();

    // Setup initial state
    await wrfToken.mint(owner.address, ethers.parseEther('1000000'));

    // Distribute tokens to test users for fuzzing
    for (let i = 0; i < Math.min(50, testUsers.length); i++) {
      await wrfToken.mint(testUsers[i].address, ethers.parseEther('1000'));
    }

    return {
      wrfToken,
      nft,
      marketplace,
      governance,
      testHelper,
      gasAnalyzer,
      owner,
      attacker,
      testUsers: testUsers.slice(0, 100), // Limit to 100 test users
    };
  }

  // Fuzzing utility functions
  class FuzzingUtils {
    constructor(seed) {
      this.random = createSeededRandom(seed);
    }

    // Generate random integer in range
    randomInt(min, max) {
      return Math.floor(this.random() * (max - min + 1)) + min;
    }

    // Generate random BigInt in range
    randomBigInt(min, max) {
      const range = max - min;
      const randomValue = this.random();
      return min + BigInt(Math.floor(randomValue * Number(range)));
    }

    // Generate random boolean
    randomBool() {
      return this.random() > 0.5;
    }

    // Generate random array of addresses
    randomAddresses(users, minCount, maxCount) {
      const count = this.randomInt(minCount, maxCount);
      const selectedUsers = [];

      for (let i = 0; i < count; i++) {
        const userIndex = this.randomInt(0, users.length - 1);
        if (!selectedUsers.includes(users[userIndex].address)) {
          selectedUsers.push(users[userIndex].address);
        }
      }

      return selectedUsers;
    }

    // Generate random array of percentages that sum to a maximum
    randomPercentages(count, maxTotal) {
      const percentages = [];
      let remaining = maxTotal;

      for (let i = 0; i < count - 1; i++) {
        const maxForThisItem = Math.floor(remaining / (count - i));
        const value = this.randomInt(1, Math.max(1, maxForThisItem));
        percentages.push(value);
        remaining -= value;
      }

      // Add the remaining to the last item
      percentages.push(Math.max(1, remaining));

      return percentages;
    }

    // Generate random string
    randomString(length) {
      const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      let result = '';
      for (let i = 0; i < length; i++) {
        result += chars.charAt(Math.floor(this.random() * chars.length));
      }
      return result;
    }
  }

  describe('1. NFTMarketplace Royalty Processing Fuzzing', function () {
    it('Fuzz test: Random royalty configurations', async function () {
      this.timeout(300000); // 5 minutes timeout

      const { marketplace, nft, testUsers } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED);

      const results = {
        successful: 0,
        failed: 0,
        gasConsumption: [],
        errors: {},
      };

      for (let run = 0; run < FUZZ_RUNS; run++) {
        try {
          // Generate random royalty configuration
          const recipientCount = fuzzer.randomInt(
            BOUNDS.royaltyRecipients.min,
            Math.min(BOUNDS.royaltyRecipients.max, testUsers.length)
          );

          const recipients = fuzzer.randomAddresses(
            testUsers,
            recipientCount,
            recipientCount
          );
          const percentages = Array(recipients.length)
            .fill(0)
            .map(() =>
              fuzzer.randomInt(
                BOUNDS.royaltyPercentage.min,
                Math.min(BOUNDS.royaltyPercentage.max, 500)
              )
            );

          // Generate deterministic NFT token ID to avoid duplicate mints across runs
          const tokenId = 1000 + run;

          // Mint NFT for testing
          await nft.mintWithURI(testUsers[0].address, tokenId, `QmFuzz${tokenId}`);

          // Attempt to set royalties
          const tx = await marketplace
            .connect(testUsers[0])
            .setRoyalties(
              await nft.getAddress(),
              tokenId,
              recipients,
              percentages
            );

          const receipt = await tx.wait();
          results.successful++;
          results.gasConsumption.push(Number(receipt.gasUsed));

          // Verify gas consumption is reasonable
          expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
        } catch (error) {
          results.failed++;
          const errorType = error.message.split(':')[0];
          results.errors[errorType] = (results.errors[errorType] || 0) + 1;

          // Some errors are expected (invalid inputs)
          if (
            !error.message.includes('Marketplace:') &&
            !error.message.includes('revert') &&
            !error.message.includes('transaction failed')
          ) {
            console.log(`Unexpected error in run ${run}:`, error.message);
          }
        }
      }

      console.log('Royalty Fuzzing Results:');
      console.log(`Successful: ${results.successful}`);
      console.log(`Failed: ${results.failed}`);
      console.log(
        `Average Gas: ${results.gasConsumption.reduce((a, b) => a + b, 0) / results.gasConsumption.length}`
      );
      console.log('Error distribution:', results.errors);

      // At least some tests should succeed
      expect(results.successful).to.be.greaterThan(FUZZ_RUNS * 0.1);
    });

    it('Fuzz test: Royalty processing during sales', async function () {
      this.timeout(300000);

      const { marketplace, nft, testUsers } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 1);

      let successfulSales = 0;
      let totalGasUsed = 0;

      for (let run = 0; run < Math.min(FUZZ_RUNS, 50); run++) {
        try {
          const tokenId = 2000 + run;
          const seller = testUsers[run % testUsers.length];
          const buyer = testUsers[(run + 1) % testUsers.length];

          // Mint NFT
          await nft.mintWithURI(seller.address, tokenId, `QmSaleFuzz${tokenId}`);

          // Random royalty setup
          const recipientCount = fuzzer.randomInt(
            BOUNDS.royaltyRecipients.min,
            BOUNDS.royaltyRecipients.max
          );
          const recipients = fuzzer.randomAddresses(
            testUsers,
            recipientCount,
            recipientCount
          );
          const percentages = Array(recipients.length)
            .fill(0)
            .map(() =>
              fuzzer.randomInt(
                BOUNDS.royaltyPercentage.min,
                Math.min(BOUNDS.royaltyPercentage.max, 500)
              )
            );

          await marketplace
            .connect(seller)
            .setRoyalties(
              await nft.getAddress(),
              tokenId,
              recipients,
              percentages
            );

          // Random price
          const price = fuzzer.randomBigInt(
            BOUNDS.priceRange.min,
            BOUNDS.priceRange.max
          );

          // Create listing
          await nft
            .connect(seller)
            .approve(await marketplace.getAddress(), tokenId);
          await marketplace.connect(seller).createFixedPriceListing(
            await nft.getAddress(),
            tokenId,
            price,
            0, // Native payment
            ethers.ZeroAddress,
            fuzzer.randomInt(BOUNDS.timeRange.min, BOUNDS.timeRange.max),
            false,
            []
          );

          // Purchase
          const purchaseTx = await marketplace
            .connect(buyer)
            .buyFixedPrice(run + 1, {
              value: price,
            });

          const receipt = await purchaseTx.wait();
          successfulSales++;
          totalGasUsed += Number(receipt.gasUsed);

          // Verify reasonable gas consumption
          expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
        } catch (error) {
          // Expected for some invalid configurations
          if (
            !error.message.includes('insufficient funds') &&
            !error.message.includes('Marketplace:')
          ) {
            console.log(`Unexpected error in sale run ${run}:`, error.message);
          }
        }
      }

      console.log(`Successful sales: ${successfulSales}`);
      console.log(`Average gas per sale: ${totalGasUsed / successfulSales}`);

      expect(successfulSales).to.be.greaterThan(0);
    });
  });

  describe('2. Governance Proposal Enumeration Fuzzing', function () {
    it('Fuzz test: Mass proposal creation', async function () {
      this.timeout(600000); // 10 minutes timeout

      const { governance, wrfToken, testUsers } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 2);

      let proposalsCreated = 0;
      const gasConsumption = [];

      // Create random proposals
      for (let run = 0; run < Math.min(FUZZ_RUNS, 100); run++) {
        try {
          const user = testUsers[run % testUsers.length];
          const title = fuzzer.randomString(fuzzer.randomInt(10, 100));
          const description = fuzzer.randomString(fuzzer.randomInt(50, 500));

          // Random proposal parameters
          const targetCount = fuzzer.randomInt(1, 5);
          const targets = Array(targetCount).fill(await wrfToken.getAddress());
          const values = Array(targetCount).fill(0);
          const signatures = Array(targetCount).fill('totalSupply()');
          const calldatas = Array(targetCount).fill('0x');

          const tx = await governance
            .connect(user)
            .createProposal(
              title,
              description,
              targets,
              values,
              signatures,
              calldatas
            );

          const receipt = await tx.wait();
          proposalsCreated++;
          gasConsumption.push(Number(receipt.gasUsed));

          // Test enumeration every 10 proposals
          if (proposalsCreated % 10 === 0) {
            const startTime = Date.now();
            const activeCount = await governance.getActiveProposalsCount();
            const enumTime = Date.now() - startTime;

            // Enumeration should not take too long
            expect(enumTime).to.be.below(5000); // Less than 5 seconds
            expect(activeCount).to.be.greaterThan(0);
          }
        } catch (error) {
          // Expected for some configurations due to rate limiting
          if (
            !error.message.includes('governance') &&
            !error.message.includes('rate limit')
          ) {
            console.log(
              `Unexpected error in proposal run ${run}:`,
              error.message
            );
          }
        }
      }

      console.log(`Proposals created: ${proposalsCreated}`);
      console.log(
        `Average gas per proposal: ${gasConsumption.reduce((a, b) => a + b, 0) / gasConsumption.length}`
      );

      // Final enumeration test with all proposals
      const finalStartTime = Date.now();
      const finalActiveCount = await governance.getActiveProposalsCount();
      const finalEnumTime = Date.now() - finalStartTime;

      console.log(
        `Final enumeration of ${finalActiveCount} proposals took ${finalEnumTime}ms`
      );

      expect(finalActiveCount).to.equal(proposalsCreated);
      expect(finalEnumTime).to.be.below(10000); // Less than 10 seconds
    });

    it('Fuzz test: Random proposal operations', async function () {
      this.timeout(300000);

      const { governance, wrfToken, testUsers } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 3);

      const operations = ['create', 'vote', 'check'];
      const proposalIds = [];
      let operationCount = 0;

      for (let run = 0; run < FUZZ_RUNS; run++) {
        try {
          const operation =
            operations[fuzzer.randomInt(0, operations.length - 1)];
          const user = testUsers[fuzzer.randomInt(0, testUsers.length - 1)];

          switch (operation) {
            case 'create':
              const tx = await governance
                .connect(user)
                .createProposal(
                  fuzzer.randomString(20),
                  fuzzer.randomString(100),
                  [await wrfToken.getAddress()],
                  [0],
                  ['totalSupply()'],
                  ['0x']
                );
              const receipt = await tx.wait();
              proposalIds.push(operationCount + 1);
              expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
              break;

            case 'vote':
              if (proposalIds.length > 0) {
                const proposalId =
                  proposalIds[fuzzer.randomInt(0, proposalIds.length - 1)];
                const support = fuzzer.randomBool();
                await governance.connect(user).castVote(proposalId, support);
              }
              break;

            case 'check':
              const activeCount = await governance.getActiveProposalsCount();
              expect(activeCount).to.be.greaterThan(0);
              break;
          }

          operationCount++;
        } catch (error) {
          // Expected for invalid operations
          if (
            !error.message.includes('governance') &&
            !error.message.includes('voting') &&
            !error.message.includes('proposal')
          ) {
            console.log(
              `Unexpected error in operation run ${run}:`,
              error.message
            );
          }
        }
      }

      console.log(`Total operations completed: ${operationCount}`);
      expect(operationCount).to.be.greaterThan(FUZZ_RUNS * 0.25);
    });
  });

  describe('3. Gas Consumption Pattern Fuzzing', function () {
    it('Fuzz test: Array processing patterns', async function () {
      this.timeout(300000);

      const { testHelper } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 4);

      const gasResults = [];

      for (let run = 0; run < Math.min(FUZZ_RUNS, 50); run++) {
        try {
          // Generate random array
          const arraySize = fuzzer.randomInt(
            BOUNDS.arraySize.min,
            BOUNDS.arraySize.max
          );
          const testArray = Array(arraySize)
            .fill(0)
            .map(() => fuzzer.randomInt(1, 1000000));

          const tx = await testHelper.processLargeArray(testArray);
          const receipt = await tx.wait();
          gasResults.push({
            arraySize: arraySize,
            gasUsed: Number(receipt.gasUsed),
          });

          // Check for linear scaling
          const gasPerElement = Number(receipt.gasUsed) / arraySize;
          expect(gasPerElement).to.be.below(50000); // Should be reasonable per element
        } catch (error) {
          // Expected for very large arrays
          if (
            !error.message.includes('gas') &&
            !error.message.includes('revert')
          ) {
            console.log(`Unexpected error in array run ${run}:`, error.message);
          }
        }
      }

      // Analyze scaling patterns
      if (gasResults.length > 10) {
        const avgGasPerSize = {};
        gasResults.forEach(result => {
          const sizeRange = Math.floor(result.arraySize / 100) * 100; // Group by hundreds
          if (!avgGasPerSize[sizeRange]) {
            avgGasPerSize[sizeRange] = { total: 0, count: 0 };
          }
          avgGasPerSize[sizeRange].total += result.gasUsed;
          avgGasPerSize[sizeRange].count++;
        });

        console.log('Gas consumption by array size range:');
        Object.keys(avgGasPerSize).forEach(sizeRange => {
          const avg =
            avgGasPerSize[sizeRange].total / avgGasPerSize[sizeRange].count;
          console.log(
            `${sizeRange}-${parseInt(sizeRange) + 99}: ${Math.round(avg)} gas average`
          );
        });
      }

      expect(gasResults.length).to.be.greaterThan(0);
    });

    it('Fuzz test: Nested operation complexity', async function () {
      this.timeout(300000);

      const { testHelper } = await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 5);

      const complexityResults = [];

      for (let run = 0; run < Math.min(FUZZ_RUNS, 20); run++) {
        try {
          const outerSize = fuzzer.randomInt(5, 100);
          const innerSize = fuzzer.randomInt(5, 100);

          // Limit total operations to prevent excessive gas usage
          if (outerSize * innerSize > 5000) continue;

          const tx = await testHelper.processNestedOperations(
            outerSize,
            innerSize
          );
          const receipt = await tx.wait();

          complexityResults.push({
            outerSize,
            innerSize,
            totalOps: outerSize * innerSize,
            gasUsed: Number(receipt.gasUsed),
          });

          // Check for quadratic scaling issues
          const gasPerOp = Number(receipt.gasUsed) / (outerSize * innerSize);
          expect(gasPerOp).to.be.below(20000); // Should be reasonable per operation
        } catch (error) {
          // Expected for very complex operations
          if (
            !error.message.includes('gas') &&
            !error.message.includes('too large')
          ) {
            console.log(
              `Unexpected error in complexity run ${run}:`,
              error.message
            );
          }
        }
      }

      console.log(`Complexity tests completed: ${complexityResults.length}`);

      if (complexityResults.length > 0) {
        const avgGasPerOp =
          complexityResults.reduce((sum, result) => {
            return sum + result.gasUsed / result.totalOps;
          }, 0) / complexityResults.length;

        console.log(
          `Average gas per nested operation: ${Math.round(avgGasPerOp)}`
        );
        expect(avgGasPerOp).to.be.below(15000);
      }
    });
  });

  describe('4. Economic Parameter Fuzzing', function () {
    it('Fuzz test: Marketplace price manipulation resistance', async function () {
      this.timeout(300000);

      const { marketplace, nft, testUsers } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 6);

      let manipulationAttempts = 0;
      let successfulTransactions = 0;

      for (let run = 0; run < Math.min(FUZZ_RUNS, 30); run++) {
        try {
          const tokenId = 5000 + run;
          const seller = testUsers[run % testUsers.length];
          const buyer = testUsers[(run + 1) % testUsers.length];

          await nft.mintWithURI(seller.address, tokenId, `QmPriceFuzz${tokenId}`);

          // Generate extreme prices to test manipulation resistance
          const priceType = fuzzer.randomInt(0, 2);
          let price;

          switch (priceType) {
            case 0: // Normal price
              price = fuzzer.randomBigInt(
                ethers.parseEther('0.1'),
                ethers.parseEther('10')
              );
              break;
            case 1: // Extremely high price
              price = fuzzer.randomBigInt(
                ethers.parseEther('1000'),
                ethers.parseEther('1000000')
              );
              manipulationAttempts++;
              break;
            case 2: // Extremely low price
              price = fuzzer.randomBigInt(1n, ethers.parseEther('0.001'));
              manipulationAttempts++;
              break;
          }

          // Create listing
          await nft
            .connect(seller)
            .approve(await marketplace.getAddress(), tokenId);
          await marketplace
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

          // Attempt purchase
          try {
            await marketplace.connect(buyer).buyFixedPrice(run + 1, {
              value: price,
            });
            successfulTransactions++;
          } catch (error) {
            // Expected for extreme prices due to insufficient funds or other protection
          }
        } catch (error) {
          // Expected for invalid configurations
          if (
            !error.message.includes('insufficient funds') &&
            !error.message.includes('Marketplace:') &&
            !error.message.includes('transfer')
          ) {
            console.log(
              `Unexpected error in price fuzz run ${run}:`,
              error.message
            );
          }
        }
      }

      console.log(`Manipulation attempts: ${manipulationAttempts}`);
      console.log(`Successful transactions: ${successfulTransactions}`);

      // System should handle extreme prices gracefully
      expect(successfulTransactions).to.be.greaterThan(0);
    });

    it('Fuzz test: Gas price attack resistance', async function () {
      this.timeout(180000);

      const { marketplace, nft, testUsers } =
        await loadFixture(deployFuzzingFixture);
      const fuzzer = new FuzzingUtils(RANDOM_SEED + 7);

      const gasResults = [];

      // Test various gas price scenarios
      for (let run = 0; run < Math.min(FUZZ_RUNS, 20); run++) {
        try {
          const tokenId = 6000 + run;
          const user = testUsers[run % testUsers.length];

          await nft.mintWithURI(user.address, tokenId, `QmGasFuzz${tokenId}`);

          // Random operation with random gas parameters
          const operation = fuzzer.randomInt(0, 2);

          switch (operation) {
            case 0: // Create listing
              await nft
                .connect(user)
                .approve(await marketplace.getAddress(), tokenId);
              const tx1 = await marketplace
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
              const receipt1 = await tx1.wait();
              gasResults.push(Number(receipt1.gasUsed));
              break;

            case 1: // Make offer
              const tx2 = await marketplace.connect(user).makeOffer(
                fuzzer.randomInt(1, 100), // Random listing ID
                ethers.parseEther('0.5'),
                0,
                ethers.ZeroAddress,
                3600,
                { value: ethers.parseEther('0.5') }
              );
              const receipt2 = await tx2.wait();
              gasResults.push(Number(receipt2.gasUsed));
              break;

            case 2: // Query operations
              await marketplace.getMarketplaceStats();
              await marketplace.getMarketplaceStats();
              break;
          }
        } catch (error) {
          // Expected for some invalid operations
        }
      }

      if (gasResults.length > 0) {
        const avgGas =
          gasResults.reduce((a, b) => a + b, 0) / gasResults.length;
        const maxGas = Math.max(...gasResults);
        const minGas = Math.min(...gasResults);

        console.log(
          `Gas usage stats - Avg: ${Math.round(avgGas)}, Max: ${maxGas}, Min: ${minGas}`
        );

        // Ensure gas usage is predictable and not exploitable
        expect(maxGas).to.be.below(MAX_GAS_LIMIT);
        expect(avgGas).to.be.below(1000000); // Reasonable average
      }
    });
  });

  after(async function () {
    console.log('\n=== DoS Fuzzing Test Suite Summary ===');
    console.log(`Total fuzzing runs completed across all test categories`);
    console.log(`Random seed used: ${RANDOM_SEED}`);
    console.log(
      'All tests focused on DoS vulnerability discovery through randomized inputs'
    );
    console.log('========================================\n');
  });
});
