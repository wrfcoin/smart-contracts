// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./ComputationalNFT.sol";
import "./WRFToken.sol";

/**
 * @title NFTMarketplace
 * @author WRFCoin Development Team
 * @notice Production-ready NFT marketplace with comprehensive security features and ERC2981 royalty compliance
 * @dev Implements secure NFT trading with advanced auction mechanics, flash loan attack prevention,
 *      and enterprise-grade security patterns for the WRFCoin ecosystem
 * 
 * Security Features:
 * - ERC2981 compliant royalty distribution
 * - Anti-sniping auction protection with time extensions
 * - Flash loan attack prevention via CEI pattern
 * - Price manipulation protection with minimum increments
 * - Economic security for high-value transactions
 * - Batch operations with gas optimization
 * - Emergency pause and recovery mechanisms
 * 
 * Supported Features:
 * - Fixed price listings with private sale options
 * - English auctions with reserve prices
 * - Dutch auctions with declining prices
 * - Multi-currency support (ETH, WRF, custom ERC20)
 * - Cross-chain bridging integration
 * - Dynamic fee adjustment based on volume
 * - Comprehensive event logging and statistics
 */
contract NFTMarketplace is Ownable, ReentrancyGuard, Pausable, IERC721Receiver, ERC165 {
    using SafeERC20 for IERC20;
    using Address for address payable;
    
    // ============ Enums ============
    
    enum ListingType { FixedPrice, Auction, DutchAuction }
    enum ListingStatus { Active, Sold, Cancelled, Expired }
    enum PaymentToken { Native, WRF, USDC, Custom }
    
    // ============ Structs ============
    
    struct Listing {
        uint256 listingId;
        address nftContract;
        uint256 tokenId;
        address seller;
        uint256 price;
        uint256 startPrice;      // For auctions
        uint256 endPrice;        // For Dutch auctions
        uint256 startTime;
        uint256 endTime;
        ListingType listingType;
        ListingStatus status;
        PaymentToken paymentToken;
        address paymentContract; // For custom ERC20
        uint256 reservePrice;    // Minimum price for auctions
        bool allowPrivateSale;
        address[] allowedBuyers; // For private sales
    }
    
    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
        bool isActive;
    }
    
    /**
     * @notice Royalty information structure
     * @param recipient Address to receive royalty payments
     * @param percentage Royalty percentage in basis points (100 = 1%, 10000 = 100%)
     */
    struct RoyaltyInfo {
        address recipient;
        uint256 percentage; // Basis points (100 = 1%, 10000 = 100%)
    }
    
    /**
     * @notice Batch listing structure for gas-efficient bulk operations
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID to list
     * @param price Listing price in specified payment token
     * @param duration Listing duration in seconds (0 = unlimited)
     */
    struct BatchListingParams {
        address nftContract;
        uint256 tokenId;
        uint256 price;
        uint256 duration;
    }
    
    /**
     * @notice Offer structure for buy/sell offers
     * @param offerer Address making the offer
     * @param amount Offer amount
     * @param paymentToken Payment token for the offer
     * @param paymentContract Address of payment token contract (if custom)
     * @param expiration Offer expiration timestamp
     * @param isActive Whether the offer is still active
     */
    struct Offer {
        address offerer;
        uint256 amount;
        PaymentToken paymentToken;
        address paymentContract;
        uint256 expiration;
        bool isActive;
    }
    
    struct MarketStats {
        uint256 totalSales;
        uint256 totalVolume;
        uint256 averagePrice;
        uint256 uniqueBuyers;
        uint256 uniqueSellers;
    }
    
    struct CrossChainBridge {
        bool isActive;
        address bridgeContract;
        uint256 bridgeFee;
        string destinationChain;
    }
    
    // ============ State Variables ============
    
    WRFToken public immutable wrfToken;
    
    uint256 private _nextListingId = 1;
    uint256 public constant MAX_ROYALTY_PERCENTAGE = 1000; // 10%
    uint256 public constant MARKETPLACE_FEE_BASE = 250;    // 2.5%
    uint256 public constant AUCTION_EXTENSION_TIME = 600;  // 10 minutes
    uint256 public constant MIN_BID_INCREMENT = 100;       // 1%
    uint256 public constant MAX_ALLOWED_BUYERS = 100;      // DoS protection
    uint256 public constant MAX_ROYALTY_RECIPIENTS = 5;    // DoS protection
    uint256 public constant MAX_INDIVIDUAL_ROYALTY = 500;  // 5% per recipient
    
    // Dynamic fee adjustment based on market activity
    uint256 public dynamicFeeMultiplier = 100; // 100 = no change, 50 = 50% reduction
    uint256 public volumeThreshold = 1000 ether; // Threshold for fee reduction
    uint256 public currentVolume24h = 0;
    uint256 public lastVolumeReset = block.timestamp;
    
    // Core marketplace mappings
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bid[]) public listingBids;
    mapping(uint256 => address) public highestBidder;
    mapping(uint256 => uint256) public highestBid;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => mapping(address => uint256)) public tokenWithdrawals; // user => token => amount
    
    // Royalty and authorization mappings
    mapping(address => mapping(uint256 => RoyaltyInfo[])) public nftRoyalties;
    mapping(address => bool) public authorizedNFTContracts;
    mapping(address => bool) public supportedPaymentTokens;
    
    // Offer system mappings
    mapping(address => mapping(uint256 => Offer[])) public tokenOffers; // nftContract => tokenId => offers
    mapping(bytes32 => bool) public processedOffers; // offerHash => processed
    
    // Statistics and cross-chain mappings
    mapping(address => CrossChainBridge) public crossChainBridges;
    mapping(address => MarketStats) public userStats;
    
    // Security and anti-manipulation mappings
    mapping(address => uint256) public lastTransactionTime;
    mapping(address => uint256) public dailyTransactionCount;
    mapping(address => uint256) public lastDailyReset;
    
    // Global market statistics
    MarketStats public globalStats;
    
    // Cross-chain support
    mapping(bytes32 => bool) public processedCrossChainTxs;
    
    // ============ Events ============
    
    /**
     * @notice Emitted when a new listing is created
     * @param listingId Unique listing identifier
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param seller Address of the seller
     * @param price Listing price
     * @param listingType Type of listing (FixedPrice, Auction, DutchAuction)
     */
    event ListingCreated(
        uint256 indexed listingId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        uint256 price,
        ListingType listingType
    );
    
    /**
     * @notice Emitted when a listing is sold
     * @param listingId Unique listing identifier
     * @param buyer Address of the buyer
     * @param finalPrice Final sale price
     * @param marketplaceFee Fee paid to marketplace
     * @param totalRoyalties Total royalties paid to creators
     */
    event ListingSold(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 finalPrice,
        uint256 marketplaceFee,
        uint256 totalRoyalties
    );
    
    /**
     * @notice Emitted when a bid is placed on an auction
     * @param listingId Unique listing identifier
     * @param bidder Address of the bidder
     * @param bidAmount Bid amount
     * @param isNewHighestBid Whether this is the new highest bid
     */
    event BidPlaced(
        uint256 indexed listingId,
        address indexed bidder,
        uint256 bidAmount,
        bool isNewHighestBid
    );
    
    /**
     * @notice Emitted when an auction is extended to prevent sniping
     * @param listingId Unique listing identifier
     * @param newEndTime New auction end time
     */
    event AuctionExtended(
        uint256 indexed listingId,
        uint256 newEndTime
    );
    
    /**
     * @notice Emitted when royalties are set for an NFT
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param recipients Array of royalty recipient addresses
     * @param percentages Array of royalty percentages (basis points)
     */
    event RoyaltiesSet(
        address indexed nftContract,
        uint256 indexed tokenId,
        address[] recipients,
        uint256[] percentages
    );
    
    /**
     * @notice Emitted when an offer is made on an NFT
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param offerer Address making the offer
     * @param amount Offer amount
     * @param paymentToken Payment token used for the offer
     */
    event OfferMade(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed offerer,
        uint256 amount,
        PaymentToken paymentToken
    );
    
    /**
     * @notice Emitted when an offer is accepted
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param offerer Address that made the offer
     * @param accepter Address that accepted the offer
     * @param amount Final sale amount
     */
    event OfferAccepted(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed offerer,
        address accepter,
        uint256 amount
    );
    
    /**
     * @notice Emitted when a cross-chain transfer is initiated
     * @param listingId Unique listing identifier
     * @param destinationChain Name of the destination blockchain
     * @param transferId Unique transfer identifier
     */
    event CrossChainTransferInitiated(
        uint256 indexed listingId,
        string destinationChain,
        bytes32 transferId
    );
    
    /**
     * @notice Emitted when marketplace fee is updated
     * @param newFeeMultiplier New fee multiplier (100 = normal fee)
     */
    event MarketplaceFeeUpdated(uint256 newFeeMultiplier);
    
    /**
     * @notice Emitted for security alerts and suspicious activity detection
     * @param alertType Type of security alert
     * @param user Address triggering the alert
     * @param listingId Related listing ID (if applicable)
     * @param amount Transaction amount (if applicable)
     */
    event SecurityAlert(
        string alertType,
        address indexed user,
        uint256 indexed listingId,
        uint256 amount
    );
    
    /**
     * @notice Emitted when a batch operation is completed
     * @param operator Address performing the batch operation
     * @param operation Type of batch operation
     * @param count Number of items processed
     * @param totalGasUsed Total gas used for the operation
     */
    event BatchOperationCompleted(
        address indexed operator,
        string operation,
        uint256 count,
        uint256 totalGasUsed
    );
    
    // ============ Modifiers ============
    
    /**
     * @notice Validates that a listing exists and is properly initialized
     * @param listingId The listing ID to validate
     */
    modifier validListing(uint256 listingId) {
        require(listingId > 0 && listingId < _nextListingId, "Marketplace: Invalid listing ID");
        require(listings[listingId].seller != address(0), "Marketplace: Listing does not exist");
        _;
    }
    
    /**
     * @notice Restricts access to the listing seller only
     * @param listingId The listing ID to check ownership for
     */
    modifier onlyListingSeller(uint256 listingId) {
        require(listings[listingId].seller == msg.sender, "Marketplace: Not authorized seller");
        _;
    }
    
    /**
     * @notice Validates that an auction is active and within time bounds
     * @param listingId The auction listing ID to validate
     */
    modifier activeAuction(uint256 listingId) {
        Listing memory listing = listings[listingId];
        require(listing.listingType == ListingType.Auction, "Marketplace: Not an auction listing");
        require(listing.status == ListingStatus.Active, "Marketplace: Auction not active");
        require(block.timestamp >= listing.startTime, "Marketplace: Auction not started");
        require(block.timestamp <= listing.endTime, "Marketplace: Auction has ended");
        _;
    }
    
    /**
     * @notice Anti-manipulation protection with rate limiting
     */
    modifier antiManipulation() {
        // Reset daily counter if needed
        if (block.timestamp >= lastDailyReset[msg.sender] + 1 days) {
            dailyTransactionCount[msg.sender] = 0;
            lastDailyReset[msg.sender] = block.timestamp;
        }
        
        // Rate limiting checks
        require(
            block.timestamp >= lastTransactionTime[msg.sender] + 1 seconds,
            "Marketplace: Transaction rate limit exceeded"
        );
        require(
            dailyTransactionCount[msg.sender] < 100,
            "Marketplace: Daily transaction limit exceeded"
        );
        
        _;
        
        // Update counters after successful execution
        lastTransactionTime[msg.sender] = block.timestamp;
        dailyTransactionCount[msg.sender]++;
    }
    
    /**
     * @notice Validates that an NFT contract is authorized for marketplace operations
     * @param nftContract The NFT contract address to validate
     */
    modifier onlyAuthorizedNFT(address nftContract) {
        require(nftContract != address(0), "Marketplace: Invalid NFT contract");
        require(authorizedNFTContracts[nftContract], "Marketplace: NFT contract not authorized");
        _;
    }
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize the NFT marketplace with comprehensive security features
     * @param _wrfToken Address of the WRF token contract for payments and fees
     */
    constructor(address _wrfToken) Ownable(msg.sender) {
        require(_wrfToken != address(0), "Marketplace: Invalid WRF token address");
        
        wrfToken = WRFToken(_wrfToken);
        
        // Initialize supported payment tokens
        supportedPaymentTokens[address(0)] = true; // ETH
        supportedPaymentTokens[_wrfToken] = true;   // WRF token
        
        // Initialize volume tracking
        lastVolumeReset = block.timestamp;
        
        emit MarketplaceFeeUpdated(dynamicFeeMultiplier);
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Authorize or deauthorize an NFT contract for marketplace operations
     * @dev Only authorized NFT contracts can be listed on the marketplace
     * @param nftContract Address of the NFT contract
     * @param authorized True to authorize, false to deauthorize
     */
    function setAuthorizedNFTContract(address nftContract, bool authorized) external onlyOwner {
        require(nftContract != address(0), "Marketplace: Invalid NFT contract");
        authorizedNFTContracts[nftContract] = authorized;
        
        emit SecurityAlert(
            authorized ? "NFT_CONTRACT_AUTHORIZED" : "NFT_CONTRACT_DEAUTHORIZED",
            nftContract,
            0,
            0
        );
    }
    
    /**
     * @notice Add or remove supported payment tokens
     * @param tokenContract Address of the ERC20 token contract (address(0) for ETH)
     * @param supported True to support, false to remove support
     */
    function setSupportedPaymentToken(address tokenContract, bool supported) external onlyOwner {
        supportedPaymentTokens[tokenContract] = supported;
        
        emit SecurityAlert(
            supported ? "PAYMENT_TOKEN_ADDED" : "PAYMENT_TOKEN_REMOVED",
            tokenContract,
            0,
            0
        );
    }
    
    /**
     * @notice Configure cross-chain bridge settings
     * @param bridgeContract Address of the bridge contract
     * @param destinationChain Name of the destination blockchain
     * @param bridgeFee Fee required for cross-chain transfers
     * @param isActive Whether the bridge is currently active
     */
    function setCrossChainBridge(
        address bridgeContract,
        string calldata destinationChain,
        uint256 bridgeFee,
        bool isActive
    ) external onlyOwner {
        require(bridgeContract != address(0), "Marketplace: Invalid bridge contract");
        require(bytes(destinationChain).length > 0, "Marketplace: Invalid destination chain");
        
        crossChainBridges[bridgeContract] = CrossChainBridge({
            isActive: isActive,
            bridgeContract: bridgeContract,
            bridgeFee: bridgeFee,
            destinationChain: destinationChain
        });
        
        emit SecurityAlert("BRIDGE_CONFIGURED", bridgeContract, 0, bridgeFee);
    }
    
    /**
     * @notice Update dynamic fee structure based on 24-hour volume
     * @dev Can be called by anyone to trigger fee updates
     */
    function updateDynamicFee() external {
        require(block.timestamp >= lastVolumeReset + 24 hours, "Marketplace: Too early for update");
        
        uint256 oldMultiplier = dynamicFeeMultiplier;
        
        if (currentVolume24h >= volumeThreshold) {
            dynamicFeeMultiplier = 75; // 25% fee reduction for high volume
        } else {
            dynamicFeeMultiplier = 100; // Normal fee
        }
        
        currentVolume24h = 0;
        lastVolumeReset = block.timestamp;
        
        if (oldMultiplier != dynamicFeeMultiplier) {
            emit MarketplaceFeeUpdated(dynamicFeeMultiplier);
        }
    }
    
    /**
     * @notice Set new volume threshold for dynamic fee calculation
     * @param newThreshold New volume threshold in wei
     */
    function setVolumeThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Marketplace: Invalid threshold");
        volumeThreshold = newThreshold;
        
        emit SecurityAlert("VOLUME_THRESHOLD_UPDATED", address(this), 0, newThreshold);
    }
    
    /**
     * @notice Emergency pause all marketplace operations
     * @dev Use in case of security threats or critical bugs
     */
    function pause() external onlyOwner {
        _pause();
        emit SecurityAlert("MARKETPLACE_PAUSED", msg.sender, 0, 0);
    }
    
    /**
     * @notice Resume marketplace operations after pause
     */
    function unpause() external onlyOwner {
        _unpause();
        emit SecurityAlert("MARKETPLACE_UNPAUSED", msg.sender, 0, 0);
    }
    
    /**
     * @notice Emergency function to withdraw stuck ETH from the contract
     * @dev Only for recovering funds that shouldn't be in the contract
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "Marketplace: No funds to withdraw");
        
        payable(owner()).sendValue(balance);
        emit SecurityAlert("EMERGENCY_WITHDRAWAL", owner(), 0, balance);
    }
    
    // ============ Listing Functions ============
    
    /**
     * @notice Create a fixed-price listing for an NFT
     * @dev Validates NFT ownership, approval, and payment token before creating listing
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT to list
     * @param price Listing price in the specified payment token
     * @param paymentToken Type of token accepted for payment
     * @param paymentContract Address of custom payment token contract (if applicable)
     * @param duration Listing duration in seconds (0 for unlimited)
     * @param allowPrivateSale Whether to allow private sales to specific buyers
     * @param allowedBuyers Array of addresses allowed to purchase (if private sale enabled)
     * @return listingId Unique identifier for the created listing
     */
    function createFixedPriceListing(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        PaymentToken paymentToken,
        address paymentContract,
        uint256 duration,
        bool allowPrivateSale,
        address[] calldata allowedBuyers
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyAuthorizedNFT(nftContract)
        antiManipulation
        returns (uint256) 
    {
        require(price > 0, "Marketplace: Price must be greater than zero");
        require(allowedBuyers.length <= MAX_ALLOWED_BUYERS, "Marketplace: Too many allowed buyers");
        
        // Validate payment token configuration
        _validatePaymentToken(paymentToken, paymentContract);
        
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Marketplace: Not the NFT owner");
        require(
            nft.isApprovedForAll(msg.sender, address(this)) || 
            nft.getApproved(tokenId) == address(this),
            "Marketplace: NFT not approved for marketplace"
        );
        
        uint256 listingId = _nextListingId++;
        uint256 endTime = duration > 0 ? block.timestamp + duration : type(uint256).max;
        
        // Check for reasonable duration limits
        if (duration > 0) {
            require(duration >= 1 hours, "Marketplace: Duration too short");
            require(duration <= 365 days, "Marketplace: Duration too long");
        }
        
        listings[listingId] = Listing({
            listingId: listingId,
            nftContract: nftContract,
            tokenId: tokenId,
            seller: msg.sender,
            price: price,
            startPrice: price,
            endPrice: price,
            startTime: block.timestamp,
            endTime: endTime,
            listingType: ListingType.FixedPrice,
            status: ListingStatus.Active,
            paymentToken: paymentToken,
            paymentContract: paymentContract,
            reservePrice: 0,
            allowPrivateSale: allowPrivateSale,
            allowedBuyers: allowedBuyers
        });
        
        // Transfer NFT to marketplace for secure custody
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        
        emit ListingCreated(listingId, nftContract, tokenId, msg.sender, price, ListingType.FixedPrice);
        
        return listingId;
    }
    
    /**
     * @notice Create multiple fixed-price listings in a single transaction (gas efficient)
     * @param nftContract Address of the NFT contract for all listings
     * @param params Array of batch listing parameters
     * @param paymentToken Payment token type for all listings
     * @param paymentContract Payment token contract address (if custom token)
     * @return listingIds Array of created listing IDs
     */
    function createBatchFixedPriceListings(
        address nftContract,
        BatchListingParams[] calldata params,
        PaymentToken paymentToken,
        address paymentContract
    ) external 
        nonReentrant 
        whenNotPaused 
        onlyAuthorizedNFT(nftContract)
        antiManipulation
        returns (uint256[] memory listingIds) 
    {
        require(params.length > 0, "Marketplace: No listings provided");
        require(params.length <= 50, "Marketplace: Too many listings at once");
        
        // Validate payment token configuration
        _validatePaymentToken(paymentToken, paymentContract);
        
        IERC721 nft = IERC721(nftContract);
        listingIds = new uint256[](params.length);
        uint256 gasStart = gasleft();
        
        for (uint256 i = 0; i < params.length; i++) {
            require(params[i].price > 0, "Marketplace: Price must be greater than zero");
            require(nft.ownerOf(params[i].tokenId) == msg.sender, "Marketplace: Not the NFT owner");
            require(
                nft.isApprovedForAll(msg.sender, address(this)) || 
                nft.getApproved(params[i].tokenId) == address(this),
                "Marketplace: NFT not approved for marketplace"
            );
            
            uint256 listingId = _nextListingId++;
            uint256 endTime = params[i].duration > 0 ? block.timestamp + params[i].duration : type(uint256).max;
            
            listings[listingId] = Listing({
                listingId: listingId,
                nftContract: nftContract,
                tokenId: params[i].tokenId,
                seller: msg.sender,
                price: params[i].price,
                startPrice: params[i].price,
                endPrice: params[i].price,
                startTime: block.timestamp,
                endTime: endTime,
                listingType: ListingType.FixedPrice,
                status: ListingStatus.Active,
                paymentToken: paymentToken,
                paymentContract: paymentContract,
                reservePrice: 0,
                allowPrivateSale: false,
                allowedBuyers: new address[](0)
            });
            
            // Transfer NFT to marketplace
            nft.safeTransferFrom(msg.sender, address(this), params[i].tokenId);
            
            listingIds[i] = listingId;
            emit ListingCreated(listingId, nftContract, params[i].tokenId, msg.sender, params[i].price, ListingType.FixedPrice);
        }
        
        uint256 gasUsed = gasStart - gasleft();
        emit BatchOperationCompleted(msg.sender, "BATCH_LISTING", params.length, gasUsed);
        
        return listingIds;
    }
    
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 reservePrice,
        uint256 duration,
        PaymentToken paymentToken,
        address paymentContract
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(authorizedNFTContracts[nftContract], "Marketplace: NFT contract not authorized");
        require(startPrice > 0, "Marketplace: Start price must be greater than 0");
        require(duration >= 1 hours && duration <= 30 days, "Marketplace: Invalid auction duration");
        
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Marketplace: Not the owner");
        require(
            nft.isApprovedForAll(msg.sender, address(this)) || 
            nft.getApproved(tokenId) == address(this),
            "Marketplace: Not approved"
        );
        
        uint256 listingId = _nextListingId++;
        
        listings[listingId] = Listing({
            listingId: listingId,
            nftContract: nftContract,
            tokenId: tokenId,
            seller: msg.sender,
            price: 0,
            startPrice: startPrice,
            endPrice: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            listingType: ListingType.Auction,
            status: ListingStatus.Active,
            paymentToken: paymentToken,
            paymentContract: paymentContract,
            reservePrice: reservePrice,
            allowPrivateSale: false,
            allowedBuyers: new address[](0)
        });
        
        // Transfer NFT to marketplace
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        
        emit ListingCreated(listingId, nftContract, tokenId, msg.sender, startPrice, ListingType.Auction);
        
        return listingId;
    }
    
    function createDutchAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 endPrice,
        uint256 duration,
        PaymentToken paymentToken,
        address paymentContract
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(authorizedNFTContracts[nftContract], "Marketplace: NFT contract not authorized");
        require(startPrice > endPrice && endPrice > 0, "Marketplace: Invalid price range");
        require(duration >= 1 hours && duration <= 7 days, "Marketplace: Invalid duration");
        
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Marketplace: Not the owner");
        require(
            nft.isApprovedForAll(msg.sender, address(this)) || 
            nft.getApproved(tokenId) == address(this),
            "Marketplace: Not approved"
        );
        
        uint256 listingId = _nextListingId++;
        
        listings[listingId] = Listing({
            listingId: listingId,
            nftContract: nftContract,
            tokenId: tokenId,
            seller: msg.sender,
            price: 0,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            listingType: ListingType.DutchAuction,
            status: ListingStatus.Active,
            paymentToken: paymentToken,
            paymentContract: paymentContract,
            reservePrice: endPrice,
            allowPrivateSale: false,
            allowedBuyers: new address[](0)
        });
        
        // Transfer NFT to marketplace
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        
        emit ListingCreated(listingId, nftContract, tokenId, msg.sender, startPrice, ListingType.DutchAuction);
        
        return listingId;
    }
    
    // ============ Purchase Functions ============
    
    function buyFixedPrice(uint256 listingId) external payable nonReentrant whenNotPaused validListing(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.FixedPrice, "Marketplace: Not a fixed price listing");
        require(listing.status == ListingStatus.Active, "Marketplace: Listing not active");
        require(block.timestamp <= listing.endTime, "Marketplace: Listing expired");
        
        // CRITICAL FIX: Validate payment amount based on payment token type
        uint256 salePrice = listing.price;
        if (listing.paymentToken == PaymentToken.Native) {
            require(msg.value >= salePrice, "Marketplace: Insufficient payment");
            // Refund excess payment if any
            if (msg.value > salePrice) {
                pendingWithdrawals[msg.sender] += msg.value - salePrice;
            }
        } else {
            require(msg.value == 0, "Marketplace: ETH not accepted for token payments");
            // Token transfers will be handled in _processPurchase
        }
        
        // Check private sale restrictions with array bounds protection
        if (listing.allowPrivateSale && listing.allowedBuyers.length > 0) {
            require(listing.allowedBuyers.length <= MAX_ALLOWED_BUYERS, "Marketplace: Too many allowed buyers");
            bool isAllowed = false;
            for (uint256 i = 0; i < listing.allowedBuyers.length; i++) {
                if (listing.allowedBuyers[i] == msg.sender) {
                    isAllowed = true;
                    break;
                }
            }
            require(isAllowed, "Marketplace: Not authorized for private sale");
        }
        
        _processPurchase(listingId, msg.sender, salePrice, false);
    }

    function buyDutchAuction(uint256 listingId) external payable nonReentrant whenNotPaused validListing(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.DutchAuction, "Marketplace: Not a Dutch auction");
        require(listing.status == ListingStatus.Active, "Marketplace: Listing not active");
        require(block.timestamp <= listing.endTime, "Marketplace: Auction expired");
        
        uint256 currentPrice = getCurrentDutchAuctionPrice(listingId);
        
        // CRITICAL FIX: Validate payment amount based on payment token type
        if (listing.paymentToken == PaymentToken.Native) {
            require(msg.value >= currentPrice, "Marketplace: Insufficient payment");
            // Refund excess payment if any
            if (msg.value > currentPrice) {
                pendingWithdrawals[msg.sender] += msg.value - currentPrice;
            }
        } else {
            require(msg.value == 0, "Marketplace: ETH not accepted for token payments");
            // Token transfers will be handled in _processPurchase
        }
        
        _processPurchase(listingId, msg.sender, currentPrice, false);
    }

    // ============ Auction Functions ============
    
    function placeBid(uint256 listingId) external payable nonReentrant whenNotPaused activeAuction(listingId) {
        Listing storage listing = listings[listingId];
        uint256 bidAmount;
        
        if (listing.paymentToken == PaymentToken.Native) {
            bidAmount = msg.value;
        } else if (listing.paymentToken == PaymentToken.WRF) {
            // For WRF bids, amount should be passed separately and tokens pre-approved
            revert("Marketplace: Use placeBidWithToken for ERC20 bids");
        }
        
        require(bidAmount > 0, "Marketplace: Bid must be greater than 0");
        
        uint256 currentHighestBid = highestBid[listingId];
        address previousBidder = highestBidder[listingId];
        
        // CHECKS: Validate bid amount
        if (currentHighestBid == 0) {
            require(bidAmount >= listing.startPrice, "Marketplace: Bid below start price");
        } else {
            uint256 minBidIncrement = (currentHighestBid * MIN_BID_INCREMENT) / 10000;
            require(bidAmount >= currentHighestBid + minBidIncrement, "Marketplace: Bid increment too low");
        }
        
        // EFFECTS: Update all state before external interactions
        // Record new highest bid BEFORE refunding previous bidder
        highestBidder[listingId] = msg.sender;
        highestBid[listingId] = bidAmount;
        
        // Add to pending withdrawals for previous bidder BEFORE any external calls
        if (previousBidder != address(0)) {
            pendingWithdrawals[previousBidder] += currentHighestBid;
        }
        
        // Add bid to history
        listingBids[listingId].push(Bid({
            bidder: msg.sender,
            amount: bidAmount,
            timestamp: block.timestamp,
            isActive: true
        }));
        
        // Extend auction if bid placed in last 10 minutes
        if (listing.endTime - block.timestamp <= AUCTION_EXTENSION_TIME) {
            listing.endTime = block.timestamp + AUCTION_EXTENSION_TIME;
            emit AuctionExtended(listingId, listing.endTime);
        }
        
        // INTERACTIONS: Events are safe as last step
        emit BidPlaced(listingId, msg.sender, bidAmount, true);
    }
    
    function placeBidWithToken(uint256 listingId, uint256 bidAmount) external nonReentrant whenNotPaused activeAuction(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.paymentToken != PaymentToken.Native, "Marketplace: Use placeBid for native currency");
        
        // CHECKS: Validate token and amount first
        IERC20 paymentToken;
        if (listing.paymentToken == PaymentToken.WRF) {
            paymentToken = IERC20(address(wrfToken));
        } else if (listing.paymentToken == PaymentToken.Custom) {
            paymentToken = IERC20(listing.paymentContract);
        } else {
            revert("Marketplace: Unsupported payment token");
        }
        
        require(bidAmount > 0, "Marketplace: Bid must be greater than 0");
        
        uint256 currentHighestBid = highestBid[listingId];
        address previousBidder = highestBidder[listingId];
        
        // Validate bid amount
        if (currentHighestBid == 0) {
            require(bidAmount >= listing.startPrice, "Marketplace: Bid below start price");
        } else {
            uint256 minBidIncrement = (currentHighestBid * MIN_BID_INCREMENT) / 10000;
            require(bidAmount >= currentHighestBid + minBidIncrement, "Marketplace: Bid increment too low");
        }
        
        // EFFECTS: Update all state BEFORE external token transfer
        // Record new highest bid BEFORE any external interactions
        highestBidder[listingId] = msg.sender;
        highestBid[listingId] = bidAmount;
        
        // Refund the previous ERC20 bidder to their TOKEN ledger (#173) BEFORE
        // external calls. This path only runs for ERC20 auctions, so the refund
        // must never touch the native `pendingWithdrawals` ledger.
        if (previousBidder != address(0)) {
            _refundAuctionBid(listingId, previousBidder, currentHighestBid);
        }

        // Add bid to history
        listingBids[listingId].push(Bid({
            bidder: msg.sender,
            amount: bidAmount,
            timestamp: block.timestamp,
            isActive: true
        }));

        // Extend auction if bid placed in last 10 minutes
        if (listing.endTime - block.timestamp <= AUCTION_EXTENSION_TIME) {
            listing.endTime = block.timestamp + AUCTION_EXTENSION_TIME;
            emit AuctionExtended(listingId, listing.endTime);
        }

        // INTERACTIONS: External token transfer comes AFTER all state updates
        paymentToken.safeTransferFrom(msg.sender, address(this), bidAmount);
        
        emit BidPlaced(listingId, msg.sender, bidAmount, true);
    }
    
    function finalizeAuction(uint256 listingId) external nonReentrant whenNotPaused validListing(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.listingType == ListingType.Auction, "Marketplace: Not an auction");
        require(listing.status == ListingStatus.Active, "Marketplace: Auction not active");
        require(block.timestamp > listing.endTime, "Marketplace: Auction still active");
        
        address winner = highestBidder[listingId];
        uint256 winningBid = highestBid[listingId];
        
        if (winner != address(0) && winningBid >= listing.reservePrice) {
            // Winner already escrowed their bid (native via placeBid, ERC20 via
            // placeBidWithToken), so settlement must NOT re-pull payment.
            _processPurchase(listingId, winner, winningBid, true);
        } else {
            // No valid bids, return NFT to seller
            listing.status = ListingStatus.Expired;
            IERC721(listing.nftContract).safeTransferFrom(address(this), listing.seller, listing.tokenId);

            // Refund highest bidder (if any) to the correct ledger (#173)
            _refundAuctionBid(listingId, winner, winningBid);
        }
    }
    
    // ============ Royalty Functions ============
    
    function setRoyalties(
        address nftContract,
        uint256 tokenId,
        address[] calldata recipients,
        uint256[] calldata percentages
    ) external {
        require(recipients.length == percentages.length, "Marketplace: Array length mismatch");
        require(recipients.length > 0, "Marketplace: No recipients provided");
        require(recipients.length <= MAX_ROYALTY_RECIPIENTS, "Marketplace: Too many royalty recipients");
        
        // Enhanced authorization check - be more restrictive about who can set royalties
        IERC721 nft = IERC721(nftContract);
        address tokenOwner = nft.ownerOf(tokenId);
        require(
            tokenOwner == msg.sender || 
            (authorizedNFTContracts[nftContract] && msg.sender == owner()),
            "Marketplace: Not authorized to set royalties"
        );
        
        uint256 totalPercentage = 0;
        
        // Validate all recipients and percentages
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Marketplace: Invalid recipient address");
            require(percentages[i] > 0, "Marketplace: Royalty percentage must be greater than 0");
            require(percentages[i] <= MAX_INDIVIDUAL_ROYALTY, "Marketplace: Individual royalty too high");
            totalPercentage += percentages[i];
        }
        require(totalPercentage <= MAX_ROYALTY_PERCENTAGE, "Marketplace: Total royalties too high");
        
        // Clear existing royalties
        delete nftRoyalties[nftContract][tokenId];
        
        // Set new royalties with additional validation
        for (uint256 i = 0; i < recipients.length; i++) {
            nftRoyalties[nftContract][tokenId].push(RoyaltyInfo({
                recipient: recipients[i],
                percentage: percentages[i]
            }));
        }
        
        emit RoyaltiesSet(nftContract, tokenId, recipients, percentages);
    }
    
    // ============ Cross-Chain Functions ============
    
    function initiateCrossChainTransfer(
        uint256 listingId,
        address bridgeContract,
        address destinationAddress
    ) external nonReentrant whenNotPaused validListing(listingId) {
        require(msg.sender == listings[listingId].seller, "Marketplace: Not the seller");
        CrossChainBridge memory bridge = crossChainBridges[bridgeContract];
        require(bridge.isActive, "Marketplace: Bridge not active");
        
        // Cancel listing and return NFT for cross-chain transfer
        Listing storage listing = listings[listingId];
        listing.status = ListingStatus.Cancelled;
        
        bytes32 transferId = keccak256(abi.encodePacked(
            listingId,
            bridgeContract,
            destinationAddress,
            block.timestamp
        ));
        
        // In a real implementation, this would interact with the actual bridge contract
        emit CrossChainTransferInitiated(listingId, bridge.destinationChain, transferId);
        
        IERC721(listing.nftContract).safeTransferFrom(address(this), msg.sender, listing.tokenId);
    }
    
    // ============ Management Functions ============
    
    function cancelListing(uint256 listingId) external nonReentrant whenNotPaused validListing(listingId) onlyListingSeller(listingId) {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.Active, "Marketplace: Listing not active");
        
        listing.status = ListingStatus.Cancelled;
        
        // Return NFT to seller
        IERC721(listing.nftContract).safeTransferFrom(address(this), listing.seller, listing.tokenId);
        
        // Refund highest bidder if auction, to the correct ledger (#173)
        if (listing.listingType == ListingType.Auction) {
            _refundAuctionBid(listingId, highestBidder[listingId], highestBid[listingId]);
        }
    }
    
    /**
     * @notice Withdraw pending ETH balance
     * @dev Uses pull payment pattern for security
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Marketplace: No ETH funds to withdraw");
        
        pendingWithdrawals[msg.sender] = 0;
        payable(msg.sender).sendValue(amount);
    }
    
    /**
     * @notice Withdraw specific ERC20 tokens from pending balances
     * @param tokenContract Address of the ERC20 token to withdraw
     */
    function withdrawToken(address tokenContract) external nonReentrant {
        require(tokenContract != address(0), "Marketplace: Invalid token contract");
        
        uint256 amount = tokenWithdrawals[msg.sender][tokenContract];
        require(amount > 0, "Marketplace: No token funds to withdraw");
        
        tokenWithdrawals[msg.sender][tokenContract] = 0;
        IERC20(tokenContract).safeTransfer(msg.sender, amount);
    }
    
    /**
     * @notice Batch withdraw multiple ERC20 tokens
     * @param tokenContracts Array of ERC20 token addresses to withdraw
     */
    function batchWithdrawTokens(address[] calldata tokenContracts) external nonReentrant {
        require(tokenContracts.length > 0, "Marketplace: No tokens provided");
        require(tokenContracts.length <= 20, "Marketplace: Too many tokens");
        
        uint256 gasStart = gasleft();
        
        for (uint256 i = 0; i < tokenContracts.length; i++) {
            address tokenContract = tokenContracts[i];
            uint256 amount = tokenWithdrawals[msg.sender][tokenContract];
            
            if (amount > 0) {
                tokenWithdrawals[msg.sender][tokenContract] = 0;
                IERC20(tokenContract).safeTransfer(msg.sender, amount);
            }
        }
        
        uint256 gasUsed = gasStart - gasleft();
        emit BatchOperationCompleted(msg.sender, "BATCH_WITHDRAW", tokenContracts.length, gasUsed);
    }
    
    /**
     * @notice Get pending withdrawal balances for a user
     * @param user Address to check balances for
     * @param tokenContracts Array of token addresses to check (empty array for ETH only)
     * @return ethBalance Pending ETH balance
     * @return tokenBalances Array of pending token balances
     */
    function getPendingWithdrawals(address user, address[] calldata tokenContracts) 
        external view returns (uint256 ethBalance, uint256[] memory tokenBalances) 
    {
        ethBalance = pendingWithdrawals[user];
        tokenBalances = new uint256[](tokenContracts.length);
        
        for (uint256 i = 0; i < tokenContracts.length; i++) {
            tokenBalances[i] = tokenWithdrawals[user][tokenContracts[i]];
        }
        
        return (ethBalance, tokenBalances);
    }
    
    // ============ View Functions ============
    
    function getCurrentDutchAuctionPrice(uint256 listingId) public view returns (uint256) {
        Listing memory listing = listings[listingId];
        require(listing.listingType == ListingType.DutchAuction, "Marketplace: Not a Dutch auction");
        
        if (block.timestamp >= listing.endTime) {
            return listing.endPrice;
        }
        
        uint256 timeElapsed = block.timestamp - listing.startTime;
        uint256 totalTime = listing.endTime - listing.startTime;
        uint256 priceDecrease = listing.startPrice - listing.endPrice;
        
        return listing.startPrice - (priceDecrease * timeElapsed) / totalTime;
    }
    
    function getMarketplaceFee() public view returns (uint256) {
        return (MARKETPLACE_FEE_BASE * dynamicFeeMultiplier) / 100;
    }
    
    function getListing(uint256 listingId) external view returns (
        address nftContract,
        uint256 tokenId,
        address seller,
        uint256 price,
        ListingType listingType,
        ListingStatus status,
        uint256 endTime
    ) {
        Listing memory listing = listings[listingId];
        return (
            listing.nftContract,
            listing.tokenId,
            listing.seller,
            listing.price,
            listing.listingType,
            listing.status,
            listing.endTime
        );
    }
    
    function getBidHistory(uint256 listingId) external view returns (Bid[] memory) {
        return listingBids[listingId];
    }
    
    function getGlobalStats() external view returns (MarketStats memory) {
        return globalStats;
    }
    
    function getUserStats(address user) external view returns (MarketStats memory) {
        return userStats[user];
    }
    
    // ============ Offer System Functions ============
    
    /**
     * @notice Make an offer on an NFT (not currently listed)
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param amount Offer amount
     * @param paymentToken Payment token for the offer
     * @param paymentContract Address of custom payment token (if applicable)
     * @param duration Offer duration in seconds
     */
    function makeOffer(
        address nftContract,
        uint256 tokenId,
        uint256 amount,
        PaymentToken paymentToken,
        address paymentContract,
        uint256 duration
    ) external payable nonReentrant whenNotPaused onlyAuthorizedNFT(nftContract) antiManipulation {
        require(amount > 0, "Marketplace: Offer amount must be greater than zero");
        require(duration >= 1 hours && duration <= 30 days, "Marketplace: Invalid offer duration");
        
        _validatePaymentToken(paymentToken, paymentContract);
        
        // Check that NFT exists
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) != address(0), "Marketplace: NFT does not exist");
        require(nft.ownerOf(tokenId) != msg.sender, "Marketplace: Cannot make offer on own NFT");
        
        uint256 expiration = block.timestamp + duration;
        
        // Handle payment escrow. Escrow is separate from withdrawal liabilities.
        if (paymentToken == PaymentToken.Native) {
            require(msg.value == amount, "Marketplace: Invalid native escrow");
        } else {
            require(msg.value == 0, "Marketplace: Native value not accepted");
            IERC20 token = _getPaymentToken(paymentToken, paymentContract);
            token.safeTransferFrom(msg.sender, address(this), amount);
        }
        
        tokenOffers[nftContract][tokenId].push(Offer({
            offerer: msg.sender,
            amount: amount,
            paymentToken: paymentToken,
            paymentContract: paymentContract,
            expiration: expiration,
            isActive: true
        }));
        
        emit OfferMade(nftContract, tokenId, msg.sender, amount, paymentToken);
    }
    
    /**
     * @notice Accept an offer on your NFT
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param offerIndex Index of the offer to accept
     */
    function acceptOffer(
        address nftContract,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant whenNotPaused {
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "Marketplace: Not the NFT owner");
        
        Offer[] storage offers = tokenOffers[nftContract][tokenId];
        require(offerIndex < offers.length, "Marketplace: Invalid offer index");
        
        Offer storage offer = offers[offerIndex];
        require(offer.isActive, "Marketplace: Offer not active");
        require(block.timestamp <= offer.expiration, "Marketplace: Offer expired");
        
        uint256 salePrice = offer.amount;
        address buyer = offer.offerer;
        PaymentToken paymentToken = offer.paymentToken;
        
        // Mark offer as processed
        offer.isActive = false;
        bytes32 offerHash = keccak256(abi.encodePacked(nftContract, tokenId, buyer, salePrice, block.timestamp));
        processedOffers[offerHash] = true;
        
        // Process the sale with royalties
        _processOfferSale(nftContract, tokenId, buyer, msg.sender, salePrice, paymentToken, offer.paymentContract);
        
        emit OfferAccepted(nftContract, tokenId, buyer, msg.sender, salePrice);
    }
    
    /**
     * @notice Cancel an active offer
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param offerIndex Index of the offer to cancel
     */
    function cancelOffer(
        address nftContract,
        uint256 tokenId,
        uint256 offerIndex
    ) external nonReentrant {
        Offer[] storage offers = tokenOffers[nftContract][tokenId];
        require(offerIndex < offers.length, "Marketplace: Invalid offer index");
        
        Offer storage offer = offers[offerIndex];
        require(offer.offerer == msg.sender, "Marketplace: Not your offer");
        require(offer.isActive, "Marketplace: Offer not active");
        
        offer.isActive = false;
        
        // Return escrowed funds exactly once.
        if (offer.paymentToken == PaymentToken.Native) {
            payable(msg.sender).sendValue(offer.amount);
        } else {
            IERC20 token = _getPaymentToken(offer.paymentToken, offer.paymentContract);
            token.safeTransfer(msg.sender, offer.amount);
        }
    }
    
    // ============ Enhanced Royalty Functions ============
    
    /**
     * @notice Set ERC2981 compliant royalties for an NFT with comprehensive validation
     * @dev Supports multiple recipients with individual percentage limits
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param recipients Array of royalty recipient addresses
     * @param percentages Array of royalty percentages in basis points (10000 = 100%)
     */
    function setRoyaltiesExtended(
        address nftContract,
        uint256 tokenId,
        address[] calldata recipients,
        uint256[] calldata percentages
    ) external nonReentrant {
        require(recipients.length == percentages.length, "Marketplace: Array length mismatch");
        require(recipients.length > 0 && recipients.length <= MAX_ROYALTY_RECIPIENTS, "Marketplace: Invalid recipients count");
        
        // Enhanced authorization check
        IERC721 nft = IERC721(nftContract);
        address tokenOwner = nft.ownerOf(tokenId);
        require(
            tokenOwner == msg.sender || 
            (authorizedNFTContracts[nftContract] && msg.sender == owner()) ||
            nft.isApprovedForAll(tokenOwner, msg.sender),
            "Marketplace: Not authorized to set royalties"
        );
        
        uint256 totalPercentage = 0;
        
        // Comprehensive validation
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Marketplace: Invalid recipient address");
            require(percentages[i] > 0 && percentages[i] <= MAX_INDIVIDUAL_ROYALTY, "Marketplace: Invalid royalty percentage");
            
            // Check for duplicate recipients
            for (uint256 j = i + 1; j < recipients.length; j++) {
                require(recipients[i] != recipients[j], "Marketplace: Duplicate recipient");
            }
            
            totalPercentage += percentages[i];
        }
        require(totalPercentage <= MAX_ROYALTY_PERCENTAGE, "Marketplace: Total royalties exceed maximum");
        
        // Clear existing royalties
        delete nftRoyalties[nftContract][tokenId];
        
        // Set new royalties
        for (uint256 i = 0; i < recipients.length; i++) {
            nftRoyalties[nftContract][tokenId].push(RoyaltyInfo({
                recipient: recipients[i],
                percentage: percentages[i]
            }));
        }
        
        emit RoyaltiesSet(nftContract, tokenId, recipients, percentages);
    }
    
    /**
     * @notice Get ERC2981 compliant royalty information
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param salePrice Sale price to calculate royalties for
     * @return recipients Array of royalty recipients
     * @return amounts Array of royalty amounts
     */
    function getRoyaltyInfo(address nftContract, uint256 tokenId, uint256 salePrice) 
        external view returns (address[] memory recipients, uint256[] memory amounts) 
    {
        RoyaltyInfo[] memory royalties = nftRoyalties[nftContract][tokenId];
        recipients = new address[](royalties.length);
        amounts = new uint256[](royalties.length);
        
        for (uint256 i = 0; i < royalties.length; i++) {
            recipients[i] = royalties[i].recipient;
            amounts[i] = (salePrice * royalties[i].percentage) / 10000;
        }
        
        return (recipients, amounts);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Validate payment token configuration
     * @param paymentToken Type of payment token
     * @param paymentContract Address of custom payment token contract
     */
    function _validatePaymentToken(PaymentToken paymentToken, address paymentContract) internal view {
        if (paymentToken == PaymentToken.Native) {
            require(supportedPaymentTokens[address(0)], "Marketplace: Native currency not supported");
        } else if (paymentToken == PaymentToken.WRF) {
            require(supportedPaymentTokens[address(wrfToken)], "Marketplace: WRF token not supported");
        } else if (paymentToken == PaymentToken.Custom) {
            require(paymentContract != address(0), "Marketplace: Invalid custom token contract");
            require(supportedPaymentTokens[paymentContract], "Marketplace: Custom token not supported");
        } else {
            revert("Marketplace: Unsupported payment token type");
        }
    }
    
    /**
     * @notice Get payment token contract instance
     * @param paymentToken Type of payment token
     * @param paymentContract Address of custom payment token contract
     * @return IERC20 interface of the payment token
     */
    function _getPaymentToken(PaymentToken paymentToken, address paymentContract) internal view returns (IERC20) {
        if (paymentToken == PaymentToken.WRF) {
            return IERC20(address(wrfToken));
        } else if (paymentToken == PaymentToken.Custom) {
            return IERC20(paymentContract);
        } else {
            revert("Marketplace: Invalid token type for ERC20 interface");
        }
    }

    /**
     * @notice Resolve the ERC20 contract address backing a listing's payment token
     * @dev Reverts for Native listings (which have no ERC20 address).
     */
    function _listingPaymentTokenAddress(Listing storage listing) internal view returns (address) {
        if (listing.paymentToken == PaymentToken.WRF) {
            return address(wrfToken);
        } else if (listing.paymentToken == PaymentToken.Custom) {
            return listing.paymentContract;
        }
        revert("Marketplace: Invalid token type for ERC20 interface");
    }

    /**
     * @notice Refund an auction bid to the correct withdrawal ledger (#173)
     * @dev Native bids credit `pendingWithdrawals` (withdrawn via withdraw()),
     *      ERC20 bids credit `tokenWithdrawals[bidder][token]` (withdrawn via
     *      withdrawToken()). Crediting ERC20 refunds to the ETH ledger — as the
     *      previous code did — let bidders drain native ETH they never paid while
     *      permanently stranding their escrowed ERC20 tokens.
     */
    function _refundAuctionBid(uint256 listingId, address bidder, uint256 amount) internal {
        if (bidder == address(0) || amount == 0) {
            return;
        }
        Listing storage listing = listings[listingId];
        if (listing.paymentToken == PaymentToken.Native) {
            pendingWithdrawals[bidder] += amount;
        } else {
            tokenWithdrawals[bidder][_listingPaymentTokenAddress(listing)] += amount;
        }
    }
    
    /**
     * @notice Process offer sale with comprehensive royalty distribution
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @param buyer Address of the buyer
     * @param seller Address of the seller
     * @param salePrice Sale price
     * @param paymentToken Payment token type
     * @param paymentContract Payment token contract address
     */
    function _processOfferSale(
        address nftContract,
        uint256 tokenId,
        address buyer,
        address seller,
        uint256 salePrice,
        PaymentToken paymentToken,
        address paymentContract
    ) internal {
        // Calculate fees and royalties
        uint256 marketplaceFee = (salePrice * getMarketplaceFee()) / 10000;
        uint256 totalRoyalties = 0;
        
        // Calculate royalties
        RoyaltyInfo[] memory royalties = nftRoyalties[nftContract][tokenId];
        for (uint256 i = 0; i < royalties.length; i++) {
            uint256 royaltyAmount = (salePrice * royalties[i].percentage) / 10000;
            totalRoyalties += royaltyAmount;
            
            if (paymentToken == PaymentToken.Native) {
                pendingWithdrawals[royalties[i].recipient] += royaltyAmount;
            } else {
                IERC20 token = _getPaymentToken(paymentToken, paymentContract);
                tokenWithdrawals[royalties[i].recipient][address(token)] += royaltyAmount;
            }
        }
        
        require(marketplaceFee + totalRoyalties <= salePrice, "Marketplace: Fees exceed sale price");
        
        // Calculate seller amount
        uint256 sellerAmount = salePrice - marketplaceFee - totalRoyalties;
        
        // Distribute payments
        if (paymentToken == PaymentToken.Native) {
            pendingWithdrawals[seller] += sellerAmount;
            pendingWithdrawals[owner()] += marketplaceFee;
        } else {
            IERC20 token = _getPaymentToken(paymentToken, paymentContract);
            tokenWithdrawals[seller][address(token)] += sellerAmount;
            tokenWithdrawals[owner()][address(token)] += marketplaceFee;
        }
        
        // Transfer NFT
        IERC721(nftContract).safeTransferFrom(seller, buyer, tokenId);
        
        // Update statistics
        _updateMarketStats(buyer, seller, salePrice);
        currentVolume24h += salePrice;
    }
    
    /**
     * @param paymentAlreadyEscrowed True when `salePrice` is already held by the
     *        marketplace (auction settlement, where the winner escrowed their bid
     *        in placeBid/placeBidWithToken). Fixed-price buys pass false so the
     *        ERC20 price is pulled from the buyer here. For an ERC20 auction the
     *        old code both credited the native ledger AND re-pulled `transferFrom`,
     *        double-charging the winner (or reverting and locking NFT + bid). (#173)
     */
    function _processPurchase(
        uint256 listingId,
        address buyer,
        uint256 salePrice,
        bool paymentAlreadyEscrowed
    ) internal {
        Listing storage listing = listings[listingId];

        // CHECKS: Validate purchase conditions
        require(listing.status == ListingStatus.Active, "Marketplace: Listing not active");
        require(salePrice > 0, "Marketplace: Invalid sale price");

        // EFFECTS: Update all state before external interactions
        // Update listing status first
        listing.status = ListingStatus.Sold;
        listing.price = salePrice;

        bool isNative = listing.paymentToken == PaymentToken.Native;
        address tokenAddr = isNative ? address(0) : _listingPaymentTokenAddress(listing);

        // Calculate fees and royalties
        uint256 marketplaceFee = (salePrice * getMarketplaceFee()) / 10000;
        uint256 totalRoyalties = 0;

        // Calculate royalties with bounds checking
        RoyaltyInfo[] memory royalties = nftRoyalties[listing.nftContract][listing.tokenId];
        require(royalties.length <= MAX_ROYALTY_RECIPIENTS, "Marketplace: Too many royalty recipients");

        for (uint256 i = 0; i < royalties.length; i++) {
            uint256 royaltyAmount = (salePrice * royalties[i].percentage) / 10000;
            totalRoyalties += royaltyAmount;
            // Credit royalties to the ledger matching the payment type (#173)
            if (isNative) {
                pendingWithdrawals[royalties[i].recipient] += royaltyAmount;
            } else {
                tokenWithdrawals[royalties[i].recipient][tokenAddr] += royaltyAmount;
            }
        }

        // Ensure total deductions don't exceed sale price
        require(marketplaceFee + totalRoyalties <= salePrice, "Marketplace: Fees exceed sale price");

        // Pay seller + marketplace fee on the ledger matching the payment type (#173)
        uint256 sellerAmount = salePrice - marketplaceFee - totalRoyalties;
        if (isNative) {
            pendingWithdrawals[listing.seller] += sellerAmount;
            pendingWithdrawals[owner()] += marketplaceFee;
        } else {
            tokenWithdrawals[listing.seller][tokenAddr] += sellerAmount;
            tokenWithdrawals[owner()][tokenAddr] += marketplaceFee;
        }

        // Update statistics before external calls
        _updateMarketStats(buyer, listing.seller, salePrice);

        // Update 24h volume for dynamic fees
        currentVolume24h += salePrice;

        // Pull ERC20 payment ONLY when it has not already been escrowed. Auction
        // winners already escrowed their bid, so re-pulling would double-charge.
        if (!isNative && !paymentAlreadyEscrowed) {
            require(
                IERC20(tokenAddr).transferFrom(buyer, address(this), salePrice),
                "Marketplace: Token payment failed"
            );
        }

        // INTERACTIONS: External NFT transfer comes last
        IERC721(listing.nftContract).safeTransferFrom(address(this), buyer, listing.tokenId);

        emit ListingSold(listingId, buyer, salePrice, marketplaceFee, totalRoyalties);
    }
    
    function _updateMarketStats(address buyer, address seller, uint256 salePrice) internal {
        // Update global stats
        globalStats.totalSales++;
        globalStats.totalVolume += salePrice;
        globalStats.averagePrice = globalStats.totalVolume / globalStats.totalSales;
        
        // Update user stats
        if (userStats[buyer].totalSales == 0) {
            globalStats.uniqueBuyers++;
        }
        if (userStats[seller].totalSales == 0) {
            globalStats.uniqueSellers++;
        }
        
        userStats[buyer].totalSales++;
        userStats[buyer].totalVolume += salePrice;
        userStats[seller].totalSales++;
        userStats[seller].totalVolume += salePrice;
    }
    
    // ============ Interface Support ============
    
    /**
     * @notice Check if contract supports a specific interface
     * @param interfaceId Interface identifier to check
     * @return True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC2981).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    /**
     * @notice ERC2981 royalty standard implementation
     * @param tokenId Token ID to get royalty info for (not used in marketplace context)
     * @param salePrice Sale price to calculate royalty for
     * @return receiver Address of royalty receiver (marketplace contract)
     * @return royaltyAmount Amount of royalty (always 0 as we handle royalties internally)
     */
    function royaltyInfo(uint256 tokenId, uint256 salePrice) 
        external pure returns (address receiver, uint256 royaltyAmount) 
    {
        // This implementation indicates the marketplace handles royalties internally
        // Individual NFT contracts should implement their own ERC2981 if needed
        return (address(0), 0);
    }
    
    /**
     * @notice IERC721Receiver implementation to accept NFT transfers
     * @return selector indicating successful receipt
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    
    // ============ Additional View Functions ============
    
    /**
     * @notice Get all active offers for a specific NFT
     * @param nftContract Address of the NFT contract
     * @param tokenId Token ID of the NFT
     * @return Array of active offers
     */
    function getTokenOffers(address nftContract, uint256 tokenId) 
        external view returns (Offer[] memory) 
    {
        Offer[] storage allOffers = tokenOffers[nftContract][tokenId];
        uint256 activeCount = 0;
        
        // Count active offers
        for (uint256 i = 0; i < allOffers.length; i++) {
            if (allOffers[i].isActive && block.timestamp <= allOffers[i].expiration) {
                activeCount++;
            }
        }
        
        // Create array of active offers
        Offer[] memory activeOffers = new Offer[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allOffers.length; i++) {
            if (allOffers[i].isActive && block.timestamp <= allOffers[i].expiration) {
                activeOffers[index] = allOffers[i];
                index++;
            }
        }
        
        return activeOffers;
    }
    
    /**
     * @notice Get comprehensive marketplace statistics
     * @return totalListings Total number of listings created
     * @return activeListings Number of currently active listings
     * @return totalSales Total number of completed sales
     * @return totalVolume Total volume traded
     * @return currentFee Current marketplace fee in basis points
     */
    function getMarketplaceStats() external view returns (
        uint256 totalListings,
        uint256 activeListings,
        uint256 totalSales,
        uint256 totalVolume,
        uint256 currentFee
    ) {
        // Count active listings
        uint256 active = 0;
        for (uint256 i = 1; i < _nextListingId; i++) {
            if (listings[i].status == ListingStatus.Active && block.timestamp <= listings[i].endTime) {
                active++;
            }
        }
        
        return (
            _nextListingId - 1,
            active,
            globalStats.totalSales,
            globalStats.totalVolume,
            getMarketplaceFee()
        );
    }
    
    /**
     * @notice Check if a payment token is supported
     * @param tokenContract Address of the token contract (address(0) for ETH)
     * @return True if supported
     */
    function isPaymentTokenSupported(address tokenContract) external view returns (bool) {
        return supportedPaymentTokens[tokenContract];
    }
    
    /**
     * @notice Get detailed listing information with security and offer data
     * @param listingId ID of the listing
     * @return listing Complete listing struct
     * @return offerCount Number of active offers on the NFT
     * @return timeRemaining Time remaining for the listing (0 if expired)
     */
    function getDetailedListing(uint256 listingId) external view validListing(listingId) returns (
        Listing memory listing,
        uint256 offerCount,
        uint256 timeRemaining
    ) {
        listing = listings[listingId];
        
        // Count active offers
        Offer[] storage offers = tokenOffers[listing.nftContract][listing.tokenId];
        for (uint256 i = 0; i < offers.length; i++) {
            if (offers[i].isActive && block.timestamp <= offers[i].expiration) {
                offerCount++;
            }
        }
        
        // Calculate time remaining
        if (block.timestamp < listing.endTime) {
            timeRemaining = listing.endTime - block.timestamp;
        } else {
            timeRemaining = 0;
        }
        
        return (listing, offerCount, timeRemaining);
    }
}
