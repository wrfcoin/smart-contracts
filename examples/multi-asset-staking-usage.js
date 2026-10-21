const { ethers } = require('ethers');

/**
 * MultiAssetStaking Usage Examples
 *
 * This file demonstrates how to integrate and use the MultiAssetStaking contract
 * for weather station registration in WRFCoin's fair launch system.
 *
 * Features demonstrated:
 * - Multi-asset staking (ETH, WBTC, WRF, USDC, USDT)
 * - Cross-chain WBTC staking
 * - Stake rebalancing
 * - Oracle price monitoring
 * - Emergency procedures
 */

// Contract addresses (example - replace with actual deployed addresses)
const CONTRACT_ADDRESSES = {
  MULTI_ASSET_STAKING: '0x...', // MultiAssetStaking contract
  WRF_TOKEN: '0x...', // WRFToken contract
  WBTC_TOKEN: '0x...', // WBTC token contract
  USDC_TOKEN: '0x...', // USDC token contract
  USDT_TOKEN: '0x...', // USDT token contract
};

// Special address for native ETH
const ETH_ADDRESS = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';

// ABI excerpts (in production, import full ABI)
const MULTI_ASSET_STAKING_ABI = [
  'function stakeAsset(address asset, uint256 amount, tuple(uint8 participationType, uint8 geographicZone, uint8 verificationLevel, tuple(bool githubVerified, bool twitterVerified, bool linkedinVerified) social, tuple(uint256 nearbyStationsCount, bool isDensityVerified) density, tuple(bool providesWeatherData, bool providesForecasting, bool providesDataStorage, bool providesValidation) hybridServices) parameters) payable',
  'function withdrawStake(address asset, uint256 amount)',
  'function rebalanceStake(address participant, address fromAsset, address toAsset, uint256 amount)',
  'function convertStakeAsset(address fromAsset, address toAsset, uint256 amount)',
  'function getStakeValueUSD(address participant) view returns (uint256 totalValueUSD, uint256[] breakdown, address[] assets)',
  'function getCollateralizationRatio(address participant) view returns (uint256 ratio, bool meetsMinimum, uint256 requiredStakeUSD, uint256 currentStakeUSD)',
  'function getComprehensiveStakeInfo(address participant) view returns (uint256 totalStakeUSD, uint256 requiredStakeUSD, uint256 collateralizationRatio, bool meetsRequirement, address[] stakedAssets, uint256[] assetAmounts, uint256[] assetValuesUSD)',
  'function getSupportedAssets() view returns (address[] assets, tuple(address tokenAddress, address priceOracle, uint8 decimals, bool isActive, bool isCrossChain, uint256 minStakeAmount, uint256 maxStakeAmount, uint256 concentrationLimit, string symbol, bytes32 bridgeId)[] configs)',
  'function getAssetPrice(address asset) view returns (uint256 priceUSD, uint256 timestamp, bool isStale)',
  'event AssetStaked(address indexed participant, address indexed asset, uint256 amount, uint256 valueUSD, uint256 newTotalStakeUSD)',
  'event StakeRebalanced(address indexed participant, address indexed fromAsset, address indexed toAsset, uint256 fromAmount, uint256 toAmount, uint256 newCollateralizationRatio)',
  'event CrossChainOperationInitiated(bytes32 indexed operationId, address indexed participant, address indexed asset, uint256 amount, bytes32 bridgeId, bool isDeposit)',
];

const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
];

class MultiAssetStakingManager {
  constructor(provider, signer) {
    this.provider = provider;
    this.signer = signer;
    this.contract = new ethers.Contract(
      CONTRACT_ADDRESSES.MULTI_ASSET_STAKING,
      MULTI_ASSET_STAKING_ABI,
      signer
    );
  }

  /**
   * Create default staking parameters for weather station
   */
  createStakeParameters(options = {}) {
    return {
      participationType: options.participationType || 0, // WEATHER_STATION
      geographicZone: options.geographicZone || 0, // DEFAULT_AREA
      verificationLevel: options.verificationLevel || 0, // UNVERIFIED
      social: {
        githubVerified: options.githubVerified || false,
        twitterVerified: options.twitterVerified || false,
        linkedinVerified: options.linkedinVerified || false,
      },
      density: {
        nearbyStationsCount: options.nearbyStationsCount || 2,
        isDensityVerified: options.isDensityVerified || false,
      },
      hybridServices: {
        providesWeatherData: options.providesWeatherData || false,
        providesForecasting: options.providesForecasting || false,
        providesDataStorage: options.providesDataStorage || false,
        providesValidation: options.providesValidation || false,
      },
    };
  }

