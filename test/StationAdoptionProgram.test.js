'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');
const { anyValue } = require('@nomicfoundation/hardhat-chai-matchers/withArgs');

describe('StationAdoptionProgram', function () {
  const TARGET_AMOUNT = ethers.parseEther('1000');
  const FIRST_DEPOSIT = ethers.parseEther('400');
  const SECOND_DEPOSIT = ethers.parseEther('600');
  const REVENUE_SHARE_BPS = 2500; // 25%
  const REGION_ID = ethers.keccak256(ethers.toUtf8Bytes('data-desert:patagonia'));
  const STATION_ID = ethers.keccak256(ethers.toUtf8Bytes('station-patagonia-001'));
  const NO_CLIFF = 0;
  const CLIFF_30_DAYS = 30 * 24 * 3600;

  async function deployFixture() {
    const [admin, sponsor1, sponsor2, oracle] = await ethers.getSigners();

    const Token = await ethers.getContractFactory('MockERC20');
    const wrfToken = await Token.deploy('WRF Token', 'WRF', 18);
    await wrfToken.waitForDeployment();

    const Certificate = await ethers.getContractFactory('StationAdoptionCertificateNFT');
    const certificateNFT = await Certificate.deploy();
    await certificateNFT.waitForDeployment();

    const Pool = await ethers.getContractFactory('StationAdoptionPool');
    const pool = await Pool.deploy(await wrfToken.getAddress(), await certificateNFT.getAddress());
    await pool.waitForDeployment();

    const minterRole = await certificateNFT.MINTER_ROLE();
    await certificateNFT.connect(admin).grantRole(minterRole, await pool.getAddress());

    const oracleRole = await pool.ORACLE_ROLE();
    await pool.connect(admin).grantRole(oracleRole, oracle.address);

    for (const sponsor of [sponsor1, sponsor2]) {
      await wrfToken.mint(sponsor.address, ethers.parseEther('2000'));
      await wrfToken.connect(sponsor).approve(await pool.getAddress(), ethers.parseEther('2000'));
    }

    // Fund the pool contract with reward tokens so claimRewards can transfer out.
    await wrfToken.mint(await pool.getAddress(), ethers.parseEther('10000'));

    return { admin, sponsor1, sponsor2, oracle, wrfToken, certificateNFT, pool };
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  async function createProject(pool, cliffDuration = NO_CLIFF) {
    const tx = await pool.createProject(
      REGION_ID,
      'Patagonia data desert',
      TARGET_AMOUNT,
      REVENUE_SHARE_BPS,
      cliffDuration,
    );
    await tx.wait();
    return 1n;
  }

  async function fundAndActivate(pool, sponsor1, sponsor2, oracle) {
    const projectId = await createProject(pool);
    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    const now = BigInt(await time.latest());
    await pool.finalizeDeployment(projectId, STATION_ID, now);
    return projectId;
  }

  // ── 1. Deposit ───────────────────────────────────────────────────────────────

  it('tracks funding and marks a project funded at threshold', async function () {
    const { pool, sponsor1, sponsor2 } = await loadFixture(deployFixture);

    const projectId = await createProject(pool);

    await expect(pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT))
      .to.emit(pool, 'AdoptionDeposited')
      .withArgs(projectId, sponsor1.address, FIRST_DEPOSIT, FIRST_DEPOSIT);

    await expect(pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT))
      .to.emit(pool, 'ProjectFunded')
      .withArgs(projectId, TARGET_AMOUNT);

    const project = await pool.getProject(projectId);
    expect(project.regionId).to.equal(REGION_ID);
    expect(project.totalDeposited).to.equal(TARGET_AMOUNT);
    expect(project.funded).to.equal(true);
    expect(await pool.getTopSponsor(projectId)).to.deep.equal([sponsor2.address, SECOND_DEPOSIT]);
  });

  it('rejects zero-amount deposit', async function () {
    const { pool } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);
    await expect(pool.deposit(projectId, 0)).to.be.revertedWithCustomError(pool, 'ZeroAmount');
  });

  it('rejects deposit into an active project', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);
    const projectId = await fundAndActivate(pool, sponsor1, sponsor2, oracle);
    await expect(pool.connect(sponsor1).deposit(projectId, ethers.parseEther('10')))
      .to.be.revertedWithCustomError(pool, 'ProjectAlreadyActive');
  });

  it('rejects deposit into a nonexistent project', async function () {
    const { pool, sponsor1 } = await loadFixture(deployFixture);
    await expect(pool.connect(sponsor1).deposit(99, FIRST_DEPOSIT))
      .to.be.revertedWithCustomError(pool, 'ProjectNotFound');
  });

  // ── 2. Withdrawal ────────────────────────────────────────────────────────────

  it('allows a sponsor to withdraw deposit before funding threshold', async function () {
    const { pool, wrfToken, sponsor1 } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);

    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    const before = await wrfToken.balanceOf(sponsor1.address);

    await expect(pool.connect(sponsor1).withdraw(projectId))
      .to.emit(pool, 'DepositWithdrawn')
      .withArgs(projectId, sponsor1.address, FIRST_DEPOSIT);

    const after = await wrfToken.balanceOf(sponsor1.address);
    expect(after - before).to.equal(FIRST_DEPOSIT);

    expect(await pool.sponsorDeposits(projectId, sponsor1.address)).to.equal(0n);
  });

  it('blocks withdrawal once project is funded', async function () {
    const { pool, sponsor1, sponsor2 } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);

    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);

    await expect(pool.connect(sponsor1).withdraw(projectId))
      .to.be.revertedWithCustomError(pool, 'ProjectAlreadyFunded');
  });

  it('blocks withdrawal when sponsor has no deposit', async function () {
    const { pool, sponsor1 } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);
    await expect(pool.connect(sponsor1).withdraw(projectId))
      .to.be.revertedWithCustomError(pool, 'NoDeposit');
  });

  // ── 3. Attestation / oracle ──────────────────────────────────────────────────

  it('records oracle attestation and updates cumulative rewards', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);
    const projectId = await fundAndActivate(pool, sponsor1, sponsor2, oracle);

    await expect(pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100')))
      .to.emit(pool, 'AdoptionRewardsRecorded')
      .withArgs(projectId, ethers.parseEther('100'), ethers.parseEther('100'));

    const project = await pool.getProject(projectId);
    expect(project.cumulativeDataRewards).to.equal(ethers.parseEther('100'));
  });

  it('rejects oracle attestation from non-oracle account', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);
    const projectId = await fundAndActivate(pool, sponsor1, sponsor2, oracle);

    await expect(pool.connect(sponsor1).recordAdoptionRewards(projectId, ethers.parseEther('10')))
      .to.be.revertedWithCustomError(pool, 'AccessControlUnauthorizedAccount');
  });

  it('rejects oracle attestation on inactive project', async function () {
    const { pool, oracle } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);
    await expect(pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('10')))
      .to.be.revertedWithCustomError(pool, 'ProjectNotActive');
  });

  // ── 4. Yield distribution ────────────────────────────────────────────────────

  it('claimableRewards is proportional to deposit share', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);

    const projectId = await createProject(pool);
    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    const now = BigInt(await time.latest());
    await pool.finalizeDeployment(projectId, STATION_ID, now);

    await pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100'));

    const s1Claimable = await pool.claimableRewards(projectId, sponsor1.address);
    const s2Claimable = await pool.claimableRewards(projectId, sponsor2.address);

    // Sponsor1: 400/1000 * 100 * 25% = 10 WRF
    // Sponsor2: 600/1000 * 100 * 25% = 15 WRF
    expect(s1Claimable).to.equal(ethers.parseEther('10'));
    expect(s2Claimable).to.equal(ethers.parseEther('15'));
  });

  it('claimRewards transfers yield and reduces claimable to zero', async function () {
    const { pool, wrfToken, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);

    const projectId = await createProject(pool);
    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    const now = BigInt(await time.latest());
    await pool.finalizeDeployment(projectId, STATION_ID, now);
    await pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100'));

    const before = await wrfToken.balanceOf(sponsor1.address);

    await expect(pool.connect(sponsor1).claimRewards(projectId))
      .to.emit(pool, 'RewardsClaimed')
      .withArgs(projectId, sponsor1.address, ethers.parseEther('10'));

    const after = await wrfToken.balanceOf(sponsor1.address);
    expect(after - before).to.equal(ethers.parseEther('10'));

    // Nothing left to claim.
    expect(await pool.claimableRewards(projectId, sponsor1.address)).to.equal(0n);
  });

  it('claimRewards only pays newly accrued rewards on successive calls', async function () {
    const { pool, wrfToken, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);

    const projectId = await createProject(pool);
    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    const now = BigInt(await time.latest());
    await pool.finalizeDeployment(projectId, STATION_ID, now);

    await pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100'));
    await pool.connect(sponsor1).claimRewards(projectId); // claims 10 WRF

    // Oracle records another 100 WRF of rewards.
    await pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100'));
    // Sponsor1 should only receive the incremental 10 WRF, not 20.
    await expect(pool.connect(sponsor1).claimRewards(projectId))
      .to.emit(pool, 'RewardsClaimed')
      .withArgs(projectId, sponsor1.address, ethers.parseEther('10'));
  });

  it('claimRewards reverts when nothing is claimable', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);
    const projectId = await fundAndActivate(pool, sponsor1, sponsor2, oracle);

    await expect(pool.connect(sponsor1).claimRewards(projectId))
      .to.be.revertedWithCustomError(pool, 'NothingToClaim');
  });

  // ── 5. Vesting cliff ─────────────────────────────────────────────────────────

  it('blocks claimRewards before vesting cliff elapses', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);

    const projectId = await createProject(pool, CLIFF_30_DAYS);
    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    const now = BigInt(await time.latest());
    await pool.finalizeDeployment(projectId, STATION_ID, now);
    await pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100'));

    await expect(pool.connect(sponsor1).claimRewards(projectId))
      .to.be.revertedWithCustomError(pool, 'CliffNotReached');
  });

  it('allows claimRewards after vesting cliff has passed', async function () {
    const { pool, sponsor1, sponsor2, oracle } = await loadFixture(deployFixture);

    const projectId = await createProject(pool, CLIFF_30_DAYS);
    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    const now = BigInt(await time.latest());
    await pool.finalizeDeployment(projectId, STATION_ID, now);
    await pool.connect(oracle).recordAdoptionRewards(projectId, ethers.parseEther('100'));

    // Advance time past the cliff.
    await time.increase(CLIFF_30_DAYS + 1);

    await expect(pool.connect(sponsor1).claimRewards(projectId))
      .to.emit(pool, 'RewardsClaimed')
      .withArgs(projectId, sponsor1.address, ethers.parseEther('10'));
  });

  // ── 6. Certificate NFT ────────────────────────────────────────────────────────

  it('mints a shareable adoption certificate with on-chain metadata', async function () {
    const { pool, certificateNFT, sponsor1, sponsor2 } = await loadFixture(deployFixture);

    const projectId = await createProject(pool);

    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    await pool.finalizeDeployment(projectId, STATION_ID, await timeNow());
    await pool.recordAdoptionRewards(projectId, ethers.parseEther('100'));

    await expect(pool.connect(sponsor1).claimCertificate(projectId))
      .to.emit(pool, 'CertificateClaimed')
      .withArgs(projectId, sponsor1.address, anyValue);

    const tokenId = 1n;
    const cert = await certificateNFT.certificateData(tokenId);
    expect(cert.sponsor).to.equal(sponsor1.address);
    expect(cert.projectId).to.equal(projectId);
    expect(cert.regionId).to.equal(REGION_ID);
    expect(cert.stationId).to.equal(STATION_ID);
    expect(cert.sponsoredAmount).to.equal(FIRST_DEPOSIT);

    const uri = await certificateNFT.tokenURI(tokenId);
    expect(uri).to.match(/^data:application\/json;base64,/);
    expect(Buffer.from(uri.split(',')[1], 'base64').toString('utf8')).to.include('Station Adoption Certificate #1');
  });

  it('rejects double certificate claim from the same sponsor', async function () {
    const { pool, sponsor1, sponsor2 } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);

    await pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT);
    await pool.connect(sponsor2).deposit(projectId, SECOND_DEPOSIT);
    await pool.finalizeDeployment(projectId, STATION_ID, await timeNow());

    await pool.connect(sponsor1).claimCertificate(projectId);
    await expect(pool.connect(sponsor1).claimCertificate(projectId))
      .to.be.revertedWithCustomError(pool, 'AlreadyClaimed');
  });

  // ── 7. Pause / access control ─────────────────────────────────────────────────

  it('pause blocks deposit', async function () {
    const { pool, admin, sponsor1 } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);

    await pool.connect(admin).pause();
    await expect(pool.connect(sponsor1).deposit(projectId, FIRST_DEPOSIT))
      .to.be.revertedWithCustomError(pool, 'EnforcedPause');
  });

  it('finalizeDeployment requires funded project', async function () {
    const { pool } = await loadFixture(deployFixture);
    const projectId = await createProject(pool);
    await expect(pool.finalizeDeployment(projectId, STATION_ID, await timeNow()))
      .to.be.revertedWithCustomError(pool, 'ProjectNotFunded');
  });

  // ── Helpers ───────────────────────────────────────────────────────────────────

  async function timeNow() {
    const block = await ethers.provider.getBlock('latest');
    return BigInt(block.timestamp);
  }
});
