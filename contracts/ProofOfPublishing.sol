// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Proof of Publishing Rewards Contract
 * @dev Automates WRF distribution based on forecast publishing activity, accuracy, and geographic coverage
 * Incentivizes computational NFT participants with weighted scoring system
 */
contract ProofOfPublishing is Pausable {

    struct PublisherProfile {
        address publisher;
        uint256 totalForecasts;
        uint256 accurateForecasts;
        uint256 totalRewards;
        uint256 lastPublishTime;
        string[] coverageAreas;
        mapping(string => uint256) areaContributions; // area -> forecast count
        bool isActive;
        uint256 reputationScore; // 0-10000 basis points
    }
    
    struct ForecastPublication {
        address publisher;
        string location;
        string forecastType;
        string dataHash; // IPFS hash
        uint256 publishTime;
        uint256 expirationTime;
        bool isVerified;
        uint256 accuracyScore; // Set after expiration
        uint256 rewardEarned;
        string[] verifierAddresses;
    }
    
    struct DataScarceArea {
        string areaId;
        string location;
        uint256 scarcityMultiplier; // 100-1000 (1x to 10x multiplier)
        uint256 lastUpdateTime;
        uint256 totalPublishers;
        bool isActive;
    }
    
    mapping(address => PublisherProfile) public publishers;
    mapping(bytes32 => ForecastPublication) public publications;
    mapping(string => DataScarceArea) public scarceAreas;
    mapping(string => address[]) public areaPublishers;
    
    address[] public allPublishers;
    string[] public allAreas;
    
    uint256 public baseReward = 5000000000000000000; // 5 WRF base reward
    uint256 public accuracyThreshold = 7000; // 70% accuracy required for full reward
    uint256 public rewardPool;
    uint256 public totalDistributed;
    
    address public oracleNetwork;
    address public governance;
    
    event ForecastPublished(
        bytes32 indexed publicationId,
        address indexed publisher,
        string location,
        string forecastType,
        uint256 publishTime,
        uint256 expirationTime
    );
    
    event RewardDistributed(
        address indexed publisher,
        uint256 amount,
        uint256 accuracyScore,
        string location
    );
    
    event DataScarceAreaAdded(
        string indexed areaId,
        string location,
        uint256 scarcityMultiplier
    );
    
    event PublisherVerified(address indexed publisher, uint256 reputationScore);
    
    modifier onlyOracle() {
        require(msg.sender == oracleNetwork, "Only oracle network can verify");
        _;
    }
    
    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance can execute");
        _;
    }
    
    constructor(address _oracleNetwork, address _governance) {
        oracleNetwork = _oracleNetwork;
        governance = _governance;
    }

    /**
     * @dev Emergency circuit breaker (#165). Halts publishing/reward flow if a
     *      bug or abuse is found post-deploy, without draining the pool. Gated
     *      by the existing governance admin lever (the same authority as
     *      emergencyWithdraw/updateParameters); no new role is introduced.
     */
    function pause() external onlyGovernance {
        _pause();
    }

    /**
     * @dev Lift the emergency stop. Governance-only.
     */
    function unpause() external onlyGovernance {
        _unpause();
    }

    /**
     * @dev Fund the reward pool
     */
    function fundRewardPool() external payable whenNotPaused {
        rewardPool += msg.value;
    }
    
    /**
     * @dev Publish forecast and register for rewards
     */
    function publishForecast(
        string memory location,
        string memory forecastType,
        string memory dataHash,
        uint256 expirationTime
    ) external whenNotPaused {
        require(expirationTime > block.timestamp, "Expiration must be in future");
        
        bytes32 publicationId = keccak256(abi.encodePacked(
            msg.sender,
            location,
            forecastType,
            block.timestamp
        ));
        
        // Create publication record
        publications[publicationId] = ForecastPublication({
            publisher: msg.sender,
            location: location,
            forecastType: forecastType,
            dataHash: dataHash,
            publishTime: block.timestamp,
            expirationTime: expirationTime,
            isVerified: false,
            accuracyScore: 0,
            rewardEarned: 0,
            verifierAddresses: new string[](0)
        });
        
        // Update publisher profile
        PublisherProfile storage profile = publishers[msg.sender];
        if (!profile.isActive) {
            profile.publisher = msg.sender;
            profile.isActive = true;
            allPublishers.push(msg.sender);
        }
        
        profile.totalForecasts++;
        profile.lastPublishTime = block.timestamp;
        
        // Track area contribution
        if (profile.areaContributions[location] == 0) {
            profile.coverageAreas.push(location);
        }
        profile.areaContributions[location]++;
        
        // Add to area publishers if new
        bool isExistingPublisher = false;
        address[] storage publishers_in_area = areaPublishers[location];
        for (uint256 i = 0; i < publishers_in_area.length; i++) {
            if (publishers_in_area[i] == msg.sender) {
                isExistingPublisher = true;
                break;
            }
        }
        if (!isExistingPublisher) {
            areaPublishers[location].push(msg.sender);
        }
        
        emit ForecastPublished(
            publicationId,
            msg.sender,
            location,
            forecastType,
            block.timestamp,
            expirationTime
        );
    }
    
    /**
     * @dev Verify forecast accuracy and distribute rewards
     */
    function verifyAndReward(
        bytes32 publicationId,
        uint256 accuracyScore,
        string[] memory verifierAddresses
    ) public onlyOracle whenNotPaused {
        ForecastPublication storage publication = publications[publicationId];
        require(!publication.isVerified, "Already verified");
        require(block.timestamp >= publication.expirationTime, "Forecast not expired");
        
        publication.isVerified = true;
        publication.accuracyScore = accuracyScore;
        publication.verifierAddresses = verifierAddresses;
        
        // Calculate reward
        uint256 reward = calculateReward(publication.publisher, publication.location, accuracyScore);
        
        if (reward > 0 && rewardPool >= reward) {
            // Update publisher profile
            PublisherProfile storage profile = publishers[publication.publisher];
            profile.totalRewards += reward;
            
            if (accuracyScore >= accuracyThreshold) {
                profile.accurateForecasts++;
            }
            
            // Update reputation score
            profile.reputationScore = calculateReputationScore(publication.publisher);
            
            // Transfer reward
            publication.rewardEarned = reward;
            rewardPool -= reward;
            totalDistributed += reward;
            
            (bool okReward,) = payable(publication.publisher).call{value: reward}("");
            require(okReward, "ProofOfPublishing: ETH reward to publisher failed");
            
            emit RewardDistributed(
                publication.publisher,
                reward,
                accuracyScore,
                publication.location
            );
        }
    }
    
    /**
     * @dev Calculate reward based on multiple factors
     */
    function calculateReward(
        address publisher,
        string memory location,
        uint256 accuracyScore
    ) public view returns (uint256) {
        PublisherProfile storage profile = publishers[publisher];
        
        // Base reward
        uint256 reward = baseReward;
        
        // Accuracy multiplier (0.5x to 1.5x based on accuracy)
        uint256 accuracyMultiplier = (accuracyScore * 100) / 10000 + 50; // 50-150
        reward = (reward * accuracyMultiplier) / 100;
        
        // Data scarcity multiplier
        DataScarceArea memory area = scarceAreas[location];
        if (area.isActive) {
            reward = (reward * area.scarcityMultiplier) / 100;
        }
        
        // Reputation bonus (up to 20% bonus for high reputation)
        uint256 reputationBonus = (profile.reputationScore * 20) / 10000;
        reward = reward + (reward * reputationBonus) / 100;
        
        // Coverage diversity bonus (up to 30% bonus for covering multiple areas)
        uint256 diversityBonus = profile.coverageAreas.length > 5 ? 30 : (profile.coverageAreas.length * 5);
        reward = reward + (reward * diversityBonus) / 100;
        
        return reward;
    }
    
    /**
     * @dev Calculate reputation score based on publishing history
     */
    function calculateReputationScore(address publisher) public view returns (uint256) {
        PublisherProfile storage profile = publishers[publisher];
        
        if (profile.totalForecasts == 0) return 0;
        
        // Base score from accuracy rate (0-7000)
        uint256 accuracyRate = (profile.accurateForecasts * 10000) / profile.totalForecasts;
        uint256 baseScore = (accuracyRate * 7000) / 10000;
        
        // Volume bonus (0-2000)
        uint256 volumeBonus = profile.totalForecasts > 100 ? 2000 : (profile.totalForecasts * 20);
        
        // Consistency bonus (0-1000) - based on regular publishing
        uint256 consistencyBonus = 0;
        if (profile.lastPublishTime > 0 && block.timestamp - profile.lastPublishTime < 7 days) {
            consistencyBonus = 1000;
        } else if (block.timestamp - profile.lastPublishTime < 30 days) {
            consistencyBonus = 500;
        }
        
        return baseScore + volumeBonus + consistencyBonus;
    }
    
    /**
     * @dev Add or update data-scarce area
     */
    function updateDataScarceArea(
        string memory areaId,
        string memory location,
        uint256 scarcityMultiplier,
        bool isActive
    ) external onlyGovernance {
        require(scarcityMultiplier >= 100 && scarcityMultiplier <= 1000, "Invalid multiplier");
        
        DataScarceArea storage area = scarceAreas[areaId];
        if (bytes(area.areaId).length == 0) {
            allAreas.push(areaId);
            area.areaId = areaId;
        }
        
        area.location = location;
        area.scarcityMultiplier = scarcityMultiplier;
        area.lastUpdateTime = block.timestamp;
        area.isActive = isActive;
        area.totalPublishers = areaPublishers[location].length;
        
        emit DataScarceAreaAdded(areaId, location, scarcityMultiplier);
    }
    
    /**
     * @dev Verify publisher credentials
     */
    function verifyPublisher(address publisher) external onlyOracle whenNotPaused {
        PublisherProfile storage profile = publishers[publisher];
        profile.reputationScore = calculateReputationScore(publisher);
        
        emit PublisherVerified(publisher, profile.reputationScore);
    }
    
    /**
     * @dev Get publisher coverage areas
     */
    function getPublisherAreas(address publisher) external view returns (string[] memory) {
        return publishers[publisher].coverageAreas;
    }
    
    /**
     * @dev Get publishers in area
     */
    function getAreaPublishers(string memory location) external view returns (address[] memory) {
        return areaPublishers[location];
    }
    
    /**
     * @dev Get all data-scarce areas
     */
    function getAllAreas() external view returns (string[] memory) {
        return allAreas;
    }
    
    /**
     * @dev Get publication verifiers
     */
    function getPublicationVerifiers(bytes32 publicationId) external view returns (string[] memory) {
        return publications[publicationId].verifierAddresses;
    }
    
    /**
     * @dev Batch verify multiple publications
     */
    function batchVerifyAndReward(
        bytes32[] memory publicationIds,
        uint256[] memory accuracyScores,
        string[][] memory verifierAddresses
    ) external onlyOracle whenNotPaused {
        require(
            publicationIds.length == accuracyScores.length && 
            publicationIds.length == verifierAddresses.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < publicationIds.length; i++) {
            verifyAndReward(publicationIds[i], accuracyScores[i], verifierAddresses[i]);
        }
    }
    
    /**
     * @dev Emergency withdrawal (governance only)
     */
    function emergencyWithdraw(uint256 amount) external onlyGovernance {
        require(amount <= rewardPool, "Insufficient pool balance");
        rewardPool -= amount;
        (bool okEmergency,) = payable(governance).call{value: amount}("");
        require(okEmergency, "ProofOfPublishing: ETH emergency withdrawal failed");
    }
    
    /**
     * @dev Update contract parameters
     */
    function updateParameters(
        uint256 _baseReward,
        uint256 _accuracyThreshold,
        address _oracleNetwork
    ) external onlyGovernance {
        baseReward = _baseReward;
        accuracyThreshold = _accuracyThreshold;
        oracleNetwork = _oracleNetwork;
    }
}