// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title WRFTreasury
 * @dev Comprehensive treasury management contract for the WRF DAO
 * Features:
 * - Multi-signature wallet integration
 * - Spending proposal creation and execution
 * - Budget allocation and tracking
 * - Emergency controls and pause mechanisms
 * - Cross-chain treasury management support
 * - DeFi protocol integration capabilities
 * - Audit trails for all treasury actions
 */
contract WRFTreasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Role definitions
    bytes32 public constant TREASURY_ADMIN_ROLE = keccak256("TREASURY_ADMIN_ROLE");
    bytes32 public constant SPENDING_MANAGER_ROLE = keccak256("SPENDING_MANAGER_ROLE");
    bytes32 public constant BUDGET_MANAGER_ROLE = keccak256("BUDGET_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MULTISIG_ROLE = keccak256("MULTISIG_ROLE");
    bytes32 public constant PROPOSAL_CREATOR_ROLE = keccak256("PROPOSAL_CREATOR_ROLE");

    // Spending proposal states
    enum ProposalState {
        Pending,
        Approved,
        Executed,
        Cancelled,
        Expired
    }

    // Treasury operation types
    enum OperationType {
        Transfer,
        Approve,
        DeFiDeposit,
        DeFiWithdraw,
        CrossChainTransfer,
        EmergencyWithdraw
    }

    // Multi-signature configuration
    struct MultiSigConfig {
        address[] signers;
        uint256 requiredSignatures;
        uint256 nonce;
        bool active;
    }

    // Spending proposal structure
    struct SpendingProposal {
        uint256 id;
        address proposer;
        address recipient;
        address token;
        uint256 amount;
        string description;
        string category;
        uint256 createdAt;
        uint256 executionDeadline;
        ProposalState state;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 requiredVotes;
        bytes32 budgetCategory;
        mapping(address => bool) hasVoted;
        mapping(address => bool) hasApproved;
        uint256 approvalCount;
        uint256 requiredApprovals;
    }

    // Budget allocation structure
    struct BudgetAllocation {
        bytes32 category;
        uint256 totalAllocated;
        uint256 spent;
        uint256 remaining;
        uint256 period;
        uint256 lastReset;
        bool active;
    }

    // Treasury operation for audit trail
    struct TreasuryOperation {
        uint256 id;
        OperationType operationType;
        address initiator;
        address target;
        address token;
        uint256 amount;
        string description;
        uint256 timestamp;
        bytes32 transactionHash;
        bool executed;
    }

    // State variables
    TimelockController public timelock;
    MultiSigConfig public multiSigConfig;
    
    uint256 public proposalCount;
    uint256 public operationCount;
    uint256 public emergencyWithdrawLimit;
    uint256 public maxProposalDuration;
    uint256 public minProposalDuration;
    
    // Mappings
    mapping(uint256 => SpendingProposal) public proposals;
    mapping(bytes32 => BudgetAllocation) public budgets;
    mapping(address => uint256) public lastEmergencyWithdraw;
    mapping(uint256 => TreasuryOperation) public operations;
    mapping(address => mapping(address => uint256)) public tokenBalances;
    mapping(bytes32 => bool) public executedTransactions;
    
    // Cross-chain support
    mapping(uint256 => address) public crossChainBridges;
    mapping(address => bool) public authorizedBridges;
    
    // DeFi protocol integration
    mapping(address => bool) public authorizedProtocols;
    mapping(address => uint256) public protocolAllocations;

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed recipient,
        address token,
        uint256 amount,
        string description
    );
    
    event ProposalVoted(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 votes
    );
    
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor,
        bool success
    );
    
    event BudgetAllocated(
        bytes32 indexed category,
        uint256 amount,
        uint256 period
    );
    
    event TreasuryOperationExecuted(
        uint256 indexed operationId,
        OperationType operationType,
        address indexed target,
        uint256 amount
    );
    
    event MultiSigConfigUpdated(
        address[] signers,
        uint256 requiredSignatures
    );
    
    event EmergencyWithdrawExecuted(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    
    event CrossChainTransferInitiated(
        uint256 indexed chainId,
        address indexed token,
        uint256 amount,
        address recipient
    );
    
    event DeFiOperationExecuted(
        address indexed protocol,
        address indexed token,
        uint256 amount,
        string operation
    );

    event BudgetReset(
        string indexed category,
        uint256 newRemaining,
        uint256 timestamp
    );

    event BudgetDeactivated(
        string indexed category,
        uint256 timestamp
    );

    event BridgeAuthorized(
        address indexed bridge,
        uint256 indexed chainId
    );

    event ProtocolAuthorized(
        address indexed protocol
    );

    event EmergencyWithdrawLimitUpdated(
        uint256 oldLimit,
        uint256 newLimit
    );

    event ProposalDurationLimitsUpdated(
        uint256 newMin,
        uint256 newMax
    );

    event ProposalCancelled(
        uint256 indexed proposalId
    );

    // Modifiers
    modifier onlyMultiSig() {
        require(hasRole(MULTISIG_ROLE, msg.sender), "WRFTreasury: Not authorized multisig");
        _;
    }

    modifier onlyTreasuryAdmin() {
        require(hasRole(TREASURY_ADMIN_ROLE, msg.sender), "WRFTreasury: Not treasury admin");
        _;
    }

    modifier onlySpendingManager() {
        require(hasRole(SPENDING_MANAGER_ROLE, msg.sender), "WRFTreasury: Not spending manager");
        _;
    }

    modifier onlyBudgetManager() {
        require(hasRole(BUDGET_MANAGER_ROLE, msg.sender), "WRFTreasury: Not budget manager");
        _;
    }

    modifier onlyEmergencyRole() {
        require(hasRole(EMERGENCY_ROLE, msg.sender), "WRFTreasury: Not emergency role");
        _;
    }

    modifier validProposal(uint256 proposalId) {
        require(proposalId > 0 && proposalId <= proposalCount, "WRFTreasury: Invalid proposal ID");
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        require(proposals[proposalId].id != 0, "WRFTreasury: Proposal does not exist");
        _;
    }

    constructor(
        address _timelock,
        address[] memory _initialSigners,
        uint256 _requiredSignatures,
        uint256 _emergencyWithdrawLimit
    ) {
        require(_timelock != address(0), "WRFTreasury: Invalid timelock address");
        require(_initialSigners.length >= _requiredSignatures, "WRFTreasury: Invalid signer configuration");
        require(_requiredSignatures > 0, "WRFTreasury: Required signatures must be > 0");

        timelock = TimelockController(payable(_timelock));
        
        // Set up multi-signature configuration
        multiSigConfig = MultiSigConfig({
            signers: _initialSigners,
            requiredSignatures: _requiredSignatures,
            nonce: 0,
            active: true
        });

        // Set up role hierarchy
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURY_ADMIN_ROLE, msg.sender);
        _grantRole(SPENDING_MANAGER_ROLE, msg.sender);
        _grantRole(BUDGET_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(PROPOSAL_CREATOR_ROLE, msg.sender);

        // Grant multisig role to initial signers
        for (uint256 i = 0; i < _initialSigners.length; i++) {
            _grantRole(MULTISIG_ROLE, _initialSigners[i]);
        }

        // Set initial parameters
        emergencyWithdrawLimit = _emergencyWithdrawLimit;
        maxProposalDuration = 30 days;
        minProposalDuration = 1 days;
    }

    // ============ SPENDING PROPOSAL FUNCTIONS ============

    /**
     * @dev Create a new spending proposal
     */
    function createSpendingProposal(
        address recipient,
        address token,
        uint256 amount,
        string calldata description,
        string calldata category,
        uint256 executionDeadline,
        bytes32 budgetCategory
    ) external whenNotPaused returns (uint256) {
        require(hasRole(PROPOSAL_CREATOR_ROLE, msg.sender), "WRFTreasury: Not authorized to create proposals");
        require(recipient != address(0), "WRFTreasury: Invalid recipient");
        require(amount > 0, "WRFTreasury: Amount must be > 0");
        require(executionDeadline > block.timestamp + minProposalDuration, "WRFTreasury: Invalid deadline");
        require(executionDeadline <= block.timestamp + maxProposalDuration, "WRFTreasury: Deadline too far");

        // Check budget allocation if specified
        if (budgetCategory != bytes32(0)) {
            BudgetAllocation storage budget = budgets[budgetCategory];
            require(budget.active, "WRFTreasury: Budget category not active");
            require(budget.remaining >= amount, "WRFTreasury: Insufficient budget");
        }

        // Check treasury balance
        uint256 balance = _getTokenBalance(token);
        require(balance >= amount, "WRFTreasury: Insufficient treasury balance");

        proposalCount++;
        uint256 proposalId = proposalCount;

        SpendingProposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.recipient = recipient;
        proposal.token = token;
        proposal.amount = amount;
        proposal.description = description;
        proposal.category = category;
        proposal.createdAt = block.timestamp;
        proposal.executionDeadline = executionDeadline;
        proposal.state = ProposalState.Pending;
        proposal.budgetCategory = budgetCategory;
        proposal.requiredVotes = _calculateRequiredVotes();
        proposal.requiredApprovals = multiSigConfig.requiredSignatures;

        emit ProposalCreated(proposalId, msg.sender, recipient, token, amount, description);
        return proposalId;
    }

    /**
     * @dev Vote on a spending proposal
     */
    function voteOnProposal(uint256 proposalId, bool support) external validProposal(proposalId) whenNotPaused {
        SpendingProposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Pending, "WRFTreasury: Proposal not in pending state");
        require(block.timestamp <= proposal.executionDeadline, "WRFTreasury: Proposal expired");
        require(!proposal.hasVoted[msg.sender], "WRFTreasury: Already voted");

        proposal.hasVoted[msg.sender] = true;
        
        // For simplicity, each voter gets 1 vote (can be enhanced with token-based voting)
        uint256 votes = 1;
        
        if (support) {
            proposal.votesFor += votes;
        } else {
            proposal.votesAgainst += votes;
        }

        emit ProposalVoted(proposalId, msg.sender, support, votes);

        // Check if proposal should be approved
        if (proposal.votesFor >= proposal.requiredVotes) {
            proposal.state = ProposalState.Approved;
        }
    }

    /**
     * @dev Multi-signature approval for spending proposals
     */
    function approveProposal(
        uint256 proposalId, 
        bytes calldata signature
    ) external onlyMultiSig validProposal(proposalId) whenNotPaused {
        SpendingProposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Approved, "WRFTreasury: Proposal not approved");
        require(block.timestamp <= proposal.executionDeadline, "WRFTreasury: Proposal expired");
        require(!proposal.hasApproved[msg.sender], "WRFTreasury: Already approved");

        // Verify signature
        bytes32 hash = keccak256(abi.encodePacked(proposalId, msg.sender, multiSigConfig.nonce));
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        address recovered = ethSignedHash.recover(signature);
        require(recovered == msg.sender, "WRFTreasury: Invalid signature");

        proposal.hasApproved[msg.sender] = true;
        proposal.approvalCount++;

        // Execute if enough approvals
        if (proposal.approvalCount >= proposal.requiredApprovals) {
            _executeProposal(proposalId);
        }
    }

    /**
     * @dev Execute an approved spending proposal
     */
    function executeProposal(uint256 proposalId) external onlySpendingManager validProposal(proposalId) whenNotPaused {
        SpendingProposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Approved, "WRFTreasury: Proposal not approved");
        require(proposal.approvalCount >= proposal.requiredApprovals, "WRFTreasury: Insufficient approvals");
        require(block.timestamp <= proposal.executionDeadline, "WRFTreasury: Proposal expired");

        _executeProposal(proposalId);
    }

    /**
     * @dev Internal function to execute a proposal
     */
    function _executeProposal(uint256 proposalId) internal nonReentrant {
        SpendingProposal storage proposal = proposals[proposalId];
        
        // Update budget if applicable
        if (proposal.budgetCategory != bytes32(0)) {
            BudgetAllocation storage budget = budgets[proposal.budgetCategory];
            budget.spent += proposal.amount;
            budget.remaining -= proposal.amount;
        }

        // Execute the transfer
        bool success = _transfer(proposal.token, proposal.recipient, proposal.amount);
        
        if (success) {
            proposal.state = ProposalState.Executed;
            
            // Record operation
            _recordOperation(
                OperationType.Transfer,
                msg.sender,
                proposal.recipient,
                proposal.token,
                proposal.amount,
                proposal.description
            );
            
            emit ProposalExecuted(proposalId, msg.sender, true);
        } else {
            emit ProposalExecuted(proposalId, msg.sender, false);
        }

        multiSigConfig.nonce++;
    }

    // ============ BUDGET MANAGEMENT FUNCTIONS ============

    /**
     * @dev Allocate budget for a specific category
     */
    function allocateBudget(
        bytes32 category,
        uint256 amount,
        uint256 period
    ) external onlyBudgetManager whenNotPaused {
        require(amount > 0, "WRFTreasury: Amount must be > 0");
        require(period > 0, "WRFTreasury: Period must be > 0");

        BudgetAllocation storage budget = budgets[category];
        budget.category = category;
        budget.totalAllocated = amount;
        budget.spent = 0;
        budget.remaining = amount;
        budget.period = period;
        budget.lastReset = block.timestamp;
        budget.active = true;

        emit BudgetAllocated(category, amount, period);
    }

    /**
     * @dev Reset budget allocation for a category
     */
    function resetBudget(bytes32 category) external onlyBudgetManager {
        BudgetAllocation storage budget = budgets[category];
        require(budget.active, "WRFTreasury: Budget not active");
        require(block.timestamp >= budget.lastReset + budget.period, "WRFTreasury: Period not elapsed");

        budget.spent = 0;
        budget.remaining = budget.totalAllocated;
        budget.lastReset = block.timestamp;

        emit BudgetReset(string(abi.encodePacked(category)), budget.remaining, block.timestamp);
    }

    /**
     * @dev Deactivate a budget category
     */
    function deactivateBudget(bytes32 category) external onlyBudgetManager {
        budgets[category].active = false;

        emit BudgetDeactivated(string(abi.encodePacked(category)), block.timestamp);
    }

    // ============ MULTI-SIGNATURE FUNCTIONS ============

    /**
     * @dev Update multi-signature configuration
     */
    function updateMultiSigConfig(
        address[] calldata newSigners,
        uint256 newRequiredSignatures
    ) external onlyTreasuryAdmin {
        require(newSigners.length >= newRequiredSignatures, "WRFTreasury: Invalid signer configuration");
        require(newRequiredSignatures > 0, "WRFTreasury: Required signatures must be > 0");

        // Revoke multisig role from old signers
        for (uint256 i = 0; i < multiSigConfig.signers.length; i++) {
            _revokeRole(MULTISIG_ROLE, multiSigConfig.signers[i]);
        }

        // Grant multisig role to new signers
        for (uint256 i = 0; i < newSigners.length; i++) {
            _grantRole(MULTISIG_ROLE, newSigners[i]);
        }

        multiSigConfig.signers = newSigners;
        multiSigConfig.requiredSignatures = newRequiredSignatures;
        multiSigConfig.nonce++;

        emit MultiSigConfigUpdated(newSigners, newRequiredSignatures);
    }

    /**
     * @dev Execute multi-signature transaction
     */
    function executeMultiSigTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        bytes[] calldata signatures
    ) external onlyMultiSig whenNotPaused nonReentrant {
        require(signatures.length >= multiSigConfig.requiredSignatures, "WRFTreasury: Insufficient signatures");
        require(target != address(0), "WRFTreasury: Invalid target");

        bytes32 txHash = keccak256(abi.encodePacked(target, value, data, multiSigConfig.nonce));
        require(!executedTransactions[txHash], "WRFTreasury: Transaction already executed");

        // Verify signatures
        address[] memory signers = new address[](signatures.length);
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes32 ethSignedHash = txHash.toEthSignedMessageHash();
            address recovered = ethSignedHash.recover(signatures[i]);
            require(hasRole(MULTISIG_ROLE, recovered), "WRFTreasury: Invalid signer");
            
            // Check for duplicate signers
            for (uint256 j = 0; j < i; j++) {
                require(signers[j] != recovered, "WRFTreasury: Duplicate signer");
            }
            signers[i] = recovered;
        }

        executedTransactions[txHash] = true;
        multiSigConfig.nonce++;

        // Execute transaction
        (bool success, ) = target.call{value: value}(data);
        require(success, "WRFTreasury: Transaction failed");

        _recordOperation(
            OperationType.Transfer,
            msg.sender,
            target,
            address(0),
            value,
            "Multi-sig transaction"
        );
    }

    // ============ EMERGENCY FUNCTIONS ============

    /**
     * @dev Emergency pause all operations
     */
    function emergencyPause() external onlyEmergencyRole {
        _pause();
    }

    /**
     * @dev Unpause operations
     */
    function unpause() external onlyTreasuryAdmin {
        _unpause();
    }

    /**
     * @dev Emergency withdraw funds
     */
    function emergencyWithdraw(
        address token,
        address recipient,
        uint256 amount
    ) external onlyEmergencyRole nonReentrant {
        require(recipient != address(0), "WRFTreasury: Invalid recipient");
        require(amount > 0, "WRFTreasury: Amount must be > 0");
        require(
            block.timestamp >= lastEmergencyWithdraw[token] + 1 days,
            "WRFTreasury: Emergency withdraw cooldown"
        );

        if (emergencyWithdrawLimit > 0) {
            require(amount <= emergencyWithdrawLimit, "WRFTreasury: Exceeds emergency limit");
        }

        lastEmergencyWithdraw[token] = block.timestamp;
        
        bool success = _transfer(token, recipient, amount);
        require(success, "WRFTreasury: Emergency withdraw failed");

        _recordOperation(
            OperationType.EmergencyWithdraw,
            msg.sender,
            recipient,
            token,
            amount,
            "Emergency withdrawal"
        );

        emit EmergencyWithdrawExecuted(token, recipient, amount);
    }

    // ============ CROSS-CHAIN FUNCTIONS ============

    /**
     * @dev Authorize a cross-chain bridge
     */
    function authorizeBridge(address bridge, uint256 chainId) external onlyTreasuryAdmin {
        require(bridge != address(0), "WRFTreasury: Invalid bridge address");
        authorizedBridges[bridge] = true;
        crossChainBridges[chainId] = bridge;

        emit BridgeAuthorized(bridge, chainId);
    }

    /**
     * @dev Initiate cross-chain transfer
     */
    function initiateCrossChainTransfer(
        uint256 chainId,
        address token,
        uint256 amount,
        address recipient
    ) external onlySpendingManager whenNotPaused {
        address bridge = crossChainBridges[chainId];
        require(bridge != address(0), "WRFTreasury: No bridge for chain");
        require(authorizedBridges[bridge], "WRFTreasury: Bridge not authorized");

        bool success = _transfer(token, bridge, amount);
        require(success, "WRFTreasury: Cross-chain transfer failed");

        _recordOperation(
            OperationType.CrossChainTransfer,
            msg.sender,
            bridge,
            token,
            amount,
            "Cross-chain transfer"
        );

        emit CrossChainTransferInitiated(chainId, token, amount, recipient);
    }

    // ============ DEFI INTEGRATION FUNCTIONS ============

    /**
     * @dev Authorize a DeFi protocol
     */
    function authorizeProtocol(address protocol) external onlyTreasuryAdmin {
        require(protocol != address(0), "WRFTreasury: Invalid protocol address");
        authorizedProtocols[protocol] = true;

        emit ProtocolAuthorized(protocol);
    }

    /**
     * @dev Deposit funds into DeFi protocol
     */
    function depositToProtocol(
        address protocol,
        address token,
        uint256 amount
    ) external onlySpendingManager whenNotPaused {
        require(authorizedProtocols[protocol], "WRFTreasury: Protocol not authorized");
        require(amount > 0, "WRFTreasury: Amount must be > 0");

        bool success = _transfer(token, protocol, amount);
        require(success, "WRFTreasury: DeFi deposit failed");

        protocolAllocations[protocol] += amount;

        _recordOperation(
            OperationType.DeFiDeposit,
            msg.sender,
            protocol,
            token,
            amount,
            "DeFi deposit"
        );

        emit DeFiOperationExecuted(protocol, token, amount, "deposit");
    }

    /**
     * @dev Withdraw funds from DeFi protocol
     */
    function withdrawFromProtocol(
        address protocol,
        address token,
        uint256 amount
    ) external onlySpendingManager whenNotPaused {
        require(authorizedProtocols[protocol], "WRFTreasury: Protocol not authorized");
        require(amount > 0, "WRFTreasury: Amount must be > 0");
        require(protocolAllocations[protocol] >= amount, "WRFTreasury: Insufficient protocol balance");

        // This would typically call a withdrawal function on the protocol
        // For now, we'll just update the allocation
        protocolAllocations[protocol] -= amount;

        _recordOperation(
            OperationType.DeFiWithdraw,
            msg.sender,
            protocol,
            token,
            amount,
            "DeFi withdrawal"
        );

        emit DeFiOperationExecuted(protocol, token, amount, "withdraw");
    }

    // ============ UTILITY FUNCTIONS ============

    /**
     * @dev Internal transfer function
     */
    function _transfer(address token, address recipient, uint256 amount) internal returns (bool) {
        if (token == address(0)) {
            // ETH transfer
            require(address(this).balance >= amount, "WRFTreasury: Insufficient ETH balance");
            (bool success, ) = recipient.call{value: amount}("");
            return success;
        } else {
            // ERC20 transfer
            IERC20 tokenContract = IERC20(token);
            uint256 balance = tokenContract.balanceOf(address(this));
            require(balance >= amount, "WRFTreasury: Insufficient token balance");
            
            try tokenContract.transfer(recipient, amount) returns (bool success) {
                return success;
            } catch {
                return false;
            }
        }
    }

    /**
     * @dev Get token balance
     */
    function _getTokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    /**
     * @dev Record treasury operation
     */
    function _recordOperation(
        OperationType operationType,
        address initiator,
        address target,
        address token,
        uint256 amount,
        string memory description
    ) internal {
        operationCount++;
        operations[operationCount] = TreasuryOperation({
            id: operationCount,
            operationType: operationType,
            initiator: initiator,
            target: target,
            token: token,
            amount: amount,
            description: description,
            timestamp: block.timestamp,
            transactionHash: keccak256(abi.encodePacked(block.timestamp, operationCount)),
            executed: true
        });

        emit TreasuryOperationExecuted(operationCount, operationType, target, amount);
    }

    /**
     * @dev Calculate required votes for proposal approval
     */
    function _calculateRequiredVotes() internal view returns (uint256) {
        // Simple implementation - can be enhanced with more sophisticated voting logic
        return multiSigConfig.requiredSignatures;
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        address proposer,
        address recipient,
        address token,
        uint256 amount,
        string memory description,
        string memory category,
        uint256 createdAt,
        uint256 executionDeadline,
        ProposalState state,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 requiredVotes,
        uint256 approvalCount,
        uint256 requiredApprovals
    ) {
        SpendingProposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.recipient,
            proposal.token,
            proposal.amount,
            proposal.description,
            proposal.category,
            proposal.createdAt,
            proposal.executionDeadline,
            proposal.state,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.requiredVotes,
            proposal.approvalCount,
            proposal.requiredApprovals
        );
    }

    /**
     * @dev Get budget allocation details
     */
    function getBudgetAllocation(bytes32 category) external view returns (
        uint256 totalAllocated,
        uint256 spent,
        uint256 remaining,
        uint256 period,
        uint256 lastReset,
        bool active
    ) {
        BudgetAllocation storage budget = budgets[category];
        return (
            budget.totalAllocated,
            budget.spent,
            budget.remaining,
            budget.period,
            budget.lastReset,
            budget.active
        );
    }

    /**
     * @dev Get multi-signature configuration
     */
    function getMultiSigConfig() external view returns (
        address[] memory signers,
        uint256 requiredSignatures,
        uint256 nonce,
        bool active
    ) {
        return (
            multiSigConfig.signers,
            multiSigConfig.requiredSignatures,
            multiSigConfig.nonce,
            multiSigConfig.active
        );
    }

    /**
     * @dev Get treasury operation details
     */
    function getOperation(uint256 operationId) external view returns (
        uint256 id,
        OperationType operationType,
        address initiator,
        address target,
        address token,
        uint256 amount,
        string memory description,
        uint256 timestamp,
        bytes32 transactionHash,
        bool executed
    ) {
        TreasuryOperation storage operation = operations[operationId];
        return (
            operation.id,
            operation.operationType,
            operation.initiator,
            operation.target,
            operation.token,
            operation.amount,
            operation.description,
            operation.timestamp,
            operation.transactionHash,
            operation.executed
        );
    }

    /**
     * @dev Get treasury balance for a token
     */
    function getTreasuryBalance(address token) external view returns (uint256) {
        return _getTokenBalance(token);
    }

    /**
     * @dev Check if user has voted on a proposal
     */
    function hasVoted(uint256 proposalId, address user) external view returns (bool) {
        return proposals[proposalId].hasVoted[user];
    }

    /**
     * @dev Check if user has approved a proposal
     */
    function hasApproved(uint256 proposalId, address user) external view returns (bool) {
        return proposals[proposalId].hasApproved[user];
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Set emergency withdraw limit
     */
    function setEmergencyWithdrawLimit(uint256 limit) external onlyTreasuryAdmin {
        uint256 oldLimit = emergencyWithdrawLimit;
        emergencyWithdrawLimit = limit;

        emit EmergencyWithdrawLimitUpdated(oldLimit, limit);
    }

    /**
     * @dev Set proposal duration limits
     */
    function setProposalDurationLimits(uint256 minDuration, uint256 maxDuration) external onlyTreasuryAdmin {
        require(minDuration < maxDuration, "WRFTreasury: Invalid duration limits");
        minProposalDuration = minDuration;
        maxProposalDuration = maxDuration;

        emit ProposalDurationLimitsUpdated(minDuration, maxDuration);
    }

    /**
     * @dev Cancel a proposal
     */
    function cancelProposal(uint256 proposalId) external onlyTreasuryAdmin validProposal(proposalId) {
        SpendingProposal storage proposal = proposals[proposalId];
        require(
            proposal.state == ProposalState.Pending || proposal.state == ProposalState.Approved, 
            "WRFTreasury: Cannot cancel executed proposal"
        );
        
        proposal.state = ProposalState.Cancelled;

        emit ProposalCancelled(proposalId);
    }

    // ============ RECEIVE FUNCTIONS ============

    /**
     * @dev Receive ETH deposits
     */
    receive() external payable {
        // Allow ETH deposits to treasury
    }

    /**
     * @dev Fallback function
     */
    fallback() external payable {
        revert("WRFTreasury: Function not found");
    }
}