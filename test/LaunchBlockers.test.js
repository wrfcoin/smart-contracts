const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('Launch blocker fixes', function () {
  async function deployMockERC20(name = 'Mock Token', symbol = 'MOCK') {
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    return MockERC20.deploy(name, symbol, 18);
  }

  describe('CarbonCreditAMMFactory constructor args', function () {
    it('deploys pools with the expected factory constructor arg and matching prediction', async function () {
      const [deployer] = await ethers.getSigners();
      const tokenA = await deployMockERC20('Token A', 'TKA');
      const tokenB = await deployMockERC20('Token B', 'TKB');

      const Factory = await ethers.getContractFactory('CarbonCreditAMMFactory');
      const factory = await Factory.deploy();

      const predicted = await factory.predictPoolAddress(
        await tokenA.getAddress(),
        await tokenB.getAddress(),
        30,
      );

      await expect(factory.createPool(await tokenA.getAddress(), await tokenB.getAddress(), 30))
        .to.emit(factory, 'PoolCreated');

      expect(await factory.getPool(await tokenA.getAddress(), await tokenB.getAddress(), 30))
        .to.equal(predicted);

      const AMM = await ethers.getContractFactory('CarbonCreditAMM');
      const pool = AMM.attach(predicted).connect(deployer);
      expect(await pool.expectedFactory()).to.equal(await factory.getAddress());
    });
  });

  describe('NFTMarketplace offer escrow', function () {
    async function marketplaceFixture() {
      const [owner, seller, buyer] = await ethers.getSigners();
      const wrf = await deployMockERC20('WRF', 'WRF');

      const Marketplace = await ethers.getContractFactory('NFTMarketplace');
      const marketplace = await Marketplace.deploy(await wrf.getAddress());

      const MockERC721 = await ethers.getContractFactory('MockERC721');
      const nft = await MockERC721.deploy('Weather NFT', 'WNFT');
      await marketplace.setAuthorizedNFTContract(await nft.getAddress(), true);

      await nft['mint(address,uint256)'](seller.address, 1);
      await nft.connect(seller).approve(await marketplace.getAddress(), 1);

      return { owner, seller, buyer, wrf, marketplace, nft };
    }

    it('requires native offer escrow before crediting accepted-offer withdrawals', async function () {
      const { owner, seller, buyer, marketplace, nft } = await loadFixture(marketplaceFixture);
      const amount = ethers.parseEther('1');

      await expect(
        marketplace.connect(buyer).makeOffer(
          await nft.getAddress(),
          1,
          amount,
          0,
          ethers.ZeroAddress,
          2 * 60 * 60,
        ),
      ).to.be.revertedWith('Marketplace: Invalid native escrow');

      await marketplace.connect(buyer).makeOffer(
        await nft.getAddress(),
        1,
        amount,
        0,
        ethers.ZeroAddress,
        2 * 60 * 60,
        { value: amount },
      );

      await marketplace.connect(seller).acceptOffer(await nft.getAddress(), 1, 0);

      const fee = (amount * 250n) / 10000n;
      expect(await marketplace.pendingWithdrawals(seller.address)).to.equal(amount - fee);
      expect(await marketplace.pendingWithdrawals(owner.address)).to.equal(fee);
      expect(await nft.ownerOf(1)).to.equal(buyer.address);
    });

    it('keeps ERC20 offer escrow separate from withdrawal liabilities and refunds on cancel', async function () {
      const { buyer, wrf, marketplace, nft } = await loadFixture(marketplaceFixture);
      const amount = ethers.parseEther('5');

      await wrf.mint(buyer.address, amount);
      await wrf.connect(buyer).approve(await marketplace.getAddress(), amount);

      await marketplace.connect(buyer).makeOffer(
        await nft.getAddress(),
        1,
        amount,
        3,
        await wrf.getAddress(),
        2 * 60 * 60,
      );

      expect(await marketplace.tokenWithdrawals(buyer.address, await wrf.getAddress())).to.equal(0);
      expect(await wrf.balanceOf(buyer.address)).to.equal(0);

      await marketplace.connect(buyer).cancelOffer(await nft.getAddress(), 1, 0);

      expect(await wrf.balanceOf(buyer.address)).to.equal(amount);
      expect(await marketplace.tokenWithdrawals(buyer.address, await wrf.getAddress())).to.equal(0);
    });
  });

  describe('Incentive reward payouts', function () {
    it('credits and pays model training rewards from funded job escrow', async function () {
      const [owner, requester, contributor] = await ethers.getSigners();
      const wrf = await deployMockERC20('WRF', 'WRF');
      const ModelTrainingRewards = await ethers.getContractFactory('ModelTrainingRewards');
      const rewards = await ModelTrainingRewards.deploy(await wrf.getAddress());

      await rewards.connect(contributor).registerContributor('worker', [0]);
      await rewards.verifyContributor(contributor.address);

      const fundedReward = ethers.parseEther('1');
      await rewards.connect(requester).createTrainingJob(
        'weather',
        'ipfs://dataset',
        1,
        (await time.latest()) + 7 * 24 * 60 * 60,
        2,
        { value: fundedReward },
      );

      await rewards.connect(contributor).submitContribution(1, 1, 3600, 'ipfs://result', 0);
      await rewards.verifyContribution(1, 9000, 9000);

      expect(await rewards.pendingRewards(contributor.address)).to.equal(fundedReward);
      await expect(rewards.connect(contributor).claimRewards())
        .to.changeEtherBalances([rewards, contributor], [-fundedReward, fundedReward]);
      expect(await rewards.pendingRewards(contributor.address)).to.equal(0);
    });

    it('transfers grant milestone WRF to the recipient on approval', async function () {
      const [admin, recipient, reviewer1, reviewer2] = await ethers.getSigners();
      const wrf = await deployMockERC20('WRF', 'WRF');
      const GrantDistribution = await ethers.getContractFactory('GrantDistribution');
      const grants = await GrantDistribution.deploy(await wrf.getAddress());
      const grantAmount = ethers.parseEther('1000');

      await wrf.mint(await grants.getAddress(), grantAmount);
      await grants.setCategoryBudget(0, grantAmount);
      await grants.addReviewer(reviewer1.address);
      await grants.addReviewer(reviewer2.address);

      await grants.connect(recipient).submitProposal(
        'Launch grant',
        'ipfs://abstract',
        grantAmount,
        0,
      );
      await grants.startVoting(1);
      await grants.connect(admin).voteOnProposal(1, true);
      await grants.connect(reviewer1).voteOnProposal(1, true);
      await grants.connect(reviewer2).voteOnProposal(1, true);

      await grants.approveGrant(
        1,
        ['Ship launch blocker fix'],
        [grantAmount],
        [(await time.latest()) + 7 * 24 * 60 * 60],
      );
      await grants.connect(recipient).submitMilestone(1, 0, 'ipfs://deliverable');

      await expect(grants.approveMilestone(1, 0))
        .to.changeTokenBalances(wrf, [grants, recipient], [-grantAmount, grantAmount]);
    });

    it('pays peer review claims from submission escrow', async function () {
      const [researcher, reviewer] = await ethers.getSigners();
      const PeerReview = await ethers.getContractFactory('PeerReviewIncentives');
      const peerReview = await PeerReview.deploy();

      await peerReview.connect(reviewer).registerReviewer('climate reviewer', 1);
      await peerReview.verifyReviewer(reviewer.address);

      const tx = await peerReview.connect(researcher).submitResearch(
        'Launch paper',
        'ipfs://abstract',
        'ipfs://dataset',
        0,
        { value: ethers.parseEther('100') },
      );
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log) => {
          try {
            return peerReview.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((parsed) => parsed && parsed.name === 'ResearchSubmitted');
      const submissionHash = event.args.submissionHash;

      await peerReview.connect(reviewer).submitReview(
        submissionHash,
        1,
        10,
        'ipfs://feedback',
      );

      const reward = await peerReview.pendingRewards(reviewer.address);
      expect(reward).to.be.greaterThan(0n);
      await expect(peerReview.connect(reviewer).claimRewards())
        .to.changeEtherBalances([peerReview, reviewer], [-reward, reward]);
      expect(await peerReview.pendingRewards(reviewer.address)).to.equal(0);
    });
  });

  describe('Governance launch bootstrap', function () {
    it('role-gates launch reputation and stake initialization', async function () {
      const [admin, participant, stranger] = await ethers.getSigners();
      const wrf = await deployMockERC20('WRF', 'WRF');
      const Governance = await ethers.getContractFactory('GovernanceSecurityFramework');
      const governance = await Governance.deploy(
        admin.address,
        admin.address,
        admin.address,
        await wrf.getAddress(),
      );

      await expect(
        governance.connect(stranger).bootstrapLaunchParticipant(
          participant.address,
          500,
          ethers.parseEther('100'),
        ),
      ).to.be.revertedWithCustomError(governance, 'AccessControlUnauthorizedAccount').withArgs(stranger.address, await governance.GOVERNANCE_ADMIN_ROLE());

      await governance.bootstrapLaunchParticipant(
        participant.address,
        500,
        ethers.parseEther('100'),
      );

      expect(await governance.stakedTokens(participant.address)).to.equal(ethers.parseEther('100'));
      const reputation = await governance.reputationData(participant.address);
      expect(reputation.baseReputation).to.equal(500);
    });
  });
});