  /**
   * Stake native ETH
   */
  async stakeETH(ethAmount, parameterOptions = {}) {
    console.log(`🚀 Staking ${ethers.utils.formatEther(ethAmount)} ETH...`);

    const parameters = this.createStakeParameters(parameterOptions);

    try {
      const tx = await this.contract.stakeAsset(
        ETH_ADDRESS,
        ethAmount,
        parameters,
        { value: ethAmount }
      );

      console.log(`📝 Transaction hash: ${tx.hash}`);
      const receipt = await tx.wait();

      console.log(`✅ ETH staking successful! Gas used: ${receipt.gasUsed}`);
      return receipt;
    } catch (error) {
      console.error(`❌ ETH staking failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Stake ERC20 tokens (WRF, USDC, USDT)
   */
  async stakeERC20(tokenAddress, amount, parameterOptions = {}) {
    const tokenContract = new ethers.Contract(
      tokenAddress,
      ERC20_ABI,
      this.signer
    );
    const symbol = await this.getTokenSymbol(tokenAddress);
    const decimals = await this.getTokenDecimals(tokenAddress);

    console.log(
      `🚀 Staking ${ethers.utils.formatUnits(amount, decimals)} ${symbol}...`
    );

    // Check balance
    const balance = await tokenContract.balanceOf(
      await this.signer.getAddress()
    );
    if (balance.lt(amount)) {
      throw new Error(
        `Insufficient ${symbol} balance. Have: ${ethers.utils.formatUnits(balance, decimals)}, Need: ${ethers.utils.formatUnits(amount, decimals)}`
      );
    }

    // Check and set approval
    const allowance = await tokenContract.allowance(
      await this.signer.getAddress(),
      this.contract.address
    );
    if (allowance.lt(amount)) {
      console.log(`📝 Approving ${symbol} spending...`);
      const approveTx = await tokenContract.approve(
        this.contract.address,
        amount
      );
      await approveTx.wait();
      console.log(`✅ ${symbol} approval confirmed`);
    }

    const parameters = this.createStakeParameters(parameterOptions);

    try {
      const tx = await this.contract.stakeAsset(
        tokenAddress,
        amount,
        parameters
      );
      console.log(`📝 Transaction hash: ${tx.hash}`);

      const receipt = await tx.wait();
      console.log(
        `✅ ${symbol} staking successful! Gas used: ${receipt.gasUsed}`
      );

      return receipt;
    } catch (error) {
      console.error(`❌ ${symbol} staking failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Stake WBTC (cross-chain asset)
   */
  async stakeWBTC(wbtcAmount, parameterOptions = {}) {
    console.log(
      `🌉 Initiating cross-chain WBTC staking: ${ethers.utils.formatUnits(wbtcAmount, 8)} WBTC...`
    );

    // WBTC staking requires cross-chain operations
    // This will initiate a cross-chain deposit process
    const receipt = await this.stakeERC20(
      CONTRACT_ADDRESSES.WBTC_TOKEN,
      wbtcAmount,
      parameterOptions
    );

    console.log(
      `⏳ Cross-chain operation initiated. Monitor for completion...`
    );
    return receipt;
  }

  /**
   * Get comprehensive stake information
   */
  async getStakeInfo(participantAddress) {
    console.log(`📊 Getting stake information for ${participantAddress}...`);

    try {
      const info =
        await this.contract.getComprehensiveStakeInfo(participantAddress);

      const stakeInfo = {
        totalStakeUSD: info.totalStakeUSD,
        requiredStakeUSD: info.requiredStakeUSD,
        collateralizationRatio: info.collateralizationRatio,
        meetsRequirement: info.meetsRequirement,
        stakedAssets: info.stakedAssets,
        assetAmounts: info.assetAmounts,
        assetValuesUSD: info.assetValuesUSD,
      };

      console.log(`📈 Stake Summary:`);
      console.log(
        `   Total Stake: $${ethers.utils.formatEther(stakeInfo.totalStakeUSD)}`
      );
      console.log(
        `   Required Stake: $${ethers.utils.formatEther(stakeInfo.requiredStakeUSD)}`
      );
      console.log(
        `   Collateralization Ratio: ${(stakeInfo.collateralizationRatio.toNumber() / 10000).toFixed(2)}%`
      );
      console.log(
        `   Meets Requirement: ${stakeInfo.meetsRequirement ? '✅' : '❌'}`
      );

      for (let i = 0; i < stakeInfo.stakedAssets.length; i++) {
        const asset = stakeInfo.stakedAssets[i];
        const amount = stakeInfo.assetAmounts[i];
        const valueUSD = stakeInfo.assetValuesUSD[i];
        const symbol = await this.getTokenSymbol(asset);
        const decimals = await this.getTokenDecimals(asset);

        console.log(
          `   ${symbol}: ${ethers.utils.formatUnits(amount, decimals)} ($${ethers.utils.formatEther(valueUSD)})`
        );
      }

      return stakeInfo;
    } catch (error) {
      console.error(`❌ Failed to get stake info: ${error.message}`);
      throw error;
    }
  }

  /**
   * Rebalance stake between assets
   */
  async rebalanceStake(fromAsset, toAsset, amount) {
    const fromSymbol = await this.getTokenSymbol(fromAsset);
    const toSymbol = await this.getTokenSymbol(toAsset);
    const decimals = await this.getTokenDecimals(fromAsset);

    console.log(
      `🔄 Rebalancing ${ethers.utils.formatUnits(amount, decimals)} ${fromSymbol} to ${toSymbol}...`
    );

    try {
      const participantAddress = await this.signer.getAddress();
      const tx = await this.contract.rebalanceStake(
        participantAddress,
        fromAsset,
        toAsset,
        amount
      );

      console.log(`📝 Transaction hash: ${tx.hash}`);
      const receipt = await tx.wait();

      console.log(`✅ Rebalancing successful! Gas used: ${receipt.gasUsed}`);
      return receipt;
    } catch (error) {
      console.error(`❌ Rebalancing failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Convert stake between assets
   */
  async convertStakeAsset(fromAsset, toAsset, amount) {
    const fromSymbol = await this.getTokenSymbol(fromAsset);
    const toSymbol = await this.getTokenSymbol(toAsset);
    const decimals = await this.getTokenDecimals(fromAsset);

    console.log(
      `🔄 Converting ${ethers.utils.formatUnits(amount, decimals)} ${fromSymbol} to ${toSymbol}...`
    );

    try {
      const tx = await this.contract.convertStakeAsset(
        fromAsset,
        toAsset,
        amount
      );

      console.log(`📝 Transaction hash: ${tx.hash}`);
      const receipt = await tx.wait();

      console.log(`✅ Conversion successful! Gas used: ${receipt.gasUsed}`);
      return receipt;
    } catch (error) {
      console.error(`❌ Conversion failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Withdraw stake
   */
  async withdrawStake(asset, amount = 0) {
    const symbol = await this.getTokenSymbol(asset);
    const decimals = await this.getTokenDecimals(asset);

    if (amount.eq(0)) {
      console.log(`🏃 Withdrawing all ${symbol} stake...`);
    } else {
      console.log(
        `🏃 Withdrawing ${ethers.utils.formatUnits(amount, decimals)} ${symbol}...`
      );
    }

    try {
      const tx = await this.contract.withdrawStake(asset, amount);

      console.log(`📝 Transaction hash: ${tx.hash}`);
      const receipt = await tx.wait();

      console.log(`✅ Withdrawal successful! Gas used: ${receipt.gasUsed}`);
      return receipt;
    } catch (error) {
      console.error(`❌ Withdrawal failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Monitor asset prices
   */
  async monitorAssetPrices() {
    console.log(`📈 Monitoring asset prices...`);

    const [assets, configs] = await this.contract.getSupportedAssets();

    for (let i = 0; i < assets.length; i++) {
      const asset = assets[i];
      const config = configs[i];

      try {
        const [priceUSD, timestamp, isStale] =
          await this.contract.getAssetPrice(asset);

        console.log(
          `${config.symbol}: $${ethers.utils.formatUnits(priceUSD, 8)} ${isStale ? '⚠️ STALE' : '✅'}`
        );
      } catch (error) {
        console.log(`${config.symbol}: ❌ Price unavailable`);
      }
    }
  }

  /**
   * Check if liquidation is needed
   */
  async checkLiquidationRisk(participantAddress) {
    console.log(`⚠️ Checking liquidation risk for ${participantAddress}...`);

    try {
      const [ratio, meetsMinimum, requiredStakeUSD, currentStakeUSD] =
        await this.contract.getCollateralizationRatio(participantAddress);

      const ratioPercent = ratio.toNumber() / 10000;

      if (ratioPercent < 120) {
        console.log(
          `🚨 LIQUIDATION RISK! Collateralization ratio: ${ratioPercent.toFixed(2)}%`
        );
        console.log(
          `   Current Stake: $${ethers.utils.formatEther(currentStakeUSD)}`
        );
        console.log(
          `   Required Stake: $${ethers.utils.formatEther(requiredStakeUSD)}`
        );
        console.log(
          `   Action needed: Add more collateral or reduce stake requirements`
        );

        return {
          needsLiquidation: true,
          ratio: ratioPercent,
          currentStakeUSD,
          requiredStakeUSD,
        };
      } else if (ratioPercent < 150) {
        console.log(
          `⚠️ Low collateralization ratio: ${ratioPercent.toFixed(2)}%. Consider adding more stake.`
        );

        return {
          needsLiquidation: false,
          lowCollateral: true,
          ratio: ratioPercent,
          currentStakeUSD,
          requiredStakeUSD,
        };
      } else {
        console.log(
          `✅ Healthy collateralization ratio: ${ratioPercent.toFixed(2)}%`
        );

        return {
          needsLiquidation: false,
          lowCollateral: false,
          ratio: ratioPercent,
          currentStakeUSD,
          requiredStakeUSD,
        };
      }
    } catch (error) {
      console.error(`❌ Failed to check liquidation risk: ${error.message}`);
      throw error;
    }
  }

  /**
   * Setup event listeners for monitoring
   */
  setupEventListeners() {
    console.log(`👂 Setting up event listeners...`);

    // Listen for stake events
    this.contract.on(
      'AssetStaked',
      (participant, asset, amount, valueUSD, newTotalStakeUSD) => {
        console.log(
          `📈 Stake Event: ${participant} staked ${amount} of ${asset} (Value: $${ethers.utils.formatEther(valueUSD)})`
        );
      }
    );

    // Listen for rebalancing events
    this.contract.on(
      'StakeRebalanced',
      (
        participant,
        fromAsset,
        toAsset,
        fromAmount,
        toAmount,
        newCollateralizationRatio
      ) => {
        console.log(
          `🔄 Rebalance Event: ${participant} rebalanced from ${fromAsset} to ${toAsset}`
        );
      }
    );

    // Listen for cross-chain operations
    this.contract.on(
      'CrossChainOperationInitiated',
      (operationId, participant, asset, amount, bridgeId, isDeposit) => {
        console.log(
          `🌉 Cross-chain ${isDeposit ? 'deposit' : 'withdrawal'} initiated: ${operationId}`
        );
      }
    );

    console.log(`✅ Event listeners active`);
  }

  /**
   * Helper function to get token symbol
   */
  async getTokenSymbol(tokenAddress) {
    if (tokenAddress === ETH_ADDRESS) {
      return 'ETH';
    }

    try {
      const [, configs] = await this.contract.getSupportedAssets();
      const [assets] = await this.contract.getSupportedAssets();
      const index = assets.findIndex(
        addr => addr.toLowerCase() === tokenAddress.toLowerCase()
      );

      if (index >= 0) {
        return configs[index].symbol;
      }

      return 'UNKNOWN';
    } catch {
      return 'UNKNOWN';
    }
  }

  /**
   * Helper function to get token decimals
   */
  async getTokenDecimals(tokenAddress) {
    if (tokenAddress === ETH_ADDRESS) {
      return 18;
    }

    try {
      const [, configs] = await this.contract.getSupportedAssets();
      const [assets] = await this.contract.getSupportedAssets();
      const index = assets.findIndex(
        addr => addr.toLowerCase() === tokenAddress.toLowerCase()
      );

      if (index >= 0) {
        return configs[index].decimals;
      }

      return 18; // Default
    } catch {
      return 18;
    }
  }
}

// Example usage functions
async function example_BasicStaking() {
  console.log('\n=== Example: Basic Multi-Asset Staking ===');

  // Initialize (in practice, get these from your app)
  const provider = new ethers.providers.JsonRpcProvider(
    'https://mainnet.infura.io/v3/YOUR_PROJECT_ID'
  );
  const signer = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

  const stakingManager = new MultiAssetStakingManager(provider, signer);

  try {
    // Stake ETH
    await stakingManager.stakeETH(ethers.utils.parseEther('0.1'));

    // Stake WRF tokens
    await stakingManager.stakeERC20(
      CONTRACT_ADDRESSES.WRF_TOKEN,
      ethers.utils.parseEther('1000'),
      { githubVerified: true } // Get 10% discount for GitHub verification
    );

    // Stake USDC
    await stakingManager.stakeERC20(
      CONTRACT_ADDRESSES.USDC_TOKEN,
      ethers.utils.parseUnits('100', 6) // $100 USDC
    );

    // Check final stake status
    const stakeInfo = await stakingManager.getStakeInfo(
      await signer.getAddress()
    );
  } catch (error) {
    console.error('Basic staking example failed:', error);
  }
}

async function example_BTCStaking() {
  console.log('\n=== Example: Bitcoin Staking via WBTC ===');

  const provider = new ethers.providers.JsonRpcProvider(
    'https://mainnet.infura.io/v3/YOUR_PROJECT_ID'
  );
  const signer = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

  const stakingManager = new MultiAssetStakingManager(provider, signer);

  try {
    // Stake WBTC (this will trigger cross-chain operations)
    await stakingManager.stakeWBTC(
      ethers.utils.parseUnits('0.05', 8), // 0.05 WBTC
      {
        verificationLevel: 2, // PHONE_VERIFIED for 10% discount
        geographicZone: 1, // UNDERSERVED_AREA for 70% discount
        githubVerified: true, // Additional 10% social discount
      }
    );

    // Monitor cross-chain operation
    stakingManager.setupEventListeners();
  } catch (error) {
    console.error('BTC staking example failed:', error);
  }
}

async function example_StakeRebalancing() {
  console.log('\n=== Example: Stake Rebalancing ===');

  const provider = new ethers.providers.JsonRpcProvider(
    'https://mainnet.infura.io/v3/YOUR_PROJECT_ID'
  );
  const signer = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

  const stakingManager = new MultiAssetStakingManager(provider, signer);

  try {
    // Check current stake status
    const participantAddress = await signer.getAddress();
    await stakingManager.getStakeInfo(participantAddress);

    // Check for liquidation risk
    const riskCheck =
      await stakingManager.checkLiquidationRisk(participantAddress);

    if (riskCheck.needsLiquidation || riskCheck.lowCollateral) {
      // Rebalance from volatile asset (ETH) to stable asset (USDC)
      await stakingManager.rebalanceStake(
        ETH_ADDRESS,
        CONTRACT_ADDRESSES.USDC_TOKEN,
        ethers.utils.parseEther('0.05') // Rebalance 0.05 ETH to USDC
      );
    }

    // Convert some WRF to USDT for diversification
    await stakingManager.convertStakeAsset(
      CONTRACT_ADDRESSES.WRF_TOKEN,
      CONTRACT_ADDRESSES.USDT_TOKEN,
      ethers.utils.parseEther('500') // Convert 500 WRF to USDT
    );
  } catch (error) {
    console.error('Rebalancing example failed:', error);
  }
}

async function example_Monitoring() {
  console.log('\n=== Example: Continuous Monitoring ===');

  const provider = new ethers.providers.JsonRpcProvider(
    'https://mainnet.infura.io/v3/YOUR_PROJECT_ID'
  );
  const signer = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

  const stakingManager = new MultiAssetStakingManager(provider, signer);

  // Setup continuous monitoring
  stakingManager.setupEventListeners();

  // Monitor prices every 5 minutes
  setInterval(
    async () => {
      try {
        await stakingManager.monitorAssetPrices();

        // Check liquidation risk
        const participantAddress = await signer.getAddress();
        await stakingManager.checkLiquidationRisk(participantAddress);
      } catch (error) {
        console.error('Monitoring error:', error);
      }
    },
    5 * 60 * 1000
  ); // 5 minutes
}

// Export for use in other modules
module.exports = {
  MultiAssetStakingManager,
  CONTRACT_ADDRESSES,
  ETH_ADDRESS,
  example_BasicStaking,
  example_BTCStaking,
  example_StakeRebalancing,
  example_Monitoring,
};

// Run examples if called directly
if (require.main === module) {
  console.log('🚀 MultiAssetStaking Usage Examples');
  console.log('=====================================');

  // Uncomment to run specific examples:
  // example_BasicStaking();
  // example_BTCStaking();
  // example_StakeRebalancing();
  // example_Monitoring();
}
