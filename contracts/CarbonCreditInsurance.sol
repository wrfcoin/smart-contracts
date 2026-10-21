// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICarbonCreditInsurance.sol";
import "./interfaces/IQualityOracle.sol";
import "./interfaces/IVolatilityOracle.sol";
import "./EnhancedCarbonCredits.sol";
import "./WRFToken.sol";

/**
 * @title CarbonCreditInsurance
 * @dev Main insurance contract for carbon credit protection
 * Provides coverage against project failure, verification issues, and regulatory risks
 */
contract CarbonCreditInsurance is ICarbonCreditInsurance, AccessControl, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    
    // Role definitions
    bytes32 public constant UNDERWRITER_ROLE = keccak256("UNDERWRITER_ROLE");
    bytes32 public constant CLAIMS_ASSESSOR_ROLE = keccak256("CLAIMS_ASSESSOR_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE = keccak256("RISK_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PAUSE_GUARDIAN_ROLE = keccak256("PAUSE_GUARDIAN_ROLE");

    // Multisig pause/unpause
    uint256 public constant PAUSE_THRESHOLD = 2;
    uint256 public pauseNonce;
    mapping(uint256 => mapping(address => bool)) public pauseApprovals;
    uint256 public pauseApprovalCount;
    uint256 public unpauseNonce;
    mapping(uint256 => mapping(address => bool)) public unpauseApprovals;
    uint256 public unpauseApprovalCount;

    // Events for pause governance
    event PauseRequested(address indexed guardian);
    event EmergencyPaused(uint256 approvalCount);
    event UnpauseRequested(address indexed guardian);
    event EmergencyUnpaused(uint256 approvalCount);
    
    // Contract references
    EnhancedCarbonCredits public immutable carbonCredits;
    WRFToken public immutable wrfToken;
    IQualityOracle public qualityOracle;
    IVolatilityOracle public volatilityOracle;
    address public insurancePool;
    address public governanceContract;
    
    // State variables
    uint256 private _nextPolicyId = 1;
    uint256 private _nextClaimId = 1;
    
    // Mappings
    mapping(uint256 => InsurancePolicy) public policies;
    mapping(uint256 => InsuranceClaim) public claims;
    mapping(uint256 => RiskAssessment) public riskAssessments;
    mapping(address => uint256[]) public userPolicies;
    mapping(uint256 => uint256[]) public tokenPolicies; // tokenId => policyIds
    mapping(uint256 => uint256) public policyReserves; // policyId => reserved amount
    
    // Configuration parameters
    mapping(CoverageType => uint256) public basePremiumRates; // basis points
    mapping(RiskLevel => uint256) public riskMultipliers; // basis points
    uint256 public constant MAX_COVERAGE_RATIO = 8000; // 80% of token value
    uint256 public constant MIN_POLICY_DURATION = 30 days;
    uint256 public constant MAX_POLICY_DURATION = 365 days;
    uint256 public constant CLAIMS_INVESTIGATION_PERIOD = 7 days;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Risk assessment weights (basis points)
    uint256 public constant PROJECT_RISK_WEIGHT = 3000;    // 30%
    uint256 public constant VERIFICATION_RISK_WEIGHT = 2500; // 25%
    uint256 public constant REGULATORY_RISK_WEIGHT = 2000;  // 20%
    uint256 public constant MARKET_RISK_WEIGHT = 1500;     // 15%
    uint256 public constant QUALITY_WEIGHT = 1000;         // 10%
    
    constructor(
        address _carbonCredits,
        address _wrfToken,
        address _qualityOracle,
        address _volatilityOracle
    ) {
        require(_carbonCredits != address(0), "Invalid carbon credits address");
        require(_wrfToken != address(0), "Invalid WRF token address");
        require(_qualityOracle != address(0), "Invalid quality oracle address");
        require(_volatilityOracle != address(0), "Invalid volatility oracle address");
        
        carbonCredits = EnhancedCarbonCredits(_carbonCredits);
        wrfToken = WRFToken(_wrfToken);
        qualityOracle = IQualityOracle(_qualityOracle);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UNDERWRITER_ROLE, msg.sender);
        _grantRole(CLAIMS_ASSESSOR_ROLE, msg.sender);
        _grantRole(RISK_MANAGER_ROLE, msg.sender);
        
        // Initialize base premium rates (basis points per year)
        basePremiumRates[CoverageType.PROJECT_FAILURE] = 300;      // 3%
        basePremiumRates[CoverageType.VERIFICATION_RISK] = 200;    // 2%
        basePremiumRates[CoverageType.REGULATORY_RISK] = 150;      // 1.5%
        basePremiumRates[CoverageType.DELIVERY_GUARANTEE] = 100;   // 1%
        basePremiumRates[CoverageType.INVALIDATION_COVER] = 250;   // 2.5%
        
        // Initialize risk multipliers
        riskMultipliers[RiskLevel.LOW] = 5000;      // 0.5x
        riskMultipliers[RiskLevel.MEDIUM] = 10000;  // 1.0x
        riskMultipliers[RiskLevel.HIGH] = 20000;    // 2.0x
        riskMultipliers[RiskLevel.CRITICAL] = 40000; // 4.0x
    }
    
    modifier validPolicy(uint256 policyId) {
        require(policyId > 0 && policyId < _nextPolicyId, "Invalid policy ID");
        _;
    }
    
    modifier validClaim(uint256 claimId) {
        require(claimId > 0 && claimId < _nextClaimId, "Invalid claim ID");
        _;
    }
    
    modifier onlyPolicyholder(uint256 policyId) {
        require(policies[policyId].policyholder == msg.sender, "Not policy holder");
        _;
    }
    
    /**
     * @dev Create a new insurance policy
     */
    function createPolicy(
        uint256 tokenId,
        uint256 coveredAmount,
        CoverageType[] calldata coverageTypes,
        uint256 duration,
        string calldata terms
    ) external override nonReentrant whenNotPaused returns (uint256 policyId) {
        require(coverageTypes.length > 0, "No coverage types specified");
        require(duration >= MIN_POLICY_DURATION && duration <= MAX_POLICY_DURATION, "Invalid duration");
        require(coveredAmount > 0, "Invalid covered amount");
        
        // Verify token ownership and validity
        require(carbonCredits.balanceOf(msg.sender, tokenId) >= coveredAmount, "Insufficient token balance");
        
        // Get batch info to validate
        EnhancedCarbonCredits.CarbonCreditBatch memory batchInfo = carbonCredits.getBatchInfo(tokenId);
        require(batchInfo.isActive, "Token batch not active");
        
        // Calculate premium
        PremiumData memory premiumData = calculatePremium(tokenId, coveredAmount, coverageTypes, duration);
        
        // Create policy
        policyId = _nextPolicyId++;
        
        policies[policyId] = InsurancePolicy({
            policyId: policyId,
            policyholder: msg.sender,
            tokenId: tokenId,
            coveredAmount: coveredAmount,
            coverageTypes: coverageTypes,
            premiumAmount: premiumData.finalPremium,
            coverageAmount: _calculateCoverageAmount(tokenId, coveredAmount),
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            status: PolicyStatus.ACTIVE,
            riskScore: riskAssessments[tokenId].overallRisk,
            riskLevel: _determineRiskLevel(riskAssessments[tokenId].overallRisk),
            terms: terms
        });
        
        // Update mappings
        userPolicies[msg.sender].push(policyId);
        tokenPolicies[tokenId].push(policyId);
        
        // Reserve capital in insurance pool
        if (insurancePool != address(0)) {
            policyReserves[policyId] = policies[policyId].coverageAmount;
            IInsurancePool(insurancePool).reserveCapital(policyId, policies[policyId].coverageAmount);
        }
        
        emit PolicyCreated(
            policyId,
            msg.sender,
            tokenId,
            coveredAmount,
            premiumData.finalPremium,
            coverageTypes
        );
    }
    
    /**
     * @dev Pay premium for a policy
     */
    function payPremium(uint256 policyId) external override validPolicy(policyId) onlyPolicyholder(policyId) {
        InsurancePolicy storage policy = policies[policyId];
        require(policy.status == PolicyStatus.ACTIVE, "Policy not active");
        
        // Transfer premium
        IERC20(address(wrfToken)).safeTransferFrom(msg.sender, address(this), policy.premiumAmount);

        // Transfer premium to insurance pool if configured
        if (insurancePool != address(0)) {
            IERC20(address(wrfToken)).safeTransfer(insurancePool, policy.premiumAmount);
        }
        
        emit PremiumPaid(policyId, msg.sender, policy.premiumAmount);
    }
    
    /**
     * @dev Submit an insurance claim
     */
    function submitClaim(
        uint256 policyId,
        CoverageType claimType,
        uint256 claimedAmount,
        string calldata evidence
    ) external override validPolicy(policyId) onlyPolicyholder(policyId) returns (uint256 claimId) {
        InsurancePolicy storage policy = policies[policyId];
        require(policy.status == PolicyStatus.ACTIVE, "Policy not active");
        require(block.timestamp <= policy.endTime, "Policy expired");
        require(claimedAmount <= policy.coveredAmount, "Claim exceeds coverage");
        require(isPolicyCovered(policyId, claimType), "Coverage type not included");
        
        claimId = _nextClaimId++;
        
        uint256 requestedPayout = (claimedAmount * policy.coverageAmount) / policy.coveredAmount;
        
        claims[claimId] = InsuranceClaim({
            claimId: claimId,
            policyId: policyId,
            claimant: msg.sender,
            claimType: claimType,
            claimedAmount: claimedAmount,
            requestedPayout: requestedPayout,
            approvedPayout: 0,
            status: ClaimStatus.PENDING,
            submissionTime: block.timestamp,
            investigationDeadline: block.timestamp + CLAIMS_INVESTIGATION_PERIOD,
            evidence: evidence,
            assessmentNotes: "",
            requiresGovernance: _requiresGovernance(claimType, requestedPayout)
        });
        
        emit ClaimSubmitted(claimId, policyId, msg.sender, claimType, claimedAmount);
        
        // Start automated processing for simple claims
        if (!claims[claimId].requiresGovernance) {
            claims[claimId].status = ClaimStatus.INVESTIGATING;
        }
    }
    
    /**
     * @dev Process an insurance claim
     */
    function processClaim(uint256 claimId) external override validClaim(claimId) onlyRole(CLAIMS_ASSESSOR_ROLE) {
        InsuranceClaim storage claim = claims[claimId];
        require(claim.status == ClaimStatus.INVESTIGATING, "Claim not under investigation");
        
        // Automated assessment based on oracle data
        bool isValid = _assessClaim(claimId);
        
        if (isValid) {
            claim.status = ClaimStatus.APPROVED;
            claim.approvedPayout = claim.requestedPayout;
            
            // Pay claim if pool is configured
            if (insurancePool != address(0)) {
                IInsurancePool(insurancePool).payClaim(claimId, claim.approvedPayout, claim.claimant);
            }
            
            // Update policy status
            InsurancePolicy storage policy = policies[claim.policyId];
            policy.status = PolicyStatus.CLAIMED;
            
            emit ClaimProcessed(claimId, ClaimStatus.APPROVED, claim.approvedPayout);
        } else {
            claim.status = ClaimStatus.REJECTED;
            claim.assessmentNotes = "Automated assessment failed validation";
            
            emit ClaimProcessed(claimId, ClaimStatus.REJECTED, 0);
        }
    }
    
    /**
     * @dev Calculate premium for a policy
     */
    function calculatePremium(
        uint256 tokenId,
        uint256 coveredAmount,
        CoverageType[] calldata coverageTypes,
        uint256 duration
    ) public view override returns (PremiumData memory) {
        // Get or calculate risk assessment
        RiskAssessment memory risk = riskAssessments[tokenId];
        if (risk.timestamp == 0) {
            risk = assessRisk(tokenId);
        }
        
        // Calculate base premium
        uint256 basePremium = 0;
        for (uint256 i = 0; i < coverageTypes.length; i++) {
            basePremium += basePremiumRates[coverageTypes[i]];
        }
        
        // Calculate coverage amount for premium calculation
        uint256 coverageAmount = _calculateCoverageAmount(tokenId, coveredAmount);
        
        // Apply duration adjustment (annual rate)
        uint256 durationAdjustedPremium = (basePremium * duration) / 365 days;
        
        // Apply risk adjustments
        RiskLevel riskLevel = _determineRiskLevel(risk.overallRisk);
        uint256 riskAdjustment = (durationAdjustedPremium * riskMultipliers[riskLevel]) / BASIS_POINTS;
        
        // Apply quality adjustment (better quality = lower premium)
        uint256 qualityFactor = qualityOracle.getQualityPricingFactor(address(carbonCredits));
        uint256 qualityAdjustment = (riskAdjustment * BASIS_POINTS) / qualityFactor;
        
        // Apply volatility adjustment
        uint256 volatility = volatilityOracle.getVolatility(address(carbonCredits), address(wrfToken));
        uint256 volatilityAdjustment = qualityAdjustment + ((qualityAdjustment * volatility) / BASIS_POINTS);
        
        // Calculate final premium amount
        uint256 finalPremium = (volatilityAdjustment * coverageAmount) / BASIS_POINTS;
        
        return PremiumData({
            basePremium: basePremium,
            riskAdjustment: riskAdjustment,
            qualityAdjustment: qualityAdjustment,
            volatilityAdjustment: volatilityAdjustment,
            finalPremium: finalPremium,
            calculationTime: block.timestamp
        });
    }
    
    /**
     * @dev Assess risk for a carbon credit token
     */
    function assessRisk(uint256 tokenId) public view override returns (RiskAssessment memory) {
        // Get batch information
        EnhancedCarbonCredits.CarbonCreditBatch memory batch = carbonCredits.getBatchInfo(tokenId);

        require(batch.isActive, "Token batch not active");

        // Calculate component risks
        uint256 projectRisk = _assessProjectRisk(batch.projectType, batch.methodology, batch.vintage);
        uint256 verificationRisk = _assessVerificationRisk(batch.registryStandard, batch.methodology);
        uint256 regulatoryRisk = _assessRegulatoryRisk(batch.registryStandard, batch.vintage);
        uint256 marketRisk = _assessMarketRisk(tokenId);
        
        // Get quality and volatility scores
        uint256 qualityScore = qualityOracle.getQualityScore(address(carbonCredits));
        uint256 volatilityScore = volatilityOracle.getVolatility(address(carbonCredits), address(wrfToken));
        
        // Calculate overall risk (weighted average)
        uint256 overallRisk = (
            projectRisk * PROJECT_RISK_WEIGHT +
            verificationRisk * VERIFICATION_RISK_WEIGHT +
            regulatoryRisk * REGULATORY_RISK_WEIGHT +
            marketRisk * MARKET_RISK_WEIGHT +
            ((1000 - qualityScore) / 10) * QUALITY_WEIGHT // Invert quality score
        ) / BASIS_POINTS;
        
        return RiskAssessment({
            projectRisk: projectRisk,
            verificationRisk: verificationRisk,
            regulatoryRisk: regulatoryRisk,
            marketRisk: marketRisk,
            overallRisk: overallRisk,
            qualityScore: qualityScore,
            volatilityScore: volatilityScore,
            timestamp: block.timestamp,
            assessmentMethod: "automated"
        });
    }
    
    /**
     * @dev Get policy information
     */
    function getPolicy(uint256 policyId) external view override validPolicy(policyId) returns (InsurancePolicy memory) {
        return policies[policyId];
    }
    
    /**
     * @dev Get claim information
     */
    function getClaim(uint256 claimId) external view override validClaim(claimId) returns (InsuranceClaim memory) {
        return claims[claimId];
    }
    
    /**
     * @dev Check if policy covers a specific type
     */
    function isPolicyCovered(
        uint256 policyId, 
        CoverageType coverageType
    ) public view override validPolicy(policyId) returns (bool) {
        CoverageType[] memory coverageTypes = policies[policyId].coverageTypes;
        for (uint256 i = 0; i < coverageTypes.length; i++) {
            if (coverageTypes[i] == coverageType) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Get remaining coverage amount
     */
    function getRemainingCoverage(uint256 policyId) external view override validPolicy(policyId) returns (uint256) {
        InsurancePolicy memory policy = policies[policyId];
        if (policy.status != PolicyStatus.ACTIVE || block.timestamp > policy.endTime) {
            return 0;
        }
        return policy.coverageAmount;
    }
    
    /**
     * @dev Internal function to calculate coverage amount based on token value
     */
    function _calculateCoverageAmount(uint256 tokenId, uint256 coveredAmount) internal view returns (uint256) {
        // Get batch info to determine project type
        EnhancedCarbonCredits.CarbonCreditBatch memory batch2 = carbonCredits.getBatchInfo(tokenId);

        // Estimate value using the carbon credits contract
        uint256 estimatedValue = carbonCredits.estimateOffsetValue(coveredAmount, batch2.projectType);
        
        // Apply maximum coverage ratio
        return (estimatedValue * MAX_COVERAGE_RATIO) / BASIS_POINTS;
    }
    
    /**
     * @dev Determine risk level from risk score
     */
    function _determineRiskLevel(uint256 riskScore) internal pure returns (RiskLevel) {
        if (riskScore <= 25) return RiskLevel.LOW;
        if (riskScore <= 50) return RiskLevel.MEDIUM;
        if (riskScore <= 75) return RiskLevel.HIGH;
        return RiskLevel.CRITICAL;
    }
    
    /**
     * @dev Check if claim requires governance review
     */
    function _requiresGovernance(CoverageType claimType, uint256 requestedPayout) internal pure returns (bool) {
        // Large claims or certain types require governance
        return requestedPayout > 100000 * 10**18 || // > 100k WRF
               claimType == CoverageType.REGULATORY_RISK ||
               claimType == CoverageType.INVALIDATION_COVER;
    }
    
    /**
     * @dev Assess project-specific risks
     */
    function _assessProjectRisk(
        string memory projectType, 
        string memory methodology, 
        uint256 vintage
    ) internal pure returns (uint256) {
        uint256 risk = 30; // Base risk
        
        // Project type adjustments
        if (keccak256(abi.encodePacked(projectType)) == keccak256("direct-air-capture")) {
            risk = 15; // Lower risk for high-tech projects
        } else if (keccak256(abi.encodePacked(projectType)) == keccak256("forestry")) {
            risk = 50; // Higher risk for nature-based solutions
        }
        
        // Vintage adjustments (older projects may have higher risk)
        if (vintage < 2020) {
            risk += 10;
        }
        
        return Math.min(risk, 100);
    }
    
    /**
     * @dev Assess verification and monitoring risks
     */
    function _assessVerificationRisk(
        string memory registryStandard, 
        string memory methodology
    ) internal pure returns (uint256) {
        uint256 risk = 25; // Base risk
        
        // Registry standard adjustments
        if (keccak256(abi.encodePacked(registryStandard)) == keccak256("VCS")) {
            risk -= 5; // VCS has robust verification
        } else if (keccak256(abi.encodePacked(registryStandard)) == keccak256("GS")) {
            risk -= 3; // Gold Standard is also strong
        }
        
        return Math.min(risk, 100);
    }
    
    /**
     * @dev Assess regulatory and political risks
     */
    function _assessRegulatoryRisk(string memory registryStandard, uint256 vintage) internal pure returns (uint256) {
        uint256 risk = 20; // Base risk
        
        // Newer regulations may be more stable
        if (vintage >= 2022) {
            risk -= 5;
        }
        
        return Math.min(risk, 100);
    }
    
    /**
     * @dev Assess market and demand risks
     */
    function _assessMarketRisk(uint256 tokenId) internal view returns (uint256) {
        uint256 risk = 15; // Base risk
        
        // Use volatility oracle data if available
        try volatilityOracle.getVolatility(address(carbonCredits), address(wrfToken)) returns (uint256 volatility) {
            // Higher volatility = higher risk
            risk += (volatility / 200); // Scale volatility to risk points
        } catch {
            // If oracle fails, use base risk
        }
        
        return Math.min(risk, 100);
    }
    
    /**
     * @dev Assess claim validity using oracle data
     */
    function _assessClaim(uint256 claimId) internal view returns (bool) {
        InsuranceClaim memory claim = claims[claimId];
        
        // For project failure claims, check if quality score has dropped significantly
        if (claim.claimType == CoverageType.PROJECT_FAILURE) {
            uint256 currentQuality = qualityOracle.getQualityScore(address(carbonCredits));
            return currentQuality < 300; // Below minimum threshold
        }
        
        // For verification risk claims, check data freshness and confidence
        if (claim.claimType == CoverageType.VERIFICATION_RISK) {
            return !qualityOracle.isQualityDataFresh(address(carbonCredits), 7 days);
        }
        
        // For regulatory risk, this would typically require manual review
        if (claim.claimType == CoverageType.REGULATORY_RISK) {
            return false; // Requires governance
        }
        
        // Default validation
        return true;
    }
    
    /**
     * @dev Update oracle addresses (admin only)
     */
    function updateOracles(
        address _qualityOracle,
        address _volatilityOracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_qualityOracle != address(0)) {
            qualityOracle = IQualityOracle(_qualityOracle);
        }
        if (_volatilityOracle != address(0)) {
            volatilityOracle = IVolatilityOracle(_volatilityOracle);
        }
    }
    
    /**
     * @dev Set insurance pool address
     */
    function setInsurancePool(address _insurancePool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        insurancePool = _insurancePool;
    }
    
    /**
     * @dev Set governance contract address
     */
    function setGovernanceContract(address _governanceContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        governanceContract = _governanceContract;
    }
    
    /**
     * @dev Update premium rates (risk manager only)
     */
    function updatePremiumRates(
        CoverageType coverageType,
        uint256 newRate
    ) external onlyRole(RISK_MANAGER_ROLE) {
        basePremiumRates[coverageType] = newRate;
    }
    
    /**
     * @dev Request emergency pause (M-of-N multisig)
     * Requires PAUSE_THRESHOLD guardians to approve before pausing.
     */
    function requestPause() external onlyRole(PAUSE_GUARDIAN_ROLE) whenNotPaused {
        uint256 nonce = pauseNonce;
        require(!pauseApprovals[nonce][msg.sender], "Already approved pause");
        pauseApprovals[nonce][msg.sender] = true;
        pauseApprovalCount++;
        emit PauseRequested(msg.sender);

        if (pauseApprovalCount >= PAUSE_THRESHOLD) {
            emit EmergencyPaused(pauseApprovalCount);
            _resetPauseApprovals();
            _pause();
        }
    }

    /**
     * @dev Request unpause (M-of-N multisig)
     * Requires PAUSE_THRESHOLD guardians to approve before unpausing.
     */
    function requestUnpause() external onlyRole(PAUSE_GUARDIAN_ROLE) whenPaused {
        uint256 nonce = unpauseNonce;
        require(!unpauseApprovals[nonce][msg.sender], "Already approved unpause");
        unpauseApprovals[nonce][msg.sender] = true;
        unpauseApprovalCount++;
        emit UnpauseRequested(msg.sender);

        if (unpauseApprovalCount >= PAUSE_THRESHOLD) {
            emit EmergencyUnpaused(unpauseApprovalCount);
            _resetUnpauseApprovals();
            _unpause();
        }
    }

    /**
     * @dev Reset pause approval state by incrementing the nonce.
     */
    function _resetPauseApprovals() internal {
        pauseApprovalCount = 0;
        pauseNonce++;
    }

    /**
     * @dev Reset unpause approval state by incrementing the nonce.
     */
    function _resetUnpauseApprovals() internal {
        unpauseApprovalCount = 0;
        unpauseNonce++;
    }
    
    /**
     * @dev Get user's policies
     */
    function getUserPolicies(address user) external view returns (uint256[] memory) {
        return userPolicies[user];
    }
    
    /**
     * @dev Get policies for a token
     */
    function getTokenPolicies(uint256 tokenId) external view returns (uint256[] memory) {
        return tokenPolicies[tokenId];
    }
}