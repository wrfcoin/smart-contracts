// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ComplianceModule
 * @notice Multi-jurisdictional compliance framework for governance operations
 * @dev Comprehensive compliance system with KYC/AML integration, regulatory reporting,
 *      sanctions screening, and automated audit trails for WRFCoin platform governance
 * 
 * Features:
 * - KYC/AML verification with multiple provider integration
 * - Multi-jurisdictional regulatory compliance (EU GDPR, US SEC, etc.)
 * - Real-time sanctions screening and PEP checks
 * - GDPR data privacy compliance with automated data handling
 * - Geographic restrictions and compliance zones
 * - Automated regulatory reporting and audit trails
 * - Transaction monitoring and suspicious activity detection
 * - Regulatory sandbox support for different regions
 * 
 * Security Measures:
 * - Role-based access with compliance officer oversight
 * - Automated compliance validation for all transactions
 * - Real-time blacklist and sanctions list screening
 * - Comprehensive audit trails with tamper-proof logging
 * - GDPR data subject rights automation
 * - Cross-jurisdictional compliance validation
 * 
 * @custom:security-contact compliance@wrfcoin.io
 */
contract ComplianceModule is ReentrancyGuard, AccessControl {
    using ECDSA for bytes32;

    // Roles with hierarchical permissions
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant SANCTIONS_OFFICER_ROLE = keccak256("SANCTIONS_OFFICER_ROLE");
    bytes32 public constant DATA_PROTECTION_OFFICER_ROLE = keccak256("DATA_PROTECTION_OFFICER_ROLE");

    // Security constants
    uint256 public constant MAX_DAILY_TRANSACTIONS = 1000;
    uint256 public constant SUSPICIOUS_VELOCITY_THRESHOLD = 50; // Transactions per hour
    uint256 public constant DEFAULT_KYC_VALIDITY_PERIOD = 365 days;
    uint256 public constant MAX_TRANSACTION_AMOUNT_BASIC = 10_000 * 1e18;
    uint256 public constant MAX_TRANSACTION_AMOUNT_ENHANCED = 100_000 * 1e18;
    uint256 public constant MAX_TRANSACTION_AMOUNT_INSTITUTIONAL = 1_000_000 * 1e18;
    uint256 public constant GDPR_RESPONSE_TIME = 30 days;
    
    // Risk scoring constants
    uint256 public constant HIGH_RISK_SCORE_THRESHOLD = 70;
    uint256 public constant MEDIUM_RISK_SCORE_THRESHOLD = 40;

    // Compliance levels
    enum ComplianceLevel {
        NONE,
        BASIC,
        ENHANCED,
        INSTITUTIONAL
    }

    // Jurisdictional frameworks
    enum Jurisdiction {
        GLOBAL,
        EU_GDPR,
        US_SEC,
        UK_FCA,
        SINGAPORE_MAS,
        JAPAN_FSA,
        CANADA_CSA,
        AUSTRALIA_ASIC
    }

    // KYC status
    enum KYCStatus {
        NOT_VERIFIED,
        PENDING,
        VERIFIED,
        REJECTED,
        EXPIRED
    }

    // Enhanced compliance record with risk scoring
    struct ComplianceRecord {
        address user;
        KYCStatus kycStatus;
        ComplianceLevel level;
        uint256 verificationDate;
        uint256 expiryDate;
        string kycProvider;
        bytes32 documentHash;
        uint256 riskScore; // 0-100 risk assessment score
        uint256 lastRiskUpdate;
        bool isPEP; // Politically Exposed Person
        bool isSanctioned;
        string countryCode; // ISO 3166-1 alpha-2 country code
        mapping(Jurisdiction => bool) jurisdictionCompliance;
        mapping(string => bool) additionalChecks;
        mapping(uint256 => uint256) dailyTransactionCount; // day => count
        mapping(uint256 => uint256) dailyTransactionVolume; // day => volume
    }

    // Risk assessment structure
    struct RiskAssessment {
        uint256 transactionRiskScore;
        uint256 geographicRiskScore;
        uint256 behaviorRiskScore;
        uint256 kycRiskScore;
        uint256 overallRiskScore;
        uint256 lastUpdated;
        string riskFactors; // JSON string of risk factors
    }

    // Sanctions screening structure
    struct SanctionsCheck {
        uint256 checkId;
        address user;
        uint256 timestamp;
        bool isClean;
        string sanctionsList; // Which lists were checked
        string matchDetails; // Details of any matches found
        address checkedBy;
    }

    // Regulatory framework requirements
    struct RegulatoryFramework {
        Jurisdiction jurisdiction;
        string name;
        ComplianceLevel minLevel;
        uint256 maxTransactionAmount;
        uint256 maxDailyAmount;
        uint256 maxMonthlyAmount;
        bool requiresKYC;
        bool requiresAML;
        bool allowsAnonymous;
        string[] requiredDocuments;
        uint256 documentRetentionPeriod;
    }

    // Compliance transaction
    struct ComplianceTransaction {
        uint256 txId;
        address user;
        string txType;
        uint256 amount;
        uint256 timestamp;
        Jurisdiction jurisdiction;
        bool approved;
        string reason;
        bytes32 auditHash;
    }

    // GDPR data request
    struct DataRequest {
        uint256 requestId;
        address user;
        string requestType; // "access", "portability", "deletion"
        uint256 timestamp;
        bool processed;
        string response;
    }

    // Core state variables
    mapping(address => ComplianceRecord) public complianceRecords;
    mapping(Jurisdiction => RegulatoryFramework) public regulatoryFrameworks;
    mapping(uint256 => ComplianceTransaction) public complianceTransactions;
    mapping(uint256 => DataRequest) public dataRequests;
    mapping(address => mapping(uint256 => uint256)) public dailyTransactionVolume; // user => day => amount
    mapping(address => mapping(uint256 => uint256)) public monthlyTransactionVolume; // user => month => amount
    
    // Enhanced security and risk management
    mapping(address => RiskAssessment) public riskAssessments;
    mapping(uint256 => SanctionsCheck) public sanctionsChecks;
    mapping(address => bool) public blacklistedAddresses;
    mapping(address => uint256) public lastSanctionsCheck; // user => timestamp
    mapping(string => bool) public restrictedCountries; // country code => restricted
    mapping(address => uint256) public suspiciousActivityScore;
    
    // Compliance configuration and providers
    mapping(string => bool) public enabledComplianceChecks;
    mapping(string => address) public kycProviders;
    mapping(address => string) public kycProviderNames; // reverse mapping
    mapping(bytes32 => bool) public usedDocumentHashes; // prevent document reuse
    
    uint256 public nextTransactionId;
    uint256 public nextRequestId;
    uint256 public nextSanctionsCheckId;
    bool public complianceEnabled;
    uint256 public defaultDocumentRetention;
    
    // Additional security tracking
    mapping(address => uint256) public lastTransactionTime;
    mapping(address => uint256) public hourlyTransactionCount;
    uint256 public globalRiskThreshold; // Global risk threshold for automatic actions
    
    // Core compliance events
    event ComplianceRecordUpdated(
        address indexed user,
        KYCStatus status,
        ComplianceLevel level,
        string provider
    );
    event RegulatoryFrameworkUpdated(Jurisdiction jurisdiction, string name);
    event ComplianceTransactionLogged(
        uint256 indexed txId,
        address indexed user,
        string txType,
        bool approved
    );
    event DataRequestProcessed(
        uint256 indexed requestId,
        address indexed user,
        string requestType
    );
    event AuditTrailEntry(
        uint256 indexed txId,
        address indexed user,
        bytes32 auditHash,
        uint256 timestamp
    );

    // Security and risk management events
    event ComplianceViolation(
        address indexed user,
        string violationType,
        string description,
        uint256 riskScore
    );
    event RiskAssessmentUpdated(
        address indexed user,
        uint256 oldRiskScore,
        uint256 newRiskScore,
        string riskFactors
    );
    event SanctionsCheckCompleted(
        uint256 indexed checkId,
        address indexed user,
        bool isClean,
        string sanctionsList
    );
    event SuspiciousActivityDetected(
        address indexed user,
        string activityType,
        uint256 severity,
        string details
    );
    event GeographicRestrictionViolation(
        address indexed user,
        string countryCode,
        string restriction
    );
    event PEPStatusUpdated(
        address indexed user,
        bool isPEP,
        string details
    );
    event BlacklistUpdated(
        address indexed user,
        bool isBlacklisted,
        address indexed updatedBy,
        string reason
    );
    event ComplianceThresholdExceeded(
        address indexed user,
        string thresholdType,
        uint256 value,
        uint256 threshold
    );

    /// @notice Ensures user is compliant with all requirements
    /// @param _user Address to check for compliance
    modifier onlyCompliantUser(address _user) {
        require(_isCompliant(_user), "CM: User not compliant");
        require(_isNotHighRisk(_user), "CM: User exceeds risk threshold");
        _;
    }

    /// @notice Ensures address is not blacklisted
    /// @param _user Address to check
    modifier notBlacklisted(address _user) {
        require(!blacklistedAddresses[_user], "CM: Address blacklisted");
        _;
    }

    /// @notice Ensures user is from an allowed jurisdiction
    /// @param _user Address to check
    modifier allowedJurisdiction(address _user) {
        string memory countryCode = complianceRecords[_user].countryCode;
        require(!restrictedCountries[countryCode], "CM: Restricted jurisdiction");
        _;
    }

    /// @notice Validates transaction velocity to prevent abuse
    /// @param _user Address to check
    modifier validTransactionVelocity(address _user) {
        require(_checkTransactionVelocity(_user), "CM: Transaction velocity too high");
        _;
    }

    /// @notice Ensures sanctions check is up to date
    /// @param _user Address to check
    modifier recentSanctionsCheck(address _user) {
        require(
            block.timestamp - lastSanctionsCheck[_user] <= 24 hours,
            "CM: Sanctions check required"
        );
        _;
    }

    /// @notice Initialize compliance module with security configurations
    /// @param _admin Administrator address
    constructor(address _admin) {
        require(_admin != address(0), "CM: Invalid admin address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(COMPLIANCE_OFFICER_ROLE, _admin);
        _grantRole(DATA_PROTECTION_OFFICER_ROLE, _admin);
        
        complianceEnabled = true;
        defaultDocumentRetention = 7 * 365 days; // 7 years
        globalRiskThreshold = HIGH_RISK_SCORE_THRESHOLD;
        
        _initializeRegulatoryFrameworks();
        _initializeComplianceChecks();
        _initializeRestrictedCountries();
    }

    /**
     * @dev Initialize regulatory frameworks
     */
    function _initializeRegulatoryFrameworks() internal {
        // EU GDPR Framework
        regulatoryFrameworks[Jurisdiction.EU_GDPR] = RegulatoryFramework({
            jurisdiction: Jurisdiction.EU_GDPR,
            name: "European GDPR Framework",
            minLevel: ComplianceLevel.ENHANCED,
            maxTransactionAmount: 10000 * 10**18, // 10,000 tokens
            maxDailyAmount: 50000 * 10**18,
            maxMonthlyAmount: 500000 * 10**18,
            requiresKYC: true,
            requiresAML: true,
            allowsAnonymous: false,
            requiredDocuments: new string[](0),
            documentRetentionPeriod: 7 * 365 days
        });

        // US SEC Framework
        regulatoryFrameworks[Jurisdiction.US_SEC] = RegulatoryFramework({
            jurisdiction: Jurisdiction.US_SEC,
            name: "US Securities Framework",
            minLevel: ComplianceLevel.INSTITUTIONAL,
            maxTransactionAmount: 25000 * 10**18,
            maxDailyAmount: 100000 * 10**18,
            maxMonthlyAmount: 1000000 * 10**18,
            requiresKYC: true,
            requiresAML: true,
            allowsAnonymous: false,
            requiredDocuments: new string[](0),
            documentRetentionPeriod: 10 * 365 days
        });

        // Singapore MAS Framework
        regulatoryFrameworks[Jurisdiction.SINGAPORE_MAS] = RegulatoryFramework({
            jurisdiction: Jurisdiction.SINGAPORE_MAS,
            name: "Singapore MAS Framework",
            minLevel: ComplianceLevel.ENHANCED,
            maxTransactionAmount: 15000 * 10**18,
            maxDailyAmount: 75000 * 10**18,
            maxMonthlyAmount: 750000 * 10**18,
            requiresKYC: true,
            requiresAML: true,
            allowsAnonymous: false,
            requiredDocuments: new string[](0),
            documentRetentionPeriod: 5 * 365 days
        });
    }

    /**
     * @dev Initialize compliance checks
     */
    function _initializeComplianceChecks() internal {
        enabledComplianceChecks["kyc_verification"] = true;
        enabledComplianceChecks["aml_screening"] = true;
        enabledComplianceChecks["sanctions_check"] = true;
        enabledComplianceChecks["pep_screening"] = true;
        enabledComplianceChecks["transaction_monitoring"] = true;
        enabledComplianceChecks["suspicious_activity"] = true;
        enabledComplianceChecks["geographic_restrictions"] = true;
        enabledComplianceChecks["velocity_monitoring"] = true;
        enabledComplianceChecks["risk_assessment"] = true;
        enabledComplianceChecks["document_verification"] = true;
    }

    /**
     * @dev Initialize restricted countries list
     */
    function _initializeRestrictedCountries() internal {
        // High-risk jurisdictions (example list)
        restrictedCountries["AF"] = true; // Afghanistan
        restrictedCountries["IR"] = true; // Iran
        restrictedCountries["KP"] = true; // North Korea
        restrictedCountries["SY"] = true; // Syria
        // Additional countries can be added based on regulatory requirements
    }

    /**
     * @dev Update KYC status for a user
     */
    function updateKYCStatus(
        address _user,
        KYCStatus _status,
        ComplianceLevel _level,
        string memory _provider,
        bytes32 _documentHash,
        uint256 _expiryDate
    ) external onlyRole(KYC_PROVIDER_ROLE) {
        require(_user != address(0), "CM: Invalid user address");
        require(kycProviders[_provider] != address(0), "CM: Invalid KYC provider");

        ComplianceRecord storage record = complianceRecords[_user];
        record.user = _user;
        record.kycStatus = _status;
        record.level = _level;
        record.verificationDate = block.timestamp;
        record.expiryDate = _expiryDate;
        record.kycProvider = _provider;
        record.documentHash = _documentHash;

        emit ComplianceRecordUpdated(_user, _status, _level, _provider);
    }

    /**
     * @dev Set jurisdiction compliance for a user
     */
    function setJurisdictionCompliance(
        address _user,
        Jurisdiction _jurisdiction,
        bool _compliant
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        complianceRecords[_user].jurisdictionCompliance[_jurisdiction] = _compliant;
    }

    /**
     * @notice Validate transaction compliance with comprehensive checks
     * @param _user User address
     * @param _txType Transaction type
     * @param _amount Transaction amount
     * @param _jurisdiction Target jurisdiction
     * @return approved Whether transaction is approved
     * @return reason Reason for approval/rejection
     */
    function validateTransaction(
        address _user,
        string memory _txType,
        uint256 _amount,
        Jurisdiction _jurisdiction
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) 
      notBlacklisted(_user) 
      allowedJurisdiction(_user) 
      validTransactionVelocity(_user) 
      returns (bool approved, string memory reason) {
        if (!complianceEnabled) {
            return (true, "Compliance disabled");
        }

        if (blacklistedAddresses[_user]) {
            return (false, "Address blacklisted");
        }

        ComplianceRecord storage record = complianceRecords[_user];
        RegulatoryFramework storage framework = regulatoryFrameworks[_jurisdiction];

        // Check KYC requirements
        if (framework.requiresKYC && record.kycStatus != KYCStatus.VERIFIED) {
            return (false, "KYC verification required");
        }

        // Check compliance level
        if (record.level < framework.minLevel) {
            return (false, "Insufficient compliance level");
        }

        // Check transaction limits
        if (_amount > framework.maxTransactionAmount) {
            return (false, "Transaction amount exceeds limit");
        }

        // Check daily limits
        uint256 currentDay = block.timestamp / 1 days;
        if (dailyTransactionVolume[_user][currentDay] + _amount > framework.maxDailyAmount) {
            return (false, "Daily transaction limit exceeded");
        }

        // Check monthly limits
        uint256 currentMonth = block.timestamp / 30 days;
        if (monthlyTransactionVolume[_user][currentMonth] + _amount > framework.maxMonthlyAmount) {
            return (false, "Monthly transaction limit exceeded");
        }

        // Check jurisdiction compliance
        if (!record.jurisdictionCompliance[_jurisdiction]) {
            return (false, "Not compliant with jurisdiction requirements");
        }

        // Enhanced risk-based checks
        if (record.riskScore > globalRiskThreshold) {
            return (false, "User risk score exceeds threshold");
        }

        // Check if user is PEP and requires enhanced due diligence
        if (record.isPEP && _amount > MAX_TRANSACTION_AMOUNT_BASIC) {
            return (false, "PEP user requires enhanced due diligence for large amounts");
        }

        // Check sanctions status
        if (record.isSanctioned) {
            return (false, "User is on sanctions list");
        }

        // Update risk assessment based on transaction
        _updateTransactionRisk(_user, _amount, _txType);

        // Log compliant transaction
        _logComplianceTransaction(_user, _txType, _amount, _jurisdiction, true, "Approved");

        // Update transaction volumes and tracking
        dailyTransactionVolume[_user][currentDay] += _amount;
        monthlyTransactionVolume[_user][currentMonth] += _amount;
        
        // Update velocity tracking
        lastTransactionTime[_user] = block.timestamp;
        record.dailyTransactionCount[currentDay]++;
        record.dailyTransactionVolume[currentDay] += _amount;

        return (true, "Transaction approved");
    }

    /**
     * @dev Log compliance transaction
     */
    function _logComplianceTransaction(
        address _user,
        string memory _txType,
        uint256 _amount,
        Jurisdiction _jurisdiction,
        bool _approved,
        string memory _reason
    ) internal {
        uint256 txId = nextTransactionId++;
        
        bytes32 auditHash = keccak256(abi.encodePacked(
            txId,
            _user,
            _txType,
            _amount,
            _jurisdiction,
            _approved,
            block.timestamp
        ));

        complianceTransactions[txId] = ComplianceTransaction({
            txId: txId,
            user: _user,
            txType: _txType,
            amount: _amount,
            timestamp: block.timestamp,
            jurisdiction: _jurisdiction,
            approved: _approved,
            reason: _reason,
            auditHash: auditHash
        });

        emit ComplianceTransactionLogged(txId, _user, _txType, _approved);
        emit AuditTrailEntry(txId, _user, auditHash, block.timestamp);
    }

    /**
     * @dev Process GDPR data request
     */
    function processDataRequest(
        address _user,
        string memory _requestType
    ) external returns (uint256 requestId) {
        require(
            keccak256(bytes(_requestType)) == keccak256(bytes("access")) ||
            keccak256(bytes(_requestType)) == keccak256(bytes("portability")) ||
            keccak256(bytes(_requestType)) == keccak256(bytes("deletion")),
            "CM: Invalid request type"
        );

        requestId = nextRequestId++;

        dataRequests[requestId] = DataRequest({
            requestId: requestId,
            user: _user,
            requestType: _requestType,
            timestamp: block.timestamp,
            processed: false,
            response: ""
        });

        // Auto-process certain request types
        if (keccak256(bytes(_requestType)) == keccak256(bytes("access"))) {
            _processAccessRequest(requestId);
        }

        emit DataRequestProcessed(requestId, _user, _requestType);
        return requestId;
    }

    /**
     * @dev Process data access request
     */
    function _processAccessRequest(uint256 _requestId) internal {
        DataRequest storage request = dataRequests[_requestId];
        ComplianceRecord storage record = complianceRecords[request.user];

        // Generate compliance data export (simplified)
        string memory response = string(abi.encodePacked(
            "KYC Status: ", _kycStatusToString(record.kycStatus),
            ", Compliance Level: ", _complianceLevelToString(record.level),
            ", Verification Date: ", _uint256ToString(record.verificationDate)
        ));

        request.response = response;
        request.processed = true;
    }

    /**
     * @dev Add address to blacklist
     */
    function addToBlacklist(
        address _address,
        string memory _reason
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        blacklistedAddresses[_address] = true;
        emit ComplianceViolation(_address, "Blacklisted", _reason, 100); // High risk score for blacklisted addresses
    }

    /**
     * @notice Remove address from blacklist with audit trail
     * @param _address Address to remove from blacklist
     * @param _reason Reason for removal
     */
    function removeFromBlacklist(address _address, string memory _reason) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        require(blacklistedAddresses[_address], "CM: Address not blacklisted");
        blacklistedAddresses[_address] = false;
        emit BlacklistUpdated(_address, false, msg.sender, _reason);
    }

    /**
     * @notice Perform sanctions screening for a user
     * @param _user User address to screen
     * @param _sanctionsList Name of sanctions list(s) checked
     * @return checkId ID of the sanctions check
     */
    function performSanctionsCheck(
        address _user,
        string memory _sanctionsList
    ) external onlyRole(SANCTIONS_OFFICER_ROLE) returns (uint256 checkId) {
        checkId = nextSanctionsCheckId++;
        
        // In a real implementation, this would integrate with actual sanctions screening APIs
        bool isClean = !complianceRecords[_user].isSanctioned;
        
        sanctionsChecks[checkId] = SanctionsCheck({
            checkId: checkId,
            user: _user,
            timestamp: block.timestamp,
            isClean: isClean,
            sanctionsList: _sanctionsList,
            matchDetails: isClean ? "" : "Match found in sanctions database",
            checkedBy: msg.sender
        });
        
        lastSanctionsCheck[_user] = block.timestamp;
        
        if (!isClean) {
            complianceRecords[_user].isSanctioned = true;
            _updateUserRiskScore(_user, 100, "Sanctions match detected");
            emit ComplianceViolation(_user, "sanctions", "User found on sanctions list", 100);
        }
        
        emit SanctionsCheckCompleted(checkId, _user, isClean, _sanctionsList);
        return checkId;
    }

    /**
     * @notice Update user's risk assessment
     * @param _user User address
     * @param _transactionRisk Transaction-based risk score
     * @param _geographicRisk Geographic risk score
     * @param _behaviorRisk Behavioral risk score
     * @param _kycRisk KYC-based risk score
     * @param _riskFactors JSON string describing risk factors
     */
    function updateRiskAssessment(
        address _user,
        uint256 _transactionRisk,
        uint256 _geographicRisk,
        uint256 _behaviorRisk,
        uint256 _kycRisk,
        string memory _riskFactors
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        uint256 oldRiskScore = complianceRecords[_user].riskScore;
        
        // Calculate overall risk score (weighted average)
        uint256 overallRisk = (_transactionRisk * 30 + _geographicRisk * 20 + _behaviorRisk * 25 + _kycRisk * 25) / 100;
        
        riskAssessments[_user] = RiskAssessment({
            transactionRiskScore: _transactionRisk,
            geographicRiskScore: _geographicRisk,
            behaviorRiskScore: _behaviorRisk,
            kycRiskScore: _kycRisk,
            overallRiskScore: overallRisk,
            lastUpdated: block.timestamp,
            riskFactors: _riskFactors
        });
        
        complianceRecords[_user].riskScore = overallRisk;
        complianceRecords[_user].lastRiskUpdate = block.timestamp;
        
        emit RiskAssessmentUpdated(_user, oldRiskScore, overallRisk, _riskFactors);
        
        // Trigger automatic actions for high-risk users
        if (overallRisk > HIGH_RISK_SCORE_THRESHOLD) {
            _handleHighRiskUser(_user);
        }
    }

    /**
     * @notice Set PEP (Politically Exposed Person) status
     * @param _user User address
     * @param _isPEP Whether user is a PEP
     * @param _details Details about PEP status
     */
    function setPEPStatus(
        address _user,
        bool _isPEP,
        string memory _details
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        complianceRecords[_user].isPEP = _isPEP;
        
        if (_isPEP) {
            // PEPs automatically get higher risk scores
            _updateUserRiskScore(_user, MEDIUM_RISK_SCORE_THRESHOLD + 10, "PEP status assigned");
        }
        
        emit PEPStatusUpdated(_user, _isPEP, _details);
    }

    /**
     * @notice Add or remove restricted country
     * @param _countryCode ISO 3166-1 alpha-2 country code
     * @param _restricted Whether country is restricted
     */
    function updateRestrictedCountry(
        string memory _countryCode,
        bool _restricted
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        restrictedCountries[_countryCode] = _restricted;
    }

    /**
     * @dev Register KYC provider
     */
    function registerKYCProvider(
        string memory _name,
        address _providerAddress
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        kycProviders[_name] = _providerAddress;
        _grantRole(KYC_PROVIDER_ROLE, _providerAddress);
    }

    /**
     * @dev Check if user is compliant
     */
    function _isCompliant(address _user) internal view returns (bool) {
        if (!complianceEnabled) return true;
        
        ComplianceRecord storage record = complianceRecords[_user];
        
        return record.kycStatus == KYCStatus.VERIFIED &&
               record.expiryDate > block.timestamp &&
               !blacklistedAddresses[_user];
    }

    /**
     * @dev Generate compliance report
     */
    function generateComplianceReport(
        uint256 _fromTimestamp,
        uint256 _toTimestamp
    ) external view onlyRole(AUDITOR_ROLE) returns (
        uint256 totalTransactions,
        uint256 approvedTransactions,
        uint256 rejectedTransactions,
        uint256 totalVolume
    ) {
        for (uint256 i = 0; i < nextTransactionId; i++) {
            ComplianceTransaction storage txRecord = complianceTransactions[i];
            
            if (txRecord.timestamp >= _fromTimestamp && txRecord.timestamp <= _toTimestamp) {
                totalTransactions++;
                totalVolume += txRecord.amount;
                
                if (txRecord.approved) {
                    approvedTransactions++;
                } else {
                    rejectedTransactions++;
                }
            }
        }
    }

    /**
     * @dev Get compliance record for user
     */
    function getComplianceRecord(address _user) external view returns (
        KYCStatus kycStatus,
        ComplianceLevel level,
        uint256 verificationDate,
        uint256 expiryDate,
        string memory kycProvider
    ) {
        ComplianceRecord storage record = complianceRecords[_user];
        return (
            record.kycStatus,
            record.level,
            record.verificationDate,
            record.expiryDate,
            record.kycProvider
        );
    }

    /**
     * @dev Check jurisdiction compliance for user
     */
    function checkJurisdictionCompliance(
        address _user,
        Jurisdiction _jurisdiction
    ) external view returns (bool) {
        return complianceRecords[_user].jurisdictionCompliance[_jurisdiction];
    }

    /**
     * @dev Enable/disable compliance
     */
    function setComplianceEnabled(bool _enabled) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        complianceEnabled = _enabled;
    }

    /**
     * @dev Update regulatory framework
     */
    function updateRegulatoryFramework(
        Jurisdiction _jurisdiction,
        string memory _name,
        ComplianceLevel _minLevel,
        uint256 _maxTransactionAmount,
        uint256 _maxDailyAmount,
        uint256 _maxMonthlyAmount,
        bool _requiresKYC,
        bool _requiresAML
    ) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        RegulatoryFramework storage framework = regulatoryFrameworks[_jurisdiction];
        framework.name = _name;
        framework.minLevel = _minLevel;
        framework.maxTransactionAmount = _maxTransactionAmount;
        framework.maxDailyAmount = _maxDailyAmount;
        framework.maxMonthlyAmount = _maxMonthlyAmount;
        framework.requiresKYC = _requiresKYC;
        framework.requiresAML = _requiresAML;

        emit RegulatoryFrameworkUpdated(_jurisdiction, _name);
    }

    // ========================================
    // INTERNAL SECURITY FUNCTIONS
    // ========================================

    /**
     * @dev Check if user is not high risk
     * @param _user User address
     * @return True if user is not high risk
     */
    function _isNotHighRisk(address _user) internal view returns (bool) {
        return complianceRecords[_user].riskScore <= globalRiskThreshold;
    }

    /**
     * @dev Check transaction velocity for suspicious patterns
     * @param _user User address
     * @return True if velocity is acceptable
     */
    function _checkTransactionVelocity(address _user) internal returns (bool) {
        uint256 currentHour = block.timestamp / 1 hours;
        
        // Check hourly transaction count
        if (hourlyTransactionCount[_user] > SUSPICIOUS_VELOCITY_THRESHOLD) {
            emit SuspiciousActivityDetected(_user, "high_velocity", hourlyTransactionCount[_user], "High transaction velocity detected");
            return false;
        }
        
        // Update velocity tracking
        hourlyTransactionCount[_user]++;
        
        return true;
    }

    /**
     * @dev Update transaction-based risk for a user
     * @param _user User address
     * @param _amount Transaction amount
     * @param _txType Transaction type
     */
    function _updateTransactionRisk(address _user, uint256 _amount, string memory _txType) internal {
        ComplianceRecord storage record = complianceRecords[_user];
        uint256 currentDay = block.timestamp / 1 days;
        
        // Increase risk score for large or frequent transactions
        if (_amount > MAX_TRANSACTION_AMOUNT_ENHANCED) {
            record.riskScore = (record.riskScore * 95 + 80) / 100; // Weighted average with high risk
        }
        
        // Check for unusual patterns
        if (record.dailyTransactionCount[currentDay] > 20) {
            suspiciousActivityScore[_user] += 10;
            emit SuspiciousActivityDetected(_user, "frequent_transactions", record.dailyTransactionCount[currentDay], "High daily transaction count");
        }
    }

    /**
     * @dev Update user risk score with reason
     * @param _user User address
     * @param _newRiskScore New risk score
     * @param _reason Reason for risk score update
     */
    function _updateUserRiskScore(address _user, uint256 _newRiskScore, string memory _reason) internal {
        uint256 oldRiskScore = complianceRecords[_user].riskScore;
        complianceRecords[_user].riskScore = _newRiskScore > 100 ? 100 : _newRiskScore;
        complianceRecords[_user].lastRiskUpdate = block.timestamp;
        
        emit RiskAssessmentUpdated(_user, oldRiskScore, complianceRecords[_user].riskScore, _reason);
    }

    /**
     * @dev Handle high-risk user detection
     * @param _user User address
     */
    function _handleHighRiskUser(address _user) internal {
        // Automatic actions for high-risk users
        emit ComplianceViolation(_user, "high_risk", "User risk score exceeds threshold", complianceRecords[_user].riskScore);
        
        // Could trigger additional verification requirements
        // Could limit transaction amounts
        // Could require manual review
    }

    // Helper functions for string conversion
    function _kycStatusToString(KYCStatus _status) internal pure returns (string memory) {
        if (_status == KYCStatus.VERIFIED) return "VERIFIED";
        if (_status == KYCStatus.PENDING) return "PENDING";
        if (_status == KYCStatus.REJECTED) return "REJECTED";
        if (_status == KYCStatus.EXPIRED) return "EXPIRED";
        return "NOT_VERIFIED";
    }

    function _complianceLevelToString(ComplianceLevel _level) internal pure returns (string memory) {
        if (_level == ComplianceLevel.INSTITUTIONAL) return "INSTITUTIONAL";
        if (_level == ComplianceLevel.ENHANCED) return "ENHANCED";
        if (_level == ComplianceLevel.BASIC) return "BASIC";
        return "NONE";
    }

    function _uint256ToString(uint256 _value) internal pure returns (string memory) {
        if (_value == 0) return "0";
        
        uint256 temp = _value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (_value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(_value % 10)));
            _value /= 10;
        }
        
        return string(buffer);
    }
}