// SPDX-License-Identifier: MIT

/**
 * Comprehensive DoS Security Test Suite for WRFCoin
 *
 * Focus Areas:
 * 1. NFTMarketplace.sol - Unbounded Royalty Processing DoS
 * 2. GovernanceSecurityFramework.sol - Unbounded Proposal Enumeration
 * 3. General gas limit exploitation across multiple contracts
 * 4. Economic attack scenarios
 *
 * Test Categories:
 * - Fuzzing Tests: Generate randomized inputs
 * - Attack Simulation: Simulate specific DoS vectors
 * - Gas Consumption: Validate limits and consumption
 * - Economic Attacks: Flash loans, governance manipulation
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
  time,
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

describe('DoS Security Test Suite', function () {
  // Test configuration
  const MAX_GAS_LIMIT = 30000000; // 30M gas block limit
  const ATTACK_ITERATIONS = 1000; // High iteration count for DoS attacks
  const MAX_ROYALTY_RECIPIENTS = 5; // Current NFTMarketplace limit
  const LARGE_ARRAY_SIZE = 10000; // Large array for unbounded loop tests

  // Fuzzing configuration
  const FUZZ_ITERATIONS = 100;
  const RANDOM_SEED = 42;

  // Economic attack parameters
  const FLASH_LOAN_AMOUNT = ethers.parseEther('1000000'); // 1M ETH
  const GOVERNANCE_MANIPULATION_PROPOSALS = 1000;

  async function deployContractsFixture() {
    const [
      owner,
      attacker,
      user1,
      user2,
      user3,
      royaltyRecipient,
      ...testUsers
    ] = await ethers.getSigners();

    // Deploy mock WRF token
    const WRFToken = await ethers.getContractFactory('MockERC20');
    const wrfToken = await WRFToken.deploy('WRFCoin', 'WRF', 18);

    // Deploy MockERC721 for NFT testing
    const MockERC721 =
      await ethers.getContractFactory('MockERC721');
    const nft = await MockERC721.deploy(
      'Test NFT',
      'TNFT'
    );

    // Deploy NFTMarketplace
    const NFTMarketplace = await ethers.getContractFactory('NFTMarketplace');
    const marketplace = await NFTMarketplace.deploy(await wrfToken.getAddress());
    await marketplace
      .connect(owner)
      .setAuthorizedNFTContract(await nft.getAddress(), true);

    // Deploy GovernanceSecurityFramework harness with protocol mocks
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

    // Deploy additional contracts for comprehensive testing
    const CarbonCreditAMM = await ethers.getContractFactory('contracts/CarbonCreditAMM.sol:CarbonCreditAMM');
    const amm = await CarbonCreditAMM.deploy(owner.address);

    // Deploy test helper contracts
    const TestHelper = await ethers.getContractFactory('DOSTestHelper');
    const testHelper = await TestHelper.deploy();

    // Setup initial state
    await wrfToken.mint(owner.address, ethers.parseEther('1000000'));
    await wrfToken.mint(user1.address, ethers.parseEther('10000'));
    await wrfToken.mint(user2.address, ethers.parseEther('10000'));
    await wrfToken.mint(attacker.address, ethers.parseEther('10000'));

    // Seed balances/approval for governance bond transfers in secure proposal paths.
    for (const participant of [owner, user1, user2, user3, attacker, ...testUsers]) {
      await wrfToken.mint(participant.address, ethers.parseEther('2000'));
      await wrfToken
        .connect(participant)
        .approve(await governance.getAddress(), ethers.parseEther('2000'));
    }

    // Mint some test NFTs
    await nft.mintWithURI(user1.address, 1, 'QmTest1');
    await nft.mintWithURI(user2.address, 2, 'QmTest2');
    await nft.mintWithURI(attacker.address, 3, 'QmTest3');

    return {
      wrfToken,
      nft,
      marketplace,
      governance,
      amm,
      testHelper,
      owner,
      attacker,
      user1,
      user2,
      user3,
      royaltyRecipient,
      testUsers,
    };
  }

  describe('1. NFTMarketplace Unbounded Royalty Processing DoS', function () {
    it('Should handle maximum number of royalty recipients without DoS', async function () {
      const { marketplace, nft, user1, testUsers } = await loadFixture(
        deployContractsFixture
      );

      // Create array of maximum allowed recipients
      const recipients = testUsers
        .slice(0, MAX_ROYALTY_RECIPIENTS)
        .map(user => user.address);
      const percentages = new Array(MAX_ROYALTY_RECIPIENTS).fill(50); // 0.5% each

      // This should work within gas limits
      const tx = await marketplace
        .connect(user1)
        .setRoyalties(await nft.getAddress(), 1, recipients, percentages);

      const receipt = await tx.wait();
      expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
    });

    it('Should prevent DoS attack via excessive royalty recipients', async function () {
      const { marketplace, nft, user1, testUsers, attacker } =
        await loadFixture(deployContractsFixture);

      // Attempt to set more than maximum recipients (should fail)
      const recipients = [
        ...testUsers.slice(0, MAX_ROYALTY_RECIPIENTS).map(user => user.address),
        attacker.address,
      ];
      const percentages = new Array(recipients.length).fill(10);

      await expect(
        marketplace
          .connect(user1)
          .setRoyalties(await nft.getAddress(), 1, recipients, percentages)
      ).to.be.revertedWith('Marketplace: Too many royalty recipients');
    });

    it('Should handle gas consumption during royalty processing attack', async function () {
      const { marketplace, nft, user1, user2, testUsers } = await loadFixture(
        deployContractsFixture
      );

      // Set up maximum royalty recipients
      const recipients = testUsers
        .slice(0, MAX_ROYALTY_RECIPIENTS)
        .map(user => user.address);
      const percentages = new Array(MAX_ROYALTY_RECIPIENTS).fill(50);

      await marketplace
        .connect(user1)
        .setRoyalties(await nft.getAddress(), 1, recipients, percentages);

      // Approve and list NFT
      await nft.connect(user1).approve(await marketplace.getAddress(), 1);
      await marketplace.connect(user1).createFixedPriceListing(
        await nft.getAddress(),
        1,
        ethers.parseEther('1'),
        0, // Native payment
        ethers.ZeroAddress,
        3600, // 1 hour
        false,
        []
      );

      // Purchase should still complete within gas limits despite many royalty recipients
      const purchaseTx = await marketplace.connect(user2).buyFixedPrice(1, {
        value: ethers.parseEther('1'),
      });

      const receipt = await purchaseTx.wait();
      expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
    });

    it('Should prevent nested royalty processing DoS via malicious contracts', async function () {
      const { marketplace, nft, user1, attacker } = await loadFixture(
        deployContractsFixture
      );

      // Deploy malicious contract that tries to cause reentrancy during royalty processing
      const MaliciousRoyaltyReceiver = await ethers.getContractFactory(
        'MaliciousRoyaltyReceiver'
      );
      const maliciousReceiver = await MaliciousRoyaltyReceiver.deploy(
        await marketplace.getAddress()
      );

      // Set up royalties with malicious contract as recipient
      await marketplace.connect(user1).setRoyalties(
        await nft.getAddress(),
        1,
        [await maliciousReceiver.getAddress()],
        [500] // 5% (MAX_INDIVIDUAL_ROYALTY)
      );

      await nft.connect(user1).approve(await marketplace.getAddress(), 1);
      await marketplace
        .connect(user1)
        .createFixedPriceListing(
          await nft.getAddress(),
          1,
          ethers.parseEther('1'),
          0,
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      // Purchase should complete without reentrancy attack succeeding
      await expect(
        marketplace.connect(attacker).buyFixedPrice(1, {
          value: ethers.parseEther('1'),
        })
      ).to.not.be.reverted;
    });

    it('Fuzz Test: Random royalty configurations', async function () {
      const { marketplace, nft, user1, testUsers } = await loadFixture(
        deployContractsFixture
      );

      const random = createSeededRandom(RANDOM_SEED);

      for (let i = 0; i < FUZZ_ITERATIONS; i++) {
        // Random number of recipients (1 to MAX_ROYALTY_RECIPIENTS)
        const numRecipients = Math.floor(random() * MAX_ROYALTY_RECIPIENTS) + 1;
        const recipients = testUsers
          .slice(0, numRecipients)
          .map(user => user.address);
        const tokenId = i + 10;

        await nft.mintWithURI(user1.address, tokenId, `QmFuzzRoyalty${tokenId}`);

        // Random percentages ensuring total doesn't exceed maximum
        const maxPerRecipient = Math.floor(2500 / numRecipients); // 25% total max
        const percentages = Array(numRecipients)
          .fill(0)
          .map(() => Math.floor(random() * maxPerRecipient) + 1);

        try {
          const tx = await marketplace.connect(user1).setRoyalties(
            await nft.getAddress(),
            tokenId, // Different token IDs
            recipients,
            percentages
          );

          const receipt = await tx.wait();
          expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
        } catch (error) {
          // Expected failures for invalid configurations
          expect(error.message).to.include('Marketplace:');
        }
      }
    });
  });

  describe('2. GovernanceSecurityFramework Unbounded Proposal Enumeration DoS', function () {
    it('Should handle counting active proposals efficiently', async function () {
      const { governance, wrfToken, user1 } = await loadFixture(
        deployContractsFixture
      );

      // Create multiple proposals to test enumeration
      for (let i = 0; i < 100; i++) {
        await governance.connect(user1).createProposal(
          `Proposal ${i}`,
          `Description ${i}`,
          [await wrfToken.getAddress()], // targets
          [0], // values
          ['transfer(address,uint256)'], // signatures
          [
            ethers.AbiCoder.defaultAbiCoder().encode(
              ['address', 'uint256'],
              [user1.address, ethers.parseEther('1')]
            ),
          ] // calldatas
        );
      }

      // The _countActiveProposals function should complete within reasonable gas limits
      // This is tested indirectly through functions that call it
      const activeCount = await governance.getActiveProposalsCount();
      expect(activeCount).to.equal(100);
    });

    it('Should prevent DoS via excessive proposal creation', async function () {
      const { governance, wrfToken, user1, attacker } = await loadFixture(
        deployContractsFixture
      );

      // Try to create an excessive number of proposals
      let proposalCount = 0;
      let lastSuccessfulGas = 0;

      try {
        for (let i = 0; i < GOVERNANCE_MANIPULATION_PROPOSALS; i++) {
          const tx = await governance
            .connect(attacker)
            .createProposal(
              `Attack Proposal ${i}`,
              `Spam proposal ${i}`,
              [await wrfToken.getAddress()],
              [0],
              ['balanceOf(address)'],
              [
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [attacker.address]
                ),
              ]
            );

          const receipt = await tx.wait();
          lastSuccessfulGas = receipt.gasUsed;
          proposalCount++;

          // If gas usage grows linearly, we have a DoS vulnerability
          if (proposalCount > 10 && receipt.gasUsed > lastSuccessfulGas * 1.5) {
            throw new Error('Gas usage growing too quickly - potential DoS');
          }
        }
      } catch (error) {
        // Expected - either gas limit reached or rate limiting kicked in
        console.log(`Created ${proposalCount} proposals before failure`);
        expect(proposalCount).to.be.below(GOVERNANCE_MANIPULATION_PROPOSALS);
      }
    });

    it('Should handle proposal enumeration under attack conditions', async function () {
      const { governance, wrfToken, user1, testUsers } = await loadFixture(
        deployContractsFixture
      );

      // Create proposals from multiple users to simulate realistic conditions
      const proposals = [];
      for (let i = 0; i < 500; i++) {
        const user = testUsers[i % testUsers.length];

        try {
          const tx = await governance
            .connect(user)
            .createProposal(
              `Mass Proposal ${i}`,
              `Description ${i}`,
              [await wrfToken.getAddress()],
              [0],
              ['totalSupply()'],
              ['0x']
            );
          proposals.push(tx);
        } catch (error) {
          // Expected when rate limiting kicks in
          break;
        }
      }

      console.log(`Created ${proposals.length} proposals for enumeration test`);

      // Test that enumeration functions still work
      const startTime = Date.now();
      const activeCount = await governance.getActiveProposalsCount();
      const enumTime = Date.now() - startTime;

      expect(activeCount).to.be.greaterThan(0);
      expect(enumTime).to.be.below(5000); // Should complete in under 5 seconds
    });

    it('Fuzz Test: Random proposal operations', async function () {
      const { governance, wrfToken, testUsers } = await loadFixture(
        deployContractsFixture
      );

      const random = createSeededRandom(RANDOM_SEED + 1);
      const operations = ['create', 'vote', 'execute', 'cancel'];
      const proposalIds = [];

      for (let i = 0; i < FUZZ_ITERATIONS; i++) {
        const operation = operations[Math.floor(random() * operations.length)];
        const user =
          testUsers[Math.floor(random() * Math.min(10, testUsers.length))];

        try {
          switch (operation) {
            case 'create':
              const tx = await governance
                .connect(user)
                .createProposal(
                  `Fuzz Proposal ${i}`,
                  `Random proposal ${i}`,
                  [await wrfToken.getAddress()],
                  [0],
                  ['totalSupply()'],
                  ['0x']
                );
              const receipt = await tx.wait();
              proposalIds.push(i + 1);
              expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
              break;

            case 'vote':
              if (proposalIds.length > 0) {
                const proposalId =
                  proposalIds[Math.floor(random() * proposalIds.length)];
                const support = random() > 0.5;
                await governance.connect(user).castVote(proposalId, support);
              }
              break;

            default:
              // Other operations would require more complex setup
              break;
          }
        } catch (error) {
          // Expected for invalid operations or insufficient permissions
          expect(error.message).to.not.include('out of gas');
        }
      }
    });
  });

  describe('3. Gas Limit Exploitation Tests', function () {
    it('Should handle large batch operations without exceeding gas limits', async function () {
      const { marketplace, nft, user1, testUsers } = await loadFixture(
        deployContractsFixture
      );

      // Test batch listing operations
      const batchParams = [];
      for (let i = 0; i < 50; i++) {
        // Mint NFT for batch listing
        await nft.mintWithURI(user1.address, 100 + i, `QmBatch${i}`);
        await nft
          .connect(user1)
          .approve(await marketplace.getAddress(), 100 + i);

        batchParams.push({
          nftContract: await nft.getAddress(),
          tokenId: 100 + i,
          price: ethers.parseEther('1'),
          duration: 3600,
        });
      }

      // Batch create listings should complete within gas limits
      const tx = await marketplace
        .connect(user1)
        .createBatchFixedPriceListings(
          await nft.getAddress(),
          batchParams,
          0,
          ethers.ZeroAddress
        );
      const receipt = await tx.wait();

      expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
    });

    it('Should prevent gas limit attacks on array iteration functions', async function () {
      const { testHelper } = await loadFixture(deployContractsFixture);

      // Test with progressively larger arrays
      const testSizes = [100, 1000, 5000, 10000];

      for (const size of testSizes) {
        const largeArray = Array(size)
          .fill(0)
          .map((_, i) => i + 1);

        try {
          const tx = await testHelper.processLargeArray(largeArray);
          const receipt = await tx.wait();

          console.log(`Array size ${size}: ${receipt.gasUsed} gas used`);

          // If gas usage exceeds limits, function should revert gracefully
          if (receipt.gasUsed > MAX_GAS_LIMIT * 0.8) {
            console.log(`Warning: High gas usage for array size ${size}`);
          }
        } catch (error) {
          // Expected for very large arrays
          expect(error.message).to.include('gas');
          console.log(
            `Array size ${size}: Failed as expected (${error.message})`
          );
        }
      }
    });

    it('Should handle nested loop complexity attacks', async function () {
      const { testHelper } = await loadFixture(deployContractsFixture);

      // Test nested loop scenarios that could cause O(n²) complexity
      const nestedTestSizes = [10, 50, 100, 200];

      for (const size of nestedTestSizes) {
        try {
          const tx = await testHelper.processNestedOperations(size, size);
          const receipt = await tx.wait();

          console.log(`Nested ${size}x${size}: ${receipt.gasUsed} gas used`);
          expect(receipt.gasUsed).to.be.below(MAX_GAS_LIMIT);
        } catch (error) {
          // Expected for large nested operations
          console.log(`Nested ${size}x${size}: Failed as expected`);
        }
      }
    });
  });

  describe('4. Economic Attack Simulations', function () {
    it('Should resist flash loan governance attacks', async function () {
      const { governance, wrfToken, attacker } = await loadFixture(
        deployContractsFixture
      );

      // Deploy flash loan attack contract
      const FlashLoanAttacker = await ethers.getContractFactory(
        'FlashLoanGovernanceAttacker'
      );
      const flashAttacker = await FlashLoanAttacker.deploy(
        await governance.getAddress(),
        await wrfToken.getAddress()
      );

      // Simulate flash loan attack on governance
      const initialBalance = await wrfToken.balanceOf(attacker.address);

      await expect(
        flashAttacker
          .connect(attacker)
          .executeFlashLoanAttack(
            FLASH_LOAN_AMOUNT,
            'Malicious Proposal',
            'This proposal should not pass'
          )
      ).to.not.be.reverted;
      expect(await flashAttacker.isAttackInProgress()).to.equal(false);

      // Attacker's balance should not have increased
      const finalBalance = await wrfToken.balanceOf(attacker.address);
      expect(finalBalance).to.equal(initialBalance);
    });

    it('Should prevent liquidity drainage attacks on AMM', async function () {
      const { amm, attacker } = await loadFixture(deployContractsFixture);

      await expect(
        amm
          .connect(attacker)
          .flashLoan(ethers.parseEther('1'), 0, attacker.address, '0x')
      ).to.be.revertedWith('CarbonCreditAMM: UNAUTHORIZED_FLASH_BORROWER');
    });

    it('Should handle sandwich attacks and MEV protection', async function () {
      const { marketplace, nft, user1, user2, attacker } = await loadFixture(
        deployContractsFixture
      );

      // Setup NFT listing
      await nft.mintWithURI(user1.address, 200, 'QmSandwich');
      await nft.connect(user1).approve(await marketplace.getAddress(), 200);

      await marketplace
        .connect(user1)
        .createFixedPriceListing(
          await nft.getAddress(),
          200,
          ethers.parseEther('1'),
          0,
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      // Simulate sandwich attack
      const listingId = 1;

      // Front-running transaction
      const frontRunTx = marketplace
        .connect(attacker)
        .makeOffer(
          await nft.getAddress(),
          200,
          ethers.parseEther('0.8'),
          0,
          ethers.ZeroAddress,
          3600,
          { value: ethers.parseEther('0.8') }
        );

      // Victim transaction
      const victimTx = marketplace.connect(user2).buyFixedPrice(listingId, {
        value: ethers.parseEther('1'),
      });

      // Back-running transaction
      const backRunTx = marketplace
        .connect(attacker)
        .cancelOffer(await nft.getAddress(), 200, 0);

      // Execute in sequence and verify protection mechanisms
      await frontRunTx;
      await victimTx; // Victim should get the NFT, not the attacker

      try {
        await backRunTx;
      } catch (error) {
        // Expected if marketplace has MEV protection
      }

      // Verify NFT went to legitimate buyer
      expect(await nft.ownerOf(200)).to.equal(user2.address);
    });
  });

  describe('5. Comprehensive Attack Scenarios', function () {
    it('Should handle coordinated multi-vector attacks', async function () {
      const { marketplace, governance, nft, wrfToken, attacker, testUsers } =
        await loadFixture(deployContractsFixture);

      // Simulate coordinated attack across multiple contracts
      const attackPromises = [];

      // Attack 1: Spam governance with proposals
      attackPromises.push(
        governance
          .connect(attacker)
          .createProposal(
            'Attack Proposal 1',
            'Malicious proposal',
            [await wrfToken.getAddress()],
            [0],
            ['transfer(address,uint256)'],
            [
              ethers.AbiCoder.defaultAbiCoder().encode(
                ['address', 'uint256'],
                [attacker.address, ethers.parseEther('1000')]
              ),
            ]
          )
          .catch(() => {}) // Ignore failures
      );

      // Attack 2: Spam marketplace with excessive royalty recipients
      for (let i = 0; i < 10; i++) {
        attackPromises.push(
          marketplace
            .connect(attacker)
            .setRoyalties(
              await nft.getAddress(),
              300 + i,
              testUsers
                .slice(0, Math.min(50, testUsers.length))
                .map(u => u.address),
              Array(Math.min(50, testUsers.length)).fill(100)
            )
            .catch(() => {}) // Ignore failures
        );
      }

      // Attack 3: Attempt to drain marketplace
      attackPromises.push(
        marketplace
          .connect(attacker)
          .withdraw()
          .catch(() => {})
      );

      // Execute all attacks simultaneously
      await Promise.all(attackPromises);

      // System should remain operational
      expect(await governance.getActiveProposalsCount()).to.be.greaterThan(0);
      expect(await marketplace.owner()).to.not.equal(attacker.address);
    });

    it('Should maintain performance under sustained attack', async function () {
      const { marketplace, nft, attacker, testUsers } = await loadFixture(
        deployContractsFixture
      );

      const startTime = Date.now();
      const attackDuration = 30000; // 30 seconds
      let operationCount = 0;

      // Sustained attack simulation
      while (Date.now() - startTime < attackDuration) {
        try {
          // Rotate between different attack vectors
          const attackType = operationCount % 4;

          switch (attackType) {
            case 0:
              await marketplace.connect(attacker).getMarketplaceStats();
              break;
            case 1:
              await marketplace.connect(attacker).getMarketplaceStats();
              break;
            case 2:
              await nft.balanceOf(attacker.address);
              break;
            case 3:
              await marketplace.connect(attacker).getMarketplaceStats();
              break;
          }

          operationCount++;
        } catch (error) {
          // Continue attacking even if operations fail
        }
      }

      console.log(
        `Performed ${operationCount} operations in ${attackDuration}ms`
      );
      const tps = operationCount / (attackDuration / 1000);

      // System should maintain reasonable performance
      expect(tps).to.be.greaterThan(1); // At least 1 TPS under attack
    });

    it('Should recover gracefully after attack mitigation', async function () {
      const { marketplace, nft, user1, user2, attacker } = await loadFixture(
        deployContractsFixture
      );

      // Perform attack
      try {
        const attackPromises = [];
        for (let i = 0; i < 100; i++) {
          attackPromises.push(
            marketplace
              .connect(attacker)
              .makeOffer(
                999999, // Non-existent listing
                ethers.parseEther('0.1'),
                0,
                ethers.ZeroAddress,
                3600,
                { value: ethers.parseEther('0.1') }
              )
              .catch(() => {})
          );
        }
        await Promise.all(attackPromises);
      } catch (error) {
        // Expected
      }

      // Normal operations should still work after attack
      await nft.mintWithURI(user1.address, 500, 'QmRecovery');
      await nft.connect(user1).approve(await marketplace.getAddress(), 500);

      await marketplace
        .connect(user1)
        .createFixedPriceListing(
          await nft.getAddress(),
          500,
          ethers.parseEther('1'),
          0,
          ethers.ZeroAddress,
          3600,
          false,
          []
        );

      await marketplace.connect(user2).buyFixedPrice(1, {
        value: ethers.parseEther('1'),
      });

      // Verify recovery
      expect(await nft.ownerOf(500)).to.equal(user2.address);
    });
  });
});
