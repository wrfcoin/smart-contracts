'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('WeatherDataPaymaster', function () {
  const ONE_DAY = 24 * 60 * 60;
  const stationId = ethers.keccak256(ethers.toUtf8Bytes('station-1'));

  function weatherData(timestamp) {
    return {
      stationId,
      timestamp,
      temperature: 2150,
      humidity: 5000,
      pressure: 101325,
      windSpeed: 850,
      rainfall: 120,
      visibility: 1000,
      uvIndex: 4,
      confidence: 85,
      dataHash: ethers.keccak256(ethers.toUtf8Bytes(`weather-${timestamp}`)),
      qualityScore: 88,
    };
  }

  async function deployFixture() {
    const [owner, contributor, recipient] = await ethers.getSigners();

    const WeatherDataValidator = await ethers.getContractFactory('WeatherDataValidator');
    const validator = await WeatherDataValidator.deploy();

    const WeatherDataPaymaster = await ethers.getContractFactory('WeatherDataPaymaster');
    const paymaster = await WeatherDataPaymaster.deploy(
      owner.address,
      await validator.getAddress(),
      2,
      ethers.parseEther('1')
    );

    await owner.sendTransaction({
      to: await paymaster.getAddress(),
      value: ethers.parseEther('2'),
    });

    const validatorIface = new ethers.Interface([
      'function updateWeatherData(bytes32 stationId, tuple(bytes32 stationId,uint256 timestamp,int256 temperature,uint256 humidity,uint256 pressure,uint256 windSpeed,uint256 rainfall,uint256 visibility,uint256 uvIndex,uint256 confidence,bytes32 dataHash,uint256 qualityScore) data)',
      'function batchUpdateWeatherData(bytes32[] stationIds, tuple(bytes32 stationId,uint256 timestamp,int256 temperature,uint256 humidity,uint256 pressure,uint256 windSpeed,uint256 rainfall,uint256 visibility,uint256 uvIndex,uint256 confidence,bytes32 dataHash,uint256 qualityScore)[] data)',
    ]);

    const accountIface = new ethers.Interface([
      'function execute(address target, uint256 value, bytes data)',
      'function executeBatch(address[] targets, uint256[] values, bytes[] data)',
    ]);

    return { owner, contributor, recipient, validator, paymaster, validatorIface, accountIface };
  }

  function buildUserOp(sender, callData) {
    return {
      sender,
      nonce: 0,
      initCode: '0x',
      callData,
      accountGasLimits: ethers.ZeroHash,
      preVerificationGas: 0,
      gasFees: ethers.ZeroHash,
      paymasterAndData: '0x',
      signature: '0x',
    };
  }

  describe('validatePaymasterUserOp', function () {
    it('sponsors a wrapped weather data submission', async function () {
      const { contributor, validator, paymaster, validatorIface, accountIface } =
        await loadFixture(deployFixture);

      const innerCall = validatorIface.encodeFunctionData('updateWeatherData', [
        stationId,
        weatherData(await time.latest()),
      ]);
      const callData = accountIface.encodeFunctionData('execute', [
        await validator.getAddress(),
        0,
        innerCall,
      ]);

      const userOp = buildUserOp(contributor.address, callData);

      await expect(paymaster.validatePaymasterUserOp(userOp, ethers.ZeroHash, 1))
        .to.emit(paymaster, 'SponsorshipValidated')
        .withArgs(
          contributor.address,
          await validator.getAddress(),
          validatorIface.getFunction('updateWeatherData').selector,
          1,
          await time.latest().then((ts) => BigInt(Math.floor(ts / ONE_DAY) * ONE_DAY))
        );
    });

    it('rejects non-weather transactions', async function () {
      const { contributor, validator, paymaster, accountIface } = await loadFixture(deployFixture);

      const badCall = accountIface.encodeFunctionData('execute', [
        await validator.getAddress(),
        0,
        '0x12345678',
      ]);

      await expect(
        paymaster.validatePaymasterUserOp(
          buildUserOp(contributor.address, badCall),
          ethers.ZeroHash,
          1
        )
      ).to.be.revertedWithCustomError(paymaster, 'WeatherDataPaymasterUnsupportedCall');
    });

    it('rejects calls to non-sponsored targets', async function () {
      const { contributor, paymaster, validatorIface, accountIface } = await loadFixture(
        deployFixture
      );

      const otherTarget = ethers.Wallet.createRandom().address;
      const innerCall = validatorIface.encodeFunctionData('updateWeatherData', [
        stationId,
        weatherData(await time.latest()),
      ]);
      const badCall = accountIface.encodeFunctionData('execute', [otherTarget, 0, innerCall]);

      await expect(
        paymaster.validatePaymasterUserOp(
          buildUserOp(contributor.address, badCall),
          ethers.ZeroHash,
          1
        )
      ).to.be.revertedWithCustomError(paymaster, 'WeatherDataPaymasterTargetNotAllowed');
    });

    it('enforces per-address daily rate limits', async function () {
      const { contributor, validator, paymaster, validatorIface, accountIface } =
        await loadFixture(deployFixture);

      const innerCall = validatorIface.encodeFunctionData('updateWeatherData', [
        stationId,
        weatherData(await time.latest()),
      ]);
      const callData = accountIface.encodeFunctionData('execute', [
        await validator.getAddress(),
        0,
        innerCall,
      ]);

      const userOp = buildUserOp(contributor.address, callData);
      await paymaster.validatePaymasterUserOp(userOp, ethers.ZeroHash, 1);
      await paymaster.validatePaymasterUserOp(userOp, ethers.ZeroHash, 1);

      await expect(
        paymaster.validatePaymasterUserOp(userOp, ethers.ZeroHash, 1)
      ).to.be.revertedWithCustomError(paymaster, 'WeatherDataPaymasterRateLimitExceeded');
    });

    it('supports batch weather data sponsorship', async function () {
      const { contributor, validator, paymaster, validatorIface, accountIface } =
        await loadFixture(deployFixture);

      const timestamps = [await time.latest(), (await time.latest()) + 1];
      const innerCall = validatorIface.encodeFunctionData('batchUpdateWeatherData', [
        [stationId, stationId],
        [weatherData(timestamps[0]), weatherData(timestamps[1])],
      ]);
      const callData = accountIface.encodeFunctionData('execute', [
        await validator.getAddress(),
        0,
        innerCall,
      ]);

      await expect(
        paymaster.validatePaymasterUserOp(
          buildUserOp(contributor.address, callData),
          ethers.ZeroHash,
          1
        )
      ).to.emit(paymaster, 'SponsorshipValidated');
    });
  });

  describe('admin and treasury controls', function () {
    it('emits minimum balance alerts after withdrawals below the threshold', async function () {
      const { owner, recipient, paymaster } = await loadFixture(deployFixture);

      await expect(
        paymaster.connect(owner).withdrawTreasury(recipient.address, ethers.parseEther('1.5'))
      )
        .to.emit(paymaster, 'TreasuryWithdrawal')
        .and.to.emit(paymaster, 'MinimumBalanceAlert');
    });

    it('allows admin to change per-address rate limits', async function () {
      const { owner, contributor, paymaster } = await loadFixture(deployFixture);

      await expect(paymaster.connect(owner).setAddressRateLimit(contributor.address, 5))
        .to.emit(paymaster, 'AddressRateLimitUpdated')
        .withArgs(contributor.address, 5);

      const [maxTransactionsPerDay] = await paymaster.getRateLimit(contributor.address);
      expect(maxTransactionsPerDay).to.equal(5n);
    });

    it('rejects sponsorship while paused', async function () {
      const { owner, contributor, validator, paymaster, validatorIface, accountIface } =
        await loadFixture(deployFixture);

      await paymaster.connect(owner).pause();

      const innerCall = validatorIface.encodeFunctionData('updateWeatherData', [
        stationId,
        weatherData(await time.latest()),
      ]);
      const callData = accountIface.encodeFunctionData('execute', [
        await validator.getAddress(),
        0,
        innerCall,
      ]);

      await expect(
        paymaster.validatePaymasterUserOp(
          buildUserOp(contributor.address, callData),
          ethers.ZeroHash,
          1
        )
      ).to.be.revertedWithCustomError(paymaster, 'EnforcedPause');
    });

    it('emits an alert when prefund can be covered but balance is below the minimum threshold', async function () {
      const { owner, contributor, validator, paymaster, validatorIface, accountIface } =
        await loadFixture(deployFixture);

      await paymaster.connect(owner).setMinimumPaymasterBalance(ethers.parseEther('3'));

      const innerCall = validatorIface.encodeFunctionData('updateWeatherData', [
        stationId,
        weatherData(await time.latest()),
      ]);
      const callData = accountIface.encodeFunctionData('execute', [
        await validator.getAddress(),
        0,
        innerCall,
      ]);

      await expect(
        paymaster.validatePaymasterUserOp(
          buildUserOp(contributor.address, callData),
          ethers.ZeroHash,
          1
        )
      ).to.emit(paymaster, 'MinimumBalanceAlert');
    });
  });
});
