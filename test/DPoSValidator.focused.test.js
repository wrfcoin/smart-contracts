const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('DPoSValidator — focused guard tests', function () {
  async function deployFixture() {
    const [owner, outsider, validatorOwner, delegator] = await ethers.getSigners();

    const TestERC20 = await ethers.getContractFactory('TestERC20');
    const stakingToken = await TestERC20.deploy(
      'WRF Stake',
      'WST',
      ethers.parseEther('1000000')
    );

    const DPoSValidator = await ethers.getContractFactory('DPoSValidator');
    const dPoSValidator = await DPoSValidator.deploy(
      await stakingToken.getAddress(),
      24 * 60 * 60
    );

    await stakingToken.transfer(validatorOwner.address, ethers.parseEther('20000'));
    await stakingToken.transfer(delegator.address, ethers.parseEther('1000'));

    return {
      dPoSValidator,
      stakingToken,
      owner,
      outsider,
      validatorOwner,
      delegator,
    };
  }

  it('rejects validator registration below minimum self-stake', async function () {
    const { dPoSValidator, validatorOwner } = await loadFixture(deployFixture);

    await expect(
      dPoSValidator.connect(validatorOwner).registerValidator(
        'Node A',
        'low stake',
        500,
        ethers.parseEther('1')
      )
    ).to.be.revertedWith('DPoS: Insufficient self stake');
  });

  it('rejects validator registration with excess commission', async function () {
    const { dPoSValidator, stakingToken, validatorOwner } = await loadFixture(
      deployFixture
    );

    await stakingToken
      .connect(validatorOwner)
      .approve(
        await dPoSValidator.getAddress(),
        ethers.parseEther('10000')
      );

    await expect(
      dPoSValidator.connect(validatorOwner).registerValidator(
        'Node A',
        'invalid commission',
        2500,
        ethers.parseEther('10000')
      )
    ).to.be.revertedWith('DPoS: Commission too high');
  });

  it('registers a validator only with sufficient stake and records state', async function () {
    const { dPoSValidator, stakingToken, validatorOwner } = await loadFixture(
      deployFixture
    );

    const minValidatorStake = ethers.parseEther('10000');
    await stakingToken
      .connect(validatorOwner)
      .approve(await dPoSValidator.getAddress(), minValidatorStake);

    await expect(
      dPoSValidator
        .connect(validatorOwner)
        .registerValidator('Node A', 'good node', 1000, minValidatorStake)
    ).to.emit(dPoSValidator, 'ValidatorRegistered');

    const stored = await dPoSValidator.validators(validatorOwner.address);
    expect(stored.validatorAddress).to.equal(validatorOwner.address);
    expect(stored.selfStake).to.equal(minValidatorStake);
    expect(stored.status).to.equal(1n); // ValidatorStatus.ACTIVE
    expect(await dPoSValidator.totalStaked()).to.equal(minValidatorStake);
  });

  it('restricts validator pause controls to contract owner', async function () {
    const { dPoSValidator, outsider } = await loadFixture(deployFixture);

    // pause() is onlyOwner — DPoSValidator.sol:751. This contract uses Ownable, not
    // AccessControl, so OpenZeppelin v5 raises OwnableUnauthorizedAccount(account)
    // with a single argument. It is the only Ownable guard in this hardening pass.
    await expect(dPoSValidator.connect(outsider).pause())
      .to.be.revertedWithCustomError(dPoSValidator, 'OwnableUnauthorizedAccount')
      .withArgs(outsider.address);

    await dPoSValidator.pause();
    await expect(dPoSValidator.unpause()).to.not.be.reverted;
  });

  it('rejects delegation with too-short lock period before token transfer path', async function () {
    const { dPoSValidator, stakingToken, validatorOwner, delegator } =
      await loadFixture(deployFixture);

    const minValidatorStake = ethers.parseEther('10000');
    await stakingToken
      .connect(validatorOwner)
      .approve(await dPoSValidator.getAddress(), minValidatorStake);
    await dPoSValidator.connect(validatorOwner).registerValidator(
      'Node A',
      'good node',
      1000,
      minValidatorStake
    );

    const minDelegationAmount = ethers.parseEther('100');
    await stakingToken
      .connect(delegator)
      .approve(await dPoSValidator.getAddress(), minDelegationAmount);

    await expect(
      dPoSValidator
        .connect(delegator)
        .delegate(validatorOwner.address, minDelegationAmount, 1 * 24 * 60 * 60, false)
    ).to.be.revertedWith('DPoS: Lock period too short');
  });
});
