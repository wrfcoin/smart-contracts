'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('Weighted fee units', function () {
  it('applies swap fees as basis points', async function () {
    const Harness = await ethers.getContractFactory('WeightedMathHarness');
    const harness = await Harness.deploy();

    const amount = ethers.parseEther('100');

    expect(await harness.applySwapFee(amount, 30)).to.equal(ethers.parseEther('99.7'));
    expect(await harness.applySwapFee(amount, 1000)).to.equal(ethers.parseEther('90'));
  });

  it('rounds input gross-up using the same basis-point denominator', async function () {
    const Harness = await ethers.getContractFactory('WeightedMathHarness');
    const harness = await Harness.deploy();

    const amountAfterFee = ethers.parseEther('99.7');

    expect(await harness.removeSwapFee(amountAfterFee, 30)).to.equal(ethers.parseEther('100'));
  });

  it('rejects fee values outside the weighted pool bps tier range', async function () {
    const Harness = await ethers.getContractFactory('WeightedMathHarness');
    const harness = await Harness.deploy();

    await expect(harness.applySwapFee(ethers.parseEther('1'), 4)).to.be.revertedWithCustomError(
      harness,
      'WeightedMath__InvalidFee'
    );
    await expect(harness.applySwapFee(ethers.parseEther('1'), 1001)).to.be.revertedWithCustomError(
      harness,
      'WeightedMath__InvalidFee'
    );
  });
});
