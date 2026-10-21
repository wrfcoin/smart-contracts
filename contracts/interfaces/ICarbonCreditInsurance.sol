// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICarbonCreditInsurance
 * @dev Interface for carbon credit insurance protocol
 * Provides protection against project failure, verification issues, and regulatory risks
 */
interface ICarbonCreditInsurance {
    
    // Insurance coverage types
    enum CoverageType {
        PROJECT_FAILURE,      // Technical issues, natural disasters, abandonment
        VERIFICATION_RISK,    // Monitoring errors, fraud, methodology changes
        REGULATORY_RISK,      // Policy changes, invalidation by authorities
        DELIVERY_GUARANTEE,   // Failure to deliver promised credits
        INVALIDATION_COVER    // Credit invalidation by registry
    }
    
    // Risk levels for premium calculation
    enum RiskLevel {
        LOW,          // 0-25% risk score
        MEDIUM,       // 26-50% risk score
        HIGH,         // 51-75% risk score
        CRITICAL      // 76-100% risk score
    }
    
    // Policy status
    enum PolicyStatus {
        ACTIVE,
        EXPIRED,
        CLAIMED,
        CANCELLED,
        SUSPENDED
    }
    
    // Claim status
    enum ClaimStatus {
        PENDING,
        INVESTIGATING,
        APPROVED,
        REJECTED,
        PAID,
        DISPUTED
    }
    
    // Insurance policy structure
    struct InsurancePolicy {
        uint256 policyId;
        address policyholder;
        uint256 tokenId;              // EnhancedCarbonCredits token ID
        uint256 coveredAmount;        // Amount of credits covered (kg CO2e)
        CoverageType[] coverageTypes; // Types of coverage
        uint256 premiumAmount;        // Premium paid in WRF
        uint256 coverageAmount;       // Maximum payout in WRF
        uint256 startTime;
        uint256 endTime;
        PolicyStatus status;
        uint256 riskScore;            // 0-100 risk assessment
        RiskLevel riskLevel;
        string terms;                 // IPFS hash of policy terms
    }
    
    // Insurance claim structure
    struct InsuranceClaim {
        uint256 claimId;
        uint256 policyId;
        address claimant;
        CoverageType claimType;
        uint256 claimedAmount;        // Amount claimed (kg CO2e)
        uint256 requestedPayout;      // Requested payout in WRF
        uint256 approvedPayout;       // Approved payout amount
        ClaimStatus status;
        uint256 submissionTime;
        uint256 investigationDeadline;
        string evidence;              // IPFS hash of evidence documents
        string assessmentNotes;       // Assessment details
        bool requiresGovernance;      // Complex claims requiring governance
    }
    
    // Risk assessment data
    struct RiskAssessment {
        uint256 projectRisk;          // Technical and operational risks (0-100)
        uint256 verificationRisk;     // Verification and monitoring risks (0-100)
        uint256 regulatoryRisk;       // Regulatory and political risks (0-100)
        uint256 marketRisk;           // Market and demand risks (0-100)
        uint256 overallRisk;          // Weighted overall risk score (0-100)
        uint256 qualityScore;         // From QualityOracle (0-1000)
        uint256 volatilityScore;      // From VolatilityOracle (0-10000)
        uint256 timestamp;
        string assessmentMethod;      // "automated", "manual", "hybrid"
    }
    
    // Premium calculation structure
    struct PremiumData {
        uint256 basePremium;          // Base premium rate (basis points)
        uint256 riskAdjustment;       // Risk-based adjustment (basis points)
        uint256 qualityAdjustment;    // Quality-based adjustment (basis points)
        uint256 volatilityAdjustment; // Volatility-based adjustment (basis points)
        uint256 finalPremium;         // Final premium amount in WRF
        uint256 calculationTime;
    }
    
