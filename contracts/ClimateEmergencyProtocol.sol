// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockChainlinkInterface.sol";

/**
 * @title ClimateEmergencyProtocol
 * @dev Automated emergency response system for climate disasters
 * Features:
 * - Multi-oracle climate data monitoring
 * - Automated trigger conditions based on climate thresholds
 * - Emergency fund allocation and distribution
 * - Guardian council override capabilities
 * - Time-weighted average metrics (TWAM) for stability
 */
contract ClimateEmergencyProtocol is ReentrancyGuard, Pausable, AccessControl {
    using Math for uint256;

    // Roles
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant PAUSE_GUARDIAN_ROLE = keccak256("PAUSE_GUARDIAN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant EMERGENCY_RESPONDER_ROLE = keccak256("EMERGENCY_RESPONDER_ROLE");

    // Emergency pause governance
    uint256 public constant PAUSE_THRESHOLD = 2;
    uint256 public constant PAUSE_TIMELOCK = 24 hours;

    // Emergency severity levels
    enum EmergencyLevel {
        NONE,
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    // Emergency types
    enum EmergencyType {
        TEMPERATURE_ANOMALY,
        EXTREME_WEATHER,
        SEA_LEVEL_RISE,
        CARBON_SPIKE,
        ECOSYSTEM_COLLAPSE,
        CUSTOM
    }

    // Emergency trigger condition
    struct TriggerCondition {
        string metricName;
        uint256 threshold;
        uint256 duration; // Minimum duration in seconds
        bool enabled;
        AggregatorV3Interface oracle;
        uint256 lastTriggered;
        uint256 cooldownPeriod;
    }

    // Emergency response action
    struct EmergencyAction {
        string description;
        address target;
        bytes callData;
        uint256 fundAmount;
        EmergencyLevel minLevel;
        bool executed;
        uint256 executionTime;
    }

    // Emergency event structure
    struct EmergencyEvent {
        uint256 id;
        EmergencyType emergencyType;
        EmergencyLevel level;
        string description;
        uint256 triggeredAt;
        uint256 resolvedAt;
        address triggeredBy;
        bool isActive;
        uint256 totalFundsAllocated;
        EmergencyAction[] actions;
    }

    // Time-weighted average metric
    struct TWAMMetric {
        uint256 currentValue;
        uint256 weightedSum;
        uint256 totalWeight;
        uint256 lastUpdateTime;
        uint256 windowPeriod; // TWAM window in seconds
    }

    // State variables
    IERC20 public immutable emergencyToken;
    address public emergencyVault;
    uint256 public constant GUARDIAN_QUORUM = 5; // 5 out of 9 guardians
    uint256 public constant ORACLE_CONSENSUS = 7; // 7 out of 10 oracles
    
    // Emergency fund limits
    uint256 public emergencyFundCap;
    uint256 public weeklyAllocationLimit;
    uint256 public lastAllocationReset;
    uint256 public currentWeeklyAllocated;

    // Storage mappings
    mapping(string => TriggerCondition) public triggerConditions;
    mapping(uint256 => EmergencyEvent) public emergencyEvents;
    mapping(string => TWAMMetric) public twamMetrics;
    mapping(address => mapping(string => uint256)) public oracleData;
    mapping(address => uint256) public oracleLastUpdate;
    mapping(uint256 => mapping(address => bool)) public pauseApprovals;
    
    string[] public activeMetrics;
    uint256[] public activeEmergencies;
    uint256 public nextEmergencyId;
    uint256 public pauseRequestNonce;
    uint256 public pauseRequestedAt;
    uint256 public pauseApprovalCount;
    bool public pauseRequestActive;
    
    // Circuit breaker
    bool public circuitBreakerActive;
    uint256 public circuitBreakerActivatedAt;
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 24 hours;

    // Events
    event EmergencyTriggered(
        uint256 indexed emergencyId,
        EmergencyType emergencyType,
        EmergencyLevel level,
        string description
    );
    event EmergencyResolved(uint256 indexed emergencyId, uint256 resolvedAt);
    event TriggerConditionUpdated(string indexed metricName, uint256 threshold, uint256 duration);
    event OracleDataUpdated(address indexed oracle, string indexed metric, uint256 value);
    event EmergencyActionExecuted(uint256 indexed emergencyId, uint256 actionIndex, uint256 fundAmount);
    event GuardianVeto(uint256 indexed emergencyId, address indexed guardian);
    event CircuitBreakerActivated(address indexed activator, string reason);
    event FundsAllocated(address indexed recipient, uint256 amount, string purpose);
    event PauseRequested(
        uint256 indexed pauseRequestNonce,
        address indexed guardian,
        uint256 approvalCount,
        uint256 executableAt
    );
    event PauseExecuted(
        uint256 indexed pauseRequestNonce,
        address indexed guardian,
        uint256 executedAt
    );

    modifier onlyGuardianQuorum() {
        // For now, just check if sender has guardian role - in production, implement proper quorum counting
        require(hasRole(GUARDIAN_ROLE, msg.sender), "CEP: Must be guardian");
        _;
    }

    modifier notCircuitBroken() {
        require(!circuitBreakerActive, "CEP: Circuit breaker active");
        _;
    }

    constructor(
        address _emergencyToken,
        address _emergencyVault,
        address _admin,
        address[] memory _pauseGuardians
    ) {
        require(_pauseGuardians.length == 3, "CEP: Must provide 3 pause guardians");

        emergencyToken = IERC20(_emergencyToken);
        emergencyVault = _emergencyVault;
        emergencyFundCap = 1000000 * 10**18; // 1M tokens
        weeklyAllocationLimit = 200000 * 10**18; // 200K tokens per week
        lastAllocationReset = block.timestamp;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE, _admin);

        for (uint256 i = 0; i < _pauseGuardians.length; i++) {
            address pauseGuardian = _pauseGuardians[i];
            require(pauseGuardian != address(0), "CEP: Invalid pause guardian");
            for (uint256 j = 0; j < i; j++) {
                require(pauseGuardian != _pauseGuardians[j], "CEP: Duplicate pause guardian");
            }
            _grantRole(PAUSE_GUARDIAN_ROLE, pauseGuardian);
        }
        
        // Initialize baseline trigger conditions
        _initializeBaseTriggers();
    }

    /**
     * @dev Initialize baseline climate emergency triggers
     */
    function _initializeBaseTriggers() internal {
        // Global temperature anomaly (>1.5°C above pre-industrial)
        triggerConditions["global_temp_anomaly"] = TriggerCondition({
            metricName: "global_temp_anomaly",
            threshold: 150, // 1.5°C in 0.01°C units
            duration: 90 days,
            enabled: true,
            oracle: AggregatorV3Interface(address(0)), // To be set later
            lastTriggered: 0,
            cooldownPeriod: 180 days
        });

        // CO2 concentration spike (>425 ppm)
        triggerConditions["co2_concentration"] = TriggerCondition({
            metricName: "co2_concentration",
            threshold: 42500, // 425 ppm in 0.01 ppm units
            duration: 90 days,
            enabled: true,
            oracle: AggregatorV3Interface(address(0)),
            lastTriggered: 0,
            cooldownPeriod: 365 days
        });

        // Category 5 hurricane landfall
        triggerConditions["extreme_hurricane"] = TriggerCondition({
            metricName: "extreme_hurricane",
            threshold: 5, // Category 5
            duration: 1 hours,
            enabled: true,
            oracle: AggregatorV3Interface(address(0)),
            lastTriggered: 0,
            cooldownPeriod: 30 days
        });

        activeMetrics.push("global_temp_anomaly");
        activeMetrics.push("co2_concentration");
        activeMetrics.push("extreme_hurricane");
    }

    /**
     * @dev Update oracle data for climate metrics
     */
    function updateOracleData(
        string memory _metric,
        uint256 _value,
        uint256 _timestamp
    ) external onlyRole(ORACLE_ROLE) notCircuitBroken {
        require(_timestamp <= block.timestamp, "CEP: Future timestamp");
        require(_timestamp > oracleLastUpdate[msg.sender], "CEP: Stale data");

        oracleData[msg.sender][_metric] = _value;
        oracleLastUpdate[msg.sender] = _timestamp;

        // Update TWAM metric
        _updateTWAM(_metric, _value);

        // Check if trigger conditions are met
        _evaluateTriggerConditions(_metric);

        emit OracleDataUpdated(msg.sender, _metric, _value);
    }

    /**
     * @dev Update Time-Weighted Average Metric
     */
    function _updateTWAM(string memory _metric, uint256 _value) internal {
        TWAMMetric storage twam = twamMetrics[_metric];
        
        if (twam.lastUpdateTime == 0) {
            // Initialize TWAM
            twam.currentValue = _value;
            twam.weightedSum = _value;
            twam.totalWeight = 1;
            twam.lastUpdateTime = block.timestamp;
            twam.windowPeriod = 90 days; // Default 90-day window
        } else {
            uint256 timeDelta = block.timestamp - twam.lastUpdateTime;
            uint256 weight = timeDelta;
            
            // Update weighted average within the window
            if (timeDelta < twam.windowPeriod) {
                twam.weightedSum += _value * weight;
                twam.totalWeight += weight;
                twam.currentValue = twam.weightedSum / twam.totalWeight;
            } else {
                // Reset TWAM if outside window
                twam.currentValue = _value;
                twam.weightedSum = _value;
                twam.totalWeight = 1;
            }
            
            twam.lastUpdateTime = block.timestamp;
        }
    }

    /**
     * @dev Evaluate trigger conditions for a metric
     */
    function _evaluateTriggerConditions(string memory _metric) internal {
        TriggerCondition storage condition = triggerConditions[_metric];
        
        if (!condition.enabled) return;
        
        // Check cooldown period
        if (block.timestamp < condition.lastTriggered + condition.cooldownPeriod) return;

        TWAMMetric storage twam = twamMetrics[_metric];
        
        // Check if threshold is exceeded for required duration
        if (twam.currentValue >= condition.threshold && 
            block.timestamp >= twam.lastUpdateTime + condition.duration) {
            
            _triggerEmergency(_metric, twam.currentValue);
            condition.lastTriggered = block.timestamp;
        }
    }

    /**
     * @dev Trigger a climate emergency
     */
    function _triggerEmergency(string memory _metric, uint256 _value) internal {
        EmergencyLevel level = _calculateEmergencyLevel(_metric, _value);
        EmergencyType emergencyType = _getEmergencyType(_metric);
        
        uint256 emergencyId = nextEmergencyId++;
        
        EmergencyEvent storage emergency = emergencyEvents[emergencyId];
        emergency.id = emergencyId;
        emergency.emergencyType = emergencyType;
        emergency.level = level;
        emergency.description = string(abi.encodePacked("Climate emergency: ", _metric, " threshold exceeded"));
        emergency.triggeredAt = block.timestamp;
        emergency.triggeredBy = address(this);
        emergency.isActive = true;
        
        activeEmergencies.push(emergencyId);
        
        // Execute automated responses
        _executeAutomatedResponse(emergencyId, level);
        
        emit EmergencyTriggered(emergencyId, emergencyType, level, emergency.description);
    }

    /**
     * @dev Calculate emergency level based on metric and value
     */
    function _calculateEmergencyLevel(string memory _metric, uint256 _value) internal view returns (EmergencyLevel) {
        TriggerCondition storage condition = triggerConditions[_metric];
        uint256 threshold = condition.threshold;
        
        if (_value >= threshold * 200 / 100) return EmergencyLevel.CRITICAL;
        if (_value >= threshold * 150 / 100) return EmergencyLevel.HIGH;
        if (_value >= threshold * 120 / 100) return EmergencyLevel.MEDIUM;
        if (_value >= threshold) return EmergencyLevel.LOW;
        
        return EmergencyLevel.NONE;
    }

    /**
     * @dev Get emergency type from metric name
     */
    function _getEmergencyType(string memory _metric) internal pure returns (EmergencyType) {
        if (keccak256(bytes(_metric)) == keccak256(bytes("global_temp_anomaly"))) {
            return EmergencyType.TEMPERATURE_ANOMALY;
        }
        if (keccak256(bytes(_metric)) == keccak256(bytes("extreme_hurricane"))) {
            return EmergencyType.EXTREME_WEATHER;
        }
        if (keccak256(bytes(_metric)) == keccak256(bytes("co2_concentration"))) {
            return EmergencyType.CARBON_SPIKE;
        }
        return EmergencyType.CUSTOM;
    }

    /**
     * @dev Execute automated emergency response
     */
    function _executeAutomatedResponse(uint256 _emergencyId, EmergencyLevel _level) internal {
        // Check weekly allocation limits
        _resetWeeklyAllocationIfNeeded();
        
        uint256 allocationAmount = _calculateAllocationAmount(_level);
        
        if (currentWeeklyAllocated + allocationAmount > weeklyAllocationLimit) {
            allocationAmount = weeklyAllocationLimit - currentWeeklyAllocated;
        }
        
        if (allocationAmount > 0) {
            // Allocate funds from emergency vault
            require(
                emergencyToken.transferFrom(emergencyVault, address(this), allocationAmount),
                "CEP: Fund allocation failed"
            );
            
            emergencyEvents[_emergencyId].totalFundsAllocated = allocationAmount;
            currentWeeklyAllocated += allocationAmount;
            
            emit FundsAllocated(address(this), allocationAmount, "Emergency response");
        }
    }

    /**
     * @dev Calculate allocation amount based on emergency level
     */
    function _calculateAllocationAmount(EmergencyLevel _level) internal view returns (uint256) {
        if (_level == EmergencyLevel.CRITICAL) return emergencyFundCap * 20 / 100; // 20%
        if (_level == EmergencyLevel.HIGH) return emergencyFundCap * 10 / 100;     // 10%
        if (_level == EmergencyLevel.MEDIUM) return emergencyFundCap * 5 / 100;   // 5%
        if (_level == EmergencyLevel.LOW) return emergencyFundCap * 2 / 100;      // 2%
        return 0;
    }

    /**
     * @dev Reset weekly allocation tracking if needed
     */
    function _resetWeeklyAllocationIfNeeded() internal {
        if (block.timestamp >= lastAllocationReset + 7 days) {
            currentWeeklyAllocated = 0;
            lastAllocationReset = block.timestamp;
        }
    }

    /**
     * @dev Guardian veto for emergency response
     */
    function guardianVeto(uint256 _emergencyId) external onlyRole(GUARDIAN_ROLE) {
        require(emergencyEvents[_emergencyId].isActive, "CEP: Emergency not active");
        require(
            block.timestamp <= emergencyEvents[_emergencyId].triggeredAt + 72 hours,
            "CEP: Veto period expired"
        );
        
        _resolveEmergency(_emergencyId);
        emit GuardianVeto(_emergencyId, msg.sender);
    }

    /**
     * @dev Activate circuit breaker
     */
    function activateCircuitBreaker(string memory _reason) external onlyRole(GUARDIAN_ROLE) {
        circuitBreakerActive = true;
        circuitBreakerActivatedAt = block.timestamp;
        emit CircuitBreakerActivated(msg.sender, _reason);
    }

    /**
     * @dev Deactivate circuit breaker
     */
    function deactivateCircuitBreaker() external onlyRole(GUARDIAN_ROLE) {
        require(
            block.timestamp >= circuitBreakerActivatedAt + CIRCUIT_BREAKER_COOLDOWN,
            "CEP: Cooldown not elapsed"
        );
        circuitBreakerActive = false;
    }

    /**
     * @dev Resolve an emergency
     */
    function resolveEmergency(uint256 _emergencyId) external onlyRole(EMERGENCY_RESPONDER_ROLE) {
        _resolveEmergency(_emergencyId);
    }

    /**
     * @dev Internal function to resolve an emergency
     */
    function _resolveEmergency(uint256 _emergencyId) internal {
        EmergencyEvent storage emergency = emergencyEvents[_emergencyId];
        require(emergency.isActive, "CEP: Emergency not active");
        
        emergency.isActive = false;
        emergency.resolvedAt = block.timestamp;
        
        // Remove from active emergencies
        for (uint256 i = 0; i < activeEmergencies.length; i++) {
            if (activeEmergencies[i] == _emergencyId) {
                activeEmergencies[i] = activeEmergencies[activeEmergencies.length - 1];
                activeEmergencies.pop();
                break;
            }
        }
        
        emit EmergencyResolved(_emergencyId, block.timestamp);
    }

    /**
     * @dev Update trigger condition
     */
    function updateTriggerCondition(
        string memory _metric,
        uint256 _threshold,
        uint256 _duration,
        bool _enabled,
        address _oracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TriggerCondition storage condition = triggerConditions[_metric];
        condition.threshold = _threshold;
        condition.duration = _duration;
        condition.enabled = _enabled;
        condition.oracle = AggregatorV3Interface(_oracle);
        
        emit TriggerConditionUpdated(_metric, _threshold, _duration);
    }

    /**
     * @dev Get active emergencies
     */
    function getActiveEmergencies() external view returns (uint256[] memory) {
        return activeEmergencies;
    }

    /**
     * @dev Get TWAM metric value
     */
    function getTWAMValue(string memory _metric) external view returns (uint256) {
        return twamMetrics[_metric].currentValue;
    }

    /**
     * @dev Get all active metrics
     */
    function getActiveMetrics() external view returns (string[] memory) {
        return activeMetrics;
    }

    /**
     * @dev Queue or approve an emergency pause request.
     * The contract pauses only after 2 pause guardians approve and the
     * 24-hour timelock elapses.
     */
    function requestPause() external onlyRole(PAUSE_GUARDIAN_ROLE) whenNotPaused {
        if (!pauseRequestActive) {
            pauseRequestActive = true;
            pauseRequestedAt = block.timestamp;
            pauseApprovalCount = 0;
            pauseRequestNonce += 1;
        }

        require(
            !pauseApprovals[pauseRequestNonce][msg.sender],
            "CEP: Pause already approved"
        );

        pauseApprovals[pauseRequestNonce][msg.sender] = true;
        pauseApprovalCount += 1;

        emit PauseRequested(
            pauseRequestNonce,
            msg.sender,
            pauseApprovalCount,
            pauseRequestedAt + PAUSE_TIMELOCK
        );
    }

    /**
     * @dev Execute the queued emergency pause after multisig approval and timelock.
     */
    function pause() external onlyRole(PAUSE_GUARDIAN_ROLE) whenNotPaused {
        require(pauseRequestActive, "CEP: Pause not requested");
        require(pauseApprovalCount >= PAUSE_THRESHOLD, "CEP: Insufficient pause approvals");
        require(
            block.timestamp >= pauseRequestedAt + PAUSE_TIMELOCK,
            "CEP: Pause timelock not elapsed"
        );

        _pause();
        emit PauseExecuted(pauseRequestNonce, msg.sender, block.timestamp);
        _resetPauseRequestState();
    }

    /**
     * @dev Unpause function
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    /**
     * @dev Reset pause governance state after execution.
     */
    function _resetPauseRequestState() internal {
        pauseRequestActive = false;
        pauseRequestedAt = 0;
        pauseApprovalCount = 0;
    }
}
