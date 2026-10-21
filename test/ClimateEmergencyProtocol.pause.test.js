// SPDX-License-Identifier: MIT
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('ClimateEmergencyProtocol - emergency pause governance', function () {
  const PAUSE_TIMELOCK = 24 * 60 * 60;

  async function deployFixture() {
    const [admin, guardian1, guardian2, guardian3, outsider] = await ethers.getSigners();

    const Token = await ethers.getContractFactory('TestERC20');
    const token = await Token.deploy(
      'Emergency Token',
      'EMT',
      ethers.parseEther('1000000')
    );

    const Protocol = await ethers.getContractFactory('ClimateEmergencyProtocol');
    const protocol = await Protocol.deploy(
      await token.getAddress(),
      admin.address,
      admin.address,
      [guardian1.address, guardian2.address, guardian3.address]
    );

    return {
      admin,
      guardian1,
      guardian2,
      guardian3,
      outsider,
      protocol,
    };
  }

  describe('requestPause', function () {
    it('queues the first approval without pausing immediately', async function () {
      const { protocol, guardian1 } = await loadFixture(deployFixture);

      await expect(protocol.connect(guardian1).requestPause())
        .to.emit(protocol, 'PauseRequested');

      expect(await protocol.paused()).to.equal(false);
      expect(await protocol.pauseRequestActive()).to.equal(true);
      expect(await protocol.pauseRequestNonce()).to.equal(1n);
      expect(await protocol.pauseApprovalCount()).to.equal(1n);
      expect(await protocol.pauseApprovals(1n, guardian1.address)).to.equal(true);
      expect(await protocol.pauseRequestedAt()).to.not.equal(0n);
    });

    it('rejects duplicate and non-council approvals', async function () {
      const { protocol, admin, guardian1, outsider } = await loadFixture(deployFixture);

      await protocol.connect(guardian1).requestPause();

      await expect(protocol.connect(guardian1).requestPause()).to.be.revertedWith(
        'CEP: Pause already approved'
      );

      await expect(protocol.connect(admin).requestPause()).to.be.revertedWithCustomError(protocol, 'AccessControlUnauthorizedAccount').withArgs(admin.address, await protocol.PAUSE_GUARDIAN_ROLE());
      await expect(protocol.connect(outsider).requestPause()).to.be.revertedWithCustomError(protocol, 'AccessControlUnauthorizedAccount').withArgs(outsider.address, await protocol.PAUSE_GUARDIAN_ROLE());
    });

    it('requires at least two approvals before pause execution is allowed', async function () {
      const { protocol, guardian1, guardian3 } = await loadFixture(deployFixture);

      await protocol.connect(guardian1).requestPause();
      await time.increase(PAUSE_TIMELOCK + 1);

      await expect(protocol.connect(guardian3).pause()).to.be.revertedWith(
        'CEP: Insufficient pause approvals'
      );
    });
  });

  describe('pause execution', function () {
    it('reverts before the 24-hour timelock elapses', async function () {
      const { protocol, guardian1, guardian2, guardian3 } = await loadFixture(deployFixture);

      await protocol.connect(guardian1).requestPause();
      await protocol.connect(guardian2).requestPause();

      await expect(protocol.connect(guardian3).pause()).to.be.revertedWith(
        'CEP: Pause timelock not elapsed'
      );
    });

    it('pauses after 2 approvals and the timelock, then resets request state', async function () {
      const { protocol, guardian1, guardian2, guardian3 } = await loadFixture(deployFixture);

      await protocol.connect(guardian1).requestPause();
      await protocol.connect(guardian2).requestPause();

      await time.increase(PAUSE_TIMELOCK + 1);

      await expect(protocol.connect(guardian3).pause())
        .to.emit(protocol, 'PauseExecuted');

      expect(await protocol.paused()).to.equal(true);
      expect(await protocol.pauseRequestActive()).to.equal(false);
      expect(await protocol.pauseApprovalCount()).to.equal(0n);
      expect(await protocol.pauseRequestedAt()).to.equal(0n);
    });

    it('unpauses normally and allows a fresh pause cycle', async function () {
      const { protocol, admin, guardian1, guardian2, guardian3 } = await loadFixture(
        deployFixture
      );

      await protocol.connect(guardian1).requestPause();
      await protocol.connect(guardian2).requestPause();
      await time.increase(PAUSE_TIMELOCK + 1);
      await protocol.connect(guardian3).pause();

      await expect(protocol.connect(admin).unpause()).to.not.be.reverted;
      expect(await protocol.paused()).to.equal(false);

      await protocol.connect(guardian1).requestPause();
      expect(await protocol.pauseRequestNonce()).to.equal(2n);
      expect(await protocol.pauseApprovalCount()).to.equal(1n);
      expect(await protocol.pauseApprovals(2n, guardian1.address)).to.equal(true);
    });
  });
});
