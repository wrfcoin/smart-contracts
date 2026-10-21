const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

const WBTC_PRICE_18 = 60_000n * 10n ** 18n;
const WBTC_PRICE_8 = 60_000n * 10n ** 8n;

function stationId(label) {
  return ethers.id(label);
}

describe('BTCStakeRegistry — focused coverage for high blast-radius guards', function () {
  async function deployFixture() {
    const [admin, user, other] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const wbtc = await MockERC20.deploy('Wrapped Bitcoin', 'WBTC', 18);
    await wbtc.waitForDeployment();

    const MockAggregatorV3 = await ethers.getContractFactory('MockAggregatorV3');
    const wbtcFeed = await MockAggregatorV3.deploy(8, 'wbtc');
    const usdFeed = await MockAggregatorV3.deploy(8, 'usd');
    await wbtcFeed.waitForDeployment();
    await usdFeed.waitForDeployment();

    const TestMultiAssetStaking = await ethers.getContractFactory('TestMultiAssetStaking');
    const staking = await TestMultiAssetStaking.deploy();
    await staking.waitForDeployment();

    const BTCStakeRegistry = await ethers.getContractFactory('BTCStakeRegistry');
    const registry = await BTCStakeRegistry.deploy(
      await wbtc.getAddress(),
      await wbtcFeed.getAddress(),
      await usdFeed.getAddress(),
      await staking.getAddress(),
      await admin.getAddress()
    );
    await registry.waitForDeployment();

    await wbtc.mint(await user.getAddress(), ethers.parseEther('200'));
    await wbtc.mint(await admin.getAddress(), ethers.parseEther('200'));

    await wbtcFeed.setPrice(WBTC_PRICE_8);
    await usdFeed.setPrice(1_000_000_000n); // unused safety value, but valid and fresh

    return { admin, user, other, wbtc, wbtcFeed, usdFeed, staking, registry };
  }

  it('rejects station registration with collateral ratio outside configured range', async function () {
    const { user, registry, wbtc } = await loadFixture(deployFixture);
    const station = stationId('station-low-ratio');
    await wbtc.connect(user).approve(await registry.getAddress(), ethers.parseEther('1'));

    await expect(
      registry.connect(user).registerWeatherStation(station, ethers.parseEther('1'), WBTC_PRICE_18)
    ).to.be.revertedWith('Invalid collateral ratio');
  });

  it('reverts registration when oracle data is stale', async function () {
    const { user, registry, wbtcFeed, wbtc } = await loadFixture(deployFixture);
    const station = stationId('station-stale');
    await wbtc.connect(user).approve(await registry.getAddress(), ethers.parseEther('1'));

    await wbtcFeed.simulateStaleData();

    await expect(
      registry
        .connect(user)
        .registerWeatherStation(station, ethers.parseEther('1'), ethers.parseEther('100'))
    ).to.be.revertedWith('WBTC price too stale');
  });

  it('registers a valid station and persists activation state', async function () {
    const { admin, user, registry, wbtc } = await loadFixture(deployFixture);
    const station = stationId('station-valid');
    await wbtc.connect(user).approve(await registry.getAddress(), ethers.parseEther('2'));

    await expect(
      registry.connect(user).registerWeatherStation(station, ethers.parseEther('2'), 40_000n * 10n ** 18n)
    ).to.emit(registry, 'StationRegistered');

    const record = await registry.getWeatherStation(station);
    expect(record.owner).to.equal(await user.getAddress());
    expect(record.wbtcCollateral).to.equal(ethers.parseEther('2'));
    expect(record.isActive).to.equal(true);
    expect(await registry.emergencyPaused(station)).to.equal(false);

    const userStations = await registry.getUserStations(await user.getAddress());
    expect(userStations).to.deep.equal([station]);
  });

  it('blocks collateral withdrawals that would violate minimum collateral ratio', async function () {
    const { user, registry, wbtc } = await loadFixture(deployFixture);
    const station = stationId('station-withdraw-guard');
    await wbtc.connect(user).approve(await registry.getAddress(), ethers.parseEther('2'));

    await registry.connect(user).registerWeatherStation(
      station,
      ethers.parseEther('2'),
      40_000n * 10n ** 18n
    );

    await expect(
      registry.connect(user).withdrawCollateral(station, ethers.parseEther('1.5'))
    ).to.be.revertedWith('Would violate min collateral ratio');
  });

  it('rejects unsupported bridge operations before any cross-chain call path', async function () {
    const { user, registry, wbtc, other } = await loadFixture(deployFixture);
    await wbtc.connect(user).approve(await registry.getAddress(), ethers.parseEther('1'));

    await expect(
      registry.connect(user).initiateBridgeOperation(
        await other.getAddress(),
        ethers.parseEther('1'),
        1,
        await other.getAddress()
      )
    ).to.be.revertedWith('Unsupported bridge');
  });

  it('keeps confirmBridgeOperation behind BRIDGE_OPERATOR_ROLE', async function () {
    const { other, registry } = await loadFixture(deployFixture);

    await expect(
      registry.connect(other).confirmBridgeOperation(1, ethers.encodeBytes32String('tx'))
    ).to.be.revertedWithCustomError(registry, 'AccessControlUnauthorizedAccount');
  });

  it('requires emergency role for supported-bridge management', async function () {
    const { other, registry } = await loadFixture(deployFixture);
    await expect(
      registry.connect(other).addSupportedBridge(other.address)
    ).to.be.revertedWithCustomError(registry, 'AccessControlUnauthorizedAccount');
  });

  it('requires configured emergency delay before emergency withdrawals', async function () {
    const { admin, user, registry, wbtc } = await loadFixture(deployFixture);
    const station = stationId('station-emergency-delay');
    await wbtc.connect(user).approve(await registry.getAddress(), ethers.parseEther('2'));

    await registry.connect(user).registerWeatherStation(
      station,
      ethers.parseEther('2'),
      40_000n * 10n ** 18n
    );

    await registry.connect(admin).activateEmergencyShutdown();
    await expect(
      registry.connect(user).emergencyWithdraw(station)
    ).to.be.revertedWith('Emergency delay not met');

    await time.increase(48 * 60 * 60 + 1);
    await expect(registry.connect(user).emergencyWithdraw(station)).to.not.be.reverted;
  });
});
