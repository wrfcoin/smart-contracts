# BTCStakeRegistry Contract Documentation

## Overview

The BTCStakeRegistry contract is designed to handle WBTC (Wrapped
Bitcoin) staking for weather station registration in the WRFCoin ecosystem. It provides
comprehensive cross-chain bridge support, emergency procedures, and robust security measures.

## Features

### Core Functionality

- **WBTC Collateral Management**: Accept WBTC as collateral for weather station registration
- **Dynamic Collateralization**: Support collateral ratios between 150%-300%
- **Cross-Chain Integration**: Bridge operations for Bitcoin holders across multiple chains
- **Price Oracle Integration**: Real-time WBTC pricing via Chainlink oracles
- **Liquidation Protection**: Automatic liquidation when collateralization falls below 125%
- **Emergency Procedures**: Comprehensive emergency shutdown and recovery mechanisms

### Security Features

- **Multi-Signature Access Control**: Role-based permissions with time-locked operations
- **Economic Security Limits**: TVL caps and daily withdrawal limits
- **Bridge Timeout Protection**: Automatic refunds for failed cross-chain operations
- **Circuit Breaker Pattern**: Emergency pause functionality
- **Reentrancy Protection**: SafeERC20 and ReentrancyGuard implementation
- **Input Validation**: Comprehensive parameter validation and bounds checking

## Architecture

### Contract Structure

```
BTCStakeRegistry
├── Core Functions
│   ├── registerWeatherStation()
│   ├── addCollateral()
│   ├── withdrawCollateral()
│   └── liquidateStation()
├── Cross-Chain Bridge
│   ├── initiateBridgeOperation()
│   ├── confirmBridgeOperation()
│   └── processBridgeTimeout()
├── Emergency Procedures
│   ├── activateEmergencyShutdown()
│   ├── emergencyWithdraw()
│   └── recoverStuckTokens()
└── Administrative Functions
    ├── updatePriceFeeds()
    ├── addSupportedBridge()
    └── updateSecurityParameters()
```

### Key Components

#### Weather Station Registry

- **Station ID**: Unique bytes32 identifier for each weather station
- **Collateral Tracking**: WBTC amount and USD value requirements
- **Status Management**: Active/inactive status and liquidation flags
- **Owner Management**: Station ownership and access control

#### Cross-Chain Bridge Integration

- **Supported Bridges**: Configurable list of authorized bridge contracts
- **Operation Tracking**: Nonce-based operation identification
- **Timeout Handling**: Automatic processing of failed operations
- **Status Management**: PENDING, CONFIRMED, FAILED, TIMEOUT, REVERSED states

#### Economic Security

- **TVL Limits**: Maximum total value locked protection ($50M default)
- **Daily Limits**: Withdrawal limits to prevent large-scale attacks ($1M default)
- **Collateral Ratios**: Enforced minimum (150%) and maximum (300%) ratios
- **Liquidation Threshold**: Automatic liquidation at 125% ratio

## Usage

### Weather Station Registration

```solidity
// 1. Approve WBTC transfer
wbtcToken.approve(btcStakeRegistryAddress, wbtcAmount);

// 2. Register weather station
bytes32 stationId = keccak256("my-weather-station");
uint256 wbtcAmount = 1e8; // 1 WBTC (8 decimals)
uint256 requiredUsdValue = 20000e18; // $20K requirement

btcStakeRegistry.registerWeatherStation(
    stationId,
    wbtcAmount,
    requiredUsdValue
);
```

### Cross-Chain Bridge Operations

```solidity
// Initiate bridge operation for Bitcoin holders
uint256 nonce = btcStakeRegistry.initiateBridgeOperation(
    bridgeAddress,      // Authorized bridge contract
    amount,             // WBTC amount to bridge
    137,                // Destination chain (Polygon)
    recipientAddress    // Recipient on destination chain
);

// Bridge operator confirms completion
btcStakeRegistry.confirmBridgeOperation(
    nonce,
    destinationTxHash
);
```

### Emergency Procedures

