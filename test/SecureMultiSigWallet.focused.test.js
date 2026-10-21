const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

const ZERO_BYTES32 = '0x0000000000000000000000000000000000000000000000000000000000000000';

describe('SecureMultiSigWallet — focused guard tests', function () {
  async function deployFixture() {
    const [owner, owner2, owner3, outsider, recipient] =
      await ethers.getSigners();

    const SecureMultiSigWallet = await ethers.getContractFactory(
      'SecureMultiSigWallet'
    );

    const wallet = await SecureMultiSigWallet.deploy(
      [owner.address, owner2.address, owner3.address],
      2,
      ethers.parseEther('10'),
      owner.address
    );

    return { wallet, owner, owner2, owner3, outsider, recipient };
  }

  it('rejects non-owners from submitting a transaction', async function () {
    const { wallet, outsider, recipient } = await loadFixture(deployFixture);

    await expect(
      wallet.connect(outsider).submitTransaction(
        recipient.address,
        ethers.parseEther('1'),
        '0x',
        'non-owner submit',
        0,
        Math.floor(Date.now() / 1000) + 3600
      )
    ).to.be.revertedWith('SecureMultiSigWallet: Not an owner');
  });

  it('rejects confirmations with signatures from non-caller identity', async function () {
    const { wallet, owner, owner2, outsider, recipient } =
      await loadFixture(deployFixture);

    const countBefore = await wallet.transactionCount();
    const submitTx = await wallet
      .connect(owner)
      .submitTransaction(
        recipient.address,
        ethers.parseEther('1'),
        '0x',
        'bad signature check',
        0,
        (await ethers.provider.getBlock('latest')).timestamp + 3600
      );
    const receipt = await submitTx.wait();

    const block = await ethers.provider.getBlock(receipt.blockNumber);
    const randomSeed = block.prevRandao ?? block.prevrandao ?? block.mixHash ?? ZERO_BYTES32;
    const txCountBefore = countBefore + 0n;
    const submitNonce = ethers.keccak256(
      ethers.solidityPacked(
        ['uint256', 'bytes32', 'uint256', 'address'],
        [block.timestamp, randomSeed, txCountBefore, owner.address]
      )
    );

    const typedSignature = await owner2.signTypedData(
      {
        name: 'SecureMultiSigWallet',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await wallet.getAddress(),
      },
      {
        Transaction: [
          { name: 'to', type: 'address' },
          { name: 'value', type: 'uint256' },
          { name: 'data', type: 'bytes' },
          { name: 'nonce', type: 'uint256' },
          { name: 'deadline', type: 'uint256' },
          { name: 'description', type: 'string' },
        ],
      },
      {
        to: recipient.address,
        value: ethers.parseEther('1'),
        data: '0x',
        nonce: submitNonce,
        deadline: (await wallet.getTransaction(0n))[5],
        description: 'bad signature check',
      }
    );

    await expect(
      wallet.connect(outsider).confirmTransaction(0n, typedSignature)
    ).to.be.revertedWith('SecureMultiSigWallet: Not an owner');

    await expect(
      wallet.connect(owner2).confirmTransaction(0n, typedSignature)
    ).to.be.revertedWith('SecureMultiSigWallet: Invalid signature');
  });

  it('rejects malformed transaction parameters at submission time', async function () {
    const { wallet, owner } = await loadFixture(deployFixture);

    await expect(
      wallet.connect(owner).submitTransaction(
        ethers.ZeroAddress,
        ethers.parseEther('1'),
        '0x',
        'zero recipient',
        0,
        (await ethers.provider.getBlock('latest')).timestamp + 3600
      )
    ).to.be.revertedWith('SecureMultiSigWallet: Invalid recipient');
  });

  it('rejects execution from insufficient confirmations', async function () {
    const { wallet, owner, recipient } = await loadFixture(deployFixture);

    await wallet.connect(owner).submitTransaction(
      recipient.address,
      ethers.parseEther('1'),
      '0x',
      'insufficient confirmations',
      0,
      (await ethers.provider.getBlock('latest')).timestamp + 3600
    );

    await expect(
      wallet.connect(owner).executeTransaction(0n)
    ).to.be.revertedWith('SecureMultiSigWallet: Insufficient confirmations');
  });

  it('restricts emergency controls to emergency-role holders', async function () {
    const { wallet, outsider } = await loadFixture(deployFixture);

    // onlyRole(EMERGENCY_ROLE) whenNotPaused — SecureMultiSigWallet.sol:746. The wallet
    // is not paused and not already in emergency mode here, so neither whenNotPaused
    // nor the `Already in emergency mode` require (:747) can fire: the role gate is the
    // only possible rejection.
    await expect(
      wallet.connect(outsider).activateEmergencyMode()
    )
      .to.be.revertedWithCustomError(wallet, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await wallet.EMERGENCY_ROLE());

    await expect(
      wallet.connect(outsider).emergencyRecover(outsider.address, 0, '0x')
    ).to.be.revertedWith('SecureMultiSigWallet: Not emergency recovery address');
  });
});
