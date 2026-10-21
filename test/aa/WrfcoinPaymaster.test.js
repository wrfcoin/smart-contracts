'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('WrfcoinPaymaster', function () {
  async function deployFixture() {
    const [owner, accountOwner, oracle, otherOracle, recipient] = await ethers.getSigners();

    const MockAAEntryPoint = await ethers.getContractFactory('MockAAEntryPoint');
    const entryPoint = await MockAAEntryPoint.deploy();

    const WrfcoinAccount = await ethers.getContractFactory('WrfcoinAccount');
    const account = await WrfcoinAccount.deploy(await entryPoint.getAddress(), accountOwner.address);

    const WrfcoinPaymaster = await ethers.getContractFactory('WrfcoinPaymaster');
    const paymaster = await WrfcoinPaymaster.deploy(await entryPoint.getAddress(), owner.address);

    await paymaster.connect(owner).addOracle(oracle.address);

    const accountIface = new ethers.Interface([
      'function executeWeatherSubmission(bytes packetData)',
      'function execute(address dest, uint256 value, bytes func)',
    ]);

    return {
      owner,
      accountOwner,
      oracle,
      otherOracle,
      recipient,
      entryPoint,
      account,
      paymaster,
      accountIface,
    };
  }

  async function currentValidUntil() {
    const latestBlock = await ethers.provider.getBlock('latest');
    return BigInt(latestBlock.timestamp + 3600);
  }

  function buildUserOp(sender, callData, paymasterAndData, overrides = {}) {
    return {
      sender,
      nonce: overrides.nonce ?? 0n,
      initCode: '0x',
      callData,
      callGasLimit: overrides.callGasLimit ?? 150000n,
      verificationGasLimit: 200000n,
      preVerificationGas: 50000n,
      maxFeePerGas: 1n,
      maxPriorityFeePerGas: 1n,
      paymasterAndData,
      signature: '0x',
    };
  }

  async function sponsorshipSignature(paymaster, userOp, oracleSigner, weatherDataHash, validUntil) {
    const digest = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['uint256', 'address', 'address', 'bytes32', 'bytes32', 'uint48'],
        [
          BigInt((await ethers.provider.getNetwork()).chainId),
          await paymaster.getAddress(),
          userOp.sender,
          ethers.keccak256(userOp.callData),
          weatherDataHash,
          validUntil,
        ]
      )
    );
    return oracleSigner.signMessage(ethers.getBytes(digest));
  }

  async function buildSponsoredUserOp(fixture, packetData, overrides = {}) {
    const { account, paymaster, oracle, accountIface } = fixture;
    const callData = accountIface.encodeFunctionData('executeWeatherSubmission', [packetData]);
    const weatherDataHash = ethers.keccak256(packetData);
    const validUntil = overrides.validUntil ?? await currentValidUntil();
    const baseUserOp = buildUserOp(
      await account.getAddress(),
      callData,
      '0x',
      { callGasLimit: overrides.callGasLimit }
    );
    const signature = await sponsorshipSignature(
      paymaster,
      baseUserOp,
      oracle,
      weatherDataHash,
      validUntil
    );
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'bytes32', 'uint48', 'bytes'],
      [oracle.address, weatherDataHash, validUntil, signature]
    );

    return {
      userOp: {
        ...baseUserOp,
        paymasterAndData: ethers.concat([await paymaster.getAddress(), encoded]),
      },
      weatherDataHash,
      validUntil,
    };
  }

  it('accepts a valid sponsored weather submission', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, oracle, account } = fixture;
    const packetData = ethers.toUtf8Bytes('weather-packet-1');
    const { userOp, weatherDataHash, validUntil } = await buildSponsoredUserOp(fixture, packetData);

    const [context, validationData] = await entryPoint.callValidatePaymasterUserOp.staticCall(
      await paymaster.getAddress(),
      userOp,
      ethers.ZeroHash,
      1n
    );

    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
      ['address', 'address', 'bytes32'],
      context
    );
    expect(decoded[0]).to.equal(oracle.address);
    expect(decoded[1]).to.equal(await account.getAddress());
    expect(decoded[2]).to.equal(weatherDataHash);

    const expectedValidationData =
      (BigInt(validUntil) << 160n);
    expect(validationData).to.equal(expectedValidationData);
  });

  it('rejects an invalid oracle signature', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, oracle, otherOracle, account, accountIface } = fixture;
    const packetData = ethers.toUtf8Bytes('weather-packet-2');
    const callData = accountIface.encodeFunctionData('executeWeatherSubmission', [packetData]);
    const weatherDataHash = ethers.keccak256(packetData);
    const validUntil = await currentValidUntil();
    const baseUserOp = buildUserOp(await account.getAddress(), callData, '0x');
    const signature = await sponsorshipSignature(
      paymaster,
      baseUserOp,
      otherOracle,
      weatherDataHash,
      validUntil
    );
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'bytes32', 'uint48', 'bytes'],
      [oracle.address, weatherDataHash, validUntil, signature]
    );
    const userOp = {
      ...baseUserOp,
      paymasterAndData: ethers.concat([await paymaster.getAddress(), encoded]),
    };

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterInvalidOracleSignature');
  });

  it('rejects an unauthorized oracle', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, otherOracle, account, accountIface } = fixture;
    const packetData = ethers.toUtf8Bytes('weather-packet-3');
    const callData = accountIface.encodeFunctionData('executeWeatherSubmission', [packetData]);
    const weatherDataHash = ethers.keccak256(packetData);
    const validUntil = await currentValidUntil();
    const baseUserOp = buildUserOp(await account.getAddress(), callData, '0x');
    const signature = await sponsorshipSignature(
      paymaster,
      baseUserOp,
      otherOracle,
      weatherDataHash,
      validUntil
    );
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'bytes32', 'uint48', 'bytes'],
      [otherOracle.address, weatherDataHash, validUntil, signature]
    );
    const userOp = {
      ...baseUserOp,
      paymasterAndData: ethers.concat([await paymaster.getAddress(), encoded]),
    };

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterUnauthorizedOracle');
  });

  it('rejects oversized callGasLimit', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster } = fixture;
    const packetData = ethers.toUtf8Bytes('weather-packet-4');
    const { userOp } = await buildSponsoredUserOp(fixture, packetData, {
      callGasLimit: 500001n,
    });

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterGasLimitTooHigh');
  });

  it('emits sponsorship data in postOp', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, oracle, account } = fixture;
    const context = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'bytes32'],
      [oracle.address, await account.getAddress(), ethers.keccak256(ethers.toUtf8Bytes('packet'))]
    );

    await expect(
      entryPoint.callPostOp(
        await paymaster.getAddress(),
        0,
        context,
        12345n
      )
    )
      .to.emit(paymaster, 'WeatherSubmissionSponsored')
      .withArgs(oracle.address, await account.getAddress(), ethers.keccak256(ethers.toUtf8Bytes('packet')), 12345n);
  });

  it('rejects user ops with no paymasterAndData', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, account, accountIface } = fixture;
    const callData = accountIface.encodeFunctionData('executeWeatherSubmission', [
      ethers.toUtf8Bytes('packet-empty'),
    ]);
    const userOp = buildUserOp(await account.getAddress(), callData, '0x');

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterInvalidPaymasterData');
  });

  it('rejects unsupported call targets', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, account, accountIface } = fixture;
    const callData = accountIface.encodeFunctionData('execute', [
      ethers.ZeroAddress,
      0n,
      '0x',
    ]);
    const userOp = buildUserOp(
      await account.getAddress(),
      callData,
      ethers.concat([await paymaster.getAddress(), '0x1234'])
    );

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterUnsupportedCall');
  });

  it('rejects expired sponsorship windows', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster } = fixture;
    const packetData = ethers.toUtf8Bytes('weather-packet-expired');
    const { userOp } = await buildSponsoredUserOp(fixture, packetData, {
      validUntil: (await currentValidUntil()) - 7200n,
    });

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterExpiredSponsorship');
  });

  it('rejects paymaster data when packet bytes do not match the signed weather hash', async function () {
    const fixture = await loadFixture(deployFixture);
    const { entryPoint, paymaster, account, oracle, accountIface } = fixture;
    const packetData = ethers.toUtf8Bytes('weather-packet-original');
    const tamperedPacketData = ethers.toUtf8Bytes('weather-packet-tampered');
    const weatherDataHash = ethers.keccak256(packetData);
    const validUntil = await currentValidUntil();
    const callData = accountIface.encodeFunctionData('executeWeatherSubmission', [
      tamperedPacketData,
    ]);
    const baseUserOp = buildUserOp(await account.getAddress(), callData, '0x');
    const signature = await sponsorshipSignature(
      paymaster,
      baseUserOp,
      oracle,
      weatherDataHash,
      validUntil
    );
    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'bytes32', 'uint48', 'bytes'],
      [oracle.address, weatherDataHash, validUntil, signature]
    );
    const userOp = {
      ...baseUserOp,
      paymasterAndData: ethers.concat([await paymaster.getAddress(), encoded]),
    };

    await expect(
      entryPoint.callValidatePaymasterUserOp(await paymaster.getAddress(), userOp, ethers.ZeroHash, 1n)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterWeatherHashMismatch');
  });

  it('supports owner deposit and withdraw flows through EntryPoint', async function () {
    const { owner, recipient, paymaster, entryPoint } = await loadFixture(deployFixture);

    await paymaster.connect(owner).deposit({ value: ethers.parseEther('1') });
    expect(await entryPoint.balanceOf(await paymaster.getAddress())).to.equal(
      ethers.parseEther('1')
    );

    await expect(
      paymaster.connect(owner).withdrawTo(recipient.address, ethers.parseEther('0.4'))
    ).to.changeEtherBalances(
      [recipient],
      [ethers.parseEther('0.4')]
    );
    expect(await entryPoint.balanceOf(await paymaster.getAddress())).to.equal(
      ethers.parseEther('0.6')
    );
  });

  it('restricts oracle admin to the owner', async function () {
    const { accountOwner, paymaster, otherOracle } = await loadFixture(deployFixture);

    await expect(
      paymaster.connect(accountOwner).addOracle(otherOracle.address)
    ).to.be.revertedWithCustomError(paymaster, 'OwnableUnauthorizedAccount').withArgs(accountOwner.address);
    await expect(
      paymaster.connect(accountOwner).removeOracle(otherOracle.address)
    ).to.be.revertedWithCustomError(paymaster, 'OwnableUnauthorizedAccount').withArgs(accountOwner.address);
  });

  it('rejects zero-address oracle administration', async function () {
    const { owner, paymaster } = await loadFixture(deployFixture);

    await expect(
      paymaster.connect(owner).addOracle(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterZeroAddress');
    await expect(
      paymaster.connect(owner).removeOracle(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(paymaster, 'WrfcoinPaymasterZeroAddress');
  });
});