```solidity
// Emergency admin activates shutdown
btcStakeRegistry.activateEmergencyShutdown();

// After 48-hour delay, users can emergency withdraw
btcStakeRegistry.emergencyWithdraw(stationId);
```

## Security Model

### Access Control Roles

| Role                   | Permissions              | Description                |
| ---------------------- | ------------------------ | -------------------------- |
| `DEFAULT_ADMIN_ROLE`   | All admin functions      | Contract administrator     |
| `BRIDGE_OPERATOR_ROLE` | Bridge confirmations     | Cross-chain operations     |
| `EMERGENCY_ROLE`       | Emergency shutdown/pause | Security incident response |
| `ORACLE_MANAGER_ROLE`  | Price feed updates       | Oracle management          |
| `WEATHER_STATION_ROLE` | Station operations       | Weather station owners     |

### Economic Security Parameters

| Parameter                | Default Value | Description                        |
| ------------------------ | ------------- | ---------------------------------- |
| `MAX_COLLATERAL_RATIO`   | 300%          | Maximum over-collateralization     |
| `MIN_COLLATERAL_RATIO`   | 150%          | Minimum collateralization required |
| `LIQUIDATION_THRESHOLD`  | 125%          | Liquidation trigger point          |
| `MAX_STATION_VALUE`      | $100K         | Maximum value per station          |
| `MAX_TOTAL_VALUE_LOCKED` | $50M          | System-wide TVL limit              |
| `DAILY_WITHDRAWAL_LIMIT` | $1M           | Daily withdrawal cap               |

### Price Feed Security

- **Staleness Check**: Prices must be updated within 1 hour
- **Validation**: Non-zero and positive price validation
- **Fallback Mechanism**: Multiple oracle support capability
- **Update Authorization**: Only ORACLE_MANAGER_ROLE can update feeds

### Bridge Security

- **Timeout Protection**: 24-hour automatic timeout for failed operations
- **Authorization**: Only approved bridge contracts accepted
- **Operation Tracking**: Comprehensive nonce-based tracking
- **Failure Limits**: Maximum 10 failed operations before circuit breaker

## Emergency Procedures

### Emergency Shutdown Process

1. **Activation**: EMERGENCY_ROLE calls `activateEmergencyShutdown()`
2. **Immediate Effect**: Contract paused, no new operations
3. **Delay Period**: 48-hour waiting period for user protection
4. **Emergency Withdrawal**: Users can withdraw full collateral after delay
5. **Recovery**: Admin can recover non-collateral tokens if needed

### Circuit Breaker Mechanisms

- **Pause/Unpause**: Emergency pause for security incidents
- **Bridge Failures**: Automatic suspension after excessive failures
- **TVL Protection**: Rejection of operations exceeding limits
- **Daily Limits**: Withdrawal restrictions reset every 24 hours

## Integration Points

### MultiAssetStaking Integration

The contract integrates with the MultiAssetStaking contract to provide additional yield
opportunities:

```solidity
// Automatic integration on registration
function _integrateWithStaking(bytes32 stationId, uint256 amount) internal {
    wbtcToken.safeApprove(address(multiAssetStaking), amount);
    multiAssetStaking.stakeBTC(stationId, amount, msg.sender);
}
```

### Chainlink Price Feeds

Real-time price data from Chainlink oracles:

```solidity
function getWBTCPrice() public view returns (uint256 price) {
    (,int256 wbtcPrice,,,) = wbtcPriceFeed.latestRoundData();
    require(wbtcPrice > 0, "Invalid WBTC price");
    return uint256(wbtcPrice) * 1e10; // Convert to 18 decimals
}
```

## Testing

### Test Coverage

The contract includes comprehensive tests covering:

- **Registration**: Valid and invalid registration scenarios
- **Collateral Management**: Add/withdraw with ratio validation
- **Liquidation**: Under-collateralization detection and processing
- **Cross-Chain**: Bridge operations and timeout handling
- **Emergency**: Shutdown procedures and recovery mechanisms
- **Security**: Access control and input validation
- **Integration**: MultiAssetStaking integration testing

