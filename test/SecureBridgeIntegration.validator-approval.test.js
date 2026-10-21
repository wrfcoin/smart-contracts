'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, setBalance, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('SecureBridgeIntegration — validator approval quorum', function () {
  const VALIDATOR_STAKE = ethers.parseEther('150000');
  const LOW_VALUE = ethers.parseEther('1');
  const ULTRA_VALUE = ethers.parseEther('100000');

  async function deployFixture() {
    const [admin, user, outsider, ...validators] = await ethers.getSigners();

    const Hardening = await ethers.getContractFactory('CrossChainBridgeSecurityHardening');
    const hardening = await Hardening.connect(admin).deploy();

    const Bridge = await ethers.getContractFactory('MockNFTCrossChainBridgeEndpoint');
    const bridge = await Bridge.connect(admin).deploy();

    const Integration = await ethers.getContractFactory('SecureBridgeIntegration');
    const integration = await Integration.connect(admin).deploy(
      await bridge.getAddress(),
      await hardening.getAddress(),
    );

    const Oracle = await ethers.getContractFactory('MockNFTValueOracle');
    const oracle = await Oracle.connect(admin).deploy();
    await integration.connect(admin).setNFTValueOracle(await oracle.getAddress());

    return { admin, user, outsider, validators, hardening, bridge, integration, oracle };
  }

  async function registerValidators(hardening, admin, validators, count) {
    await setBalance(admin.address, VALIDATOR_STAKE * BigInt(count + 2));
    for (let i = 0; i < count; i++) {
      await hardening.connect(admin).registerEnhancedValidator(
        validators[i].address,
        VALIDATOR_STAKE,
        ethers.encodeBytes32String(`node-${i + 1}`),
        `https://validator-${i + 1}.example.com`,
        { value: VALIDATOR_STAKE },
      );
    }
  }

  async function initiate(integration, oracle, user, value, tokenId = 1n) {
    const nftAddress = ethers.Wallet.createRandom().address;
    await oracle.setQuote(nftAddress, tokenId, value, (await time.latest()) - 1);
    const tx = await integration.connect(user).initiateSecureTransfer(
      nftAddress,
      tokenId,
      0,
      user.address,
      'validator-quorum-test',
    );
    const receipt = await tx.wait();
    const event = receipt.logs
      .map((log) => {
        try {
          return integration.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((entry) => entry && entry.name === 'SecureTransferInitiated');
    return event.args.transferId;
  }

  function selectedSigners(selected, validators) {
    const byAddress = new Map(validators.map((validator) => [validator.address.toLowerCase(), validator]));
    return selected.map((address) => byAddress.get(address.toLowerCase()));
  }

  it('reverts selection when the active set cannot satisfy the required strength', async function () {
    const { admin, user, validators, hardening, integration, oracle } = await loadFixture(deployFixture);
    await registerValidators(hardening, admin, validators, 2);

    const nftAddress = ethers.Wallet.createRandom().address;
    await oracle.setQuote(nftAddress, 1n, LOW_VALUE, (await time.latest()) - 1);
    await expect(
      integration.connect(user).initiateSecureTransfer(
        nftAddress,
        1n,
        0,
        user.address,
        'under-strength',
      ),
    ).to.be.revertedWith('SecureBridge: Insufficient active validators');
  });

  it('accepts one vote only from each selected validator and exposes quorum reads', async function () {
    const { admin, user, outsider, validators, hardening, integration, oracle } =
      await loadFixture(deployFixture);
    await registerValidators(hardening, admin, validators, 3);
    const transferId = await initiate(integration, oracle, user, LOW_VALUE);
    const selected = await integration.getSelectedValidators(transferId);
    const signers = selectedSigners(selected, validators);

    expect(selected).to.have.length(3);
    expect(await integration.getValidatorApprovalCount(transferId)).to.equal(0n);
    expect(await integration.hasValidatorQuorum(transferId)).to.equal(false);

    await expect(integration.connect(outsider).submitValidatorApproval(transferId))
      .to.be.revertedWith('SecureBridge: Validator not selected');

    await expect(integration.connect(signers[0]).submitValidatorApproval(transferId))
      .to.emit(integration, 'ValidatorApprovalSubmitted')
      .withArgs(transferId, signers[0].address, 1n, 3n);
    expect(await integration.hasValidatorApproved(transferId, signers[0].address)).to.equal(true);
    expect(await integration.getValidatorApprovalCount(transferId)).to.equal(1n);

    await expect(integration.connect(signers[0]).submitValidatorApproval(transferId))
      .to.be.revertedWith('SecureBridge: Validator already approved');

    await integration.connect(signers[1]).submitValidatorApproval(transferId);
    await expect(integration.connect(signers[2]).submitValidatorApproval(transferId))
      .to.emit(integration, 'ValidatorQuorumReached')
      .withArgs(transferId, 3n, 3n);
    expect(await integration.hasValidatorQuorum(transferId)).to.equal(true);
  });

  it('rejects an inactive selected validator and votes submitted after expiry', async function () {
    const { admin, user, validators, hardening, integration, oracle } = await loadFixture(deployFixture);
    await registerValidators(hardening, admin, validators, 3);
    const transferId = await initiate(integration, oracle, user, LOW_VALUE);
    const selected = await integration.getSelectedValidators(transferId);
    const signers = selectedSigners(selected, validators);

    await hardening.connect(admin).slashValidatorEnhanced(signers[0].address, 'test deactivation', 4);
    await expect(integration.connect(signers[0]).submitValidatorApproval(transferId))
      .to.be.revertedWith('SecureBridge: Validator not active');

    const request = await integration.getTransferDetails(transferId);
    await time.increaseTo(request.approvalDeadline + 1n);
    await expect(integration.connect(signers[1]).submitValidatorApproval(transferId))
      .to.be.revertedWith('SecureBridge: Transfer expired');
  });

  it('keeps manual approval and validator quorum independent and executes only after every gate', async function () {
    const { admin, user, validators, hardening, bridge, integration, oracle } =
      await loadFixture(deployFixture);
    await registerValidators(hardening, admin, validators, 6);
    const transferId = await initiate(integration, oracle, user, ULTRA_VALUE);
    const selected = await integration.getSelectedValidators(transferId);
    const signers = selectedSigners(selected, validators);

    expect(selected).to.have.length(6);
    for (const signer of signers) {
      await integration.connect(signer).submitValidatorApproval(transferId);
    }
    expect(await integration.hasValidatorQuorum(transferId)).to.equal(true);

    await expect(integration.connect(user).executeSecureTransfer(transferId))
      .to.be.revertedWith('SecureBridge: Transfer not approved');

    await integration.connect(admin).approveManualTransfer(transferId);
    await expect(integration.connect(user).executeSecureTransfer(transferId))
      .to.be.revertedWith('SecureBridge: Timelock active');

    const request = await integration.getTransferDetails(transferId);
    await time.increaseTo(request.executionNotBefore);
    await expect(integration.connect(user).executeSecureTransfer(transferId))
      .to.emit(integration, 'SecurityValidationCompleted')
      .withArgs(transferId, true, 'Transfer executed successfully', request.executionNotBefore + 1n);
    expect(await bridge.callCount()).to.equal(1n);
    expect(await integration.getSelectedValidators(transferId)).to.deep.equal(selected);
    expect(await integration.getValidatorApprovalCount(transferId)).to.equal(6n);
    expect(await integration.hasValidatorQuorum(transferId)).to.equal(true);
  });

  it('does not let manual approval substitute for validator quorum', async function () {
    const { admin, user, validators, hardening, integration, oracle } = await loadFixture(deployFixture);
    await registerValidators(hardening, admin, validators, 6);
    const transferId = await initiate(integration, oracle, user, ULTRA_VALUE, 2n);
    await integration.connect(admin).approveManualTransfer(transferId);

    const request = await integration.getTransferDetails(transferId);
    await time.increaseTo(request.executionNotBefore);
    await expect(integration.connect(user).executeSecureTransfer(transferId))
      .to.be.revertedWith('SecureBridge: Validator quorum not reached');
  });

  // Keep this no-time-travel fixture last so repository-wide suites that use
  // wall-clock-based test inputs do not inherit the 24-hour ULTRA timelock jump.
  it('reports the configured low-tier selection strength', async function () {
    const { admin, user, validators, hardening, integration, oracle } = await loadFixture(deployFixture);
    await registerValidators(hardening, admin, validators, 3);
    const transferId = await initiate(integration, oracle, user, LOW_VALUE, 3n);

    const selection = await integration.transferValidators(transferId);
    expect(selection.requiredCount).to.equal(3n);
    expect(await integration.getSelectedValidators(transferId)).to.have.length(3);
  });
});
