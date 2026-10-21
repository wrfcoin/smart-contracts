// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Private Analysis Contracts
 * @dev Enables users to request private environmental analysis with confidential data
 * AI analyzers bid for jobs and deliver results through secure channels
 */
contract PrivateAnalysisContracts {
    
    struct AnalysisRequest {
        uint256 requestId;
        address requester;
        string analysisType; // "air_quality", "climate_risk", "environmental_impact"
        string encryptedDataHash; // Encrypted IPFS hash
        uint256 bountyAmount;
        uint256 deadline;
        uint256 maxBidders;
        bool isActive;
        bool isCompleted;
        address selectedAnalyzer;
        uint256 totalBids;
        mapping(address => AnalyzerBid) bids;
        address[] bidders;
    }
    
    struct AnalyzerBid {
        address analyzer;
        uint256 bidAmount;
        uint256 estimatedTime; // in hours
        string credentialsHash; // IPFS hash of credentials
        string proposalHash; // IPFS hash of analysis proposal
        uint256 bidTime;
        bool isSelected;
    }
    
    struct AnalyzerProfile {
        address analyzer;
        string specialization;
        uint256 completedJobs;
        uint256 totalEarnings;
        uint256 averageRating;
        uint256 ratingCount;
        bool isVerified;
        string certificationHash; // IPFS hash of certifications
    }
    
    struct DeliverySubmission {
        uint256 requestId;
        address analyzer;
        string encryptedResultHash; // Encrypted analysis results
        string proofOfWorkHash; // IPFS hash proving work completed
        uint256 submissionTime;
        bool isApproved;
        uint256 rating; // 1-5 stars
        string feedback;
    }
    
    mapping(uint256 => AnalysisRequest) public requests;
    mapping(address => AnalyzerProfile) public analyzers;
    mapping(uint256 => DeliverySubmission) public deliveries;
    
    uint256 public nextRequestId = 1;
    uint256 public minimumBounty = 10000000000000000000; // 10 WRF minimum for private analysis
    uint256 public platformFeeRate = 500; // 5% platform fee
    address public treasury;
    address public oracleNetwork;
    
    event AnalysisRequested(
        uint256 indexed requestId,
        address indexed requester,
        string analysisType,
        uint256 bountyAmount,
        uint256 deadline
    );
    
    event BidSubmitted(
        uint256 indexed requestId,
        address indexed analyzer,
        uint256 bidAmount,
        uint256 estimatedTime
    );
    
    event AnalyzerSelected(
        uint256 indexed requestId,
        address indexed analyzer,
        uint256 bidAmount
    );
    
    event AnalysisDelivered(
        uint256 indexed requestId,
        address indexed analyzer,
        string encryptedResultHash,
        uint256 payment
    );
    
    event AnalyzerVerified(address indexed analyzer, string specialization);
    
    modifier onlyOracle() {
        require(msg.sender == oracleNetwork, "Only oracle can verify");
        _;
    }
    
    modifier onlyActiveRequest(uint256 requestId) {
        require(requests[requestId].isActive, "Request not active");
        require(block.timestamp < requests[requestId].deadline, "Deadline passed");
        _;
    }
    
    constructor(address _treasury, address _oracleNetwork) {
        treasury = _treasury;
        oracleNetwork = _oracleNetwork;
    }
    
    /**
     * @dev Request private environmental analysis
     */
    function requestAnalysis(
        string memory analysisType,
        string memory encryptedDataHash,
        uint256 deadline,
        uint256 maxBidders
    ) external payable {
        require(msg.value >= minimumBounty, "Bounty below minimum");
        require(deadline > block.timestamp, "Deadline must be in future");
        require(maxBidders > 0 && maxBidders <= 20, "Invalid max bidders");
        
        uint256 requestId = nextRequestId++;
        AnalysisRequest storage request = requests[requestId];
        
        request.requestId = requestId;
        request.requester = msg.sender;
        request.analysisType = analysisType;
        request.encryptedDataHash = encryptedDataHash;
        request.bountyAmount = msg.value;
        request.deadline = deadline;
        request.maxBidders = maxBidders;
        request.isActive = true;
        
        emit AnalysisRequested(
            requestId,
            msg.sender,
            analysisType,
            msg.value,
            deadline
        );
    }
    
    /**
     * @dev Submit bid for analysis request
     */
    function submitBid(
        uint256 requestId,
        uint256 bidAmount,
        uint256 estimatedTime,
        string memory credentialsHash,
        string memory proposalHash
    ) external onlyActiveRequest(requestId) {
        AnalysisRequest storage request = requests[requestId];
        
        require(request.totalBids < request.maxBidders, "Max bidders reached");
        require(request.bids[msg.sender].analyzer == address(0), "Already submitted bid");
        require(bidAmount <= request.bountyAmount, "Bid exceeds bounty");
        require(analyzers[msg.sender].isVerified, "Analyzer not verified");
        
        // Create bid
        request.bids[msg.sender] = AnalyzerBid({
            analyzer: msg.sender,
            bidAmount: bidAmount,
            estimatedTime: estimatedTime,
            credentialsHash: credentialsHash,
            proposalHash: proposalHash,
            bidTime: block.timestamp,
            isSelected: false
        });
        
        request.bidders.push(msg.sender);
        request.totalBids++;
        
        emit BidSubmitted(requestId, msg.sender, bidAmount, estimatedTime);
    }
    
    /**
     * @dev Select winning bid for analysis
     */
    function selectAnalyzer(uint256 requestId, address analyzer) external {
        AnalysisRequest storage request = requests[requestId];
        
        require(msg.sender == request.requester, "Only requester can select");
        require(request.isActive, "Request not active");
        require(request.selectedAnalyzer == address(0), "Analyzer already selected");
        require(request.bids[analyzer].analyzer == analyzer, "Invalid analyzer");
        
        request.selectedAnalyzer = analyzer;
        request.bids[analyzer].isSelected = true;
        request.isActive = false;
        
        emit AnalyzerSelected(requestId, analyzer, request.bids[analyzer].bidAmount);
    }
    
    /**
     * @dev Deliver analysis results
     */
    function deliverAnalysis(
        uint256 requestId,
        string memory encryptedResultHash,
        string memory proofOfWorkHash
    ) external {
        AnalysisRequest storage request = requests[requestId];
        
        require(msg.sender == request.selectedAnalyzer, "Only selected analyzer");
        require(!request.isCompleted, "Request already completed");
        require(deliveries[requestId].analyzer == address(0), "Already delivered");
        
        // Record delivery
        deliveries[requestId] = DeliverySubmission({
            requestId: requestId,
            analyzer: msg.sender,
            encryptedResultHash: encryptedResultHash,
            proofOfWorkHash: proofOfWorkHash,
            submissionTime: block.timestamp,
            isApproved: false,
            rating: 0,
            feedback: ""
        });
        
        emit AnalysisDelivered(requestId, msg.sender, encryptedResultHash, 0);
    }
    
    /**
     * @dev Approve delivery and release payment
     */
    function approveDelivery(
        uint256 requestId,
        uint256 rating,
        string memory feedback
    ) external {
        AnalysisRequest storage request = requests[requestId];
        DeliverySubmission storage delivery = deliveries[requestId];
        
        require(msg.sender == request.requester, "Only requester can approve");
        require(delivery.analyzer != address(0), "No delivery found");
        require(!delivery.isApproved, "Already approved");
        require(rating >= 1 && rating <= 5, "Invalid rating");
        
        // Mark as approved
        delivery.isApproved = true;
        delivery.rating = rating;
        delivery.feedback = feedback;
        request.isCompleted = true;
        
        // Calculate payments
        uint256 bidAmount = request.bids[delivery.analyzer].bidAmount;
        uint256 platformFee = (bidAmount * platformFeeRate) / 10000;
        uint256 analyzerPayment = bidAmount - platformFee;
        uint256 refund = request.bountyAmount - bidAmount;
        
        // Update analyzer profile
        AnalyzerProfile storage profile = analyzers[delivery.analyzer];
        profile.completedJobs++;
        profile.totalEarnings += analyzerPayment;
        profile.averageRating = (profile.averageRating * profile.ratingCount + rating) / (profile.ratingCount + 1);
        profile.ratingCount++;
        
        // Transfer payments
        payable(delivery.analyzer).transfer(analyzerPayment);
        payable(treasury).transfer(platformFee);
        
        if (refund > 0) {
            payable(request.requester).transfer(refund);
        }
        
        emit AnalysisDelivered(requestId, delivery.analyzer, delivery.encryptedResultHash, analyzerPayment);
    }
    
    /**
     * @dev Verify analyzer credentials
     */
    function verifyAnalyzer(
        address analyzer,
        string memory specialization,
        string memory certificationHash
    ) external onlyOracle {
        AnalyzerProfile storage profile = analyzers[analyzer];
        
        profile.analyzer = analyzer;
        profile.specialization = specialization;
        profile.isVerified = true;
        profile.certificationHash = certificationHash;
        
        emit AnalyzerVerified(analyzer, specialization);
    }
    
    /**
     * @dev Get all bidders for a request
     */
    function getRequestBidders(uint256 requestId) external view returns (address[] memory) {
        return requests[requestId].bidders;
    }
    
    /**
     * @dev Get bid details
     */
    function getBidDetails(uint256 requestId, address analyzer) external view returns (
        uint256 bidAmount,
        uint256 estimatedTime,
        string memory credentialsHash,
        string memory proposalHash,
        uint256 bidTime,
        bool isSelected
    ) {
        AnalyzerBid storage bid = requests[requestId].bids[analyzer];
        return (
            bid.bidAmount,
            bid.estimatedTime,
            bid.credentialsHash,
            bid.proposalHash,
            bid.bidTime,
            bid.isSelected
        );
    }
    
    /**
     * @dev Emergency refund for incomplete jobs
     */
    function emergencyRefund(uint256 requestId) external {
        AnalysisRequest storage request = requests[requestId];
        
        require(msg.sender == request.requester, "Only requester can refund");
        require(request.selectedAnalyzer != address(0), "No analyzer selected");
        require(!request.isCompleted, "Request completed");
        
        // Check if deadline passed with no delivery
        DeliverySubmission storage delivery = deliveries[requestId];
        require(
            delivery.analyzer == address(0) && 
            block.timestamp > request.deadline + 7 days,
            "Too early for emergency refund"
        );
        
        uint256 refundAmount = request.bountyAmount;
        request.bountyAmount = 0;
        request.isCompleted = true;
        
        payable(request.requester).transfer(refundAmount);
    }
    
    /**
     * @dev Update contract parameters
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