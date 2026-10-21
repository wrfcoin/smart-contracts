'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('coverage: medium-risk uncovered contract guard coverage (tier 3)', function () {
  it('ComputationalNFT constructor rejects invalid WRF token address', async function () {
    const MockWeatherOracle = await ethers.getContractFactory('MockWeatherOracle');
    const mockWeatherOracle = await MockWeatherOracle.deploy();
    const ComputationalNFT = await ethers.getContractFactory('ComputationalNFT');

    await expect(
      ComputationalNFT.deploy(ethers.ZeroAddress, await mockWeatherOracle.getAddress())
    ).to.be.revertedWith('ComputationalNFT: Invalid WRF token address');
  });

  it('EnterpriseNFTMarketplace create listing requires owner NFT control', async function () {
    const [seller, buyer] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const wrf = await MockERC20.deploy('WRF Token', 'WRF', 18);
    const CryptographicSecurityModule = await ethers.getContractFactory('CryptographicSecurityModule');
    const securityModule = await CryptographicSecurityModule.deploy();
    const EnterpriseNFTMarketplace = await ethers.getContractFactory('EnterpriseNFTMarketplace');
    const market = await EnterpriseNFTMarketplace.deploy(await wrf.getAddress(), await securityModule.getAddress());

    const MockERC721 = await ethers.getContractFactory('MockERC721');
    const nft = await MockERC721.deploy('MockNFT', 'MNFT');
    await nft['mint(address,uint256)'](await seller.getAddress(), 1n);

    await expect(
      market.connect(buyer).createSecureFixedPriceListing(
        await nft.getAddress(),
        1n,
        1n,
        0,
        ethers.ZeroAddress,
        3600n,
        0,
        [],
        ethers.ZeroHash
      )
    ).to.be.revertedWith('ENM: Not the owner');
  });

  it('LegacyMigrationHelper constructor rejects invalid decentralized fair launch address', async function () {
    const LegacyMigrationHelper = await ethers.getContractFactory('LegacyMigrationHelper');
    await expect(
      LegacyMigrationHelper.deploy(
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        ethers.ZeroAddress
      )
    ).to.be.revertedWith('Invalid decentralized fair launch');
  });

  it('SelectiveIdentityReveal rejects non-oracle verification attempts', async function () {
    const [governance, _, outsider] = await ethers.getSigners();
    const SelectiveIdentityReveal = await ethers.getContractFactory('SelectiveIdentityReveal');
    const sir = await SelectiveIdentityReveal.deploy(await governance.getAddress(), ethers.ZeroAddress);

    await expect(
      sir.connect(outsider).verifyPublication(ethers.ZeroHash, true, 'manual review')
    ).to.be.revertedWith('Only oracle can verify');
  });

  it('SimpleMockEnhancedCarbonCredits createBatch rejects non-positive supply', async function () {
    const SimpleMockEnhancedCarbonCredits = await ethers.getContractFactory('SimpleMockEnhancedCarbonCredits');
    const smec = await SimpleMockEnhancedCarbonCredits.deploy();

    await expect(
      smec.createBatch(0n, '', 0n, '')
    ).to.be.revertedWith('SMEC: Invalid supply amount');
  });

  it('SensorLeaseAgreements constructor rejects invalid treasury', async function () {
    const [admin] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const paymentToken = await MockERC20.deploy('Payment', 'PAY', 18);

    const SensorLeaseAgreements = await ethers.getContractFactory('SensorLeaseAgreements');
    await expect(
      SensorLeaseAgreements.deploy(
        await paymentToken.getAddress(),
        ethers.ZeroAddress,
        await admin.getAddress(),
        await admin.getAddress()
      )
    ).to.be.revertedWith('SensorLease: invalid treasury');
  });

  it('PrivateAnalysisContracts rejects analysis requests with bounty below minimum', async function () {
    const [requester] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const treasury = await MockERC20.deploy('Treasury', 'TR', 18);
    const PrivateAnalysisContracts = await ethers.getContractFactory('PrivateAnalysisContracts');
    const pac = await PrivateAnalysisContracts.deploy(await treasury.getAddress(), await requester.getAddress());

    await expect(
      pac.connect(requester).requestAnalysis(
        'air_quality',
        'ipfs://sample',
        Math.floor((Date.now() / 1000)) + 3600,
        1,
        { value: ethers.parseEther('1') }
      )
    ).to.be.revertedWith('Bounty below minimum');
  });
});
