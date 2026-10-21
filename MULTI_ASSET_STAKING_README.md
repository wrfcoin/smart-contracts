# MultiAssetStaking Contract - Comprehensive Documentation

## Overview

The MultiAssetStaking contract is a comprehensive multi-collateral staking system that supports
multiple asset types including WBTC for Bitcoin staking in WRFCoin's fair launch ecosystem. It
enables weather station participants to stake various assets (ETH, WBTC, WRF, USDC, USDT) as
collateral for network participation.

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                    MultiAssetStaking                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  │   Asset Config  │  │  Price Oracles  │  │ Cross-Chain     │
│  │   Management    │  │   (Chainlink)   │  │ Bridge Support  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  │ Stake Records   │  │  Rebalancing    │  │  Emergency      │
│  │   Per User      │  │   Mechanisms    │  │  Liquidation    │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘
└─────────────────────────────────────────────────────────────┘
            │                    │                    │
            ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ DynamicStake    │  │ ParticipantType │  │ SecureBridge    │
│ Calculator      │  │ Registry        │  │ Integration     │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

### Supported Assets

| Asset | Type   | Cross-Chain | Decimals | Use Case             |
| ----- | ------ | ----------- | -------- | -------------------- |
| ETH   | Native | No          | 18       | Primary collateral   |
| WBTC  | ERC20  | Yes         | 8        | Bitcoin exposure     |
| WRF   | ERC20  | No          | 18       | Native token staking |
| USDC  | ERC20  | No          | 6        | Stable collateral    |
| USDT  | ERC20  | No          | 6        | Stable collateral    |

## Key Features

### 1. Multi-Asset Support

- **Native ETH**: Direct staking without token transfers
- **ERC20 Tokens**: Standard token staking with approval mechanisms
- **Cross-Chain Assets**: WBTC staking via bridge integration
- **Dynamic Asset Configuration**: Owner can add/remove supported assets

### 2. Dynamic Stake Calculations

- Integration with `DynamicStakeCalculator` for sophisticated requirements
- Participant type-based multipliers
- Geographic zone incentives
- Verification level discounts
- Social verification bonuses

### 3. Cross-Chain WBTC Integration

- Seamless WBTC deposits via bridge infrastructure
- Automatic cross-chain operation handling
- Failure recovery mechanisms
- Bridge timeout protections

### 4. Automatic Rebalancing

- Maintains minimum collateralization ratios (120%)
- Asset conversion between supported tokens
- Slippage protection (max 5%)
- Emergency rebalancing triggers

### 5. Oracle Price Integration

- Chainlink price feeds for all assets
- Stale price detection and rejection
- Oracle failure handling
- Real-time USD value calculations

### 6. Security Features

- Emergency liquidation for undercollateralized positions
- Asset concentration limits (prevent over-exposure)
- Pause functionality for emergency situations
- Multi-signature emergency controls

## Contract Interface

### Core Functions

#### Staking Operations

```solidity
function stakeAsset(
    address asset,
    uint256 amount,
    DynamicStakeCalculator.StakeParameters calldata parameters
) external payable;

function withdrawStake(address asset, uint256 amount) external;
```

#### Asset Management

```solidity
function rebalanceStake(
    address participant,
    address fromAsset,
    address toAsset,
    uint256 amount
) external;

function convertStakeAsset(
    address fromAsset,
    address toAsset,
    uint256 amount
) external;
```

#### Information Queries

```solidity
function getStakeValueUSD(address participant)
    external view
    returns (uint256 totalValueUSD, uint256[] memory breakdown, address[] memory assets);

function getCollateralizationRatio(address participant)
    external view
    returns (uint256 ratio, bool meetsMinimum, uint256 requiredStakeUSD, uint256 currentStakeUSD);
```

### Cross-Chain Functions

#### Bridge Integration

```solidity
function completeCrossChainDeposit(
    bytes32 operationId,
    address participant,
    address asset,
    uint256 amount
) external;

function completeCrossChainWithdrawal(
    bytes32 operationId,
    bool success,
    string calldata reason
) external;
```

## Integration Guide

### 1. Contract Deployment

```javascript
// Deploy MultiAssetStaking
const multiAssetStaking = await MultiAssetStakingFactory.deploy(
  stakeCalculatorAddress, // DynamicStakeCalculator integration
  participantRegistryAddress, // ParticipantTypeRegistry
  bridgeIntegrationAddress, // SecureBridgeIntegration
  emergencyLiquidatorAddress, // Emergency liquidator
  treasuryAddress // Treasury for liquidated assets
);

// Configure supported assets
await multiAssetStaking.configureAsset(ETH_ADDRESS, {
  tokenAddress: ETH_ADDRESS,
  priceOracle: ethUsdOracleAddress,
  decimals: 18,
  isActive: true,
  isCrossChain: false,
  minStakeAmount: ethers.utils.parseEther('0.01'),
  maxStakeAmount: ethers.utils.parseEther('100'),
  concentrationLimit: 400000, // 40%
  symbol: 'ETH',
  bridgeId: ethers.constants.HashZero,
});
```

### 2. Basic Staking Integration

```javascript
const stakingManager = new MultiAssetStakingManager(provider, signer);

// Stake ETH
await stakingManager.stakeETH(ethers.utils.parseEther('1.0'), {
  participationType: 0, // WEATHER_STATION
  geographicZone: 1, // UNDERSERVED_AREA (70% discount)
  verificationLevel: 2, // PHONE_VERIFIED (10% discount)
  githubVerified: true, // 10% social discount
});

// Stake WRF tokens
await stakingManager.stakeERC20(WRF_TOKEN_ADDRESS, ethers.utils.parseEther('1000'));

// Check stake status
const stakeInfo = await stakingManager.getStakeInfo(participantAddress);
```