### Running Tests

```bash
# Run all BTCStakeRegistry tests
npx hardhat test test/BTCStakeRegistry.test.js

# Run with coverage
npx hardhat coverage --testfiles test/BTCStakeRegistry.test.js

# Run gas analysis
npx hardhat test test/BTCStakeRegistry.test.js --reporter gas
```

## Deployment

### Local/Testnet Deployment

```bash
# Deploy with mock contracts for testing
npx hardhat run contracts/deploy/deploy-btc-stake-registry.js --network localhost

# Deploy to Sepolia testnet
npx hardhat run contracts/deploy/deploy-btc-stake-registry.js --network sepolia
```

### Production Deployment

```bash
# Update deployment script with production addresses
# Set WBTC token: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
# Set WBTC/USD feed: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c
# Set MultiAssetStaking address

npx hardhat run contracts/deploy/deploy-btc-stake-registry.js --network mainnet

# Verify deployment
npx hardhat verify --network mainnet <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

## Gas Optimization

### Deployment Costs

- **Contract Deployment**: ~4.5M gas
- **Role Setup**: ~200K gas per role
- **Bridge Addition**: ~100K gas per bridge

### Operation Costs

- **Register Station**: ~180K gas
- **Add Collateral**: ~120K gas
- **Withdraw Collateral**: ~140K gas
- **Liquidation**: ~160K gas
- **Bridge Operation**: ~200K gas

### Optimization Techniques

- **Packed Structs**: Minimize storage slots usage
- **Batch Operations**: Multiple operations in single transaction
- **Event Logging**: Off-chain data storage via events
- **Unchecked Math**: Loop counters use unchecked increment

## Monitoring and Maintenance

### Health Monitoring

```solidity
// Get contract health status
(bool isHealthy, uint256 tvlUtilization, uint256 failureRate) =
    btcStakeRegistry.getHealthStatus();
```

### Key Metrics to Monitor

- **TVL Utilization**: Should stay below 90%
- **Failed Operation Rate**: Should stay below 10%
- **Daily Withdrawals**: Track against limits
- **Price Feed Freshness**: Monitor oracle updates
- **Bridge Operation Success**: Track cross-chain reliability

### Maintenance Tasks

- **Price Feed Updates**: Monitor oracle performance
- **Bridge Management**: Add/remove bridge contracts as needed
- **Security Parameter Updates**: Adjust limits based on market conditions
- **Role Management**: Rotate keys and update access control

## Security Considerations

### Best Practices Implemented

- **Checks-Effects-Interactions**: Proper state update ordering
- **Input Validation**: Comprehensive parameter checking
- **Access Control**: Multi-role permission system
- **Economic Limits**: TVL and withdrawal protection
- **Emergency Procedures**: Comprehensive incident response

### Potential Risks

- **Oracle Manipulation**: Mitigated by staleness checks and multiple feeds
- **Bridge Failures**: Protected by timeout mechanisms and failure limits
- **Large Liquidations**: Limited by individual station value caps
- **Smart Contract Risk**: Extensive testing and security audits

### Audit Recommendations

- **External Security Audit**: Before production deployment
- **Economic Model Review**: Validate collateral ratios and limits
- **Oracle Integration Testing**: Verify price feed reliability
- **Cross-Chain Testing**: Validate bridge integrations
- **Emergency Procedure Testing**: Test all emergency scenarios

## Support and Resources

### Documentation

- **Contract Source**: `contracts/BTCStakeRegistry.sol`
- **Interfaces**: `contracts/interfaces/`
- **Tests**: `test/BTCStakeRegistry.test.js`
- **Deployment**: `contracts/deploy/deploy-btc-stake-registry.js`

### Contact Information

- **Platform**: WRFCoin Weather Forecasting Platform
- **Repository**: WRFCoin Smart Contracts
- **Security Contact**: For security issues, contact the platform security team

---

_This documentation is maintained alongside the contract code. For the latest information, always
refer to the contract source code and recent deployment information._
