// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Carbon Credit Trading
 * @dev Automated carbon offset verification and trading for environmental projects
 * Enables transparent carbon credit marketplace with verified environmental impact
 */
contract CarbonCreditTrading is ReentrancyGuard {
    struct CarbonCredit {
        uint256 creditId;
        address issuer;
        string projectId;
        string projectName;
        string location;
        uint256 co2Reduced;          // CO2 reduced in tons * 100
        uint256 issueDate;
        uint256 verificationDate;
        uint256 expiryDate;
        CreditType creditType;
        CreditStatus status;
        address currentOwner;
        string verificationHash;     // IPFS hash of verification documents
        uint256 price;               // Price in WRF tokens
        bool isForSale;
    }

    struct EnvironmentalProject {
        string projectId;
        address developer;
        string name;
        string description;
        string location;
        ProjectType projectType;
        uint256 expectedCO2Reduction;
        uint256 actualCO2Reduction;
        uint256 startDate;
        uint256 endDate;
        bool isActive;
        bool isVerified;
        string[] verificationDocs;   // IPFS hashes
        uint256 totalCreditsIssued;
    }

    struct Trade {
        uint256 tradeId;
        uint256 creditId;
        address seller;
        address buyer;
        uint256 price;
        uint256 timestamp;
        string purpose;              // Offset purpose/reason
    }

    enum CreditType {
        RENEWABLE_ENERGY,
        FOREST_CONSERVATION,
        REFORESTATION,
        METHANE_CAPTURE,
        DIRECT_AIR_CAPTURE,
        BLUE_CARBON,
        ENERGY_EFFICIENCY,
        SUSTAINABLE_AGRICULTURE
    }

    enum CreditStatus {
        PENDING,
        VERIFIED,
        ACTIVE,
        RETIRED,
        EXPIRED,
        CANCELLED
    }

    enum ProjectType {
        SOLAR,
        WIND,
        HYDRO,
        BIOMASS,
        FOREST,
        OCEAN,
        INDUSTRIAL,
        AGRICULTURAL
    }

    mapping(uint256 => CarbonCredit) public carbonCredits;
    mapping(string => EnvironmentalProject) public projects;
    mapping(address => uint256[]) public ownerCredits;
    mapping(address => bool) public authorizedVerifiers;
    mapping(uint256 => Trade) public trades;
    
    uint256 public nextCreditId = 1;
    uint256 public nextTradeId = 1;
    address public owner;
    uint256 public verificationFee = 5 * 10**18;    // 5 WRF tokens
    uint256 public tradingFee = 100;                // 1% trading fee
    uint256 public totalCreditsIssued;
    uint256 public totalCO2Offset;

    event ProjectRegistered(string indexed projectId, address indexed developer, ProjectType projectType);
    event CreditIssued(uint256 indexed creditId, string indexed projectId, uint256 co2Reduced);
    event CreditVerified(uint256 indexed creditId, address indexed verifier);
    event CreditListed(uint256 indexed creditId, uint256 price);
    event CreditTraded(uint256 indexed tradeId, uint256 indexed creditId, address seller, address buyer, uint256 price);
    event CreditRetired(uint256 indexed creditId, address indexed owner, string purpose);
    event ProjectVerified(string indexed projectId, address indexed verifier);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier onlyVerifier() {
        require(authorizedVerifiers[msg.sender], "Not authorized verifier");
        _;
    }

    modifier onlyCreditOwner(uint256 _creditId) {
        require(carbonCredits[_creditId].currentOwner == msg.sender, "Not credit owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedVerifiers[msg.sender] = true;
    }

    /**
     * @dev Register a new environmental project
     */
    function registerProject(
        string memory _projectId,
        string memory _name,
        string memory _description,
        string memory _location,
        ProjectType _projectType,
        uint256 _expectedCO2Reduction,
        uint256 _startDate,
        uint256 _endDate
    ) external {
        require(bytes(projects[_projectId].projectId).length == 0, "Project already exists");
        require(_endDate > _startDate, "Invalid project duration");

        projects[_projectId] = EnvironmentalProject({
            projectId: _projectId,
            developer: msg.sender,
            name: _name,
            description: _description,
            location: _location,
            projectType: _projectType,
            expectedCO2Reduction: _expectedCO2Reduction,
            actualCO2Reduction: 0,
            startDate: _startDate,
            endDate: _endDate,
            isActive: true,
            isVerified: false,
            verificationDocs: new string[](0),
            totalCreditsIssued: 0
        });

        emit ProjectRegistered(_projectId, msg.sender, _projectType);
    }

    /**
     * @dev Issue carbon credits for verified CO2 reduction
     */
    function issueCredits(
        string memory _projectId,
        uint256 _co2Reduced,
        CreditType _creditType,
        string memory _verificationHash,
        uint256 _expiryDate
    ) external onlyVerifier {
        require(projects[_projectId].isVerified, "Project not verified");
        require(projects[_projectId].isActive, "Project not active");
        require(_co2Reduced > 0, "CO2 reduction must be positive");

        uint256 creditId = nextCreditId++;

        carbonCredits[creditId] = CarbonCredit({
            creditId: creditId,
            issuer: msg.sender,
            projectId: _projectId,
            projectName: projects[_projectId].name,
            location: projects[_projectId].location,
            co2Reduced: _co2Reduced,
            issueDate: block.timestamp,
            verificationDate: block.timestamp,
            expiryDate: _expiryDate,
            creditType: _creditType,
            status: CreditStatus.VERIFIED,
            currentOwner: projects[_projectId].developer,
            verificationHash: _verificationHash,
            price: 0,
            isForSale: false
        });

        projects[_projectId].actualCO2Reduction += _co2Reduced;
        projects[_projectId].totalCreditsIssued++;
        ownerCredits[projects[_projectId].developer].push(creditId);
        
        totalCreditsIssued++;
        totalCO2Offset += _co2Reduced;

        emit CreditIssued(creditId, _projectId, _co2Reduced);
    }

    /**
     * @dev List carbon credit for sale
     */
    function listCreditForSale(uint256 _creditId, uint256 _price) external onlyCreditOwner(_creditId) {
        require(carbonCredits[_creditId].status == CreditStatus.VERIFIED, "Credit not verified");
        require(_price > 0, "Price must be positive");

        carbonCredits[_creditId].price = _price;
        carbonCredits[_creditId].isForSale = true;

        emit CreditListed(_creditId, _price);
    }

    /**
     * @dev Purchase carbon credit with automatic payment to seller
     * Transfers (price - trading fee) to seller and refunds excess to buyer
     */
    function purchaseCredit(uint256 _creditId, string memory _purpose) external payable nonReentrant {
        CarbonCredit storage credit = carbonCredits[_creditId];
        require(credit.isForSale, "Credit not for sale");
        require(credit.status == CreditStatus.VERIFIED, "Credit not verified");
        require(msg.value >= credit.price, "Insufficient payment");
        require(credit.currentOwner != msg.sender, "Cannot buy own credit");

        address seller = credit.currentOwner;
        uint256 price = credit.price;
        uint256 fee = (price * tradingFee) / 10000;

        // Transfer ownership
        credit.currentOwner = msg.sender;
        credit.isForSale = false;
        credit.price = 0;

        // Update ownership records
        _removeFromOwnerCredits(seller, _creditId);
        ownerCredits[msg.sender].push(_creditId);

        // Record trade
        uint256 tradeId = nextTradeId++;
        trades[tradeId] = Trade({
            tradeId: tradeId,
            creditId: _creditId,
            seller: seller,
            buyer: msg.sender,
            price: price,
            timestamp: block.timestamp,
            purpose: _purpose
        });

        // Handle payments - transfer funds to seller after deducting fee
        uint256 sellerAmount = price - fee;
        
        // Transfer payment to seller (price minus trading fee)
        if (sellerAmount > 0) {
            (bool success, ) = payable(seller).call{value: sellerAmount}("");
            require(success, "Payment to seller failed");
        }
        
        // Refund excess payment to buyer if any
        uint256 excess = msg.value - price;
        if (excess > 0) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: excess}("");
            require(refundSuccess, "Refund to buyer failed");
        }
        
        emit CreditTraded(tradeId, _creditId, seller, msg.sender, price);
    }

    /**
     * @dev Retire carbon credit (permanent offset)
     */
    function retireCredit(uint256 _creditId, string memory _purpose) external onlyCreditOwner(_creditId) {
        require(carbonCredits[_creditId].status == CreditStatus.VERIFIED, "Credit not verified");
        
        carbonCredits[_creditId].status = CreditStatus.RETIRED;
        carbonCredits[_creditId].isForSale = false;

        emit CreditRetired(_creditId, msg.sender, _purpose);
    }

    /**
     * @dev Verify environmental project
     */
    function verifyProject(
        string memory _projectId,
        string[] memory _verificationDocs
    ) external onlyVerifier payable {
        require(msg.value >= verificationFee, "Insufficient verification fee");
        require(bytes(projects[_projectId].projectId).length > 0, "Project does not exist");

        projects[_projectId].isVerified = true;
        
        for (uint256 i = 0; i < _verificationDocs.length; i++) {
            projects[_projectId].verificationDocs.push(_verificationDocs[i]);
        }

        emit ProjectVerified(_projectId, msg.sender);
    }

    /**
     * @dev Add authorized verifier
     */
    function addVerifier(address _verifier) external onlyOwner {
        authorizedVerifiers[_verifier] = true;
    }

    /**
     * @dev Remove verifier authorization
     */
    function removeVerifier(address _verifier) external onlyOwner {
        authorizedVerifiers[_verifier] = false;
    }

    /**
     * @dev Get carbon credit details
     */
    function getCreditDetails(uint256 _creditId) external view returns (
        string memory projectName,
        uint256 co2Reduced,
        CreditType creditType,
        CreditStatus status,
        address currentOwner,
        uint256 price,
        bool isForSale
    ) {
        CarbonCredit memory credit = carbonCredits[_creditId];
        return (
            credit.projectName,
            credit.co2Reduced,
            credit.creditType,
            credit.status,
            credit.currentOwner,
            credit.price,
            credit.isForSale
        );
    }

    /**
     * @dev Get project statistics
     */
    function getProjectStats(string memory _projectId) external view returns (
        uint256 expectedCO2Reduction,
        uint256 actualCO2Reduction,
        uint256 creditsIssued,
        bool isVerified,
        bool isActive
    ) {
        EnvironmentalProject memory project = projects[_projectId];
        return (
            project.expectedCO2Reduction,
            project.actualCO2Reduction,
            project.totalCreditsIssued,
            project.isVerified,
            project.isActive
        );
    }

    /**
     * @dev Get credits owned by address
     */
    function getOwnerCredits(address _owner) external view returns (uint256[] memory) {
        return ownerCredits[_owner];
    }

    /**
     * @dev Get marketplace statistics
     */
    function getMarketplaceStats() external view returns (
        uint256 totalCredits,
        uint256 totalOffset,
        uint256 totalTrades
    ) {
        return (totalCreditsIssued, totalCO2Offset, nextTradeId - 1);
    }

    /**
     * @dev Internal function to remove credit from owner's list
     */
    function _removeFromOwnerCredits(address _owner, uint256 _creditId) internal {
        uint256[] storage credits = ownerCredits[_owner];
        for (uint256 i = 0; i < credits.length; i++) {
            if (credits[i] == _creditId) {
                credits[i] = credits[credits.length - 1];
                credits.pop();
                break;
            }
        }
    }
}