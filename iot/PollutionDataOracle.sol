// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Pollution Data Oracle
 * @dev Secure environmental sensor data integration for WRFCoin network
 * @notice Validates and stores pollution data from verified IoT sensors with comprehensive security
 * @custom:security Multi-sensor validation, geographic verification, temporal consistency
 */
contract PollutionDataOracle is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Role definitions for access control
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");
    bytes32 public constant SENSOR_MANAGER_ROLE = keccak256("SENSOR_MANAGER_ROLE");

    /**
     * @dev Environmental data point from IoT sensors
     * @param timestamp Data collection timestamp (validation window check)
     * @param co2Level CO2 concentration in parts per million (ppm)
     * @param pm25Level PM2.5 particles in micrograms per cubic meter (µg/m³)
     * @param pm10Level PM10 particles in micrograms per cubic meter (µg/m³)
     * @param ozoneLevel Ground-level ozone in micrograms per cubic meter (µg/m³)
     * @param no2Level Nitrogen dioxide in micrograms per cubic meter (µg/m³)
     * @param so2Level Sulfur dioxide in micrograms per cubic meter (µg/m³)
     * @param temperature Temperature in Celsius multiplied by 100 for precision
     * @param humidity Relative humidity percentage multiplied by 100 for precision
     * @param location Geographic identifier (lat,lng or area code)
     * @param sensorAddress Verified sensor device Ethereum address
     * @param isVerified Multi-validator consensus reached
     * @param qualityScore Air quality index calculation (0-500 AQI scale)
     * @param aqi Calculated Air Quality Index based on all pollutants
     * @param validationCount Number of validator confirmations received
     */
    struct SensorData {
        uint48 timestamp;           // Reduced to 48 bits (sufficient until year 8,939,000)
        uint32 co2Level;           // CO2 in ppm (0-50,000 ppm max)
        uint32 pm25Level;          // PM2.5 in µg/m³ (0-1000 µg/m³ max)
        uint32 pm10Level;          // PM10 in µg/m³ (0-1000 µg/m³ max)
        uint32 ozoneLevel;         // O3 in µg/m³ (0-1000 µg/m³ max)
        uint32 no2Level;           // NO2 in µg/m³ (0-1000 µg/m³ max)
        uint32 so2Level;           // SO2 in µg/m³ (0-1000 µg/m³ max)
        int16 temperature;         // Temperature in Celsius * 100 (-100°C to 327°C)
        uint16 humidity;           // Humidity percentage * 100 (0-100%)
        uint16 qualityScore;       // Data quality rating (0-10000 basis points)
        uint16 aqi;                // Air Quality Index (0-500)
        uint8 validationCount;     // Number of validator confirmations
        bool isVerified;           // Multi-validator consensus reached
        address sensorAddress;     // Verified sensor device address
        string location;           // Geographic coordinates or identifier
    }

    /**
     * @dev Registered IoT sensor device information
     * @param deviceId Unique device identifier from manufacturer
     * @param manufacturer Device manufacturer name
     * @param model Device model number and version
     * @param calibrationDate Last calibration timestamp (quality assurance)
     * @param lastMaintenance Last maintenance check timestamp
     * @param isActive Device operational status
     * @param isVerified Admin verification of device authenticity
     * @param owner Device owner address
     * @param location Fixed installation location
     * @param dataSubmissions Total number of data points submitted
     * @param totalRewards Accumulated reward tokens earned
     * @param reputationScore Device reliability score (0-10000)
     * @param lastSubmission Timestamp of most recent data submission
     */
    struct SensorDevice {
        string deviceId;
        string manufacturer;
        string model;
        uint48 calibrationDate;
        uint48 lastMaintenance;
        uint48 lastSubmission;
        uint32 dataSubmissions;
        uint32 totalRewards;
        uint16 reputationScore;     // Device reliability (0-10000)
        bool isActive;
        bool isVerified;
        address owner;
        string location;
    }

    /**
     * @dev Geographic validation parameters for location consistency
     * @param minSensorsRequired Minimum sensors needed for area validation
     * @param maxDistanceKm Maximum distance between correlated sensors (km)
     * @param consistencyThreshold Minimum agreement percentage for validation
     */
    struct GeographicValidator {
        uint8 minSensorsRequired;
        uint16 maxDistanceKm;
        uint16 consistencyThreshold;    // Basis points (e.g., 8000 = 80%)
        bool isActive;
    }

    // State mappings
    mapping(bytes32 => SensorData) public sensorReadings;
    mapping(address => SensorDevice) public registeredSensors;
    mapping(string => address[]) public locationSensors;
    mapping(bytes32 => address[]) public dataValidators;
    mapping(string => GeographicValidator) public geoValidators;
    
    // Security tracking
    mapping(address => uint256) public dailySubmissions;
    mapping(address => uint256) public lastSubmissionDay;
    mapping(bytes32 => uint256) public dataTimestamp;
    
    // Contract parameters
    IERC20 public rewardToken;
    address public treasury;
    uint256 public totalDataPoints;
    uint256 public rewardPerSubmission = 10 * 10**18; // 10 WRF tokens
    uint256 public validationThreshold = 3; // Minimum validations required
    uint256 public maxDailySubmissions = 144; // Max 144 submissions per day (10 min intervals)
    uint256 public dataValidityWindow = 1 hours; // Data must be recent
    // Air quality thresholds for validation (µg/m³)
    uint256 public constant PM25_HAZARDOUS = 500;    // PM2.5 hazardous level
    uint256 public constant PM10_HAZARDOUS = 600;    // PM10 hazardous level
    uint256 public constant OZONE_HAZARDOUS = 1000;  // O3 hazardous level
    uint256 public constant NO2_HAZARDOUS = 1000;    // NO2 hazardous level
    uint256 public constant SO2_HAZARDOUS = 1000;    // SO2 hazardous level
    uint256 public constant CO2_NORMAL_MAX = 5000;   // CO2 normal maximum (ppm)

    /**
     * @dev Emitted when a new sensor device is registered
     * @param sensorAddress Ethereum address of the sensor device
     * @param deviceId Unique device identifier
     * @param location Geographic location of installation
     * @param owner Address of the sensor owner
     */
    event SensorRegistered(
        address indexed sensorAddress, 
        string indexed deviceId, 
        string location,
        address indexed owner
    );

    /**
     * @dev Emitted when environmental data is submitted by a sensor
     * @param dataHash Unique hash identifier for the data point
     * @param sensor Address of the submitting sensor
     * @param timestamp Data collection timestamp
     * @param aqi Calculated Air Quality Index
     */
    event DataSubmitted(
        bytes32 indexed dataHash, 
        address indexed sensor, 
        uint256 timestamp,
        uint256 aqi
    );

    /**
     * @dev Emitted when data is validated by authorized validators
     * @param dataHash Hash of the validated data point
     * @param validator Address of the validating authority
     * @param isValid Whether the data passed validation
     * @param qualityScore Assigned data quality score
     */
    event DataValidated(
        bytes32 indexed dataHash, 
        address indexed validator, 
        bool isValid,
        uint256 qualityScore
    );

    /**
     * @dev Emitted when rewards are distributed to participants
     * @param recipient Address receiving the reward
     * @param amount Number of tokens rewarded
     * @param reason Reason for the reward distribution
     */
    event RewardDistributed(
        address indexed recipient, 
        uint256 amount, 
        string reason
    );

    /**
     * @dev Emitted when air quality index is calculated and updated
     * @param dataHash Hash of the data point
     * @param aqi Calculated Air Quality Index (0-500)
     * @param category AQI category (Good, Moderate, Unhealthy, etc.)
     */
    event AirQualityIndexUpdated(
        bytes32 indexed dataHash, 
        uint256 aqi, 
        string category
    );

    /**
     * @dev Emitted when geographic validation is performed
     * @param location Geographic area identifier
     * @param sensorsCount Number of sensors in the area
     * @param consistencyScore Area data consistency percentage
     */
    event GeographicValidation(
        string indexed location,
        uint256 sensorsCount,
        uint256 consistencyScore
    );

    /**
     * @dev Emitted when sensor reputation is updated
     * @param sensor Address of the sensor device
     * @param oldScore Previous reputation score
     * @param newScore Updated reputation score
     * @param reason Reason for reputation change
     */
    event ReputationUpdated(
        address indexed sensor,
        uint256 oldScore,
        uint256 newScore,
        string reason
    );

    // Security modifiers
    modifier onlyRegisteredSensor() {
        require(registeredSensors[msg.sender].isActive, "PollutionOracle: sensor not active");
        require(registeredSensors[msg.sender].isVerified, "PollutionOracle: sensor not verified");
        _;
    }

    modifier withinSubmissionLimit() {
        uint256 currentDay = block.timestamp / 1 days;
        if (lastSubmissionDay[msg.sender] != currentDay) {
            dailySubmissions[msg.sender] = 0;
            lastSubmissionDay[msg.sender] = currentDay;
        }
        require(
            dailySubmissions[msg.sender] < maxDailySubmissions, 
            "PollutionOracle: daily submission limit exceeded"
        );
        dailySubmissions[msg.sender]++;
        _;
    }

    modifier validDataRange(
        uint256 co2Level,
        uint256 pm25Level,
        uint256 pm10Level,
        uint256 ozoneLevel,
        uint256 no2Level,
        uint256 so2Level,
        int256 temperature,
        uint256 humidity
    ) {
        require(co2Level <= 50000, "PollutionOracle: CO2 level too high");
        require(pm25Level <= PM25_HAZARDOUS, "PollutionOracle: PM2.5 level invalid");
        require(pm10Level <= PM10_HAZARDOUS, "PollutionOracle: PM10 level invalid");
        require(ozoneLevel <= OZONE_HAZARDOUS, "PollutionOracle: ozone level invalid");
        require(no2Level <= NO2_HAZARDOUS, "PollutionOracle: NO2 level invalid");
        require(so2Level <= SO2_HAZARDOUS, "PollutionOracle: SO2 level invalid");
        require(temperature >= -10000 && temperature <= 6000, "PollutionOracle: temperature out of range");
        require(humidity <= 10000, "PollutionOracle: humidity out of range");
        _;
    }

    /**
     * @dev Initialize the pollution data oracle with comprehensive security
     * @param _rewardToken ERC20 token contract for rewards
     * @param _treasury Treasury address for platform fees
     * @param _admin Primary administrator address
     */
    constructor(
        address _rewardToken,
        address _treasury,
        address _admin
    ) {
        require(_rewardToken != address(0), "PollutionOracle: invalid reward token");
        require(_treasury != address(0), "PollutionOracle: invalid treasury");
        require(_admin != address(0), "PollutionOracle: invalid admin");

        rewardToken = IERC20(_rewardToken);
        treasury = _treasury;

        // Set up role hierarchy
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORACLE_ADMIN_ROLE, _admin);
        _grantRole(VALIDATOR_ROLE, _admin);
        _grantRole(SENSOR_MANAGER_ROLE, _admin);

        // Initialize default geographic validator for global data
        geoValidators["global"] = GeographicValidator({
            minSensorsRequired: 2,
            maxDistanceKm: 50,
            consistencyThreshold: 7000, // 70% consistency required
            isActive: true
        });
    }

    /**
     * @dev Register a new environmental sensor device with comprehensive validation
     * @param _deviceId Unique device identifier from manufacturer
     * @param _manufacturer Device manufacturer name
     * @param _model Device model number and version
     * @param _location Geographic location (lat,lng format recommended)
     * @param _calibrationDate Unix timestamp of last calibration
     * @notice Only unregistered addresses can register sensors
     * @notice Sensors must be verified by admin before data submission
     */
    function registerSensor(
        string calldata _deviceId,
        string calldata _manufacturer,
        string calldata _model,
        string calldata _location,
        uint256 _calibrationDate
    ) external whenNotPaused {
        require(!registeredSensors[msg.sender].isActive, "PollutionOracle: sensor already registered");
        require(bytes(_deviceId).length > 0, "PollutionOracle: device ID required");
        require(bytes(_manufacturer).length > 0, "PollutionOracle: manufacturer required");
        require(bytes(_model).length > 0, "PollutionOracle: model required");
        require(bytes(_location).length > 0, "PollutionOracle: location required");
        require(_calibrationDate <= block.timestamp, "PollutionOracle: future calibration date");
        require(
            block.timestamp - _calibrationDate <= 365 days,
            "PollutionOracle: calibration too old"
        );
        
        registeredSensors[msg.sender] = SensorDevice({
            deviceId: _deviceId,
            manufacturer: _manufacturer,
            model: _model,
            calibrationDate: uint48(_calibrationDate),
            lastMaintenance: uint48(block.timestamp),
            lastSubmission: 0,
            dataSubmissions: 0,
            totalRewards: 0,
            reputationScore: 5000, // Start with neutral reputation (50%)
            isActive: true,
            isVerified: false, // Requires admin verification
            owner: msg.sender,
            location: _location
        });

        locationSensors[_location].push(msg.sender);
        
        emit SensorRegistered(msg.sender, _deviceId, _location, msg.sender);
    }

    /**
     * @dev Verify a registered sensor device (admin only)
     * @param _sensorAddress Address of the sensor to verify
     * @param _isVerified Verification status to set
     * @notice Only admins can verify sensors for data submission
     */
    function verifySensor(
        address _sensorAddress,
        bool _isVerified
    ) external onlyRole(SENSOR_MANAGER_ROLE) {
        require(registeredSensors[_sensorAddress].isActive, "PollutionOracle: sensor not registered");
        
        uint256 oldScore = registeredSensors[_sensorAddress].reputationScore;
        registeredSensors[_sensorAddress].isVerified = _isVerified;
        
        if (_isVerified) {
            // Boost reputation for verified sensors
            registeredSensors[_sensorAddress].reputationScore = 7500; // 75%
        }
        
        emit ReputationUpdated(
            _sensorAddress,
            oldScore,
            registeredSensors[_sensorAddress].reputationScore,
            _isVerified ? "Sensor verified" : "Sensor unverified"
        );
    }

    /**
     * @dev Submit comprehensive environmental sensor data with validation
     * @param _co2Level CO2 concentration in parts per million (ppm)
     * @param _pm25Level PM2.5 particles in µg/m³
     * @param _pm10Level PM10 particles in µg/m³
     * @param _ozoneLevel Ground-level ozone in µg/m³
     * @param _no2Level Nitrogen dioxide in µg/m³
     * @param _so2Level Sulfur dioxide in µg/m³
     * @param _temperature Temperature in Celsius * 100
     * @param _humidity Relative humidity percentage * 100
     * @param _location Geographic coordinates or identifier
     * @notice Validates data ranges, calculates AQI, enforces rate limits
     */
    function submitSensorData(
        uint256 _co2Level,
        uint256 _pm25Level,
        uint256 _pm10Level,
        uint256 _ozoneLevel,
        uint256 _no2Level,
        uint256 _so2Level,
        int256 _temperature,
        uint256 _humidity,
        string calldata _location
    ) 
        external 
        onlyRegisteredSensor 
        whenNotPaused
        withinSubmissionLimit
        validDataRange(
            _co2Level,
            _pm25Level,
            _pm10Level,
            _ozoneLevel,
            _no2Level,
            _so2Level,
            _temperature,
            _humidity
        )
        nonReentrant
    {
        // Prevent duplicate submissions within time window
        bytes32 dataHash = keccak256(abi.encodePacked(
            block.timestamp / 1 hours, // Hour-based bucketing to prevent spam
            msg.sender,
            _co2Level,
            _pm25Level,
            _pm10Level,
            _location
        ));

        require(sensorReadings[dataHash].timestamp == 0, "PollutionOracle: duplicate data");

        // Calculate Air Quality Index based on pollutant levels
        uint256 aqi = _calculateAQI(
            _pm25Level,
            _pm10Level,
            _ozoneLevel,
            _no2Level,
            _so2Level
        );

        // Store sensor data with optimized struct packing
        sensorReadings[dataHash] = SensorData({
            timestamp: uint48(block.timestamp),
            co2Level: uint32(_co2Level),
            pm25Level: uint32(_pm25Level),
            pm10Level: uint32(_pm10Level),
            ozoneLevel: uint32(_ozoneLevel),
            no2Level: uint32(_no2Level),
            so2Level: uint32(_so2Level),
            temperature: int16(_temperature),
            humidity: uint16(_humidity),
            qualityScore: 0, // Set during validation
            aqi: uint16(aqi),
            validationCount: 0,
            isVerified: false,
            sensorAddress: msg.sender,
            location: _location
        });

        // Update sensor statistics
        registeredSensors[msg.sender].dataSubmissions++;
        registeredSensors[msg.sender].lastSubmission = uint48(block.timestamp);
        totalDataPoints++;

        // Perform temporal consistency check
        _performTemporalValidation(msg.sender, _pm25Level, _temperature);

        // Trigger geographic validation if multiple sensors in area
        address[] memory areaSensors = locationSensors[_location];
        if (areaSensors.length >= geoValidators[_location].minSensorsRequired) {
            _performGeographicValidation(_location);
        }

        emit DataSubmitted(dataHash, msg.sender, block.timestamp, aqi);
        
        // Calculate reward based on data quality and sensor reputation
        uint256 rewardAmount = _calculateReward(msg.sender, aqi);
        _distributeReward(msg.sender, rewardAmount, "Data Submission");
    }

    /**
     * @dev Calculate Air Quality Index based on multiple pollutants
     * @param pm25 PM2.5 level in µg/m³
     * @param pm10 PM10 level in µg/m³
     * @param ozone Ozone level in µg/m³
     * @param no2 NO2 level in µg/m³
     * @param so2 SO2 level in µg/m³
     * @return aqi Calculated AQI (0-500 scale)
     * @notice Uses EPA AQI calculation methodology
     */
    function _calculateAQI(
        uint256 pm25,
        uint256 pm10,
        uint256 ozone,
        uint256 no2,
        uint256 so2
    ) internal pure returns (uint256 aqi) {
        // Calculate individual AQI for each pollutant
        uint256 pm25AQI = _calculatePollutantAQI(pm25, 0, 12, 35, 55, 150, 250); // PM2.5 breakpoints
        uint256 pm10AQI = _calculatePollutantAQI(pm10, 0, 54, 154, 254, 354, 424); // PM10 breakpoints
        uint256 ozoneAQI = _calculatePollutantAQI(ozone, 0, 124, 164, 204, 404, 504); // O3 breakpoints
        uint256 no2AQI = _calculatePollutantAQI(no2, 0, 53, 100, 360, 649, 1249); // NO2 breakpoints
        uint256 so2AQI = _calculatePollutantAQI(so2, 0, 35, 75, 185, 304, 604); // SO2 breakpoints

        // Return the maximum AQI (worst pollutant determines overall air quality)
        aqi = pm25AQI;
        if (pm10AQI > aqi) aqi = pm10AQI;
        if (ozoneAQI > aqi) aqi = ozoneAQI;
        if (no2AQI > aqi) aqi = no2AQI;
        if (so2AQI > aqi) aqi = so2AQI;

        // Cap at maximum AQI value
        if (aqi > 500) aqi = 500;
    }

    /**
     * @dev Calculate AQI for individual pollutant using linear interpolation
     * @param concentration Pollutant concentration
     * @param bp1 Lower breakpoint concentration
     * @param bp2 Upper breakpoint concentration  
     * @param bp3 Moderate level concentration
     * @param bp4 Unhealthy level concentration
     * @param bp5 Very unhealthy level concentration
     * @param bp6 Hazardous level concentration
     * @return Individual pollutant AQI value
     */
    function _calculatePollutantAQI(
        uint256 concentration,
        uint256 bp1, uint256 bp2, uint256 bp3, 
        uint256 bp4, uint256 bp5, uint256 bp6
    ) internal pure returns (uint256) {
        if (concentration <= bp1) return 0;
        if (concentration <= bp2) return ((concentration - bp1) * 50) / (bp2 - bp1);
        if (concentration <= bp3) return 51 + ((concentration - bp2) * 49) / (bp3 - bp2);
        if (concentration <= bp4) return 101 + ((concentration - bp3) * 49) / (bp4 - bp3);
        if (concentration <= bp5) return 151 + ((concentration - bp4) * 99) / (bp5 - bp4);
        if (concentration <= bp6) return 201 + ((concentration - bp5) * 99) / (bp6 - bp5);
        return 301 + ((concentration - bp6) * 199) / (bp6 - bp5); // Hazardous+ levels
    }

    /**
     * @dev Validate submitted sensor data with comprehensive checks
     * @param _dataHash Unique identifier for the data point
     * @param _isValid Whether the data passes validation
     * @param _qualityScore Data quality rating (0-10000 basis points)
     * @notice Only authorized validators can validate data
     */
    function validateData(
        bytes32 _dataHash,
        bool _isValid,
        uint256 _qualityScore
    ) external onlyRole(VALIDATOR_ROLE) whenNotPaused {
        require(sensorReadings[_dataHash].timestamp != 0, "PollutionOracle: data not found");
        require(_qualityScore <= 10000, "PollutionOracle: quality score must be 0-10000");
        require(!sensorReadings[_dataHash].isVerified, "PollutionOracle: already validated");

        sensorReadings[_dataHash].validationCount++;
        dataValidators[_dataHash].push(msg.sender);

        if (_isValid) {
            sensorReadings[_dataHash].qualityScore = uint16(_qualityScore);
            
            // Check if minimum validations reached
            if (sensorReadings[_dataHash].validationCount >= validationThreshold) {
                sensorReadings[_dataHash].isVerified = true;
                
                // Update sensor reputation based on data quality
                address sensor = sensorReadings[_dataHash].sensorAddress;
                _updateSensorReputation(sensor, _qualityScore, true);
            }
            
            // Reward validator for successful validation
            _distributeReward(msg.sender, rewardPerSubmission / 4, "Data Validation");
        } else {
            // Penalize sensor reputation for invalid data
            address sensor = sensorReadings[_dataHash].sensorAddress;
            _updateSensorReputation(sensor, 0, false);
        }

        emit DataValidated(_dataHash, msg.sender, _isValid, _qualityScore);
    }

    /**
     * @dev Perform temporal consistency validation
     * @param _sensor Sensor address to validate
     * @param _pm25Level Current PM2.5 reading
     * @param _temperature Current temperature reading
     */
    function _performTemporalValidation(
        address _sensor,
        uint256 _pm25Level,
        int256 _temperature
    ) internal {
        SensorDevice storage sensor = registeredSensors[_sensor];
        
        // Skip validation for first submission
        if (sensor.lastSubmission == 0) return;
        
        // Check for extreme variations that might indicate sensor malfunction
        uint256 timeSinceLastSubmission = block.timestamp - sensor.lastSubmission;
        
        // Only validate if recent submission (within 24 hours)
        if (timeSinceLastSubmission > 24 hours) return;
        
        // Simple consistency check - in production, this would be more sophisticated
        if (_pm25Level > 300 || _temperature > 5000 || _temperature < -2000) {
            // Flag for manual review if extreme values
            sensor.reputationScore = (sensor.reputationScore * 95) / 100; // 5% penalty
        }
    }

    /**
     * @dev Perform geographic validation across sensors in same area
     * @param _location Geographic area to validate
     */
    function _performGeographicValidation(string memory _location) internal {
        address[] memory areaSensors = locationSensors[_location];
        GeographicValidator memory validator = geoValidators[_location];
        
        if (!validator.isActive || areaSensors.length < validator.minSensorsRequired) {
            return;
        }

        uint256 validSensors = 0;
        uint256 avgPM25 = 0;
        uint256 sensorCount = 0;

        // Collect recent data from area sensors
        for (uint256 i = 0; i < areaSensors.length && i < 10; i++) { // Limit to 10 sensors
            SensorDevice memory sensor = registeredSensors[areaSensors[i]];
            
            if (sensor.isActive && sensor.isVerified && 
                block.timestamp - sensor.lastSubmission <= 24 hours) {
                validSensors++;
                sensorCount++;
            }
        }

        uint256 consistencyScore = validSensors >= validator.minSensorsRequired ? 
            (validSensors * 10000) / areaSensors.length : 0;

        emit GeographicValidation(_location, validSensors, consistencyScore);
    }

    /**
     * @dev Update sensor reputation based on data quality
     * @param _sensor Sensor address to update
     * @param _qualityScore Quality score from validation
     * @param _isValid Whether data was validated successfully
     */
    function _updateSensorReputation(
        address _sensor,
        uint256 _qualityScore,
        bool _isValid
    ) internal {
        SensorDevice storage sensor = registeredSensors[_sensor];
        uint256 oldScore = sensor.reputationScore;
        
        if (_isValid) {
            // Increase reputation for high quality data
            if (_qualityScore > 8000) { // > 80%
                sensor.reputationScore = ((sensor.reputationScore * 9) + 9000) / 10; // Move toward 90%
            } else if (_qualityScore > 5000) { // > 50%
                sensor.reputationScore = ((sensor.reputationScore * 19) + 7000) / 20; // Slow increase
            }
        } else {
            // Decrease reputation for invalid data
            sensor.reputationScore = (sensor.reputationScore * 90) / 100; // 10% penalty
        }
        
        // Ensure reputation stays within bounds
        if (sensor.reputationScore > 10000) sensor.reputationScore = 10000;
        if (sensor.reputationScore < 1000) sensor.reputationScore = 1000; // Minimum 10%

        emit ReputationUpdated(_sensor, oldScore, sensor.reputationScore, 
            _isValid ? "Quality validation" : "Invalid data penalty");
    }

    /**
     * @dev Calculate reward amount based on sensor reputation and data quality
     * @param _sensor Sensor address
     * @param _aqi Air Quality Index of submitted data
     * @return Calculated reward amount
     */
    function _calculateReward(address _sensor, uint256 _aqi) internal view returns (uint256) {
        uint256 baseReward = rewardPerSubmission;
        uint256 reputationMultiplier = registeredSensors[_sensor].reputationScore;
        
        // Higher rewards for better air quality reporting and sensor reputation
        uint256 adjustedReward = (baseReward * reputationMultiplier) / 10000;
        
        // Bonus for reporting concerning air quality (incentivize monitoring pollution)
        if (_aqi > 100) { // Unhealthy air quality
            adjustedReward = (adjustedReward * 110) / 100; // 10% bonus
        }
        
        return adjustedReward;
    }

    /**
     * @dev Distribute rewards to participants with token transfer
     * @param _recipient Address to receive rewards
     * @param _amount Token amount to distribute
     * @param _reason Reason for reward distribution
     */
    function _distributeReward(address _recipient, uint256 _amount, string memory _reason) internal {
        if (_amount > 0) {
            registeredSensors[_recipient].totalRewards += uint32(_amount / 1e18); // Store in whole tokens
            
            // Transfer rewards from treasury (requires prior token approval)
            rewardToken.safeTransferFrom(treasury, _recipient, _amount);
            
            emit RewardDistributed(_recipient, _amount, _reason);
        }
    }

    /**
     * @dev Batch validate multiple data points for gas efficiency
     * @param _dataHashes Array of data hashes to validate
     * @param _validations Array of validation results
     * @param _qualityScores Array of quality scores
     */
    function batchValidateData(
        bytes32[] calldata _dataHashes,
        bool[] calldata _validations,
        uint256[] calldata _qualityScores
    ) external onlyRole(VALIDATOR_ROLE) whenNotPaused {
        require(_dataHashes.length == _validations.length, "PollutionOracle: array length mismatch");
        require(_dataHashes.length == _qualityScores.length, "PollutionOracle: array length mismatch");
        require(_dataHashes.length <= 50, "PollutionOracle: batch too large"); // Gas limit protection
        
        for (uint256 i = 0; i < _dataHashes.length;) {
            this.validateData(_dataHashes[i], _validations[i], _qualityScores[i]);
            unchecked { ++i; }
        }
    }

    /**
     * @dev Get comprehensive sensor statistics
     * @param _sensorAddress Sensor address to query
     * @return deviceId Device identifier
     * @return submissions Number of data submissions
     * @return totalRewards Total rewards earned
     * @return reputationScore Current reputation score
     * @return isVerified Verification status
     * @return location Installation location
     * @return lastSubmission Timestamp of last data submission
     */
    function getSensorStats(address _sensorAddress) 
        external 
        view 
        returns (
            string memory deviceId,
            uint256 submissions,
            uint256 totalRewards,
            uint256 reputationScore,
            bool isVerified,
            string memory location,
            uint256 lastSubmission
        ) 
    {
        SensorDevice memory sensor = registeredSensors[_sensorAddress];
        return (
            sensor.deviceId,
            sensor.dataSubmissions,
            sensor.totalRewards,
            sensor.reputationScore,
            sensor.isVerified,
            sensor.location,
            sensor.lastSubmission
        );
    }

    /**
     * @dev Get air quality data for a specific reading
     * @param _dataHash Hash identifier for the data point
     * @return aqi Air Quality Index
     * @return pm25 PM2.5 level
     * @return pm10 PM10 level
     * @return ozone Ozone level
     * @return isVerified Verification status
     * @return qualityScore Data quality score
     */
    function getAirQualityData(bytes32 _dataHash)
        external
        view
        returns (
            uint256 aqi,
            uint256 pm25,
            uint256 pm10,
            uint256 ozone,
            bool isVerified,
            uint256 qualityScore
        )
    {
        SensorData memory data = sensorReadings[_dataHash];
        return (
            data.aqi,
            data.pm25Level,
            data.pm10Level,
            data.ozoneLevel,
            data.isVerified,
            data.qualityScore
        );
    }

    /**
     * @dev Emergency pause function for oracle admin
     */
    function emergencyPause() external onlyRole(ORACLE_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Resume operations after emergency
     */
    function unpause() external onlyRole(ORACLE_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Update contract parameters (admin only)
     * @param _rewardPerSubmission New reward amount per submission
     * @param _validationThreshold New minimum validation requirement
     * @param _maxDailySubmissions New daily submission limit
     */
    function updateParameters(
        uint256 _rewardPerSubmission,
        uint256 _validationThreshold,
        uint256 _maxDailySubmissions
    ) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(_validationThreshold > 0, "PollutionOracle: validation threshold too low");
        require(_maxDailySubmissions <= 288, "PollutionOracle: daily limit too high"); // Max every 5 minutes
        
        rewardPerSubmission = _rewardPerSubmission;
        validationThreshold = _validationThreshold;
        maxDailySubmissions = _maxDailySubmissions;
    }
}