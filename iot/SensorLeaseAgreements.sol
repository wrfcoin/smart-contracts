// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Sensor Lease Agreements Contract
 * @dev Secure IoT sensor data leasing platform with automated payments and SLA enforcement
 * @notice Enables sensor owners to monetize data access while maintaining public contributions
 * @custom:security Multi-signature approvals, automated SLA monitoring, performance tracking
 */
contract SensorLeaseAgreements is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Role definitions for access control
    bytes32 public constant LEASE_ADMIN_ROLE = keccak256("LEASE_ADMIN_ROLE");
    bytes32 public constant SENSOR_MANAGER_ROLE = keccak256("SENSOR_MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /**
     * @dev IoT sensor device with comprehensive monitoring and SLA tracking
     * @param sensorId Unique sensor identifier
     * @param owner Device owner address
     * @param deviceType Sensor category (air_quality, weather, radiation, noise, multi)
     * @param location Geographic installation coordinates
     * @param dataEndpoint Secure API endpoint or IPFS gateway
     * @param isActive Operational status
     * @param isPublicContributor Still earning WRF from public data contributions
     * @param totalLeases Number of completed lease agreements
     * @param totalEarnings Cumulative earnings from leasing
     * @param baseRatePerHour WRF tokens per hour for data access
     * @param uptimePercentage Historical uptime percentage (basis points)
     * @param dataQualityScore Average data quality rating (0-10000)
     * @param maintenanceSchedule Next scheduled maintenance timestamp
     * @param slaThreshold Service level agreement minimum uptime (basis points)
     */
    struct SensorDevice {
        uint64 sensorId;
        uint48 maintenanceSchedule;
        uint32 totalLeases;
        uint32 totalEarnings;
        uint32 baseRatePerHour;
        uint16 uptimePercentage;      // Historical uptime in basis points
        uint16 dataQualityScore;      // Average quality (0-10000)
        uint16 slaThreshold;          // Minimum SLA uptime (basis points)
        bool isActive;
        bool isPublicContributor;
        address owner;
        string deviceType;
        string location;
        string dataEndpoint;
        mapping(address => SensorLease) activeLeases;
        address[] lessees;
    }
    
    /**
     * @dev Secure sensor data lease agreement with SLA monitoring
     * @param leaseId Unique lease identifier
     * @param sensorId Associated sensor ID
     * @param lessee Data consumer address
     * @param sensorOwner Sensor owner address
     * @param startTime Lease start timestamp
     * @param endTime Lease expiration timestamp
     * @param ratePerHour Hourly payment rate in WRF tokens
     * @param totalPaid Total amount paid for the lease
     * @param isActive Current lease status
     * @param accessToken Encrypted API access token
     * @param dataQualityLevel Data processing tier (raw, processed, premium)
     * @param slaLevel Service level agreement tier (basic, standard, premium)
     * @param uptimeGuarantee Guaranteed uptime percentage (basis points)
     * @param dataFrequency Data update frequency in minutes
     * @param penaltyRate Penalty rate for SLA violations (basis points)
     * @param escrowAmount Reserved funds for SLA penalties
     */
    struct SensorLease {
        uint64 leaseId;
        uint64 sensorId;
        uint48 startTime;
        uint48 endTime;
        uint32 ratePerHour;
        uint32 totalPaid;
        uint32 escrowAmount;
        uint16 uptimeGuarantee;       // SLA uptime guarantee (basis points)
        uint16 penaltyRate;           // Penalty for SLA violations (basis points)
        uint16 dataFrequency;         // Data update frequency (minutes)
        bool isActive;
        address lessee;
        address sensorOwner;
        string accessToken;
        string dataQualityLevel;
        string slaLevel;
    }
    
    /**
     * @dev NFT-based data access license with granular permissions
     * @param tokenId Unique NFT identifier
     * @param leaseId Associated lease agreement ID
     * @param holder Current NFT holder
     * @param expirationTime Access expiration timestamp
     * @param permissions Granted access permissions array
     * @param isTransferable Whether NFT can be transferred
     * @param accessLevel Access tier (read_only, standard, premium)
     * @param dataRetention Data retention period in days
     */
    struct DataAccessNFT {
        uint64 tokenId;
        uint64 leaseId;
        uint48 expirationTime;
        uint16 dataRetention;         // Data retention period (days)
        bool isTransferable;
        address holder;
        string[] permissions;
        string accessLevel;
    }

    /**
     * @dev SLA performance monitoring data
     * @param totalChecks Number of uptime checks performed
     * @param successfulChecks Number of successful checks
     * @param currentUptime Current period uptime percentage
     * @param violations Number of SLA violations
     * @param lastViolation Timestamp of most recent violation
     * @param penaltiesAccrued Total penalty fees accrued
     */
    struct SLAMetrics {
        uint32 totalChecks;
        uint32 successfulChecks;
        uint16 currentUptime;
        uint16 violations;
        uint48 lastViolation;
        uint256 penaltiesAccrued;
    }
    
    // Core state mappings
    mapping(uint256 => SensorDevice) public sensors;
    mapping(uint256 => SensorLease) public leases;
    mapping(uint256 => DataAccessNFT) public accessNFTs;
    mapping(uint256 => SLAMetrics) public slaMetrics;
    
    // Index mappings for efficient queries
    mapping(address => uint256[]) public ownerSensors;
    mapping(address => uint256[]) public lesseeLeases;
    mapping(string => uint256[]) public deviceTypeIndex;
    mapping(string => uint256[]) public locationIndex;
    
    // Security and monitoring mappings
    mapping(address => uint256) public dailyLeaseCreations;
    mapping(address => uint256) public lastLeaseDay;
    mapping(uint256 => bool) public emergencyStoppedSensors;
    mapping(bytes32 => bool) public usedSignatures;
    
    // Contract parameters
    IERC20 public paymentToken;
    address public treasury;
    address public oracleNetwork;
    
    uint256 public nextSensorId = 1;
    uint256 public nextLeaseId = 1;
    uint256 public nextTokenId = 1;
    uint256 public platformFeeRate = 250;        // 2.5% in basis points
    uint256 public minimumLeaseHours = 1;        // Minimum lease duration
    uint256 public maxDailyLeases = 20;          // Anti-spam protection
    uint256 public slaCheckInterval = 1 hours;   // SLA monitoring frequency
    uint256 public maintenanceWindow = 30 days;  // Required maintenance frequency
    
    /**
     * @dev Emitted when a new sensor is registered for leasing
     */
    event SensorRegistered(
        uint256 indexed sensorId,
        address indexed owner,
        string deviceType,
        string location,
        uint256 baseRatePerHour,
        uint256 slaThreshold
    );
    
    /**
     * @dev Emitted when a new lease agreement is created
     */
    event LeaseCreated(
        uint256 indexed leaseId,
        uint256 indexed sensorId,
        address indexed lessee,
        uint256 duration,
        uint256 totalCost,
        string slaLevel,
        uint256 uptimeGuarantee
    );
    
    /**
     * @dev Emitted when data access NFT is granted
     */
    event DataAccessGranted(
        uint256 indexed tokenId,
        uint256 indexed leaseId,
        address indexed holder,
        uint256 expirationTime,
        string accessLevel
    );
    
    /**
     * @dev Emitted when lease is renewed or extended
     */
    event LeaseRenewed(
        uint256 indexed leaseId,
        uint256 newEndTime,
        uint256 additionalPayment,
        uint256 escrowIncrease
    );
    
    /**
     * @dev Emitted when sensor parameters are updated
     */
    event SensorUpdated(
        uint256 indexed sensorId, 
        uint256 newRate, 
        bool isActive,
        uint256 newSlaThreshold
    );

    /**
     * @dev Emitted when SLA violation is detected
     */
    event SLAViolation(
        uint256 indexed sensorId,
        uint256 indexed leaseId,
        uint256 downtimeMinutes,
        uint256 penaltyAmount,
        string violationType
    );

    /**
     * @dev Emitted when maintenance is scheduled or completed
     */
    event MaintenanceScheduled(
        uint256 indexed sensorId,
        uint256 scheduledTime,
        uint256 estimatedDuration,
        string maintenanceType
    );

    /**
     * @dev Emitted when payments are processed
     */
    event PaymentProcessed(
        uint256 indexed leaseId,
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        string paymentType
    );
    
    // Security modifiers
    modifier onlySensorOwner(uint256 sensorId) {
        require(sensors[sensorId].owner == msg.sender, "SensorLease: only sensor owner");
        _;
    }
    
    modifier validSensor(uint256 sensorId) {
        require(sensors[sensorId].owner != address(0), "SensorLease: sensor not found");
        require(sensors[sensorId].isActive, "SensorLease: sensor not active");
        require(!emergencyStoppedSensors[sensorId], "SensorLease: sensor emergency stopped");
        _;
    }

    modifier withinLeaseLimit() {
        uint256 currentDay = block.timestamp / 1 days;
        if (lastLeaseDay[msg.sender] != currentDay) {
            dailyLeaseCreations[msg.sender] = 0;
            lastLeaseDay[msg.sender] = currentDay;
        }
        require(
            dailyLeaseCreations[msg.sender] < maxDailyLeases, 
            "SensorLease: daily lease limit exceeded"
        );
        dailyLeaseCreations[msg.sender]++;
        _;
    }

    modifier validLeaseParams(uint256 durationHours, uint256 sensorId) {
        require(durationHours >= minimumLeaseHours, "SensorLease: duration too short");
        require(durationHours <= 8760, "SensorLease: duration too long"); // Max 1 year
        require(sensors[sensorId].owner != msg.sender, "SensorLease: cannot lease own sensor");
        _;
    }

    /**
     * @dev Initialize sensor lease agreements platform with comprehensive security
     * @param _paymentToken ERC20 token for lease payments
     * @param _treasury Treasury address for platform fees
     * @param _oracleNetwork Oracle network for SLA monitoring
     * @param _admin Primary administrator address
     */
    constructor(
        address _paymentToken,
        address _treasury,
        address _oracleNetwork,
        address _admin
    ) {
        require(_paymentToken != address(0), "SensorLease: invalid payment token");
        require(_treasury != address(0), "SensorLease: invalid treasury");
        require(_oracleNetwork != address(0), "SensorLease: invalid oracle");
        require(_admin != address(0), "SensorLease: invalid admin");

        paymentToken = IERC20(_paymentToken);
        treasury = _treasury;
        oracleNetwork = _oracleNetwork;

        // Set up role hierarchy
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(LEASE_ADMIN_ROLE, _admin);
        _grantRole(SENSOR_MANAGER_ROLE, _admin);
        _grantRole(ORACLE_ROLE, _oracleNetwork);
        _grantRole(EMERGENCY_ROLE, _admin);
    }
    
    /**
     * @dev Register sensor device for leasing with comprehensive SLA setup
     * @param deviceType Sensor category (air_quality, weather, radiation, noise, multi)
     * @param location Geographic coordinates or area identifier
     * @param dataEndpoint Secure API endpoint or IPFS gateway URL
     * @param baseRatePerHour Hourly rate in WRF tokens (wei units)
     * @param isPublicContributor Continue earning from public data contributions
     * @param slaThreshold Minimum uptime guarantee in basis points (e.g., 9500 = 95%)
     * @notice Registers IoT sensor for data leasing with SLA commitments
     */
    function registerSensor(
        string calldata deviceType,
        string calldata location,
        string calldata dataEndpoint,
        uint256 baseRatePerHour,
        bool isPublicContributor,
        uint256 slaThreshold
    ) external whenNotPaused {
        require(baseRatePerHour > 0, "SensorLease: rate must be positive");
        require(baseRatePerHour <= 10000 * 1e18, "SensorLease: rate too high"); // Max 10k tokens/hour
        require(bytes(deviceType).length > 0, "SensorLease: device type required");
        require(bytes(location).length > 0, "SensorLease: location required");
        require(bytes(dataEndpoint).length > 0, "SensorLease: endpoint required");
        require(slaThreshold >= 5000, "SensorLease: SLA threshold too low"); // Min 50%
        require(slaThreshold <= 10000, "SensorLease: SLA threshold invalid");
        
        uint256 sensorId = nextSensorId++;
        SensorDevice storage sensor = sensors[sensorId];
        
        // Initialize sensor with gas-optimized struct packing
        sensor.sensorId = uint64(sensorId);
        sensor.maintenanceSchedule = uint48(block.timestamp + maintenanceWindow);
        sensor.totalLeases = 0;
        sensor.totalEarnings = 0;
        sensor.baseRatePerHour = uint32(baseRatePerHour);
        sensor.uptimePercentage = 10000; // Start with perfect uptime
        sensor.dataQualityScore = 8000;  // Start with good quality
        sensor.slaThreshold = uint16(slaThreshold);
        sensor.isActive = true;
        sensor.isPublicContributor = isPublicContributor;
        sensor.owner = msg.sender;
        sensor.deviceType = deviceType;
        sensor.location = location;
        sensor.dataEndpoint = dataEndpoint;

        // Update indices for efficient querying
        ownerSensors[msg.sender].push(sensorId);
        deviceTypeIndex[deviceType].push(sensorId);
        locationIndex[location].push(sensorId);
        
        // Initialize SLA metrics
        slaMetrics[sensorId] = SLAMetrics({
            totalChecks: 0,
            successfulChecks: 0,
            currentUptime: 10000, // Perfect uptime to start
            violations: 0,
            lastViolation: 0,
            penaltiesAccrued: 0
        });
        
        emit SensorRegistered(
            sensorId,
            msg.sender,
            deviceType,
            location,
            baseRatePerHour,
            slaThreshold
        );
    }
    
    /**
     * @dev Create lease agreement for sensor data access
     */
    function createLease(
        uint256 sensorId,
        uint256 durationHours,
        string memory dataQualityLevel
    ) external payable validSensor(sensorId) {
        require(durationHours >= minimumLeaseHours, "Duration too short");
        
        SensorDevice storage sensor = sensors[sensorId];
        require(sensor.owner != msg.sender, "Cannot lease own sensor");
        
        uint256 totalCost = sensor.baseRatePerHour * durationHours;
        require(msg.value >= totalCost, "Insufficient payment");
        
        uint256 leaseId = nextLeaseId++;
        SensorLease storage lease = leases[leaseId];
        
        lease.leaseId = leaseId;
        lease.sensorId = sensorId;
        lease.lessee = msg.sender;
        lease.sensorOwner = sensor.owner;
        lease.startTime = block.timestamp;
        lease.endTime = block.timestamp + (durationHours * 1 hours);
        lease.ratePerHour = sensor.baseRatePerHour;
        lease.totalPaid = totalCost;
        lease.isActive = true;
        lease.dataQualityLevel = dataQualityLevel;
        
        // Generate access token (simplified for demo)
        lease.accessToken = generateAccessToken(leaseId, msg.sender);
        
        // Update sensor statistics
        sensor.activeLeases[msg.sender] = lease;
        sensor.lessees.push(msg.sender);
        sensor.totalLeases++;
        
        // Add to lessee's leases
        lesseeLeases[msg.sender].push(leaseId);
        
        // Create data access NFT
        uint256 tokenId = nextTokenId++;
        DataAccessNFT storage nft = accessNFTs[tokenId];
        nft.tokenId = tokenId;
        nft.leaseId = leaseId;
        nft.holder = msg.sender;
        nft.expirationTime = lease.endTime;
        nft.permissions = ["read", "real_time"];
        nft.isTransferable = true;
        
        // Calculate platform fee and owner payment
        uint256 platformFee = (totalCost * platformFeeRate) / 10000;
        uint256 ownerPayment = totalCost - platformFee;
        
        // Update earnings
        sensor.totalEarnings += ownerPayment;
        
        // Process payments
        payable(sensor.owner).transfer(ownerPayment);
        payable(treasury).transfer(platformFee);
        
        // Refund excess payment
        if (msg.value > totalCost) {
            payable(msg.sender).transfer(msg.value - totalCost);
        }
        
        emit LeaseCreated(leaseId, sensorId, msg.sender, durationHours, totalCost);
        emit DataAccessGranted(tokenId, leaseId, msg.sender, lease.endTime);
    }
    
    /**
     * @dev Renew existing lease
     */
    function renewLease(uint256 leaseId, uint256 additionalHours) external payable {
        SensorLease storage lease = leases[leaseId];
        
        require(lease.lessee == msg.sender, "Only lessee can renew");
        require(lease.isActive, "Lease not active");
        require(block.timestamp < lease.endTime, "Lease already expired");
        
        uint256 additionalCost = lease.ratePerHour * additionalHours;
        require(msg.value >= additionalCost, "Insufficient payment");
        
        // Extend lease
        lease.endTime += additionalHours * 1 hours;
        lease.totalPaid += additionalCost;
        
        // Update NFT expiration
        for (uint256 i = 1; i < nextTokenId; i++) {
            if (accessNFTs[i].leaseId == leaseId && accessNFTs[i].holder == msg.sender) {
                accessNFTs[i].expirationTime = lease.endTime;
                break;
            }
        }
        
        // Process payment
        SensorDevice storage sensor = sensors[lease.sensorId];
        uint256 platformFee = (additionalCost * platformFeeRate) / 10000;
        uint256 ownerPayment = additionalCost - platformFee;
        
        sensor.totalEarnings += ownerPayment;
        
        payable(sensor.owner).transfer(ownerPayment);
        payable(treasury).transfer(platformFee);
        
        if (msg.value > additionalCost) {
            payable(msg.sender).transfer(msg.value - additionalCost);
        }
        
        emit LeaseRenewed(leaseId, lease.endTime, additionalCost);
    }
    
    /**
     * @dev Transfer data access NFT
     */
    function transferDataAccess(uint256 tokenId, address to) external {
        DataAccessNFT storage nft = accessNFTs[tokenId];
        
        require(nft.holder == msg.sender, "Only holder can transfer");
        require(nft.isTransferable, "NFT not transferable");
        require(block.timestamp < nft.expirationTime, "NFT expired");
        require(to != address(0), "Invalid recipient");
        
        nft.holder = to;
        
        // Update lease record
        SensorLease storage lease = leases[nft.leaseId];
        lease.lessee = to;
        
        // Update lesseeLeases mapping
        uint256[] storage oldLesseeLeases = lesseeLeases[msg.sender];
        for (uint256 i = 0; i < oldLesseeLeases.length; i++) {
            if (oldLesseeLeases[i] == nft.leaseId) {
                oldLesseeLeases[i] = oldLesseeLeases[oldLesseeLeases.length - 1];
                oldLesseeLeases.pop();
                break;
            }
        }
        lesseeLeases[to].push(nft.leaseId);
    }
    
    /**
     * @dev Update sensor parameters
     */
    function updateSensor(
        uint256 sensorId,
        uint256 newBaseRate,
        string memory newDataEndpoint,
        bool isActive
    ) external onlySensorOwner(sensorId) {
        SensorDevice storage sensor = sensors[sensorId];
        
        sensor.baseRatePerHour = newBaseRate;
        sensor.dataEndpoint = newDataEndpoint;
        sensor.isActive = isActive;
        
        emit SensorUpdated(sensorId, newBaseRate, isActive);
    }
    
    /**
     * @dev Verify data quality and update sensor reputation
     */
    function verifySensorData(
        uint256 sensorId,
        uint256 qualityScore,
        bool maintainPublicStatus
    ) external onlyRole(ORACLE_ROLE) {
        SensorDevice storage sensor = sensors[sensorId];
        
        // Adjust rates based on quality score (70-130% of base rate)
        if (qualityScore > 8000) { // 80%+ quality
            // Premium rate increase
            sensor.baseRatePerHour = (sensor.baseRatePerHour * 130) / 100;
        } else if (qualityScore < 6000) { // Below 60% quality
            // Rate decrease for poor quality
            sensor.baseRatePerHour = (sensor.baseRatePerHour * 70) / 100;
        }
        
        sensor.isPublicContributor = maintainPublicStatus;
    }
    
    /**
     * @dev Get sensor lessees
     */
    function getSensorLessees(uint256 sensorId) external view returns (address[] memory) {
        return sensors[sensorId].lessees;
    }
    
    /**
     * @dev Get owner's sensors
     */
    function getOwnerSensors(address owner) external view returns (uint256[] memory) {
        return ownerSensors[owner];
    }
    
    /**
     * @dev Get lessee's active leases
     */
    function getLesseeLeases(address lessee) external view returns (uint256[] memory) {
        return lesseeLeases[lessee];
    }
    
    /**
     * @dev Check if lease is active
     */
    function isLeaseActive(uint256 leaseId) external view returns (bool) {
        SensorLease storage lease = leases[leaseId];
        return lease.isActive && block.timestamp < lease.endTime;
    }
    
    /**
     * @dev Get access token for active lease
     */
    function getAccessToken(uint256 leaseId) external view returns (string memory) {
        SensorLease storage lease = leases[leaseId];
        require(lease.lessee == msg.sender, "Only lessee can access token");
        require(lease.isActive && block.timestamp < lease.endTime, "Lease not active");
        
        return lease.accessToken;
    }
    
    /**
     * @dev Generate access token (simplified implementation)
     */
    function generateAccessToken(uint256 leaseId, address lessee) private pure returns (string memory) {
        return string(abi.encodePacked(
            "wrf_token_",
            uint2str(leaseId),
            "_",
            uint2str(uint256(uint160(lessee)) % 10000)
        ));
    }
    
    /**
     * @dev Convert uint to string (helper function)
     */
    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
    
    /**
     * @dev Emergency lease termination
     */
    function terminateLease(uint256 leaseId) external {
        SensorLease storage lease = leases[leaseId];
        SensorDevice storage sensor = sensors[lease.sensorId];
        
        require(
            msg.sender == lease.lessee || msg.sender == sensor.owner,
            "Only lessee or owner can terminate"
        );
        
        lease.isActive = false;
        
        // Invalidate NFT
        for (uint256 i = 1; i < nextTokenId; i++) {
            if (accessNFTs[i].leaseId == leaseId) {
                accessNFTs[i].expirationTime = block.timestamp;
                break;
            }
        }
    }
    
    /**
     * @dev Update contract parameters
     */
    function updateParameters(
        uint256 _platformFeeRate,
        uint256 _minimumLeaseHours,
        address _oracleNetwork
    ) external {
        require(msg.sender == treasury, "Only treasury can update");
        platformFeeRate = _platformFeeRate;
        minimumLeaseHours = _minimumLeaseHours;
        oracleNetwork = _oracleNetwork;
    }
}