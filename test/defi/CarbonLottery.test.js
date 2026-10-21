'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonLottery', function () {
  const EPOCH = 7 * 24 * 60 * 60;
  const DONATION_BPS = 1000;

  async function deployFixture() {
    const [owner, treasury, alice, bob, carol] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const token = await MockERC20.deploy('WRF', 'WRF', 18);

    const MockYieldSource = await ethers.getContractFactory('MockYieldSource');
    const yieldSource = await MockYieldSource.deploy(await token.getAddress());

    const CarbonLottery = await ethers.getContractFactory('CarbonLottery');
    const lottery = await CarbonLottery.deploy(
      owner.address,
      await token.getAddress(),
      await yieldSource.getAddress(),
      treasury.address,
      EPOCH,
      DONATION_BPS
    );

    const initialMint = ethers.parseEther('1000');
    for (const signer of [owner, alice, bob, carol]) {
      await token.mint(signer.address, initialMint);
      await token.connect(signer).approve(await lottery.getAddress(), initialMint);
      await token.connect(signer).approve(await yieldSource.getAddress(), initialMint);
    }

    return { owner, treasury, alice, bob, carol, token, yieldSource, lottery };
  }

  it('deposit increments balance', async function () {
    const { alice, lottery } = await loadFixture(deployFixture);

    const amount = ethers.parseEther('25');
    await expect(lottery.connect(alice).deposit(amount)).to.emit(lottery, 'Deposited');

    expect(await lottery.deposits(alice.address)).to.equal(amount);
    expect(await lottery.totalDeposited()).to.equal(amount);
  });

  it('cannot draw before epoch ends', async function () {
    const { alice, lottery } = await loadFixture(deployFixture);

    await lottery.connect(alice).deposit(ethers.parseEther('10'));

    await expect(lottery.drawWinner()).to.be.revertedWithCustomError(
      lottery,
      'LotteryEpochNotEnded'
    );
  });

  it('winner receives yield and treasury receives carbon donation', async function () {
    const { owner, treasury, alice, token, yieldSource, lottery } = await loadFixture(deployFixture);

    await lottery.connect(alice).deposit(ethers.parseEther('100'));

    const yieldAmount = ethers.parseEther('10');
    await yieldSource.connect(owner).addYield(yieldAmount, await lottery.getAddress());

    await time.increase(EPOCH + 1);

    const treasuryBefore = await token.balanceOf(treasury.address);
    const winnerBefore = await token.balanceOf(alice.address);

    await expect(lottery.drawWinner())
      .to.emit(lottery, 'WinnerDrawn')
      .withArgs(alice.address, ethers.parseEther('9'), 1);

    expect(await token.balanceOf(treasury.address)).to.equal(treasuryBefore + ethers.parseEther('1'));
    expect(await token.balanceOf(alice.address)).to.equal(winnerBefore + ethers.parseEther('9'));
  });

  it('withdraw returns principal', async function () {
    const { alice, token, lottery } = await loadFixture(deployFixture);

    const depositAmount = ethers.parseEther('40');
    const withdrawAmount = ethers.parseEther('15');

    await lottery.connect(alice).deposit(depositAmount);

    const before = await token.balanceOf(alice.address);
    await expect(lottery.connect(alice).withdraw(withdrawAmount)).to.emit(lottery, 'Withdrawn');

    const after = await token.balanceOf(alice.address);
    expect(after - before).to.equal(withdrawAmount);
    expect(await lottery.deposits(alice.address)).to.equal(depositAmount - withdrawAmount);
  });

  it('multiple depositors: winner is deterministic given mocked blockhash inputs', async function () {
    const { owner, alice, bob, carol, token, yieldSource, lottery } = await loadFixture(deployFixture);

    await lottery.connect(alice).deposit(ethers.parseEther('100'));
    await lottery.connect(bob).deposit(ethers.parseEther('100'));
    await lottery.connect(carol).deposit(ethers.parseEther('100'));

    await yieldSource.connect(owner).addYield(ethers.parseEther('15'), await lottery.getAddress());

    const latest = await time.latest();
    const drawTimestamp = latest + EPOCH + 10;
    const mockedRandao =
      '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';

    await ethers.provider.send('hardhat_setPrevRandao', [mockedRandao]);
    await ethers.provider.send('evm_setNextBlockTimestamp', [drawTimestamp]);

    const tx = await lottery.drawWinner();
    const receipt = await tx.wait();
    const block = await ethers.provider.getBlock(receipt.blockNumber);

    const depositorCount = await lottery.depositorCount();
    const hash = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'uint256'],
      [BigInt(mockedRandao), BigInt(block.timestamp), depositorCount]
    );
    const expectedIndex = BigInt(hash) % depositorCount;

    const expectedWinner = [alice.address, bob.address, carol.address][Number(expectedIndex)];

    const winnerEvent = receipt.logs
      .map((log) => {
        try {
          return lottery.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((event) => event && event.name === 'WinnerDrawn');

    expect(winnerEvent.args.winner).to.equal(expectedWinner);
  });

  it('constructor validates addresses, bps, and defaults', async function () {
    const [owner, treasury] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const token = await MockERC20.deploy('WRF', 'WRF', 18);
    const wrongToken = await MockERC20.deploy('ALT', 'ALT', 18);
    const MockYieldSource = await ethers.getContractFactory('MockYieldSource');
    const yieldSource = await MockYieldSource.deploy(await token.getAddress());
    const mismatchedSource = await MockYieldSource.deploy(await wrongToken.getAddress());
    const CarbonLottery = await ethers.getContractFactory('CarbonLottery');

    await expect(
      CarbonLottery.deploy(
        ethers.ZeroAddress,
        await token.getAddress(),
        await yieldSource.getAddress(),
        treasury.address,
        EPOCH,
        DONATION_BPS
      )
    ).to.be.revertedWithCustomError(CarbonLottery, 'OwnableInvalidOwner');

    await expect(
      CarbonLottery.deploy(
        owner.address,
        await token.getAddress(),
        await yieldSource.getAddress(),
        ethers.ZeroAddress,
        EPOCH,
        DONATION_BPS
      )
    ).to.be.revertedWithCustomError(CarbonLottery, 'LotteryInvalidAddress');

    await expect(
      CarbonLottery.deploy(
        owner.address,
        await token.getAddress(),
        await yieldSource.getAddress(),
        treasury.address,
        EPOCH,
        10001
      )
    ).to.be.revertedWithCustomError(CarbonLottery, 'LotteryInvalidBps');

    await expect(
      CarbonLottery.deploy(
        owner.address,
        await token.getAddress(),
        await mismatchedSource.getAddress(),
        treasury.address,
        EPOCH,
        DONATION_BPS
      )
    ).to.be.revertedWithCustomError(CarbonLottery, 'LotteryInvalidAddress');

    const lottery = await CarbonLottery.deploy(
      owner.address,
      await token.getAddress(),
      await yieldSource.getAddress(),
      treasury.address,
      0,
      0
    );
    expect(await lottery.epochDuration()).to.equal(7n * 24n * 60n * 60n);
    expect(await lottery.carbonDonationBps()).to.equal(1000n);
  });

  it('reverts on zero and insufficient amounts', async function () {
    const { alice, lottery } = await loadFixture(deployFixture);

    await expect(lottery.connect(alice).deposit(0)).to.be.revertedWithCustomError(
      lottery,
      'LotteryZeroAmount'
    );
    await expect(lottery.connect(alice).withdraw(0)).to.be.revertedWithCustomError(
      lottery,
      'LotteryZeroAmount'
    );
    await expect(lottery.connect(alice).withdraw(1)).to.be.revertedWithCustomError(
      lottery,
      'LotteryInsufficientDeposit'
    );
  });

  it('reverts draw with no depositors after epoch and supports zero-yield draw', async function () {
    const { alice, lottery } = await loadFixture(deployFixture);

    await time.increase(EPOCH + 1);
    await expect(lottery.drawWinner()).to.be.revertedWithCustomError(lottery, 'LotteryNoDepositors');

    await lottery.connect(alice).deposit(ethers.parseEther('20'));
    await time.increase(EPOCH + 1);
    await expect(lottery.drawWinner()).to.emit(lottery, 'WinnerDrawn').withArgs(alice.address, 0, 1);
  });

  it('owner controls pause/unpause and setters', async function () {
    const { owner, treasury, alice, bob, lottery } = await loadFixture(deployFixture);

    await expect(lottery.connect(alice).pause()).to.be.revertedWithCustomError(
      lottery,
      'OwnableUnauthorizedAccount'
    );

    await lottery.connect(owner).pause();
    await expect(lottery.connect(alice).deposit(ethers.parseEther('1'))).to.be.revertedWithCustomError(
      lottery,
      'EnforcedPause'
    );
    await expect(lottery.drawWinner()).to.be.revertedWithCustomError(lottery, 'EnforcedPause');

    await lottery.connect(owner).unpause();
    await lottery.connect(alice).deposit(ethers.parseEther('1'));

    await expect(
      lottery.connect(owner).setCarbonOffsetTreasury(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(lottery, 'LotteryInvalidAddress');
    await expect(lottery.connect(owner).setCarbonOffsetTreasury(bob.address))
      .to.emit(lottery, 'CarbonTreasuryUpdated')
      .withArgs(treasury.address, bob.address);

    await expect(lottery.connect(owner).setEpochDuration(0)).to.be.revertedWithCustomError(
      lottery,
      'LotteryZeroAmount'
    );
    await expect(lottery.connect(owner).setEpochDuration(3600))
      .to.emit(lottery, 'EpochDurationUpdated')
      .withArgs(EPOCH, 3600);

    await expect(lottery.connect(owner).setCarbonDonationBps(10001)).to.be.revertedWithCustomError(
      lottery,
      'LotteryInvalidBps'
    );
    await expect(lottery.connect(owner).setCarbonDonationBps(500))
      .to.emit(lottery, 'CarbonDonationBpsUpdated')
      .withArgs(DONATION_BPS, 500);
  });
});
