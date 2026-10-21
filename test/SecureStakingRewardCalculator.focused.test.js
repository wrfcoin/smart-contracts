'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('SecureStakingRewardCalculator — focused coverage', function () {
  async function deployFixture() {
    const [admin, calculator, outsider] = await ethers.getSigners();

    const MockQualityOracle = await ethers.getContractFactory('MockQualityOracleConcrete');
    const qualityOracle = await MockQualityOracle.deploy();

    const Calculator = await ethers.getContractFactory('SecureStakingRewardCalculator');
    const calculatorContract = await Calculator.deploy(await qualityOracle.getAddress());

    const CALCULATOR_ROLE = await calculatorContract.CALCULATOR_ROLE();
    const STAKING_MANAGER_ROLE = await calculatorContract.STAKING_MANAGER_ROLE();
    const ORACLE_MANAGER_ROLE = await calculatorContract.ORACLE_MANAGER_ROLE();
    const EMERGENCY_ROLE = await calculatorContract.EMERGENCY_ROLE();
    const validParams = {
      stakedAmount: 10n ** 18n,
      baseRewardRate: 100n,
      stakeDuration: 24n * 60n * 60n,
      qualityMultiplier: 10n ** 18n,
      vintageBonus: 100n,
      sustainabilityBonus: 100n,
      globalMultiplier: 10n ** 18n,
      minStakeDuration: 1n * 60n * 60n,
      maxStakeDuration: 90n * 24n * 60n * 60n,
    };

    return {
      admin,
      calculator,
      outsider,
      qualityOracle,
      calculatorContract,
      CALCULATOR_ROLE,
      STAKING_MANAGER_ROLE,
      ORACLE_MANAGER_ROLE,
      EMERGENCY_ROLE,
      validParams,
    };
  }

  it('requires non-zero oracle and seeds bootstrap roles', async function () {
    const { admin } = await loadFixture(deployFixture);
    const Calculator = await ethers.getContractFactory('SecureStakingRewardCalculator');

    await expect(
      Calculator.deploy(ethers.ZeroAddress)
    ).to.be.revertedWith('SecureStakingRewardCalculator: Invalid oracle address');

    const MockQualityOracle = await ethers.getContractFactory('MockQualityOracleConcrete');
    const qualityOracle = await MockQualityOracle.deploy();
    const calculatorContract = await Calculator.deploy(await qualityOracle.getAddress());

    expect(await calculatorContract.hasRole(await calculatorContract.DEFAULT_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await calculatorContract.hasRole(await calculatorContract.CALCULATOR_ROLE(), admin.address)).to.equal(true);
    expect(await calculatorContract.hasRole(await calculatorContract.STAKING_MANAGER_ROLE(), admin.address)).to.equal(true);
    expect(await calculatorContract.hasRole(await calculatorContract.ORACLE_MANAGER_ROLE(), admin.address)).to.equal(true);
    expect(await calculatorContract.hasRole(await calculatorContract.EMERGENCY_ROLE(), admin.address)).to.equal(true);
  });

  it('gates reward calculation behind authorized calculator access', async function () {
    const { admin, calculator, calculatorContract, validParams } = await loadFixture(deployFixture);

    await expect(
      calculatorContract.connect(calculator).calculateStakingRewards(validParams)
    ).to.be.revertedWith('SecureStakingRewardCalculator: Not authorized calculator');

    await calculatorContract.connect(admin).grantRole(await calculatorContract.CALCULATOR_ROLE(), calculator.address);
    const result = await calculatorContract.connect(calculator).calculateStakingRewards(validParams);
    expect(result.totalReward).to.be.gt(0n);

    await expect(
      calculatorContract.connect(calculator).calculateStakingRewards({
        ...validParams,
        stakedAmount: 0n,
      })
    ).to.be.revertedWith('SecureStakingRewardCalculator: Invalid staked amount');
  });

  it('restricts authorized-calculator registry to staking manager role', async function () {
    const { outsider, admin, calculatorContract, STAKING_MANAGER_ROLE } = await loadFixture(deployFixture);

    // onlyRole(STAKING_MANAGER_ROLE) — SecureStakingRewardCalculator.sol:771.
    // outsider.address is non-zero, so the function's own
    // `require(calculator != address(0))` (:772) would pass: deleting the role
    // modifier lets this call succeed rather than revert for another reason,
    // which is what keeps this assertion able to fail.
    await expect(
      calculatorContract.connect(outsider).setAuthorizedCalculator(outsider.address, true)
    )
      .to.be.revertedWithCustomError(calculatorContract, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, STAKING_MANAGER_ROLE);

    await expect(
      calculatorContract.connect(admin).setAuthorizedCalculator(outsider.address, true)
    ).to.not.be.reverted;

    expect(await calculatorContract.authorizedCalculators(outsider.address)).to.equal(true);

    await expect(
      calculatorContract.connect(admin).setAuthorizedCalculator(ethers.ZeroAddress, true)
    ).to.be.revertedWith('SecureStakingRewardCalculator: Invalid calculator address');
  });

  it('restricts oracle updates to oracle managers and rejects invalid oracle', async function () {
    const { admin, outsider, calculatorContract, ORACLE_MANAGER_ROLE } = await loadFixture(deployFixture);
    const MockQualityOracle = await ethers.getContractFactory('MockQualityOracleConcrete');
    const oracle2 = await MockQualityOracle.deploy();

    // onlyRole(ORACLE_MANAGER_ROLE) — SecureStakingRewardCalculator.sol:779. A
    // DIFFERENT role from the staking-manager gate in the test above, which an
    // unpinned assertion could not have distinguished. oracle2 is a deployed
    // non-zero address, so the :780 zero-address require would pass.
    await expect(
      calculatorContract.connect(outsider).setQualityOracle(await oracle2.getAddress())
    )
      .to.be.revertedWithCustomError(calculatorContract, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, ORACLE_MANAGER_ROLE);

    await calculatorContract.connect(admin).setQualityOracle(await oracle2.getAddress());
    expect(await calculatorContract.qualityOracle()).to.equal(await oracle2.getAddress());

    await expect(
      calculatorContract.connect(admin).setQualityOracle(ethers.ZeroAddress)
    ).to.be.revertedWith('SecureStakingRewardCalculator: Invalid oracle address');

    const hasOracleManager = await calculatorContract.hasRole(ORACLE_MANAGER_ROLE, admin.address);
    expect(hasOracleManager).to.equal(true);
  });

  it('binds emergency pause controls to emergency role and calculation gating', async function () {
    const { admin, outsider, calculatorContract, validParams, EMERGENCY_ROLE } = await loadFixture(deployFixture);

    // All three unauthorized calls in this test are onlyRole(EMERGENCY_ROLE):
    // pauseCalculations :834, pause :848, unpause :852. Each body is a bare
    // state write, so deleting the role modifier makes the call succeed —
    // these assertions can genuinely fail.
    await expect(
      calculatorContract.connect(outsider).pauseCalculations()
    )
      .to.be.revertedWithCustomError(calculatorContract, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, EMERGENCY_ROLE);

    await expect(
      calculatorContract.connect(admin).pauseCalculations()
    ).to.not.be.reverted;

    await expect(
      calculatorContract.connect(admin).calculateStakingRewards(validParams)
    ).to.be.revertedWith('SecureStakingRewardCalculator: Calculations paused');

    await calculatorContract.connect(admin).resumeCalculations();
    const result = await calculatorContract.connect(admin).calculateStakingRewards(validParams);
    expect(result.baseReward).to.be.gt(0n);

    await expect(
      calculatorContract.connect(outsider).pause()
    )
      .to.be.revertedWithCustomError(calculatorContract, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, EMERGENCY_ROLE);

    await expect(
      calculatorContract.connect(admin).pause()
    ).to.not.be.reverted;
    expect(await calculatorContract.paused()).to.equal(true);

    // The contract IS paused at this point (asserted directly above), so
    // unpause's own precondition is satisfied and the role gate is the only
    // thing that can reject this call.
    await expect(
      calculatorContract.connect(outsider).unpause()
    )
      .to.be.revertedWithCustomError(calculatorContract, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, EMERGENCY_ROLE);
  });
});
