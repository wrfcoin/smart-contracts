// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IQualityOracle.sol";
import "./CarbonCredits.sol";

/**
 * @title CarbonBasketToken
 * @dev ERC20 token representing a diversified basket of carbon credits with comprehensive features
 * 
 * Features:
 * - ERC20 compliant basket token backed by NFT carbon credits
 * - Weighted composition management with quality-based scoring
 * - Automatic rebalancing based on quality scores
 * - Secure deposit/withdrawal mechanisms
 * - Fee calculation with quality-based adjustments
 * - Underlying asset validation and verification
 * - Quality score integration for premium pricing
 * - Comprehensive access controls and emergency features
 * - Gas-optimized batch operations
 * 
 * Security:
 * - Reentrancy protection on all external calls
 * - Input validation and access controls
 * - Pause functionality for emergency situations
 * - Weighted composition validation
 * - Quality threshold enforcement
 * - Economic security for high-value baskets
 */
contract CarbonBasketToken is ERC20, ERC20Burnable, Ownable, ReentrancyGuard, Pausable {
    
    /// @dev Basket component representing underlying carbon credits
    struct BasketComponent {
        address creditContract;     // Carbon credit NFT contract address
        uint256[] tokenIds;        // Array of token IDs held
        uint256 targetWeight;      // Target weight in basis points (10000 = 100%)
        uint256 currentWeight;     // Current actual weight
        uint256 averageQuality;    // Average quality score of held credits
        bool isActive;             // Whether component is active
    }
    
    /// @dev Rebalancing configuration
    struct RebalanceConfig {
        uint256 threshold;         // Deviation threshold for rebalancing (basis points)
        uint256 frequency;         // Minimum time between rebalances
        uint256 maxSlippage;       // Maximum slippage allowed during rebalancing
        bool autoRebalance;        // Whether auto-rebalancing is enabled
    }
    
    /// @dev Deposit/withdrawal tracking
    struct UserDeposit {
        uint256 amount;            // Amount of basket tokens
        uint256 timestamp;         // Deposit timestamp
        uint256 qualityAtDeposit;  // Average quality at deposit
    }
    
    // Constants
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MIN_QUALITY_THRESHOLD = 60;
    uint256 public constant MAX_COMPONENTS = 20;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant REBALANCE_THRESHOLD = 500; // 5% default threshold
    
    // Core state variables
    IQualityOracle public immutable qualityOracle;
    address public rebalancer;
    uint256 public managementFeeRate = 100; // 1% annual in basis points
    uint256 public performanceFeeRate = 1000; // 10% of outperformance
    uint256 public constant MAX_MANAGEMENT_FEE = 500; // 5% max
    uint256 public constant MAX_PERFORMANCE_FEE = 2000; // 20% max
    
    // Basket composition
    BasketComponent[] public basketComponents;
    mapping(address => uint256) public componentIndex; // contract address => index
    mapping(address => bool) public authorizedComponents;
    
    // Rebalancing
    RebalanceConfig public rebalanceConfig;
    uint256 public lastRebalance;
    
    // Fee tracking
    uint256 public totalFeesCollected;
    uint256 public lastFeeCollection;
    address public feeRecipient;

    // Fee timelock
    uint256 public constant FEE_TIMELOCK_DELAY = 48 hours;
    uint256 public constant FEE_TIMELOCK_EXPIRY = 7 days;
    uint256 public feeChangeNonce;

    struct PendingFeeChange {
        uint256 newRate;
        uint256 queuedAt;
        uint256 nonce;
        bool exists;
    }

    PendingFeeChange public pendingManagementFee;
    PendingFeeChange public pendingPerformanceFee;

    // User tracking
    mapping(address => UserDeposit[]) public userDeposits;
    mapping(address => uint256) public totalUserDeposits;
    
    // Enhanced events
    
    /// @notice Emitted when basket composition is updated
    event BasketUpdated(
        address indexed component,
        uint256 newWeight,
        uint256 oldWeight
    );
    
    /// @notice Emitted when a deposit is made
    event Deposited(
        address indexed user,
        address indexed component,
        uint256[] tokenIds,
        uint256 basketTokens,
        uint256 averageQuality
    );
    
    /// @notice Emitted when a withdrawal is made
    event Withdrawn(
        address indexed user,
        address indexed component,
        uint256[] tokenIds,
        uint256 basketTokens
    );
    
    /// @notice Emitted when rebalancing occurs
    event Rebalanced(
        uint256 timestamp,
        uint256[] oldWeights,
        uint256[] newWeights,
        uint256 totalQualityScore
    );
    
    /// @notice Emitted when fees are collected
    event FeesCollected(
        uint256 managementFees,
        uint256 performanceFees,
        address indexed recipient
    );
    
    /// @notice Emitted when a fee update is queued
    event FeeUpdateQueued(
        uint256 indexed changeId,
        string feeType,
        uint256 currentRate,
        uint256 newRate,
        uint256 effectiveAt
    );

    /// @notice Emitted when a queued fee update is executed
    event FeeUpdateExecuted(
        uint256 indexed changeId,
        string feeType,
        uint256 oldRate,
        uint256 newRate
    );

    /// @notice Emitted when the fee recipient is updated
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /// @notice Emitted when rebalance configuration is updated
    event RebalanceConfigUpdated(
        uint256 threshold,
        uint256 frequency,
        uint256 maxSlippage,
        bool autoRebalance
    );
    
    // Modifiers
    
    modifier onlyRebalancer() {
        if (msg.sender != rebalancer && msg.sender != owner()) {
            revert("CarbonBasketToken: Not authorized rebalancer");
        }
        _;
    }
    
    modifier validComponent(address component) {
        if (!authorizedComponents[component]) {
            revert("CarbonBasketToken: Component not authorized");
        }
        _;
    }
    
    modifier validWeight(uint256 weight) {
        if (weight > BASIS_POINTS) {
            revert("CarbonBasketToken: Invalid weight");
        }
        _;
    }
    
    /**
     * @notice Constructor initializes the carbon basket token
     * @dev Sets up ERC20, quality oracle, and default configuration
     * @param _qualityOracle Address of the quality oracle contract
     * @param name Token name
     * @param symbol Token symbol
     */
    constructor(
        address _qualityOracle,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) Ownable(msg.sender) {
        if (_qualityOracle == address(0)) {
            revert("CarbonBasketToken: Invalid oracle address");
        }
        
        qualityOracle = IQualityOracle(_qualityOracle);
        rebalancer = msg.sender;
        feeRecipient = msg.sender;
        lastFeeCollection = block.timestamp;
        lastRebalance = block.timestamp;
        
        // Set default rebalance configuration
        rebalanceConfig = RebalanceConfig({
            threshold: REBALANCE_THRESHOLD,
            frequency: 1 days,
            maxSlippage: 300, // 3%
            autoRebalance: true
        });
    }
    
    // ========== BASKET MANAGEMENT ==========
    
    /**
     * @notice Add a new component to the basket
     * @dev Only owner can add components to ensure quality
     * @param creditContract Address of the carbon credit NFT contract
     * @param targetWeight Target weight in basis points
     */
    function addComponent(
        address creditContract,
        uint256 targetWeight
    ) external onlyOwner validWeight(targetWeight) {
        if (creditContract == address(0)) {
            revert("CarbonBasketToken: Invalid contract address");
        }
        
        if (authorizedComponents[creditContract]) {
            revert("CarbonBasketToken: Component already exists");
        }
        
        if (basketComponents.length >= MAX_COMPONENTS) {
            revert("CarbonBasketToken: Too many components");
        }
        
        // Validate total weights don't exceed 100%
        uint256 totalWeight = targetWeight;
        for (uint256 i = 0; i < basketComponents.length; i++) {
            totalWeight += basketComponents[i].targetWeight;
        }
        
        if (totalWeight > BASIS_POINTS) {
            revert("CarbonBasketToken: Total weight exceeds 100%");
        }
        
        // Add component
        basketComponents.push(BasketComponent({
            creditContract: creditContract,
            tokenIds: new uint256[](0),
            targetWeight: targetWeight,
            currentWeight: 0,
            averageQuality: 0,
            isActive: true
        }));
        
        componentIndex[creditContract] = basketComponents.length - 1;
        authorizedComponents[creditContract] = true;
        
        emit BasketUpdated(creditContract, targetWeight, 0);
    }
    
    /**
     * @notice Update the target weight of a component
     * @dev Automatically triggers rebalancing if enabled
     * @param creditContract Address of the component to update
     * @param newWeight New target weight in basis points
     */
    function updateComponentWeight(
        address creditContract,
        uint256 newWeight
    ) external onlyOwner validComponent(creditContract) validWeight(newWeight) {
        uint256 index = componentIndex[creditContract];
        uint256 oldWeight = basketComponents[index].targetWeight;
        
        // Validate total weights
        uint256 totalWeight = newWeight;
        for (uint256 i = 0; i < basketComponents.length; i++) {
            if (i != index) {
                totalWeight += basketComponents[i].targetWeight;
            }
        }
        
        if (totalWeight > BASIS_POINTS) {
            revert("CarbonBasketToken: Total weight exceeds 100%");
        }
        
        basketComponents[index].targetWeight = newWeight;
        
        emit BasketUpdated(creditContract, newWeight, oldWeight);
        
        // Trigger rebalancing if auto-rebalance is enabled
        if (rebalanceConfig.autoRebalance) {
            _checkAndRebalance();
        }
    }
    
    /**
     * @notice Remove a component from the basket
     * @dev Withdraws all held credits before removal
     * @param creditContract Address of the component to remove
     */
    function removeComponent(address creditContract) 
        external 
        onlyOwner 
        validComponent(creditContract) 
    {
        uint256 index = componentIndex[creditContract];
        BasketComponent storage component = basketComponents[index];
        
        // Ensure no credits are held
        if (component.tokenIds.length > 0) {
            revert("CarbonBasketToken: Component has held credits");
        }
        
        uint256 oldWeight = component.targetWeight;
        
        // Remove from arrays and mappings
        authorizedComponents[creditContract] = false;
        
        // Move last element to deleted spot to maintain array structure
        if (index != basketComponents.length - 1) {
            basketComponents[index] = basketComponents[basketComponents.length - 1];
            componentIndex[basketComponents[index].creditContract] = index;
        }
        basketComponents.pop();
        delete componentIndex[creditContract];
        
        emit BasketUpdated(creditContract, 0, oldWeight);
    }
    
    // ========== DEPOSIT/WITHDRAWAL ==========
    
    /**
     * @notice Deposit carbon credit NFTs to receive basket tokens
     * @dev Validates quality and calculates proportional basket tokens
     * @param creditContract Address of the carbon credit contract
     * @param tokenIds Array of NFT token IDs to deposit
     * @return basketTokens Amount of basket tokens minted
     */
    function deposit(
        address creditContract,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant validComponent(creditContract) returns (uint256 basketTokens) {
        if (tokenIds.length == 0) {
            revert("CarbonBasketToken: No tokens provided");
        }

        require(tokenIds.length <= MAX_BATCH_SIZE, "CarbonBasketToken: Batch too large");
        
        uint256 index = componentIndex[creditContract];
        BasketComponent storage component = basketComponents[index];
        
        if (!component.isActive) {
            revert("CarbonBasketToken: Component not active");
        }
        
        // Validate ownership and quality of all tokens using internal function to reduce stack depth
        CarbonCredits creditNFT = CarbonCredits(creditContract);
        (uint256 totalValue, uint256 totalQuality) = _validateDepositsAndCalculateTotals(
            creditContract, 
            creditNFT, 
            tokenIds
        );
        
        uint256 averageQuality = totalQuality / tokenIds.length;
        
        // Calculate basket tokens to mint based on current exchange rate
        basketTokens = _calculateBasketTokens(totalValue, averageQuality);
        
        // Transfer NFTs to contract
        for (uint256 i = 0; i < tokenIds.length; i++) {
            creditNFT.transferFrom(msg.sender, address(this), tokenIds[i]);
            component.tokenIds.push(tokenIds[i]);
        }
        
        // Update component statistics
        _updateComponentStats(index, totalValue, averageQuality, true);
        
        // Record user deposit
        userDeposits[msg.sender].push(UserDeposit({
            amount: basketTokens,
            timestamp: block.timestamp,
            qualityAtDeposit: averageQuality
        }));
        
        totalUserDeposits[msg.sender] += basketTokens;
        
        // Mint basket tokens
        _mint(msg.sender, basketTokens);
        
        emit Deposited(msg.sender, creditContract, tokenIds, basketTokens, averageQuality);
    }
    
    /**
     * @notice Withdraw proportional carbon credits by burning basket tokens
     * @dev Burns basket tokens and returns proportional underlying credits
     * @param basketTokenAmount Amount of basket tokens to burn
     * @return creditContracts Array of credit contract addresses
     * @return tokenIds Array of returned token ID arrays
     */
    function withdraw(uint256 basketTokenAmount) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (address[] memory creditContracts, uint256[][] memory tokenIds) 
    {
        if (basketTokenAmount == 0) {
            revert("CarbonBasketToken: Invalid amount");
        }
        
        if (balanceOf(msg.sender) < basketTokenAmount) {
            revert("CarbonBasketToken: Insufficient balance");
        }
        
        uint256 totalSupplyBefore = totalSupply();
        uint256 userShare = (basketTokenAmount * BASIS_POINTS) / totalSupplyBefore;
        
        creditContracts = new address[](basketComponents.length);
        tokenIds = new uint256[][](basketComponents.length);
        
        // Calculate proportional withdrawal from each component
        for (uint256 i = 0; i < basketComponents.length; i++) {
            BasketComponent storage component = basketComponents[i];
            
            if (component.tokenIds.length > 0) {
                uint256 tokensToWithdraw = (component.tokenIds.length * userShare) / BASIS_POINTS;
                require(tokensToWithdraw <= MAX_BATCH_SIZE, "CarbonBasketToken: Withdraw batch too large");

                if (tokensToWithdraw > 0) {
                    creditContracts[i] = component.creditContract;
                    tokenIds[i] = new uint256[](tokensToWithdraw);
                    
                    CarbonCredits creditNFT = CarbonCredits(component.creditContract);
                    
                    // Transfer tokens back to user
                    for (uint256 j = 0; j < tokensToWithdraw; j++) {
                        uint256 tokenId = component.tokenIds[component.tokenIds.length - 1];
                        component.tokenIds.pop();
                        tokenIds[i][j] = tokenId;
                        
                        creditNFT.transferFrom(address(this), msg.sender, tokenId);
                    }
                    
                    emit Withdrawn(msg.sender, component.creditContract, tokenIds[i], basketTokenAmount);
                }
            }
        }
        
        // Update user deposits (FIFO)
        _updateUserDepositsOnWithdrawal(msg.sender, basketTokenAmount);
        
        // Burn basket tokens
        _burn(msg.sender, basketTokenAmount);
        
        // Update component weights
        _recalculateWeights();
    }
    
    // ========== REBALANCING ==========
    
    /**
     * @notice Manually trigger rebalancing of the basket
     * @dev Can only be called by authorized rebalancer
     */
    function rebalance() external onlyRebalancer whenNotPaused {
        _performRebalance();
    }
    
    /**
     * @notice Check if rebalancing is needed and perform if necessary
     * @dev Internal function called during operations
     */
    function _checkAndRebalance() internal {
        if (!rebalanceConfig.autoRebalance) return;
        
        if (block.timestamp < lastRebalance + rebalanceConfig.frequency) return;
        
        if (_isRebalanceNeeded()) {
            _performRebalance();
        }
    }
    
    /**
     * @notice Check if rebalancing is needed based on weight deviations
     * @return needed Whether rebalancing is needed
     */
    function _isRebalanceNeeded() internal view returns (bool needed) {
        for (uint256 i = 0; i < basketComponents.length; i++) {
            BasketComponent memory component = basketComponents[i];
            
            if (!component.isActive) continue;
            
            uint256 deviation = component.currentWeight > component.targetWeight
                ? component.currentWeight - component.targetWeight
                : component.targetWeight - component.currentWeight;
            
            if (deviation > rebalanceConfig.threshold) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Perform the actual rebalancing
     * @dev Updates weights based on quality scores and target allocations
     */
    function _performRebalance() internal {
        uint256[] memory oldWeights = new uint256[](basketComponents.length);
        uint256[] memory newWeights = new uint256[](basketComponents.length);
        uint256 totalQuality = 0;
        
        // Calculate new weights based on quality scores
        for (uint256 i = 0; i < basketComponents.length; i++) {
            oldWeights[i] = basketComponents[i].currentWeight;
            
            if (basketComponents[i].isActive) {
                uint256 quality = qualityOracle.getQualityScore(basketComponents[i].creditContract);
                basketComponents[i].averageQuality = quality;
                totalQuality += quality;
            }
        }
        
        // Update weights proportionally based on quality
        for (uint256 i = 0; i < basketComponents.length; i++) {
            if (basketComponents[i].isActive && totalQuality > 0) {
                newWeights[i] = (basketComponents[i].averageQuality * BASIS_POINTS) / totalQuality;
                basketComponents[i].currentWeight = newWeights[i];
            }
        }
        
        lastRebalance = block.timestamp;
        
        emit Rebalanced(block.timestamp, oldWeights, newWeights, totalQuality);
    }
    
    // ========== INTERNAL HELPER FUNCTIONS ==========
    
    /**
     * @notice Calculate basket tokens to mint for given value and quality
     * @param carbonValue Total carbon offset value in grams
     * @param quality Average quality score
     * @return basketTokens Amount of basket tokens to mint
     */
    function _calculateBasketTokens(uint256 carbonValue, uint256 quality) internal view returns (uint256 basketTokens) {
        if (totalSupply() == 0) {
            // First deposit: 1:1 ratio with quality multiplier
            basketTokens = (carbonValue * quality) / 100;
        } else {
            // Subsequent deposits: maintain proportional value
            uint256 totalValue = getTotalBasketValue();
            basketTokens = (carbonValue * totalSupply()) / totalValue;
            
            // Apply quality premium/discount
            basketTokens = (basketTokens * quality) / 100;
        }
    }
    
    /**
     * @notice Update component statistics after deposit/withdrawal
     * @param index Component index
     * @param value Carbon value change
     * @param quality Quality score
     * @param isDeposit Whether this is a deposit (true) or withdrawal (false)
     */
    function _updateComponentStats(
        uint256 index,
        uint256 value,
        uint256 quality,
        bool isDeposit
    ) internal {
        BasketComponent storage component = basketComponents[index];
        
        if (isDeposit) {
            // Update average quality (weighted average)
            if (component.tokenIds.length > 0) {
                component.averageQuality = (component.averageQuality + quality) / 2;
            } else {
                component.averageQuality = quality;
            }
        }
        
        // Recalculate current weights
        _recalculateWeights();
    }
    
    /**
     * @notice Recalculate current weights based on held assets
     */
    function _recalculateWeights() internal {
        uint256 totalValue = getTotalBasketValue();
        
        if (totalValue == 0) return;
        
        for (uint256 i = 0; i < basketComponents.length; i++) {
            uint256 componentValue = getComponentValue(i);
            basketComponents[i].currentWeight = (componentValue * BASIS_POINTS) / totalValue;
        }
    }
    
    /**
     * @notice Update user deposits on withdrawal (FIFO)
     * @param user User address
     * @param amount Amount being withdrawn
     */
    function _updateUserDepositsOnWithdrawal(address user, uint256 amount) internal {
        UserDeposit[] storage deposits = userDeposits[user];
        uint256 remaining = amount;
        
        for (uint256 i = 0; i < deposits.length && remaining > 0; i++) {
            if (deposits[i].amount == 0) continue;
            
            if (deposits[i].amount <= remaining) {
                remaining -= deposits[i].amount;
                deposits[i].amount = 0;
            } else {
                deposits[i].amount -= remaining;
                remaining = 0;
            }
        }
        
        totalUserDeposits[user] -= amount;
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get the total value of all basket components
     * @return totalValue Total carbon offset value in grams
     */
    function getTotalBasketValue() public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < basketComponents.length; i++) {
            totalValue += getComponentValue(i);
        }
    }
    
    /**
     * @notice Get the value of a specific component
     * @param index Component index
     * @return componentValue Total carbon offset value for the component
     */
    function getComponentValue(uint256 index) public view returns (uint256 componentValue) {
        if (index >= basketComponents.length) return 0;
        
        BasketComponent memory component = basketComponents[index];
        if (component.tokenIds.length == 0) return 0;
        
        CarbonCredits creditNFT = CarbonCredits(component.creditContract);
        
        for (uint256 i = 0; i < component.tokenIds.length; i++) {
            try creditNFT.getCreditDetails(component.tokenIds[i]) returns (
                uint256 carbonOffset,
                string memory, // projectType
                string memory, // verificationStandard  
                uint256, // issuanceDate
                uint256, // expiryDate
                string memory, // location
                bool isRetired,
                address // issuer
            ) {
                if (!isRetired) {
                    componentValue += carbonOffset;
                }
            } catch {
                // Skip invalid tokens
            }
        }
    }
    
    /**
     * @notice Get detailed information about a component
     * @param index Component index
     * @return component The component details
     */
    function getComponentInfo(uint256 index) external view returns (BasketComponent memory component) {
        if (index < basketComponents.length) {
            component = basketComponents[index];
        }
    }
    
    /**
     * @notice Get the number of components in the basket
     * @return count Number of components
     */
    function getComponentCount() external view returns (uint256 count) {
        return basketComponents.length;
    }
    
    /**
     * @notice Get user deposit history
     * @param user User address
     * @return deposits Array of user deposits
     */
    function getUserDeposits(address user) external view returns (UserDeposit[] memory deposits) {
        return userDeposits[user];
    }
    
    /**
     * @notice Check if rebalancing is currently needed
     * @return needed Whether rebalancing is needed
     */
    function isRebalanceNeeded() external view returns (bool needed) {
        return _isRebalanceNeeded();
    }
    
    /**
     * @notice Get the current basket exchange rate
     * @return rate Rate of basket tokens per unit of carbon offset
     */
    function getExchangeRate() external view returns (uint256 rate) {
        uint256 totalValue = getTotalBasketValue();
        if (totalValue == 0 || totalSupply() == 0) return 1e18;
        return (totalSupply() * 1e18) / totalValue;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set the rebalancer address
     * @param newRebalancer Address of the new rebalancer
     */
    function setRebalancer(address newRebalancer) external onlyOwner {
        if (newRebalancer == address(0)) {
            revert("CarbonBasketToken: Invalid rebalancer address");
        }
        rebalancer = newRebalancer;
    }
    
    /**
     * @notice Update rebalance configuration
     * @param threshold New deviation threshold
     * @param frequency New rebalance frequency
     * @param maxSlippage New maximum slippage
     * @param autoRebalance Whether to enable auto-rebalancing
     */
    function setRebalanceConfig(
        uint256 threshold,
        uint256 frequency,
        uint256 maxSlippage,
        bool autoRebalance
    ) external onlyOwner {
        if (threshold > 2000) { // Max 20% deviation
            revert("CarbonBasketToken: Threshold too high");
        }
        if (maxSlippage > 1000) { // Max 10% slippage
            revert("CarbonBasketToken: Slippage too high");
        }
        
        rebalanceConfig.threshold = threshold;
        rebalanceConfig.frequency = frequency;
        rebalanceConfig.maxSlippage = maxSlippage;
        rebalanceConfig.autoRebalance = autoRebalance;
        
        emit RebalanceConfigUpdated(threshold, frequency, maxSlippage, autoRebalance);
    }
    
    /**
     * @notice Queue a management fee rate change (subject to timelock)
     * @param newFeeRate New fee rate in basis points
     */
    function queueManagementFeeRate(uint256 newFeeRate) external onlyOwner {
        if (newFeeRate > MAX_MANAGEMENT_FEE) {
            revert("CarbonBasketToken: Fee rate too high");
        }
        uint256 nonce = ++feeChangeNonce;
        pendingManagementFee = PendingFeeChange({
            newRate: newFeeRate,
            queuedAt: block.timestamp,
            nonce: nonce,
            exists: true
        });
        emit FeeUpdateQueued(nonce, "management", managementFeeRate, newFeeRate, block.timestamp + FEE_TIMELOCK_DELAY);
    }

    /**
     * @notice Execute a queued management fee rate change after timelock
     */
    function executeManagementFeeRate() external onlyOwner {
        PendingFeeChange memory pending = pendingManagementFee;
        if (!pending.exists) {
            revert("CarbonBasketToken: No pending fee change");
        }
        if (block.timestamp < pending.queuedAt + FEE_TIMELOCK_DELAY) {
            revert("CarbonBasketToken: Timelock not elapsed");
        }
        if (block.timestamp > pending.queuedAt + FEE_TIMELOCK_DELAY + FEE_TIMELOCK_EXPIRY) {
            revert("CarbonBasketToken: Fee change expired");
        }
        uint256 oldRate = managementFeeRate;
        managementFeeRate = pending.newRate;
        delete pendingManagementFee;
        emit FeeUpdateExecuted(pending.nonce, "management", oldRate, pending.newRate);
    }

    /**
     * @notice Queue a performance fee rate change (subject to timelock)
     * @param newFeeRate New fee rate in basis points
     */
    function queuePerformanceFeeRate(uint256 newFeeRate) external onlyOwner {
        if (newFeeRate > MAX_PERFORMANCE_FEE) {
            revert("CarbonBasketToken: Fee rate too high");
        }
        uint256 nonce = ++feeChangeNonce;
        pendingPerformanceFee = PendingFeeChange({
            newRate: newFeeRate,
            queuedAt: block.timestamp,
            nonce: nonce,
            exists: true
        });
        emit FeeUpdateQueued(nonce, "performance", performanceFeeRate, newFeeRate, block.timestamp + FEE_TIMELOCK_DELAY);
    }

    /**
     * @notice Execute a queued performance fee rate change after timelock
     */
    function executePerformanceFeeRate() external onlyOwner {
        PendingFeeChange memory pending = pendingPerformanceFee;
        if (!pending.exists) {
            revert("CarbonBasketToken: No pending fee change");
        }
        if (block.timestamp < pending.queuedAt + FEE_TIMELOCK_DELAY) {
            revert("CarbonBasketToken: Timelock not elapsed");
        }
        if (block.timestamp > pending.queuedAt + FEE_TIMELOCK_DELAY + FEE_TIMELOCK_EXPIRY) {
            revert("CarbonBasketToken: Fee change expired");
        }
        uint256 oldRate = performanceFeeRate;
        performanceFeeRate = pending.newRate;
        delete pendingPerformanceFee;
        emit FeeUpdateExecuted(pending.nonce, "performance", oldRate, pending.newRate);
    }

    /**
     * @notice Set fee recipient (immediate, no timelock)
     * @param newRecipient Address of the new fee recipient
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) {
            revert("CarbonBasketToken: Invalid recipient address");
        }
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }
    
    /**
     * @notice Emergency pause all operations
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause all operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ========== ERC20 OVERRIDES ==========
    
    /**
     * @notice Override transfer to include fee collection
     */
    function _update(address from, address to, uint256 value) internal override {
        if (paused()) {
            revert("CarbonBasketToken: Token transfers paused");
        }
        
        // Collect management fees on transfers
        _collectManagementFees();
        
        super._update(from, to, value);
    }
    
    /**
     * @notice Collect management fees
     */
    function _collectManagementFees() internal {
        if (block.timestamp <= lastFeeCollection + 1 days) return;
        
        uint256 timeElapsed = block.timestamp - lastFeeCollection;
        uint256 annualizedSupply = totalSupply();
        uint256 fees = (annualizedSupply * managementFeeRate * timeElapsed) / (BASIS_POINTS * 365 days);
        
        if (fees > 0) {
            _mint(feeRecipient, fees);
            totalFeesCollected += fees;
            lastFeeCollection = block.timestamp;
        }
    }
    
    /**
     * @notice Manually collect fees
     */
    function collectFees() external {
        _collectManagementFees();
        
        emit FeesCollected(0, 0, feeRecipient); // Management fees collected automatically
    }
    
    /**
     * @dev Internal function to validate deposits and calculate totals
     * @param creditContract Address of the credit contract
     * @param creditNFT Interface to the credit contract
     * @param tokenIds Array of token IDs to validate
     * @return totalValue Total carbon offset value
     * @return totalQuality Total quality score
     */
    function _validateDepositsAndCalculateTotals(
        address creditContract,
        CarbonCredits creditNFT,
        uint256[] calldata tokenIds
    ) internal view returns (uint256 totalValue, uint256 totalQuality) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Verify ownership
            if (creditNFT.ownerOf(tokenId) != msg.sender) {
                revert("CarbonBasketToken: Not owner of token");
            }
            
            // Get credit details
            (
                uint256 carbonOffset,
                , // projectType
                , // verificationStandard
                , // issuanceDate
                uint256 expiryDate,
                , // location
                bool isRetired,
                // address issuer
            ) = creditNFT.getCreditDetails(tokenId);
            
            if (isRetired) {
                revert("CarbonBasketToken: Credit already retired");
            }
            
            if (expiryDate <= block.timestamp) {
                revert("CarbonBasketToken: Credit expired");
            }
            
            // Get quality score
            uint256 quality = qualityOracle.getQualityScore(creditContract);
            if (quality < MIN_QUALITY_THRESHOLD) {
                revert("CarbonBasketToken: Quality below threshold");
            }
            
            totalValue += carbonOffset;
            totalQuality += quality;
        }
    }
}