const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

function validStakeParams() {
  return {
    participationType: 0,
    geographicZone: 0,
    verificationLevel: 1,
    social: {
      githubVerified: false,
      twitterVerified: false,
      linkedinVerified: false,
    },
    density: {
      nearbyStationsCount: 5,
      isDensityVerified: false,
    },
    hybridServices: {
      providesWeatherData: false,
      providesForecasting: false,
      providesDataStorage: false,
      providesValidation: false,
    },
  };
}

describe('FairLaunchStakeManager — focused guards and controls', function () {
  async function deployFixture() {
    const [owner, user, other] = await ethers.getSigners();

    const Token = await ethers.getContractFactory('MockERC20');
    const token = await Token.deploy('Stake Test', 'TST', 18);
    await token.waitForDeployment();

    const FairLaunchStakeManager = await ethers.getContractFactory('FairLaunchStakeManager');
    const manager = await FairLaunchStakeManager.deploy(
      owner.address,
      owner.address
    );
    await manager.waitForDeployment();

    // Keep a deterministic $1-like oracle price in calculator precision.
    await manager
      .connect(owner)
      .setSupportedAsset(await token.getAddress(), 18, ethers.parseEther('1'), ethers.parseEther('1000000'), 'TST');
    await manager
      .connect(owner)
      .setOraclePrice(await token.getAddress(), 1_000_000n, owner.address);

    await token.mint(user.address, ethers.parseEther('1000000'));

    return { owner, user, other, token, manager };
  }

  it('rejects deposits to unsupported assets (asset allowlist guard)', async function () {
    const { user, manager, token } = await loadFixture(deployFixture);
    const params = validStakeParams();

    // Remove support first so the guard has a clear failure target.
    await manager.removeSupportedAsset(await token.getAddress());

    await expect(
      manager.connect(user).depositStake(await token.getAddress(), ethers.parseEther('1'), params)
    ).to.be.revertedWithCustomError(manager, 'AssetNotSupported');
  });

  it('rejects deposits with stale oracle price (timeliness guard)', async function () {
    const { owner, user, token, manager } = await loadFixture(deployFixture);
    const params = validStakeParams();

    // Use a dedicated oracle freshness window check (older than 1 hour).
    await time.increase(3600 + 1);

    await token.connect(user).approve(await manager.getAddress(), ethers.parseEther('1'));
    await expect(
      manager.connect(user).depositStake(await token.getAddress(), ethers.parseEther('1'), params)
    ).to.be.revertedWithCustomError(manager, 'StaleOraclePrice');
  });

  it('rejects deposits below calculated requirement (economic guard)', async function () {
    const { user, token, manager } = await loadFixture(deployFixture);
    const params = validStakeParams();
    const [requiredStake] = await manager.calculateRequiredStake(params);

    // For this contract's staking check, this guard is exercised directly
    // against the deposited raw amount, so subtract one from the required value.
    const shortfall = requiredStake - 1n;

    await token.connect(user).approve(await manager.getAddress(), shortfall);

    await expect(
      manager.connect(user).depositStake(await token.getAddress(), shortfall, params)
    ).to.be.revertedWithCustomError(manager, 'InsufficientStakeAmount');
  });

  it('allows a valid stake deposit and records requirement satisfaction', async function () {
    const { user, token, manager } = await loadFixture(deployFixture);
    const params = validStakeParams();
    const [requiredStake] = await manager.calculateRequiredStake(params);

    // The current contract compares stake size against `finalStakeUSD` using the
    // raw deposit amount value directly (fixed-point USD scaling), so use that
    // required amount verbatim here.
    const requiredAmount = requiredStake;
    await token.connect(user).approve(await manager.getAddress(), requiredAmount);

    await expect(manager.connect(user).depositStake(await token.getAddress(), requiredAmount, params)).to.emit(
      manager,
      'StakeDeposited'
    );

    const info = await manager.getStakeInfo(user.address);
    expect(info[0]).to.equal(requiredAmount);
    expect(info[2]).to.equal(true);
  });

  it('restricts stake slashing to emergency multisig (access-control guard)', async function () {
    const { other, user, token, manager } = await loadFixture(deployFixture);
    const params = validStakeParams();
    const [requiredStake] = await manager.calculateRequiredStake(params);
    const amount = requiredStake;

    await token.connect(user).approve(await manager.getAddress(), amount);
    await manager.connect(user).depositStake(await token.getAddress(), amount, params);

    await expect(
      manager.connect(other).slashStake(user.address, await token.getAddress(), 'invalid')
    ).to.be.revertedWithCustomError(manager, 'UnauthorizedSlashing');
  });

  it('guards withdrawals to inactive/missing stakes (state-machine guard)', async function () {
    const { user, token, manager } = await loadFixture(deployFixture);
    const params = validStakeParams();
    const [requiredStake] = await manager.calculateRequiredStake(params);
    const amount = requiredStake;

    await token.connect(user).approve(await manager.getAddress(), amount);
    await manager.connect(user).depositStake(await token.getAddress(), amount, params);

    await expect(
      manager.connect(user).withdrawStake(await token.getAddress(), 0)
    ).to.not.be.reverted;

    await expect(
      manager.connect(user).withdrawStake(await token.getAddress(), 0)
    ).to.be.revertedWithCustomError(manager, 'StakeNotFound');
  });
});
