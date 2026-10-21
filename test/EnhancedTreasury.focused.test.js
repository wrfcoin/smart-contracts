'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('EnhancedTreasury — focused guard coverage', function () {
  async function deployFixture() {
    const [admin, manager, allocator, auditor, outsider, signer1, signer2] =
      await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const token = await MockERC20.deploy('Wrapped Mock', 'WMOCK', 18);

    const TimelockController = await ethers.getContractFactory('TimelockController');
    const timelock = await TimelockController.deploy(
      0,
      [admin.address],
      [admin.address],
      admin.address
    );

    const EnhancedTreasury = await ethers.getContractFactory('EnhancedTreasury');
    const treasury = await EnhancedTreasury.deploy(
      admin.address,
      await timelock.getAddress(),
      1000
    );

    return {
      admin,
      manager,
      allocator,
      auditor,
      outsider,
      signer1,
      signer2,
      token,
      timelock,
      treasury,
    };
  }

  it('constructor rejects invalid treasury settings', async function () {
    const { timelock } = await loadFixture(deployFixture);

    const EnhancedTreasury = await ethers.getContractFactory('EnhancedTreasury');
    const [admin] = await ethers.getSigners();
    const timelockAddr = await timelock.getAddress();

    await expect(
      EnhancedTreasury.deploy(ethers.ZeroAddress, timelockAddr, 1000)
    ).to.be.revertedWith('ET: Invalid admin address');

    await expect(
      EnhancedTreasury.deploy(admin.address, ethers.ZeroAddress, 1000)
    ).to.be.revertedWith('ET: Invalid timelock address');

    await expect(
      EnhancedTreasury.deploy(admin.address, timelockAddr, 500)
    ).to.be.revertedWith('ET: Emergency fund too low');
  });

  it('restricts manager-only and allocator-only operations', async function () {
    const { admin, manager, allocator, outsider, treasury, token } =
      await loadFixture(deployFixture);

    // onlyRole(TREASURY_MANAGER_ROLE) validToken(_token) — EnhancedTreasury.sol:421-424.
    // A real deployed token address is passed, so validToken passes.
    await expect(
      treasury.connect(outsider).addTreasuryAsset(await token.getAddress(), 3)
    )
      .to.be.revertedWithCustomError(treasury, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await treasury.TREASURY_MANAGER_ROLE());

    const treasuryManagerRole = await treasury.TREASURY_MANAGER_ROLE();
    await treasury.connect(admin).grantRole(treasuryManagerRole, manager.address);
    await treasury.connect(manager).addTreasuryAsset(await token.getAddress(), 3);

    await token.mint(admin.address, ethers.parseEther('120000'));
    await token.approve(await treasury.getAddress(), ethers.parseEther('120000'));
    await treasury.connect(admin).deposit(await token.getAddress(), ethers.parseEther('120000'));

    const fundAllocatorRole = await treasury.FUND_ALLOCATOR_ROLE();
    await expect(
      treasury
        .connect(outsider)
        .allocateFunds(
          0,
          await token.getAddress(),
          ethers.parseEther('1000'),
          outsider.address,
          'non-allocator',
          ethers.ZeroHash,
          0
        )
    )
      .to.be.revertedWithCustomError(treasury, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await treasury.FUND_ALLOCATOR_ROLE());

    await treasury.connect(admin).grantRole(fundAllocatorRole, allocator.address);
    await expect(
      treasury
        .connect(allocator)
        .allocateFunds(
          0,
          await token.getAddress(),
          ethers.parseEther('60000'),
          outsider.address,
          'oversized fund',
          ethers.ZeroHash,
          0
        )
    ).to.be.revertedWith('ET: Spending limit exceeded');
  });

  it('enforces emergency-role and reason requirements on withdrawals', async function () {
    const { admin, outsider, treasury, token } = await loadFixture(deployFixture);

    await treasury.connect(admin).addTreasuryAsset(await token.getAddress(), 3);
    await token.mint(admin.address, ethers.parseEther('120000'));
    await token.approve(await treasury.getAddress(), ethers.parseEther('120000'));
    await treasury.connect(admin).deposit(await token.getAddress(), ethers.parseEther('120000'));

    // onlyRole(EMERGENCY_ROLE) nonReentrant — EnhancedTreasury.sol:599-604. The
    // deposit on the line above funds the asset, and amount/recipient are both valid,
    // so every body require would pass: deleting the role modifier makes this call
    // succeed. That deposit ordering is load-bearing for this assertion.
    await expect(
      treasury.connect(outsider).emergencyWithdraw(await token.getAddress(), 1n, outsider.address, 'x')
    )
      .to.be.revertedWithCustomError(treasury, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await treasury.EMERGENCY_ROLE());

    await expect(
      treasury.connect(admin).emergencyWithdraw(
        await token.getAddress(),
        ethers.parseEther('1000'),
        outsider.address,
        ''
      )
    ).to.be.revertedWith('ET: Reason required');

    await expect(
      treasury.connect(admin).emergencyWithdraw(
        await token.getAddress(),
        ethers.parseEther('25000'),
        outsider.address,
        'too much'
      )
    ).to.be.revertedWith('ET: Emergency withdrawal too large');
  });

  it('prevents executing queued operations without required approvals', async function () {
    const { admin, treasury, outsider } = await loadFixture(deployFixture);

    const operationHash = await treasury.connect(admin).queueOperation.staticCall(
      outsider.address,
      ethers.parseEther('25000'),
      '0x',
      'high-value manual op'
    );

    await treasury.connect(admin).queueOperation(
      outsider.address,
      ethers.parseEther('25000'),
      '0x',
      'high-value manual op'
    );

    await expect(
      treasury
        .connect(outsider)
        .executeQueuedOperation(
          operationHash,
          outsider.address,
          ethers.parseEther('25000'),
          '0x'
        )
    ).to.be.revertedWith('ET: Insufficient approvals');
  });
});
