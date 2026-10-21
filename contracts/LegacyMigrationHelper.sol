// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./DecentralizedFairLaunch.sol";
import "./interfaces/ILayawayRegistration.sol";
import "./interfaces/IMultiAssetStaking.sol";
import "./interfaces/ISocialVerification.sol";
import "./interfaces/ISlashingMechanism.sol";
import "./interfaces/IParticipantTypeRegistry.sol";

/**
 * @title LegacyMigrationHelper
 * @author WRFCoin Development Team
 * @notice Migration contract to transition from centralized to decentralized fair launch
 * @dev One-time migration helper with NO ongoing admin controls
 * 
 * === MIGRATION PHILOSOPHY ===
 * 
 * This contract helps participants migrate from the old centralized system to the
 * new decentralized one. It does NOT have admin controls and cannot be used to
 * recreate centralization in the new system.
 * 
 * Migration Process:
 * 1. Participant calls migration function with proof of legacy stake
 * 2. Contract validates stake exists in legacy contracts
 * 3. New stake is created in DecentralizedFairLaunch with equivalent value
 * 4. Migration record prevents double-migration
 * 
 * === SECURITY GUARANTEES ===
 * 
 * - NO admin functions after deployment
 * - Cannot modify participant stakes in new system
 * - Cannot bypass new system's security mechanisms
 * - One-time migration only (no re-entry)
 * - Transparent migration records for audit
 * 
 * This contract becomes obsolete once all migrations are complete.
 */
