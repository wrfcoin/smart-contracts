// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const {
  loadFixture,
} = require('@nomicfoundation/hardhat-network-helpers');

/**
 * CarbonBasketToken — Batch-Size Security Tests
 *
 * Validates the MAX_BATCH_SIZE (50) bound added to deposit() and withdraw(),
 * preventing block-gas-limit DoS from unbounded loops containing external
 * transferFrom calls. Withdraw reverts (not silently caps) when too large.
 */
describe('CarbonBasketToken — Batch Size Limits (sc#25)', function () {
  async function deployFixture() {
    const [owner, user] = await ethers.getSigners();

    // Deploy WRFToken (needed by CarbonCredits)
    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();

    // Deploy CarbonCredits NFT
    const CarbonCredits = await ethers.getContractFactory('CarbonCredits');
    const carbonCredits = await CarbonCredits.deploy(await wrfToken.getAddress());

    // Deploy mock quality oracle
    const MockOracle = await ethers.getContractFactory('MockQualityOracleConcrete');
    const oracle = await MockOracle.deploy();

    // Deploy CarbonBasketToken
    const CarbonBasketToken = await ethers.getContractFactory('CarbonBasketToken');
    const basket = await CarbonBasketToken.deploy(
      await oracle.getAddress(),
      'Carbon Basket',
      'CBASKET'
    );

    // Set quality score for the credit contract (above MIN_QUALITY_THRESHOLD=60)
    const creditAddr = await carbonCredits.getAddress();
    await oracle.setQualityScore(creditAddr, 80);

    // Add CarbonCredits as authorized component (50% weight)
    await basket.addComponent(creditAddr, 5000);

    // Authorize owner as issuer so we can mint NFTs
    await carbonCredits.authorizeIssuer(owner.address);

    return { owner, user, wrfToken, carbonCredits, oracle, basket, creditAddr };
  }

  /**
   * Helper: issue `count` carbon credit NFTs to `recipient` and return their token IDs.
   * Also approves the basket contract to transfer them.
   */
  async function mintCredits(carbonCredits, basket, recipient, count) {
    const basketAddr = await basket.getAddress();
    const ids = [];
    const futureExpiry = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;

    for (let i = 0; i < count; i++) {
      const tx = await carbonCredits.issueCredit({
        carbonOffsetTonnes: 10,
        projectType: 'renewable-energy',
        verificationStandard: 'VCS',
        expiryDate: futureExpiry,
        location: 'Global',
        certificationHash: `ipfs://cert-${Date.now()}-${i}-${Math.random()}`,
        tokenURIPath: `https://example.com/token/${i}`,
        qualityScore: 80,
        vintageYear: 2025,
        additionalData: '',
      });
      const receipt = await tx.wait();

      // Find Transfer event to get token ID
      const transferEvent = receipt.logs.find(
        (log) => {
          try {
            const parsed = carbonCredits.interface.parseLog({ topics: log.topics, data: log.data });
            return parsed && parsed.name === 'Transfer';
          } catch {
            return false;
          }
        }
      );
      const parsed = carbonCredits.interface.parseLog({
        topics: transferEvent.topics,
        data: transferEvent.data,
      });
      const tokenId = parsed.args[2]; // Transfer(from, to, tokenId)
      ids.push(tokenId);

      // Transfer to recipient if not already owner
      if (recipient !== (await carbonCredits.runner).address) {
        await carbonCredits.transferFrom((await carbonCredits.runner).address, recipient, tokenId);
      }
    }

    // Approve basket to transfer all
    const signer = await ethers.getSigner(recipient);
    await carbonCredits.connect(signer).setApprovalForAll(basketAddr, true);

    return ids;
  }

  // ----------------------------------------------------------------
  // deposit() tests
  // ----------------------------------------------------------------

  describe('deposit() batch size limits', function () {
    it('should accept deposit of exactly MAX_BATCH_SIZE (50) tokens', async function () {
      const { owner, carbonCredits, basket, creditAddr } = await loadFixture(deployFixture);

      const ids = await mintCredits(carbonCredits, basket, owner.address, 50);
      await expect(basket.deposit(creditAddr, ids)).to.not.be.reverted;

      // Verify basket tokens were minted
      const balance = await basket.balanceOf(owner.address);
      expect(balance).to.be.gt(0);
    });

    it('should revert deposit of MAX_BATCH_SIZE + 1 (51) tokens with "Batch too large"', async function () {
      const { owner, carbonCredits, basket, creditAddr } = await loadFixture(deployFixture);

      const ids = await mintCredits(carbonCredits, basket, owner.address, 51);
      await expect(basket.deposit(creditAddr, ids)).to.be.revertedWith(
        'CarbonBasketToken: Batch too large'
      );
    });

    it('should still allow small deposits (1 token)', async function () {
      const { owner, carbonCredits, basket, creditAddr } = await loadFixture(deployFixture);

      const ids = await mintCredits(carbonCredits, basket, owner.address, 1);
      await expect(basket.deposit(creditAddr, ids)).to.not.be.reverted;

      const balance = await basket.balanceOf(owner.address);
      expect(balance).to.be.gt(0);
    });

    it('should still reject empty deposits', async function () {
      const { basket, creditAddr } = await loadFixture(deployFixture);

      await expect(basket.deposit(creditAddr, [])).to.be.revertedWith(
        'CarbonBasketToken: No tokens provided'
      );
    });
  });

  // ----------------------------------------------------------------
  // withdraw() tests
  // ----------------------------------------------------------------

  describe('withdraw() per-component cap', function () {
    it('should allow normal small withdrawal', async function () {
      const { owner, carbonCredits, basket, creditAddr } = await loadFixture(deployFixture);

      // Deposit 5 tokens
      const ids = await mintCredits(carbonCredits, basket, owner.address, 5);
      await basket.deposit(creditAddr, ids);

      const basketBal = await basket.balanceOf(owner.address);

      // Withdraw all basket tokens — should return all 5 NFTs
      await expect(basket.withdraw(basketBal)).to.not.be.reverted;

      // User should have received NFTs back
      for (const id of ids) {
        expect(await carbonCredits.ownerOf(id)).to.equal(owner.address);
      }
    });

    it('should revert when per-component withdrawal exceeds MAX_BATCH_SIZE', async function () {
      const { owner, carbonCredits, basket, creditAddr } = await loadFixture(deployFixture);

      // We deposit in two batches of 50 to get 100 tokens into the component
      const ids1 = await mintCredits(carbonCredits, basket, owner.address, 50);
      await basket.deposit(creditAddr, ids1);

      const ids2 = await mintCredits(carbonCredits, basket, owner.address, 50);
      await basket.deposit(creditAddr, ids2);

      const totalBasket = await basket.balanceOf(owner.address);
      expect(totalBasket).to.be.gt(0);

      // Withdraw all basket tokens at once — should revert because >50 NFTs in a component
      await expect(basket.withdraw(totalBasket)).to.be.revertedWith(
        'CarbonBasketToken: Withdraw batch too large'
      );
    });

    it('should allow large position to be withdrawn in multiple smaller calls', async function () {
      const { owner, carbonCredits, basket, creditAddr } = await loadFixture(deployFixture);

      // Deposit two batches of 50 to get 100 tokens into the component
      const ids1 = await mintCredits(carbonCredits, basket, owner.address, 50);
      await basket.deposit(creditAddr, ids1);

      const ids2 = await mintCredits(carbonCredits, basket, owner.address, 50);
      await basket.deposit(creditAddr, ids2);

      const totalBasket = await basket.balanceOf(owner.address);
      expect(totalBasket).to.be.gt(0);

      // Withdraw in two halves — each should succeed (<=50 NFTs per component)
      const halfBasket = totalBasket / 2n;
      await expect(basket.withdraw(halfBasket)).to.not.be.reverted;
      await expect(basket.withdraw(halfBasket)).to.not.be.reverted;

      // All 100 NFTs should be back with the owner
      const allIds = [...ids1, ...ids2];
      for (const id of allIds) {
        expect(await carbonCredits.ownerOf(id)).to.equal(owner.address);
      }

      // Basket token balance should be zero
      expect(await basket.balanceOf(owner.address)).to.equal(0);
    });
  });

  // ----------------------------------------------------------------
  // Constant verification
  // ----------------------------------------------------------------

  describe('constant value', function () {
    it('MAX_BATCH_SIZE should equal 50', async function () {
      const { basket } = await loadFixture(deployFixture);
      expect(await basket.MAX_BATCH_SIZE()).to.equal(50);
    });
  });
});