### 3. WBTC Cross-Chain Staking

```javascript
// WBTC staking automatically triggers cross-chain operations
await stakingManager.stakeWBTC(
  ethers.utils.parseUnits('0.1', 8), // 0.1 WBTC
  { verificationLevel: 3 } // GOVERNMENT_ID_VERIFIED
);

// Monitor cross-chain completion
stakingManager.setupEventListeners();
stakingManager.contract.on('CrossChainOperationCompleted', (operationId, participant, success) => {
  console.log(`Cross-chain operation ${operationId}: ${success ? 'Success' : 'Failed'}`);
});
```

### 4. Automatic Rebalancing

```javascript
// Check liquidation risk
const riskCheck = await stakingManager.checkLiquidationRisk(participantAddress);

if (riskCheck.needsLiquidation) {
  // Rebalance from volatile to stable assets
  await stakingManager.rebalanceStake(
    ETH_ADDRESS,
    USDC_TOKEN_ADDRESS,
    ethers.utils.parseEther('0.5')
  );
}
```

## Economic Model

### Collateralization Requirements

- **Minimum Ratio**: 120% of required stake value
- **Emergency Threshold**: 110% (triggers liquidation)
- **Healthy Ratio**: 150%+ recommended

### Stake Calculations

Base stake requirements are calculated using the DynamicStakeCalculator:

```
Final_Stake = max(
    Base_Stake × Participation_Multiplier × Geographic_Multiplier × Density_Multiplier × Verification_Discount × Social_Discount,
    $20_USD_Floor
)
```

### Asset Concentration Limits

| Asset     | Max Concentration | Reasoning                 |
| --------- | ----------------- | ------------------------- |
| ETH       | 40%               | Primary collateral        |
| WBTC      | 50%               | Bitcoin exposure priority |
| WRF       | 30%               | Native token incentive    |
| USDC/USDT | 40% each          | Stable value preservation |

## Security Considerations

### 1. Oracle Security

- **Price Freshness**: Maximum 30-minute age for prices
- **Price Validation**: Rejects negative or zero prices
- **Fallback Mechanisms**: Multiple oracle support planned

### 2. Cross-Chain Security

- **Bridge Validation**: Only authorized bridge contracts can complete operations
- **Timeout Protection**: 24-hour maximum for cross-chain operations
- **Failure Recovery**: Automatic stake restoration on bridge failures

### 3. Slashing Protection

- **Liquidation Thresholds**: Clear warning levels before liquidation
- **Emergency Delays**: 24-hour delay for non-emergency liquidations
- **Multi-Signature Controls**: Critical functions require multiple signatures

### 4. Access Controls

- **Owner Functions**: Asset configuration, emergency pause
- **Emergency Liquidator**: Authorized liquidation operations only
- **Participant Self-Management**: Users control their own stakes

## Gas Optimization

The contract is optimized for gas efficiency:

- **Batch Operations**: Support for multiple asset operations
- **Storage Optimization**: Packed structs and efficient mappings
- **Event Optimization**: Comprehensive but gas-efficient event emission
- **View Function Caching**: Efficient read operations

## Testing

Comprehensive test suite covers:

- **Multi-Asset Staking**: All supported asset types
- **Cross-Chain Operations**: WBTC bridge integration
- **Oracle Integration**: Price feed handling and validation
- **Rebalancing Mechanisms**: Asset conversion and rebalancing
- **Security Features**: Emergency liquidation and pause functionality
- **Edge Cases**: Slippage protection, concentration limits, stale prices

Run tests:

```bash
npx hardhat test contracts/test/MultiAssetStaking.test.js
```

## Deployment Scripts

Deploy the complete system:

```bash
npx hardhat run contracts/deploy/deploy-multi-asset-staking.js --network mainnet
```

## Monitoring and Maintenance

### Event Monitoring

Key events to monitor:

- `AssetStaked`: New stake deposits
- `StakeRebalanced`: Rebalancing operations
- `CrossChainOperationInitiated`: Bridge operations
- `EmergencyLiquidation`: Liquidation events
- `CollateralizationRatioUpdated`: Health changes

### Price Monitoring

- Monitor oracle price feeds for staleness
- Alert on significant price movements (>10%)
- Track collateralization ratios across participants

### Cross-Chain Monitoring

- Monitor bridge operation success rates
- Track pending cross-chain operations
- Alert on bridge failures or delays

## Future Enhancements

### Planned Features

1. **Additional Assets**: Support for more cryptocurrencies and stablecoins
2. **Advanced Rebalancing**: AI-driven optimization algorithms
3. **Governance Integration**: DAO-controlled parameter updates
4. **Insurance Integration**: Stake insurance for participants
5. **Yield Generation**: Productive staking with DeFi protocols

### Scaling Solutions

- Layer 2 integration for lower gas costs
- State channel support for frequent rebalancing
- Optimistic rollup deployment for mass adoption

## Support and Documentation

- **Contract Source**: `/contracts/MultiAssetStaking.sol`
- **Interface**: `/contracts/interfaces/IMultiAssetStaking.sol`
- **Tests**: `/contracts/test/MultiAssetStaking.test.js`
- **Examples**: `/contracts/examples/multi-asset-staking-usage.js`
- **Deployment**: `/contracts/deploy/deploy-multi-asset-staking.js`

For technical support or questions:

- GitHub Issues: [WRFCoin Repository](https://github.com/wrfcoin/contracts)
- Documentation: [WRFCoin Docs](https://docs.wrfcoin.io)
- Community: [WRFCoin Discord](https://discord.gg/wrfcoin)

---

_This contract is part of the WRFCoin fair launch ecosystem, enabling decentralized weather data
collection through economic incentives and multi-asset collateral support._
