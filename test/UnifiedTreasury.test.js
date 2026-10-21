'use strict';
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('UnifiedTreasury (#135)', function () {
  const BUCKET = ethers.keccak256(ethers.toUtf8Bytes('cloud-compute'));
  async function fixture() {
    const [gov, executor, recipient, outsider] = await ethers.getSigners();
    const Treasury = await ethers.getContractFactory('UnifiedTreasury');
    const treasury = await Treasury.deploy(gov.address);
    await treasury.waitForDeployment();
    await treasury.connect(gov).grantRole(await treasury.ALLOCATION_EXECUTOR_ROLE(), executor.address);
    await treasury.connect(gov).configureBucket(BUCKET, ethers.ZeroAddress, recipient.address, ethers.parseEther('1'), 3600, true);
    return { treasury, gov, executor, recipient, outsider };
  }
  it('routes a bounded native allocation to its configured recipient', async function () {
    const { treasury, executor, recipient } = await fixture();
    await treasury.depositNative(ethers.ZeroHash, { value: ethers.parseEther('2') });
    await expect(treasury.connect(executor).executeAllocation(BUCKET, ethers.parseEther('1')))
      .to.changeEtherBalance(recipient, ethers.parseEther('1'));
  });
  it('mutation: remove executor guard reverts for an unauthorized allocator', async function () {
    const { treasury, outsider } = await fixture();
    await expect(treasury.connect(outsider).executeAllocation(BUCKET, 1))
      .to.be.revertedWithCustomError(treasury, 'AccessControlUnauthorizedAccount');
  });
  it('mutation: omit bucket-limit guard reverts on overspend', async function () {
    const { treasury, executor } = await fixture();
    await treasury.depositNative(ethers.ZeroHash, { value: ethers.parseEther('3') });
    await expect(treasury.connect(executor).executeAllocation(BUCKET, ethers.parseEther('2')))
      .to.be.revertedWith('UnifiedTreasury: bucket limit exceeded');
  });
  it('resets the configured budget only after the period', async function () {
    const { treasury, executor } = await fixture();
    await treasury.depositNative(ethers.ZeroHash, { value: ethers.parseEther('2') });
    await treasury.connect(executor).executeAllocation(BUCKET, ethers.parseEther('1'));
    await expect(treasury.connect(executor).executeAllocation(BUCKET, 1))
      .to.be.revertedWith('UnifiedTreasury: bucket limit exceeded');
    await time.increase(3600);
    await expect(treasury.connect(executor).executeAllocation(BUCKET, ethers.parseEther('1'))).to.not.be.reverted;
  });

  it('keeps configureBucket from introducing spend desync', async function () {
    const { treasury, gov, executor, recipient } = await fixture();
    const bucketId = ethers.keccak256(ethers.toUtf8Bytes('cloud-compute-desync'));
    await treasury.connect(gov).configureBucket(bucketId, ethers.ZeroAddress, recipient.address, 100, 3600, true);
    await treasury.depositNative(ethers.ZeroHash, { value: 200n * 1000n });

    await treasury.connect(executor).executeAllocation(bucketId, 100);
    await treasury.connect(gov).configureBucket(bucketId, ethers.ZeroAddress, recipient.address, 100, 3600, true);
    await time.increase(151);
    await treasury.connect(executor).executeAllocation(bucketId, 100);

    await time.increase(3449);
    await expect(treasury.connect(executor).executeAllocation(bucketId, 1))
      .to.be.revertedWith('UnifiedTreasury: bucket limit exceeded');
  });

  it('enforces stable gas on the rolling window accrual path', async function () {
    const { treasury, gov, executor, recipient } = await fixture();
    const bucketId = ethers.keccak256(ethers.toUtf8Bytes('cloud-compute-gas'));
    await treasury.connect(gov).configureBucket(
      bucketId,
      ethers.ZeroAddress,
      recipient.address,
      ethers.parseEther('1'),
      86400,
      true,
    );
    await treasury.depositNative(ethers.ZeroHash, { value: ethers.parseEther('2') });

    const tx = await treasury.connect(executor).executeAllocation(bucketId, ethers.parseEther('1'));
    const receipt = await tx.wait();
    expect(receipt.gasUsed).to.be.lessThan(250000n);
  });
});
