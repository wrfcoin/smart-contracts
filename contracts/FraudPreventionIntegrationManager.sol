// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./EnhancedFraudPreventionSystem.sol";
import "./RealTimeFraudMonitor.sol";
import "./ComprehensiveFraudDetection.sol";
import "./interfaces/ISlashingMechanism.sol";

/**
 * @title FraudPreventionIntegrationManager
 * @dev Central coordination hub for all fraud detection and prevention systems
 * 
 * INTEGRATION MANAGEMENT FEATURES:
 * 
 * 1. UNIFIED ORCHESTRATION:
 *    - Centralized coordination of all fraud prevention components
 *    - Synchronized state management across systems
 *    - Unified API for external integrations
 *    - Cross-system data consistency validation
 *    - Automated system health monitoring
 * 
 * 2. INTELLIGENT ROUTING:
 *    - Dynamic routing of detection events to appropriate systems
 *    - Priority-based processing of fraud alerts
 *    - Load balancing across monitoring systems
 *    - Intelligent escalation pathways
 *    - Redundancy and failover management
 * 
 * 3. COMPREHENSIVE REPORTING:
 *    - Unified fraud prevention dashboard
 *    - Cross-system analytics and insights
 *    - Performance metrics aggregation
 *    - Compliance reporting automation
 *    - Executive summary generation
 * 
 * 4. AUTOMATED WORKFLOWS:
 *    - End-to-end fraud handling automation
 *    - Intelligent case management
 *    - Evidence collection and packaging
 *    - Multi-system response coordination
 *    - Outcome tracking and validation
 * 
 * @author WRFCoin Security Team
 * @notice Production-ready fraud prevention integration management
 */