    // Events
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed policyholder,
        uint256 indexed tokenId,
        uint256 coveredAmount,
        uint256 premiumAmount,
        CoverageType[] coverageTypes
    );
    
    event PremiumPaid(
        uint256 indexed policyId,
        address indexed policyholder,
        uint256 amount
    );
    
    event ClaimSubmitted(
        uint256 indexed claimId,
        uint256 indexed policyId,
        address indexed claimant,
        CoverageType claimType,
        uint256 claimedAmount
    );
    
    event ClaimProcessed(
        uint256 indexed claimId,
        ClaimStatus status,
        uint256 payoutAmount
    );
    
    event PolicyStatusUpdated(
        uint256 indexed policyId,
        PolicyStatus oldStatus,
        PolicyStatus newStatus
    );
    
    event RiskAssessmentUpdated(
        uint256 indexed tokenId,
        uint256 newRiskScore,
        RiskLevel riskLevel
    );
    
    // Core functions
    function createPolicy(
        uint256 tokenId,
        uint256 coveredAmount,
        CoverageType[] calldata coverageTypes,
        uint256 duration,
        string calldata terms
    ) external returns (uint256 policyId);
    
    function payPremium(uint256 policyId) external;
    
    function submitClaim(
        uint256 policyId,
        CoverageType claimType,
        uint256 claimedAmount,
        string calldata evidence
    ) external returns (uint256 claimId);
    
    function processClaim(uint256 claimId) external;
    
    function calculatePremium(
        uint256 tokenId,
        uint256 coveredAmount,
        CoverageType[] calldata coverageTypes,
        uint256 duration
    ) external view returns (PremiumData memory);
    
    function assessRisk(uint256 tokenId) external view returns (RiskAssessment memory);
    
    function getPolicy(uint256 policyId) external view returns (InsurancePolicy memory);
    
    function getClaim(uint256 claimId) external view returns (InsuranceClaim memory);
    
    function isPolicyCovered(uint256 policyId, CoverageType coverageType) external view returns (bool);
    
    function getRemainingCoverage(uint256 policyId) external view returns (uint256);
}

/**
 * @title IInsurancePool
 * @dev Interface for insurance capital pool management
 */
interface IInsurancePool {
    
    struct PoolStats {
        uint256 totalCapital;         // Total pool capital in WRF
        uint256 availableCapital;     // Capital available for new policies
        uint256 reservedCapital;      // Capital reserved for active policies
        uint256 claimedCapital;       // Capital paid out in claims
        uint256 premiumsCollected;    // Total premiums collected
        uint256 totalPolicies;        // Total number of policies
        uint256 activePolicies;       // Currently active policies
        uint256 utilizationRate;      // Capital utilization rate (basis points)
        uint256 solvencyRatio;        // Solvency ratio (basis points)
    }
    
    struct CapitalProvider {
        uint256 contribution;         // Amount contributed to pool
        uint256 shares;               // Pool shares owned
        uint256 lastRewardClaim;      // Last reward claim timestamp
        uint256 totalRewards;         // Total rewards earned
        bool isActive;
    }
    
    event CapitalDeposited(address indexed provider, uint256 amount, uint256 shares);
    event CapitalWithdrawn(address indexed provider, uint256 amount, uint256 shares);
    event RewardsDistributed(uint256 totalRewards, uint256 timestamp);
    event RewardsClaimed(address indexed provider, uint256 amount);
    event PolicyReserved(uint256 indexed policyId, uint256 amount);
    event ClaimPaid(uint256 indexed claimId, uint256 amount);
    
    function depositCapital(uint256 amount) external returns (uint256 shares);
    function withdrawCapital(uint256 shares) external returns (uint256 amount);
    function claimRewards() external returns (uint256 rewards);
    function reserveCapital(uint256 policyId, uint256 amount) external;
    function releaseReserve(uint256 policyId) external;
    function payClaim(uint256 claimId, uint256 amount, address recipient) external;
    function distributeRewards() external;
    function getPoolStats() external view returns (PoolStats memory);
    function getProviderInfo(address provider) external view returns (CapitalProvider memory);
    function calculateShares(uint256 amount) external view returns (uint256 shares);
    function calculateWithdrawalAmount(uint256 shares) external view returns (uint256 amount);
}

/**
 * @title IInsuranceGovernance
 * @dev Interface for insurance governance and dispute resolution
 */
interface IInsuranceGovernance {
    
    enum ProposalType {
        CLAIM_DISPUTE,
        POLICY_TERMS_UPDATE,
        PREMIUM_ADJUSTMENT,
        COVERAGE_EXPANSION,
        RISK_MODEL_UPDATE
    }
    
    enum ProposalStatus {
        PENDING,
        ACTIVE,
        SUCCEEDED,
        DEFEATED,
        EXECUTED,
        CANCELLED
    }
    
    struct GovernanceProposal {
        uint256 proposalId;
        ProposalType proposalType;
        address proposer;
        uint256 claimId;              // For claim disputes
        string description;
        string evidence;              // IPFS hash
        uint256 votingStart;
        uint256 votingEnd;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        ProposalStatus status;
        bool executed;
    }
    
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType proposalType,
        string description
    );
    
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        bool support,
        uint256 weight,
        string reason
    );
    
    event ProposalExecuted(uint256 indexed proposalId);
    
    function propose(
        ProposalType proposalType,
        uint256 claimId,
        string calldata description,
        string calldata evidence
    ) external returns (uint256 proposalId);
    
    function vote(uint256 proposalId, bool support, string calldata reason) external;
    
    function execute(uint256 proposalId) external;
    
    function getProposal(uint256 proposalId) external view returns (GovernanceProposal memory);
    
    function getVotingPower(address account) external view returns (uint256);
    
    function hasVotedOnProposal(uint256 proposalId, address account) external view returns (bool);
}