contract LegacyMigrationHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================================
    //                                 CONSTANTS
    // ============================================================================
    
    /// @dev Migration window duration (90 days from deployment)
    uint256 public constant MIGRATION_WINDOW = 90 days;
    
    /// @dev Maximum ETH that can be migrated per transaction (100 ETH)
    uint256 public constant MAX_MIGRATION_AMOUNT = 100 ether;
    
    /// @dev Migration fee to prevent spam (0.001 ETH)
    uint256 public constant MIGRATION_FEE = 0.001 ether;

    // ============================================================================
    //                                   ENUMS
    // ============================================================================
    
    enum LegacyContractType {
        LAYAWAY_REGISTRATION,
        MULTI_ASSET_STAKING,
        SOCIAL_VERIFICATION,
        SLASHING_MECHANISM,
        PARTICIPANT_REGISTRY
    }
    
    enum MigrationStatus {
        NOT_MIGRATED,      // Has not migrated yet
        MIGRATED,          // Successfully migrated
        FAILED,            // Migration attempted but failed
        BLOCKED            // Blocked from migration (slashing, etc.)
    }

    // ============================================================================
    //                                  STRUCTS
    // ============================================================================
    
    /// @dev Migration record for audit and prevention of double-migration
    struct MigrationRecord {
        address participant;                    // Address that migrated
        uint256 legacyStakeAmount;             // Amount staked in legacy system
        uint256 migratedAmount;                // Amount migrated to new system
        DecentralizedFairLaunch.RegistrationPath newPath; // Path chosen in new system
        uint256 migrationTime;                 // When migration occurred
        MigrationStatus status;                // Migration status
        bytes32 legacyProofHash;               // Hash of legacy proof data
        string migrationNotes;                 // Any notes about the migration
    }
    
    /// @dev Legacy contract integration data
    struct LegacyContractInfo {
        address contractAddress;               // Address of legacy contract
        bool isActive;                         // Whether migration from this contract is active
        uint256 totalMigrations;               // Number of successful migrations
        uint256 totalAmountMigrated;           // Total ETH migrated from this contract
    }
    
    /// @dev Proof data for legacy stake verification
    struct LegacyStakeProof {
        LegacyContractType contractType;       // Which legacy contract
        bytes32 stakeHash;                     // Hash of stake data
        uint256 stakeAmount;                   // Amount staked in legacy system
        uint256 stakingTime;                   // When stake was created
        bytes additionalData;                  // Additional verification data
        bytes signature;                       // Signature for verification (if needed)
    }

    // ============================================================================
    //                              STATE VARIABLES
    // ============================================================================
    
    /// @dev Migration tracking
    mapping(address => MigrationRecord) public migrationRecords;
    mapping(bytes32 => bool) public usedLegacyProofs; // Prevent proof reuse
    
    /// @dev Legacy contract integration
    mapping(LegacyContractType => LegacyContractInfo) public legacyContracts;
    
    /// @dev New decentralized system integration
    DecentralizedFairLaunch public immutable decentralizedFairLaunch;
    
    /// @dev Migration window control
    uint256 public immutable deploymentTime;
    uint256 public immutable migrationDeadline;
    
    /// @dev Migration statistics
    uint256 public totalMigrations;
    uint256 public totalAmountMigrated;
    uint256 public migrationFeesCollected;
    
    /// @dev Migration failure tracking
    mapping(address => string) public migrationFailureReasons;

    // ============================================================================
    //                                  EVENTS
    // ============================================================================
    
    event MigrationStarted(
        address indexed participant,
        LegacyContractType indexed legacyContract,
        uint256 legacyStakeAmount,
        bytes32 proofHash
    );
    
    event MigrationCompleted(
        address indexed participant,
        uint256 legacyStakeAmount,
        uint256 migratedAmount,
        DecentralizedFairLaunch.RegistrationPath newPath,
        uint256 timestamp
    );
    
    event MigrationFailed(
        address indexed participant,
        string reason,
        bytes32 proofHash,
        uint256 timestamp
    );
    
    event LegacyContractConfigured(
        LegacyContractType indexed contractType,
        address indexed contractAddress,
        bool active
    );
    
    event MigrationWindowExpired(
        uint256 deadline,
        uint256 totalMigrations,
        uint256 totalAmountMigrated
    );

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Deploy migration helper
     * @param _decentralizedFairLaunch Address of new decentralized fair launch contract
     * @param _legacyLayaway Address of legacy LayawayRegistration contract
     * @param _legacyMultiAsset Address of legacy MultiAssetStaking contract
     * @param _legacySocialVerification Address of legacy SocialVerification contract
     * @param _legacySlashing Address of legacy SlashingMechanism contract
     * @param _legacyParticipantRegistry Address of legacy ParticipantTypeRegistry contract
     */
    constructor(
        address _decentralizedFairLaunch,
        address _legacyLayaway,
        address _legacyMultiAsset,
        address _legacySocialVerification,
        address _legacySlashing,
        address _legacyParticipantRegistry
    ) {
        require(_decentralizedFairLaunch != address(0), "Invalid decentralized fair launch");
        
        decentralizedFairLaunch = DecentralizedFairLaunch(payable(_decentralizedFairLaunch));
        deploymentTime = block.timestamp;
        migrationDeadline = block.timestamp + MIGRATION_WINDOW;
        
        // Configure legacy contracts
        _configureLegacyContract(LegacyContractType.LAYAWAY_REGISTRATION, _legacyLayaway);
        _configureLegacyContract(LegacyContractType.MULTI_ASSET_STAKING, _legacyMultiAsset);
        _configureLegacyContract(LegacyContractType.SOCIAL_VERIFICATION, _legacySocialVerification);
        _configureLegacyContract(LegacyContractType.SLASHING_MECHANISM, _legacySlashing);
        _configureLegacyContract(LegacyContractType.PARTICIPANT_REGISTRY, _legacyParticipantRegistry);
        
        // NO ADMIN ROLES SET - This is a one-time migration helper only
    }

    // ============================================================================
    //                            MIGRATION FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Migrate from legacy LayawayRegistration contract
     * @dev Migrates layaway participants to appropriate new system path
     * @param newPath Which registration path to use in new system
     */
    function migrateFromLayaway(DecentralizedFairLaunch.RegistrationPath newPath) 
        external 
        payable 
        nonReentrant 
    {
        require(block.timestamp <= migrationDeadline, "Migration window closed");
        require(msg.value >= MIGRATION_FEE, "Insufficient migration fee");
        require(migrationRecords[msg.sender].status == MigrationStatus.NOT_MIGRATED, "Already migrated");
        
        address legacyContract = legacyContracts[LegacyContractType.LAYAWAY_REGISTRATION].contractAddress;
        require(legacyContract != address(0), "Legacy contract not configured");
        
        // Verify participant exists in legacy system
        try ILayawayRegistration(legacyContract).getLayawayAccount(msg.sender) returns (
            ILayawayRegistration.LayawayAccount memory account
        ) {
            require(account.participant == msg.sender, "No legacy layaway account");
            require(account.status == ILayawayRegistration.LayawayStatus.ACTIVE, "Legacy account not active");
            
            uint256 migrationAmount = _calculateMigrationAmount(account.accumulatedStake, account.requiredStake);
            require(migrationAmount > 0, "No stake to migrate");
            require(msg.value >= migrationAmount + MIGRATION_FEE, "Insufficient ETH for migration");
            
            // Create migration record
            bytes32 proofHash = keccak256(abi.encode(msg.sender, account.accumulatedStake, block.timestamp));
            _createMigrationRecord(msg.sender, account.accumulatedStake, migrationAmount, newPath, proofHash);
            
            // Register in new decentralized system
            bool success = _registerInNewSystem(newPath, migrationAmount, proofHash);
            
            if (success) {
                migrationRecords[msg.sender].status = MigrationStatus.MIGRATED;
                _updateMigrationStats(LegacyContractType.LAYAWAY_REGISTRATION, migrationAmount);
                
                emit MigrationCompleted(msg.sender, account.accumulatedStake, migrationAmount, newPath, block.timestamp);
            } else {
                migrationRecords[msg.sender].status = MigrationStatus.FAILED;
                migrationFailureReasons[msg.sender] = "Failed to register in new system";
                
                emit MigrationFailed(msg.sender, "Registration failed", proofHash, block.timestamp);
            }
            
        } catch {
            emit MigrationFailed(msg.sender, "Legacy account verification failed", bytes32(0), block.timestamp);
            revert("Legacy account verification failed");
        }
    }
    
    /**
     * @notice Migrate from legacy MultiAssetStaking contract
     * @dev Migrates multi-asset stakes to basic ETH staking in new system
     * @param newPath Which registration path to use in new system
     */
    function migrateFromMultiAssetStaking(DecentralizedFairLaunch.RegistrationPath newPath) 
        external 
        payable 
        nonReentrant 
    {
        require(block.timestamp <= migrationDeadline, "Migration window closed");
        require(msg.value >= MIGRATION_FEE, "Insufficient migration fee");
        require(migrationRecords[msg.sender].status == MigrationStatus.NOT_MIGRATED, "Already migrated");
        
        address legacyContract = legacyContracts[LegacyContractType.MULTI_ASSET_STAKING].contractAddress;
        require(legacyContract != address(0), "Legacy contract not configured");
        
        // Get comprehensive stake info from legacy contract
        try IMultiAssetStaking(legacyContract).getComprehensiveStakeInfo(msg.sender) returns (
            uint256 totalStakeUSD,
            uint256 requiredStakeUSD,
            uint256 collateralizationRatio,
            bool meetsRequirement,
            address[] memory stakedAssets,
            uint256[] memory assetAmounts,
            uint256[] memory assetValuesUSD
        ) {
            require(totalStakeUSD > 0, "No stake in legacy system");
            require(meetsRequirement, "Legacy stake doesn't meet requirements");
            
            // Convert USD value to ETH (simplified - would use oracle in production)
            uint256 migrationAmount = _convertUSDToETH(totalStakeUSD);
            require(msg.value >= migrationAmount + MIGRATION_FEE, "Insufficient ETH for migration");
            
            // Create migration record
            bytes32 proofHash = keccak256(abi.encode(msg.sender, totalStakeUSD, stakedAssets));
            _createMigrationRecord(msg.sender, migrationAmount, migrationAmount, newPath, proofHash);
            
            // Register in new decentralized system
            bool success = _registerInNewSystem(newPath, migrationAmount, proofHash);
            
            if (success) {
                migrationRecords[msg.sender].status = MigrationStatus.MIGRATED;
                _updateMigrationStats(LegacyContractType.MULTI_ASSET_STAKING, migrationAmount);
                
                emit MigrationCompleted(msg.sender, migrationAmount, migrationAmount, newPath, block.timestamp);
            } else {
                migrationRecords[msg.sender].status = MigrationStatus.FAILED;
                migrationFailureReasons[msg.sender] = "Failed to register in new system";
                
                emit MigrationFailed(msg.sender, "Registration failed", proofHash, block.timestamp);
            }
            
        } catch {
            emit MigrationFailed(msg.sender, "Legacy stake verification failed", bytes32(0), block.timestamp);
            revert("Legacy stake verification failed");
        }
    }
    
    /**
     * @notice Migrate with social verification benefits
     * @dev Automatically uses MERIT path if social verification exists
     */
    function migrateWithSocialVerification() 
        external 
        payable 
        nonReentrant 
    {
        require(block.timestamp <= migrationDeadline, "Migration window closed");
        require(msg.value >= MIGRATION_FEE, "Insufficient migration fee");
        require(migrationRecords[msg.sender].status == MigrationStatus.NOT_MIGRATED, "Already migrated");
        
        address legacyContract = legacyContracts[LegacyContractType.SOCIAL_VERIFICATION].contractAddress;
        require(legacyContract != address(0), "Legacy social verification not configured");
        
        // Check for social verifications in legacy system
        try ISocialVerification(legacyContract).getCombinedDiscount(msg.sender) returns (
            uint256 totalDiscount,
            uint256[3] memory platformDiscounts,
            bool hasActiveVerifications
        ) {
            require(hasActiveVerifications, "No social verifications found");
            
            // Calculate migration amount with social verification discount
            uint256 baseMigrationAmount = decentralizedFairLaunch.MIN_ETH_STAKE();
            uint256 discountedAmount = (baseMigrationAmount * (10000 - totalDiscount)) / 10000;
            
            require(msg.value >= discountedAmount + MIGRATION_FEE, "Insufficient ETH for migration");
            
            // Create contribution proof for merit path
            bytes32 contributionProof = keccak256(abi.encode(
                msg.sender,
                "SocialVerificationMigration",
                totalDiscount,
                block.timestamp
            ));
            
            // Create migration record
            _createMigrationRecord(msg.sender, baseMigrationAmount, discountedAmount, 
                                DecentralizedFairLaunch.RegistrationPath.MERIT, contributionProof);
            
            // Register in new system using merit path
            try decentralizedFairLaunch.registerMeritPath{value: discountedAmount}(
                contributionProof,
                "SocialVerificationMigration"
            ) {
                migrationRecords[msg.sender].status = MigrationStatus.MIGRATED;
                _updateMigrationStats(LegacyContractType.SOCIAL_VERIFICATION, discountedAmount);
                
                emit MigrationCompleted(
                    msg.sender, 
                    baseMigrationAmount, 
                    discountedAmount, 
                    DecentralizedFairLaunch.RegistrationPath.MERIT, 
                    block.timestamp
                );
            } catch {
                migrationRecords[msg.sender].status = MigrationStatus.FAILED;
                migrationFailureReasons[msg.sender] = "Merit registration failed";
                
                emit MigrationFailed(msg.sender, "Merit registration failed", contributionProof, block.timestamp);
            }
            
        } catch {
            emit MigrationFailed(msg.sender, "Social verification check failed", bytes32(0), block.timestamp);
            revert("Social verification check failed");
        }
    }
    
    /**
     * @notice Emergency migration for participants with complex legacy stakes
     * @dev Fallback migration method for edge cases
     * @param legacyProof Proof of legacy participation
     */
    function emergencyMigration(LegacyStakeProof calldata legacyProof) 
        external 
        payable 
        nonReentrant 
    {
        require(block.timestamp <= migrationDeadline, "Migration window closed");
        require(msg.value >= MIGRATION_FEE * 2, "Insufficient emergency migration fee"); // Higher fee for emergency
        require(migrationRecords[msg.sender].status == MigrationStatus.NOT_MIGRATED, "Already migrated");
        require(!usedLegacyProofs[legacyProof.stakeHash], "Proof already used");
        
        // Validate the proof
        require(_validateLegacyProof(legacyProof), "Invalid legacy proof");
        
        uint256 migrationAmount = legacyProof.stakeAmount;
        require(migrationAmount > 0, "No stake to migrate");
        require(migrationAmount <= MAX_MIGRATION_AMOUNT, "Migration amount too high");
        require(msg.value >= migrationAmount + MIGRATION_FEE * 2, "Insufficient ETH for emergency migration");
        
        // Mark proof as used
        usedLegacyProofs[legacyProof.stakeHash] = true;
        
        // Create migration record
        _createMigrationRecord(
            msg.sender, 
            migrationAmount, 
            migrationAmount, 
            DecentralizedFairLaunch.RegistrationPath.BASIC, 
            legacyProof.stakeHash
        );
        
        // Register in new system using basic path
        bool success = _registerInNewSystem(
            DecentralizedFairLaunch.RegistrationPath.BASIC, 
            migrationAmount, 
            legacyProof.stakeHash
        );
        
        if (success) {
            migrationRecords[msg.sender].status = MigrationStatus.MIGRATED;
            _updateMigrationStats(legacyProof.contractType, migrationAmount);
            
            emit MigrationCompleted(
                msg.sender, 
                migrationAmount, 
                migrationAmount, 
                DecentralizedFairLaunch.RegistrationPath.BASIC, 
                block.timestamp
            );
        } else {
            migrationRecords[msg.sender].status = MigrationStatus.FAILED;
            migrationFailureReasons[msg.sender] = "Emergency registration failed";
            
            emit MigrationFailed(msg.sender, "Emergency registration failed", legacyProof.stakeHash, block.timestamp);
        }
    }

    // ============================================================================
    //                              INTERNAL FUNCTIONS
    // ============================================================================
    
    /**
     * @dev Configure a legacy contract for migration
     */
    function _configureLegacyContract(LegacyContractType contractType, address contractAddress) internal {
        if (contractAddress != address(0)) {
            legacyContracts[contractType] = LegacyContractInfo({
                contractAddress: contractAddress,
                isActive: true,
                totalMigrations: 0,
                totalAmountMigrated: 0
            });
            
            emit LegacyContractConfigured(contractType, contractAddress, true);
        }
    }
    
    /**
     * @dev Create migration record
     */
    function _createMigrationRecord(
        address participant,
        uint256 legacyStakeAmount,
        uint256 migratedAmount,
        DecentralizedFairLaunch.RegistrationPath newPath,
        bytes32 proofHash
    ) internal {
        migrationRecords[participant] = MigrationRecord({
            participant: participant,
            legacyStakeAmount: legacyStakeAmount,
            migratedAmount: migratedAmount,
            newPath: newPath,
            migrationTime: block.timestamp,
            status: MigrationStatus.NOT_MIGRATED, // Will be updated after successful registration
            legacyProofHash: proofHash,
            migrationNotes: ""
        });
        
        migrationFeesCollected += MIGRATION_FEE;
    }
    
    /**
     * @dev Register participant in new decentralized system
     */
    function _registerInNewSystem(
        DecentralizedFairLaunch.RegistrationPath path,
        uint256 amount,
        bytes32 proofHash
    ) internal returns (bool) {
        try decentralizedFairLaunch.migrateFromLegacy{value: amount}(proofHash) {
            return true;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Update migration statistics
     */
    function _updateMigrationStats(LegacyContractType contractType, uint256 amount) internal {
        totalMigrations++;
        totalAmountMigrated += amount;
        
        LegacyContractInfo storage info = legacyContracts[contractType];
        info.totalMigrations++;
        info.totalAmountMigrated += amount;
    }
    
    /**
     * @dev Calculate appropriate migration amount based on legacy stake
     */
    function _calculateMigrationAmount(uint256 accumulated, uint256 required) internal pure returns (uint256) {
        // If they completed their layaway, migrate the full accumulated amount
        if (accumulated >= required) {
            return accumulated;
        }
        
        // If they partially completed, migrate proportionally
        if (accumulated > 0) {
            return accumulated;
        }
        
        return 0;
    }
    
    /**
     * @dev Convert USD value to ETH (simplified)
     * @dev In production, this would use a price oracle
     */
    function _convertUSDToETH(uint256 usdValue) internal pure returns (uint256) {
        // Simplified conversion assuming 1 ETH = $2000
        // In production, use Chainlink or another price oracle
        return (usdValue * 1e18) / 2000e18; // Very simplified
    }
    
    /**
     * @dev Validate legacy proof for emergency migrations
     */
    function _validateLegacyProof(LegacyStakeProof calldata proof) internal view returns (bool) {
        // Basic validation - in production this would be more comprehensive
        if (proof.stakeAmount == 0) return false;
        if (proof.stakingTime > block.timestamp) return false;
        if (proof.stakingTime < deploymentTime - 365 days) return false; // Must be within reasonable timeframe
        
        // Check that proof hash hasn't been used
        if (usedLegacyProofs[proof.stakeHash]) return false;
        
        return true;
    }

    // ============================================================================
    //                               VIEW FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Get migration record for a participant
     * @param participant Address to query
     * @return Migration record data
     */
    function getMigrationRecord(address participant) external view returns (MigrationRecord memory) {
        return migrationRecords[participant];
    }
    
    /**
     * @notice Get legacy contract information
     * @param contractType Type of legacy contract
     * @return Legacy contract info
     */
    function getLegacyContractInfo(LegacyContractType contractType) external view returns (LegacyContractInfo memory) {
        return legacyContracts[contractType];
    }
    
    /**
     * @notice Get migration statistics
     */
    function getMigrationStats() external view returns (
        uint256 _totalMigrations,
        uint256 _totalAmountMigrated,
        uint256 _migrationFeesCollected,
        uint256 _migrationDeadline,
        bool _migrationActive
    ) {
        return (
            totalMigrations,
            totalAmountMigrated,
            migrationFeesCollected,
            migrationDeadline,
            block.timestamp <= migrationDeadline
        );
    }
    
    /**
     * @notice Check if migration is still possible
     * @return Whether migration window is open
     */
    function isMigrationActive() external view returns (bool) {
        return block.timestamp <= migrationDeadline;
    }
    
    /**
     * @notice Get time remaining for migration
     * @return Seconds remaining in migration window
     */
    function timeRemainingForMigration() external view returns (uint256) {
        if (block.timestamp >= migrationDeadline) {
            return 0;
        }
        return migrationDeadline - block.timestamp;
    }

    // ============================================================================
    //                           MIGRATION WINDOW CLOSURE
    // ============================================================================
    
    /**
     * @notice Finalize migration process after window closes
     * @dev Can be called by anyone after migration deadline
     */
    function finalizeMigration() external nonReentrant {
        require(block.timestamp > migrationDeadline, "Migration window still open");
        
        // Send collected migration fees to the new system's treasury
        if (migrationFeesCollected > 0) {
            (bool ok,) = payable(address(decentralizedFairLaunch)).call{value: migrationFeesCollected}("");
            require(ok, "LegacyMigrationHelper: ETH transfer failed");
        }
        
        emit MigrationWindowExpired(migrationDeadline, totalMigrations, totalAmountMigrated);
    }

    // ============================================================================
    //                              RECEIVE FUNCTION
    // ============================================================================
    
    /**
     * @notice Accept ETH for migrations
     */
    receive() external payable {
        // ETH received for migrations
    }
}