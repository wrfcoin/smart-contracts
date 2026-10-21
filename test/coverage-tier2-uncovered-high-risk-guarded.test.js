'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('coverage: high-risk uncovered contract guard coverage (tier 2)', function () {
  it('SecureStakingRewardCalculator requires a valid oracle address', async function () {
    const SecureStakingRewardCalculator = await ethers.getContractFactory('SecureStakingRewardCalculator');
    await expect(
      SecureStakingRewardCalculator.deploy(ethers.ZeroAddress)
    ).to.be.revertedWith('SecureStakingRewardCalculator: Invalid oracle address');
  });

  it('ComplianceModule blocks non-officer configuration calls', async function () {
    const [admin, outsider] = await ethers.getSigners();
    const ComplianceModule = await ethers.getContractFactory('ComplianceModule');
    const complianceModule = await ComplianceModule.deploy(await admin.getAddress());
    await expect(
      complianceModule.connect(outsider).setComplianceEnabled(true)
    ).to.be.revertedWithCustomError(complianceModule, 'AccessControlUnauthorizedAccount');
  });

  it('DPoSValidator enforces maximum commission rate', async function () {
    const [owner, validatorOperator] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const stakingToken = await MockERC20.deploy('WRF', 'WRF', 18);
    await stakingToken.mint(await validatorOperator.getAddress(), 20_000n * 10n ** 18n);

    const DPoSValidator = await ethers.getContractFactory('DPoSValidator');
    const dpos = await DPoSValidator.deploy(await stakingToken.getAddress(), 3600);

    await stakingToken.connect(validatorOperator).approve(await dpos.getAddress(), 20_000n * 10n ** 18n);
    await expect(
      dpos.connect(validatorOperator).registerValidator(
        'operator-node',
        'Primary validator endpoint',
        3000,
        10_000n * 10n ** 18n
      )
    ).to.be.revertedWith('DPoS: Commission too high');
  });
});
