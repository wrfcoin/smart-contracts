// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Geo-Staking Contracts
 * @dev Stake WRF to earn yield for contributing sensors to data-scarce areas
 * Yield rates are inversely proportional to sensor density in regions
 */
contract GeoStakingContracts is ReentrancyGuard {
    
    struct GeographicZone {
        string zoneId;
        string location;
        int256 latitude;
        int256 longitude;
        uint256 radius; // in meters
        uint256 sensorCount;
        uint256 totalStaked;
        uint256 yieldMultiplier; // 100-2000 (1x to 20x based on scarcity)
        uint256 lastUpdateTime;
        bool isActive;
        address[] stakers;
        mapping(address => StakePosition) stakes;
    }
    
    struct StakePosition {
        address staker;
        string zoneId;
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 accumulatedRewards;
        uint256 sensorContributions; // Number of sensors contributed
        bool isActive;
    }
    
    struct SensorContribution {
        uint256 sensorId;
        address contributor;
        string zoneId;
        string sensorType;
        uint256 registrationTime;
        uint256 lastDataSubmission;
        bool isActive;
        uint256 qualityScore; // 0-10000 basis points
    }
    
    mapping(string => GeographicZone) public zones;
    mapping(address => mapping(string => StakePosition)) public stakes;
    mapping(uint256 => SensorContribution) public sensorContributions;
    mapping(address => string[]) public stakerZones;
    
    string[] public allZones;
    uint256 public nextSensorId = 1;
    uint256 public totalStaked;
    uint256 public rewardPool;
    uint256 public baseYieldRate = 1000; // 10% annual base rate
    uint256 public minimumStake = 100000000000000000000; // 100 WRF minimum
    address public governance;
    address public oracleNetwork;
    
    event ZoneCreated(
        string indexed zoneId,
        string location,
        int256 latitude,
        int256 longitude,
        uint256 yieldMultiplier
    );
    
    event StakeDeposited(
        address indexed staker,
        string indexed zoneId,
        uint256 amount,
        uint256 expectedYield
    );
    
    event SensorRegistered(
        uint256 indexed sensorId,
        address indexed contributor,
        string indexed zoneId,
        string sensorType
    );
    
    event RewardsClaimed(
        address indexed staker,
        string indexed zoneId,
        uint256 amount
    );
    
    event YieldMultiplierUpdated(
        string indexed zoneId,
        uint256 oldMultiplier,
        uint256 newMultiplier
    );
    
    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance can execute");
        _;
    }
    
    modifier onlyOracle() {
        require(msg.sender == oracleNetwork, "Only oracle can verify");
        _;
    }
    
    modifier validZone(string memory zoneId) {
        require(zones[zoneId].isActive, "Zone not active");
        _;
    }
    
    constructor(address _governance, address _oracleNetwork) {
        governance = _governance;
        oracleNetwork = _oracleNetwork;
    }
    
    /**
     * @dev Fund the reward pool for staking yields
     */
    function fundRewardPool() external payable {
        rewardPool += msg.value;
    }
    
    /**
     * @dev Create new geographic zone for staking
     */
    function createZone(
        string memory zoneId,
        string memory location,
        int256 latitude,
        int256 longitude,
        uint256 radius,
        uint256 initialYieldMultiplier
    ) external onlyGovernance {
        require(bytes(zones[zoneId].zoneId).length == 0, "Zone already exists");
        require(initialYieldMultiplier >= 100 && initialYieldMultiplier <= 2000, "Invalid multiplier");
        
        GeographicZone storage zone = zones[zoneId];
        zone.zoneId = zoneId;
        zone.location = location;
        zone.latitude = latitude;
        zone.longitude = longitude;
        zone.radius = radius;
        zone.yieldMultiplier = initialYieldMultiplier;
        zone.lastUpdateTime = block.timestamp;
        zone.isActive = true;
        
        allZones.push(zoneId);
        
        emit ZoneCreated(zoneId, location, latitude, longitude, initialYieldMultiplier);
    }
    
    /**
     * @dev Stake WRF tokens in a geographic zone
     */
    function stakeInZone(string memory zoneId) external payable validZone(zoneId) {
        require(msg.value >= minimumStake, "Below minimum stake");
        
        GeographicZone storage zone = zones[zoneId];
        StakePosition storage position = stakes[msg.sender][zoneId];
        
        // If first time staking in this zone
        if (!position.isActive) {
            position.staker = msg.sender;
            position.zoneId = zoneId;
            position.startTime = block.timestamp;
            position.lastClaimTime = block.timestamp;
            position.isActive = true;
            
            zone.stakers.push(msg.sender);
            stakerZones[msg.sender].push(zoneId);
        } else {
            // Claim existing rewards before adding more stake
            _claimRewards(msg.sender, zoneId);
        }
        
        // Add to stake position
        position.amount += msg.value;
        zone.totalStaked += msg.value;
        totalStaked += msg.value;
        
        // Calculate expected annual yield
        uint256 expectedYield = calculateYield(msg.value, zone.yieldMultiplier);
        
        emit StakeDeposited(msg.sender, zoneId, msg.value, expectedYield);
    }
    
    /**
     * @dev Register sensor contribution to boost staking rewards
     */
    function registerSensorContribution(
        string memory zoneId,
        string memory sensorType,
        string memory /* dataEndpoint */
    ) external validZone(zoneId) {
        StakePosition storage position = stakes[msg.sender][zoneId];
        require(position.isActive, "No active stake in zone");
        
        uint256 sensorId = nextSensorId++;
        SensorContribution storage contribution = sensorContributions[sensorId];
        
        contribution.sensorId = sensorId;
        contribution.contributor = msg.sender;
        contribution.zoneId = zoneId;
        contribution.sensorType = sensorType;
        contribution.registrationTime = block.timestamp;
        contribution.lastDataSubmission = block.timestamp;
        contribution.isActive = true;
        contribution.qualityScore = 8000; // Start with 80% quality score
        
        // Update zone and stake position
        GeographicZone storage zone = zones[zoneId];
        zone.sensorCount++;
        position.sensorContributions++;
        
        // Recalculate yield multiplier based on new sensor density
        _updateYieldMultiplier(zoneId);
        
        emit SensorRegistered(sensorId, msg.sender, zoneId, sensorType);
    }
    
    /**
     * @dev Submit sensor data to maintain contribution status
     */
    function submitSensorData(uint256 sensorId, string memory /* dataHash */) external {
        SensorContribution storage contribution = sensorContributions[sensorId];
        
        require(contribution.contributor == msg.sender, "Only contributor can submit");
        require(contribution.isActive, "Sensor contribution not active");
        
        contribution.lastDataSubmission = block.timestamp;
        
        // Bonus rewards for regular data submission
        StakePosition storage position = stakes[msg.sender][contribution.zoneId];
        if (position.isActive) {
            uint256 dataBonus = (position.amount * 50) / 10000; // 0.5% bonus
            position.accumulatedRewards += dataBonus;
        }
    }
    
    /**
     * @dev Claim accumulated staking rewards
     */
    function claimRewards(string memory zoneId) external validZone(zoneId) {
        _claimRewards(msg.sender, zoneId);
    }
    
    /**
     * @dev Internal function to calculate and distribute rewards
     */
    function _claimRewards(address staker, string memory zoneId) internal {
        StakePosition storage position = stakes[staker][zoneId];
        require(position.isActive, "No active stake");
        
        uint256 timeStaked = block.timestamp - position.lastClaimTime;
        uint256 rewards = calculateRewards(staker, zoneId, timeStaked);
        
        if (rewards > 0 && rewardPool >= rewards) {
            position.accumulatedRewards += rewards;
            position.lastClaimTime = block.timestamp;
            
            rewardPool -= rewards;
            payable(staker).transfer(rewards);
            
            emit RewardsClaimed(staker, zoneId, rewards);
        }
    }
    
    /**
     * @dev Calculate rewards for a staker in a zone
     */
    function calculateRewards(
        address staker,
        string memory zoneId,
        uint256 timeStaked
    ) public view returns (uint256) {
        StakePosition storage position = stakes[staker][zoneId];
        GeographicZone storage zone = zones[zoneId];
        
        if (!position.isActive || timeStaked == 0) return 0;
        
        // Base annual yield calculation
        uint256 annualYield = calculateYield(position.amount, zone.yieldMultiplier);
        uint256 baseRewards = (annualYield * timeStaked) / (365 days);
        
        // Sensor contribution bonus (up to 50% extra)
        uint256 sensorBonus = position.sensorContributions > 0 ? 
            (baseRewards * (position.sensorContributions * 10)) / 100 : 0;
        if (sensorBonus > baseRewards / 2) sensorBonus = baseRewards / 2;
        
        // Early adopter bonus (extra 25% for first month)
        uint256 earlyBonus = 0;
        if (block.timestamp - position.startTime < 30 days) {
            earlyBonus = baseRewards / 4;
        }
        
        return baseRewards + sensorBonus + earlyBonus + position.accumulatedRewards;
    }
    
    /**
     * @dev Calculate expected yield based on stake amount and multiplier
     */
    function calculateYield(uint256 stakeAmount, uint256 yieldMultiplier) public view returns (uint256) {
        return (stakeAmount * baseYieldRate * yieldMultiplier) / (10000 * 100);
    }
    
    /**
     * @dev Update yield multiplier based on sensor density
     */
    function _updateYieldMultiplier(string memory zoneId) internal {
        GeographicZone storage zone = zones[zoneId];
        uint256 oldMultiplier = zone.yieldMultiplier;
        
        // Calculate new multiplier based on inverse relationship with sensor count
        // More sensors = lower scarcity = lower yield multiplier
        uint256 newMultiplier;
        if (zone.sensorCount == 0) {
            newMultiplier = 2000; // Maximum 20x for completely uncovered areas
        } else if (zone.sensorCount <= 5) {
            newMultiplier = 1500; // 15x for very sparse coverage
        } else if (zone.sensorCount <= 15) {
            newMultiplier = 1000; // 10x for sparse coverage
        } else if (zone.sensorCount <= 50) {
            newMultiplier = 500;  // 5x for moderate coverage
        } else {
            newMultiplier = 200;  // 2x for dense coverage
        }
        
        zone.yieldMultiplier = newMultiplier;
        zone.lastUpdateTime = block.timestamp;
        
        emit YieldMultiplierUpdated(zoneId, oldMultiplier, newMultiplier);
    }
    
    /**
     * @dev Unstake tokens from a zone
     */
    function unstake(string memory zoneId, uint256 amount) external validZone(zoneId) {
        StakePosition storage position = stakes[msg.sender][zoneId];
        require(position.isActive, "No active stake");
        require(position.amount >= amount, "Insufficient stake");
        
        // Claim rewards before unstaking
        _claimRewards(msg.sender, zoneId);
        
        // Update positions
        position.amount -= amount;
        zones[zoneId].totalStaked -= amount;
        totalStaked -= amount;
        
        // Deactivate if fully unstaked
        if (position.amount == 0) {
            position.isActive = false;
        }
        
        payable(msg.sender).transfer(amount);
    }
    
    /**
     * @dev Verify sensor data quality and update scores
     */
    function updateSensorQuality(
        uint256 sensorId,
        uint256 qualityScore
    ) external onlyOracle {
        require(qualityScore <= 10000, "Invalid quality score");
        
        SensorContribution storage contribution = sensorContributions[sensorId];
        contribution.qualityScore = qualityScore;
        
        // Deactivate if quality too low
        if (qualityScore < 5000) { // Below 50% quality
            contribution.isActive = false;
            
            // Update zone sensor count
            GeographicZone storage zone = zones[contribution.zoneId];
            if (zone.sensorCount > 0) {
                zone.sensorCount--;
                _updateYieldMultiplier(contribution.zoneId);
            }
        }
    }
    
    /**
     * @dev Get all zones
     */
    function getAllZones() external view returns (string[] memory) {
        return allZones;
    }
    
    /**
     * @dev Get staker's zones
     */
    function getStakerZones(address staker) external view returns (string[] memory) {
        return stakerZones[staker];
    }
    
    /**
     * @dev Get zone stakers
     */
    function getZoneStakers(string memory zoneId) external view returns (address[] memory) {
        return zones[zoneId].stakers;
    }
    
    /**
     * @dev Batch claim rewards from multiple zones
     */
    function batchClaimRewards(string[] memory zoneIds) external {
        for (uint256 i = 0; i < zoneIds.length; i++) {
            if (zones[zoneIds[i]].isActive && stakes[msg.sender][zoneIds[i]].isActive) {
                _claimRewards(msg.sender, zoneIds[i]);
            }
        }
    }
    
    /**
     * @dev Emergency withdrawal (governance only)
     */
    function emergencyWithdraw(uint256 amount) external onlyGovernance nonReentrant {
        require(amount <= rewardPool, "Insufficient pool balance");
        rewardPool -= amount;
        payable(governance).transfer(amount);
    }
    
    /**
     * @dev Update contract parameters
     */
    function updateParameters(
        uint256 _baseYieldRate,
        uint256 _minimumStake,
        address _oracleNetwork
    ) external onlyGovernance {
        baseYieldRate = _baseYieldRate;
        minimumStake = _minimumStake;
        oracleNetwork = _oracleNetwork;
    }
}