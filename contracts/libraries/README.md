# DynamicStakeCalculator Library Documentation

## Overview

The `DynamicStakeCalculator` library implements a sophisticated staking calculation system for
WRFCoin's enhanced fair launch system. It provides dynamic stake requirements based on multiple
factors to ensure economic security while incentivizing participation in underserved areas.

## Key Features

### 🎯 **Multi-Factor Staking Algorithm**

- **Participation Type Multipliers**: Different rates for weather stations, forecast producers,
  validators, etc.
- **Geographic Incentives**: Lower stakes for underserved areas, higher for competitive zones
- **Network Density Adjustments**: Encourages coverage in sparse areas
- **Verification Discounts**: Rewards KYC, phone, email, and physical verification
- **Social Verification**: Additional discounts for GitHub, Twitter, LinkedIn verification

### 🛡️ **Security Features**

- **$20 USD Minimum Floor**: Prevents excessive discounts from compromising security
- **Input Validation**: Comprehensive parameter checking and bounds validation
- **Gas Optimization**: Fixed-point arithmetic with 6-decimal precision
- **Anti-Manipulation**: Economic security limits and overflow protection

### 🔧 **Technical Implementation**

- **Solidity 0.8.28+**: Built-in overflow protection
- **Library Architecture**: Gas-efficient, reusable across contracts
- **Oracle Integration**: Hooks for real-time asset pricing
- **Multi-Asset Support**: ETH, WBTC, WRF, USDC, USDT conversion

## Calculation Formula

```
Raw_Stake = Base_Stake × Participation_Type × Geographic_Factor × Network_Density
Discounted_Stake = Raw_Stake × Verification_Discount × Social_Discount
Final_Stake = max(Discounted_Stake, $20_USD_Floor)
```

## Participation Type Multipliers

| Type              | Multiplier | Use Case                                 |
| ----------------- | ---------- | ---------------------------------------- |
| Weather Station   | 1.0x       | Base rate for data providers             |
| Forecast Producer | 0.8x       | Computational contributors get discount  |
| Data Storage Node | 0.6x       | Storage providers get largest discount   |
| Validator Node    | 1.2x       | Consensus participants pay premium       |
| Hybrid Node       | Variable   | Additive discounts for multiple services |

## Geographic Zone Multipliers

| Zone                | Multiplier | Purpose                              |
| ------------------- | ---------- | ------------------------------------ |
| Default Area        | 1.0x       | Standard rate                        |
| Underserved Area    | 0.3x       | High incentive for coverage          |
| Dense Urban Area    | 2.0x       | Higher stakes in competitive areas   |
| Rural/Remote Area   | 0.5x       | Medium incentive for remote coverage |
| Island/Coastal Zone | 0.4x       | Critical for weather data accuracy   |

## Verification Level Discounts

| Level               | Discount | Requirements                 |
| ------------------- | -------- | ---------------------------- |
| Unverified          | 0%       | No verification              |
| Email Verified      | 5%       | Valid email confirmation     |
| Phone Verified      | 10%      | SMS verification             |
| Government ID       | 20%      | KYC with official documents  |
| Physical Inspection | 30%      | On-site station verification |

## Social Verification Discounts

| Platform          | Discount | Criteria                          |
| ----------------- | -------- | --------------------------------- |
| GitHub            | 10%      | Active contributor with repos     |
| Twitter           | 5%       | Verified account with activity    |
| LinkedIn          | 7%       | Professional profile verification |
| **Maximum Total** | **20%**  | Combined social verification cap  |

## Network Density Adjustments

| Nearby Stations | Multiplier | Incentive                      |
| --------------- | ---------- | ------------------------------ |
| 0 stations      | 0.8x       | Encourage sparse area coverage |
| 1-3 stations    | 1.0x       | Normal density                 |
| 4-10 stations   | 1.5x       | Moderate competition           |
| >10 stations    | 2.0x       | High density areas             |

