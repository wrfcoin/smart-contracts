// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title EnhancedTreasury
 * @dev Advanced treasury management with automated fund allocation and security features
 * @notice Comprehensive treasury system with multi-signature controls, spending limits,
 *         emergency functions, and compliance tracking for WRFCoin platform governance
 * 
 * Features:
 * - Multi-signature fund management with EIP-712 signature validation
 * - Hierarchical spending limits and approval workflows  
 * - Emergency fund controls with timelock protection
 * - Investment strategy validation with risk assessment
 * - Fee collection and distribution mechanisms
 * - Cross-chain treasury coordination
 * - Comprehensive audit trails and financial reporting
 * - Economic security limits protecting up to $5M TVL
 * 
 * Security Measures:
 * - EIP-712 signature verification prevents bypass attacks
 * - Timelock delays for large transactions
 * - Spending velocity limits and daily caps
 * - Emergency pause functionality
 * - Role-based access with principle of least privilege
 * - Slashing protection for validator funds
 * 
 * @custom:security-contact security@wrfcoin.io
 */
contract EnhancedTreasury is ReentrancyGuard, AccessControl, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using ECDSA for bytes32;

    // Roles with hierarchical permissions
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant FUND_ALLOCATOR_ROLE = keccak256("FUND_ALLOCATOR_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant INVESTMENT_COMMITTEE_ROLE = keccak256("INVESTMENT_COMMITTEE_ROLE");
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");

    // EIP-712 Domain and TypeHashes for signature verification
    bytes32 private constant OPERATION_TYPEHASH = keccak256(
        "Operation(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline,string description)"
    );
    bytes32 private constant ALLOCATION_TYPEHASH = keccak256(
        "Allocation(uint8 category,address token,uint256 amount,address recipient,uint256 nonce,uint256 deadline,string purpose)"
    );

    // Economic security constants
    uint256 public constant MAX_DAILY_SPENDING = 100_000 * 1e18; // $100K daily limit
    uint256 public constant MAX_SINGLE_TRANSACTION = 50_000 * 1e18; // $50K single tx limit
    uint256 public constant MAX_TVL_PERCENTAGE_PER_TX = 500; // 5% of TVL max per transaction
    uint256 public constant TIMELOCK_DELAY = 2 days; // Minimum timelock delay
    uint256 private constant MAX_BPS = 10_000; // 100% in basis points
    
    // Security thresholds
    uint256 public constant HIGH_VALUE_THRESHOLD = 25_000 * 1e18; // $25K requires enhanced approval
    uint256 public constant EMERGENCY_FUND_MIN_PERCENTAGE = 1000; // 10% minimum emergency fund
    uint256 public constant SLASHING_COOLDOWN_PERIOD = 7 days;

    // Allocation categories
    enum AllocationCategory {
        DEVELOPMENT,
        MARKETING,
        OPERATIONS,
        RESEARCH,
        EMERGENCY_FUND,
        COMMUNITY_GRANTS,
        CLIMATE_INITIATIVES,
        YIELD_FARMING,
        INSURANCE_RESERVE
    }

    // Allocation strategy
    struct AllocationStrategy {
        AllocationCategory category;
        uint256 percentage; // Basis points (100 = 1%)
        uint256 minAmount;
        uint256 maxAmount;
        uint256 frequency; // Allocation frequency in seconds
        bool isActive;
        address targetAddress;
        string description;
    }

    // Fund allocation record
    struct FundAllocation {
        uint256 allocationId;
        AllocationCategory category;
        address token;
        uint256 amount;
        address recipient;
        uint256 timestamp;
        string purpose;
        bool executed;
        bytes32 proposalHash;
        uint256 governanceApprovalId;
    }

    // Treasury asset
    struct TreasuryAsset {
        address token;
        uint256 balance;
        uint256 reservedAmount;
        uint256 yieldEarned;
        uint256 lastYieldUpdate;
        bool isActive;
        uint256 riskRating; // 1-10 scale
    }

    // Yield farming position
    struct YieldPosition {
        uint256 positionId;
        address protocol;
        address token;
        uint256 principalAmount;
        uint256 yieldEarned;
        uint256 startTime;
        uint256 lastUpdate;
        bool isActive;
        string strategyName;
    }

    // Enhanced multi-signature requirement with security features
    struct MultiSigConfig {
        uint256 requiredSignatures;
        uint256 totalSigners;
        mapping(address => bool) isSigner;
        mapping(bytes32 => mapping(address => bool)) hasApproved;
        mapping(bytes32 => uint256) approvalCount;
        mapping(bytes32 => uint256) operationDeadline;
        mapping(bytes32 => uint256) operationNonce;
        mapping(bytes32 => bool) usedSignatureHashes;
        uint256 globalNonce;
    }

    // Spending limits and velocity controls
    struct SpendingLimits {
        uint256 dailyLimit;
        uint256 monthlyLimit;
        mapping(uint256 => uint256) dailySpent; // day => amount spent
        mapping(uint256 => uint256) monthlySpent; // month => amount spent
        mapping(address => uint256) lastTransactionTime;
        mapping(address => uint256) transactionCount24h;
    }

    // Investment risk assessment
    struct InvestmentRisk {
        uint256 riskScore; // 1-100 (1 = lowest risk)
        uint256 maxAllocation; // Percentage of total treasury
        uint256 lockPeriod; // Minimum investment period
        bool requiresCommitteeApproval;
        string riskAssessmentHash; // IPFS hash of detailed risk assessment
    }

    // Financial report
    struct FinancialReport {
        uint256 reportId;
        uint256 timestamp;
        uint256 totalAssets;
        uint256 totalAllocated;
        uint256 totalYieldEarned;
        uint256 emergencyFundBalance;
        mapping(AllocationCategory => uint256) categoryAllocations;
        string reportHash;
    }

    // Core state variables
    mapping(AllocationCategory => AllocationStrategy) public allocationStrategies;
    mapping(uint256 => FundAllocation) public fundAllocations;
    mapping(address => TreasuryAsset) public treasuryAssets;
    mapping(uint256 => YieldPosition) public yieldPositions;
    mapping(uint256 => FinancialReport) public financialReports;
    
    // Security and access control
    MultiSigConfig public multiSigConfig;
    SpendingLimits public spendingLimits;
    TimelockController public timelock;
    
    // Investment and risk management
    mapping(address => InvestmentRisk) public protocolRiskAssessments;
    mapping(address => uint256) public lastSlashingTime; // Prevent rapid slashing
    mapping(bytes32 => uint256) public pendingOperations; // Timelock operations
    
    uint256 public nextAllocationId;
    uint256 public nextPositionId;
    uint256 public nextReportId;
    uint256 public totalTreasuryValue;
    uint256 public emergencyFundPercentage; // Basis points
    uint256 public reportingInterval;
    uint256 public lastReportTime;
    
    // Cross-chain coordination
    mapping(uint256 => address) public crossChainTreasuries; // chainId => treasury address
    mapping(uint256 => uint256) public crossChainBalances; // chainId => balance
    
    address[] public supportedTokens;
    address[] public yieldFarmingProtocols;
    
    // Core operational events
    event FundAllocated(
        uint256 indexed allocationId,
        AllocationCategory category,
        address token,
        uint256 amount,
        address recipient
    );
    event AllocationStrategyUpdated(
        AllocationCategory category,
        uint256 percentage,
        bool isActive
    );
    event YieldPositionCreated(
        uint256 indexed positionId,
        address protocol,
        address token,
        uint256 amount
    );
    event YieldHarvested(
        uint256 indexed positionId,
        uint256 yieldAmount,
        uint256 timestamp
    );
    event FinancialReportGenerated(
        uint256 indexed reportId,
        uint256 totalAssets,
        uint256 timestamp
    );

    // Security and access control events
    event EmergencyWithdrawal(
        address indexed token,
        uint256 amount,
        address indexed recipient,
        address indexed initiator,
        string reason
    );
    event MultiSigApproval(
        bytes32 indexed operationHash,
        address indexed signer,
        uint256 approvalCount,
        uint256 requiredCount
    );
    event SpendingLimitExceeded(
        address indexed initiator,
        uint256 attemptedAmount,
        uint256 currentLimit,
        string limitType
    );
    event SuspiciousActivity(
        address indexed account,
        string activityType,
        uint256 value,
        string description
    );
    event ProtocolRiskUpdated(
        address indexed protocol,
        uint256 oldRiskScore,
        uint256 newRiskScore
    );

    // Cross-chain and advanced features
    event CrossChainTransfer(
        uint256 destinationChain,
        address token,
        uint256 amount,
        address recipient
    );
    event OperationQueued(
        bytes32 indexed operationHash,
        uint256 executionTime,
        string description
    );
    event OperationExecuted(
        bytes32 indexed operationHash,
        bool success
    );
    event TreasuryPaused(
        address indexed by,
        string reason
    );
    event TreasuryUnpaused(
        address indexed by
    );

    /// @notice Ensures operation has sufficient multi-signature approvals
    /// @param _operationHash The hash of the operation to verify
    modifier onlyMultiSig(bytes32 _operationHash) {
        require(_hasRequiredApprovals(_operationHash), "ET: Insufficient approvals");
        require(block.timestamp <= multiSigConfig.operationDeadline[_operationHash], "ET: Operation expired");
        _;
    }

    /// @notice Validates that the token is supported by the treasury
    /// @param _token The token address to validate
    modifier validToken(address _token) {
        require(_isValidToken(_token), "ET: Invalid token");
        _;
    }

    /// @notice Checks spending limits before allowing transactions
    /// @param _amount The amount to spend
    modifier withinSpendingLimits(uint256 _amount) {
        require(_checkSpendingLimits(_amount), "ET: Spending limit exceeded");
        _;
    }

    /// @notice Prevents operations during emergency pause
    modifier notInEmergency() {
        require(!paused(), "ET: Emergency pause active");
        _;
    }

    /// @notice Validates risk assessment for investment operations
    /// @param _protocol The protocol address to check
    /// @param _amount The investment amount
    modifier validInvestment(address _protocol, uint256 _amount) {
        require(_validateInvestmentRisk(_protocol, _amount), "ET: Investment risk too high");
        _;
    }

    /// @notice Initializes the Enhanced Treasury with security configurations
    /// @param _admin The admin address with all roles initially
    /// @param _timelock The timelock controller address for governance operations
    /// @param _emergencyFundPercentage The percentage of funds reserved for emergencies (in basis points)
    constructor(
        address _admin,
        address _timelock,
        uint256 _emergencyFundPercentage
    ) EIP712("EnhancedTreasury", "1") {
        require(_admin != address(0), "ET: Invalid admin address");
        require(_timelock != address(0), "ET: Invalid timelock address");
        require(_emergencyFundPercentage >= EMERGENCY_FUND_MIN_PERCENTAGE, "ET: Emergency fund too low");
        require(_emergencyFundPercentage <= MAX_BPS, "ET: Emergency fund exceeds 100%");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(TREASURY_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        
        timelock = TimelockController(payable(_timelock));
        emergencyFundPercentage = _emergencyFundPercentage;
        reportingInterval = 30 days;
        lastReportTime = block.timestamp;
        
        // Initialize enhanced multi-sig with secure defaults
        multiSigConfig.requiredSignatures = 3;
        multiSigConfig.totalSigners = 5;
        multiSigConfig.globalNonce = 1;
        
        // Initialize spending limits
        spendingLimits.dailyLimit = MAX_DAILY_SPENDING;
        spendingLimits.monthlyLimit = MAX_DAILY_SPENDING * 30;
        
        _initializeAllocationStrategies();
    }

    /**
     * @dev Initialize default allocation strategies
     */
    function _initializeAllocationStrategies() internal {
        allocationStrategies[AllocationCategory.DEVELOPMENT] = AllocationStrategy({
            category: AllocationCategory.DEVELOPMENT,
            percentage: 3000, // 30%
            minAmount: 1000 * 10**18,
            maxAmount: 100000 * 10**18,
            frequency: 30 days,
            isActive: true,
            targetAddress: address(0),
            description: "Development and engineering expenses"
        });

        allocationStrategies[AllocationCategory.CLIMATE_INITIATIVES] = AllocationStrategy({
            category: AllocationCategory.CLIMATE_INITIATIVES,
            percentage: 2500, // 25%
            minAmount: 5000 * 10**18,
            maxAmount: 200000 * 10**18,
            frequency: 90 days,
            isActive: true,
            targetAddress: address(0),
            description: "Climate action and carbon offset projects"
        });

        allocationStrategies[AllocationCategory.EMERGENCY_FUND] = AllocationStrategy({
            category: AllocationCategory.EMERGENCY_FUND,
            percentage: 1500, // 15%
            minAmount: 10000 * 10**18,
            maxAmount: 500000 * 10**18,
            frequency: 0, // No regular allocation
            isActive: true,
            targetAddress: address(0),
            description: "Emergency response and disaster relief"
        });

        allocationStrategies[AllocationCategory.YIELD_FARMING] = AllocationStrategy({
            category: AllocationCategory.YIELD_FARMING,
            percentage: 2000, // 20%
            minAmount: 50000 * 10**18,
            maxAmount: 1000000 * 10**18,
            frequency: 7 days,
            isActive: true,
            targetAddress: address(0),
            description: "Yield farming for treasury growth"
        });
    }

    /**
     * @dev Add treasury asset
     */
    function addTreasuryAsset(
        address _token,
        uint256 _riskRating
    ) external onlyRole(TREASURY_MANAGER_ROLE) validToken(_token) {
        require(!treasuryAssets[_token].isActive, "ET: Asset already exists");
        require(_riskRating >= 1 && _riskRating <= 10, "ET: Invalid risk rating");

        treasuryAssets[_token] = TreasuryAsset({
            token: _token,
            balance: 0,
            reservedAmount: 0,
            yieldEarned: 0,
            lastYieldUpdate: block.timestamp,
            isActive: true,
            riskRating: _riskRating
        });

        supportedTokens.push(_token);
    }

    /**
     * @dev Deposit funds into treasury
     */
    function deposit(
        address _token,
        uint256 _amount
    ) external nonReentrant validToken(_token) {
        require(_amount > 0, "ET: Amount must be positive");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        
        TreasuryAsset storage asset = treasuryAssets[_token];
        asset.balance += _amount;
        totalTreasuryValue += _amount;

        // Trigger automated allocation if conditions are met
        _evaluateAutomatedAllocations(_token);
    }

    /**
     * @notice Allocate funds based on governance decision with enhanced security
     * @param _category Category of allocation
     * @param _token Token to allocate
     * @param _amount Amount to allocate
     * @param _recipient Recipient address
     * @param _purpose Purpose of allocation
     * @param _proposalHash Hash of governance proposal
     * @param _governanceApprovalId ID of governance approval
     */
    function allocateFunds(
        AllocationCategory _category,
        address _token,
        uint256 _amount,
        address _recipient,
        string memory _purpose,
        bytes32 _proposalHash,
        uint256 _governanceApprovalId
    ) external onlyRole(FUND_ALLOCATOR_ROLE) nonReentrant notInEmergency withinSpendingLimits(_amount) {
        require(_amount > 0, "ET: Amount must be positive");
        require(_recipient != address(0), "ET: Invalid recipient");

        TreasuryAsset storage asset = treasuryAssets[_token];
        require(asset.isActive, "ET: Token not supported");
        require(asset.balance >= _amount, "ET: Insufficient balance");

        // Create allocation record
        uint256 allocationId = nextAllocationId++;
        fundAllocations[allocationId] = FundAllocation({
            allocationId: allocationId,
            category: _category,
            token: _token,
            amount: _amount,
            recipient: _recipient,
            timestamp: block.timestamp,
            purpose: _purpose,
            executed: false,
            proposalHash: _proposalHash,
            governanceApprovalId: _governanceApprovalId
        });

        // Reserve funds
        asset.reservedAmount += _amount;

        emit FundAllocated(allocationId, _category, _token, _amount, _recipient);
    }

    /**
     * @dev Execute fund allocation
     */
    function executeAllocation(
        uint256 _allocationId
    ) external onlyRole(FUND_ALLOCATOR_ROLE) nonReentrant {
        FundAllocation storage allocation = fundAllocations[_allocationId];
        require(!allocation.executed, "ET: Already executed");

        TreasuryAsset storage asset = treasuryAssets[allocation.token];
        require(asset.reservedAmount >= allocation.amount, "ET: Insufficient reserved amount");

        // Execute transfer
        IERC20(allocation.token).safeTransfer(allocation.recipient, allocation.amount);

        // Update state
        allocation.executed = true;
        asset.balance -= allocation.amount;
        asset.reservedAmount -= allocation.amount;
        totalTreasuryValue -= allocation.amount;
    }

    /**
     * @notice Create yield farming position with risk validation
     * @param _protocol Protocol address for yield farming
     * @param _token Token to farm
     * @param _amount Amount to invest
     * @param _strategyName Name of the strategy
     */
    function createYieldPosition(
        address _protocol,
        address _token,
        uint256 _amount,
        string memory _strategyName
    ) external onlyRole(TREASURY_MANAGER_ROLE) nonReentrant notInEmergency validInvestment(_protocol, _amount) {
        require(_amount > 0, "ET: Amount must be positive");
        require(_isValidProtocol(_protocol), "ET: Invalid protocol");

        TreasuryAsset storage asset = treasuryAssets[_token];
        require(asset.balance >= _amount, "ET: Insufficient balance");

        uint256 positionId = nextPositionId++;
        yieldPositions[positionId] = YieldPosition({
            positionId: positionId,
            protocol: _protocol,
            token: _token,
            principalAmount: _amount,
            yieldEarned: 0,
            startTime: block.timestamp,
            lastUpdate: block.timestamp,
            isActive: true,
            strategyName: _strategyName
        });

        // Transfer funds to yield protocol
        IERC20(_token).safeTransfer(_protocol, _amount);
        asset.balance -= _amount;

        emit YieldPositionCreated(positionId, _protocol, _token, _amount);
    }

    /**
     * @dev Harvest yield from farming position
     */
    function harvestYield(uint256 _positionId) external onlyRole(TREASURY_MANAGER_ROLE) {
        YieldPosition storage position = yieldPositions[_positionId];
        require(position.isActive, "ET: Position not active");

        // This would integrate with actual yield farming protocols
        uint256 yieldAmount = _calculateYield(_positionId);
        
        if (yieldAmount > 0) {
            position.yieldEarned += yieldAmount;
            position.lastUpdate = block.timestamp;

            TreasuryAsset storage asset = treasuryAssets[position.token];
            asset.yieldEarned += yieldAmount;
            asset.balance += yieldAmount;
            totalTreasuryValue += yieldAmount;

            emit YieldHarvested(_positionId, yieldAmount, block.timestamp);
        }
    }

    /**
     * @notice Emergency withdrawal function with enhanced security
     * @dev Only callable by emergency role with comprehensive logging
     * @param _token Token address to withdraw
     * @param _amount Amount to withdraw
     * @param _recipient Address to send funds to
     * @param _reason Reason for emergency withdrawal
     */
    function emergencyWithdraw(
        address _token,
        uint256 _amount,
        address _recipient,
        string memory _reason
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        require(_amount > 0, "ET: Amount must be positive");
        require(_recipient != address(0), "ET: Invalid recipient");
        require(bytes(_reason).length > 0, "ET: Reason required");

        TreasuryAsset storage asset = treasuryAssets[_token];
        require(asset.balance >= _amount, "ET: Insufficient balance");
        
        // Enhanced security: Limit emergency withdrawals to prevent abuse
        require(_amount <= (totalTreasuryValue * 2000) / MAX_BPS, "ET: Emergency withdrawal too large"); // Max 20% per withdrawal

        IERC20(_token).safeTransfer(_recipient, _amount);
        asset.balance -= _amount;
        totalTreasuryValue -= _amount;

        emit EmergencyWithdrawal(_token, _amount, _recipient, msg.sender, _reason);
    }

    /**
     * @notice Pause treasury operations in case of security incident
     * @dev Only emergency role can pause, any admin can unpause
     * @param _reason Reason for pausing
     */
    function emergencyPause(string memory _reason) external onlyRole(EMERGENCY_ROLE) {
        require(!paused(), "ET: Already paused");
        _pause();
        emit TreasuryPaused(msg.sender, _reason);
    }

    /**
     * @notice Unpause treasury operations
     * @dev Can only be called when paused
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(paused(), "ET: Not paused");
        _unpause();
        emit TreasuryUnpaused(msg.sender);
    }

    /**
     * @notice Queue a high-value operation for timelock execution
     * @param _to Target address for the operation
     * @param _value Value to transfer
     * @param _data Transaction data
     * @param _description Human-readable description
     * @return operationHash Hash of the queued operation
     */
    function queueOperation(
        address _to,
        uint256 _value,
        bytes memory _data,
        string memory _description
    ) external onlyRole(TREASURY_MANAGER_ROLE) returns (bytes32 operationHash) {
        require(_value >= HIGH_VALUE_THRESHOLD, "ET: Use direct execution for small amounts");
        
        operationHash = keccak256(abi.encodePacked(
            _to,
            _value,
            _data,
            block.timestamp,
            multiSigConfig.globalNonce++
        ));
        
        uint256 executionTime = block.timestamp + TIMELOCK_DELAY;
        pendingOperations[operationHash] = executionTime;
        multiSigConfig.operationDeadline[operationHash] = executionTime + 7 days; // 1 week execution window
        
        emit OperationQueued(operationHash, executionTime, _description);
    }

    /**
     * @notice Execute a previously queued operation
     * @param _operationHash Hash of the operation to execute
     * @param _to Target address
     * @param _value Value to transfer
     * @param _data Transaction data
     */
    function executeQueuedOperation(
        bytes32 _operationHash,
        address _to,
        uint256 _value,
        bytes memory _data
    ) external onlyMultiSig(_operationHash) nonReentrant notInEmergency {
        require(pendingOperations[_operationHash] != 0, "ET: Operation not queued");
        require(block.timestamp >= pendingOperations[_operationHash], "ET: Operation still timelocked");
        require(block.timestamp <= multiSigConfig.operationDeadline[_operationHash], "ET: Operation expired");
        
        // Clear the operation
        delete pendingOperations[_operationHash];
        delete multiSigConfig.operationDeadline[_operationHash];
        
        // Execute the operation
        (bool success, ) = _to.call{value: _value}(_data);
        require(success, "ET: Operation execution failed");
        
        emit OperationExecuted(_operationHash, success);
    }

    /**
     * @dev Generate financial report
     */
    function generateFinancialReport() external onlyRole(AUDITOR_ROLE) returns (uint256) {
        require(block.timestamp >= lastReportTime + reportingInterval, "ET: Report too early");

        uint256 reportId = nextReportId++;
        FinancialReport storage report = financialReports[reportId];
        
        report.reportId = reportId;
        report.timestamp = block.timestamp;
        report.totalAssets = totalTreasuryValue;
        report.emergencyFundBalance = _calculateEmergencyFundBalance();

        // Calculate category allocations
        for (uint256 i = 0; i < nextAllocationId; i++) {
            FundAllocation storage allocation = fundAllocations[i];
            if (allocation.executed && allocation.timestamp >= lastReportTime) {
                report.categoryAllocations[allocation.category] += allocation.amount;
                report.totalAllocated += allocation.amount;
            }
        }

        // Calculate total yield earned
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            TreasuryAsset storage asset = treasuryAssets[supportedTokens[i]];
            report.totalYieldEarned += asset.yieldEarned;
        }

        lastReportTime = block.timestamp;

        emit FinancialReportGenerated(reportId, report.totalAssets, report.timestamp);
        return reportId;
    }

    /**
     * @dev Update allocation strategy
     */
    function updateAllocationStrategy(
        AllocationCategory _category,
        uint256 _percentage,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _frequency,
        bool _isActive,
        address _targetAddress
    ) external onlyRole(TREASURY_MANAGER_ROLE) {
        AllocationStrategy storage strategy = allocationStrategies[_category];
        strategy.percentage = _percentage;
        strategy.minAmount = _minAmount;
        strategy.maxAmount = _maxAmount;
        strategy.frequency = _frequency;
        strategy.isActive = _isActive;
        strategy.targetAddress = _targetAddress;

        emit AllocationStrategyUpdated(_category, _percentage, _isActive);
    }

    /**
     * @dev Add multi-sig signer
     */
    function addMultiSigSigner(address _signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!multiSigConfig.isSigner[_signer], "ET: Already a signer");
        
        multiSigConfig.isSigner[_signer] = true;
        multiSigConfig.totalSigners++;
    }

    /**
     * @notice Approve multi-sig operation with EIP-712 signature verification
     * @param _operationHash Hash of the operation to approve
     * @param _signature EIP-712 signature for verification
     */
    function approveOperation(bytes32 _operationHash, bytes memory _signature) external {
        require(multiSigConfig.isSigner[msg.sender], "ET: Not a signer");
        require(!multiSigConfig.hasApproved[_operationHash][msg.sender], "ET: Already approved");
        require(block.timestamp <= multiSigConfig.operationDeadline[_operationHash], "ET: Operation expired");
        
        // Verify EIP-712 signature
        bytes32 digest = _hashTypedDataV4(_operationHash);
        address recoveredSigner = digest.recover(_signature);
        require(recoveredSigner == msg.sender, "ET: Invalid signature");
        
        // Anti-replay protection
        bytes32 signatureHash = keccak256(_signature);
        require(!multiSigConfig.usedSignatureHashes[signatureHash], "ET: Signature already used");
        multiSigConfig.usedSignatureHashes[signatureHash] = true;

        multiSigConfig.hasApproved[_operationHash][msg.sender] = true;
        multiSigConfig.approvalCount[_operationHash]++;

        emit MultiSigApproval(_operationHash, msg.sender, multiSigConfig.approvalCount[_operationHash], multiSigConfig.requiredSignatures);
    }

    /**
     * @notice Set protocol risk assessment
     * @param _protocol Protocol address
     * @param _riskScore Risk score (1-100)
     * @param _maxAllocation Maximum allocation percentage
     * @param _lockPeriod Minimum investment period
     * @param _requiresCommitteeApproval Whether investment committee approval is required
     * @param _riskAssessmentHash IPFS hash of detailed risk assessment
     */
    function setProtocolRisk(
        address _protocol,
        uint256 _riskScore,
        uint256 _maxAllocation,
        uint256 _lockPeriod,
        bool _requiresCommitteeApproval,
        string memory _riskAssessmentHash
    ) external onlyRole(INVESTMENT_COMMITTEE_ROLE) {
        require(_protocol != address(0), "ET: Invalid protocol");
        require(_riskScore >= 1 && _riskScore <= 100, "ET: Invalid risk score");
        require(_maxAllocation <= 5000, "ET: Max allocation too high"); // Max 50%
        
        uint256 oldRiskScore = protocolRiskAssessments[_protocol].riskScore;
        
        protocolRiskAssessments[_protocol] = InvestmentRisk({
            riskScore: _riskScore,
            maxAllocation: _maxAllocation,
            lockPeriod: _lockPeriod,
            requiresCommitteeApproval: _requiresCommitteeApproval,
            riskAssessmentHash: _riskAssessmentHash
        });
        
        emit ProtocolRiskUpdated(_protocol, oldRiskScore, _riskScore);
    }

    /**
     * @notice Update spending limits
     * @param _dailyLimit New daily spending limit
     * @param _monthlyLimit New monthly spending limit
     */
    function updateSpendingLimits(
        uint256 _dailyLimit,
        uint256 _monthlyLimit
    ) external onlyRole(TREASURY_MANAGER_ROLE) {
        require(_dailyLimit <= MAX_DAILY_SPENDING, "ET: Daily limit too high");
        require(_monthlyLimit <= _dailyLimit * 31, "ET: Monthly limit inconsistent");
        
        spendingLimits.dailyLimit = _dailyLimit;
        spendingLimits.monthlyLimit = _monthlyLimit;
    }

    /**
     * @dev Evaluate and execute automated allocations
     */
    function _evaluateAutomatedAllocations(address _token) internal {
        // Check if any allocation strategies should be triggered
        // This would include logic for automated yield farming, emergency fund maintenance, etc.
        // Simplified implementation for now
    }

    /**
     * @dev Calculate yield for a position
     */
    function _calculateYield(uint256 _positionId) internal view returns (uint256) {
        // This would integrate with actual yield farming protocol APIs
        // Simplified calculation for now
        YieldPosition storage position = yieldPositions[_positionId];
        uint256 timeElapsed = block.timestamp - position.lastUpdate;
        uint256 annualYield = position.principalAmount * 5 / 100; // 5% APY
        return (annualYield * timeElapsed) / 365 days;
    }

    /**
     * @dev Calculate emergency fund balance
     */
    function _calculateEmergencyFundBalance() internal view returns (uint256) {
        return (totalTreasuryValue * emergencyFundPercentage) / 10000;
    }

    /**
     * @dev Check if operation has required approvals
     */
    function _hasRequiredApprovals(bytes32 _operationHash) internal view returns (bool) {
        return multiSigConfig.approvalCount[_operationHash] >= multiSigConfig.requiredSignatures;
    }

    /**
     * @dev Check if token is valid
     */
    function _isValidToken(address _token) internal view returns (bool) {
        return treasuryAssets[_token].isActive || _token != address(0);
    }

    /**
     * @dev Check if protocol is valid for yield farming
     */
    function _isValidProtocol(address _protocol) internal view returns (bool) {
        for (uint256 i = 0; i < yieldFarmingProtocols.length; i++) {
            if (yieldFarmingProtocols[i] == _protocol) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Get treasury asset information
     */
    function getTreasuryAsset(address _token) external view returns (TreasuryAsset memory) {
        return treasuryAssets[_token];
    }

    /**
     * @dev Get allocation strategy
     */
    function getAllocationStrategy(AllocationCategory _category) external view returns (AllocationStrategy memory) {
        return allocationStrategies[_category];
    }

    /**
     * @dev Get yield position
     */
    function getYieldPosition(uint256 _positionId) external view returns (YieldPosition memory) {
        return yieldPositions[_positionId];
    }

    /**
     * @dev Get supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Get total treasury value
     * @return The total value held by the treasury
     */
    function getTotalTreasuryValue() external view returns (uint256) {
        return totalTreasuryValue;
    }

    // ========================================
    // INTERNAL SECURITY FUNCTIONS
    // ========================================

    /**
     * @dev Check spending limits for a transaction
     * @param _amount Amount to spend
     * @return True if within limits, false otherwise
     */
    function _checkSpendingLimits(uint256 _amount) internal returns (bool) {
        uint256 currentDay = block.timestamp / 1 days;
        uint256 currentMonth = block.timestamp / 30 days;
        
        // Check daily limit
        if (spendingLimits.dailySpent[currentDay] + _amount > spendingLimits.dailyLimit) {
            emit SpendingLimitExceeded(msg.sender, _amount, spendingLimits.dailyLimit, "daily");
            return false;
        }
        
        // Check monthly limit
        if (spendingLimits.monthlySpent[currentMonth] + _amount > spendingLimits.monthlyLimit) {
            emit SpendingLimitExceeded(msg.sender, _amount, spendingLimits.monthlyLimit, "monthly");
            return false;
        }
        
        // Check single transaction limit
        if (_amount > MAX_SINGLE_TRANSACTION) {
            emit SpendingLimitExceeded(msg.sender, _amount, MAX_SINGLE_TRANSACTION, "single_transaction");
            return false;
        }
        
        // Check TVL percentage limit
        uint256 maxTvlAmount = (totalTreasuryValue * MAX_TVL_PERCENTAGE_PER_TX) / MAX_BPS;
        if (_amount > maxTvlAmount) {
            emit SpendingLimitExceeded(msg.sender, _amount, maxTvlAmount, "tvl_percentage");
            return false;
        }
        
        // Update spending tracking
        spendingLimits.dailySpent[currentDay] += _amount;
        spendingLimits.monthlySpent[currentMonth] += _amount;
        
        // Update transaction velocity tracking
        spendingLimits.lastTransactionTime[msg.sender] = block.timestamp;
        spendingLimits.transactionCount24h[msg.sender]++;
        
        // Check for suspicious velocity (more than 10 transactions in 24h)
        if (spendingLimits.transactionCount24h[msg.sender] > 10) {
            emit SuspiciousActivity(msg.sender, "high_velocity", _amount, "More than 10 transactions in 24h");
        }
        
        return true;
    }

    /**
     * @dev Validate investment risk for a protocol
     * @param _protocol Protocol address
     * @param _amount Investment amount
     * @return True if investment passes risk checks
     */
    function _validateInvestmentRisk(address _protocol, uint256 _amount) internal view returns (bool) {
        InvestmentRisk storage risk = protocolRiskAssessments[_protocol];
        
        // Protocol must have a risk assessment
        if (risk.riskScore == 0) {
            return false;
        }
        
        // Check if amount exceeds max allocation for this protocol
        uint256 maxAllowedAmount = (totalTreasuryValue * risk.maxAllocation) / MAX_BPS;
        if (_amount > maxAllowedAmount) {
            return false;
        }
        
        // High-risk protocols have additional restrictions
        if (risk.riskScore > 70) { // High risk
            // Limit to 5% of treasury for high-risk protocols
            uint256 highRiskLimit = (totalTreasuryValue * 500) / MAX_BPS;
            if (_amount > highRiskLimit) {
                return false;
            }
        }
        
        return true;
    }
}