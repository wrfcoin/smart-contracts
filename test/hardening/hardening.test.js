'use strict';
/**
 * @title Hardening Sweep Tests
 * @notice Tests for vulnerabilities fixed in the S48m hardening sweep:
 *   - CarbonCreditAMM: sync() access control, flash-swap callback target
 *   - ClimateActionNFT: updateOffset/verify on non-existent tokens
 *   - StationAdoptionPool: claimableRewards precision loss, error naming
 *   - StationAdoptionCertificateNFT: baseline correctness
 */

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function deployERC20(name, symbol, signer) {
  const Token = await ethers.getContractFactory('MockERC20', signer);
  const token = await Token.deploy(name, symbol, 18);
  await token.waitForDeployment();
  return token;
}

// ─────────────────────────────────────────────────────────────────────────────
// CarbonCreditAMM Hardening
// ─────────────────────────────────────────────────────────────────────────────

describe('CarbonCreditAMM — hardening sweep', function () {
  async function ammFixture() {
    const [factory, alice, bob] = await ethers.getSigners();

    let tokenA = await deployERC20('Token A', 'TKA', factory);
    let tokenB = await deployERC20('Token B', 'TKB', factory);

    const addrA = await tokenA.getAddress();
    const addrB = await tokenB.getAddress();
    const [token0Addr, token1Addr] =
      addrA.toLowerCase() < addrB.toLowerCase()
        ? [addrA, addrB]
        : [addrB, addrA];
    const token0 = addrA === token0Addr ? tokenA : tokenB;
    const token1 = addrA === token0Addr ? tokenB : tokenA;

    const CarbonCreditAMM = await ethers.getContractFactory('CarbonCreditAMM');
    const amm = await CarbonCreditAMM.connect(factory).deploy(factory.address);
    await amm.waitForDeployment();

    await amm.connect(factory).initialize(token0Addr, token1Addr, factory.address, 30);

    return { amm, token0, token1, token0Addr, token1Addr, factory, alice, bob };
  }

  // ── sync() access control ────────────────────────────────────────────────

  it('sync() reverts for non-admin callers', async function () {
    // VULNERABILITY FIXED: sync() was unrestricted, allowing any caller to force
    // a reserve update at an adversarially-chosen time, manipulating the TWAP oracle.
    const { amm, alice } = await loadFixture(ammFixture);

    await expect(amm.connect(alice).sync()).to.be.revertedWithCustomError(amm, 'AccessControlUnauthorizedAccount').withArgs(alice.address, await amm.DEFAULT_ADMIN_ROLE());
  });

  it('sync() succeeds for DEFAULT_ADMIN_ROLE holder', async function () {
    const { amm, factory } = await loadFixture(ammFixture);
    // Should not revert for admin
    await expect(amm.connect(factory).sync()).to.not.be.reverted;
  });

  // ── flash swap callback target ────────────────────────────────────────────

  it('swap() with data reverts when to != msg.sender', async function () {
    // VULNERABILITY FIXED: an authorized flash borrower could pass `to != msg.sender`
    // to trigger executeOperation() on any arbitrary contract address.
    const { amm, factory, token0, token1, token0Addr, token1Addr, alice, bob } =
      await loadFixture(ammFixture);

    // Add liquidity so the pool is operational
    const liquidity = ethers.parseEther('100');
    await token0.mint(factory.address, liquidity);
    await token1.mint(factory.address, liquidity);
    await token0.connect(factory).transfer(await amm.getAddress(), liquidity);
    await token1.connect(factory).transfer(await amm.getAddress(), liquidity);
    await amm.connect(factory).mint(factory.address);

    // Authorize factory as flash borrower
    await amm.connect(factory).setAuthorizedFlashBorrower(factory.address, true);

    // Attempt flash swap where `to` != `msg.sender` (bob != factory)
    const nonEmptyData = ethers.toUtf8Bytes('flash');
    await expect(
      amm
        .connect(factory)
        .swap(0, ethers.parseEther('1'), bob.address, nonEmptyData)
    ).to.be.revertedWith('CarbonCreditAMM: FLASH_SWAP_TO_MUST_BE_CALLER');
  });

  it('swap() with empty data allows to != msg.sender (normal swap)', async function () {
    const { amm, factory, token0, token1, alice } = await loadFixture(ammFixture);

    const MINT = ethers.parseEther('1000');
    const SWAP_IN = ethers.parseEther('10');

    await token0.mint(factory.address, MINT);
    await token1.mint(factory.address, MINT);
    await token0.connect(factory).transfer(await amm.getAddress(), MINT);
    await token1.connect(factory).transfer(await amm.getAddress(), MINT);
    await amm.connect(factory).mint(factory.address);

    // Compute expected output for SWAP_IN of token0 → token1
    const ammAddr = await amm.getAddress();
    await token0.mint(factory.address, SWAP_IN);
    await token0.connect(factory).transfer(ammAddr, SWAP_IN);

    const amountOut = await amm.getAmountOut(SWAP_IN, MINT, MINT);

    // Normal swap to alice (no data) — should succeed even though to != msg.sender
    // MEV protection: warp time forward 12+ seconds so antiMEV passes
    await ethers.provider.send('evm_increaseTime', [15]);
    await ethers.provider.send('evm_mine', []);

    await expect(
      amm.connect(factory).swap(0, amountOut, alice.address, '0x')
    ).to.not.be.reverted;
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// ClimateActionNFT Hardening
// ─────────────────────────────────────────────────────────────────────────────

describe('ClimateActionNFT — hardening sweep', function () {
  async function climateFixture() {
    const [admin, oracle, minter, verifier, user, attacker] = await ethers.getSigners();

    const ClimateActionNFT = await ethers.getContractFactory('ClimateActionNFT');
    const nft = await ClimateActionNFT.deploy(oracle.address, minter.address);
    await nft.waitForDeployment();

    const VERIFIER_ROLE = await nft.VERIFIER_ROLE();
    await nft.connect(admin).grantVerifierRole(verifier.address);

    return { nft, admin, oracle, minter, verifier, user, attacker };
  }

  // ── updateOffset on non-existent token ──────────────────────────────────

  it('updateOffset() reverts for non-existent tokenId', async function () {
    // VULNERABILITY FIXED: updateOffset() previously wrote to carbonRecords for any
    // tokenId without checking existence, allowing state corruption before a mint.
    const { nft, oracle } = await loadFixture(climateFixture);

    const PHANTOM_TOKEN_ID = 9999;
    await expect(
      nft.connect(oracle).updateOffset(PHANTOM_TOKEN_ID, 500, 100)
    ).to.be.revertedWithCustomError(nft, 'TokenDoesNotExist').withArgs(PHANTOM_TOKEN_ID);
  });

  it('updateOffset() succeeds on a live token', async function () {
    const { nft, oracle, minter, user } = await loadFixture(climateFixture);

    // Mint a token first
    const tx = await nft.connect(minter).mint(user.address, 100, 2025, 50);
    const receipt = await tx.wait();
    const tokenId = 1n;

    await expect(
      nft.connect(oracle).updateOffset(tokenId, 200, 75)
    ).to.not.be.reverted;
  });

  // ── verify on non-existent token ─────────────────────────────────────────

  it('verify() reverts for non-existent tokenId', async function () {
    // VULNERABILITY FIXED: verify() previously allowed setting the verified flag on
    // any tokenId without checking existence, pre-populating a future minted token.
    const { nft, verifier } = await loadFixture(climateFixture);

    const PHANTOM_TOKEN_ID = 42;
    await expect(
      nft.connect(verifier).verify(PHANTOM_TOKEN_ID)
    ).to.be.revertedWithCustomError(nft, 'TokenDoesNotExist').withArgs(PHANTOM_TOKEN_ID);
  });

  it('verify() succeeds on a live unverified token', async function () {
    const { nft, minter, oracle, verifier, user } = await loadFixture(climateFixture);

    await nft.connect(minter).mint(user.address, 100, 2025, 50);
    const tokenId = 1n;

    await expect(nft.connect(verifier).verify(tokenId)).to.not.be.reverted;

    const rec = await nft.carbonRecords(tokenId);
    expect(rec.verified).to.be.true;
  });

  it('verify() reverts if called again on already-verified token', async function () {
    const { nft, minter, verifier, user } = await loadFixture(climateFixture);

    await nft.connect(minter).mint(user.address, 100, 2025, 50);
    const tokenId = 1n;
    await nft.connect(verifier).verify(tokenId);

    await expect(
      nft.connect(verifier).verify(tokenId)
    ).to.be.revertedWithCustomError(nft, 'AlreadyVerified').withArgs(tokenId);
  });

  it('updateOffset() reverts on a retired (burned) token', async function () {
    const { nft, minter, oracle, user } = await loadFixture(climateFixture);

    await nft.connect(minter).mint(user.address, 100, 2025, 50);
    const tokenId = 1n;
    await nft.connect(user).retire(tokenId);

    // After retire the token is burned, _exists() returns false
    await expect(
      nft.connect(oracle).updateOffset(tokenId, 200, 75)
    ).to.be.revertedWithCustomError(nft, 'TokenDoesNotExist');
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// StationAdoptionPool Hardening
// ─────────────────────────────────────────────────────────────────────────────

describe('StationAdoptionPool — hardening sweep', function () {
  const TARGET = ethers.parseEther('1000');
  const REGION = ethers.keccak256(ethers.toUtf8Bytes('test:region'));
  const STATION = ethers.keccak256(ethers.toUtf8Bytes('test:station-001'));
  const REV_SHARE_BPS = 2000; // 20%

  async function poolFixture() {
    const [admin, sponsor1, sponsor2, oracle] = await ethers.getSigners();

    const wrfToken = await deployERC20('WRF Token', 'WRF', admin);

    const Certificate = await ethers.getContractFactory('StationAdoptionCertificateNFT');
    const certNFT = await Certificate.deploy();
    await certNFT.waitForDeployment();

    const Pool = await ethers.getContractFactory('StationAdoptionPool');
    const pool = await Pool.deploy(await wrfToken.getAddress(), await certNFT.getAddress());
    await pool.waitForDeployment();

    // Grant MINTER_ROLE on certNFT to the pool
    const minterRole = await certNFT.MINTER_ROLE();
    await certNFT.connect(admin).grantRole(minterRole, await pool.getAddress());

    // Grant ORACLE_ROLE on pool to oracle signer
    const oracleRole = await pool.ORACLE_ROLE();
    await pool.connect(admin).grantRole(oracleRole, oracle.address);

    for (const sponsor of [sponsor1, sponsor2]) {
      await wrfToken.mint(sponsor.address, ethers.parseEther('5000'));
      await wrfToken.connect(sponsor).approve(await pool.getAddress(), ethers.parseEther('5000'));
    }

    return { admin, sponsor1, sponsor2, oracle, wrfToken, certNFT, pool };
  }

  async function createProject(pool) {
    const tx = await pool.createProject(REGION, 'Test Region', TARGET, REV_SHARE_BPS, 0);
    const receipt = await tx.wait();
    return 1n; // first project ID
  }

  // ── claimableRewards precision fix ───────────────────────────────────────

  it('claimableRewards() returns non-zero for small deposits (precision fix)', async function () {
    // VULNERABILITY FIXED: the original expression divided twice sequentially:
    //   (a * b * c) / d / e
    // which loses up to (d-1) wei in the first division.  The fix combines both
    // denominators: (a * b * c) / (d * e) preserving precision.
    const { pool, sponsor1, oracle } = await loadFixture(poolFixture);

    const projectId = await createProject(pool);

    // Deposit the full target amount from a single sponsor
    await pool.connect(sponsor1).deposit(projectId, TARGET);

    // Finalize deployment
    await pool.finalizeDeployment(projectId, STATION, Math.floor(Date.now() / 1000) - 100);

    // Record 1 WRF of data rewards
    const dataRewards = ethers.parseEther('1');
    await pool.connect(oracle).recordAdoptionRewards(projectId, dataRewards);

    // sponsor1 owns 100% of the pool → expected claimable = dataRewards * REV_SHARE_BPS / 10000
    const expected = (dataRewards * BigInt(REV_SHARE_BPS)) / 10000n;
    const actual = await pool.claimableRewards(projectId, sponsor1.address);

    expect(actual).to.equal(expected);
  });

  it('claimableRewards() is consistent with pro-rata split between two sponsors', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(poolFixture);

    const projectId = await createProject(pool);

    const dep1 = ethers.parseEther('300');
    const dep2 = ethers.parseEther('700');
    await pool.connect(sponsor1).deposit(projectId, dep1);
    await pool.connect(sponsor2).deposit(projectId, dep2);

    await pool.finalizeDeployment(projectId, STATION, Math.floor(Date.now() / 1000) - 100);

    const dataRewards = ethers.parseEther('10');
    await pool.connect(oracle).recordAdoptionRewards(projectId, dataRewards);

    const totalDeposited = dep1 + dep2; // = 1000 ETH

    const expected1 = (dep1 * dataRewards * BigInt(REV_SHARE_BPS)) / (totalDeposited * 10000n);
    const expected2 = (dep2 * dataRewards * BigInt(REV_SHARE_BPS)) / (totalDeposited * 10000n);

    const actual1 = await pool.claimableRewards(projectId, sponsor1.address);
    const actual2 = await pool.claimableRewards(projectId, sponsor2.address);

    expect(actual1).to.equal(expected1);
    expect(actual2).to.equal(expected2);
  });

  // ── ProjectAlreadyActive error naming ────────────────────────────────────

  it('deposit() reverts with ProjectAlreadyActive after station is live', async function () {
    // VULNERABILITY FIXED: the original code threw ProjectNotActive when a project
    // WAS active, which is a misleading error name. Now throws ProjectAlreadyActive.
    const { pool, sponsor1 } = await loadFixture(poolFixture);

    const projectId = await createProject(pool);

    // Fund and activate
    await pool.connect(sponsor1).deposit(projectId, TARGET);
    await pool.finalizeDeployment(projectId, STATION, Math.floor(Date.now() / 1000) - 100);

    // Attempt deposit after activation
    await expect(
      pool.connect(sponsor1).deposit(projectId, ethers.parseEther('1'))
    ).to.be.revertedWithCustomError(pool, 'ProjectAlreadyActive');
  });

  it('finalizeDeployment() reverts with ProjectAlreadyActive on double-finalize', async function () {
    const { pool, sponsor1 } = await loadFixture(poolFixture);
    const projectId = await createProject(pool);

    await pool.connect(sponsor1).deposit(projectId, TARGET);
    const ts = Math.floor(Date.now() / 1000) - 100;
    await pool.finalizeDeployment(projectId, STATION, ts);

    await expect(
      pool.finalizeDeployment(projectId, STATION, ts)
    ).to.be.revertedWithCustomError(pool, 'ProjectAlreadyActive');
  });

  it('claimableRewards() returns 0 before any rewards are recorded', async function () {
    const { pool, sponsor1, sponsor2 } = await loadFixture(poolFixture);
    const projectId = await createProject(pool);
    await pool.connect(sponsor1).deposit(projectId, TARGET);

    const result = await pool.claimableRewards(projectId, sponsor1.address);
    expect(result).to.equal(0n);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// StationAdoptionCertificateNFT Baseline
// ─────────────────────────────────────────────────────────────────────────────

describe('StationAdoptionCertificateNFT — hardening sweep', function () {
  async function certFixture() {
    const [admin, minterAccount, sponsor] = await ethers.getSigners();

    const Certificate = await ethers.getContractFactory('StationAdoptionCertificateNFT');
    const certNFT = await Certificate.deploy();
    await certNFT.waitForDeployment();

    const minterRole = await certNFT.MINTER_ROLE();
    await certNFT.connect(admin).grantRole(minterRole, minterAccount.address);

    return { certNFT, admin, minterAccount, sponsor };
  }

  it('mintCertificate() reverts for zero sponsor address', async function () {
    const { certNFT, minterAccount } = await loadFixture(certFixture);

    await expect(
      certNFT.connect(minterAccount).mintCertificate(
        ethers.ZeroAddress,
        1n,
        ethers.keccak256(ethers.toUtf8Bytes('r')),
        ethers.keccak256(ethers.toUtf8Bytes('s')),
        ethers.parseEther('100'),
        Math.floor(Date.now() / 1000) - 60,
        0n
      )
    ).to.be.revertedWithCustomError(certNFT, 'ZeroAddress');
  });

  it('mintCertificate() reverts for zero sponsored amount', async function () {
    const { certNFT, minterAccount, sponsor } = await loadFixture(certFixture);

    await expect(
      certNFT.connect(minterAccount).mintCertificate(
        sponsor.address,
        1n,
        ethers.keccak256(ethers.toUtf8Bytes('r')),
        ethers.keccak256(ethers.toUtf8Bytes('s')),
        0n,
        Math.floor(Date.now() / 1000) - 60,
        0n
      )
    ).to.be.revertedWithCustomError(certNFT, 'ZeroAmount');
  });

  it('mintCertificate() is restricted to MINTER_ROLE', async function () {
    const { certNFT, sponsor } = await loadFixture(certFixture);

    await expect(
      certNFT.connect(sponsor).mintCertificate(
        sponsor.address,
        1n,
        ethers.keccak256(ethers.toUtf8Bytes('r')),
        ethers.keccak256(ethers.toUtf8Bytes('s')),
        ethers.parseEther('1'),
        Math.floor(Date.now() / 1000) - 60,
        0n
      )
    ).to.be.revertedWithCustomError(certNFT, 'AccessControlUnauthorizedAccount').withArgs(sponsor.address, await certNFT.MINTER_ROLE());
  });

  it('mintCertificate() mints token to sponsor and stores data correctly', async function () {
    const { certNFT, minterAccount, sponsor } = await loadFixture(certFixture);

    const regionId = ethers.keccak256(ethers.toUtf8Bytes('patagonia'));
    const stationId = ethers.keccak256(ethers.toUtf8Bytes('station-001'));
    const projectId = 5n;
    const amount = ethers.parseEther('250');
    const depTs = BigInt(Math.floor(Date.now() / 1000) - 3600);
    const rewards = ethers.parseEther('7');

    const tx = await certNFT
      .connect(minterAccount)
      .mintCertificate(sponsor.address, projectId, regionId, stationId, amount, depTs, rewards);
    await tx.wait();

    const tokenId = 1n;
    expect(await certNFT.ownerOf(tokenId)).to.equal(sponsor.address);

    const data = await certNFT.certificateData(tokenId);
    expect(data.sponsor).to.equal(sponsor.address);
    expect(data.projectId).to.equal(projectId);
    expect(data.sponsoredAmount).to.equal(amount);
    expect(data.cumulativeDataRewards).to.equal(rewards);
  });

  it('certificateData() reverts for unknown tokenId', async function () {
    const { certNFT } = await loadFixture(certFixture);

    await expect(certNFT.certificateData(999n)).to.be.revertedWithCustomError(
      certNFT,
      'UnknownCertificate'
    );
  });
});