_Density calculated within 50km radius_

## Usage Examples

### Basic Weather Station Stake

```solidity
import "./libraries/DynamicStakeCalculator.sol";

// Calculate stake for basic weather station
uint256 stakeRequired = DynamicStakeCalculator.calculateBasicStake(
    DynamicStakeCalculator.ParticipationType.WEATHER_STATION,
    DynamicStakeCalculator.GeographicZone.DEFAULT_AREA,
    DynamicStakeCalculator.VerificationLevel.EMAIL_VERIFIED
);
// Result: $47.50 ($50 * 1.0 * 1.0 * 0.95)
```

### Advanced Multi-Factor Calculation

```solidity
// Define comprehensive staking parameters
DynamicStakeCalculator.StakeParameters memory params = DynamicStakeCalculator.StakeParameters({
    participationType: DynamicStakeCalculator.ParticipationType.DATA_STORAGE_NODE,
    geographicZone: DynamicStakeCalculator.GeographicZone.UNDERSERVED_AREA,
    verificationLevel: DynamicStakeCalculator.VerificationLevel.PHYSICAL_STATION_INSPECTED,
    social: DynamicStakeCalculator.SocialVerification({
        githubVerified: true,
        twitterVerified: true,
        linkedinVerified: true
    }),
    density: DynamicStakeCalculator.NetworkDensity({
        nearbyStationsCount: 0,
        isDensityVerified: true
    }),
    hybridServices: DynamicStakeCalculator.HybridServices({
        providesWeatherData: false,
        providesForecasting: false,
        providesDataStorage: true,
        providesValidation: false
    })
});

// Get detailed calculation breakdown
DynamicStakeCalculator.StakeCalculationResult memory result =
    DynamicStakeCalculator.calculateRequiredStake(params);

// Result will hit $20 minimum floor due to high incentives
// Raw calculation: $50 * 0.6 * 0.3 * 0.8 * 0.7 * 0.8 = $4.03
// Final result: $20 (minimum floor protection)
```

### Multi-Asset Conversion

```solidity
// Convert $100 USD stake requirement to various assets
uint256 usdAmount = 100 * DynamicStakeCalculator.PRECISION; // $100

(uint256 ethAmount, uint256 wbtcAmount, uint256 wrfAmount, uint256 usdcAmount, uint256 usdtAmount) =
    DynamicStakeCalculator.getMultiAssetStakeAmounts(
        usdAmount,
        2000 * DynamicStakeCalculator.PRECISION, // ETH at $2000
        50000 * DynamicStakeCalculator.PRECISION, // WBTC at $50000
        5 * DynamicStakeCalculator.PRECISION,    // WRF at $5
        1 * DynamicStakeCalculator.PRECISION,    // USDC at $1
        1 * DynamicStakeCalculator.PRECISION     // USDT at $1
    );
```

## Integration with Contracts

### Using in Smart Contracts

```solidity
pragma solidity ^0.8.28;

import "./libraries/DynamicStakeCalculator.sol";

contract YourStakingContract {
    using DynamicStakeCalculator for DynamicStakeCalculator.StakeParameters;

    function registerWithStake(
        DynamicStakeCalculator.StakeParameters calldata params
    ) external payable {
        // Calculate required stake
        DynamicStakeCalculator.StakeCalculationResult memory result =
            DynamicStakeCalculator.calculateRequiredStake(params);

        // Validate stake amount
        require(msg.value >= convertToETH(result.finalStakeUSD), "Insufficient stake");

        // Process registration...
    }
}
```

### Event Integration

The library emits detailed events for transparency:

```solidity
event StakeCalculated(
    address indexed participant,
    uint256 indexed finalStakeUSD,
    ParticipationType participationType,
    GeographicZone geographicZone,
    VerificationLevel verificationLevel,
    uint256 socialDiscountPercent,
    uint256 networkDensityCount,
    bool hitMinimumFloor
);
```

