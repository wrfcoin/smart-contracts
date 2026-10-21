// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title CarbonCreditTracker
 * @dev Enterprise-grade cross-chain carbon credit lifecycle tracking system with comprehensive security
 * 
 * Features:
 * - Cross-chain duplicate prevention with cryptographic proofs
 * - Quality score synchronization across networks
 * - Batch bridging operations with gas optimization
 * - Merkle proof verification for credit validity
 * - Anti-replay protection with nonce management
 * - Economic security for high-value credit transfers
 * 
 * @author WRFCoin Security Team
 * @notice Tracks carbon credits across multiple blockchain networks with full lifecycle management
 */
contract CarbonCreditTracker is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    
    // ============ Access Control Roles ============
    
    bytes32 public constant AUTHORIZED_ISSUER_ROLE = keccak256("AUTHORIZED_ISSUER_ROLE");
    bytes32 public constant REGISTRY_CONNECTOR_ROLE = keccak256("REGISTRY_CONNECTOR_ROLE");
    bytes32 public constant CROSS_CHAIN_VALIDATOR_ROLE = keccak256("CROSS_CHAIN_VALIDATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant VERIFICATION_ORACLE_ROLE = keccak256("VERIFICATION_ORACLE_ROLE");

    // ============ Cross-Chain Security Constants ============
    
    uint256 public constant MIN_VALIDATORS_REQUIRED = 3;
    uint256 public constant HIGH_VALUE_THRESHOLD = 10000 ether; // $10K worth of credits
    uint256 public constant CROSS_CHAIN_TIMEOUT = 24 hours;
    uint256 public constant REPLAY_PROTECTION_WINDOW = 7 days;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant VERIFICATION_TIMEOUT = 7 days;

    // Verification oracle address
    address public verificationOracle;

    enum LifecycleStatus {
        ISSUED,
        PENDING_VERIFICATION,
        ACTIVE,
        IMMOBILIZED,
        PARTIALLY_RETIRED,
        FULLY_RETIRED,
        DISPUTED,
        CANCELLED,
        CROSS_CHAIN_PENDING,
        CROSS_CHAIN_LOCKED,
        CROSS_CHAIN_VERIFIED
    }
    
    enum CrossChainOperation {
        BRIDGE_OUT,
        BRIDGE_IN,
        RETIREMENT_SYNC,
        QUALITY_SYNC,
        BATCH_TRANSFER
    }
    
    struct CreditLifecycle {
        uint256 tokenId;
        string projectId;
        string serialNumber;
        string registryStandard;
        address originalIssuer;
        uint256 totalSupply;
        uint256 activeSupply;
        uint256 immobilizedSupply;
        uint256 retiredSupply;
        uint256 issuanceTimestamp;
        uint256 lastVerificationTimestamp;
        bool isVerified;
        string currentLocation;
        LifecycleStatus status;
    }
    
    struct TransferRecord {
        address from;
        address to;
        uint256 amount;
        uint256 timestamp;
        string transferReason;
    }
    
    struct RetirementRecord {
        address retiringEntity;
        uint256 amount;
        uint256 timestamp;
        string retirementMessage;
        string certificateId;
    }
    
    struct RetirementCertificate {
        string certificateId;
        bytes32 lifecycleId;
        address retiringEntity;
        uint256 amount;
        uint256 timestamp;
        string projectId;
        string registryStandard;
        string retirementMessage;
        string ipfsCertificateHash;
        bool isValid;
        uint256 sourceChainId;
        bytes32 crossChainHash;
    }
    
    struct CrossChainProof {
        bytes32 messageHash;
        uint256 sourceChainId;
        uint256 targetChainId;
        address sourceContract;
        address targetContract;
        bytes32[] merkleProof;
        bytes32 merkleRoot;
        bytes[] validatorSignatures;
        uint256 nonce;
        uint256 timestamp;
        bool isVerified;
    }
    
    struct CrossChainTransfer {
        bytes32 transferId;
        bytes32 lifecycleId;
        uint256 sourceChainId;
        uint256 targetChainId;
        address initiator;
        address recipient;
        uint256 amount;
        uint256 qualityScore;
        CrossChainOperation operation;
        uint256 timestamp;
        uint256 expiresAt;
        bool isExecuted;
        bytes32 proofHash;
    }
    
    struct ValidatorInfo {
        address validatorAddress;
        uint256 stake;
        uint256 validatedTransfers;
        bool isActive;
        uint256 lastActivityTimestamp;
        string endpoint;
    }
    
    struct CrossChainRegistry {
        uint256 chainId;
        address contractAddress;
        bool isActive;
        uint256 minimumConfirmations;
        string rpcEndpoint;
        bytes32 registryHash;
    }
    
    // ============ State Variables ============
    
    // Lifecycle tracking
    mapping(bytes32 => CreditLifecycle) public lifecycles;
    mapping(bytes32 => TransferRecord[]) public transferHistory;
    mapping(bytes32 => RetirementRecord[]) public retirementHistory;
    mapping(string => bytes32) public serialToLifecycle; // Prevents double-counting
    mapping(string => RetirementCertificate) public retirementCertificates;
    
    // Cross-chain security mappings
    mapping(bytes32 => CrossChainTransfer) public crossChainTransfers;
    mapping(bytes32 => CrossChainProof) public crossChainProofs;
    mapping(bytes32 => bool) public processedHashes; // Anti-replay protection
    mapping(address => ValidatorInfo) public validators;
    mapping(uint256 => CrossChainRegistry) public crossChainRegistries;
    mapping(bytes32 => uint256) public validatorConfirmations;
    mapping(bytes32 => mapping(address => bool)) public hasValidatorSigned;
    
    // Nonce management for replay protection
    mapping(uint256 => uint256) public chainNonces; // chainId => nonce
    mapping(address => uint256) public userNonces; // user => nonce
    mapping(bytes32 => uint256) public transferNonces; // transferId => nonce
    
    // Registry connections
    mapping(string => address) public registryBridges; // Standard => Bridge Address
    mapping(address => bool) public authorizedRegistries;
    mapping(bytes32 => uint256) public duplicatePreventionHashes; // Global duplicate prevention
    
    // Security tracking
    mapping(address => uint256) public dailyTransferCount;
    mapping(address => uint256) public lastTransferDay;
    mapping(bytes32 => uint256) public highValueLocks; // High-value transfer timelock
    
    // Gas optimization - batch operations
    mapping(bytes32 => bytes32[]) public batchTransferGroups;
    mapping(bytes32 => uint256) public batchExecutionTimestamp;
    
    // Counters and tracking
    uint256 private certificateCounter;
    uint256 public totalCrossChainTransfers;
    uint256 public successfulTransfers;
    uint256 public failedTransfers;
    address[] public validatorList;
    
    // ============ Enhanced Security Events ============
    
    event CreditLifecycleCreated(
        bytes32 indexed lifecycleId,
        uint256 indexed tokenId,
        string projectId,
        string registryStandard,
        address indexed issuer,
        uint256 chainId
    );
    
    event CreditRetired(
        bytes32 indexed lifecycleId,
        address indexed retiringEntity,
        uint256 amount,
        string retirementMessage,
        string retirementCertificateHash,
        uint256 timestamp,
        uint256 sourceChainId
    );
    
    event CreditTransferred(
        bytes32 indexed lifecycleId,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 timestamp,
        string transferReason
    );
    
    event RetirementCertificateGenerated(
        bytes32 indexed lifecycleId,
        string certificateId,
        address indexed retiringEntity,
        uint256 amount,
        string ipfsCertificateHash,
        uint256 sourceChainId
    );
    
    // Cross-chain security events
    event CrossChainTransferInitiated(
        bytes32 indexed transferId,
        bytes32 indexed lifecycleId,
        uint256 indexed sourceChainId,
        uint256 targetChainId,
        address initiator,
        uint256 amount,
        CrossChainOperation operation
    );
    
    event CrossChainTransferValidated(
        bytes32 indexed transferId,
        address indexed validator,
        uint256 confirmations,
        bytes32 proofHash
    );
    
    event CrossChainTransferCompleted(
        bytes32 indexed transferId,
        bytes32 indexed lifecycleId,
        uint256 targetChainId,
        bool success
    );
    
    event DuplicateTransferPrevented(
        bytes32 indexed transferId,
        bytes32 duplicateHash,
        uint256 sourceChainId,
        address indexed initiator
    );
    
    event ValidatorAdded(
        address indexed validator,
        uint256 stake,
        string endpoint
    );
    
    event ValidatorRemoved(
        address indexed validator,
        string reason
    );
    
    event CrossChainRegistryUpdated(
        uint256 indexed chainId,
        address contractAddress,
        bool isActive
    );
    
    event HighValueTransferQueued(
        bytes32 indexed transferId,
        uint256 amount,
        uint256 releaseTime
    );
    
    event BatchTransferExecuted(
        bytes32 indexed batchId,
        uint256 transferCount,
        uint256 totalAmount
    );
    
    event SecurityViolation(
        bytes32 indexed transferId,
        address indexed violator,
        string violationType,
        uint256 timestamp
    );
    
    event QualitySynchronized(
        bytes32 indexed lifecycleId,
        uint256 sourceChainId,
        uint256 targetChainId,
        uint256 qualityScore
    );
    
    // ============ Security Modifiers ============
    
    modifier onlyAuthorizedIssuer() {
        require(hasRole(AUTHORIZED_ISSUER_ROLE, msg.sender), "CarbonCreditTracker: Not authorized issuer");
        _;
    }
    
    modifier onlyRegistryConnector() {
        require(hasRole(REGISTRY_CONNECTOR_ROLE, msg.sender), "CarbonCreditTracker: Not registry connector");
        _;
    }
    
    modifier onlyValidator() {
        require(hasRole(CROSS_CHAIN_VALIDATOR_ROLE, msg.sender), "CarbonCreditTracker: Not validator");
        require(validators[msg.sender].isActive, "CarbonCreditTracker: Validator inactive");
        _;
    }
    
    modifier onlyEmergencyRole() {
        require(hasRole(EMERGENCY_ROLE, msg.sender), "CarbonCreditTracker: Not emergency admin");
        _;
    }
    
    modifier rateLimited() {
        uint256 currentDay = block.timestamp / 86400;
        if (lastTransferDay[msg.sender] != currentDay) {
            dailyTransferCount[msg.sender] = 0;
            lastTransferDay[msg.sender] = currentDay;
        }
        require(dailyTransferCount[msg.sender] < 100, "CarbonCreditTracker: Daily rate limit exceeded");
        dailyTransferCount[msg.sender]++;
        _;
    }
    
    modifier validChain(uint256 chainId) {
        require(crossChainRegistries[chainId].isActive, "CarbonCreditTracker: Unsupported chain");
        _;
    }
    
    modifier nonReplayable(bytes32 messageHash) {
        require(!processedHashes[messageHash], "CarbonCreditTracker: Message already processed");
        processedHashes[messageHash] = true;
        _;
    }

    modifier onlyVerificationOracle() {
        require(hasRole(VERIFICATION_ORACLE_ROLE, msg.sender), "CarbonCreditTracker: Not verification oracle");
        _;
    }

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUTHORIZED_ISSUER_ROLE, msg.sender);
        _grantRole(REGISTRY_CONNECTOR_ROLE, msg.sender);
        _grantRole(CROSS_CHAIN_VALIDATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        // Initialize current chain registry
        crossChainRegistries[block.chainid] = CrossChainRegistry({
            chainId: block.chainid,
            contractAddress: address(this),
            isActive: true,
            minimumConfirmations: 1,
            rpcEndpoint: "",
            registryHash: keccak256(abi.encodePacked("CARBON_TRACKER", block.chainid))
        });
    }
    
    /**
     * @dev Create a new lifecycle tracking record
     */
    function createLifecycle(
        uint256 tokenId,
        string memory projectId,
        string memory serialNumber,
        string memory registryStandard,
        address originalIssuer,
        uint256 totalSupply
    ) external onlyAuthorizedIssuer whenNotPaused returns (bytes32 lifecycleId) {
        require(bytes(serialNumber).length > 0, "CarbonCreditTracker: Invalid serial number");
        require(serialToLifecycle[serialNumber] == bytes32(0), "CarbonCreditTracker: Serial number already used");
        require(totalSupply > 0, "CarbonCreditTracker: Invalid total supply");
        
        lifecycleId = keccak256(abi.encodePacked(
            tokenId,
            projectId,
            serialNumber,
            registryStandard,
            block.timestamp,
            originalIssuer
        ));
        
        lifecycles[lifecycleId] = CreditLifecycle({
            tokenId: tokenId,
            projectId: projectId,
            serialNumber: serialNumber,
            registryStandard: registryStandard,
            originalIssuer: originalIssuer,
            totalSupply: totalSupply,
            activeSupply: totalSupply,
            immobilizedSupply: 0,
            retiredSupply: 0,
            issuanceTimestamp: block.timestamp,
            lastVerificationTimestamp: block.timestamp,
            isVerified: false,
            currentLocation: "ISSUED",
            status: LifecycleStatus.ISSUED
        });
        
        serialToLifecycle[serialNumber] = lifecycleId;
        
        emit CreditLifecycleCreated(lifecycleId, tokenId, projectId, registryStandard, originalIssuer, block.chainid);
        
        return lifecycleId;
    }
    
    /**
     * @dev Record a transfer in the lifecycle
     */
    function recordTransfer(
        bytes32 lifecycleId,
        address from,
        address to,
        uint256 amount,
        string memory transferReason
    ) external whenNotPaused {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(amount > 0, "CarbonCreditTracker: Invalid amount");
        require(
            lifecycles[lifecycleId].status == LifecycleStatus.ACTIVE ||
            lifecycles[lifecycleId].status == LifecycleStatus.PARTIALLY_RETIRED ||
            lifecycles[lifecycleId].status == LifecycleStatus.CROSS_CHAIN_VERIFIED,
            "CarbonCreditTracker: Credit not in transferable status"
        );

        transferHistory[lifecycleId].push(TransferRecord({
            from: from,
            to: to,
            amount: amount,
            timestamp: block.timestamp,
            transferReason: transferReason
        }));

        emit CreditTransferred(lifecycleId, from, to, amount, block.timestamp, transferReason);
    }
    
    /**
     * @dev Record retirement and generate certificate
     */
    function recordRetirement(
        bytes32 lifecycleId,
        address retiringEntity,
        uint256 amount,
        string memory retirementMessage
    ) external onlyRegistryConnector whenNotPaused returns (string memory certificateId) {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(amount > 0, "CarbonCreditTracker: Invalid amount");
        require(amount <= lifecycles[lifecycleId].activeSupply, "CarbonCreditTracker: Insufficient active supply");
        require(
            lifecycles[lifecycleId].status != LifecycleStatus.PENDING_VERIFICATION &&
            lifecycles[lifecycleId].status != LifecycleStatus.ISSUED,
            "CarbonCreditTracker: Credit not verified for retirement"
        );

        // Update lifecycle state
        lifecycles[lifecycleId].activeSupply -= amount;
        lifecycles[lifecycleId].retiredSupply += amount;
        
        if (lifecycles[lifecycleId].activeSupply == 0) {
            lifecycles[lifecycleId].status = LifecycleStatus.FULLY_RETIRED;
        } else {
            lifecycles[lifecycleId].status = LifecycleStatus.PARTIALLY_RETIRED;
        }
        
        // Generate certificate ID
        certificateCounter++;
        certificateId = string(abi.encodePacked(
            lifecycles[lifecycleId].registryStandard,
            "-RET-",
            _toString(certificateCounter),
            "-",
            _toString(block.timestamp)
        ));
        
        // Create retirement record
        retirementHistory[lifecycleId].push(RetirementRecord({
            retiringEntity: retiringEntity,
            amount: amount,
            timestamp: block.timestamp,
            retirementMessage: retirementMessage,
            certificateId: certificateId
        }));
        
        // Generate certificate (would upload to IPFS in production)
        string memory ipfsHash = _generateCertificateHash(lifecycleId, certificateId, amount);
        
        retirementCertificates[certificateId] = RetirementCertificate({
            certificateId: certificateId,
            lifecycleId: lifecycleId,
            retiringEntity: retiringEntity,
            amount: amount,
            timestamp: block.timestamp,
            projectId: lifecycles[lifecycleId].projectId,
            registryStandard: lifecycles[lifecycleId].registryStandard,
            retirementMessage: retirementMessage,
            ipfsCertificateHash: ipfsHash,
            isValid: true,
            sourceChainId: block.chainid,
            crossChainHash: keccak256(abi.encodePacked(lifecycleId, certificateId, block.chainid))
        });
        
        emit CreditRetired(lifecycleId, retiringEntity, amount, retirementMessage, ipfsHash, block.timestamp, block.chainid);
        emit RetirementCertificateGenerated(lifecycleId, certificateId, retiringEntity, amount, ipfsHash, block.chainid);
        
        return certificateId;
    }
    
    /**
     * @dev Get lifecycle information
     */
    function getLifecycle(bytes32 lifecycleId) external view returns (CreditLifecycle memory) {
        return lifecycles[lifecycleId];
    }
    
    /**
     * @dev Get retirement certificate
     */
    function getRetirementCertificate(
        string memory certificateId
    ) external view returns (RetirementCertificate memory) {
        return retirementCertificates[certificateId];
    }
    
    /**
     * @dev Check if serial number is already used
     */
    function isSerialNumberUsed(string memory serialNumber) external view returns (bool) {
        return serialToLifecycle[serialNumber] != bytes32(0);
    }
    
    /**
     * @dev Verify certificate authenticity
     */
    function verifyCertificate(string memory certificateId) external view returns (bool) {
        return retirementCertificates[certificateId].isValid;
    }
    
    /**
     * @dev Get transfer history for a lifecycle
     */
    function getTransferHistory(bytes32 lifecycleId) external view returns (TransferRecord[] memory) {
        return transferHistory[lifecycleId];
    }
    
    /**
     * @dev Get retirement history for a lifecycle
     */
    function getRetirementHistory(bytes32 lifecycleId) external view returns (RetirementRecord[] memory) {
        return retirementHistory[lifecycleId];
    }
    
    /**
     * @dev Get comprehensive lifecycle summary
     */
    function getLifecycleSummary(bytes32 lifecycleId) external view returns (
        uint256 tokenId,
        string memory projectId,
        string memory serialNumber,
        uint256 activeSupply,
        uint256 retiredSupply,
        bool isVerified,
        uint256 transferCount,
        uint256 retirementCount
    ) {
        CreditLifecycle memory lifecycle = lifecycles[lifecycleId];
        require(lifecycle.tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        
        return (
            lifecycle.tokenId,
            lifecycle.projectId,
            lifecycle.serialNumber,
            lifecycle.activeSupply,
            lifecycle.retiredSupply,
            lifecycle.isVerified,
            transferHistory[lifecycleId].length,
            retirementHistory[lifecycleId].length
        );
    }
    
    // ============ Verification Oracle Functions ============

    function setVerificationOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_oracle != address(0), "CarbonCreditTracker: Invalid oracle");
        verificationOracle = _oracle;
        _grantRole(VERIFICATION_ORACLE_ROLE, _oracle);
    }

    function setVerificationPending(bytes32 lifecycleId) external onlyVerificationOracle whenNotPaused {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(
            lifecycles[lifecycleId].status == LifecycleStatus.ISSUED,
            "CarbonCreditTracker: Must be in ISSUED status"
        );
        lifecycles[lifecycleId].status = LifecycleStatus.PENDING_VERIFICATION;
    }

    function confirmVerification(bytes32 lifecycleId) external onlyVerificationOracle whenNotPaused {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(
            lifecycles[lifecycleId].status == LifecycleStatus.PENDING_VERIFICATION,
            "CarbonCreditTracker: Must be pending verification"
        );
        lifecycles[lifecycleId].status = LifecycleStatus.ACTIVE;
        lifecycles[lifecycleId].isVerified = true;
        lifecycles[lifecycleId].lastVerificationTimestamp = block.timestamp;
        lifecycles[lifecycleId].currentLocation = "VERIFIED_ACTIVE";
    }

    function rejectVerification(bytes32 lifecycleId) external onlyVerificationOracle whenNotPaused {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(
            lifecycles[lifecycleId].status == LifecycleStatus.PENDING_VERIFICATION,
            "CarbonCreditTracker: Must be pending verification"
        );
        lifecycles[lifecycleId].status = LifecycleStatus.CANCELLED;
        lifecycles[lifecycleId].isVerified = false;
    }

    function setDisputed(bytes32 lifecycleId) external onlyVerificationOracle whenNotPaused {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(
            lifecycles[lifecycleId].status == LifecycleStatus.ACTIVE,
            "CarbonCreditTracker: Must be active to dispute"
        );
        lifecycles[lifecycleId].status = LifecycleStatus.DISPUTED;
        lifecycles[lifecycleId].isVerified = false;
    }

    function resolveDispute(bytes32 lifecycleId, bool verified) external onlyVerificationOracle whenNotPaused {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(
            lifecycles[lifecycleId].status == LifecycleStatus.DISPUTED,
            "CarbonCreditTracker: Must be disputed"
        );
        if (verified) {
            lifecycles[lifecycleId].status = LifecycleStatus.ACTIVE;
            lifecycles[lifecycleId].isVerified = true;
            lifecycles[lifecycleId].lastVerificationTimestamp = block.timestamp;
            lifecycles[lifecycleId].currentLocation = "VERIFIED_ACTIVE";
        } else {
            lifecycles[lifecycleId].status = LifecycleStatus.CANCELLED;
            lifecycles[lifecycleId].isVerified = false;
        }
    }

    // ============ Cross-Chain Bridge Functions ============
    
    /**
     * @notice Initiate cross-chain transfer of carbon credits with comprehensive security
     * @param lifecycleId The lifecycle to transfer
     * @param targetChainId Destination chain ID
     * @param recipient Recipient address on target chain
     * @param amount Amount of credits to transfer
     * @param operation Type of cross-chain operation
     * @dev Implements duplicate prevention, high-value timelock, and validator consensus
     */
    function initiateCrossChainTransfer(
        bytes32 lifecycleId,
        uint256 targetChainId,
        address recipient,
        uint256 amount,
        CrossChainOperation operation
    ) external whenNotPaused rateLimited validChain(targetChainId) returns (bytes32 transferId) {
        require(lifecycles[lifecycleId].tokenId != 0, "CarbonCreditTracker: Lifecycle not found");
        require(recipient != address(0), "CarbonCreditTracker: Invalid recipient");
        require(amount > 0, "CarbonCreditTracker: Invalid amount");
        require(amount <= lifecycles[lifecycleId].activeSupply, "CarbonCreditTracker: Insufficient supply");
        require(targetChainId != block.chainid, "CarbonCreditTracker: Cannot transfer to same chain");
        
        // Generate transfer ID with replay protection
        transferId = keccak256(abi.encodePacked(
            lifecycleId,
            targetChainId,
            recipient,
            amount,
            operation,
            chainNonces[targetChainId]++,
            userNonces[msg.sender]++,
            block.timestamp,
            msg.sender
        ));
        
        // Duplicate prevention check
        bytes32 duplicateHash = keccak256(abi.encodePacked(
            lifecycles[lifecycleId].serialNumber,
            amount,
            targetChainId,
            recipient
        ));
        
        if (duplicatePreventionHashes[duplicateHash] != 0) {
            emit DuplicateTransferPrevented(transferId, duplicateHash, block.chainid, msg.sender);
            revert("CarbonCreditTracker: Duplicate transfer detected");
        }
        
        duplicatePreventionHashes[duplicateHash] = block.timestamp;
        
        // High-value transfer timelock
        uint256 expiresAt = block.timestamp + CROSS_CHAIN_TIMEOUT;
        if (amount >= HIGH_VALUE_THRESHOLD) {
            expiresAt += 24 hours; // Additional 24h delay for high-value transfers
            highValueLocks[transferId] = block.timestamp + 24 hours;
            emit HighValueTransferQueued(transferId, amount, expiresAt);
        }
        
        // Create cross-chain transfer record
        crossChainTransfers[transferId] = CrossChainTransfer({
            transferId: transferId,
            lifecycleId: lifecycleId,
            sourceChainId: block.chainid,
            targetChainId: targetChainId,
            initiator: msg.sender,
            recipient: recipient,
            amount: amount,
            qualityScore: _getQualityScore(lifecycleId),
            operation: operation,
            timestamp: block.timestamp,
            expiresAt: expiresAt,
            isExecuted: false,
            proofHash: bytes32(0)
        });
        
        // Update lifecycle status
        lifecycles[lifecycleId].status = LifecycleStatus.CROSS_CHAIN_PENDING;
        lifecycles[lifecycleId].activeSupply -= amount;
        
        totalCrossChainTransfers++;
        
        emit CrossChainTransferInitiated(
            transferId,
            lifecycleId,
            block.chainid,
            targetChainId,
            msg.sender,
            amount,
            operation
        );
        
        return transferId;
    }
    
    /**
     * @notice Validate cross-chain transfer with cryptographic proof verification
     * @param transferId The transfer to validate
     * @param proof Cryptographic proof from source chain
     * @dev Requires multiple validator signatures and Merkle proof verification
     */
    function validateCrossChainTransfer(
        bytes32 transferId,
        CrossChainProof calldata proof
    ) external onlyValidator nonReentrant whenNotPaused nonReplayable(proof.messageHash) {
        CrossChainTransfer storage transfer = crossChainTransfers[transferId];
        require(transfer.transferId != bytes32(0), "CarbonCreditTracker: Transfer not found");
        require(!transfer.isExecuted, "CarbonCreditTracker: Transfer already executed");
        require(block.timestamp <= transfer.expiresAt, "CarbonCreditTracker: Transfer expired");
        require(!hasValidatorSigned[transferId][msg.sender], "CarbonCreditTracker: Already signed");
        
        // Verify proof structure
        require(proof.validatorSignatures.length >= MIN_VALIDATORS_REQUIRED, "CarbonCreditTracker: Insufficient signatures");
        require(proof.sourceChainId == transfer.sourceChainId, "CarbonCreditTracker: Chain ID mismatch");
        require(proof.targetChainId == transfer.targetChainId, "CarbonCreditTracker: Target chain mismatch");
        
        // Verify Merkle proof
        require(
            MerkleProof.verify(proof.merkleProof, proof.merkleRoot, proof.messageHash),
            "CarbonCreditTracker: Invalid Merkle proof"
        );
        
        // Verify validator signatures
        uint256 validSignatures = _verifyValidatorSignatures(transferId, proof);
        require(validSignatures >= MIN_VALIDATORS_REQUIRED, "CarbonCreditTracker: Insufficient valid signatures");
        
        // Mark validator as signed
        hasValidatorSigned[transferId][msg.sender] = true;
        validatorConfirmations[transferId]++;
        
        // Update validator stats
        validators[msg.sender].validatedTransfers++;
        validators[msg.sender].lastActivityTimestamp = block.timestamp;
        
        // Store proof
        crossChainProofs[transferId] = proof;
        transfer.proofHash = proof.messageHash;
        
        emit CrossChainTransferValidated(transferId, msg.sender, validatorConfirmations[transferId], proof.messageHash);
        
        // Execute transfer if enough confirmations
        if (validatorConfirmations[transferId] >= MIN_VALIDATORS_REQUIRED) {
            _executeCrossChainTransfer(transferId);
        }
    }
    
    /**
     * @notice Execute cross-chain transfer after validation
     * @param transferId The validated transfer to execute
     * @dev Internal function called after sufficient validator confirmations
     */
    function _executeCrossChainTransfer(bytes32 transferId) internal {
        CrossChainTransfer storage transfer = crossChainTransfers[transferId];
        require(!transfer.isExecuted, "CarbonCreditTracker: Already executed");
        
        // High-value transfer additional check
        if (highValueLocks[transferId] > 0) {
            require(block.timestamp >= highValueLocks[transferId], "CarbonCreditTracker: High-value timelock active");
        }
        
        transfer.isExecuted = true;
        
        // Update lifecycle on target chain (this would be a separate contract call in production)
        CreditLifecycle storage lifecycle = lifecycles[transfer.lifecycleId];
        
        if (transfer.operation == CrossChainOperation.BRIDGE_OUT) {
            // Lock credits on source chain
            lifecycle.status = LifecycleStatus.CROSS_CHAIN_LOCKED;
            lifecycle.immobilizedSupply += transfer.amount;
        } else if (transfer.operation == CrossChainOperation.BRIDGE_IN) {
            // Unlock credits on target chain
            lifecycle.status = LifecycleStatus.ACTIVE;
            lifecycle.activeSupply += transfer.amount;
            lifecycle.immobilizedSupply -= transfer.amount;
        }
        
        successfulTransfers++;
        
        emit CrossChainTransferCompleted(transferId, transfer.lifecycleId, transfer.targetChainId, true);
        
        // Quality score synchronization
        if (transfer.operation == CrossChainOperation.QUALITY_SYNC) {
            emit QualitySynchronized(
                transfer.lifecycleId,
                transfer.sourceChainId,
                transfer.targetChainId,
                transfer.qualityScore
            );
        }
    }
    
    /**
     * @notice Batch execute multiple cross-chain transfers for gas optimization
     * @param transferIds Array of transfer IDs to execute
     * @dev Only for transfers that have met validation requirements
     */
    function batchExecuteCrossChainTransfers(
        bytes32[] calldata transferIds
    ) external onlyValidator nonReentrant whenNotPaused {
        require(transferIds.length <= MAX_BATCH_SIZE, "CarbonCreditTracker: Batch too large");
        require(transferIds.length > 0, "CarbonCreditTracker: Empty batch");
        
        bytes32 batchId = keccak256(abi.encodePacked(transferIds, block.timestamp, msg.sender));
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < transferIds.length; i++) {
            bytes32 transferId = transferIds[i];
            CrossChainTransfer storage transfer = crossChainTransfers[transferId];
            
            require(transfer.transferId != bytes32(0), "CarbonCreditTracker: Transfer not found");
            require(!transfer.isExecuted, "CarbonCreditTracker: Transfer already executed");
            require(validatorConfirmations[transferId] >= MIN_VALIDATORS_REQUIRED, "CarbonCreditTracker: Insufficient confirmations");
            
            totalAmount += transfer.amount;
            batchTransferGroups[batchId].push(transferId);
            
            _executeCrossChainTransfer(transferId);
        }
        
        batchExecutionTimestamp[batchId] = block.timestamp;
        
        emit BatchTransferExecuted(batchId, transferIds.length, totalAmount);
    }
    
    /**
     * @notice Emergency function to recover failed cross-chain transfers
     * @param transferId The failed transfer to recover
     * @dev Only callable by emergency role during emergencies
     */
    function emergencyRecoverTransfer(bytes32 transferId) external onlyEmergencyRole whenNotPaused {
        CrossChainTransfer storage transfer = crossChainTransfers[transferId];
        require(transfer.transferId != bytes32(0), "CarbonCreditTracker: Transfer not found");
        require(block.timestamp > transfer.expiresAt + REPLAY_PROTECTION_WINDOW, "CarbonCreditTracker: Not expired yet");
        require(!transfer.isExecuted, "CarbonCreditTracker: Transfer already executed");
        
        // Return credits to active supply
        CreditLifecycle storage lifecycle = lifecycles[transfer.lifecycleId];
        lifecycle.activeSupply += transfer.amount;
        lifecycle.status = LifecycleStatus.ACTIVE;
        
        // Mark as failed
        transfer.isExecuted = true; // Prevent re-execution
        failedTransfers++;
        
        emit CrossChainTransferCompleted(transfer.transferId, transfer.lifecycleId, transfer.targetChainId, false);
        emit SecurityViolation(transferId, msg.sender, "EMERGENCY_RECOVERY", block.timestamp);
    }
    
    /**
     * @notice Add or update cross-chain registry configuration
     * @param chainId The chain ID to configure
     * @param contractAddress The contract address on that chain
     * @param isActive Whether the chain is active
     * @param minimumConfirmations Minimum confirmations required
     * @param rpcEndpoint RPC endpoint for the chain
     */
    function updateCrossChainRegistry(
        uint256 chainId,
        address contractAddress,
        bool isActive,
        uint256 minimumConfirmations,
        string calldata rpcEndpoint
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(chainId != 0, "CarbonCreditTracker: Invalid chain ID");
        require(contractAddress != address(0), "CarbonCreditTracker: Invalid contract address");
        
        crossChainRegistries[chainId] = CrossChainRegistry({
            chainId: chainId,
            contractAddress: contractAddress,
            isActive: isActive,
            minimumConfirmations: minimumConfirmations,
            rpcEndpoint: rpcEndpoint,
            registryHash: keccak256(abi.encodePacked("CARBON_TRACKER", chainId, contractAddress))
        });
        
        emit CrossChainRegistryUpdated(chainId, contractAddress, isActive);
    }
    
    /**
     * @notice Add cross-chain validator
     * @param validator Validator address
     * @param stake Required stake amount
     * @param endpoint Validator endpoint
     */
    function addCrossChainValidator(
        address validator,
        uint256 stake,
        string calldata endpoint
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validator != address(0), "CarbonCreditTracker: Invalid validator");
        require(stake > 0, "CarbonCreditTracker: Invalid stake");
        require(!validators[validator].isActive, "CarbonCreditTracker: Validator already active");
        
        validators[validator] = ValidatorInfo({
            validatorAddress: validator,
            stake: stake,
            validatedTransfers: 0,
            isActive: true,
            lastActivityTimestamp: block.timestamp,
            endpoint: endpoint
        });
        
        validatorList.push(validator);
        _grantRole(CROSS_CHAIN_VALIDATOR_ROLE, validator);
        
        emit ValidatorAdded(validator, stake, endpoint);
    }
    
    /**
     * @notice Remove cross-chain validator
     * @param validator Validator to remove
     * @param reason Reason for removal
     */
    function removeCrossChainValidator(
        address validator,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validators[validator].isActive, "CarbonCreditTracker: Validator not active");
        
        validators[validator].isActive = false;
        _revokeRole(CROSS_CHAIN_VALIDATOR_ROLE, validator);
        
        // Remove from list
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorList[i] == validator) {
                validatorList[i] = validatorList[validatorList.length - 1];
                validatorList.pop();
                break;
            }
        }
        
        emit ValidatorRemoved(validator, reason);
    }
    
    /**
     * @notice Get cross-chain transfer details
     * @param transferId The transfer ID
     * @return transfer The transfer details
     */
    function getCrossChainTransfer(bytes32 transferId) external view returns (CrossChainTransfer memory transfer) {
        return crossChainTransfers[transferId];
    }
    
    /**
     * @notice Get cross-chain proof details
     * @param transferId The transfer ID
     * @return proof The cryptographic proof
     */
    function getCrossChainProof(bytes32 transferId) external view returns (CrossChainProof memory proof) {
        return crossChainProofs[transferId];
    }
    
    /**
     * @notice Get validator information
     * @param validator The validator address
     * @return info The validator information
     */
    function getValidatorInfo(address validator) external view returns (ValidatorInfo memory info) {
        return validators[validator];
    }
    
    /**
     * @notice Get cross-chain registry information
     * @param chainId The chain ID
     * @return registry The registry information
     */
    function getCrossChainRegistry(uint256 chainId) external view returns (CrossChainRegistry memory registry) {
        return crossChainRegistries[chainId];
    }
    
    /**
     * @notice Get bridge statistics
     * @return total Total transfers
     * @return successful Successful transfers
     * @return failed Failed transfers
     * @return activeValidators Number of active validators
     */
    function getBridgeStats() external view returns (
        uint256 total,
        uint256 successful,
        uint256 failed,
        uint256 activeValidators
    ) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validators[validatorList[i]].isActive) {
                activeCount++;
            }
        }
        
        return (
            totalCrossChainTransfers,
            successfulTransfers,
            failedTransfers,
            activeCount
        );
    }
    
    // ============ Internal Helper Functions ============
    
    function _verifyValidatorSignatures(
        bytes32 transferId,
        CrossChainProof calldata proof
    ) internal view returns (uint256 validSignatures) {
        validSignatures = 0;
        address[] memory signers = new address[](proof.validatorSignatures.length);
        
        for (uint256 i = 0; i < proof.validatorSignatures.length; i++) {
            address signer = proof.messageHash.recover(proof.validatorSignatures[i]);
            
            // Prevent duplicate signatures
            for (uint256 j = 0; j < i; j++) {
                require(signers[j] != signer, "CarbonCreditTracker: Duplicate signature");
            }
            signers[i] = signer;
            
            // Verify signer is active validator
            if (validators[signer].isActive && hasRole(CROSS_CHAIN_VALIDATOR_ROLE, signer)) {
                validSignatures++;
            }
        }
        
        return validSignatures;
    }
    
    function _getQualityScore(bytes32 lifecycleId) internal view returns (uint256) {
        // Placeholder - would integrate with quality oracle
        // For now, return a default score based on lifecycle data
        CreditLifecycle memory lifecycle = lifecycles[lifecycleId];
        if (lifecycle.isVerified) {
            return 85; // High quality for verified credits
        }
        return 60; // Lower quality for unverified credits
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Emergency unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // Internal helper functions
    function _generateCertificateHash(
        bytes32 lifecycleId,
        string memory certificateId,
        uint256 amount
    ) internal view returns (string memory) {
        // In production, this would generate proper IPFS hash
        bytes32 hash = keccak256(abi.encodePacked(
            lifecycleId,
            certificateId,
            amount,
            block.timestamp,
            block.number
        ));
        return string(abi.encodePacked("Qm", _toHexString(uint256(hash))));
    }
    
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function _toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return _toHexString(value, length);
    }
    
    function _toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
    
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";
}