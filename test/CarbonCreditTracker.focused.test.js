'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonCreditTracker — focused coverage', function () {
  async function deployFixture() {
    const [admin, issuer, connector, oracle, outsider, beneficiary] = await ethers.getSigners();

    const Tracker = await ethers.getContractFactory('CarbonCreditTracker');
    const tracker = await Tracker.deploy();

    return {
      admin,
      issuer,
      connector,
      oracle,
      outsider,
      beneficiary,
      tracker,
    };
  }

  async function createActiveLifecycle(tracker, creator) {
    const lifecycleId = await tracker
      .connect(creator)
      .createLifecycle.staticCall(1n, 'project-z', 'SN-Z', 'VCS', creator.address, 1000n);
    await tracker.connect(creator).createLifecycle(1n, 'project-z', 'SN-Z', 'VCS', creator.address, 1000n);
    return lifecycleId;
  }

  async function createLifecycle(tracker, creator, serial) {
    return tracker
      .connect(creator)
      .createLifecycle(1n, 'project-z', serial, 'VCS', creator.address, 1000n);
  }

  it('guards lifecycle issuance role and uniqueness invariants', async function () {
    const { tracker, admin, issuer, outsider } = await loadFixture(deployFixture);
    const issuerRole = await tracker.AUTHORIZED_ISSUER_ROLE();

    await expect(
      tracker.connect(issuer).createLifecycle(1n, 'project-1', 'SN-1', 'VCS', issuer.address, 1n),
    ).to.be.revertedWith('CarbonCreditTracker: Not authorized issuer');

    await tracker.connect(admin).grantRole(issuerRole, issuer.address);
    await expect(
      tracker
        .connect(issuer)
        .createLifecycle(1n, 'project-1', '', 'VCS', issuer.address, 1n),
    ).to.be.revertedWith('CarbonCreditTracker: Invalid serial number');

    await createLifecycle(tracker, issuer, 'SN-1');
    await expect(
      createLifecycle(tracker, issuer, 'SN-1'),
    ).to.be.revertedWith('CarbonCreditTracker: Serial number already used');
  });

  it('guards registry-connector retirement flow and lifecycle state', async function () {
    const { tracker, admin, issuer, connector, outsider } = await loadFixture(deployFixture);
    const connectorRole = await tracker.REGISTRY_CONNECTOR_ROLE();
    await tracker.connect(admin).grantRole(connectorRole, connector.address);

    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), issuer.address);
    const tx = await createLifecycle(tracker, issuer, 'SN-2');
    const receipt = await tx.wait();
    const lifecycleId = receipt.logs[0].args[0];

    await expect(
      tracker.connect(outsider).recordRetirement(lifecycleId, outsider.address, 1n, 'blocked'),
    ).to.be.revertedWith('CarbonCreditTracker: Not registry connector');

    await expect(
      tracker.connect(connector).recordRetirement(lifecycleId, outsider.address, 0n, 'zero'),
    ).to.be.revertedWith('CarbonCreditTracker: Invalid amount');

    await expect(
      tracker.connect(connector).recordRetirement(lifecycleId, outsider.address, 500n, 'not verified'),
    ).to.be.revertedWith('CarbonCreditTracker: Credit not verified for retirement');
  });

  it('guards transferability state transitions', async function () {
    const { tracker, admin, issuer, connector } = await loadFixture(deployFixture);
    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), issuer.address);
    await tracker.connect(admin).grantRole(await tracker.REGISTRY_CONNECTOR_ROLE(), connector.address);
    const tx = await createLifecycle(tracker, issuer, 'SN-3');
    const lifecycleId = (await tx.wait()).logs[0].args[0];

    await expect(
      tracker.connect(admin).recordTransfer(lifecycleId, issuer.address, connector.address, 1n, 'invalid status'),
    ).to.be.revertedWith('CarbonCreditTracker: Credit not in transferable status');

    await expect(
      tracker.connect(admin).recordTransfer(lifecycleId, ethers.ZeroAddress, connector.address, 0n, 'zero amount'),
    ).to.be.revertedWith('CarbonCreditTracker: Invalid amount');
  });

  it('guards oracle registration and oracle-only operations', async function () {
    const { tracker, admin, oracle, outsider } = await loadFixture(deployFixture);

    // onlyRole(DEFAULT_ADMIN_ROLE) — CarbonCreditTracker.sol:617. oracle.address is
    // a real signer address, so any zero-address check inside would pass: deleting
    // the role modifier makes this call succeed rather than revert for another reason.
    await expect(tracker.connect(outsider).setVerificationOracle(oracle.address))
      .to.be.revertedWithCustomError(tracker, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await tracker.DEFAULT_ADMIN_ROLE());

    await expect(tracker.connect(admin).setVerificationOracle(ethers.ZeroAddress)).to.be.revertedWith(
      'CarbonCreditTracker: Invalid oracle',
    );

    await tracker.connect(admin).setVerificationOracle(oracle.address);
    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), admin);
    const tx = await createLifecycle(tracker, admin, 'SN-4');
    const lifecycleId = (await tx.wait()).logs[0].args[0];

    await expect(
      tracker.connect(outsider).setVerificationPending(lifecycleId),
    ).to.be.revertedWith('CarbonCreditTracker: Not verification oracle');

    await expect(
      tracker.connect(oracle).setVerificationPending(ethers.ZeroHash),
    ).to.be.revertedWith('CarbonCreditTracker: Lifecycle not found');

    await tracker.connect(oracle).setVerificationPending(lifecycleId);
    await tracker.connect(oracle).confirmVerification(lifecycleId);
    expect(await tracker.getLifecycleSummary(lifecycleId)).to.have.lengthOf(8);
  });

  // Builds a genuinely valid CrossChainProof for an initiated transfer:
  //   - merkleRoot == messageHash with an empty merkleProof, which is what
  //     OpenZeppelin MerkleProof.verify accepts for a single-leaf tree
  //   - MIN_VALIDATORS_REQUIRED distinct raw ECDSA signatures over messageHash
  //     (ECDSA.recover on the raw digest, so these are SigningKey signatures,
  //     NOT signMessage -- signMessage applies the EIP-191 prefix and would
  //     recover to the wrong address)
  // Signing wallets are random rather than hardhat signers because the raw
  // private key is needed; they only ever sign, they never send transactions.
  async function setUpValidatedTransfer(tracker, admin, issuer, recipient) {
    // Take the id from the event rather than a staticCall: createLifecycle's id
    // depends on state the real call mutates, so a pre-call staticCall can drift.
    const tx = await createLifecycle(tracker, issuer, 'SN-XC');
    const lifecycleId = (await tx.wait()).logs[0].args[0];
    await tracker.connect(admin).updateCrossChainRegistry(1001n, admin.address, true, 1n, 'http://chain');

    const initTx = await tracker
      .connect(issuer)
      .initiateCrossChainTransfer(lifecycleId, 1001n, recipient.address, 1n, 0);
    const initReceipt = await initTx.wait();
    const initiated = initReceipt.logs
      .map(l => { try { return tracker.interface.parseLog(l); } catch { return null; } })
      .find(e => e && e.name === 'CrossChainTransferInitiated');
    const transferId = initiated.args[0];

    const signers = [ethers.Wallet.createRandom(), ethers.Wallet.createRandom(), ethers.Wallet.createRandom()];
    for (const w of signers) {
      await tracker.connect(admin).addCrossChainValidator(w.address, 1n, 'http://validator');
    }

    const messageHash = ethers.keccak256(ethers.toUtf8Bytes('cross-chain-message-1'));
    const proof = {
      messageHash,
      sourceChainId: (await ethers.provider.getNetwork()).chainId,
      targetChainId: 1001n,
      sourceContract: await tracker.getAddress(),
      targetContract: admin.address,
      merkleProof: [],
      merkleRoot: messageHash,
      validatorSignatures: signers.map(w => new ethers.SigningKey(w.privateKey).sign(messageHash).serialized),
      nonce: 1n,
      timestamp: BigInt((await ethers.provider.getBlock('latest')).timestamp),
      isVerified: false,
    };

    return { transferId, proof };
  }

  it('guards cross-chain transfer preconditions', async function () {
    const { tracker, admin, issuer, outsider } = await loadFixture(deployFixture);
    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), issuer.address);
    const tx = await createLifecycle(tracker, issuer, 'SN-5');
    const lifecycleId = (await tx.wait()).logs[0].args[0];

    await expect(
      tracker
        .connect(issuer)
        .initiateCrossChainTransfer(
          lifecycleId,
          0n,
          outsider.address,
          1n,
          0, // BRIDGE_OUT
        ),
    ).to.be.revertedWith('CarbonCreditTracker: Unsupported chain');

    await expect(
      tracker
        .connect(issuer)
        .initiateCrossChainTransfer(
          lifecycleId,
          await ethers.provider.getNetwork().then((n) => n.chainId),
          outsider.address,
          1n,
          0,
        ),
    ).to.be.revertedWith('CarbonCreditTracker: Cannot transfer to same chain');

    await tracker.connect(admin).updateCrossChainRegistry(1001n, admin.address, true, 1n, 'http://chain');
    await expect(
      tracker
        .connect(issuer)
        .initiateCrossChainTransfer(
          lifecycleId,
          1_001n,
          ethers.ZeroAddress,
          1n,
          0,
        ),
    ).to.be.revertedWith('CarbonCreditTracker: Invalid recipient');
  });

  it('rejects inbound validation from a non-validator', async function () {
    const { tracker, admin, issuer, beneficiary, outsider } = await loadFixture(deployFixture);
    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), issuer.address);
    const { transferId, proof } = await setUpValidatedTransfer(tracker, admin, issuer, beneficiary);

    await expect(
      tracker.connect(outsider).validateCrossChainTransfer(transferId, proof)
    ).to.be.revertedWith('CarbonCreditTracker: Not validator');
  });

  it('rejects inbound validation from a deactivated validator', async function () {
    const { tracker, admin, issuer, beneficiary } = await loadFixture(deployFixture);
    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), issuer.address);
    const { transferId, proof } = await setUpValidatedTransfer(tracker, admin, issuer, beneficiary);

    // Grant the role WITHOUT addCrossChainValidator, so hasRole passes but the
    // validator record is inactive. removeCrossChainValidator also revokes the
    // role, so a removed validator trips "Not validator" first and could never
    // reach this second guard -- the two checks are genuinely independent.
    const caller = (await ethers.getSigners())[7];
    await tracker.connect(admin).grantRole(await tracker.CROSS_CHAIN_VALIDATOR_ROLE(), caller.address);

    await expect(
      tracker.connect(caller).validateCrossChainTransfer(transferId, proof)
    ).to.be.revertedWith('CarbonCreditTracker: Validator inactive');
  });

  it('rejects a replayed cross-chain proof', async function () {
    const { tracker, admin, issuer, beneficiary } = await loadFixture(deployFixture);
    await tracker.connect(admin).grantRole(await tracker.AUTHORIZED_ISSUER_ROLE(), issuer.address);
    const { transferId, proof } = await setUpValidatedTransfer(tracker, admin, issuer, beneficiary);

    const caller = (await ethers.getSigners())[7];
    await tracker.connect(admin).addCrossChainValidator(caller.address, 1n, 'http://caller');

    await tracker.connect(caller).validateCrossChainTransfer(transferId, proof);

    await expect(
      tracker.connect(caller).validateCrossChainTransfer(transferId, proof)
    ).to.be.revertedWith('CarbonCreditTracker: Message already processed');
  });
});
