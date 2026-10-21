const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("StorageEndowment", function () {
  let storageEndowment;
  let wrfToken;
  let owner;
  let admin;
  let keeperBot;
  let keeperBot2;
  let user;
  let rewardDistributor;

  const MAX_CLAIM_AMOUNT = ethers.parseEther("100");
  const INITIAL_RATE_BPS = 50;

  async function seedEndowment(amount) {
    await wrfToken.connect(owner).approve(await storageEndowment.getAddress(), amount);
    await storageEndowment.connect(owner).depositEndowment(amount);
  }

  beforeEach(async function () {
    [owner, admin, keeperBot, keeperBot2, user, rewardDistributor] = await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    wrfToken = await ERC20Mock.deploy("WRF Token", "WRF", 18);

    await wrfToken.mint(owner.address, ethers.parseEther("1000000"));
    await wrfToken.mint(rewardDistributor.address, ethers.parseEther("1000000"));

    const StorageEndowment = await ethers.getContractFactory("StorageEndowment");
    storageEndowment = await StorageEndowment.deploy(
      await wrfToken.getAddress(),
      MAX_CLAIM_AMOUNT,
      INITIAL_RATE_BPS
    );

    const ADMIN_ROLE = await storageEndowment.ADMIN_ROLE();
    const KEEPER_BOT_ROLE = await storageEndowment.KEEPER_BOT_ROLE();

    await storageEndowment.grantRole(ADMIN_ROLE, admin.address);
    await storageEndowment.grantRole(KEEPER_BOT_ROLE, keeperBot.address);
    await storageEndowment.grantRole(KEEPER_BOT_ROLE, keeperBot2.address);
  });

  describe("Constructor", function () {
    it("reverts with zero token address", async function () {
      const StorageEndowment = await ethers.getContractFactory("StorageEndowment");

      await expect(
        StorageEndowment.deploy(ethers.ZeroAddress, MAX_CLAIM_AMOUNT, INITIAL_RATE_BPS)
      ).to.be.revertedWith("Invalid WRF token address");
    });

    it("uses default rate when initial rate is zero", async function () {
      const StorageEndowment = await ethers.getContractFactory("StorageEndowment");
      const contract = await StorageEndowment.deploy(
        await wrfToken.getAddress(),
        MAX_CLAIM_AMOUNT,
        0
      );

      expect(await contract.endowmentRateBps()).to.equal(50);
    });

    it("reverts when initial rate exceeds ceiling", async function () {
      const StorageEndowment = await ethers.getContractFactory("StorageEndowment");

      await expect(
        StorageEndowment.deploy(await wrfToken.getAddress(), MAX_CLAIM_AMOUNT, 1001)
      ).to.be.revertedWith("Rate exceeds ceiling");
    });
  });

  describe("Endowment Deposit", function () {
    it("allows depositing WRF into the endowment", async function () {
      const depositAmount = ethers.parseEther("500");
      await wrfToken.connect(owner).approve(await storageEndowment.getAddress(), depositAmount);

      await expect(storageEndowment.connect(owner).depositEndowment(depositAmount))
        .to.emit(storageEndowment, "EndowmentReceived")
        .withArgs(owner.address, depositAmount);

      expect(await wrfToken.balanceOf(await storageEndowment.getAddress())).to.equal(depositAmount);
    });
  });

  describe("Claiming Funds", function () {
    beforeEach(async function () {
      await seedEndowment(ethers.parseEther("1000"));
    });

    it("allows a keeper bot to claim funds for a storage deal", async function () {
      const claimAmount = ethers.parseEther("50");
      await expect(storageEndowment.connect(keeperBot).claimForStorageDeal(claimAmount, "deal-123"))
        .to.emit(storageEndowment, "FundsClaimed")
        .withArgs(keeperBot.address, claimAmount, "deal-123");

      expect(await wrfToken.balanceOf(keeperBot.address)).to.equal(claimAmount);
    });

    it("reverts when endowment balance is insufficient", async function () {
      await storageEndowment.connect(admin).setMaxClaimAmountPerDay(ethers.parseEther("5000"));

      await expect(
        storageEndowment
          .connect(keeperBot)
          .claimForStorageDeal(ethers.parseEther("2000"), "deal-insufficient")
      ).to.be.revertedWith("Insufficient endowment funds");
    });
  });

  describe("Daily Limit Enforcement", function () {
    beforeEach(async function () {
      await seedEndowment(ethers.parseEther("1000"));
    });

    it("reverts when cumulative claims exceed maxClaimAmountPerDay", async function () {
      const firstClaim = ethers.parseEther("60");
      const secondClaim = ethers.parseEther("41");

      await storageEndowment.connect(keeperBot).claimForStorageDeal(firstClaim, "deal-1");

      await expect(
        storageEndowment.connect(keeperBot).claimForStorageDeal(secondClaim, "deal-2")
      ).to.be.revertedWith("Exceeds daily claim limit");
    });

    it("resets daily limit after 24 hours", async function () {
      await storageEndowment
        .connect(keeperBot)
        .claimForStorageDeal(MAX_CLAIM_AMOUNT, "deal-1");

      await expect(
        storageEndowment
          .connect(keeperBot)
          .claimForStorageDeal(ethers.parseEther("1"), "deal-2")
      ).to.be.revertedWith("Exceeds daily claim limit");

      await ethers.provider.send("evm_increaseTime", [25 * 60 * 60]);
      await ethers.provider.send("evm_mine");

      await expect(
        storageEndowment
          .connect(keeperBot)
          .claimForStorageDeal(ethers.parseEther("1"), "deal-3")
      ).to.not.be.reverted;
    });

    it("tracks independent daily limits for two keepers", async function () {
      await storageEndowment
        .connect(keeperBot)
        .claimForStorageDeal(MAX_CLAIM_AMOUNT, "keeper-1-deal");

      await expect(
        storageEndowment
          .connect(keeperBot)
          .claimForStorageDeal(ethers.parseEther("1"), "keeper-1-extra")
      ).to.be.revertedWith("Exceeds daily claim limit");

      await expect(
        storageEndowment
          .connect(keeperBot2)
          .claimForStorageDeal(MAX_CLAIM_AMOUNT, "keeper-2-deal")
      ).to.not.be.reverted;

      expect(await storageEndowment.dailyClaimedAmount(keeperBot.address)).to.equal(MAX_CLAIM_AMOUNT);
      expect(await storageEndowment.dailyClaimedAmount(keeperBot2.address)).to.equal(MAX_CLAIM_AMOUNT);
    });
  });

  describe("Access Control", function () {
    beforeEach(async function () {
      await seedEndowment(ethers.parseEther("1000"));
    });

    it("reverts when non-keeper calls claimForStorageDeal", async function () {
      const KEEPER_BOT_ROLE = await storageEndowment.KEEPER_BOT_ROLE();

      await expect(storageEndowment.connect(user).claimForStorageDeal(ethers.parseEther("1"), "deal-123"))
        .to.be.revertedWithCustomError(storageEndowment, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, KEEPER_BOT_ROLE);
    });

    it("reverts when non-admin calls setMaxClaimAmountPerDay", async function () {
      const ADMIN_ROLE = await storageEndowment.ADMIN_ROLE();

      await expect(storageEndowment.connect(user).setMaxClaimAmountPerDay(ethers.parseEther("200")))
        .to.be.revertedWithCustomError(storageEndowment, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, ADMIN_ROLE);
    });
  });

  describe("Pause", function () {
    beforeEach(async function () {
      await seedEndowment(ethers.parseEther("1000"));
    });

    it("reverts depositEndowment when paused", async function () {
      const depositAmount = ethers.parseEther("10");
      await storageEndowment.connect(admin).pause();
      await wrfToken.connect(owner).approve(await storageEndowment.getAddress(), depositAmount);

      await expect(storageEndowment.connect(owner).depositEndowment(depositAmount)).to.be.revertedWithCustomError(
        storageEndowment,
        "EnforcedPause"
      );
    });

    it("reverts claimForStorageDeal when paused", async function () {
      await storageEndowment.connect(admin).pause();

      await expect(
        storageEndowment.connect(keeperBot).claimForStorageDeal(ethers.parseEther("10"), "deal-paused")
      ).to.be.revertedWithCustomError(storageEndowment, "EnforcedPause");
    });

    it("unpause restores full operation", async function () {
      const depositAmount = ethers.parseEther("10");
      const claimAmount = ethers.parseEther("5");

      await storageEndowment.connect(admin).pause();
      await storageEndowment.connect(admin).unpause();

      await wrfToken.connect(owner).approve(await storageEndowment.getAddress(), depositAmount);
      await expect(storageEndowment.connect(owner).depositEndowment(depositAmount)).to.not.be.reverted;

      await expect(storageEndowment.connect(keeperBot).claimForStorageDeal(claimAmount, "deal-unpause")).to.not.be
        .reverted;
    });

    it("reverts when non-admin pauses", async function () {
      const ADMIN_ROLE = await storageEndowment.ADMIN_ROLE();

      await expect(storageEndowment.connect(user).pause())
        .to.be.revertedWithCustomError(storageEndowment, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, ADMIN_ROLE);
    });

    it("reverts when non-admin unpauses", async function () {
      const ADMIN_ROLE = await storageEndowment.ADMIN_ROLE();
      await storageEndowment.connect(admin).pause();

      await expect(storageEndowment.connect(user).unpause())
        .to.be.revertedWithCustomError(storageEndowment, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, ADMIN_ROLE);
    });
  });

  describe("Zero-amount guards", function () {
    beforeEach(async function () {
      await seedEndowment(ethers.parseEther("1000"));
    });

    it("depositEndowment(0) reverts", async function () {
      await expect(storageEndowment.connect(owner).depositEndowment(0)).to.be.revertedWith("Amount must be > 0");
    });

    it("claimForStorageDeal(0, dealId) reverts", async function () {
      await expect(storageEndowment.connect(keeperBot).claimForStorageDeal(0, "deal")).to.be.revertedWith(
        "Amount must be > 0"
      );
    });

    it("claimForStorageDeal with empty dealId reverts", async function () {
      await expect(storageEndowment.connect(keeperBot).claimForStorageDeal(1, "")).to.be.revertedWith(
        "Deal ID required"
      );
    });
  });

  describe("receiveBlockReward", function () {
    it("emits EndowmentReceived and increases balance", async function () {
      const amount = ethers.parseEther("250");
      const endowmentAddress = await storageEndowment.getAddress();

      await wrfToken.connect(rewardDistributor).approve(endowmentAddress, amount);

      await expect(storageEndowment.connect(rewardDistributor).receiveBlockReward(amount))
        .to.emit(storageEndowment, "EndowmentReceived")
        .withArgs(rewardDistributor.address, amount);

      expect(await wrfToken.balanceOf(endowmentAddress)).to.equal(amount);
      expect(await storageEndowment.getEndowmentBalance()).to.equal(amount);
    });

    it("reverts when paused", async function () {
      const amount = ethers.parseEther("10");
      await storageEndowment.connect(admin).pause();
      await wrfToken.connect(rewardDistributor).approve(await storageEndowment.getAddress(), amount);

      await expect(storageEndowment.connect(rewardDistributor).receiveBlockReward(amount)).to.be.revertedWithCustomError(
        storageEndowment,
        "EnforcedPause"
      );
    });

    it("reverts for zero amount", async function () {
      await expect(storageEndowment.connect(rewardDistributor).receiveBlockReward(0)).to.be.revertedWith(
        "Amount must be > 0"
      );
    });
  });

  describe("endowmentRateBps", function () {
    it("sets constructor default rate to 50 bps", async function () {
      expect(await storageEndowment.endowmentRateBps()).to.equal(50);
    });

    it("setEndowmentRateBps(100) updates rate and emits RateUpdated", async function () {
      await expect(storageEndowment.connect(admin).setEndowmentRateBps(100))
        .to.emit(storageEndowment, "RateUpdated")
        .withArgs(50, 100);

      expect(await storageEndowment.endowmentRateBps()).to.equal(100);
    });

    it("setEndowmentRateBps(1001) reverts", async function () {
      await expect(storageEndowment.connect(admin).setEndowmentRateBps(1001)).to.be.revertedWith(
        "Rate exceeds ceiling"
      );
    });

    it("reverts when non-admin calls setEndowmentRateBps", async function () {
      const ADMIN_ROLE = await storageEndowment.ADMIN_ROLE();

      await expect(storageEndowment.connect(user).setEndowmentRateBps(100))
        .to.be.revertedWithCustomError(storageEndowment, "AccessControlUnauthorizedAccount")
        .withArgs(user.address, ADMIN_ROLE);
    });
  });

  describe("getEndowmentBalance", function () {
    it("returns 0 before any deposit", async function () {
      expect(await storageEndowment.getEndowmentBalance()).to.equal(0);
    });

    it("matches wrfToken.balanceOf after deposits", async function () {
      const firstDeposit = ethers.parseEther("40");
      const secondDeposit = ethers.parseEther("60");
      const endowmentAddress = await storageEndowment.getAddress();

      await wrfToken.connect(owner).approve(endowmentAddress, firstDeposit + secondDeposit);
      await storageEndowment.connect(owner).depositEndowment(firstDeposit);
      await storageEndowment.connect(owner).depositEndowment(secondDeposit);

      const tokenBalance = await wrfToken.balanceOf(endowmentAddress);
      expect(await storageEndowment.getEndowmentBalance()).to.equal(tokenBalance);
    });
  });

  describe("Admin Functions", function () {
    it("allows admin to update max daily claim", async function () {
      const newMax = ethers.parseEther("200");
      await expect(storageEndowment.connect(admin).setMaxClaimAmountPerDay(newMax))
        .to.emit(storageEndowment, "MaxClaimUpdated")
        .withArgs(MAX_CLAIM_AMOUNT, newMax);

      expect(await storageEndowment.maxClaimAmountPerDay()).to.equal(newMax);
    });
  });
});
