# SlashingMechanism Contract

## Overview

The SlashingMechanism contract is a comprehensive fraud detection and penalty enforcement system
designed for WRFCoin's fair launch ecosystem. It provides robust protection against various forms of
network abuse while maintaining fair appeals processes and graduated penalties.

## Key Features

### 🔒 Security Features

- **Multi-signature validation**: Requires minimum 3 out of 5 validators for slashing decisions
- **Evidence-based slashing**: All slashing proposals must include verified evidence via IPFS
- **Time-locked execution**: 48-hour delay between confirmation and execution for appeals
- **Emergency override**: Admin override capabilities for critical security situations
- **Audit logging**: Complete transparency with comprehensive event emissions

### ⚖️ Fair Process

- **Graduated penalties**: Escalating severity based on violation type and history
- **Appeals mechanism**: 30-day appeal window with community voting
- **Evidence submission**: Participants can submit defending evidence
- **Independent review**: Governance committee oversight of contested cases

### 📊 Violation Types & Penalties

| Violation Type      | Minor (25%) | Major (50%) | Critical (75%) | Terminal (100%) |
| ------------------- | ----------- | ----------- | -------------- | --------------- |
| Data Manipulation   | ✅          | ✅          | ✅             | ✅              |
| Sybil Attack        | -           | ✅          | ✅             | ✅              |
| Network Disruption  | -           | ✅          | ✅             | ✅              |
| Repeated Violations | -           | -           | ✅             | ✅              |
| Fraud               | ✅          | ✅          | ✅             | ✅              |

### 🔄 Stake Recovery Process

- **Grace period**: 30 days to refill stake after slashing
- **Extended layaway**: 2x normal layaway periods after violations
- **Escalating penalties**: Each violation increases future slashing severity
- **Account suspension**: Automatic suspension if grace period expires

## Contract Architecture

### Core Components

1. **SlashingEvent Management**: Tracks all slashing proposals and their lifecycle
2. **Evidence Registry**: IPFS-based evidence verification system
3. **Appeals Process**: Democratic voting mechanism for contested decisions
4. **Participant Records**: Historical violation tracking and penalty management
5. **Multi-Asset Integration**: Handles slashing across different stake types

### State Management

```solidity
struct SlashingEvent {
    uint256 id;
    address participant;
    SlashingReason reason;
    ViolationSeverity severity;
    uint256 slashedAmount;
    uint256 timestamp;
    uint256 executionTime;
    address[] validators;
    bytes32 evidenceHash;
    SlashingStatus status;
    uint256 appealDeadline;
    string description;
    // Additional fields for validator approvals...
}

struct ParticipantRecord {
    uint256 violationCount;
    uint256 totalSlashed;
    uint256 lastViolation;
    bool isBanned;
    uint256 banExpiry;
    uint256 graceDeadline;
    bool requiresRefill;
    uint256 layawayMultiplier;
}
```

## Usage Examples

### 1. Proposing a Slashing Event

```javascript
// First, submit evidence
const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes('fraud evidence data'));
await slashingMechanism
  .connect(validator)
  .submitEvidence(evidenceHash, 'QmIPFSHashOfEvidence123...');

// Then propose slashing
await slashingMechanism.connect(validator).proposeSlashing(
  participantAddress,
  0, // DATA_MANIPULATION
  1, // MAJOR severity
  evidenceHash,
  'Participant submitted falsified weather data on multiple occasions'
);
```

### 2. Validator Approval Process

```javascript
// Multiple validators must approve
await slashingMechanism.connect(validator2).validateSlashing(slashingId);
await slashingMechanism.connect(validator3).validateSlashing(slashingId);
// After 3 approvals, slashing is confirmed and enters execution delay
```

### 3. Appeal Process

```javascript
// Participant submits appeal
const defendingEvidenceHash = ethers.keccak256(ethers.toUtf8Bytes('defense evidence'));
await slashingMechanism
  .connect(validator)
  .submitEvidence(defendingEvidenceHash, 'QmDefenseEvidence456...');

await slashingMechanism
  .connect(participant)
  .appealSlashing(
    slashingId,
    defendingEvidenceHash,
    'I was wrongly accused - here is evidence proving my innocence'
  );

// Appeals committee votes
await slashingMechanism.connect(committeeMember1).voteOnAppeal(appealId, true); // Support
await slashingMechanism.connect(committeeMember2).voteOnAppeal(appealId, false); // Oppose

// After voting period, resolve appeal
await slashingMechanism.resolveAppeal(appealId);
```

### 4. Stake Refill After Slashing

```javascript
// Check eligibility
const [eligible, reason] = await slashingMechanism.checkEligibility(participantAddress);

if (eligible || reason === 'Must refill stake to continue') {
  // Refill stake to continue participation
  await slashingMechanism.connect(participant).refillStake(
    ethers.parseEther('1000') // Amount to refill
  );
}
```

## Integration Points

### MultiAssetStaking Integration