## Security Considerations

### Economic Security

- **Minimum Floor**: $20 USD floor prevents excessive discounts
- **Maximum Limits**: Anti-whale protection and validation limits
- **Oracle Dependency**: Price feeds must be validated and fresh

### Input Validation

```solidity
// Always validate parameters before calculation
(bool valid, string memory error) = DynamicStakeCalculator.validateStakeParameters(params);
require(valid, error);
```

### Gas Optimization

- Fixed-point arithmetic with 1e6 precision
- Efficient struct packing
- Minimal storage operations
- Batch calculation support

## Error Handling

| Error                      | Cause                        | Solution                         |
| -------------------------- | ---------------------------- | -------------------------------- |
| `InvalidParticipationType` | Enum value out of range      | Use valid ParticipationType enum |
| `InvalidGeographicZone`    | Invalid zone parameter       | Use valid GeographicZone enum    |
| `InvalidVerificationLevel` | Invalid verification enum    | Use valid VerificationLevel enum |
| `InvalidAssetPrice`        | Zero or invalid price        | Validate oracle price before use |
| `MinimumFloorViolation`    | Calculated stake below floor | Check validateStakeSecurity()    |

## Best Practices

### 1. **Parameter Validation**

```solidity
// Always validate before calculation
(bool valid, string memory error) = DynamicStakeCalculator.validateStakeParameters(params);
require(valid, error);
```

### 2. **Oracle Price Validation**

```solidity
// Ensure fresh, valid oracle prices
require(oraclePrice > 0, "Invalid oracle price");
require(block.timestamp - lastUpdate < MAX_ORACLE_AGE, "Stale oracle price");
```

### 3. **Economic Security Checks**

```solidity
// Validate final stake meets security requirements
(bool secure, string memory level) = DynamicStakeCalculator.validateStakeSecurity(finalStake);
require(secure, "Stake below security minimum");
```

### 4. **Event Emission**

```solidity
// Emit calculation events for transparency
emit StakeCalculated(participant, finalStake, /* other parameters */);
```

## Testing

Comprehensive test suite covers:

- ✅ All participation type multipliers
- ✅ Geographic zone calculations
- ✅ Network density adjustments
- ✅ Verification level discounts
- ✅ Social verification combinations
- ✅ Minimum floor enforcement
- ✅ Asset conversion accuracy
- ✅ Parameter validation
- ✅ Edge cases and precision
- ✅ Gas optimization validation

Run tests:

```bash
npx hardhat test test/DynamicStakeCalculator.test.js
```

## Production Deployment

### Prerequisites

1. **Oracle Integration**: Set up price feeds for supported assets
2. **Multi-Asset Support**: Deploy asset management contracts
3. **Geographic Data**: Implement location verification system
4. **Network Density**: Establish station counting mechanism

### Deployment Checklist

- [ ] Validate all constants match requirements
- [ ] Test oracle integration thoroughly
- [ ] Verify gas costs are acceptable
- [ ] Audit security parameters
- [ ] Test with various parameter combinations
- [ ] Validate minimum floor enforcement
- [ ] Test asset conversion accuracy

### Monitoring

- Monitor calculation precision
- Track minimum floor hit rates
- Validate oracle price freshness
- Monitor gas costs in production
- Track stake distribution patterns

## Version History

- **v1.0.0**: Initial implementation with core calculation logic
- **v1.1.0**: Added multi-asset conversion support
- **v1.2.0**: Enhanced hybrid node calculations
- **v1.3.0**: Added comprehensive validation and security checks

## Support

For technical support or questions about the DynamicStakeCalculator library:

- Review comprehensive test suite examples
- Check parameter validation functions
- Consult security best practices above
- Validate oracle integration requirements

---

_This library is designed for production use in high-value staking scenarios ($2M-$5M TVL). Thorough
testing and security validation are required before deployment._
