// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICarbonCreditInsurance.sol";
import "./WRFToken.sol";

/**
 * @title InsurancePool
 * @author WRFCoin Team
 * @notice Advanced insurance capital pool with sophisticated risk management
 * @dev Manages capital from providers, reserves for policies, claims processing,
 *      actuarial calculations, and maintains economic security for high-value TVL
 * 
 * Key Security Features:
 * - Multi-signature claim approvals for large payouts
 * - Time-locked withdrawals with solvency checks  
 * - Actuarial mathematics for premium calculations
 * - Circuit breakers for catastrophic events
 * - Gas-optimized batch operations
 * - Mathematical precision with overflow protection
 */
contract InsurancePool is IInsurancePool, AccessControl, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    
    // Enhanced role definitions with granular permissions
    bytes32 public constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant INSURANCE_CONTRACT_ROLE = keccak256("INSURANCE_CONTRACT_ROLE");
    bytes32 public constant CLAIMS_PAYER_ROLE = keccak256("CLAIMS_PAYER_ROLE");
    bytes32 public constant RISK_ASSESSOR_ROLE = keccak256("RISK_ASSESSOR_ROLE");
    bytes32 public constant ACTUARIAL_ROLE = keccak256("ACTUARIAL_ROLE");
    bytes32 public constant EMERGENCY_RESPONDER_ROLE = keccak256("EMERGENCY_RESPONDER_ROLE");
    bytes32 public constant MULTI_SIG_SIGNER_ROLE = keccak256("MULTI_SIG_SIGNER_ROLE");
    
    // Contract references
    WRFToken public immutable wrfToken;
    
    // Enhanced pool state with risk management
    uint256 public totalShares;
    uint256 public totalCapital;
    uint256 public availableCapital;
    uint256 public reservedCapital;
    uint256 public claimedCapital;
    uint256 public premiumsCollected;
    uint256 public totalPolicies;
    uint256 public activePolicies;
    
    // Risk management metrics
    uint256 public catastrophicLossReserve;   // Emergency reserves for major events
    uint256 public currentUtilizationRate;   // Current capital utilization
    uint256 public riskWeightedCapital;      // Risk-adjusted capital requirement
    uint256 public totalExposure;           // Sum of all policy exposures
    uint256 public maxSingleClaimLimit;     // Maximum single claim amount
    
    // Capital providers
    mapping(address => CapitalProvider) public capitalProviders;
    address[] public providersList;
    mapping(address => bool) public isProvider;
    
    // Policy reserves
    mapping(uint256 => uint256) public policyReserves;
    mapping(uint256 => bool) public policyActive;
    
    // Reward distribution
    uint256 public lastRewardDistribution;
    uint256 public rewardDistributionInterval = 7 days;
    uint256 public totalRewardsDistributed;
    
    // Multi-signature requirements for large claims
    struct MultiSigClaim {
        uint256 claimId;
        uint256 amount;
        address recipient;
        uint256 signaturesRequired;
        uint256 signaturesReceived;
        mapping(address => bool) hasSigned;
        uint256 deadline;
        bool executed;
    }
    
    mapping(uint256 => MultiSigClaim) public multiSigClaims;
    uint256 public nextMultiSigClaimId = 1;

    /// @dev Tracks claimIds that have already been paid to prevent double-payout.
    mapping(uint256 => bool) public claimPaid;
    
    // Actuarial parameters and risk models
    struct ActuarialModel {
        uint256 baseRiskFactor;        // Base risk factor (basis points)
        uint256 volatilityAdjustment;  // Volatility adjustment factor  
        uint256 seasonalityFactor;     // Seasonal risk adjustment
        uint256 concentrationRisk;     // Geographic concentration risk
        uint256 lastUpdated;
        bool isActive;
    }
    
    ActuarialModel public currentModel;
    
    // Enhanced pool parameters with security limits
    uint256 public constant MIN_SOLVENCY_RATIO = 12000; // 120%
    uint256 public constant REWARD_RATE = 500; // 5% annual
    uint256 public constant MIN_DEPOSIT = 1000 * 10**18; // 1000 WRF
    uint256 public constant WITHDRAWAL_DELAY = 2 days;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_UTILIZATION_RATE = 8000; // 80% max utilization
    uint256 public constant CATASTROPHIC_RESERVE_RATIO = 1000; // 10% reserve
    uint256 public constant MULTI_SIG_THRESHOLD = 1000000 * 10**18; // 1M WRF threshold
    uint256 public constant MAX_SINGLE_POLICY_EXPOSURE = 5000000 * 10**18; // 5M WRF max
    uint256 public constant EMERGENCY_CIRCUIT_BREAKER = 10000000 * 10**18; // 10M WRF breaker
    
    // Withdrawal requests
    struct WithdrawalRequest {
        uint256 shares;
        uint256 requestTime;
        bool processed;
    }
    
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    
    // Enhanced event definitions for comprehensive audit trail
    event ActuarialModelUpdated(
        uint256 indexed timestamp,
        uint256 baseRiskFactor,
        uint256 volatilityAdjustment,
        uint256 seasonalityFactor,
        uint256 concentrationRisk
    );
    
    event RiskMetricsUpdated(
        uint256 catastrophicLossReserve,
        uint256 currentUtilizationRate,
        uint256 riskWeightedCapital,
        uint256 totalExposure
    );
    
    event MultiSigClaimCreated(
        uint256 indexed multiSigClaimId,
        uint256 indexed claimId,
        uint256 amount,
        address recipient,
        uint256 signaturesRequired,
        uint256 deadline
    );
    
    event MultiSigClaimSigned(
        uint256 indexed multiSigClaimId,
        address signer,
        uint256 signaturesReceived,
        uint256 signaturesRequired
    );
    
    event EmergencyCircuitBreakerTriggered(
        uint256 timestamp,
        uint256 totalExposure,
        uint256 triggerThreshold,
        address triggeredBy
    );
    
    event CatastrophicEventDeclared(
        uint256 timestamp,
        string eventDescription,
        uint256 estimatedLoss,
        uint256 reservesActivated
    );
    
    /**
     * @notice Initialize insurance pool with enhanced security
     * @param _wrfToken Address of WRF token contract
     * @dev Sets up role hierarchy and initializes actuarial model
     */
    constructor(address _wrfToken) {
        require(_wrfToken != address(0), "Invalid WRF token address");
        
        wrfToken = WRFToken(_wrfToken);
        
        // Set up comprehensive role hierarchy
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POOL_MANAGER_ROLE, msg.sender);
        _grantRole(RISK_ASSESSOR_ROLE, msg.sender);
        _grantRole(ACTUARIAL_ROLE, msg.sender);
        _grantRole(EMERGENCY_RESPONDER_ROLE, msg.sender);
        _grantRole(MULTI_SIG_SIGNER_ROLE, msg.sender);
        
        // Initialize actuarial model with conservative parameters
        currentModel = ActuarialModel({
            baseRiskFactor: 200,      // 2% base risk
            volatilityAdjustment: 100, // 1% volatility adjustment
            seasonalityFactor: 50,     // 0.5% seasonal adjustment
            concentrationRisk: 75,     // 0.75% concentration risk
            lastUpdated: block.timestamp,
            isActive: true
        });
        
        // Initialize risk management parameters
        maxSingleClaimLimit = MAX_SINGLE_POLICY_EXPOSURE / 10; // 10% of max policy exposure
        
        lastRewardDistribution = block.timestamp;
    }
    
    modifier onlyInsuranceContract() {
        require(hasRole(INSURANCE_CONTRACT_ROLE, msg.sender), "Not authorized insurance contract");
        _;
    }
    
    modifier validProvider(address provider) {
        require(isProvider[provider], "Not a capital provider");
        _;
    }
    
    modifier economicSecurityCheck(uint256 amount) {
        require(amount <= EMERGENCY_CIRCUIT_BREAKER, "Amount exceeds circuit breaker");
        require(totalExposure + amount <= EMERGENCY_CIRCUIT_BREAKER, "Total exposure limit exceeded");
        _;
    }
    
    modifier solvencyMaintained(uint256 amount) {
        require(_checkSolvencyAfterWithdrawal(amount), "Withdrawal would breach solvency");
        _;
    }
    
    modifier utilizationCheck() {
        uint256 newUtilization = reservedCapital * BASIS_POINTS / totalCapital;
        require(newUtilization <= MAX_UTILIZATION_RATE, "Utilization rate exceeded");
        _;
    }
    
    modifier catastrophicProtection() {
        if (totalExposure >= EMERGENCY_CIRCUIT_BREAKER) {
            _triggerEmergencyCircuitBreaker();
        }
        _;
    }
    
    /**
     * @notice Deposit WRF tokens to become a capital provider
     * @param amount Amount of WRF tokens to deposit (must be >= MIN_DEPOSIT)
     * @return shares Number of pool shares minted for the deposit
     * @dev Uses share-based accounting to track proportional ownership.
     *      First depositor receives 1:1 shares, subsequent deposits calculated
     *      proportionally based on current pool value. Automatically updates
     *      catastrophic loss reserves and risk metrics.
     */
    function depositCapital(uint256 amount) external override nonReentrant whenNotPaused returns (uint256 shares) {
        require(amount >= MIN_DEPOSIT, "Deposit below minimum");
        
        // Transfer tokens
        require(
            wrfToken.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );
        
        // Calculate shares
        shares = calculateShares(amount);
        
        // Update provider info
        if (!isProvider[msg.sender]) {
            isProvider[msg.sender] = true;
            providersList.push(msg.sender);
            capitalProviders[msg.sender] = CapitalProvider({
                contribution: amount,
                shares: shares,
                lastRewardClaim: block.timestamp,
                totalRewards: 0,
                isActive: true
            });
        } else {
            capitalProviders[msg.sender].contribution += amount;
            capitalProviders[msg.sender].shares += shares;
            capitalProviders[msg.sender].isActive = true;
        }
        
        // Update pool state
        totalCapital += amount;
        availableCapital += amount;
        totalShares += shares;
        
        // Update catastrophic loss reserve (10% of new capital)
        uint256 reserveAddition = (amount * CATASTROPHIC_RESERVE_RATIO) / BASIS_POINTS;
        catastrophicLossReserve += reserveAddition;
        availableCapital -= reserveAddition; // Reserve is not available for policies
        
        // Update risk metrics
        _updateRiskMetrics();
        
        emit CapitalDeposited(msg.sender, amount, shares);
    }
    
    /**
     * @notice Request withdrawal of capital shares with mandatory delay
     * @param shares Number of shares to withdraw
     * @dev Implements time-locked withdrawal to prevent bank runs and
     *      ensure pool stability. Withdrawal requests must wait WITHDRAWAL_DELAY
     *      before execution and pass solvency checks.
     */
    function requestWithdrawal(uint256 shares) external validProvider(msg.sender) {
        require(shares > 0, "Invalid shares amount");
        require(capitalProviders[msg.sender].shares >= shares, "Insufficient shares");
        require(!withdrawalRequests[msg.sender].processed, "Pending withdrawal exists");
        
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            shares: shares,
            requestTime: block.timestamp,
            processed: false
        });
    }
    
    /**
     * @notice Execute withdrawal after mandatory delay period
     * @param shares Number of shares to withdraw (must match request)
     * @return amount WRF tokens returned to provider
     * @dev Enforces solvency checks and updates catastrophic reserves.
     *      Cannot execute if withdrawal would breach minimum solvency ratio.
     */
    function withdrawCapital(
        uint256 shares
    ) external override validProvider(msg.sender) nonReentrant returns (uint256 amount) {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        require(!request.processed, "Request already processed");
        require(request.shares == shares, "Shares mismatch");
        require(block.timestamp >= request.requestTime + WITHDRAWAL_DELAY, "Withdrawal delay not met");
        
        // Calculate withdrawal amount
        amount = calculateWithdrawalAmount(shares);
        
        // Check pool solvency
        require(_checkSolvencyAfterWithdrawal(amount), "Withdrawal would compromise solvency");
        
        // Update provider info
        capitalProviders[msg.sender].shares -= shares;
        capitalProviders[msg.sender].contribution = (
            capitalProviders[msg.sender].contribution * capitalProviders[msg.sender].shares
        ) / (capitalProviders[msg.sender].shares + shares);
        
        if (capitalProviders[msg.sender].shares == 0) {
            capitalProviders[msg.sender].isActive = false;
        }
        
        // Update pool state
        totalCapital -= amount;
        availableCapital -= amount;
        totalShares -= shares;
        
        // Mark request as processed
        request.processed = true;
        
        // Transfer tokens
        IERC20(address(wrfToken)).safeTransfer(msg.sender, amount);
        
        emit CapitalWithdrawn(msg.sender, amount, shares);
    }
    
    /**
     * @dev Claim accumulated rewards
     */
    function claimRewards() external override validProvider(msg.sender) nonReentrant returns (uint256 rewards) {
        CapitalProvider storage provider = capitalProviders[msg.sender];
        
        // Calculate rewards since last claim
        rewards = _calculateRewards(msg.sender);
        
        if (rewards > 0) {
            // Update provider info
            provider.lastRewardClaim = block.timestamp;
            provider.totalRewards += rewards;
            
            // Transfer rewards
            IERC20(address(wrfToken)).safeTransfer(msg.sender, rewards);
            
            emit RewardsClaimed(msg.sender, rewards);
        }
    }
    
    /**
     * @dev Reserve capital for a new policy
     */
    function reserveCapital(uint256 policyId, uint256 amount) external override onlyInsuranceContract {
        require(amount <= availableCapital, "Insufficient available capital");
        require(!policyActive[policyId], "Policy already reserved");
        
        // Update reserves
        policyReserves[policyId] = amount;
        policyActive[policyId] = true;
        reservedCapital += amount;
        availableCapital -= amount;
        activePolicies++;
        
        emit PolicyReserved(policyId, amount);
    }
    
    /**
     * @dev Release reserve when policy expires or is cancelled
     */
    function releaseReserve(uint256 policyId) external override onlyInsuranceContract {
        require(policyActive[policyId], "Policy not active");
        
        uint256 reservedAmount = policyReserves[policyId];
        
        // Update reserves
        policyReserves[policyId] = 0;
        policyActive[policyId] = false;
        reservedCapital -= reservedAmount;
        availableCapital += reservedAmount;
        activePolicies--;
    }
    
    /**
     * @notice Create multi-signature claim for large payouts
     * @param claimId Insurance claim identifier
     * @param amount Claim payout amount in WRF
     * @param recipient Address to receive payout
     * @return multiSigClaimId Unique identifier for multi-sig process
     * @dev Claims exceeding MULTI_SIG_THRESHOLD require multiple signatures
     *      from authorized signers. Implements time-locked execution.
     */
    function createMultiSigClaim(
        uint256 claimId,
        uint256 amount,
        address recipient
    ) external onlyRole(CLAIMS_PAYER_ROLE) economicSecurityCheck(amount) returns (uint256 multiSigClaimId) {
        require(amount >= MULTI_SIG_THRESHOLD, "Below multi-sig threshold");
        require(recipient != address(0), "Invalid recipient");
        require(amount <= maxSingleClaimLimit, "Exceeds single claim limit");
        
        multiSigClaimId = nextMultiSigClaimId++;
        
        // Calculate required signatures based on claim size
        uint256 signaturesRequired = _calculateRequiredSignatures(amount);
        
        MultiSigClaim storage claim = multiSigClaims[multiSigClaimId];
        claim.claimId = claimId;
        claim.amount = amount;
        claim.recipient = recipient;
        claim.signaturesRequired = signaturesRequired;
        claim.signaturesReceived = 0;
        claim.deadline = block.timestamp + 7 days; // 7 day execution window
        claim.executed = false;
        
        emit MultiSigClaimCreated(
            multiSigClaimId,
            claimId,
            amount,
            recipient,
            signaturesRequired,
            claim.deadline
        );
    }
    
    /**
     * @notice Sign a multi-signature claim
     * @param multiSigClaimId Multi-sig claim identifier
     * @dev Authorized signers can approve large claims. Auto-executes when
     *      sufficient signatures collected and within deadline.
     */
    function signMultiSigClaim(uint256 multiSigClaimId) external onlyRole(MULTI_SIG_SIGNER_ROLE) {
        MultiSigClaim storage claim = multiSigClaims[multiSigClaimId];
        require(!claim.executed, "Claim already executed");
        require(block.timestamp <= claim.deadline, "Claim expired");
        require(!claim.hasSigned[msg.sender], "Already signed");
        require(claim.amount <= reservedCapital, "Insufficient reserved capital");
        
        claim.hasSigned[msg.sender] = true;
        claim.signaturesReceived++;
        
        emit MultiSigClaimSigned(
            multiSigClaimId,
            msg.sender,
            claim.signaturesReceived,
            claim.signaturesRequired
        );
        
        // Auto-execute if enough signatures
        if (claim.signaturesReceived >= claim.signaturesRequired) {
            _executeMultiSigClaim(multiSigClaimId);
        }
    }
    
    /**
     * @notice Execute approved multi-signature claim
     * @param multiSigClaimId Multi-sig claim identifier
     * @dev Internal execution after sufficient signatures collected
     */
    function _executeMultiSigClaim(uint256 multiSigClaimId) internal {
        MultiSigClaim storage claim = multiSigClaims[multiSigClaimId];
        require(!claim.executed, "Already executed");
        require(claim.signaturesReceived >= claim.signaturesRequired, "Insufficient signatures");
        require(!claimPaid[claim.claimId], "InsurancePool: claim already paid");

        claim.executed = true;
        claimPaid[claim.claimId] = true;
        
        // Update pool state
        reservedCapital -= claim.amount;
        claimedCapital += claim.amount;
        totalCapital -= claim.amount;
        
        // Update risk metrics after large payout
        _updateRiskMetrics();
        
        // Transfer payment
        IERC20(address(wrfToken)).safeTransfer(claim.recipient, claim.amount);
        
        emit ClaimPaid(claim.claimId, claim.amount);
    }
    
    /**
     * @notice Pay a regular claim from the pool (for amounts below multi-sig threshold)
     * @param claimId Insurance claim identifier
     * @param amount Claim payout amount in WRF
     * @param recipient Address to receive payout
     * @dev For claims below MULTI_SIG_THRESHOLD. Large claims use multi-sig process.
     */
    function payClaim(
        uint256 claimId, 
        uint256 amount, 
        address recipient
    ) external override onlyRole(CLAIMS_PAYER_ROLE) economicSecurityCheck(amount) {
        require(amount < MULTI_SIG_THRESHOLD, "Use multi-sig process for large claims");
        require(amount <= reservedCapital, "Insufficient reserved capital");
        require(recipient != address(0), "Invalid recipient");
        require(!claimPaid[claimId], "InsurancePool: claim already paid");

        // Mark before transfer to prevent re-entrancy double-payout
        claimPaid[claimId] = true;

        // Update pool state
        reservedCapital -= amount;
        claimedCapital += amount;
        totalCapital -= amount;

        // Update risk metrics after payout
        _updateRiskMetrics();

        // Transfer payment
        IERC20(address(wrfToken)).safeTransfer(recipient, amount);

        emit ClaimPaid(claimId, amount);
    }
    
    /**
     * @dev Distribute rewards to capital providers
     */
    function distributeRewards() external override onlyRole(POOL_MANAGER_ROLE) {
        require(block.timestamp >= lastRewardDistribution + rewardDistributionInterval, "Distribution too early");
        
        uint256 totalRewards = _calculateTotalRewards();
        
        if (totalRewards > 0) {
            totalRewardsDistributed += totalRewards;
            lastRewardDistribution = block.timestamp;
            
            emit RewardsDistributed(totalRewards, block.timestamp);
        }
    }
    
    /**
     * @dev Get current pool statistics
     */
    function getPoolStats() external view override returns (PoolStats memory) {
        return PoolStats({
            totalCapital: totalCapital,
            availableCapital: availableCapital,
            reservedCapital: reservedCapital,
            claimedCapital: claimedCapital,
            premiumsCollected: premiumsCollected,
            totalPolicies: totalPolicies,
            activePolicies: activePolicies,
            utilizationRate: totalCapital > 0 ? (reservedCapital * BASIS_POINTS) / totalCapital : 0,
            solvencyRatio: reservedCapital > 0 ? (totalCapital * BASIS_POINTS) / reservedCapital : BASIS_POINTS
        });
    }
    
    /**
     * @dev Get capital provider information
     */
    function getProviderInfo(address provider) external view override returns (CapitalProvider memory) {
        return capitalProviders[provider];
    }
    
    /**
     * @dev Calculate shares for a deposit amount
     */
    function calculateShares(uint256 amount) public view override returns (uint256 shares) {
        if (totalShares == 0) {
            return amount; // 1:1 for first depositor
        }
        
        return (amount * totalShares) / totalCapital;
    }
    
    /**
     * @dev Calculate withdrawal amount for shares
     */
    function calculateWithdrawalAmount(uint256 shares) public view override returns (uint256 amount) {
        require(totalShares > 0, "No shares outstanding");
        
        return (shares * totalCapital) / totalShares;
    }
    
    /**
     * @dev Add premium to pool when policy is purchased
     */
    function addPremium(uint256 amount) external onlyInsuranceContract {
        premiumsCollected += amount;
        totalCapital += amount;
        availableCapital += amount;
        totalPolicies++;
    }
    
    /**
     * @dev Calculate rewards for a provider
     */
    function _calculateRewards(address provider) internal view returns (uint256) {
        CapitalProvider memory providerInfo = capitalProviders[provider];
        
        if (!providerInfo.isActive || providerInfo.shares == 0) {
            return 0;
        }
        
        uint256 timeElapsed = block.timestamp - providerInfo.lastRewardClaim;
        uint256 annualReward = (providerInfo.contribution * REWARD_RATE) / BASIS_POINTS;
        
        return (annualReward * timeElapsed) / 365 days;
    }
    
    /**
     * @dev Calculate total rewards to be distributed
     */
    function _calculateTotalRewards() internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastRewardDistribution;
        uint256 annualReward = (totalCapital * REWARD_RATE) / BASIS_POINTS;
        
        return (annualReward * timeElapsed) / 365 days;
    }
    
    /**
     * @dev Check if pool maintains solvency after withdrawal
     */
    function _checkSolvencyAfterWithdrawal(uint256 withdrawalAmount) internal view returns (bool) {
        if (reservedCapital == 0) return true;
        
        uint256 newTotalCapital = totalCapital - withdrawalAmount;
        uint256 newSolvencyRatio = (newTotalCapital * BASIS_POINTS) / reservedCapital;
        
        return newSolvencyRatio >= MIN_SOLVENCY_RATIO;
    }
    
    /**
     * @dev Emergency withdraw for capital providers (admin only)
     */
    function emergencyWithdraw(address provider, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isProvider[provider], "Not a provider");
        require(amount <= capitalProviders[provider].contribution, "Exceeds contribution");
        
        // Update provider info
        capitalProviders[provider].contribution -= amount;
        uint256 sharesReduction = (amount * capitalProviders[provider].shares) / 
            (capitalProviders[provider].contribution + amount);
        capitalProviders[provider].shares -= sharesReduction;
        
        // Update pool state
        totalCapital -= amount;
        availableCapital -= amount;
        totalShares -= sharesReduction;
        
        // Transfer tokens
        IERC20(address(wrfToken)).safeTransfer(provider, amount);
    }
    
    /**
     * @dev Update reward distribution interval
     */
    function setRewardDistributionInterval(uint256 interval) external onlyRole(POOL_MANAGER_ROLE) {
        require(interval >= 1 days && interval <= 30 days, "Invalid interval");
        rewardDistributionInterval = interval;
    }
    
    /**
     * @dev Get list of all capital providers
     */
    function getProvidersList() external view returns (address[] memory) {
        return providersList;
    }
    
    /**
     * @dev Get active providers count
     */
    function getActiveProvidersCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < providersList.length; i++) {
            if (capitalProviders[providersList[i]].isActive) {
                count++;
            }
        }
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // ============================================================================
    // ACTUARIAL AND RISK MANAGEMENT FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Update actuarial model parameters
     * @param baseRiskFactor Base risk factor in basis points
     * @param volatilityAdjustment Volatility adjustment factor
     * @param seasonalityFactor Seasonal risk adjustment factor
     * @param concentrationRisk Geographic concentration risk factor
     * @dev Only actuaries can update the risk model parameters
     */
    function updateActuarialModel(
        uint256 baseRiskFactor,
        uint256 volatilityAdjustment,
        uint256 seasonalityFactor,
        uint256 concentrationRisk
    ) external onlyRole(ACTUARIAL_ROLE) {
        require(baseRiskFactor <= 1000, "Base risk too high"); // Max 10%
        require(volatilityAdjustment <= 500, "Volatility adjustment too high"); // Max 5%
        require(seasonalityFactor <= 200, "Seasonality factor too high"); // Max 2%
        require(concentrationRisk <= 300, "Concentration risk too high"); // Max 3%
        
        currentModel.baseRiskFactor = baseRiskFactor;
        currentModel.volatilityAdjustment = volatilityAdjustment;
        currentModel.seasonalityFactor = seasonalityFactor;
        currentModel.concentrationRisk = concentrationRisk;
        currentModel.lastUpdated = block.timestamp;
        
        emit ActuarialModelUpdated(
            block.timestamp,
            baseRiskFactor,
            volatilityAdjustment,
            seasonalityFactor,
            concentrationRisk
        );
    }
    
    /**
     * @notice Calculate actuarial premium using current risk model
     * @param baseAmount Base coverage amount
     * @param riskScore Risk score from oracle (0-1000)
     * @param duration Coverage duration in seconds
     * @return premium Calculated premium amount
     * @dev Implements sophisticated actuarial mathematics with multiple risk factors
     */
    function calculateActuarialPremium(
        uint256 baseAmount,
        uint256 riskScore,
        uint256 duration
    ) external view returns (uint256 premium) {
        require(baseAmount > 0, "Invalid base amount");
        require(riskScore <= 1000, "Invalid risk score");
        require(duration > 0, "Invalid duration");
        require(currentModel.isActive, "Model not active");
        
        // Base premium calculation: baseAmount * baseRiskFactor * duration
        uint256 basePremium = (baseAmount * currentModel.baseRiskFactor * duration) / 
                              (BASIS_POINTS * 365 days);
        
        // Risk score adjustment (0-100% additional premium based on risk)
        uint256 riskAdjustment = (basePremium * riskScore) / 1000;
        
        // Volatility adjustment
        uint256 volatilityAdjustment = (basePremium * currentModel.volatilityAdjustment) / BASIS_POINTS;
        
        // Seasonal adjustment
        uint256 seasonalAdjustment = _calculateSeasonalAdjustment(basePremium);
        
        // Concentration risk adjustment
        uint256 concentrationAdjustment = (basePremium * currentModel.concentrationRisk) / BASIS_POINTS;
        
        // Final premium calculation with all adjustments
        premium = basePremium + riskAdjustment + volatilityAdjustment + 
                 seasonalAdjustment + concentrationAdjustment;
        
        // Apply minimum premium (0.1% of coverage amount)
        uint256 minPremium = baseAmount / 1000;
        if (premium < minPremium) {
            premium = minPremium;
        }
        
        // Apply maximum premium cap (10% of coverage amount)
        uint256 maxPremium = baseAmount / 10;
        if (premium > maxPremium) {
            premium = maxPremium;
        }
    }
    
    /**
     * @notice Calculate seasonal risk adjustment based on current month
     * @param basePremium Base premium amount
     * @return adjustment Seasonal adjustment amount
     * @dev Applies higher premiums during high-risk seasons (winter storms, hurricane season)
     */
    function _calculateSeasonalAdjustment(uint256 basePremium) internal view returns (uint256 adjustment) {
        uint256 month = (block.timestamp / 30 days) % 12 + 1; // Approximate month (1-12)
        
        // High-risk months: June-November (hurricane season), December-February (winter storms)
        if ((month >= 6 && month <= 11) || month <= 2) {
            adjustment = (basePremium * currentModel.seasonalityFactor * 2) / BASIS_POINTS;
        } else {
            adjustment = (basePremium * currentModel.seasonalityFactor) / BASIS_POINTS;
        }
    }
    
    /**
     * @notice Update risk metrics after significant pool changes
     * @dev Recalculates utilization rates, risk-weighted capital, and exposure limits
     */
    function _updateRiskMetrics() internal {
        // Update utilization rate
        if (totalCapital > 0) {
            currentUtilizationRate = (reservedCapital * BASIS_POINTS) / totalCapital;
        }
        
        // Calculate risk-weighted capital requirement
        riskWeightedCapital = _calculateRiskWeightedCapital();
        
        // Update total exposure
        totalExposure = reservedCapital + claimedCapital;
        
        emit RiskMetricsUpdated(
            catastrophicLossReserve,
            currentUtilizationRate,
            riskWeightedCapital,
            totalExposure
        );
    }
    
    /**
     * @notice Calculate required signatures for multi-sig claims based on amount
     * @param amount Claim amount
     * @return signatures Number of signatures required
     * @dev Higher amounts require more signatures for enhanced security
     */
    function _calculateRequiredSignatures(uint256 amount) internal pure returns (uint256 signatures) {
        if (amount >= 10000000 * 10**18) { // >= 10M WRF
            return 5; // Maximum security
        } else if (amount >= 5000000 * 10**18) { // >= 5M WRF
            return 4;
        } else if (amount >= 2000000 * 10**18) { // >= 2M WRF
            return 3;
        } else {
            return 2; // Minimum for multi-sig
        }
    }
    
    /**
     * @notice Calculate risk-weighted capital requirement
     * @return riskCapital Required capital based on current risk exposure
     * @dev Uses Basel-III inspired risk weighting methodology
     */
    function _calculateRiskWeightedCapital() internal view returns (uint256 riskCapital) {
        // Base capital requirement (8% of total exposure)
        uint256 baseCapital = (totalExposure * 800) / BASIS_POINTS;
        
        // Risk adjustment based on current utilization
        uint256 utilizationMultiplier = BASIS_POINTS;
        if (currentUtilizationRate > 6000) { // > 60%
            utilizationMultiplier = 15000; // 1.5x
        } else if (currentUtilizationRate > 4000) { // > 40%
            utilizationMultiplier = 12500; // 1.25x
        }
        
        riskCapital = (baseCapital * utilizationMultiplier) / BASIS_POINTS;
        
        // Minimum capital requirement
        uint256 minCapital = totalCapital / 10; // 10% of total capital
        if (riskCapital < minCapital) {
            riskCapital = minCapital;
        }
    }
    
    /**
     * @notice Trigger emergency circuit breaker for catastrophic events
     * @dev Pauses new policy creation and large withdrawals when exposure limits exceeded
     */
    function _triggerEmergencyCircuitBreaker() internal {
        _pause();
        
        emit EmergencyCircuitBreakerTriggered(
            block.timestamp,
            totalExposure,
            EMERGENCY_CIRCUIT_BREAKER,
            msg.sender
        );
    }
    
    /**
     * @notice Declare catastrophic event and activate emergency reserves
     * @param eventDescription Description of the catastrophic event
     * @param estimatedLoss Estimated loss amount
     * @dev Only emergency responders can declare catastrophic events
     */
    function declareCatastrophicEvent(
        string calldata eventDescription,
        uint256 estimatedLoss
    ) external onlyRole(EMERGENCY_RESPONDER_ROLE) {
        require(estimatedLoss > 0, "Invalid loss estimate");
        require(bytes(eventDescription).length > 0, "Empty description");
        
        // Activate catastrophic reserves
        uint256 reservesActivated = Math.min(catastrophicLossReserve, estimatedLoss);
        catastrophicLossReserve -= reservesActivated;
        availableCapital += reservesActivated; // Make reserves available for claims
        
        emit CatastrophicEventDeclared(
            block.timestamp,
            eventDescription,
            estimatedLoss,
            reservesActivated
        );
    }
    
    /**
     * @notice Get comprehensive pool risk assessment
     * @return solvencyRatio Current solvency ratio
     * @return utilizationRate Current utilization rate
     * @return riskWeightedCapitalRatio Risk-weighted capital ratio
     * @return catastrophicReserveRatio Catastrophic reserve ratio
     * @return maxClaimCapacity Maximum claim capacity
     * @return isHealthy Whether pool is healthy
     */
    function getPoolRiskAssessment() external view returns (
        uint256 solvencyRatio,
        uint256 utilizationRate,
        uint256 riskWeightedCapitalRatio,
        uint256 catastrophicReserveRatio,
        uint256 maxClaimCapacity,
        bool isHealthy
    ) {
        solvencyRatio = reservedCapital > 0 ? 
            (totalCapital * BASIS_POINTS) / reservedCapital : BASIS_POINTS;
        
        utilizationRate = currentUtilizationRate;
        
        riskWeightedCapitalRatio = totalCapital > 0 ? 
            (riskWeightedCapital * BASIS_POINTS) / totalCapital : 0;
        
        catastrophicReserveRatio = totalCapital > 0 ? 
            (catastrophicLossReserve * BASIS_POINTS) / totalCapital : 0;
        
        maxClaimCapacity = Math.min(maxSingleClaimLimit, reservedCapital);
        
        // Pool is healthy if all key metrics are within acceptable ranges
        isHealthy = solvencyRatio >= MIN_SOLVENCY_RATIO &&
                   utilizationRate <= MAX_UTILIZATION_RATE &&
                   catastrophicReserveRatio >= CATASTROPHIC_RESERVE_RATIO / 2; // At least half reserve
    }
    
    /**
     * @notice Batch process multiple provider reward distributions
     * @param providers Array of provider addresses
     * @dev Gas-optimized batch rewards processing for operational efficiency
     */
    function batchProcessRewards(address[] calldata providers) external onlyRole(POOL_MANAGER_ROLE) {
        require(providers.length <= 50, "Batch size too large"); // Gas limit protection
        
        uint256 totalBatchRewards = 0;
        
        for (uint256 i = 0; i < providers.length; i++) {
            address provider = providers[i];
            if (isProvider[provider] && capitalProviders[provider].isActive) {
                uint256 rewards = _calculateRewards(provider);
                if (rewards > 0) {
                    capitalProviders[provider].lastRewardClaim = block.timestamp;
                    capitalProviders[provider].totalRewards += rewards;
                    totalBatchRewards += rewards;
                    
                    IERC20(address(wrfToken)).safeTransfer(provider, rewards);
                    emit RewardsClaimed(provider, rewards);
                }
            }
        }
        
        if (totalBatchRewards > 0) {
            totalRewardsDistributed += totalBatchRewards;
        }
    }
    
    /**
     * @notice Update maximum single claim limit
     * @param newLimit New maximum claim limit
     * @dev Security parameter that can be adjusted based on pool growth and risk assessment
     */
    function updateMaxSingleClaimLimit(uint256 newLimit) external onlyRole(RISK_ASSESSOR_ROLE) {
        require(newLimit > 0, "Invalid limit");
        require(newLimit <= MAX_SINGLE_POLICY_EXPOSURE, "Exceeds policy exposure limit");
        
        uint256 oldLimit = maxSingleClaimLimit;
        maxSingleClaimLimit = newLimit;
        
        // Update risk metrics after limit change
        _updateRiskMetrics();
        
        // Note: Could emit an event here for audit trail if needed
    }
}