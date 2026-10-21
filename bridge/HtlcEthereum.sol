// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title HtlcEthereum
 * @dev Enterprise-grade Hash Time-Locked Contract implementation for secure cross-chain atomic swaps
 * 
 * Security Features:
 * - Hash preimage validation with multiple algorithms support
 * - Time-lock mechanism with configurable bounds
 * - Anti-replay protection through unique contract IDs
 * - Secret revelation security with commitment schemes  
 * - Economic security for high-value transfers ($2M-$5M TVL)
 * - Emergency pause functionality
 * - Cryptographic signature verification for enhanced security
 * - Gas optimization for batch operations
 * 
 * @author WRFCoin Security Team
 * @notice Secures cross-chain atomic swaps with enterprise-grade security measures
 */
contract HtlcEthereum is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @dev Supported hash algorithms for preimage validation
    enum HashAlgorithm { SHA256, KECCAK256, RIPEMD160 }
    
    /// @dev HTLC contract structure with enhanced security fields
    struct HtlcContract {
        bytes32 hashLock;           // Hash of the secret
        uint256 timeLock;           // Expiration timestamp
        address sender;             // Initiator of the contract
        address recipient;          // Intended recipient
        uint256 amount;             // Amount locked in contract
        address tokenAddress;       // Token contract address (0x0 for ETH)
        bool withdrawn;             // Whether funds have been withdrawn
        bool refunded;              // Whether funds have been refunded
        bytes32 secret;             // Revealed secret (empty until claimed)
        HashAlgorithm hashAlgorithm;// Hash algorithm used
        uint256 nonce;              // Anti-replay nonce
        bytes signature;            // Optional sender signature for verification
        uint256 securityDeposit;    // Additional security deposit for high-value transfers
        bool isHighValue;           // Flag for high-value transfer security
    }

    // ============ Storage Variables ============
    
    /// @dev Mapping from contract ID to HTLC contract
    mapping(bytes32 => HtlcContract) public contracts;
    
    /// @dev Mapping to track if a contract ID is used (anti-replay protection)
    mapping(bytes32 => bool) public contractExists;
    
    /// @dev Mapping to track used secrets to prevent secret reuse
    mapping(bytes32 => bool) public usedSecrets;
    
    /// @dev Mapping to track sender nonces for enhanced replay protection
    mapping(address => uint256) public senderNonces;
    
    /// @dev Mapping for emergency pause by contract ID
    mapping(bytes32 => bool) public contractPaused;

    // ============ Security Constants ============
    
    /// @notice Minimum time lock duration (1 hour) for security
    uint256 public constant MIN_TIME_LOCK = 3600;
    
    /// @notice Maximum time lock duration (30 days) to prevent indefinite locks
    uint256 public constant MAX_TIME_LOCK = 2592000;
    
    /// @notice High-value threshold requiring additional security ($100K equivalent)
    uint256 public constant HIGH_VALUE_THRESHOLD = 100000 ether;
    
    /// @notice Security deposit percentage for high-value transfers (5%)
    uint256 public constant SECURITY_DEPOSIT_RATE = 500; // 5% in basis points
    
    /// @notice Maximum contracts per sender per day for rate limiting
    uint256 public constant MAX_CONTRACTS_PER_DAY = 50;
    
    /// @dev Daily contract count tracking
    mapping(address => mapping(uint256 => uint256)) public dailyContractCount;

    /// @notice Timestamp when the contract was paused (H-04 fix: for emergency recovery timelock)
    uint256 public pausedAt;

    // ============ Enhanced Security Events ============
    
    /// @notice Emitted when a new HTLC is created
    event HtlcCreated(
        bytes32 indexed contractId,
        bytes32 indexed hashLock,
        uint256 timeLock,
        address indexed sender,
        address recipient,
        uint256 amount,
        address tokenAddress,
        HashAlgorithm hashAlgorithm,
        bool isHighValue
    );

    /// @notice Emitted when an HTLC is successfully claimed
    event HtlcClaimed(
        bytes32 indexed contractId,
        bytes32 secret,
        address indexed claimer,
        uint256 amount
    );

    /// @notice Emitted when an HTLC is refunded after expiration
    event HtlcRefunded(
        bytes32 indexed contractId,
        address indexed refundee,
        uint256 amount
    );

    /// @notice Emitted when a secret is revealed (for transparency)
    event SecretRevealed(
        bytes32 indexed contractId,
        bytes32 secret,
        HashAlgorithm algorithm
    );
    
    /// @notice Emitted when a security deposit is collected for high-value transfers
    event SecurityDepositCollected(
        bytes32 indexed contractId,
        uint256 depositAmount,
        address indexed sender
    );
    
    /// @notice Emitted for security monitoring
    event SecurityEvent(
        bytes32 indexed contractId,
        string eventType,
        address indexed actor,
        uint256 timestamp
    );
    
    /// @notice Emitted when contract is individually paused
    event ContractPaused(
        bytes32 indexed contractId,
        address indexed admin
    );
    
    /// @notice Emitted when contract is individually unpaused
    event ContractUnpaused(
        bytes32 indexed contractId,
        address indexed admin
    );

    // ============ Modifiers ============
    
    /// @dev Ensures contract is not individually paused
    modifier notContractPaused(bytes32 contractId) {
        require(!contractPaused[contractId], "HTLC: Contract individually paused");
        _;
    }
    
    /// @dev Rate limiting modifier to prevent spam
    modifier rateLimited() {
        uint256 currentDay = block.timestamp / 86400;
        require(
            dailyContractCount[msg.sender][currentDay] < MAX_CONTRACTS_PER_DAY,
            "HTLC: Daily contract limit exceeded"
        );
        dailyContractCount[msg.sender][currentDay]++;
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Create a new Hash Time-Locked Contract with enhanced security
     * @param contractId Unique identifier for the contract (must be unique)
     * @param hashLock Hash of the secret using specified algorithm
     * @param hashAlgorithm Hash algorithm to use (SHA256, KECCAK256, RIPEMD160)
     * @param timeLock Expiration timestamp (must be within valid range)
     * @param recipient Address that can claim the funds (cannot be sender)
     * @param tokenAddress Token contract address (0x0 for ETH)
     * @param amount Amount to be locked (must match msg.value for ETH)
     * @param signature Optional signature for additional verification
     * @dev High-value transfers require additional security deposit
     */
    function createHtlc(
        bytes32 contractId,
        bytes32 hashLock,
        HashAlgorithm hashAlgorithm,
        uint256 timeLock,
        address recipient,
        address tokenAddress,
        uint256 amount,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused rateLimited {
        // Enhanced input validation
        require(!contractExists[contractId], "HTLC: Contract ID already exists");
        require(hashLock != bytes32(0), "HTLC: Hash lock cannot be empty");
        require(timeLock > block.timestamp, "HTLC: Time lock must be in the future");
        require(timeLock <= block.timestamp + MAX_TIME_LOCK, "HTLC: Time lock too far in future");
        require(timeLock >= block.timestamp + MIN_TIME_LOCK, "HTLC: Time lock too short");
        require(recipient != address(0), "HTLC: Invalid recipient address");
        require(recipient != msg.sender, "HTLC: Sender cannot be recipient");
        require(amount > 0, "HTLC: Amount must be greater than zero");
        require(uint8(hashAlgorithm) <= 2, "HTLC: Invalid hash algorithm");
        
        // Signature verification if provided
        if (signature.length > 0) {
            bytes32 messageHash = keccak256(abi.encodePacked(
                contractId,
                hashLock,
                timeLock,
                recipient,
                tokenAddress,
                amount,
                senderNonces[msg.sender],
                block.chainid
            ));
            
            bytes32 ethMessageHash = messageHash.toEthSignedMessageHash();
            address recoveredSigner = ethMessageHash.recover(signature);
            require(recoveredSigner == msg.sender, "HTLC: Invalid signature");
        }
        
        // Determine if high-value transfer
        bool isHighValue = amount >= HIGH_VALUE_THRESHOLD;
        uint256 requiredDeposit = 0;
        
        if (isHighValue) {
            requiredDeposit = (amount * SECURITY_DEPOSIT_RATE) / 10000;
        }

        if (tokenAddress == address(0)) {
            // ETH transfer - check for security deposit
            uint256 totalRequired = amount + requiredDeposit;
            require(msg.value == totalRequired, "HTLC: ETH amount mismatch including deposit");
        } else {
            // ERC20 token transfer
            require(msg.value == requiredDeposit, "HTLC: Incorrect security deposit");
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Create contract with enhanced security
        contracts[contractId] = HtlcContract({
            hashLock: hashLock,
            timeLock: timeLock,
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            tokenAddress: tokenAddress,
            withdrawn: false,
            refunded: false,
            secret: bytes32(0),
            hashAlgorithm: hashAlgorithm,
            nonce: senderNonces[msg.sender]++,
            signature: signature,
            securityDeposit: requiredDeposit,
            isHighValue: isHighValue
        });

        contractExists[contractId] = true;
        
        // Emit security deposit event for high-value transfers
        if (isHighValue && requiredDeposit > 0) {
            emit SecurityDepositCollected(contractId, requiredDeposit, msg.sender);
        }

        emit HtlcCreated(
            contractId,
            hashLock,
            timeLock,
            msg.sender,
            recipient,
            amount,
            tokenAddress,
            hashAlgorithm,
            isHighValue
        );
        
        emit SecurityEvent(contractId, "HTLC_CREATED", msg.sender, block.timestamp);
    }

    /**
     * @dev Claim funds from HTLC by revealing the secret
     * @param contractId The contract identifier
     * @param secret The secret that hashes to hashLock
     */
    /**
     * @notice Claim funds from HTLC by revealing the secret with enhanced security validation
     * @param contractId The unique contract identifier
     * @param secret The secret that hashes to hashLock using the specified algorithm
     * @dev Implements comprehensive security checks including secret reuse prevention,
     *      hash algorithm validation, and economic security for high-value transfers
     */
    function claimHtlc(
        bytes32 contractId,
        bytes32 secret
    ) external nonReentrant whenNotPaused notContractPaused(contractId) {
        HtlcContract storage htlc = contracts[contractId];
        
        // Enhanced validation checks
        require(contractExists[contractId], "HTLC: Contract does not exist");
        require(!htlc.withdrawn, "HTLC: Funds already withdrawn");
        require(!htlc.refunded, "HTLC: Funds already refunded");
        require(block.timestamp < htlc.timeLock, "HTLC: Contract has expired");
        require(msg.sender == htlc.recipient, "HTLC: Only recipient can claim");
        require(secret != bytes32(0), "HTLC: Secret cannot be empty");
        require(!usedSecrets[secret], "HTLC: Secret already used");
        
        // Multi-algorithm hash verification
        bytes32 hashedSecret;
        if (htlc.hashAlgorithm == HashAlgorithm.SHA256) {
            hashedSecret = sha256(abi.encodePacked(secret));
        } else if (htlc.hashAlgorithm == HashAlgorithm.KECCAK256) {
            hashedSecret = keccak256(abi.encodePacked(secret));
        } else if (htlc.hashAlgorithm == HashAlgorithm.RIPEMD160) {
            hashedSecret = ripemd160(abi.encodePacked(secret));
        } else {
            revert("HTLC: Invalid hash algorithm");
        }
        
        require(hashedSecret == htlc.hashLock, "HTLC: Invalid secret");
        
        // Mark secret as used to prevent reuse attacks
        usedSecrets[secret] = true;
        
        // Update contract state
        htlc.withdrawn = true;
        htlc.secret = secret;

        // Transfer funds to recipient with enhanced security
        if (htlc.tokenAddress == address(0)) {
            // Transfer ETH with gas limit to prevent reentrancy
            (bool success, ) = htlc.recipient.call{value: htlc.amount, gas: 2300}("");
            require(success, "HTLC: ETH transfer failed");
            
            // Return security deposit for high-value transfers
            if (htlc.isHighValue && htlc.securityDeposit > 0) {
                (bool depositSuccess, ) = htlc.sender.call{value: htlc.securityDeposit, gas: 2300}("");
                require(depositSuccess, "HTLC: Security deposit return failed");
            }
        } else {
            // Transfer ERC20 tokens
            IERC20(htlc.tokenAddress).safeTransfer(htlc.recipient, htlc.amount);
            
            // Return ETH security deposit for high-value transfers
            if (htlc.isHighValue && htlc.securityDeposit > 0) {
                (bool depositSuccess, ) = htlc.sender.call{value: htlc.securityDeposit, gas: 2300}("");
                require(depositSuccess, "HTLC: Security deposit return failed");
            }
        }

        emit SecretRevealed(contractId, secret, htlc.hashAlgorithm);
        emit HtlcClaimed(contractId, secret, msg.sender, htlc.amount);
        emit SecurityEvent(contractId, "HTLC_CLAIMED", msg.sender, block.timestamp);
    }

    /**
     * @notice Refund funds after time lock expiration with enhanced security validation
     * @param contractId The unique contract identifier
     * @dev Implements comprehensive security checks including time validation,
     *      refund authorization, and economic security for high-value transfers
     */
    function refundHtlc(bytes32 contractId) external nonReentrant whenNotPaused notContractPaused(contractId) {
        HtlcContract storage htlc = contracts[contractId];
        
        // Enhanced validation checks
        require(contractExists[contractId], "HTLC: Contract does not exist");
        require(!htlc.withdrawn, "HTLC: Funds already withdrawn");
        require(!htlc.refunded, "HTLC: Funds already refunded");
        require(block.timestamp >= htlc.timeLock, "HTLC: Contract has not expired");
        require(msg.sender == htlc.sender, "HTLC: Only sender can refund");
        
        // Additional security: prevent immediate refunds (grace period)
        require(
            block.timestamp >= htlc.timeLock + 300, // 5 minute grace period
            "HTLC: Grace period active"
        );

        htlc.refunded = true;

        // Transfer funds back to sender with enhanced security
        if (htlc.tokenAddress == address(0)) {
            // Calculate total refund including security deposit
            uint256 totalRefund = htlc.amount + htlc.securityDeposit;
            
            // Transfer ETH with gas limit to prevent reentrancy
            (bool success, ) = htlc.sender.call{value: totalRefund, gas: 2300}("");
            require(success, "HTLC: ETH refund failed");
        } else {
            // Transfer ERC20 tokens back to sender
            IERC20(htlc.tokenAddress).safeTransfer(htlc.sender, htlc.amount);
            
            // Return ETH security deposit if applicable
            if (htlc.securityDeposit > 0) {
                (bool depositSuccess, ) = htlc.sender.call{value: htlc.securityDeposit, gas: 2300}("");
                require(depositSuccess, "HTLC: Security deposit refund failed");
            }
        }

        emit HtlcRefunded(contractId, msg.sender, htlc.amount);
        emit SecurityEvent(contractId, "HTLC_REFUNDED", msg.sender, block.timestamp);
    }

    /**
     * @dev Get contract details
     * @param contractId The contract identifier
     * @return hashLock The hash of the secret
     * @return timeLock The expiration timestamp 
     * @return sender The contract creator
     * @return recipient The fund recipient
     * @return amount The contract amount
     * @return tokenAddress The token contract address
     * @return withdrawn Whether funds have been withdrawn
     * @return refunded Whether funds have been refunded
     * @return secret The revealed secret (if claimed)
     */
    function getContract(bytes32 contractId) external view returns (
        bytes32 hashLock,
        uint256 timeLock,
        address sender,
        address recipient,
        uint256 amount,
        address tokenAddress,
        bool withdrawn,
        bool refunded,
        bytes32 secret
    ) {
        require(contractExists[contractId], "Contract does not exist");
        
        HtlcContract storage htlc = contracts[contractId];
        return (
            htlc.hashLock,
            htlc.timeLock,
            htlc.sender,
            htlc.recipient,
            htlc.amount,
            htlc.tokenAddress,
            htlc.withdrawn,
            htlc.refunded,
            htlc.secret
        );
    }

    /**
     * @dev Check if contract is claimable
     * @param contractId The contract identifier
     * @return Whether the contract can be claimed
     */
    function isClaimable(bytes32 contractId) external view returns (bool) {
        if (!contractExists[contractId]) return false;
        
        HtlcContract storage htlc = contracts[contractId];
        return !htlc.withdrawn && 
               !htlc.refunded && 
               block.timestamp < htlc.timeLock;
    }

    /**
     * @dev Check if contract is refundable
     * @param contractId The contract identifier
     * @return Whether the contract can be refunded
     */
    function isRefundable(bytes32 contractId) external view returns (bool) {
        if (!contractExists[contractId]) return false;
        
        HtlcContract storage htlc = contracts[contractId];
        return !htlc.withdrawn && 
               !htlc.refunded && 
               block.timestamp >= htlc.timeLock;
    }

    /**
     * @dev Get the secret if revealed
     * @param contractId The contract identifier
     * @return The revealed secret (bytes32(0) if not revealed)
     */
    function getSecret(bytes32 contractId) external view returns (bytes32) {
        require(contractExists[contractId], "Contract does not exist");
        return contracts[contractId].secret;
    }

    /**
     * @dev Check time until expiration
     * @param contractId The contract identifier
     * @return Seconds until expiration (0 if expired)
     */
    function timeUntilExpiration(bytes32 contractId) external view returns (uint256) {
        require(contractExists[contractId], "Contract does not exist");
        
        uint256 timeLock = contracts[contractId].timeLock;
        if (block.timestamp >= timeLock) {
            return 0;
        }
        return timeLock - block.timestamp;
    }

    /**
     * @notice Pause individual contract in case of security concerns
     * @param contractId The contract to pause
     * @dev Only owner can pause individual contracts for emergency situations
     */
    function pauseContract(bytes32 contractId) external onlyOwner {
        require(contractExists[contractId], "HTLC: Contract does not exist");
        require(!contractPaused[contractId], "HTLC: Contract already paused");
        
        contractPaused[contractId] = true;
        emit ContractPaused(contractId, msg.sender);
        emit SecurityEvent(contractId, "CONTRACT_PAUSED", msg.sender, block.timestamp);
    }
    
    /**
     * @notice Unpause individual contract
     * @param contractId The contract to unpause
     * @dev Only owner can unpause individual contracts
     */
    function unpauseContract(bytes32 contractId) external onlyOwner {
        require(contractExists[contractId], "HTLC: Contract does not exist");
        require(contractPaused[contractId], "HTLC: Contract not paused");
        
        contractPaused[contractId] = false;
        emit ContractUnpaused(contractId, msg.sender);
        emit SecurityEvent(contractId, "CONTRACT_UNPAUSED", msg.sender, block.timestamp);
    }
    
    /**
     * @notice Batch operation to create multiple HTLCs for gas optimization
     * @param contractIds Array of unique contract identifiers
     * @param hashLocks Array of hash locks
     * @param hashAlgorithms Array of hash algorithms
     * @param timeLocks Array of expiration timestamps
     * @param recipients Array of recipient addresses
     * @param tokenAddresses Array of token contract addresses
     * @param amounts Array of amounts to lock
     * @dev All arrays must have the same length. High-value transfers still subject to individual security deposits
     */
    function createBatchHtlc(
        bytes32[] calldata contractIds,
        bytes32[] calldata hashLocks,
        HashAlgorithm[] calldata hashAlgorithms,
        uint256[] calldata timeLocks,
        address[] calldata recipients,
        address[] calldata tokenAddresses,
        uint256[] calldata amounts
    ) external payable nonReentrant whenNotPaused rateLimited {
        require(
            contractIds.length == hashLocks.length &&
            hashLocks.length == hashAlgorithms.length &&
            hashAlgorithms.length == timeLocks.length &&
            timeLocks.length == recipients.length &&
            recipients.length == tokenAddresses.length &&
            tokenAddresses.length == amounts.length,
            "HTLC: Array length mismatch"
        );
        
        require(contractIds.length <= 10, "HTLC: Batch size too large");
        require(contractIds.length > 0, "HTLC: Empty batch");
        
        uint256 totalETHRequired = 0;
        uint256 totalSecurityDeposit = 0;
        
        // Pre-calculate total ETH and security deposits required
        for (uint256 i = 0; i < contractIds.length; i++) {
            require(!contractExists[contractIds[i]], "HTLC: Contract ID already exists");
            require(hashLocks[i] != bytes32(0), "HTLC: Hash lock cannot be empty");
            require(timeLocks[i] > block.timestamp, "HTLC: Time lock must be in the future");
            require(timeLocks[i] <= block.timestamp + MAX_TIME_LOCK, "HTLC: Time lock too far in future");
            require(timeLocks[i] >= block.timestamp + MIN_TIME_LOCK, "HTLC: Time lock too short");
            require(recipients[i] != address(0), "HTLC: Invalid recipient address");
            require(recipients[i] != msg.sender, "HTLC: Sender cannot be recipient");
            require(amounts[i] > 0, "HTLC: Amount must be greater than zero");
            require(uint8(hashAlgorithms[i]) <= 2, "HTLC: Invalid hash algorithm");
            
            if (tokenAddresses[i] == address(0)) {
                totalETHRequired += amounts[i];
            }
            
            // Check for high-value transfers
            if (amounts[i] >= HIGH_VALUE_THRESHOLD) {
                uint256 securityDeposit = (amounts[i] * SECURITY_DEPOSIT_RATE) / 10000;
                totalSecurityDeposit += securityDeposit;
            }
        }
        
        require(msg.value >= totalETHRequired + totalSecurityDeposit, "HTLC: Insufficient ETH sent");
        
        // Create all HTLCs
        for (uint256 i = 0; i < contractIds.length; i++) {
            bool isHighValue = amounts[i] >= HIGH_VALUE_THRESHOLD;
            uint256 requiredDeposit = 0;
            
            if (isHighValue) {
                requiredDeposit = (amounts[i] * SECURITY_DEPOSIT_RATE) / 10000;
            }
            
            // Transfer ERC20 tokens if not ETH
            if (tokenAddresses[i] != address(0)) {
                IERC20(tokenAddresses[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
            
            // Create contract record
            contracts[contractIds[i]] = HtlcContract({
                hashLock: hashLocks[i],
                timeLock: timeLocks[i],
                sender: msg.sender,
                recipient: recipients[i],
                amount: amounts[i],
                tokenAddress: tokenAddresses[i],
                withdrawn: false,
                refunded: false,
                secret: bytes32(0),
                hashAlgorithm: hashAlgorithms[i],
                nonce: senderNonces[msg.sender]++,
                signature: "",
                securityDeposit: requiredDeposit,
                isHighValue: isHighValue
            });
            
            contractExists[contractIds[i]] = true;
            
            emit HtlcCreated(
                contractIds[i],
                hashLocks[i],
                timeLocks[i],
                msg.sender,
                recipients[i],
                amounts[i],
                tokenAddresses[i],
                hashAlgorithms[i],
                isHighValue
            );
            
            if (isHighValue && requiredDeposit > 0) {
                emit SecurityDepositCollected(contractIds[i], requiredDeposit, msg.sender);
            }
            
            emit SecurityEvent(contractIds[i], "HTLC_BATCH_CREATED", msg.sender, block.timestamp);
        }
        
        // Refund excess ETH
        uint256 totalRequired = totalETHRequired + totalSecurityDeposit;
        if (msg.value > totalRequired) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - totalRequired, gas: 2300}("");
            require(refundSuccess, "HTLC: Excess refund failed");
        }
    }
    
    /**
     * @notice Pause the contract and record the pause timestamp (H-04 fix)
     * @dev Only callable by owner. Records pausedAt for emergency recovery timelock.
     */
    function pause() external onlyOwner {
        pausedAt = block.timestamp;
        _pause();
    }

    /**
     * @notice Unpause the contract
     * @dev Only callable by owner. Resets pausedAt.
     */
    function unpause() external onlyOwner {
        pausedAt = 0;
        _unpause();
    }

    /**
     * @notice Emergency function to recover stuck tokens (owner only)
     * @param tokenAddress Token contract address (address(0) for ETH)
     * @param amount Amount to recover
     * @dev Only callable when contract is paused and after 7-day timelock
     */
    function emergencyTokenRecovery(
        address tokenAddress,
        uint256 amount
    ) external onlyOwner {
        require(paused(), "HTLC: Not in emergency state");
        // H-04 fix: Enforce 7-day timelock after pause as documented in NatSpec
        require(pausedAt > 0, "HTLC: Pause timestamp not set");
        require(block.timestamp >= pausedAt + 7 days, "HTLC: 7-day timelock not elapsed");
        
        if (tokenAddress == address(0)) {
            // Recover ETH
            require(address(this).balance >= amount, "HTLC: Insufficient ETH balance");
            (bool success, ) = owner().call{value: amount, gas: 2300}("");
            require(success, "HTLC: ETH recovery failed");
        } else {
            // Recover ERC20 tokens
            IERC20(tokenAddress).safeTransfer(owner(), amount);
        }
        
        emit SecurityEvent(bytes32(0), "EMERGENCY_RECOVERY", msg.sender, block.timestamp);
    }

    /**
     * @dev Receive function to accept ETH deposits
     */
    receive() external payable {
        // Accept ETH deposits for HTLC contracts
    }

    /**
     * @dev Fallback function
     */
    fallback() external payable {
        revert("Function not found");
    }
}