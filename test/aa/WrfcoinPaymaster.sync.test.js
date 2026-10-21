'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('WrfcoinPaymaster — Oracle Sync (#52)', function () {
  async function deployFixture() {
    const [owner, relayerSigner, oracle1, oracle2, oracle3, attacker] = await ethers.getSigners();

    const MockAAEntryPoint = await ethers.getContractFactory('MockAAEntryPoint');
    const entryPoint = await MockAAEntryPoint.deploy();

    const WrfcoinPaymaster = await ethers.getContractFactory('WrfcoinPaymaster');
    const paymaster = await WrfcoinPaymaster.deploy(await entryPoint.getAddress(), owner.address);

    // Set relayer
    await paymaster.connect(owner).setRelayer(relayerSigner.address);

    return { paymaster, owner, relayerSigner, oracle1, oracle2, oracle3, attacker };
  }

  describe('setRelayer', function () {
    it('owner can set relayer', async function () {
      const { paymaster, relayerSigner } = await loadFixture(deployFixture);
      expect(await paymaster.relayer()).to.equal(relayerSigner.address);
    });

    it('non-owner cannot set relayer', async function () {
      const { paymaster, attacker } = await loadFixture(deployFixture);
      await expect(paymaster.connect(attacker).setRelayer(attacker.address)).to.be.revertedWithCustomError(paymaster, 'OwnableUnauthorizedAccount').withArgs(attacker.address);
    });

    it('emits RelayerUpdated event', async function () {
      const { paymaster, owner, oracle1 } = await loadFixture(deployFixture);
      await expect(paymaster.connect(owner).setRelayer(oracle1.address))
        .to.emit(paymaster, 'RelayerUpdated');
    });
  });

  describe('syncOracles', function () {
    it('relayer can add oracles', async function () {
      const { paymaster, relayerSigner, oracle1, oracle2 } = await loadFixture(deployFixture);

      await paymaster.connect(relayerSigner).syncOracles(
        [oracle1.address, oracle2.address],
        []
      );

      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.true;
      expect(await paymaster.authorizedOracles(oracle2.address)).to.be.true;
    });

    it('relayer can remove oracles', async function () {
      const { paymaster, owner, relayerSigner, oracle1 } = await loadFixture(deployFixture);

      // Add via owner first
      await paymaster.connect(owner).addOracle(oracle1.address);
      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.true;

      // Remove via relayer
      await paymaster.connect(relayerSigner).syncOracles([], [oracle1.address]);
      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.false;
    });

    it('relayer can add and remove in one call', async function () {
      const { paymaster, owner, relayerSigner, oracle1, oracle2 } = await loadFixture(deployFixture);

      await paymaster.connect(owner).addOracle(oracle1.address);

      await paymaster.connect(relayerSigner).syncOracles(
        [oracle2.address],
        [oracle1.address]
      );

      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.false;
      expect(await paymaster.authorizedOracles(oracle2.address)).to.be.true;
    });

    it('owner can also call syncOracles', async function () {
      const { paymaster, owner, oracle1 } = await loadFixture(deployFixture);

      await paymaster.connect(owner).syncOracles([oracle1.address], []);
      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.true;
    });

    it('non-relayer/non-owner cannot call syncOracles', async function () {
      const { paymaster, attacker, oracle1 } = await loadFixture(deployFixture);

      await expect(
        paymaster.connect(attacker).syncOracles([oracle1.address], [])
      ).to.be.revertedWith('WrfcoinPaymaster: unauthorized');
    });

    it('skips zero addresses', async function () {
      const { paymaster, relayerSigner } = await loadFixture(deployFixture);

      // Should not revert
      await paymaster.connect(relayerSigner).syncOracles(
        [ethers.ZeroAddress],
        [ethers.ZeroAddress]
      );
    });

    it('emits OraclesSynced event', async function () {
      const { paymaster, relayerSigner, oracle1 } = await loadFixture(deployFixture);

      await expect(paymaster.connect(relayerSigner).syncOracles([oracle1.address], []))
        .to.emit(paymaster, 'OraclesSynced')
        .withArgs(1, 0);
    });

    it('existing addOracle/removeOracle still work', async function () {
      const { paymaster, owner, oracle1 } = await loadFixture(deployFixture);

      await paymaster.connect(owner).addOracle(oracle1.address);
      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.true;

      await paymaster.connect(owner).removeOracle(oracle1.address);
      expect(await paymaster.authorizedOracles(oracle1.address)).to.be.false;
    });
  });
});
