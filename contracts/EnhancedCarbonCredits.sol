// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./WRFToken.sol";

/**
 * @title EnhancedCarbonCredits
 * @dev ERC1155-based carbon credits designed for registry compliance and DeFi composability
 * Supports Verra's "Authorized Tokenization Platform" model with immobilization/retirement lifecycle
 * Each tokenId represents a specific carbon credit batch with fungible sub-units
 */
contract EnhancedCarbonCredits is ERC1155, ERC1155URIStorage, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Role definitions for access control
    bytes32 public constant REGISTRY_CONNECTOR_ROLE = keccak256("REGISTRY_CONNECTOR_ROLE");
    bytes32 public constant AUTHORIZED_ISSUER_ROLE = keccak256("AUTHORIZED_ISSUER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    // Input params for createBatch to avoid stack-too-deep
    struct CreateBatchParams {
        uint256 totalSupplyKg;
        string projectId;
        uint256 vintage;
        string methodology;
        string projectType;
        string registryStandard;
        string location;
        uint256 expiryDate;
        string certificationHash;
        string registryUrl;
        string metadataUri;
    }

    // Batch metadata structure for each tokenId
    struct CarbonCreditBatch {
        uint256 totalSupply;           // Total units in this batch (in kg CO2e)
        uint256 immobilizedSupply;     // Units immobilized in registry
        uint256 retiredSupply;         // Units retired (burned)
        string projectId;              // Registry project identifier
        uint256 vintage;               // Year of issuance
        string methodology;            // Verification methodology (e.g., "VM0006")
        string projectType;            // "renewable-energy", "forestry", "direct-air-capture"
        string registryStandard;       // "VCS", "GS", "CDM", "CAR"
        string location;               // Geographic coordinates or region
        address issuer;                // Original issuer address
        uint256 issuanceDate;          // Block timestamp of issuance
        uint256 expiryDate;            // Expiry date for trading
        string certificationHash;      // IPFS hash of verification documents
        string registryUrl;            // Direct link to registry entry
        bool isActive;                 // Whether batch is active for trading
    }
    
    // Trading and marketplace structures
    struct MarketListing {
        address seller;
        uint256 amount;
        uint256 pricePerUnit;          // Price per kg CO2e in WRF
        uint256 expiry;                // Listing expiry timestamp
        bool isActive;
    }
    
    WRFToken public immutable wrfToken;
    uint256 private _nextTokenId = 1;
    uint256 public constant RETIREMENT_FEE_BASIS_POINTS = 25; // 0.25% fee
    
    // Core mappings
    mapping(uint256 => CarbonCreditBatch) internal batches;
    mapping(string => bool) public usedCertificationHashes;
    mapping(string => uint256) public projectIdToTokenId;
    
    // Trading mappings
    // tokenId => listingId => MarketListing
    mapping(uint256 => mapping(uint256 => MarketListing)) public marketListings;
    mapping(uint256 => uint256) public nextListingId; // tokenId => next listing ID
    
    // Statistics tracking
    mapping(address => uint256) public totalCreditsIssued;
    mapping(address => uint256) public totalCreditsRetired;
    mapping(address => mapping(uint256 => uint256)) public userRetiredByTokenId;
    
    // Events
    event BatchCreated(
        uint256 indexed tokenId,
        address indexed issuer,
        string projectId,
        uint256 totalSupply,
        uint256 vintage
    );
    
    event CreditsImmobilized(
        uint256 indexed tokenId,
        uint256 amount,
        address indexed recipient
    );
    
    event CreditsRetired(
        uint256 indexed tokenId,
        address indexed retiringEntity,
        uint256 amount,
        string retirementMessage,
        uint256 fee
    );
    
    event CreditListed(
        uint256 indexed tokenId,
        uint256 indexed listingId,
        address indexed seller,
        uint256 amount,
        uint256 pricePerUnit
    );
    
    event CreditSold(
        uint256 indexed tokenId,
        uint256 indexed listingId,
        address indexed buyer,
        address seller,
        uint256 amount,
        uint256 totalPrice
    );
    
    event BatchStatusUpdated(uint256 indexed tokenId, bool isActive);
    
    // Modifiers
    modifier validTokenId(uint256 tokenId) {
        require(batches[tokenId].issuanceDate > 0, "EnhancedCarbonCredits: Invalid token ID");
        _;
    }
    
    modifier batchActive(uint256 tokenId) {
        require(batches[tokenId].isActive, "EnhancedCarbonCredits: Batch not active");
        require(
            block.timestamp <= batches[tokenId].expiryDate,
            "EnhancedCarbonCredits: Batch expired"
        );
        _;
    }
    
    constructor(address _wrfToken) ERC1155("") {
        wrfToken = WRFToken(_wrfToken);
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(REGISTRY_CONNECTOR_ROLE, msg.sender);
    }
    
    /**
     * @dev Create a new carbon credit batch (only by authorized issuers)
     */
    function createBatch(
        CreateBatchParams calldata params
    ) external onlyRole(AUTHORIZED_ISSUER_ROLE) returns (uint256) {
        require(params.totalSupplyKg > 0, "EnhancedCarbonCredits: Invalid supply");
        require(params.vintage >= 2008, "EnhancedCarbonCredits: Invalid vintage");
        require(params.expiryDate > block.timestamp, "EnhancedCarbonCredits: Invalid expiry");
        require(!usedCertificationHashes[params.certificationHash], "EnhancedCarbonCredits: Hash already used");
        require(projectIdToTokenId[params.projectId] == 0, "EnhancedCarbonCredits: Project already tokenized");

        uint256 tokenId = _nextTokenId++;

        CarbonCreditBatch storage batch = batches[tokenId];
        batch.totalSupply = params.totalSupplyKg;
        batch.projectId = params.projectId;
        batch.vintage = params.vintage;
        batch.methodology = params.methodology;
        batch.projectType = params.projectType;
        batch.registryStandard = params.registryStandard;
        batch.location = params.location;
        batch.issuer = msg.sender;
        batch.issuanceDate = block.timestamp;
        batch.expiryDate = params.expiryDate;
        batch.certificationHash = params.certificationHash;
        batch.registryUrl = params.registryUrl;
        batch.isActive = true;

        usedCertificationHashes[params.certificationHash] = true;
        projectIdToTokenId[params.projectId] = tokenId;
        totalCreditsIssued[msg.sender] += params.totalSupplyKg;

        _setURI(tokenId, params.metadataUri);

        emit BatchCreated(tokenId, msg.sender, params.projectId, params.totalSupplyKg, params.vintage);

        return tokenId;
    }
    
    /**
     * @dev Get batch core data
     */
    function getBatchCore(uint256 tokenId) external view returns (
        uint256 totalSupply, uint256 immobilizedSupply, uint256 retiredSupply,
        uint256 vintage, address issuer, uint256 issuanceDate, uint256 expiryDate, bool isActive
    ) {
        CarbonCreditBatch storage b = batches[tokenId];
        return (b.totalSupply, b.immobilizedSupply, b.retiredSupply, b.vintage, b.issuer, b.issuanceDate, b.expiryDate, b.isActive);
    }

    /**
     * @dev Get batch metadata (strings)
     */
    function getBatchMetadata(uint256 tokenId) external view returns (
        string memory projectId, string memory methodology, string memory projectType,
        string memory registryStandard, string memory location, string memory certificationHash, string memory registryUrl
    ) {
        CarbonCreditBatch storage b = batches[tokenId];
        return (b.projectId, b.methodology, b.projectType, b.registryStandard, b.location, b.certificationHash, b.registryUrl);
    }

    /**
     * @dev Immobilize credits from registry and mint tokens (Registry Connector only)
     */
    function immobilizeCredits(
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external onlyRole(REGISTRY_CONNECTOR_ROLE) validTokenId(tokenId) {
        CarbonCreditBatch storage batch = batches[tokenId];
        require(
            batch.immobilizedSupply + amount <= batch.totalSupply,
            "EnhancedCarbonCredits: Exceeds total supply"
        );
        
        batch.immobilizedSupply += amount;
        _mint(recipient, tokenId, amount, "");
        
        emit CreditsImmobilized(tokenId, amount, recipient);
    }
    
    /**
     * @dev Retire carbon credits (burn tokens and update registry)
     */
    function retireCredits(
        uint256 tokenId,
        uint256 amount,
        string calldata retirementMessage
    ) external validTokenId(tokenId) batchActive(tokenId) nonReentrant {
        require(balanceOf(msg.sender, tokenId) >= amount, "EnhancedCarbonCredits: Insufficient balance");
        require(amount > 0, "EnhancedCarbonCredits: Invalid amount");
        
        // Calculate retirement fee
        uint256 fee = (amount * RETIREMENT_FEE_BASIS_POINTS) / 10000;
        require(
            wrfToken.transferFrom(msg.sender, address(this), fee),
            "EnhancedCarbonCredits: Fee payment failed"
        );
        
        // Burn the tokens
        _burn(msg.sender, tokenId, amount);
        
        // Update batch statistics
        batches[tokenId].retiredSupply += amount;
        totalCreditsRetired[msg.sender] += amount;
        userRetiredByTokenId[msg.sender][tokenId] += amount;
        
        emit CreditsRetired(tokenId, msg.sender, amount, retirementMessage, fee);
    }
    
    /**
     * @dev List credits for sale on the marketplace
     */
    function listCreditsForSale(
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerUnit,
        uint256 expiry
    ) external validTokenId(tokenId) batchActive(tokenId) {
        require(balanceOf(msg.sender, tokenId) >= amount, "EnhancedCarbonCredits: Insufficient balance");
        require(amount > 0 && pricePerUnit > 0, "EnhancedCarbonCredits: Invalid parameters");
        require(expiry > block.timestamp, "EnhancedCarbonCredits: Invalid expiry");
        
        uint256 listingId = nextListingId[tokenId]++;
        
        marketListings[tokenId][listingId] = MarketListing({
            seller: msg.sender,
            amount: amount,
            pricePerUnit: pricePerUnit,
            expiry: expiry,
            isActive: true
        });
        
        emit CreditListed(tokenId, listingId, msg.sender, amount, pricePerUnit);
    }
    
    /**
     * @dev Purchase credits from marketplace
     */
    function purchaseCredits(
        uint256 tokenId,
        uint256 listingId,
        uint256 amount
    ) external validTokenId(tokenId) batchActive(tokenId) nonReentrant {
        MarketListing storage listing = marketListings[tokenId][listingId];
        
        require(listing.isActive, "EnhancedCarbonCredits: Listing not active");
        require(block.timestamp <= listing.expiry, "EnhancedCarbonCredits: Listing expired");
        require(amount <= listing.amount, "EnhancedCarbonCredits: Insufficient listed amount");
        require(listing.seller != msg.sender, "EnhancedCarbonCredits: Cannot buy own listing");
        
        uint256 totalPrice = amount * listing.pricePerUnit;
        
        // Transfer payment
        require(
            wrfToken.transferFrom(msg.sender, listing.seller, totalPrice),
            "EnhancedCarbonCredits: Payment failed"
        );
        
        // Transfer tokens
        _safeTransferFrom(listing.seller, msg.sender, tokenId, amount, "");
        
        // Update listing
        listing.amount -= amount;
        if (listing.amount == 0) {
            listing.isActive = false;
        }
        
        emit CreditSold(tokenId, listingId, msg.sender, listing.seller, amount, totalPrice);
    }
    
    /**
     * @dev Cancel a marketplace listing
     */
    function cancelListing(uint256 tokenId, uint256 listingId) external {
        MarketListing storage listing = marketListings[tokenId][listingId];
        require(listing.seller == msg.sender, "EnhancedCarbonCredits: Not listing owner");
        require(listing.isActive, "EnhancedCarbonCredits: Listing not active");
        
        listing.isActive = false;
    }
    
    /**
     * @dev Get detailed batch information
     */
    function getBatchInfo(uint256 tokenId) external view validTokenId(tokenId) returns (
        CarbonCreditBatch memory
    ) {
        return batches[tokenId];
    }
    
    /**
     * @dev Get user's retirement statistics
     */
    function getUserRetirementStats(address user) external view returns (
        uint256 totalRetired,
        uint256 totalIssued
    ) {
        return (totalCreditsRetired[user], totalCreditsIssued[user]);
    }
    
    /**
     * @dev Estimate carbon offset value in WRF tokens
     */
    function estimateOffsetValue(uint256 carbonOffsetKg, string calldata projectType) 
        external 
        pure 
        returns (uint256) 
    {
        // Base price: 50 WRF per tonne (1000 kg)
        uint256 basePrice = (carbonOffsetKg * 50 * 10**18) / 1000;
        
        // Premium for high-quality project types
        if (keccak256(abi.encodePacked(projectType)) == keccak256("direct-air-capture")) {
            return basePrice * 3; // 3x premium for DAC
        } else if (keccak256(abi.encodePacked(projectType)) == keccak256("renewable-energy")) {
            return basePrice * 12 / 10; // 20% premium
        }
        
        return basePrice;
    }
    
    /**
     * @dev Admin function to update batch status
     */
    function setBatchStatus(uint256 tokenId, bool isActive) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        validTokenId(tokenId) 
    {
        batches[tokenId].isActive = isActive;
        emit BatchStatusUpdated(tokenId, isActive);
    }
    
    /**
     * @dev Withdraw accumulated fees (admin only)
     */
    function withdrawFees(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(address(wrfToken)).safeTransfer(to, amount);
    }
    
    /**
     * @dev Pause contract (emergency use)
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause contract
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    // Override functions
    function uri(uint256 tokenId) public view override(ERC1155, ERC1155URIStorage) returns (string memory) {
        return super.uri(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(ERC1155, AccessControl) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
    
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override whenNotPaused {
        super._update(from, to, ids, values);
    }
}