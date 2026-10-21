// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./NFTCrossChainBridge.sol";
import "./CrossChainBridgeSecurityHardening.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SecureBridgeIntegration
 * @dev Integration layer that combines the existing NFT bridge with enhanced security hardening
 * Provides seamless integration while maintaining backward compatibility
 * 
 * Security Integration Features:
 * - Pre-transfer security validation
 * - Dynamic security level determination
 * - Enhanced validator selection
 * - Risk-based approval workflows
 * - Real-time monitoring integration
 * - Automatic security adjustments
 * 
 * OWASP SC02 Remediation:
 * - Multi-layered access control validation
 * - Enhanced validator consensus requirements
 * - Risk-based security escalation
 * - Comprehensive audit logging
 * 
 * @author WRFCoin Security Team
 * @custom:security-contact security@wrfcoin.io
 */
contract SecureBridgeIntegration is AccessControl, ReentrancyGuard {
    
    // ============ Contract References ============
    
    NFTCrossChainBridge public immutable nftBridge;
    CrossChainBridgeSecurityHardening public immutable securityHardening;
    
    // ============ Integration Constants ============
    
    uint256 public constant INTEGRATION_VERSION = 1;
    uint256 public constant SECURITY_CHECK_TIMEOUT = 5 minutes;
    uint256 public constant MAX_PENDING_APPROVALS = 50;
    /// @notice Maximum transfer value allowed even for whitelisted bypass users (B-01 fix)
    uint256 public constant MAX_WHITELISTED_VALUE = 100 ether;
    
    // ============ Roles ============
    
    bytes32 public constant INTEGRATION_ADMIN_ROLE = keccak256("INTEGRATION_ADMIN_ROLE");
    bytes32 public constant SECURITY_OPERATOR_ROLE = keccak256("SECURITY_OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_OPERATOR_ROLE = keccak256("EMERGENCY_OPERATOR_ROLE");
    
    // ============ Structs ============
    
    struct SecureTransferRequest {
        bytes32 transferId;
        address user;
        address nftContract;
        uint256 tokenId;
        uint256 destinationChain;
        address recipient;
        uint256 value;
        uint256 riskScore;
        CrossChainBridgeSecurityHardening.SecurityLevel securityLevel;
        uint256 requestTime;
        uint256 approvalDeadline;
        bool requiresManualApproval;
        bool isApproved;
        bool isExecuted;
        string metadata;
    }
    
    struct SecurityValidationResult {
        bool isValid;
        string reason;
        uint256 requiredValidators;
        uint256 timelock;
        bool requiresManualApproval;
        CrossChainBridgeSecurityHardening.SecurityLevel securityLevel;
    }
    
    struct ValidatorSelection {
        address[] selectedValidators;
        uint256 selectionTime;
        bytes32 selectionSeed;
        uint256 requiredCount;
    }
    
    // ============ State Variables ============
    
    // Transfer management
    mapping(bytes32 => SecureTransferRequest) public pendingTransfers;
    mapping(address => bytes32[]) public userPendingTransfers;
    mapping(bytes32 => ValidatorSelection) public transferValidators;
    
    // Security integration tracking
    uint256 public totalSecureTransfers;
    uint256 public blockedTransfers;
    uint256 public manualApprovalsRequired;
    uint256 public averageProcessingTime;
    
    // Manual approval queue
    bytes32[] public pendingApprovals;
    mapping(bytes32 => bool) public requiresManualApproval;
    
    // Integration settings
    bool public integrationEnabled = true;
    // Deprecated: retained for storage compatibility, bypass cannot be enabled.
    bool public bypassSecurityForWhitelisted = false;
    // Deprecated: retained for storage compatibility, whitelist entries are rejected.
    mapping(address => bool) public securityBypassWhitelist;
    
    // ============ Events ============
    
    event SecureTransferInitiated(
        bytes32 indexed transferId,
        address indexed user,
        uint256 riskScore,
        CrossChainBridgeSecurityHardening.SecurityLevel securityLevel,
        bool requiresManualApproval
    );
    
    event SecurityValidationCompleted(
        bytes32 indexed transferId,
        bool approved,
        string reason,
        uint256 timestamp
    );
    
    event ManualApprovalRequired(
        bytes32 indexed transferId,
        address indexed user,
        uint256 value,
        string reason
    );
    
    event ManualApprovalGranted(
        bytes32 indexed transferId,
        address indexed approver,
        uint256 timestamp
    );
    
    event TransferSecurityEscalated(
        bytes32 indexed transferId,
        CrossChainBridgeSecurityHardening.SecurityLevel oldLevel,
        CrossChainBridgeSecurityHardening.SecurityLevel newLevel,
        string reason
    );
    
    event ValidatorsSelected(
        bytes32 indexed transferId,
        address[] validators,
        uint256 requiredCount
    );
    
    event IntegrationStatusChanged(
        bool enabled,
        address indexed admin,
        uint256 timestamp
    );
    
    event SecurityBypassGranted(
        address indexed user,
        address indexed admin,
        uint256 timestamp
    );
    
    // ============ Modifiers ============
    
    modifier onlyIntegrationAdmin() {
        require(hasRole(INTEGRATION_ADMIN_ROLE, msg.sender), "SecureBridge: Not integration admin");
        _;
    }
    
    modifier onlySecurityOperator() {
        require(hasRole(SECURITY_OPERATOR_ROLE, msg.sender), "SecureBridge: Not security operator");
        _;
    }
    
    modifier integrationActive() {
        require(integrationEnabled, "SecureBridge: Integration disabled");
        _;
    }
    
    modifier validTransferId(bytes32 transferId) {
        require(pendingTransfers[transferId].transferId != bytes32(0), "SecureBridge: Invalid transfer ID");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _nftBridge,
        address _securityHardening
    ) {
        require(_nftBridge != address(0), "SecureBridge: Invalid NFT bridge");
        require(_securityHardening != address(0), "SecureBridge: Invalid security hardening");
        
        nftBridge = NFTCrossChainBridge(_nftBridge);
        securityHardening = CrossChainBridgeSecurityHardening(_securityHardening);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(INTEGRATION_ADMIN_ROLE, msg.sender);
        _grantRole(SECURITY_OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_OPERATOR_ROLE, msg.sender);
    }
    
    // ============ Main Bridge Functions ============
    
    /**
     * @notice Initiate secure cross-chain NFT transfer with enhanced security validation
     * @dev Implements comprehensive security checks before bridge transfer
     * @param nftContract Address of the NFT contract
     * @param tokenId NFT token ID
     * @param destinationChain Destination chain type
     * @param recipient Recipient address
     * @param metadata Transfer metadata
     * @return transferId Unique transfer identifier
     */
    function initiateSecureTransfer(
        address nftContract,
        uint256 tokenId,
        NFTCrossChainBridge.ChainType destinationChain,
        address recipient,
        string memory metadata
    ) external payable nonReentrant integrationActive returns (bytes32 transferId) {
        require(nftContract != address(0), "SecureBridge: Invalid NFT contract");
        require(recipient != address(0), "SecureBridge: Invalid recipient");
        
        // Generate unique transfer ID
        transferId = keccak256(abi.encodePacked(
            nftContract,
            tokenId,
            msg.sender,
            recipient,
            destinationChain,
            block.timestamp,
            totalSecureTransfers++
        ));
        
        // Get NFT value for security assessment
        uint256 nftValue = _estimateNFTValue(nftContract, tokenId);
        
        // Perform comprehensive security validation
        SecurityValidationResult memory validation = _performSecurityValidation(
            msg.sender,
            nftValue,
            uint256(destinationChain)
        );
        
        if (!validation.isValid) {
            blockedTransfers++;
            revert(string(abi.encodePacked("SecureBridge: Transfer blocked - ", validation.reason)));
        }
        
        // Create secure transfer request
        SecureTransferRequest storage request = pendingTransfers[transferId];
        request.transferId = transferId;
        request.user = msg.sender;
        request.nftContract = nftContract;
        request.tokenId = tokenId;
        request.destinationChain = uint256(destinationChain);
        request.recipient = recipient;
        request.value = nftValue;
        request.riskScore = securityHardening.calculateTransferRiskScore(msg.sender, nftValue, uint256(destinationChain));
        request.securityLevel = validation.securityLevel;
        request.requestTime = block.timestamp;
        request.approvalDeadline = block.timestamp + SECURITY_CHECK_TIMEOUT;
        request.requiresManualApproval = validation.requiresManualApproval;
        request.isApproved = false;
        request.isExecuted = false;
        request.metadata = metadata;
        
        // Add to user's pending transfers
        userPendingTransfers[msg.sender].push(transferId);
        
        // Select validators for this transfer
        _selectValidators(transferId, validation.requiredValidators);
        
        emit SecureTransferInitiated(
            transferId,
            msg.sender,
            request.riskScore,
            validation.securityLevel,
            validation.requiresManualApproval
        );
        
        // Handle manual approval requirement
        if (validation.requiresManualApproval) {
            _queueForManualApproval(transferId);
            return transferId;
        }
        
        // Auto-approve if timelock is 0 and no manual approval required
        if (validation.timelock == 0) {
            _approveTransfer(transferId);
        }
        
        return transferId;
    }
    
    /**
     * @notice Execute approved secure transfer
     * @dev Executes the transfer after all security requirements are met
     * @param transferId Transfer ID to execute
     */
    function executeSecureTransfer(bytes32 transferId) external payable nonReentrant validTransferId(transferId) {
        SecureTransferRequest storage request = pendingTransfers[transferId];
        
        require(request.user == msg.sender, "SecureBridge: Not transfer owner");
        require(request.isApproved, "SecureBridge: Transfer not approved");
        require(!request.isExecuted, "SecureBridge: Transfer already executed");
        require(block.timestamp <= request.approvalDeadline, "SecureBridge: Transfer expired");
        
        // Final security checks
        (bool allowed, string memory reason) = securityHardening.wouldTransferBeBlocked(
            request.user,
            request.value,
            request.destinationChain
        );
        
        if (!allowed) {
            revert(string(abi.encodePacked("SecureBridge: Transfer blocked - ", reason)));
        }
        
        // Mark as executed
        request.isExecuted = true;
        
        // Execute the actual bridge transfer
        try nftBridge.bridgeNFT{value: msg.value}(
            request.nftContract,
            request.tokenId,
            NFTCrossChainBridge.ChainType(request.destinationChain),
            request.recipient,
            request.metadata
        ) returns (bytes32 bridgeTransferId) {
            // Update metrics
            averageProcessingTime = (averageProcessingTime * (totalSecureTransfers - 1) + 
                                   (block.timestamp - request.requestTime)) / totalSecureTransfers;
            
            // Clean up pending transfer
            _cleanupPendingTransfer(transferId, request.user);
            
            emit SecurityValidationCompleted(transferId, true, "Transfer executed successfully", block.timestamp);
        } catch Error(string memory revertReason) {
            request.isExecuted = false;
            revert(string(abi.encodePacked("SecureBridge: Bridge transfer failed - ", revertReason)));
        }
    }
    
    /**
     * @notice Approve transfer for manual approval queue
     * @dev Allows security operators to approve transfers requiring manual review
     * @param transferId Transfer ID to approve
     */
    function approveManualTransfer(bytes32 transferId) external onlySecurityOperator validTransferId(transferId) {
        SecureTransferRequest storage request = pendingTransfers[transferId];
        
        require(request.requiresManualApproval, "SecureBridge: Manual approval not required");
        require(!request.isApproved, "SecureBridge: Already approved");
        require(block.timestamp <= request.approvalDeadline, "SecureBridge: Transfer expired");
        
        request.isApproved = true;
        
        // Remove from pending approvals queue
        _removeFromApprovalQueue(transferId);
        
        emit ManualApprovalGranted(transferId, msg.sender, block.timestamp);
    }
    
    /**
     * @notice Reject transfer in manual approval queue
     * @dev Allows security operators to reject transfers requiring manual review
     * @param transferId Transfer ID to reject
     * @param reason Reason for rejection
     */
    function rejectManualTransfer(
        bytes32 transferId, 
        string memory reason
    ) external onlySecurityOperator validTransferId(transferId) {
        SecureTransferRequest storage request = pendingTransfers[transferId];
        
        require(request.requiresManualApproval, "SecureBridge: Manual approval not required");
        require(!request.isApproved, "SecureBridge: Already approved");
        
        // Clean up and notify
        _cleanupPendingTransfer(transferId, request.user);
        
        emit SecurityValidationCompleted(transferId, false, reason, block.timestamp);
    }
    
    // ============ Security Integration Functions ============
    
    /**
     * @notice Perform comprehensive security validation
     * @dev Implements multi-layered security assessment
     * @param user User address
     * @param value Transfer value
     * @param destinationChain Destination chain ID
     * @return validation Security validation result
     */
    function _performSecurityValidation(
        address user,
        uint256 value,
        uint256 destinationChain
    ) internal view returns (SecurityValidationResult memory validation) {
        // Check if transfer would be blocked
        (bool blocked, string memory blockReason) = securityHardening.wouldTransferBeBlocked(
            user,
            value,
            destinationChain
        );
        
        if (blocked) {
            return SecurityValidationResult({
                isValid: false,
                reason: blockReason,
                requiredValidators: 0,
                timelock: 0,
                requiresManualApproval: false,
                securityLevel: CrossChainBridgeSecurityHardening.SecurityLevel.LOW
            });
        }
        
        // Calculate risk score
        uint256 riskScore = securityHardening.calculateTransferRiskScore(user, value, destinationChain);
        
        // Determine security level
        CrossChainBridgeSecurityHardening.SecurityLevel securityLevel = 
            securityHardening.determineSecurityLevel(value, riskScore);
        
        // Get security profile
        CrossChainBridgeSecurityHardening.TransferSecurityProfile memory profile = 
            securityHardening.getSecurityProfile(value);
        
        // Determine requirements based on security level
        uint256 requiredValidators = profile.requiredValidators;
        uint256 timelock = profile.timelockDuration;
        bool needsManualApproval = profile.requiresManualApproval || riskScore >= 80;
        
        return SecurityValidationResult({
            isValid: true,
            reason: "Validation passed",
            requiredValidators: requiredValidators,
            timelock: timelock,
            requiresManualApproval: needsManualApproval,
            securityLevel: securityLevel
        });
    }
    
    /**
     * @notice Select validators for transfer validation
     * @dev Implements secure validator selection algorithm
     * @param transferId Transfer ID
     * @param requiredCount Number of validators required
     */
    /**
     * @notice DISABLED: Validator selection requires proper integration with security hardening contract
     * @dev SECURITY FIX: Previous implementation created empty validator arrays (all zero addresses),
     * which would allow transfers to proceed without any actual validator authorization.
     * This must be properly integrated with CrossChainBridgeSecurityHardening's validator system
     * before it can be used in production.
     */
    function _selectValidators(bytes32 /* transferId */, uint256 /* requiredCount */) internal pure {
        revert("SecureBridge: Validator selection not implemented - requires security hardening integration");
    }
    
    /**
     * @notice Auto-approve transfer if conditions are met
     * @dev Automatically approves transfers that meet security requirements
     * @param transferId Transfer ID to approve
     */
    function _approveTransfer(bytes32 transferId) internal {
        SecureTransferRequest storage request = pendingTransfers[transferId];
        request.isApproved = true;
        
        emit SecurityValidationCompleted(transferId, true, "Auto-approved", block.timestamp);
    }
    
    /**
     * @notice Queue transfer for manual approval
     * @dev Adds transfer to manual approval queue
     * @param transferId Transfer ID to queue
     */
    function _queueForManualApproval(bytes32 transferId) internal {
        require(pendingApprovals.length < MAX_PENDING_APPROVALS, "SecureBridge: Approval queue full");
        
        pendingApprovals.push(transferId);
        requiresManualApproval[transferId] = true;
        manualApprovalsRequired++;
        
        SecureTransferRequest memory request = pendingTransfers[transferId];
        emit ManualApprovalRequired(transferId, request.user, request.value, "High risk transfer");
    }
    
    /**
     * @notice Execute direct transfer (bypass security for whitelisted users)
     * @dev Executes transfer directly without security delays
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @param destinationChain Destination chain
     * @param recipient Recipient address
     * @param metadata Transfer metadata
     * @return transferId Bridge transfer ID
     */
    function _executeDirectTransfer(
        address nftContract,
        uint256 tokenId,
        NFTCrossChainBridge.ChainType destinationChain,
        address recipient,
        string memory metadata
    ) internal returns (bytes32 transferId) {
        return nftBridge.bridgeNFT{value: msg.value}(
            nftContract,
            tokenId,
            destinationChain,
            recipient,
            metadata
        );
    }
    
    /**
     * @notice Estimate NFT value for security assessment
     * @dev Implements NFT valuation logic
     * @param nftContract NFT contract address
     * @param tokenId Token ID
     * @return value Estimated value in wei
     */
    /**
     * @notice DISABLED: NFT valuation requires oracle price feed integration
     * @dev SECURITY FIX: Previous placeholder returned arbitrary values based on tokenId modulo,
     * which could be manipulated to bypass security thresholds or trigger incorrect risk assessments.
     * Must integrate with a proper price oracle before use.
     */
    function _estimateNFTValue(address /* nftContract */, uint256 /* tokenId */) internal pure returns (uint256) {
        revert("SecureBridge: NFT valuation not implemented - requires oracle price feed");
    }
    
    /**
     * @notice Clean up pending transfer data
     * @dev Removes transfer from pending lists and mappings
     * @param transferId Transfer ID to clean up
     * @param user User address
     */
    function _cleanupPendingTransfer(bytes32 transferId, address user) internal {
        // Remove from user's pending transfers
        bytes32[] storage userTransfers = userPendingTransfers[user];
        for (uint256 i = 0; i < userTransfers.length; i++) {
            if (userTransfers[i] == transferId) {
                userTransfers[i] = userTransfers[userTransfers.length - 1];
                userTransfers.pop();
                break;
            }
        }
        
        // Clean up validator selection
        delete transferValidators[transferId];
        
        // Remove from manual approval if needed
        if (requiresManualApproval[transferId]) {
            _removeFromApprovalQueue(transferId);
        }
    }
    
    /**
     * @notice Remove transfer from approval queue
     * @dev Removes transfer ID from pending approvals array
     * @param transferId Transfer ID to remove
     */
    function _removeFromApprovalQueue(bytes32 transferId) internal {
        for (uint256 i = 0; i < pendingApprovals.length; i++) {
            if (pendingApprovals[i] == transferId) {
                pendingApprovals[i] = pendingApprovals[pendingApprovals.length - 1];
                pendingApprovals.pop();
                break;
            }
        }
        requiresManualApproval[transferId] = false;
    }
    
    // ============ Administrative Functions ============
    
    /**
     * @notice Enable or disable security integration
     * @dev Controls whether enhanced security is active
     * @param enabled Whether integration is enabled
     */
    function setIntegrationEnabled(bool enabled) external onlyIntegrationAdmin {
        integrationEnabled = enabled;
        emit IntegrationStatusChanged(enabled, msg.sender, block.timestamp);
    }
    
    /**
     * @notice Manage legacy security bypass flag
     * @dev Bypass activation is permanently disabled to preserve transfer security invariants.
     * @param enabled Must be false
     */
    function setSecurityBypassEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!enabled, "SecureBridge: Security bypass disabled");
        bypassSecurityForWhitelisted = false;
    }
    
    /**
     * @notice Legacy whitelist method
     * @dev Whitelisting is disabled and cannot be used to bypass validation.
     * @param user User to whitelist
     */
    function addToSecurityBypass(address user) external onlyIntegrationAdmin {
        require(user != address(0), "SecureBridge: Invalid user");
        revert("SecureBridge: Security bypass disabled");
    }
    
    /**
     * @notice Remove user from security bypass whitelist
     * @dev Removes security bypass privileges
     * @param user User to remove
     */
    function removeFromSecurityBypass(address user) external onlyIntegrationAdmin {
        securityBypassWhitelist[user] = false;
    }
    
    /**
     * @notice Emergency cancel transfer
     * @dev Allows emergency operators to cancel transfers
     * @param transferId Transfer ID to cancel
     * @param reason Reason for cancellation
     */
    function emergencyCancelTransfer(
        bytes32 transferId, 
        string memory reason
    ) external onlyRole(EMERGENCY_OPERATOR_ROLE) validTransferId(transferId) {
        SecureTransferRequest storage request = pendingTransfers[transferId];
        require(!request.isExecuted, "SecureBridge: Transfer already executed");
        
        _cleanupPendingTransfer(transferId, request.user);
        emit SecurityValidationCompleted(transferId, false, string(abi.encodePacked("Emergency cancel: ", reason)), block.timestamp);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get transfer details
     * @dev Returns comprehensive transfer information
     * @param transferId Transfer ID
     * @return request Transfer request details
     */
    function getTransferDetails(bytes32 transferId) external view returns (SecureTransferRequest memory request) {
        return pendingTransfers[transferId];
    }
    
    /**
     * @notice Get user's pending transfers
     * @dev Returns array of pending transfer IDs for user
     * @param user User address
     * @return transferIds Array of pending transfer IDs
     */
    function getUserPendingTransfers(address user) external view returns (bytes32[] memory transferIds) {
        return userPendingTransfers[user];
    }
    
    /**
     * @notice Get pending manual approvals
     * @dev Returns transfers waiting for manual approval
     * @return approvals Array of transfer IDs requiring approval
     */
    function getPendingApprovals() external view returns (bytes32[] memory approvals) {
        return pendingApprovals;
    }
    
    /**
     * @notice Get integration statistics
     * @dev Returns comprehensive integration metrics
     * @return totalTransfers Total number of secure transfers
     * @return blocked Number of blocked transfers
     * @return manualApprovals Number of manual approvals required
     * @return avgProcessingTime Average processing time
     */
    function getIntegrationStats() external view returns (
        uint256 totalTransfers,
        uint256 blocked,
        uint256 manualApprovals,
        uint256 avgProcessingTime
    ) {
        return (totalSecureTransfers, blockedTransfers, manualApprovalsRequired, averageProcessingTime);
    }
    
    /**
     * @notice Preview security requirements for transfer
     * @dev Returns security requirements without executing transfer
     * @param user User address
     * @param value Transfer value
     * @param destinationChain Destination chain ID
     * @return validation Security validation preview
     */
    function previewSecurityRequirements(
        address user,
        uint256 value,
        uint256 destinationChain
    ) external view returns (SecurityValidationResult memory validation) {
        return _performSecurityValidation(user, value, destinationChain);
    }
    
    /**
     * @notice Check if user is whitelisted for security bypass
     * @dev Returns whether user can bypass security measures
     * @param user User address
     * @return whitelisted Whether user is whitelisted
     */
    function isSecurityBypassWhitelisted(address user) external view returns (bool whitelisted) {
        return securityBypassWhitelist[user];
    }
}