- **Stake Slashing**: Automatically reduces participant stakes across all assets
- **Asset Recovery**: Handles proportional slashing for multi-asset positions
- **Collateral Management**: Updates collateralization ratios after slashing

### Participant Registry Integration

- **Status Updates**: Automatically updates participant eligibility
- **Type Verification**: Verifies participant types for penalty calculations
- **Activity Tracking**: Maintains participation history and verification status

### Layaway Registration Integration

- **Period Extensions**: Doubles layaway periods after violations
- **Penalty Tracking**: Links slashing history to registration requirements
- **Recovery Process**: Manages re-entry after violations

### Weather Data Validator Integration

- **Quality Monitoring**: Receives data quality violation reports
- **Automated Detection**: Triggers slashing for persistent data issues
- **Historical Analysis**: Tracks data quality patterns over time

## Security Considerations

### Access Control

- **Role-based permissions**: VALIDATOR_ROLE, APPEALS_COMMITTEE_ROLE, EMERGENCY_ROLE
- **Multi-signature requirements**: Prevents single-point-of-failure attacks
- **Time delays**: Execution delays provide appeal opportunities
- **Emergency procedures**: Override capabilities for critical situations

### Attack Prevention

- **Evidence verification**: IPFS hash validation prevents fake evidence
- **Validator collusion protection**: Minimum validator requirements
- **Appeal process**: Democratic oversight of slashing decisions
- **Graduated penalties**: Prevents excessive punishment for minor violations

### Data Integrity

- **Immutable records**: Historical violation data cannot be altered
- **Transparent process**: All slashing events publicly viewable
- **Audit trails**: Complete logging of all security actions
- **Cross-validation**: Multiple systems verify slashing legitimacy

## Gas Optimization

The contract implements several gas optimization strategies:

- **Batch operations**: Process multiple slashing events efficiently
- **State packing**: Optimize storage layout for minimal gas costs
- **Lazy evaluation**: Only calculate complex values when needed
- **Event indexing**: Efficient event filtering and searching

## Testing

Comprehensive test suite covers:

- ✅ Deployment and initialization
- ✅ Evidence management
- ✅ Slashing proposal and validation
- ✅ Multi-validator approval process
- ✅ Appeals mechanism
- ✅ Emergency slashing procedures
- ✅ Stake refill process
- ✅ Configuration management
- ✅ View functions and eligibility checks

Run tests with:

```bash
npx hardhat test contracts/test/SlashingMechanism.test.js
```

## Deployment

### Prerequisites

- All interface contracts deployed (MultiAssetStaking, ParticipantTypeRegistry, etc.)
- Treasury and burn addresses configured
- Validator addresses identified
- Appeals committee established

### Deployment Script

```javascript
const SlashingMechanism = await ethers.getContractFactory('SlashingMechanism');
const slashingMechanism = await SlashingMechanism.deploy(
  multiAssetStakingAddress,
  participantRegistryAddress,
  layawayRegistrationAddress,
  stakeDelegationAddress,
  weatherDataValidatorAddress,
  treasuryAddress,
  burnAddress
);

// Configure validator roles
const VALIDATOR_ROLE = await slashingMechanism.VALIDATOR_ROLE();
for (const validator of validatorAddresses) {
  await slashingMechanism.grantRole(VALIDATOR_ROLE, validator);
}
```

## Monitoring & Analytics

### Key Metrics

- **Slashing frequency**: Track violation trends over time
- **Appeal success rate**: Monitor appeals committee effectiveness
- **Stake recovery rate**: Measure participant rehabilitation success
- **Validator participation**: Ensure validator network health
- **Evidence quality**: Track evidence submission and verification rates

### Dashboard Integration

The contract emits comprehensive events suitable for real-time monitoring:

- SlashingProposed, SlashingExecuted
- AppealSubmitted, AppealResolved
- StakeRefilled, ParticipantBanned
- EvidenceSubmitted, EmergencySlashing

## Future Enhancements

### Planned Features

- **AI-powered violation detection**: Automated pattern recognition
- **Dynamic penalty adjustment**: Machine learning-based penalty optimization
- **Cross-chain slashing**: Multi-blockchain violation enforcement
- **Insurance integration**: Compensation mechanisms for false positives
- **Reputation scoring**: Advanced participant scoring systems

### Upgrade Path

The contract is designed with upgradeability in mind:

- Modular architecture allows component upgrades
- Configuration parameters support runtime adjustments
- Interface-based integration enables easy component swapping
- Event-driven architecture supports analytics expansion

## Support & Documentation

- **Technical Support**: [WRFCoin Discord](https://discord.gg/wrfcoin)
- **Documentation**: [GitBook Docs](https://docs.wrfcoin.org)
- **Bug Reports**: [GitHub Issues](https://github.com/wrfcoin/contracts/issues)
- **Feature Requests**: [Community Forum](https://forum.wrfcoin.org)

---

_Last Updated: December 2024_  
_Version: 1.0.0_  
_License: MIT_
