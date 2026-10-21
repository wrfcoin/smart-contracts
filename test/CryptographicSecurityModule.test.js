const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CryptographicSecurityModule', function () {
  async function deployHarnessFixture() {
    const [admin, signer] = await ethers.getSigners();
    const harnessFactory = await ethers.getContractFactory(
      'CryptographicSecurityModuleHarness',
    );
    const harness = await harnessFactory.connect(admin).deploy();
    return { harness, admin, signer };
  }

  it('REJECTS ECDSA_SECP256R1 signer algorithm instead of reusing secp256k1 recover', async function () {
    const { harness, signer } = await loadFixture(deployHarnessFixture);

    const message = ethers.keccak256(ethers.toUtf8Bytes('ecrecover-should-not-accept-r1'));
    const signature = await signer.signMessage(ethers.getBytes(message));

    await harness.seedSigner(
      signer.address,
      ethers.keccak256(ethers.toUtf8Bytes('test-public-key')),
      1, // ECDSA_SECP256R1
      3, // EMERGENCY clearance (safest path)
    );

    await expect(
      harness.verifySignatureForSigner(message, signature, signer.address),
    ).to.be.revertedWith('CSM: ECDSA_SECP256R1 unsupported without dedicated verifier');
  });
});