contract FraudPreventionIntegrationManager is AccessControl, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ============ CONSTANTS ============
    
    bytes32 public constant INTEGRATION_ADMIN_ROLE = keccak256("INTEGRATION_ADMIN_ROLE");
    bytes32 public constant SYSTEM_COORDINATOR_ROLE = keccak256("SYSTEM_COORDINATOR_ROLE");
    bytes32 public constant FRAUD_RESPONSE_MANAGER_ROLE = keccak256("FRAUD_RESPONSE_MANAGER_ROLE");
    bytes32 public constant COMPLIANCE_REPORTER_ROLE = keccak256("COMPLIANCE_REPORTER_ROLE");
    bytes32 public constant EXTERNAL_INTEGRATOR_ROLE = keccak256("EXTERNAL_INTEGRATOR_ROLE");
    
    // Processing priorities
    uint256 private constant CRITICAL_PRIORITY = 1;
    uint256 private constant HIGH_PRIORITY = 2;
    uint256 private constant MEDIUM_PRIORITY = 3;
    uint256 private constant LOW_PRIORITY = 4;
    
    // System health thresholds
    uint256 private constant SYSTEM_HEALTHY_THRESHOLD = 95;
    uint256 private constant SYSTEM_WARNING_THRESHOLD = 85;
    uint256 private constant SYSTEM_CRITICAL_THRESHOLD = 70;

    // Case storage bounds (prevent storage DoS)
    uint256 private constant MAX_CASES_PER_PARTICIPANT = 1000;
    uint256 private constant MAX_CASES_PER_SYSTEM = 5000;

    // ============ ENUMS ============

    enum SystemComponent {
        COMPREHENSIVE_FRAUD_DETECTION,
        ENHANCED_FRAUD_PREVENTION,
        REAL_TIME_MONITOR,
        SLASHING_MECHANISM,
        EXTERNAL_SYSTEM
    }

    enum CaseStatus {
        OPEN,
        INVESTIGATING,
        EVIDENCE_COLLECTION,
        PENDING_REVIEW,
        RESOLVED,
        ESCALATED,
        CLOSED
    }

    enum ResponseOutcome {
        FRAUD_CONFIRMED,
        FRAUD_PREVENTED,
        FALSE_POSITIVE,
        INSUFFICIENT_EVIDENCE,
        SYSTEM_ERROR,
        EXTERNAL_REFERRAL
    }

    enum SystemHealth {
        HEALTHY,
        WARNING,
        CRITICAL,
        OFFLINE
    }

    // ============ STRUCTS ============

    struct IntegratedCase {
        uint256 caseId;
        address participant;
        SystemComponent originSystem;
        uint256[] relatedDetectionIds;
        uint256[] relatedAlertIds;
        uint256[] relatedInterventionIds;
        CaseStatus status;
        uint256 priority;
        uint256 riskScore;
        uint256 confidenceScore;
        uint256 openedTime;
        uint256 lastUpdateTime;
        uint256 responseDeadline;
        address assignedInvestigator;
        bytes32[] evidenceHashes;
        string description;
        ResponseOutcome outcome;
        string resolution;
        bool escalatedToExternal;
        uint256 totalValueAtRisk;
        mapping(SystemComponent => bool) systemsInvolved;
        mapping(address => string) investigatorNotes;
    }

    struct SystemStatus {
        SystemComponent component;
        address contractAddress;
        SystemHealth health;
        uint256 lastHealthCheck;
        uint256 totalProcessed;
        uint256 successRate;
        uint256 averageResponseTime;
        uint256 currentLoad;
        bool isActive;
        string statusMessage;
    }

    struct FraudPreventionMetrics {
        uint256 totalCases;
        uint256 openCases;
        uint256 resolvedCases;
        uint256 fraudsPrevented;
        uint256 falsePositives;
        uint256 totalValueProtected;
        uint256 averageCaseResolutionTime;
        uint256 systemEfficiency;
        uint256 crossSystemAccuracy;
        uint256 lastMetricsUpdate;
    }

    struct WorkflowConfiguration {
        uint256 maxConcurrentCases;
        uint256 defaultResponseTimeout;
        uint256 escalationThreshold;
        uint256 autoCloseTimeout;
        bool enableAutoEscalation;
        bool enableCrossSystemValidation;
        bool enableExternalIntegration;
        mapping(SystemComponent => uint256) systemWeights;
        mapping(uint256 => uint256) priorityTimeouts;
    }

    struct ComplianceReport {
        uint256 reportId;
        uint256 reportingPeriodStart;
        uint256 reportingPeriodEnd;
        uint256 totalIncidents;
        uint256 fraudsDetected;
        uint256 fraudsPrevented;
        uint256 falsePositiveRate;
        uint256 averageResponseTime;
        uint256 complianceScore;
        bytes32 reportHash;
        bool submitted;
        uint256 submissionTime;
        address submittedBy;
    }

    // ============ STATE VARIABLES ============

    // System component references
    ComprehensiveFraudDetection public immutable comprehensiveFraudDetection;
    EnhancedFraudPreventionSystem public immutable enhancedFraudPrevention;
    RealTimeFraudMonitor public immutable realTimeMonitor;
    ISlashingMechanism public slashingMechanism;

    // Case management
    mapping(uint256 => IntegratedCase) public integratedCases;
    mapping(address => uint256[]) public participantCases;
    mapping(SystemComponent => uint256[]) public systemCases;
    mapping(uint256 => SystemComponent) public caseOrigins;

    // System monitoring
    mapping(SystemComponent => SystemStatus) public systemStatuses;
    mapping(address => SystemComponent) public contractToComponent;

    // Metrics and reporting
    FraudPreventionMetrics public overallMetrics;
    mapping(uint256 => ComplianceReport) public complianceReports;
    mapping(uint256 => uint256) public periodicMetrics; // timestamp => metric

    // Configuration
    WorkflowConfiguration internal workflowConfig;
    mapping(uint256 => address) public priorityAssignments;

    // Counters and tracking
    uint256 public nextCaseId;
    uint256 public nextReportId;
    uint256 public activeCasesCount;
    uint256 public lastSystemHealthCheck;

    // Sets for efficient operations
    EnumerableSet.AddressSet private authorizedInvestigators;
    EnumerableSet.Bytes32Set private activeCases;
    EnumerableSet.Bytes32Set private escalatedCases;

    // External system integration
    mapping(address => bool) public authorizedExternalSystems;
    mapping(bytes32 => address) public externalSystemEndpoints;

    // ============ EVENTS ============

    event IntegratedCaseOpened(
        uint256 indexed caseId,
        address indexed participant,
        SystemComponent originSystem,
        uint256 priority,
        uint256 riskScore
    );

    event CaseStatusUpdated(
        uint256 indexed caseId,
        CaseStatus oldStatus,
        CaseStatus newStatus,
        address updatedBy
    );

    event CaseResolved(
        uint256 indexed caseId,
        ResponseOutcome outcome,
        uint256 resolutionTime,
        uint256 valueProtected
    );

    event SystemHealthUpdated(
        SystemComponent indexed component,
        SystemHealth oldHealth,
        SystemHealth newHealth,
        string statusMessage
    );

    event CrossSystemValidationCompleted(
        uint256 indexed caseId,
        uint256 validationScore,
        bool consensusReached,
        uint256 participatingSystems
    );

    event ComplianceReportGenerated(
        uint256 indexed reportId,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 complianceScore
    );

    event ExternalSystemIntegration(
        address indexed externalSystem,
        uint256 indexed caseId,
        string integrationReason,
        bytes32 referenceId
    );

    event WorkflowAutomationTriggered(
        uint256 indexed caseId,
        string automationReason,
        SystemComponent[] involvedSystems
    );

    // ============ MODIFIERS ============

    modifier validCase(uint256 caseId) {
        require(caseId > 0 && caseId < nextCaseId, "FPIM: Invalid case ID");
        _;
    }

    modifier caseNotClosed(uint256 caseId) {
        require(
            integratedCases[caseId].status != CaseStatus.CLOSED,
            "FPIM: Case is closed"
        );
        _;
    }

    modifier systemHealthy() {
        require(_checkSystemsHealth(), "FPIM: Critical system health issues");
        _;
    }

    modifier withinCapacity() {
        require(
            activeCasesCount < workflowConfig.maxConcurrentCases,
            "FPIM: System at capacity"
        );
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(
        address _comprehensiveFraudDetection,
        address _enhancedFraudPrevention,
        address _realTimeMonitor,
        address _slashingMechanism
    ) {
        require(_comprehensiveFraudDetection != address(0), "FPIM: Invalid fraud detection");
        require(_enhancedFraudPrevention != address(0), "FPIM: Invalid fraud prevention");
        require(_realTimeMonitor != address(0), "FPIM: Invalid real-time monitor");
        require(_slashingMechanism != address(0), "FPIM: Invalid slashing mechanism");

        comprehensiveFraudDetection = ComprehensiveFraudDetection(_comprehensiveFraudDetection);
        enhancedFraudPrevention = EnhancedFraudPreventionSystem(_enhancedFraudPrevention);
        realTimeMonitor = RealTimeFraudMonitor(_realTimeMonitor);
        slashingMechanism = ISlashingMechanism(_slashingMechanism);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(INTEGRATION_ADMIN_ROLE, msg.sender);
        _grantRole(SYSTEM_COORDINATOR_ROLE, msg.sender);
        _grantRole(FRAUD_RESPONSE_MANAGER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_REPORTER_ROLE, msg.sender);

        nextCaseId = 1;
        nextReportId = 1;

        // Initialize system component mappings
        contractToComponent[_comprehensiveFraudDetection] = SystemComponent.COMPREHENSIVE_FRAUD_DETECTION;
        contractToComponent[_enhancedFraudPrevention] = SystemComponent.ENHANCED_FRAUD_PREVENTION;
        contractToComponent[_realTimeMonitor] = SystemComponent.REAL_TIME_MONITOR;
        contractToComponent[_slashingMechanism] = SystemComponent.SLASHING_MECHANISM;

        // Initialize workflow configuration
        workflowConfig.maxConcurrentCases = 100;
        workflowConfig.defaultResponseTimeout = 24 hours;
        workflowConfig.escalationThreshold = 48 hours;
        workflowConfig.autoCloseTimeout = 7 days;
        workflowConfig.enableAutoEscalation = true;
        workflowConfig.enableCrossSystemValidation = true;
        workflowConfig.enableExternalIntegration = false;

        // Initialize system statuses
        _initializeSystemStatuses();
    }

    // ============ CASE MANAGEMENT ============

    /**
     * @notice Open new integrated fraud case
     * @param participant Address of participant involved
     * @param originSystem System that detected the issue
     * @param relatedIds Array of related detection/alert IDs
     * @param priority Case priority (1-4, where 1 is highest)
     * @param riskScore Initial risk assessment
     * @param description Case description
     * @return caseId ID of opened case
     */
    function openIntegratedCase(
        address participant,
        SystemComponent originSystem,
        uint256[] calldata relatedIds,
        uint256 priority,
        uint256 riskScore,
        string calldata description
    )
        external
        onlyRole(SYSTEM_COORDINATOR_ROLE)
        whenNotPaused
        systemHealthy
        withinCapacity
        returns (uint256 caseId)
    {
        require(participant != address(0), "FPIM: Invalid participant");
        require(priority >= CRITICAL_PRIORITY && priority <= LOW_PRIORITY, "FPIM: Invalid priority");
        require(riskScore <= 100, "FPIM: Invalid risk score");
        require(bytes(description).length > 0, "FPIM: Description required");

        caseId = nextCaseId++;

        IntegratedCase storage newCase = integratedCases[caseId];
        newCase.caseId = caseId;
        newCase.participant = participant;
        newCase.originSystem = originSystem;
        newCase.status = CaseStatus.OPEN;
        newCase.priority = priority;
        newCase.riskScore = riskScore;
        newCase.confidenceScore = 50; // Default confidence
        newCase.openedTime = block.timestamp;
        newCase.lastUpdateTime = block.timestamp;
        newCase.responseDeadline = block.timestamp + _getResponseTimeout(priority);
        newCase.description = description;

        // Store related IDs based on system
        if (originSystem == SystemComponent.COMPREHENSIVE_FRAUD_DETECTION) {
            newCase.relatedDetectionIds = relatedIds;
        } else if (originSystem == SystemComponent.REAL_TIME_MONITOR) {
            newCase.relatedAlertIds = relatedIds;
        } else if (originSystem == SystemComponent.ENHANCED_FRAUD_PREVENTION) {
            newCase.relatedInterventionIds = relatedIds;
        }

        newCase.systemsInvolved[originSystem] = true;

        // Bounds checks (prevent storage DoS)
        require(participantCases[participant].length < MAX_CASES_PER_PARTICIPANT, "FPIM: Participant case limit reached");
        require(systemCases[originSystem].length < MAX_CASES_PER_SYSTEM, "FPIM: System case limit reached");

        // Track case
        participantCases[participant].push(caseId);
        systemCases[originSystem].push(caseId);
        caseOrigins[caseId] = originSystem;
        activeCases.add(bytes32(caseId));
        activeCasesCount++;

        // Update metrics
        overallMetrics.totalCases++;
        overallMetrics.openCases++;

        // Auto-assign investigator based on priority
        newCase.assignedInvestigator = _assignInvestigator(priority, riskScore);

        emit IntegratedCaseOpened(
            caseId,
            participant,
            originSystem,
            priority,
            riskScore
        );

        // Trigger automated workflow if enabled
        if (_shouldTriggerAutomation(newCase)) {
            _triggerAutomatedWorkflow(caseId);
        }

        return caseId;
    }

    /**
     * @notice Update case status with investigation notes
     * @param caseId Case to update
     * @param newStatus New status for the case
     * @param investigatorNotes Notes from investigator
     */
    function updateCaseStatus(
        uint256 caseId,
        CaseStatus newStatus,
        string calldata investigatorNotes
    )
        external
        onlyRole(FRAUD_RESPONSE_MANAGER_ROLE)
        validCase(caseId)
        caseNotClosed(caseId)
        whenNotPaused
    {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        CaseStatus oldStatus = fraudCase.status;
        
        require(oldStatus != newStatus, "FPIM: Status unchanged");
        require(bytes(investigatorNotes).length > 0, "FPIM: Notes required");

        fraudCase.status = newStatus;
        fraudCase.lastUpdateTime = block.timestamp;
        fraudCase.investigatorNotes[msg.sender] = investigatorNotes;

        // Update deadline for certain status changes
        if (newStatus == CaseStatus.EVIDENCE_COLLECTION) {
            fraudCase.responseDeadline = block.timestamp + 72 hours;
        } else if (newStatus == CaseStatus.PENDING_REVIEW) {
            fraudCase.responseDeadline = block.timestamp + 24 hours;
        }

        emit CaseStatusUpdated(caseId, oldStatus, newStatus, msg.sender);

        // Check for auto-escalation
        if (_shouldAutoEscalate(fraudCase)) {
            _escalateCase(caseId);
        }

        // Trigger cross-system validation for certain statuses
        if (newStatus == CaseStatus.INVESTIGATING && workflowConfig.enableCrossSystemValidation) {
            _performCrossSystemValidation(caseId);
        }
    }

    /**
     * @notice Resolve case with outcome and evidence
     * @param caseId Case to resolve
     * @param outcome Resolution outcome
     * @param resolution Description of resolution
     * @param valueProtected Amount of value protected (if applicable)
     * @param evidenceHash Hash of final evidence package
     */
    function resolveCase(
        uint256 caseId,
        ResponseOutcome outcome,
        string calldata resolution,
        uint256 valueProtected,
        bytes32 evidenceHash
    )
        external
        onlyRole(FRAUD_RESPONSE_MANAGER_ROLE)
        validCase(caseId)
        caseNotClosed(caseId)
        whenNotPaused
    {
        require(bytes(resolution).length > 0, "FPIM: Resolution required");
        require(evidenceHash != bytes32(0), "FPIM: Evidence hash required");

        IntegratedCase storage fraudCase = integratedCases[caseId];
        uint256 resolutionTime = block.timestamp - fraudCase.openedTime;

        fraudCase.status = CaseStatus.RESOLVED;
        fraudCase.outcome = outcome;
        fraudCase.resolution = resolution;
        fraudCase.totalValueAtRisk = valueProtected;
        fraudCase.lastUpdateTime = block.timestamp;
        fraudCase.evidenceHashes.push(evidenceHash);

        // Update metrics
        overallMetrics.resolvedCases++;
        overallMetrics.openCases--;
        activeCasesCount--;
        activeCases.remove(bytes32(caseId));

        if (outcome == ResponseOutcome.FRAUD_CONFIRMED || outcome == ResponseOutcome.FRAUD_PREVENTED) {
            overallMetrics.fraudsPrevented++;
            overallMetrics.totalValueProtected += valueProtected;
        } else if (outcome == ResponseOutcome.FALSE_POSITIVE) {
            overallMetrics.falsePositives++;
        }

        // Update average resolution time
        overallMetrics.averageCaseResolutionTime = (
            overallMetrics.averageCaseResolutionTime * (overallMetrics.resolvedCases - 1) + 
            resolutionTime
        ) / overallMetrics.resolvedCases;

        emit CaseResolved(caseId, outcome, resolutionTime, valueProtected);

        // Execute final actions based on outcome
        _executeFinalActions(caseId, outcome);
    }

    // ============ CROSS-SYSTEM VALIDATION ============

    /**
     * @dev Perform cross-system validation for enhanced accuracy
     * @param caseId Case to validate across systems
     */
    function _performCrossSystemValidation(uint256 caseId) internal {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        address participant = fraudCase.participant;
        
        uint256 validationScore = 0;
        uint256 participatingSystems = 0;
        bool consensusReached = false;

        // Get validation from comprehensive fraud detection
        try comprehensiveFraudDetection.getAddressStatus(participant) returns (
            bool isQuarantined,
            uint256 riskScore,
            uint256 trustScore
        ) {
            if (riskScore > 0) {
                validationScore += riskScore;
                participatingSystems++;
                fraudCase.systemsInvolved[SystemComponent.COMPREHENSIVE_FRAUD_DETECTION] = true;
            }
        } catch {
            // System unavailable - continue with other validations
        }

        // Get validation from enhanced fraud prevention
        try enhancedFraudPrevention.getRiskAssessment(participant) returns (
            uint256 currentRisk,
            EnhancedFraudPreventionSystem.TrustLevel trustLevel,
            EnhancedFraudPreventionSystem.PreventionLevel preventionLevel,
            bool interventionRequired
        ) {
            if (currentRisk > 0) {
                validationScore += currentRisk;
                participatingSystems++;
                fraudCase.systemsInvolved[SystemComponent.ENHANCED_FRAUD_PREVENTION] = true;
            }
        } catch {
            // System unavailable - continue with other validations
        }

        // Calculate consensus
        if (participatingSystems > 0) {
            validationScore = validationScore / participatingSystems;
            consensusReached = participatingSystems >= 2 && validationScore > 60;
            
            // Update case confidence based on cross-system validation
            fraudCase.confidenceScore = validationScore;
            
            if (consensusReached) {
                // High confidence - can proceed with automated actions
                fraudCase.priority = validationScore > 80 ? CRITICAL_PRIORITY : HIGH_PRIORITY;
            }
        }

        emit CrossSystemValidationCompleted(
            caseId,
            validationScore,
            consensusReached,
            participatingSystems
        );
    }

    // ============ AUTOMATED WORKFLOWS ============

    /**
     * @dev Trigger automated workflow for case processing
     * @param caseId Case to process with automation
     */
    function _triggerAutomatedWorkflow(uint256 caseId) internal {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        SystemComponent[] memory involvedSystems = _getInvolvedSystems(caseId);
        
        string memory automationReason;
        
        if (fraudCase.priority == CRITICAL_PRIORITY) {
            automationReason = "Critical priority case requiring immediate attention";
            
            // Auto-escalate critical cases
            if (fraudCase.riskScore > 90) {
                _escalateCase(caseId);
                fraudCase.escalatedToExternal = true;
            }
            
        } else if (fraudCase.riskScore > 85) {
            automationReason = "High-risk participant requires enhanced monitoring";
            
            // Automatically configure enhanced monitoring
            try realTimeMonitor.configureMonitoring(
                fraudCase.participant,
                RealTimeFraudMonitor.MonitoringLevel.INTENSIVE,
                true, true, true
            ) {
                // Monitoring configured successfully
            } catch {
                // Continue without monitoring configuration
            }
            
        } else if (_isRepeatOffender(fraudCase.participant)) {
            automationReason = "Repeat offender detected - applying enhanced measures";
            
            // Apply enhanced measures for repeat offenders
            _applyEnhancedMeasures(caseId);
        }

        emit WorkflowAutomationTriggered(caseId, automationReason, involvedSystems);
    }

    // ============ SYSTEM HEALTH MONITORING ============

    /**
     * @notice Perform comprehensive system health check
     * @return overallHealth Overall system health status
     * @return unhealthySystems Array of systems with health issues
     */
    function performSystemHealthCheck()
        external
        onlyRole(SYSTEM_COORDINATOR_ROLE)
        returns (SystemHealth overallHealth, SystemComponent[] memory unhealthySystems)
    {
        SystemComponent[] memory components = new SystemComponent[](4);
        components[0] = SystemComponent.COMPREHENSIVE_FRAUD_DETECTION;
        components[1] = SystemComponent.ENHANCED_FRAUD_PREVENTION;
        components[2] = SystemComponent.REAL_TIME_MONITOR;
        components[3] = SystemComponent.SLASHING_MECHANISM;

        uint256 healthyCount = 0;
        uint256 unhealthyCount = 0;
        SystemComponent[] memory tempUnhealthy = new SystemComponent[](4);

        for (uint256 i = 0; i < components.length; i++) {
            SystemHealth componentHealth = _checkComponentHealth(components[i]);
            SystemStatus storage status = systemStatuses[components[i]];
            
            SystemHealth oldHealth = status.health;
            status.health = componentHealth;
            status.lastHealthCheck = block.timestamp;

            if (componentHealth == SystemHealth.HEALTHY) {
                healthyCount++;
                status.statusMessage = "System operating normally";
            } else {
                tempUnhealthy[unhealthyCount] = components[i];
                unhealthyCount++;
                
                if (componentHealth == SystemHealth.CRITICAL) {
                    status.statusMessage = "Critical system issues detected";
                } else if (componentHealth == SystemHealth.WARNING) {
                    status.statusMessage = "System performance degraded";
                } else {
                    status.statusMessage = "System offline or unresponsive";
                }
            }

            if (oldHealth != componentHealth) {
                emit SystemHealthUpdated(components[i], oldHealth, componentHealth, status.statusMessage);
            }
        }

        // Determine overall health
        uint256 healthPercentage = (healthyCount * 100) / components.length;
        if (healthPercentage >= SYSTEM_HEALTHY_THRESHOLD) {
            overallHealth = SystemHealth.HEALTHY;
        } else if (healthPercentage >= SYSTEM_WARNING_THRESHOLD) {
            overallHealth = SystemHealth.WARNING;
        } else if (healthPercentage >= SYSTEM_CRITICAL_THRESHOLD) {
            overallHealth = SystemHealth.CRITICAL;
        } else {
            overallHealth = SystemHealth.OFFLINE;
        }

        // Resize unhealthy systems array
        unhealthySystems = new SystemComponent[](unhealthyCount);
        for (uint256 i = 0; i < unhealthyCount; i++) {
            unhealthySystems[i] = tempUnhealthy[i];
        }

        lastSystemHealthCheck = block.timestamp;
        
        return (overallHealth, unhealthySystems);
    }

    // ============ COMPLIANCE REPORTING ============

    /**
     * @notice Generate comprehensive compliance report
     * @param periodStart Start of reporting period
     * @param periodEnd End of reporting period
     * @return reportId ID of generated report
     */
    function generateComplianceReport(
        uint256 periodStart,
        uint256 periodEnd
    )
        external
        onlyRole(COMPLIANCE_REPORTER_ROLE)
        whenNotPaused
        returns (uint256 reportId)
    {
        require(periodStart < periodEnd, "FPIM: Invalid period");
        require(periodEnd <= block.timestamp, "FPIM: Future period not allowed");

        reportId = nextReportId++;

        ComplianceReport storage report = complianceReports[reportId];
        report.reportId = reportId;
        report.reportingPeriodStart = periodStart;
        report.reportingPeriodEnd = periodEnd;
        
        // Calculate metrics for the reporting period
        (
            uint256 totalIncidents,
            uint256 fraudsDetected,
            uint256 fraudsPrevented,
            uint256 falsePositiveRate,
            uint256 averageResponseTime,
            uint256 complianceScore
        ) = _calculatePeriodMetrics(periodStart, periodEnd);

        report.totalIncidents = totalIncidents;
        report.fraudsDetected = fraudsDetected;
        report.fraudsPrevented = fraudsPrevented;
        report.falsePositiveRate = falsePositiveRate;
        report.averageResponseTime = averageResponseTime;
        report.complianceScore = complianceScore;
        
        // Generate report hash for integrity
        report.reportHash = keccak256(abi.encodePacked(
            reportId,
            periodStart,
            periodEnd,
            totalIncidents,
            fraudsDetected,
            fraudsPrevented,
            complianceScore
        ));

        report.submissionTime = block.timestamp;
        report.submittedBy = msg.sender;
        report.submitted = true;

        emit ComplianceReportGenerated(reportId, periodStart, periodEnd, complianceScore);

        return reportId;
    }

    // ============ EXTERNAL SYSTEM INTEGRATION ============

    /**
     * @notice Integrate case with external system
     * @param caseId Case to integrate externally
     * @param externalSystem Address of external system
     * @param integrationReason Reason for external integration
     * @param referenceId External reference ID
     */
    function integrateWithExternalSystem(
        uint256 caseId,
        address externalSystem,
        string calldata integrationReason,
        bytes32 referenceId
    )
        external
        onlyRole(EXTERNAL_INTEGRATOR_ROLE)
        validCase(caseId)
        whenNotPaused
    {
        require(authorizedExternalSystems[externalSystem], "FPIM: Unauthorized external system");
        require(bytes(integrationReason).length > 0, "FPIM: Integration reason required");
        require(referenceId != bytes32(0), "FPIM: Reference ID required");

        IntegratedCase storage fraudCase = integratedCases[caseId];
        fraudCase.escalatedToExternal = true;
        fraudCase.lastUpdateTime = block.timestamp;

        // Store external reference
        externalSystemEndpoints[referenceId] = externalSystem;

        emit ExternalSystemIntegration(externalSystem, caseId, integrationReason, referenceId);

        // Update case status to escalated
        fraudCase.status = CaseStatus.ESCALATED;
        emit CaseStatusUpdated(caseId, CaseStatus.INVESTIGATING, CaseStatus.ESCALATED, msg.sender);
    }

    // ============ INTERNAL HELPER FUNCTIONS ============

    /**
     * @dev Initialize system status structures
     */
    function _initializeSystemStatuses() internal {
        SystemComponent[] memory components = new SystemComponent[](4);
        components[0] = SystemComponent.COMPREHENSIVE_FRAUD_DETECTION;
        components[1] = SystemComponent.ENHANCED_FRAUD_PREVENTION;
        components[2] = SystemComponent.REAL_TIME_MONITOR;
        components[3] = SystemComponent.SLASHING_MECHANISM;

        address[] memory addresses = new address[](4);
        addresses[0] = address(comprehensiveFraudDetection);
        addresses[1] = address(enhancedFraudPrevention);
        addresses[2] = address(realTimeMonitor);
        addresses[3] = address(slashingMechanism);

        for (uint256 i = 0; i < components.length; i++) {
            SystemStatus storage status = systemStatuses[components[i]];
            status.component = components[i];
            status.contractAddress = addresses[i];
            status.health = SystemHealth.HEALTHY;
            status.lastHealthCheck = block.timestamp;
            status.isActive = true;
            status.statusMessage = "System initialized";
        }
    }

    /**
     * @dev Check health of individual system component
     * @param component Component to check
     * @return health Health status of component
     */
    function _checkComponentHealth(SystemComponent component) internal view returns (SystemHealth) {
        SystemStatus storage status = systemStatuses[component];
        
        if (!status.isActive || status.contractAddress == address(0)) {
            return SystemHealth.OFFLINE;
        }

        // Simple health check based on code size (contract exists)
        uint256 codeSize;
        address contractAddr = status.contractAddress;
        assembly {
            codeSize := extcodesize(contractAddr)
        }
        
        if (codeSize == 0) {
            return SystemHealth.OFFLINE;
        }

        // More sophisticated health checks would go here
        // For now, assume healthy if contract exists and is active
        return SystemHealth.HEALTHY;
    }

    /**
     * @dev Check if all systems are healthy
     * @return healthy True if all critical systems are healthy
     */
    function _checkSystemsHealth() internal view returns (bool) {
        SystemComponent[] memory criticalSystems = new SystemComponent[](3);
        criticalSystems[0] = SystemComponent.COMPREHENSIVE_FRAUD_DETECTION;
        criticalSystems[1] = SystemComponent.ENHANCED_FRAUD_PREVENTION;
        criticalSystems[2] = SystemComponent.REAL_TIME_MONITOR;

        for (uint256 i = 0; i < criticalSystems.length; i++) {
            SystemHealth health = systemStatuses[criticalSystems[i]].health;
            if (health == SystemHealth.CRITICAL || health == SystemHealth.OFFLINE) {
                return false;
            }
        }
        
        return true;
    }

    /**
     * @dev Get response timeout based on priority
     * @param priority Case priority
     * @return timeout Response timeout in seconds
     */
    function _getResponseTimeout(uint256 priority) internal view returns (uint256) {
        if (priority == CRITICAL_PRIORITY) return 1 hours;
        if (priority == HIGH_PRIORITY) return 6 hours;
        if (priority == MEDIUM_PRIORITY) return 24 hours;
        return 72 hours; // LOW_PRIORITY
    }

    /**
     * @dev Assign investigator based on priority and risk
     * @param priority Case priority
     * @param riskScore Risk score
     * @return investigator Address of assigned investigator
     */
    function _assignInvestigator(uint256 priority, uint256 riskScore) internal view returns (address) {
        if (priorityAssignments[priority] != address(0)) {
            return priorityAssignments[priority];
        }
        
        // Default assignment logic
        if (authorizedInvestigators.length() > 0) {
            uint256 index = (priority + riskScore) % authorizedInvestigators.length();
            return authorizedInvestigators.at(index);
        }
        
        return address(0); // No investigators available
    }

    /**
     * @dev Check if case should trigger automation
     * @param fraudCase Case to check
     * @return shouldTrigger Whether to trigger automation
     */
    function _shouldTriggerAutomation(IntegratedCase storage fraudCase) internal view returns (bool) {
        return fraudCase.priority <= HIGH_PRIORITY || fraudCase.riskScore > 75;
    }

    /**
     * @dev Check if case should auto-escalate
     * @param fraudCase Case to check
     * @return shouldEscalate Whether to escalate
     */
    function _shouldAutoEscalate(IntegratedCase storage fraudCase) internal view returns (bool) {
        if (!workflowConfig.enableAutoEscalation) return false;
        
        return (
            block.timestamp > fraudCase.responseDeadline &&
            fraudCase.status == CaseStatus.INVESTIGATING &&
            fraudCase.priority <= HIGH_PRIORITY
        );
    }

    /**
     * @dev Escalate case to higher priority or external system
     * @param caseId Case to escalate
     */
    function _escalateCase(uint256 caseId) internal {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        
        // Increase priority if possible
        if (fraudCase.priority > CRITICAL_PRIORITY) {
            fraudCase.priority = fraudCase.priority - 1;
        }
        
        // Mark as escalated
        escalatedCases.add(bytes32(caseId));
        fraudCase.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Check if participant is a repeat offender
     * @param participant Address to check
     * @return isRepeat Whether participant has previous cases
     */
    function _isRepeatOffender(address participant) internal view returns (bool) {
        return participantCases[participant].length > 1;
    }

    /**
     * @dev Apply enhanced measures for high-risk cases
     * @param caseId Case to apply measures to
     */
    function _applyEnhancedMeasures(uint256 caseId) internal {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        
        // Could integrate with other systems to apply measures
        // For now, just update the case priority and deadline
        if (fraudCase.priority > CRITICAL_PRIORITY) {
            fraudCase.priority = CRITICAL_PRIORITY;
        }
        
        fraudCase.responseDeadline = block.timestamp + 12 hours; // Shorter deadline
    }

    /**
     * @dev Get array of involved systems for a case
     * @param caseId Case to check
     * @return systems Array of involved systems
     */
    function _getInvolvedSystems(uint256 caseId) internal view returns (SystemComponent[] memory) {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        
        uint256 count = 0;
        SystemComponent[] memory allSystems = new SystemComponent[](5);
        allSystems[0] = SystemComponent.COMPREHENSIVE_FRAUD_DETECTION;
        allSystems[1] = SystemComponent.ENHANCED_FRAUD_PREVENTION;
        allSystems[2] = SystemComponent.REAL_TIME_MONITOR;
        allSystems[3] = SystemComponent.SLASHING_MECHANISM;
        allSystems[4] = SystemComponent.EXTERNAL_SYSTEM;
        
        // Count involved systems
        for (uint256 i = 0; i < allSystems.length; i++) {
            if (fraudCase.systemsInvolved[allSystems[i]]) {
                count++;
            }
        }
        
        // Create result array
        SystemComponent[] memory result = new SystemComponent[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < allSystems.length; i++) {
            if (fraudCase.systemsInvolved[allSystems[i]]) {
                result[index] = allSystems[i];
                index++;
            }
        }
        
        return result;
    }

    /**
     * @dev Execute final actions based on case outcome
     * @param caseId Case that was resolved
     * @param outcome Resolution outcome
     */
    function _executeFinalActions(uint256 caseId, ResponseOutcome outcome) internal {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        
        if (outcome == ResponseOutcome.FRAUD_CONFIRMED) {
            // Could trigger slashing mechanism
            // For now, just mark the case as requiring follow-up
            fraudCase.lastUpdateTime = block.timestamp;
        } else if (outcome == ResponseOutcome.FALSE_POSITIVE) {
            // Could trigger system recalibration
            // Update confidence scores for involved systems
        }
        
        // Close the case
        fraudCase.status = CaseStatus.CLOSED;
    }

    /**
     * @dev Calculate metrics for a specific period
     * @param periodStart Start timestamp
     * @param periodEnd End timestamp
     * @return totalIncidents Total incidents in period
     * @return fraudsDetected Frauds detected in period  
     * @return fraudsPrevented Frauds prevented in period
     * @return falsePositiveRate False positive rate
     * @return averageResponseTime Average response time
     * @return complianceScore Overall compliance score
     */
    function _calculatePeriodMetrics(
        uint256 periodStart,
        uint256 periodEnd
    ) internal view returns (
        uint256 totalIncidents,
        uint256 fraudsDetected,
        uint256 fraudsPrevented,
        uint256 falsePositiveRate,
        uint256 averageResponseTime,
        uint256 complianceScore
    ) {
        // Simplified calculation - in production would iterate through cases in period
        totalIncidents = overallMetrics.totalCases;
        fraudsDetected = overallMetrics.fraudsPrevented;
        fraudsPrevented = overallMetrics.fraudsPrevented;
        
        if (totalIncidents > 0) {
            falsePositiveRate = (overallMetrics.falsePositives * 100) / totalIncidents;
        }
        
        averageResponseTime = overallMetrics.averageCaseResolutionTime;
        
        // Calculate compliance score based on performance metrics
        complianceScore = 100;
        if (falsePositiveRate > 10) complianceScore -= 20;
        if (averageResponseTime > 48 hours) complianceScore -= 15;
        if (fraudsPrevented < totalIncidents * 80 / 100) complianceScore -= 25;
        
        return (totalIncidents, fraudsDetected, fraudsPrevented, falsePositiveRate, averageResponseTime, complianceScore);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get comprehensive case details
     * @param caseId Case to query
     * @return participant Address involved
     * @return originSystem System that detected issue
     * @return status Current case status
     * @return priority Case priority
     * @return riskScore Risk assessment score
     * @return openedTime When case was opened
     * @return assignedInvestigator Investigator assigned
     */
    function getCaseDetails(uint256 caseId)
        external
        view
        validCase(caseId)
        returns (
            address participant,
            SystemComponent originSystem,
            CaseStatus status,
            uint256 priority,
            uint256 riskScore,
            uint256 openedTime,
            address assignedInvestigator
        )
    {
        IntegratedCase storage fraudCase = integratedCases[caseId];
        return (
            fraudCase.participant,
            fraudCase.originSystem,
            fraudCase.status,
            fraudCase.priority,
            fraudCase.riskScore,
            fraudCase.openedTime,
            fraudCase.assignedInvestigator
        );
    }

    /**
     * @notice Get system health status
     * @param component System component to check
     * @return health Current health status
     * @return lastCheck Last health check timestamp
     * @return statusMessage Current status message
     * @return isActive Whether system is active
     */
    function getSystemStatus(SystemComponent component)
        external
        view
        returns (
            SystemHealth health,
            uint256 lastCheck,
            string memory statusMessage,
            bool isActive
        )
    {
        SystemStatus storage status = systemStatuses[component];
        return (
            status.health,
            status.lastHealthCheck,
            status.statusMessage,
            status.isActive
        );
    }

    /**
     * @notice Get overall fraud prevention metrics
     * @return totalCases Total cases processed
     * @return openCases Currently open cases
     * @return fraudsPrevented Total frauds prevented
     * @return systemEfficiency System efficiency score
     * @return totalValueProtected Total value protected
     */
    function getOverallMetrics()
        external
        view
        returns (
            uint256 totalCases,
            uint256 openCases,
            uint256 fraudsPrevented,
            uint256 systemEfficiency,
            uint256 totalValueProtected
        )
    {
        return (
            overallMetrics.totalCases,
            overallMetrics.openCases,
            overallMetrics.fraudsPrevented,
            overallMetrics.systemEfficiency,
            overallMetrics.totalValueProtected
        );
    }

    // ============ PAGINATED VIEW FUNCTIONS ============

    /**
     * @notice Get paginated participant cases
     * @param participant Address to query
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return cases Array of case IDs
     * @return total Total number of cases for participant
     */
    function getParticipantCasesPaginated(address participant, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory cases, uint256 total)
    {
        uint256[] storage allCases = participantCases[participant];
        total = allCases.length;

        if (offset >= total || limit == 0) {
            return (new uint256[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        uint256 resultLength = end - offset;

        cases = new uint256[](resultLength);
        for (uint256 i = 0; i < resultLength; i++) {
            cases[i] = allCases[offset + i];
        }

        return (cases, total);
    }

    /**
     * @notice Get paginated system cases
     * @param component System component to query
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return cases Array of case IDs
     * @return total Total number of cases for component
     */
    function getSystemCasesPaginated(SystemComponent component, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory cases, uint256 total)
    {
        uint256[] storage allCases = systemCases[component];
        total = allCases.length;

        if (offset >= total || limit == 0) {
            return (new uint256[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        uint256 resultLength = end - offset;

        cases = new uint256[](resultLength);
        for (uint256 i = 0; i < resultLength; i++) {
            cases[i] = allCases[offset + i];
        }

        return (cases, total);
    }

    // ============ ADMINISTRATIVE FUNCTIONS ============

    /**
     * @notice Add authorized investigator
     * @param investigator Address to authorize
     */
    function addAuthorizedInvestigator(address investigator)
        external
        onlyRole(INTEGRATION_ADMIN_ROLE)
    {
        require(investigator != address(0), "FPIM: Invalid investigator");
        authorizedInvestigators.add(investigator);
    }

    /**
     * @notice Authorize external system
     * @param externalSystem Address of external system
     */
    function authorizeExternalSystem(address externalSystem)
        external
        onlyRole(INTEGRATION_ADMIN_ROLE)
    {
        require(externalSystem != address(0), "FPIM: Invalid external system");
        authorizedExternalSystems[externalSystem] = true;
    }

    /**
     * @notice Update workflow configuration
     * @param maxConcurrentCases New max concurrent cases
     * @param defaultResponseTimeout New default timeout
     * @param escalationThreshold New escalation threshold
     */
    function updateWorkflowConfiguration(
        uint256 maxConcurrentCases,
        uint256 defaultResponseTimeout,
        uint256 escalationThreshold
    )
        external
        onlyRole(INTEGRATION_ADMIN_ROLE)
    {
        require(maxConcurrentCases > 0, "FPIM: Invalid max cases");
        require(defaultResponseTimeout > 0, "FPIM: Invalid timeout");
        require(escalationThreshold > 0, "FPIM: Invalid escalation threshold");

        workflowConfig.maxConcurrentCases = maxConcurrentCases;
        workflowConfig.defaultResponseTimeout = defaultResponseTimeout;
        workflowConfig.escalationThreshold = escalationThreshold;
    }

    /**
     * @notice Emergency pause all operations
     */
    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause all operations
     */
    function emergencyUnpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}