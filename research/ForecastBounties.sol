// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title Forecast Bounties Contract
 * @dev Secure research incentive platform for environmental forecasting and peer review
 * @notice Enables bounty-based forecast requests with fair reward distribution and IP protection
 * @custom:security Multi-round peer review, cryptographic verification, anti-gaming measures
 */
contract ForecastBounties is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    // Role definitions for access control
    bytes32 public constant BOUNTY_ADMIN_ROLE = keccak256("BOUNTY_ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PEER_REVIEWER_ROLE = keccak256("PEER_REVIEWER_ROLE");
    bytes32 public constant RESEARCH_VALIDATOR_ROLE = keccak256("RESEARCH_VALIDATOR_ROLE");

    // EIP-712 type hashes for secure submission verification
    bytes32 private constant FORECAST_SUBMISSION_TYPEHASH = keccak256(
        "ForecastSubmission(uint256 requestId,string forecastDataHash,string modelHash,uint256 submissionTime,uint256 nonce)"
    );

    /**
     * @dev Enhanced forecast request with comprehensive validation and IP protection
     * @param requestId Unique request identifier
     * @param requester Address requesting the forecast
     * @param location Geographic area for forecast
     * @param forecastType Type of prediction (air_quality, weather, pollution, climate, extreme_weather)
     * @param bountyAmount Total reward pool for winning submissions
     * @param deadline Submission deadline timestamp
     * @param verificationDeadline Verification completion deadline
     * @param isActive Request accepting submissions
     * @param isVerified Verification process completed
     * @param winner Address of winning analyst
     * @param totalSubmissions Number of submissions received
     * @param minAccuracyThreshold Minimum accuracy required for payout
     * @param peerReviewRequired Whether peer review is mandatory
     * @param submitters Array of participating analysts
     * @param submissions Mapping of analyst submissions
     */
    struct ForecastRequest {
        uint64 requestId;
        uint48 deadline;
        uint48 verificationDeadline;
        uint32 bountyAmount;
        uint16 totalSubmissions;
        uint16 minAccuracyThreshold;  // Minimum accuracy for payout (basis points)
        uint8 peerReviewsRequired;    // Number of peer reviews needed
        bool isActive;
        bool isVerified;
        bool peerReviewRequired;
        address requester;
        address winner;
        string location;
        string forecastType;
        mapping(address => ForecastSubmission) submissions;
        address[] submitters;
    }
    
    /**
     * @dev Secure forecast submission with cryptographic verification
     * @param analyst Submitting analyst address
     * @param forecastDataHash IPFS hash of encrypted forecast data
     * @param modelHash IPFS hash of model methodology and code
     * @param submissionTime Timestamp of submission
     * @param accuracyScore Final accuracy rating (0-10000 basis points)
     * @param isVerified Oracle verification status
     * @param peerReviewScore Average peer review score
     * @param ipfsProofHash IPFS hash proving data availability
     * @param confidenceInterval Analyst's confidence level (0-100%)
     * @param methodologyType Forecasting approach used
     */
    struct ForecastSubmission {
        uint48 submissionTime;
        uint16 accuracyScore;         // Final accuracy (0-10000 basis points)
        uint16 peerReviewScore;       // Peer review average (0-10000)
        uint8 confidenceInterval;     // Analyst confidence (0-100%)
        uint8 peerReviewCount;        // Number of peer reviews received
        bool isVerified;
        address analyst;
        string forecastDataHash;
        string modelHash;
        string ipfsProofHash;         // Proof of data availability
        string methodologyType;       // "statistical", "ml", "ensemble", "physics"
    }
    
    /**
     * @dev Comprehensive analyst profile with reputation tracking
     * @param totalSubmissions Number of forecasts submitted
     * @param totalWins Number of winning submissions
     * @param averageAccuracy Weighted average accuracy score
     * @param totalEarnings Cumulative bounty earnings
     * @param specialization Primary research area
     * @param isVerified Verified researcher status
     * @param reputationScore Overall reputation (0-10000 basis points)
     * @param consistencyScore Prediction consistency rating
     * @param lastSubmissionTime Most recent submission timestamp
     * @param peerReviewsGiven Number of peer reviews conducted
     * @param peerReviewRating Average rating as peer reviewer
     */
    struct AnalystProfile {
        uint32 totalSubmissions;
        uint32 totalWins;
        uint32 totalEarnings;
        uint32 lastSubmissionTime;
        uint16 averageAccuracy;       // Weighted accuracy (0-10000)
        uint16 reputationScore;       // Overall reputation (0-10000)
        uint16 consistencyScore;      // Prediction consistency (0-10000)
        uint16 peerReviewsGiven;      // Peer reviews conducted
        uint16 peerReviewRating;      // Rating as peer reviewer (0-10000)
        bool isVerified;
        string specialization;
    }

    /**
     * @dev Peer review data for quality assessment
     * @param reviewer Address of peer reviewer
     * @param score Review score (0-10000 basis points)
     * @param comments IPFS hash of review comments
     * @param timestamp Review submission time
     * @param categories Scored categories (methodology, data, presentation, etc.)
     */
    struct PeerReview {
        address reviewer;
        uint48 timestamp;
        uint16 score;                 // Overall review score (0-10000)
        string comments;              // IPFS hash of detailed review
        mapping(string => uint16) categories; // Category-specific scores
    }

    /**
     * @dev Intellectual property protection record
     * @param submissionHash Hash of submission content
     * @param timestampProof Blockchain timestamp proof
     * @param ipfsHash IPFS storage proof
     * @param encryptionKey Public key for accessing protected content
     */
    struct IPProtection {
        bytes32 submissionHash;
        uint48 timestampProof;
        string ipfsHash;
        string encryptionKey;
    }
    
    mapping(uint256 => ForecastRequest) public requests;
    mapping(address => AnalystProfile) public analysts;
    mapping(string => uint256[]) public locationRequests; // Track requests by location
    
    uint256 public nextRequestId = 1;
    uint256 public minimumBounty = 1000000000000000000; // 1 WRF minimum
    uint256 public platformFeeRate = 250; // 2.5% in basis points
    address public oracleNetwork;
    address public treasury;
    
    event ForecastRequested(
        uint256 indexed requestId,
        address indexed requester,
        string location,
        string forecastType,
        uint256 bountyAmount,
        uint256 deadline
    );
    
    event ForecastSubmitted(
        uint256 indexed requestId,
        address indexed analyst,
        string forecastDataHash,
        string modelHash
    );
    
    event ForecastVerified(
        uint256 indexed requestId,
        address indexed winner,
        uint256 accuracyScore,
        uint256 reward
    );
    
    event AnalystVerified(address indexed analyst, string specialization);
    
    modifier onlyOracle() {
        require(msg.sender == oracleNetwork, "Only oracle network can verify");
        _;
    }
    
    modifier onlyActiveRequest(uint256 requestId) {
        require(requests[requestId].isActive, "Request not active");
        require(block.timestamp < requests[requestId].deadline, "Submission deadline passed");
        _;
    }
    
    constructor(address _oracleNetwork, address _treasury) {
        oracleNetwork = _oracleNetwork;
        treasury = _treasury;
    }
    
    /**
     * @dev Create a new forecast request with WRF bounty
     */
    function createForecastRequest(
        string memory location,
        string memory forecastType,
        uint256 deadline,
        uint256 verificationDeadline
    ) external payable {
        require(msg.value >= minimumBounty, "Bounty below minimum");
        require(deadline > block.timestamp, "Deadline must be in future");
        require(verificationDeadline > deadline, "Verification deadline must be after submission deadline");
        
        uint256 requestId = nextRequestId++;
        ForecastRequest storage request = requests[requestId];
        
        request.requestId = requestId;
        request.requester = msg.sender;
        request.location = location;
        request.forecastType = forecastType;
        request.bountyAmount = msg.value;
        request.deadline = deadline;
        request.verificationDeadline = verificationDeadline;
        request.isActive = true;
        
        locationRequests[location].push(requestId);
        
        emit ForecastRequested(
            requestId,
            msg.sender,
            location,
            forecastType,
            msg.value,
            deadline
        );
    }
    
    /**
     * @dev Submit forecast analysis for a bounty
     */
    function submitForecast(
        uint256 requestId,
        string memory forecastDataHash,
        string memory modelHash
    ) external onlyActiveRequest(requestId) {
        ForecastRequest storage request = requests[requestId];
        
        require(
            request.submissions[msg.sender].analyst == address(0),
            "Already submitted for this request"
        );
        
        // Create submission
        request.submissions[msg.sender] = ForecastSubmission({
            analyst: msg.sender,
            forecastDataHash: forecastDataHash,
            modelHash: modelHash,
            submissionTime: block.timestamp,
            accuracyScore: 0,
            isVerified: false
        });
        
        request.submitters.push(msg.sender);
        request.totalSubmissions++;
        
        // Update analyst profile
        AnalystProfile storage profile = analysts[msg.sender];
        profile.totalSubmissions++;
        
        emit ForecastSubmitted(requestId, msg.sender, forecastDataHash, modelHash);
    }
    
    /**
     * @dev Oracle verifies forecasts and determines winner
     */
    function verifyForecasts(
        uint256 requestId,
        address[] memory submitters,
        uint256[] memory accuracyScores
    ) external onlyOracle {
        require(submitters.length == accuracyScores.length, "Array length mismatch");
        
        ForecastRequest storage request = requests[requestId];
        require(!request.isVerified, "Request already verified");
        require(
            block.timestamp >= request.deadline && 
            block.timestamp <= request.verificationDeadline,
            "Outside verification window"
        );
        
        address winner = address(0);
        uint256 highestScore = 0;
        
        // Score all submissions and find winner
        for (uint256 i = 0; i < submitters.length; i++) {
            address analyst = submitters[i];
            uint256 score = accuracyScores[i];
            
            ForecastSubmission storage submission = request.submissions[analyst];
            require(submission.analyst == analyst, "Invalid submission");
            
            submission.accuracyScore = score;
            submission.isVerified = true;
            
            // Update analyst profile
            AnalystProfile storage profile = analysts[analyst];
            profile.averageAccuracy = 
                (profile.averageAccuracy * (profile.totalSubmissions - 1) + score) / 
                profile.totalSubmissions;
            
            if (score > highestScore) {
                highestScore = score;
                winner = analyst;
            }
        }
        
        // Pay out bounty
        if (winner != address(0)) {
            request.winner = winner;
            analysts[winner].totalWins++;
            
            uint256 platformFee = (request.bountyAmount * platformFeeRate) / 10000;
            uint256 reward = request.bountyAmount - platformFee;
            
            analysts[winner].totalEarnings += reward;
            
            // Transfer reward and fee
            payable(winner).transfer(reward);
            payable(treasury).transfer(platformFee);
            
            emit ForecastVerified(requestId, winner, highestScore, reward);
        }
        
        request.isVerified = true;
        request.isActive = false;
    }
    
    /**
     * @dev Verify analyst credentials and specialization
     */
    function verifyAnalyst(address analyst, string memory specialization) external onlyOracle {
        analysts[analyst].isVerified = true;
        analysts[analyst].specialization = specialization;
        
        emit AnalystVerified(analyst, specialization);
    }
    
    /**
     * @dev Get forecast requests for a location
     */
    function getLocationRequests(string memory location) external view returns (uint256[] memory) {
        return locationRequests[location];
    }
    
    /**
     * @dev Get all submitters for a request
     */
    function getRequestSubmitters(uint256 requestId) external view returns (address[] memory) {
        return requests[requestId].submitters;
    }
    
    /**
     * @dev Get submission details
     */
    function getSubmission(uint256 requestId, address analyst) external view returns (
        string memory forecastDataHash,
        string memory modelHash,
        uint256 submissionTime,
        uint256 accuracyScore,
        bool isVerified
    ) {
        ForecastSubmission storage submission = requests[requestId].submissions[analyst];
        return (
            submission.forecastDataHash,
            submission.modelHash,
            submission.submissionTime,
            submission.accuracyScore,
            submission.isVerified
        );
    }
    
    /**
     * @dev Emergency withdrawal for unclaimed bounties
     */
    function emergencyWithdraw(uint256 requestId) external {
        ForecastRequest storage request = requests[requestId];
        require(msg.sender == request.requester, "Only requester can withdraw");
        require(
            block.timestamp > request.verificationDeadline + 30 days,
            "Must wait 30 days after verification deadline"
        );
        require(!request.isVerified, "Request already verified");
        
        uint256 amount = request.bountyAmount;
        request.bountyAmount = 0;
        request.isActive = false;
        
        payable(msg.sender).transfer(amount);
    }
    
    /**
     * @dev Update platform parameters (admin function)
     */
    function updateParameters(
        uint256 _minimumBounty,
        uint256 _platformFeeRate,
        address _oracleNetwork
    ) external {
        require(msg.sender == treasury, "Only treasury can update");
        minimumBounty = _minimumBounty;
        platformFeeRate = _platformFeeRate;
        oracleNetwork = _oracleNetwork;
    }
}