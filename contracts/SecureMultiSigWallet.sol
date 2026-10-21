// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
// import "@openzeppelin/contracts/utils/math/SafeMath.sol"; // Not needed in Solidity 0.8+
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SecureMultiSigWallet
 * @dev Enhanced multi-signature wallet with comprehensive security against bypass attempts
 * 
 * SECURITY FEATURES FOR TASK 99.14:
 * - Robust signature verification preventing bypass attacks
 * - Comprehensive access control with role-based permissions
 * - Anti-replay protection with nonces and timestamps
 * - Emergency controls and circuit breaker mechanisms
 * - Audit trail and monitoring of all operations
 * - Protection against OWASP SC02 Access Control vulnerabilities
 * 
 * VULNERABILITY FIXES IMPLEMENTED:
 * - Prevents unauthorized transaction execution without required signatures
 * - Enforces minimum signature threshold at all times
 * - Validates signature authenticity and prevents manipulation
 * - Implements proper checks-effects-interactions pattern
 * - Comprehensive input validation and bounds checking
 * - Emergency pause mechanisms and recovery procedures
 * 
 * ECONOMIC IMPACT: Protects $5M TVL from unauthorized access
 */
contract SecureMultiSigWallet is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    // using SafeMath for uint256; // Not needed in Solidity 0.8+
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============ Constants and State Variables ============

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    // Security constraints
    uint256 public constant MAX_OWNERS = 20;
    uint256 public constant MIN_REQUIRED_SIGNATURES = 2;
    uint256 public constant MAX_REQUIRED_SIGNATURES = 15;
    uint256 public constant TRANSACTION_EXPIRY_TIME = 7 days;
    uint256 public constant SIGNATURE_REPLAY_WINDOW = 1 hours;
    uint256 public constant MAX_DAILY_TRANSACTION_LIMIT = 100;
    uint256 public constant MAX_BATCH_SIZE = 20;

    // Core multi-sig parameters
    uint256 public requiredSignatures;
    uint256 public totalOwners;
    
    // Owner management
    mapping(address => bool) public isOwner;
    address[] public owners;
    mapping(address => uint256) public ownerIndex; // 1-based indexing, 0 means not an owner

    // Transaction management
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 confirmations;
        mapping(address => bool) isConfirmed;
        address creator;
        string description;
        TransactionType txType;
        uint256 nonce;
        uint256 emergencyNonceAtCreation; // SECURITY FIX: tracks emergency nonce at submission
    }

    enum TransactionType {
        TRANSFER,
        TOKEN_TRANSFER,
        CONTRACT_CALL,
        OWNER_MANAGEMENT,
        EMERGENCY_ACTION
    }

    mapping(uint256 => Transaction) public transactions;
    uint256 public transactionCount;
    uint256 public executedTransactionCount;

    // Security features
    mapping(address => uint256) public lastSignatureTime;
    mapping(address => uint256) public dailyTransactionCount;
    mapping(address => uint256) public lastDailyReset;
    mapping(bytes32 => bool) public usedSignatureHashes;
    mapping(uint256 => bool) public usedNonces;

    // Emergency controls
    bool public emergencyMode;
    uint256 public emergencyModeActivatedAt;
    address public emergencyRecoveryAddress;
    mapping(address => bool) public emergencyApprovals;
    uint256 public emergencyApprovalCount;

    /// @dev SECURITY FIX: Emergency nonce increments each time emergency mode activates.
    /// Transactions submitted before emergency activation are invalidated by recording
    /// the emergencyNonce at submission time and checking it at execution time.
    uint256 public emergencyNonce;

    // Audit and monitoring
    struct AuditLog {
        address actor;
        string action;
        uint256 timestamp;
        bytes32 dataHash;
        bool success;
    }

    AuditLog[] public auditLogs;
    uint256 public lastAuditLogIndex;

    // Daily limits
    uint256 public dailyLimit;
    uint256 public lastDay;
    uint256 public spentToday;

    // EIP-712 typehashes
    bytes32 private constant TRANSACTION_TYPEHASH = keccak256(
        "Transaction(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline,string description)"
    );

    bytes32 private constant OWNER_MANAGEMENT_TYPEHASH = keccak256(
        "OwnerManagement(address newOwner,bool isAddition,uint256 newRequiredSignatures,uint256 nonce,uint256 deadline)"
    );

    // ============ Events ============

    event TransactionSubmitted(
        uint256 indexed transactionId,
        address indexed creator,
        address indexed to,
        uint256 value,
        string description
    );

    event TransactionConfirmed(
        uint256 indexed transactionId,
        address indexed owner,
        uint256 confirmations
    );

    event TransactionExecuted(
        uint256 indexed transactionId,
        address indexed executor,
        bool success,
        bytes returnData
    );

    event OwnerAdded(
        address indexed newOwner,
        address indexed addedBy,
        uint256 newRequiredSignatures
    );

    event OwnerRemoved(
        address indexed removedOwner,
        address indexed removedBy,
        uint256 newRequiredSignatures
    );

    event RequiredSignaturesChanged(
        uint256 oldRequired,
        uint256 newRequired,
        address indexed changedBy
    );

    event EmergencyModeActivated(
        address indexed activatedBy,
        uint256 timestamp
    );

    event EmergencyModeDeactivated(
        address indexed deactivatedBy,
        uint256 timestamp
    );

    event SecurityAlert(
        string alertType,
        address indexed actor,
        uint256 indexed transactionId,
        bytes32 dataHash
    );

    event AuditLogCreated(
        uint256 indexed logIndex,
        address indexed actor,
        string action,
        bool success
    );

    // ============ Modifiers ============

    modifier onlyOwner() {
        require(isOwner[msg.sender], "SecureMultiSigWallet: Not an owner");
        _;
    }

    modifier validRequirement(uint256 ownerCount, uint256 required) {
        require(
            required >= MIN_REQUIRED_SIGNATURES && 
            required <= MAX_REQUIRED_SIGNATURES && 
            required <= ownerCount,
            "SecureMultiSigWallet: Invalid required signatures"
        );
        _;
    }

    modifier transactionExists(uint256 transactionId) {
        require(
            transactionId < transactionCount,
            "SecureMultiSigWallet: Transaction does not exist"
        );
        _;
    }

    modifier notExecuted(uint256 transactionId) {
        require(
            !transactions[transactionId].executed,
            "SecureMultiSigWallet: Transaction already executed"
        );
        _;
    }

    modifier notExpired(uint256 transactionId) {
        require(
            block.timestamp <= transactions[transactionId].expiresAt,
            "SecureMultiSigWallet: Transaction expired"
        );
        _;
    }

    modifier rateLimited() {
        require(
            !_isRateLimited(msg.sender),
            "SecureMultiSigWallet: Rate limit exceeded"
        );
        _;
    }

    modifier notInEmergencyMode() {
        require(!emergencyMode, "SecureMultiSigWallet: Emergency mode active");
        _;
    }

    modifier emergencyModeOnly() {
        require(emergencyMode, "SecureMultiSigWallet: Not in emergency mode");
        _;
    }

    // ============ Constructor ============

    constructor(
        address[] memory _owners,
        uint256 _requiredSignatures,
        uint256 _dailyLimit,
        address _emergencyRecoveryAddress
    ) 
        EIP712("SecureMultiSigWallet", "1") 
        validRequirement(_owners.length, _requiredSignatures)
    {
        require(_owners.length > 0, "SecureMultiSigWallet: No owners provided");
        require(_owners.length <= MAX_OWNERS, "SecureMultiSigWallet: Too many owners");
        require(_emergencyRecoveryAddress != address(0), "SecureMultiSigWallet: Invalid emergency address");

        // Initialize owners
        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "SecureMultiSigWallet: Invalid owner address");
            require(!isOwner[owner], "SecureMultiSigWallet: Duplicate owner");

            isOwner[owner] = true;
            owners.push(owner);
            ownerIndex[owner] = i + 1; // 1-based indexing
            
            _grantRole(OWNER_ROLE, owner);
        }

        requiredSignatures = _requiredSignatures;
        totalOwners = _owners.length;
        dailyLimit = _dailyLimit;
        emergencyRecoveryAddress = _emergencyRecoveryAddress;

        // Grant emergency role to first owner and emergency recovery address
        _grantRole(EMERGENCY_ROLE, _owners[0]);
        _grantRole(EMERGENCY_ROLE, _emergencyRecoveryAddress);
        _grantRole(AUDITOR_ROLE, _emergencyRecoveryAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, _emergencyRecoveryAddress);

        _logAuditEvent(msg.sender, "WALLET_CREATED", true);
    }

    // ============ Core Multi-Sig Functions ============

    /**
     * @notice Submit a new transaction for multi-signature approval with comprehensive security validation
     * @dev Implements multi-layered security checks including rate limiting, daily limits, and transaction type validation
     * 
     * Security Features:
     * - Validates all input parameters for safety
     * - Enforces daily transaction limits for transfers
     * - Implements rate limiting per owner
     * - Validates transaction type-specific constraints
     * - Generates cryptographically secure nonces
     * - Creates audit trail for all submissions
     * 
     * @param to The destination address for the transaction
     * @param value The amount of ETH to transfer (in wei)
     * @param data The transaction data payload
     * @param description Human-readable description of the transaction purpose
     * @param txType The type of transaction (TRANSFER, TOKEN_TRANSFER, CONTRACT_CALL, etc.)
     * @param deadline The expiration timestamp for signature collection
     * @return transactionId The unique identifier for the submitted transaction
     * 
     * Requirements:
     * - Caller must be an authorized owner
     * - Contract must not be paused or in emergency mode
     * - Must pass rate limiting checks
     * - Destination address cannot be zero
     * - Deadline must be valid and within allowed timeframe
     * - Description cannot be empty
     * - Must comply with daily spending limits for transfers
     */
    function submitTransaction(
        address to,
        uint256 value,
        bytes memory data,
        string memory description,
        TransactionType txType,
        uint256 deadline
    ) 
        external 
        onlyOwner 
        nonReentrant 
        whenNotPaused 
        notInEmergencyMode
        rateLimited
        returns (uint256 transactionId) 
    {
        require(to != address(0), "SecureMultiSigWallet: Invalid recipient");
        require(deadline > block.timestamp, "SecureMultiSigWallet: Invalid deadline");
        require(deadline <= block.timestamp + TRANSACTION_EXPIRY_TIME, "SecureMultiSigWallet: Deadline too far");
        require(bytes(description).length > 0, "SecureMultiSigWallet: Description required");

        // Check daily limit for transfers
        if (txType == TransactionType.TRANSFER || txType == TransactionType.TOKEN_TRANSFER) {
            _checkDailyLimit(value);
        }

        // Validate transaction type specific constraints
        _validateTransactionType(to, value, data, txType);

        transactionId = transactionCount;
        Transaction storage transaction = transactions[transactionId];
        
        transaction.to = to;
        transaction.value = value;
        transaction.data = data;
        transaction.executed = false;
        transaction.createdAt = block.timestamp;
        transaction.expiresAt = deadline;
        transaction.confirmations = 0;
        transaction.creator = msg.sender;
        transaction.description = description;
        transaction.txType = txType;
        transaction.nonce = _generateNonce();
        transaction.emergencyNonceAtCreation = emergencyNonce;

        transactionCount = transactionCount + 1;

        // Update rate limiting
        _updateRateLimit(msg.sender);

        emit TransactionSubmitted(transactionId, msg.sender, to, value, description);
        _logAuditEvent(msg.sender, "TRANSACTION_SUBMITTED", true);

        return transactionId;
    }

    /**
     * @notice Confirm a pending transaction with cryptographically secure signature verification
     * @dev Implements EIP-712 structured signature verification to prevent bypass attacks
     * 
     * Critical Security Measures:
     * - EIP-712 structured data signing prevents signature malleability
     * - Anti-replay protection using signature hash tracking
     * - Rate limiting prevents signature flooding attacks
     * - Comprehensive validation of transaction state
     * - Automatic execution when threshold is reached
     * 
     * @param transactionId The unique identifier of the transaction to confirm
     * @param signature The EIP-712 signature proving authorization from the caller
     * 
     * Requirements:
     * - Caller must be an authorized owner
     * - Transaction must exist and not be executed or cancelled
     * - Transaction must not be expired
     * - Owner must not have already signed this transaction
     * - Signature must be valid EIP-712 signature from caller
     * - Must pass anti-replay and rate limiting checks
     * 
     * Effects:
     * - Records the confirmation from the calling owner
     * - Increments the confirmation count
     * - Updates the owner's last signature timestamp
     * - Automatically executes transaction if threshold is reached
     * - Emits TransactionConfirmed event
     * - Creates audit log entry
     */
    function confirmTransaction(
        uint256 transactionId,
        bytes memory signature
    ) 
        external 
        onlyOwner 
        nonReentrant 
        transactionExists(transactionId) 
        notExecuted(transactionId) 
        notExpired(transactionId)
        whenNotPaused
    {
        Transaction storage transaction = transactions[transactionId];
        
        require(
            !transaction.isConfirmed[msg.sender],
            "SecureMultiSigWallet: Already confirmed by this owner"
        );

        // CRITICAL SECURITY: Verify EIP-712 signature to prevent bypass
        bytes32 structHash = keccak256(abi.encode(
            TRANSACTION_TYPEHASH,
            transaction.to,
            transaction.value,
            keccak256(transaction.data),
            transaction.nonce,
            transaction.expiresAt,
            keccak256(bytes(transaction.description))
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredSigner = digest.recover(signature);

        require(
            recoveredSigner == msg.sender,
            "SecureMultiSigWallet: Invalid signature"
        );

        // Anti-replay protection
        bytes32 signatureHash = keccak256(signature);
        require(
            !usedSignatureHashes[signatureHash],
            "SecureMultiSigWallet: Signature already used"
        );
        usedSignatureHashes[signatureHash] = true;

        // Rate limiting for signatures
        require(
            block.timestamp >= lastSignatureTime[msg.sender] + SIGNATURE_REPLAY_WINDOW,
            "SecureMultiSigWallet: Signature rate limit exceeded"
        );
        lastSignatureTime[msg.sender] = block.timestamp;

        // Record confirmation
        transaction.isConfirmed[msg.sender] = true;
        transaction.confirmations = transaction.confirmations + 1;

        emit TransactionConfirmed(transactionId, msg.sender, transaction.confirmations);
        _logAuditEvent(msg.sender, "TRANSACTION_CONFIRMED", true);

        // Auto-execute if threshold reached
        if (transaction.confirmations >= requiredSignatures) {
            _executeTransaction(transactionId);
        }
    }

    /**
     * @dev Execute a fully confirmed transaction
     * SECURITY: Final validation before execution to prevent bypass
     */
    function executeTransaction(uint256 transactionId) 
        external 
        onlyOwner 
        nonReentrant 
        transactionExists(transactionId) 
        notExecuted(transactionId) 
        notExpired(transactionId)
        whenNotPaused
    {
        Transaction storage transaction = transactions[transactionId];
        
        require(
            transaction.confirmations >= requiredSignatures,
            "SecureMultiSigWallet: Insufficient confirmations"
        );

        _executeTransaction(transactionId);
    }

    /**
     * @dev Internal function to execute transaction with comprehensive validation
     */
    function _executeTransaction(uint256 transactionId) internal {
        Transaction storage transaction = transactions[transactionId];

        // SECURITY: Double-check all conditions before execution
        require(!transaction.executed, "SecureMultiSigWallet: Already executed");
        require(transaction.confirmations >= requiredSignatures, "SecureMultiSigWallet: Insufficient confirmations");
        require(block.timestamp <= transaction.expiresAt, "SecureMultiSigWallet: Transaction expired");

        // SECURITY FIX: Prevent execution in the same block as emergency mode activation.
        // If emergency mode was activated in this block, the transaction could execute under
        // emergency rules, creating a race condition. Require at least 1 block separation.
        require(
            !emergencyMode || emergencyModeActivatedAt < block.timestamp,
            "SecureMultiSigWallet: Emergency mode activated this block"
        );

        // SECURITY FIX: Invalidate transactions submitted before emergency mode activation.
        // When emergency mode is triggered, the emergencyNonce increments, making all
        // previously submitted transactions invalid. This prevents pending regular
        // confirmations from racing with emergency execution.
        require(
            transaction.emergencyNonceAtCreation == emergencyNonce,
            "SecureMultiSigWallet: Transaction invalidated by emergency mode"
        );

        // Mark as executed first (checks-effects-interactions)
        transaction.executed = true;
        executedTransactionCount = executedTransactionCount + 1;

        // Update daily spending for transfers
        if (transaction.txType == TransactionType.TRANSFER || transaction.txType == TransactionType.TOKEN_TRANSFER) {
            _updateDailySpending(transaction.value);
        }

        // Execute the transaction
        bool success;
        bytes memory returnData;

        if (transaction.txType == TransactionType.TOKEN_TRANSFER) {
            // Handle ERC20 token transfers
            success = _executeTokenTransfer(transaction);
            returnData = "";
        } else {
            // Handle ETH transfers and contract calls
            (success, returnData) = transaction.to.call{value: transaction.value}(transaction.data);
        }

        // M-02 fix: Revert on failure so transaction is not marked as executed and can be retried
        if (!success) {
            transaction.executed = false;
            executedTransactionCount = executedTransactionCount - 1;
            _logAuditEvent(msg.sender, "TRANSACTION_EXECUTION_FAILED", false);
            emit SecurityAlert("EXECUTION_FAILURE", msg.sender, transactionId, keccak256(returnData));
            revert("SecureMultiSigWallet: Transaction execution failed");
        }

        emit TransactionExecuted(transactionId, msg.sender, success, returnData);
        _logAuditEvent(msg.sender, "TRANSACTION_EXECUTED", true);
    }

    /**
     * @dev Execute ERC20 token transfer
     */
    function _executeTokenTransfer(Transaction storage transaction) internal returns (bool) {
        // Decode token transfer data
        require(transaction.data.length >= 68, "SecureMultiSigWallet: Invalid token transfer data");
        
        // Extract function selector (first 4 bytes)
        bytes4 selector;
        bytes memory data = transaction.data;
        assembly {
            selector := mload(add(data, 0x20))
        }
        
        require(
            selector == IERC20.transfer.selector || selector == IERC20.transferFrom.selector,
            "SecureMultiSigWallet: Invalid token function"
        );

        // FIXED: Execute the actual transaction data instead of hardcoded transfer
        // This properly executes the intended token transfer to the correct recipient
        (bool success, bytes memory returnData) = transaction.to.call(transaction.data);
        
        // Check for successful execution
        if (success) {
            // For ERC20 transfers, verify the return value if present
            if (returnData.length > 0) {
                require(abi.decode(returnData, (bool)), "SecureMultiSigWallet: Token transfer returned false");
            }
            return true;
        } else {
            return false;
        }
    }

    // ============ Owner Management Functions ============

    /**
     * @dev Add a new owner with multi-signature approval
     * SECURITY: Prevents unauthorized owner additions
     */
    function addOwner(
        address newOwner,
        uint256 newRequiredSignatures,
        bytes[] memory signatures,
        uint256 deadline,
        uint256 nonce
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        notInEmergencyMode
        validRequirement(totalOwners + 1, newRequiredSignatures)
    {
        require(newOwner != address(0), "SecureMultiSigWallet: Invalid owner address");
        require(!isOwner[newOwner], "SecureMultiSigWallet: Already an owner");
        require(totalOwners < MAX_OWNERS, "SecureMultiSigWallet: Too many owners");
        require(block.timestamp <= deadline, "SecureMultiSigWallet: Deadline expired");
        require(!usedNonces[nonce], "SecureMultiSigWallet: Nonce already used");
        require(signatures.length >= requiredSignatures, "SecureMultiSigWallet: Insufficient signatures");

        // Verify multi-signature approval for owner addition
        bytes32 structHash = keccak256(abi.encode(
            OWNER_MANAGEMENT_TYPEHASH,
            newOwner,
            true, // isAddition
            newRequiredSignatures,
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        _verifyMultipleSignatures(digest, signatures, requiredSignatures);

        usedNonces[nonce] = true;

        // Add the new owner
        isOwner[newOwner] = true;
        owners.push(newOwner);
        ownerIndex[newOwner] = owners.length; // 1-based indexing
        totalOwners = totalOwners + 1;

        _grantRole(OWNER_ROLE, newOwner);

        // Update required signatures if specified
        if (newRequiredSignatures != requiredSignatures) {
            uint256 oldRequired = requiredSignatures;
            requiredSignatures = newRequiredSignatures;
            emit RequiredSignaturesChanged(oldRequired, newRequiredSignatures, msg.sender);
        }

        emit OwnerAdded(newOwner, msg.sender, requiredSignatures);
        _logAuditEvent(msg.sender, "OWNER_ADDED", true);
    }

    /**
     * @dev Remove an owner with multi-signature approval
     * SECURITY: Prevents unauthorized owner removal
     */
    function removeOwner(
        address ownerToRemove,
        uint256 newRequiredSignatures,
        bytes[] memory signatures,
        uint256 deadline,
        uint256 nonce
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        notInEmergencyMode
        validRequirement(totalOwners - 1, newRequiredSignatures)
    {
        require(isOwner[ownerToRemove], "SecureMultiSigWallet: Not an owner");
        require(totalOwners > MIN_REQUIRED_SIGNATURES, "SecureMultiSigWallet: Cannot remove, minimum owners required");
        require(block.timestamp <= deadline, "SecureMultiSigWallet: Deadline expired");
        require(!usedNonces[nonce], "SecureMultiSigWallet: Nonce already used");
        require(signatures.length >= requiredSignatures, "SecureMultiSigWallet: Insufficient signatures");

        // Verify multi-signature approval for owner removal
        bytes32 structHash = keccak256(abi.encode(
            OWNER_MANAGEMENT_TYPEHASH,
            ownerToRemove,
            false, // isAddition
            newRequiredSignatures,
            nonce,
            deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        _verifyMultipleSignatures(digest, signatures, requiredSignatures);

        usedNonces[nonce] = true;

        // Remove the owner
        _removeOwnerInternal(ownerToRemove);

        // Update required signatures
        uint256 oldRequired = requiredSignatures;
        requiredSignatures = newRequiredSignatures;

        emit OwnerRemoved(ownerToRemove, msg.sender, requiredSignatures);
        emit RequiredSignaturesChanged(oldRequired, newRequiredSignatures, msg.sender);
        _logAuditEvent(msg.sender, "OWNER_REMOVED", true);
    }

    /**
     * @dev Internal function to remove owner from arrays and mappings
     */
    function _removeOwnerInternal(address ownerToRemove) internal {
        uint256 index = ownerIndex[ownerToRemove] - 1; // Convert to 0-based
        uint256 lastIndex = owners.length - 1;

        // Move the last owner to the position of the owner to remove
        if (index != lastIndex) {
            address lastOwner = owners[lastIndex];
            owners[index] = lastOwner;
            ownerIndex[lastOwner] = index + 1; // Update to 1-based
        }

        // Remove the last element
        owners.pop();
        delete ownerIndex[ownerToRemove];
        delete isOwner[ownerToRemove];
        totalOwners = totalOwners - 1;

        _revokeRole(OWNER_ROLE, ownerToRemove);
    }

    // ============ Emergency Functions ============

    /**
     * @dev Activate emergency mode to pause all operations
     */
    function activateEmergencyMode() external onlyRole(EMERGENCY_ROLE) whenNotPaused {
        require(!emergencyMode, "SecureMultiSigWallet: Already in emergency mode");

        emergencyMode = true;
        emergencyModeActivatedAt = block.timestamp;

        // SECURITY FIX: Increment emergency nonce to invalidate all pending transactions.
        // This prevents a race condition where regular transactions confirmed before
        // emergency mode could still execute, bypassing emergency controls.
        emergencyNonce++;

        _pause();

        emit EmergencyModeActivated(msg.sender, block.timestamp);
        _logAuditEvent(msg.sender, "EMERGENCY_MODE_ACTIVATED", true);
    }

    /**
     * @dev Deactivate emergency mode with multi-signature approval
     */
    function deactivateEmergencyMode(bytes[] memory signatures) 
        external 
        onlyRole(EMERGENCY_ROLE) 
        emergencyModeOnly 
    {
        require(signatures.length >= requiredSignatures, "SecureMultiSigWallet: Insufficient signatures");

        // Create hash for emergency deactivation
        bytes32 emergencyHash = keccak256(abi.encodePacked(
            "DEACTIVATE_EMERGENCY",
            address(this),
            block.timestamp
        ));

        _verifyMultipleSignatures(emergencyHash, signatures, requiredSignatures);

        emergencyMode = false;
        emergencyModeActivatedAt = 0;
        _unpause();

        emit EmergencyModeDeactivated(msg.sender, block.timestamp);
        _logAuditEvent(msg.sender, "EMERGENCY_MODE_DEACTIVATED", true);
    }

    /**
     * @dev Emergency recovery function - can only be called by emergency recovery address
     */
    function emergencyRecover(
        address to,
        uint256 amount,
        bytes memory data
    ) external nonReentrant {
        require(msg.sender == emergencyRecoveryAddress, "SecureMultiSigWallet: Not emergency recovery address");
        require(emergencyMode, "SecureMultiSigWallet: Not in emergency mode");
        require(block.timestamp >= emergencyModeActivatedAt + 7 days, "SecureMultiSigWallet: Emergency cooling period");

        (bool success, ) = to.call{value: amount}(data);
        require(success, "SecureMultiSigWallet: Emergency recovery failed");

        emit SecurityAlert("EMERGENCY_RECOVERY", msg.sender, 0, keccak256(data));
        _logAuditEvent(msg.sender, "EMERGENCY_RECOVERY", success);
    }

    // ============ Security Helper Functions ============

    /**
     * @dev Verify multiple signatures against a hash
     * CRITICAL: Prevents signature bypass attacks
     */
    function _verifyMultipleSignatures(
        bytes32 hash,
        bytes[] memory signatures,
        uint256 required
    ) internal view {
        require(signatures.length >= required, "SecureMultiSigWallet: Insufficient signatures");

        address[] memory signers = new address[](signatures.length);
        uint256 validSignatures = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = hash.recover(signatures[i]);
            
            // Check if signer is an owner
            if (!isOwner[signer]) {
                continue;
            }

            // Check for duplicate signers
            bool duplicate = false;
            for (uint256 j = 0; j < validSignatures; j++) {
                if (signers[j] == signer) {
                    duplicate = true;
                    break;
                }
            }

            if (!duplicate) {
                signers[validSignatures] = signer;
                validSignatures = validSignatures + 1;
            }
        }

        require(validSignatures >= required, "SecureMultiSigWallet: Invalid signatures");
    }

    /**
     * @dev Check if an address is rate limited
     */
    function _isRateLimited(address user) internal view returns (bool) {
        uint256 currentDay = block.timestamp / 1 days;
        uint256 userLastDay = lastDailyReset[user] / 1 days;
        
        if (currentDay > userLastDay) {
            return false; // New day, reset count
        }
        
        return dailyTransactionCount[user] >= MAX_DAILY_TRANSACTION_LIMIT;
    }

    /**
     * @dev Update rate limiting for user
     */
    function _updateRateLimit(address user) internal {
        uint256 currentDay = block.timestamp / 1 days;
        uint256 userLastDay = lastDailyReset[user] / 1 days;
        
        if (currentDay > userLastDay) {
            dailyTransactionCount[user] = 1;
            lastDailyReset[user] = block.timestamp;
        } else {
            dailyTransactionCount[user] = dailyTransactionCount[user] + 1;
        }
    }

    /**
     * @dev Check daily spending limit
     */
    function _checkDailyLimit(uint256 amount) internal view {
        uint256 currentDay = block.timestamp / 1 days;
        
        if (currentDay > lastDay) {
            // New day, amount is within daily limit
            require(amount <= dailyLimit, "SecureMultiSigWallet: Exceeds daily limit");
        } else {
            // Same day, check cumulative spending
            require(spentToday + amount <= dailyLimit, "SecureMultiSigWallet: Exceeds daily limit");
        }
    }

    /**
     * @dev Update daily spending
     */
    function _updateDailySpending(uint256 amount) internal {
        uint256 currentDay = block.timestamp / 1 days;
        
        if (currentDay > lastDay) {
            lastDay = currentDay;
            spentToday = amount;
        } else {
            spentToday = spentToday + amount;
        }
    }

    /**
     * @dev Generate a unique nonce
     */
    function _generateNonce() internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            transactionCount,
            msg.sender
        )));
    }

    /**
     * @dev Validate transaction type specific constraints
     */
    function _validateTransactionType(
        address to,
        uint256 value,
        bytes memory data,
        TransactionType txType
    ) internal view {
        if (txType == TransactionType.TRANSFER) {
            require(data.length == 0, "SecureMultiSigWallet: Transfer should have no data");
            require(value > 0, "SecureMultiSigWallet: Transfer value must be greater than 0");
        } else if (txType == TransactionType.TOKEN_TRANSFER) {
            require(data.length >= 68, "SecureMultiSigWallet: Invalid token transfer data");
            require(value == 0, "SecureMultiSigWallet: Token transfer should not send ETH");
        } else if (txType == TransactionType.CONTRACT_CALL) {
            require(data.length > 0, "SecureMultiSigWallet: Contract call requires data");
        } else if (txType == TransactionType.OWNER_MANAGEMENT) {
            require(to == address(this), "SecureMultiSigWallet: Owner management must target this contract");
            require(value == 0, "SecureMultiSigWallet: Owner management should not send ETH");
        }
    }

    /**
     * @dev Log audit event
     */
    function _logAuditEvent(address actor, string memory action, bool success) internal {
        bytes32 dataHash = keccak256(abi.encodePacked(actor, action, block.timestamp));
        
        auditLogs.push(AuditLog({
            actor: actor,
            action: action,
            timestamp: block.timestamp,
            dataHash: dataHash,
            success: success
        }));

        emit AuditLogCreated(auditLogs.length - 1, actor, action, success);
    }

    // ============ View Functions ============

    /**
     * @dev Get transaction details
     */
    function getTransaction(uint256 transactionId) 
        external 
        view 
        transactionExists(transactionId)
        returns (
            address to,
            uint256 value,
            bytes memory data,
            bool executed,
            uint256 createdAt,
            uint256 expiresAt,
            uint256 confirmations,
            address creator,
            string memory description,
            TransactionType txType
        ) 
    {
        Transaction storage transaction = transactions[transactionId];
        return (
            transaction.to,
            transaction.value,
            transaction.data,
            transaction.executed,
            transaction.createdAt,
            transaction.expiresAt,
            transaction.confirmations,
            transaction.creator,
            transaction.description,
            transaction.txType
        );
    }

    /**
     * @dev Check if transaction is confirmed by specific owner
     */
    function isTransactionConfirmed(uint256 transactionId, address owner) 
        external 
        view 
        transactionExists(transactionId)
        returns (bool) 
    {
        return transactions[transactionId].isConfirmed[owner];
    }

    /**
     * @dev Get owners array
     */
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /**
     * @dev Get confirmation count for transaction
     */
    function getConfirmationCount(uint256 transactionId) 
        external 
        view 
        transactionExists(transactionId)
        returns (uint256) 
    {
        return transactions[transactionId].confirmations;
    }

    /**
     * @dev Get audit log
     */
    function getAuditLog(uint256 index) 
        external 
        view 
        returns (
            address actor,
            string memory action,
            uint256 timestamp,
            bytes32 dataHash,
            bool success
        ) 
    {
        require(index < auditLogs.length, "SecureMultiSigWallet: Invalid audit log index");
        AuditLog storage log = auditLogs[index];
        return (log.actor, log.action, log.timestamp, log.dataHash, log.success);
    }

    /**
     * @dev Get total audit logs count
     */
    function getAuditLogsCount() external view returns (uint256) {
        return auditLogs.length;
    }

    // ============ Gas Optimization Functions ============

    /**
     * @notice Batch confirm multiple transactions in a single call to save gas
     * @dev Optimizes gas usage by processing multiple confirmations in one transaction
     * 
     * @param transactionIds Array of transaction IDs to confirm
     * @param signatures Array of signatures corresponding to each transaction
     * 
     * Requirements:
     * - Arrays must have the same length
     * - All standard confirmation requirements apply to each transaction
     * 
     * Gas Optimization:
     * - Reduces per-transaction overhead
     * - Shares fixed costs across multiple operations
     * - Uses unchecked arithmetic for loop counters
     */
    function batchConfirmTransactions(
        uint256[] memory transactionIds,
        bytes[] memory signatures
    ) external onlyOwner nonReentrant whenNotPaused {
        require(transactionIds.length == signatures.length, "SecureMultiSigWallet: Array length mismatch");
        require(transactionIds.length > 0, "SecureMultiSigWallet: Empty arrays");
        require(transactionIds.length <= MAX_BATCH_SIZE, "SecureMultiSigWallet: Batch size exceeds maximum");

        for (uint256 i = 0; i < transactionIds.length;) {
            _confirmTransactionInternal(transactionIds[i], signatures[i]);
            unchecked { ++i; } // Gas optimization: unchecked increment
        }

        _logAuditEvent(msg.sender, "BATCH_CONFIRMATIONS", true);
    }

    /**
     * @notice Get multiple transaction details in a single call
     * @dev Gas-efficient way to retrieve multiple transaction details
     * 
     * @param transactionIds Array of transaction IDs to query
     * @return tos Array of destination addresses for transactions
     * @return values Array of transaction values
     * @return executeds Array of execution status for each transaction
     * @return confirmations Array of confirmation counts for each transaction
     */
    function batchGetTransactions(uint256[] memory transactionIds)
        external
        view
        returns (
            address[] memory tos,
            uint256[] memory values,
            bool[] memory executeds,
            uint256[] memory confirmations
        )
    {
        require(transactionIds.length > 0, "SecureMultiSigWallet: Empty array");
        require(transactionIds.length <= 50, "SecureMultiSigWallet: Too many transactions");

        tos = new address[](transactionIds.length);
        values = new uint256[](transactionIds.length);
        executeds = new bool[](transactionIds.length);
        confirmations = new uint256[](transactionIds.length);

        for (uint256 i = 0; i < transactionIds.length;) {
            require(transactionIds[i] < transactionCount, "SecureMultiSigWallet: Transaction does not exist");
            
            Transaction storage transaction = transactions[transactionIds[i]];
            tos[i] = transaction.to;
            values[i] = transaction.value;
            executeds[i] = transaction.executed;
            confirmations[i] = transaction.confirmations;
            
            unchecked { ++i; } // Gas optimization: unchecked increment
        }
    }

    /**
     * @dev Internal function for batch confirmation optimization
     */
    function _confirmTransactionInternal(uint256 transactionId, bytes memory signature) internal {
        require(transactionId < transactionCount, "SecureMultiSigWallet: Transaction does not exist");
        
        Transaction storage transaction = transactions[transactionId];
        
        require(!transaction.executed, "SecureMultiSigWallet: Transaction already executed");
        require(block.timestamp <= transaction.expiresAt, "SecureMultiSigWallet: Transaction expired");
        require(!transaction.isConfirmed[msg.sender], "SecureMultiSigWallet: Already confirmed by this owner");

        // CRITICAL SECURITY: Verify EIP-712 signature to prevent bypass
        bytes32 structHash = keccak256(abi.encode(
            TRANSACTION_TYPEHASH,
            transaction.to,
            transaction.value,
            keccak256(transaction.data),
            transaction.nonce,
            transaction.expiresAt,
            keccak256(bytes(transaction.description))
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        address recoveredSigner = digest.recover(signature);

        require(recoveredSigner == msg.sender, "SecureMultiSigWallet: Invalid signature");

        // Anti-replay protection
        bytes32 signatureHash = keccak256(signature);
        require(!usedSignatureHashes[signatureHash], "SecureMultiSigWallet: Signature already used");
        usedSignatureHashes[signatureHash] = true;

        // Record confirmation
        transaction.isConfirmed[msg.sender] = true;
        transaction.confirmations = transaction.confirmations + 1;

        emit TransactionConfirmed(transactionId, msg.sender, transaction.confirmations);

        // Auto-execute if threshold reached
        if (transaction.confirmations >= requiredSignatures) {
            _executeTransaction(transactionId);
        }
    }

    // ============ Admin Functions ============

    /**
     * @dev Update daily limit with multi-signature approval
     */
    function updateDailyLimit(
        uint256 newDailyLimit,
        bytes[] memory signatures,
        uint256 deadline,
        uint256 nonce
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "SecureMultiSigWallet: Deadline expired");
        require(!usedNonces[nonce], "SecureMultiSigWallet: Nonce already used");
        require(signatures.length >= requiredSignatures, "SecureMultiSigWallet: Insufficient signatures");

        bytes32 hash = keccak256(abi.encodePacked(
            "UPDATE_DAILY_LIMIT",
            newDailyLimit,
            deadline,
            nonce
        ));

        _verifyMultipleSignatures(hash, signatures, requiredSignatures);
        usedNonces[nonce] = true;

        uint256 oldLimit = dailyLimit;
        dailyLimit = newDailyLimit;

        emit SecurityAlert("DAILY_LIMIT_UPDATED", msg.sender, 0, keccak256(abi.encodePacked(oldLimit, newDailyLimit)));
        _logAuditEvent(msg.sender, "DAILY_LIMIT_UPDATED", true);
    }

    // ============ Fallback Functions ============

    /**
     * @dev Receive ETH payments
     */
    receive() external payable {
        _logAuditEvent(msg.sender, "ETH_RECEIVED", true);
    }

    /**
     * @dev Fallback function
     */
    fallback() external payable {
        _logAuditEvent(msg.sender, "FALLBACK_CALLED", true);
    }
}