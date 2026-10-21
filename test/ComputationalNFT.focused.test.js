'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('ComputationalNFT — focused coverage', function () {
  async function deployFixture() {
    const [owner, user, provider, outsider, weatherOracle] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const wrfToken = await MockERC20.deploy('WRF', 'WRF', 18);

    const ComputationalNFT = await ethers.getContractFactory('ComputationalNFT');
    const nft = await ComputationalNFT.deploy(
      await wrfToken.getAddress(),
      weatherOracle.address
    );

    const minimumStake = ethers.parseEther('100');
    await wrfToken.mint(owner.address, minimumStake * 20n);
    await wrfToken.mint(user.address, minimumStake * 20n);

    return {
      owner,
      user,
      provider,
      outsider,
      weatherOracle,
      wrfToken,
      nft,
      minimumStake,
    };
  }

  async function createJob(nft, wrfToken, creator, minimumStake) {
    const jobArgs = [
      0n, // ModelType.WeatherForecast
      'WRF-GFS-Ensemble',
      ethers.toUtf8Bytes('inputs-v1'),
      'cpu=4|ram=16GB',
      3600n,
      minimumStake,
      'ipfs://metadata/computational-nft.json',
    ];
    await wrfToken.connect(creator).approve(await nft.getAddress(), minimumStake * 2n);
    await nft.connect(creator).createComputeJob(...jobArgs);
    return { jobId: 1n, jobArgs };
  }

  it('rejects invalid constructor wiring inputs', async function () {
    const { wrfToken, weatherOracle } = await loadFixture(deployFixture);

    const ComputationalNFT = await ethers.getContractFactory('ComputationalNFT');
    await expect(
      ComputationalNFT.deploy(ethers.ZeroAddress, weatherOracle.address)
    ).to.be.revertedWith('ComputationalNFT: Invalid WRF token address');
    await expect(
      ComputationalNFT.deploy(await wrfToken.getAddress(), ethers.ZeroAddress)
    ).to.be.revertedWith('ComputationalNFT: Invalid weather oracle address');
  });

  it('enforces registerComputeProvider ownership and staking guardrails', async function () {
    const { owner, provider, outsider, nft, wrfToken, minimumStake } = await loadFixture(deployFixture);
    await wrfToken.approve(await nft.getAddress(), minimumStake * 2n);
    await expect(
      nft.connect(outsider).registerComputeProvider(provider.address, 'hw-spec', minimumStake)
    ).to.be.revertedWithCustomError(nft, 'OwnableUnauthorizedAccount').withArgs(outsider.address);

    await expect(
      nft.connect(owner).registerComputeProvider(
        provider.address,
        'hw-spec',
        ethers.parseEther('1')
      )
    ).to.be.revertedWith('ComputationalNFT: Insufficient stake');

    await expect(
      nft.connect(owner).registerComputeProvider(
        provider.address,
        'hw-spec',
        minimumStake
      )
    ).to.not.be.reverted;

    expect(await nft.hasRole(await nft.COMPUTE_PROVIDER_ROLE(), provider.address)).to.equal(true);

    const stats = await nft.getProviderStats(provider.address);
    expect(stats[0]).to.equal(true);
    expect(stats[4]).to.equal(minimumStake);
  });

  it('guards job creation against invalid and duplicate inputs', async function () {
    const { user, nft, wrfToken, minimumStake } = await loadFixture(deployFixture);
    await wrfToken.connect(user).approve(await nft.getAddress(), minimumStake * 3n);

    await expect(
      nft.connect(user).createComputeJob(
        0n,
        'unsupported-model',
        ethers.toUtf8Bytes('inputs-v1'),
        'cpu=4',
        3600n,
        minimumStake,
        'ipfs://metadata/first.json'
      )
    ).to.be.revertedWith('ComputationalNFT: Model not supported');

    await expect(
      nft.connect(user).createComputeJob(
        0n,
        'WRF-GFS-Ensemble',
        '0x',
        'cpu=4',
        3600n,
        minimumStake,
        'ipfs://metadata/first.json'
      )
    ).to.be.revertedWith('ComputationalNFT: Invalid input data');

    await nft.connect(user).createComputeJob(
      0n,
      'WRF-GFS-Ensemble',
      ethers.toUtf8Bytes('inputs-v1'),
      'cpu=4',
      3600n,
      minimumStake,
      'ipfs://metadata/first.json'
    );

    await expect(
      nft.connect(user).createComputeJob(
        0n,
        'WRF-GFS-Ensemble',
        ethers.toUtf8Bytes('inputs-v1'),
        'cpu=4',
        3600n,
        minimumStake,
        'ipfs://metadata/second.json'
      )
    ).to.be.revertedWith('ComputationalNFT: Duplicate computation');
  });

  it('requires authorized provider and valid status/hash for execution', async function () {
    const { owner, user, provider, outsider, nft, wrfToken, minimumStake } = await loadFixture(deployFixture);

    await wrfToken.approve(await nft.getAddress(), minimumStake * 3n);
    await nft.connect(owner).registerComputeProvider(provider.address, 'compute-node', minimumStake * 2n);
    const { jobId } = await createJob(nft, wrfToken, user, minimumStake);

    await expect(
      nft.connect(outsider).executeComputeJob(
        jobId,
        ethers.randomBytes(64),
        '0x' + '11'.repeat(64)
      )
    ).to.be.revertedWith('ComputationalNFT: Not authorized or paused provider');

    await expect(
      nft.connect(provider).executeComputeJob(
        jobId,
        ethers.randomBytes(64),
        ''
      )
    ).to.be.revertedWith('ComputationalNFT: Invalid result hash');

    await nft.connect(provider).executeComputeJob(
      jobId,
      ethers.randomBytes(64),
      '0x' + '11'.repeat(64)
    );

    const [, , status] = await nft.getComputeJob(jobId);
    expect(status).to.equal(3n);

    await expect(
      nft.connect(provider).executeComputeJob(
        jobId,
        ethers.randomBytes(64),
        '0x' + '22'.repeat(64)
      )
    ).to.be.revertedWith('ComputationalNFT: Job not available');
  });

  it('enforces owner-only pause and provider pause-flag execution gate', async function () {
    const { owner, provider, outsider, user, nft, wrfToken, minimumStake } = await loadFixture(deployFixture);

    await wrfToken.approve(await nft.getAddress(), minimumStake * 3n);
    await nft.connect(owner).registerComputeProvider(provider.address, 'compute-node', minimumStake * 2n);
    const { jobId } = await createJob(nft, wrfToken, user, minimumStake);

    await expect(
      nft.connect(outsider).pauseProvider(provider.address)
    ).to.be.revertedWithCustomError(nft, 'OwnableUnauthorizedAccount').withArgs(outsider.address);

    await nft.connect(owner).pauseProvider(provider.address);

    await expect(
      nft.connect(provider).executeComputeJob(
        jobId,
        ethers.randomBytes(64),
        '0x' + '33'.repeat(64)
      )
    ).to.be.revertedWith('ComputationalNFT: Not authorized or paused provider');
  });

  it('restricts weather data integration to oracle role and hard station bounds', async function () {
    const { owner, weatherOracle, user, outsider, nft, wrfToken, minimumStake } = await loadFixture(deployFixture);
    await wrfToken.approve(await nft.getAddress(), minimumStake * 3n);
    const { jobId } = await createJob(nft, wrfToken, user, minimumStake);

    // A single valid station id, so the role check is the only thing that can
    // reject these calls -- an empty array would trip the "no stations" guard
    // on the next line instead and prove nothing about the role.
    const oneStation = [ethers.keccak256(ethers.toUtf8Bytes('station-0'))];

    await expect(
      nft.connect(outsider).integrateWeatherData(jobId, oneStation, 1n)
    ).to.be.revertedWithCustomError(nft, 'AccessControlUnauthorizedAccount');

    await expect(
      nft.connect(owner).integrateWeatherData(jobId, oneStation, 0n)
    ).to.be.revertedWithCustomError(nft, 'AccessControlUnauthorizedAccount'); // owner does not hold WEATHER_ORACLE_ROLE by default

    const tooManyStations = Array.from({ length: 11 }, (_, i) =>
      ethers.keccak256(ethers.toUtf8Bytes(`station-${i}`))
    );
    await expect(
      nft.connect(weatherOracle).integrateWeatherData(jobId, tooManyStations, 0n)
    ).to.be.revertedWith('ComputationalNFT: Too many weather stations');

    await expect(
      nft.connect(weatherOracle).integrateWeatherData(jobId, [], 0n)
    ).to.be.revertedWith('ComputationalNFT: No weather stations provided');
  });

  it('guards quality scoring updates with role and bounds', async function () {
    const { owner, outsider, user, nft, wrfToken, minimumStake } = await loadFixture(deployFixture);
    await wrfToken.approve(await nft.getAddress(), minimumStake * 3n);
    const { jobId } = await createJob(nft, wrfToken, user, minimumStake);

    // updateQualityScore stacks onlyRole(VALIDATOR_ROLE) jobExists(tokenId)
    // validQualityScore(newQualityScore) — ComputationalNFT.sol:949-953. jobId was
    // just created and 88 is in range, so both trailing modifiers pass and the role
    // gate is the only thing that can reject this call.
    await expect(
      nft.connect(outsider).updateQualityScore(jobId, 88n, 'peer review')
    )
      .to.be.revertedWithCustomError(nft, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await nft.VALIDATOR_ROLE());

    await expect(
      nft.connect(owner).updateQualityScore(jobId, 101n, 'invalid')
    ).to.be.revertedWith('ComputationalNFT: Quality score must be 0-100');
  });
});
