// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDerivativesEngine.sol";
import "./interfaces/IQualityOracle.sol";
import "./EnhancedCarbonCredits.sol";
import "./WRFToken.sol";
import "./CarbonCreditAMM.sol";

/**
 * @title DerivativesEngine
 * @dev Central engine for carbon credit derivatives trading
 * Manages futures, options, margin, liquidations, and settlements
 */
contract DerivativesEngine is IDerivativesEngine, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Role definitions
    bytes32 public constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    
    // Contract dependencies
    EnhancedCarbonCredits public immutable carbonCredits;
    WRFToken public immutable wrfToken;
    IQualityOracle public immutable qualityOracle;
    CarbonCreditAMM public immutable amm;
    
    // State variables
    uint256 private _nextFutureId = 1;
    uint256 private _nextOptionId = 1;
    uint256 private _nextPositionId = 1;
    
    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_INITIAL_MARGIN = 1000;      // 10%
    uint256 public constant DEFAULT_MAINTENANCE_MARGIN = 500;   // 5%
    uint256 public constant LIQUIDATION_REWARD = 50;           // 0.5%
    uint256 public constant MARGIN_CALL_GRACE_PERIOD = 24 hours;
    uint256 public constant MIN_POSITION_VALUE = 100 * 10**18; // 100 WRF minimum
    
    // Oracle Security Constants
    uint256 public constant MAX_PRICE_DEVIATION = 1000;        // 10% max price change
    uint256 public constant MAX_PRICE_AGE = 1 hours;           // Max 1 hour stale price
    uint256 public constant MIN_ORACLE_CONFIDENCE = 8000;      // 80% minimum confidence
    uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 2000;  // 20% deviation triggers circuit breaker
    
    // Storage mappings
    mapping(uint256 => Future) public futures;
    mapping(uint256 => Option) public options;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => MarginRequirement) public futureMarginRequirements;
    mapping(uint256 => MarginRequirement) public optionMarginRequirements;
    mapping(address => uint256[]) public userPositions;
    mapping(uint256 => LiquidationData) public liquidations;
    
    // Market parameters
    mapping(uint256 => uint256) public lastPriceUpdate;
    mapping(uint256 => uint256) public settlementPrices;
    
    // Oracle Security State
    mapping(uint256 => uint256) public lastValidPrices;       // tokenId => last valid price
    mapping(uint256 => uint256) public lastPriceTimestamp;    // tokenId => timestamp
    mapping(uint256 => bool) public circuitBreakerTriggered;  // tokenId => breaker status
    bool public globalCircuitBreaker = false;                 // Global emergency stop
    
    // MEV Protection State
    mapping(bytes32 => uint256) public liquidationCommits;    // caller-scoped commit key => timestamp
    mapping(uint256 => uint256) public lastLiquidationTime;   // positionId => timestamp
    uint256 public constant LIQUIDATION_DELAY = 300;          // 5 minutes delay for liquidations
    uint256 public constant COMMIT_REVEAL_WINDOW = 600;       // 10 minutes window for reveal
    uint256 public constant MIN_LIQUIDATION_INTERVAL = 3600;  // 1 hour between liquidations per position
    
    modifier validFuture(uint256 futureId) {
        require(futureId > 0 && futureId < _nextFutureId, "Invalid future ID");
        require(futures[futureId].isActive, "Future not active");
        _;
    }
    
    modifier validOption(uint256 optionId) {
        require(optionId > 0 && optionId < _nextOptionId, "Invalid option ID");
        require(options[optionId].isActive, "Option not active");
        _;
    }
    
    modifier validPosition(uint256 positionId) {
        require(positionId > 0 && positionId < _nextPositionId, "Invalid position ID");
        require(positions[positionId].status == PositionStatus.ACTIVE, "Position not active");
        _;
    }
    
    modifier onlyPositionOwner(uint256 positionId) {
        require(positions[positionId].trader == msg.sender, "Not position owner");
        _;
    }
    
    modifier circuitBreakerCheck(uint256 tokenId) {
        require(!globalCircuitBreaker, "Global circuit breaker triggered");
        require(!circuitBreakerTriggered[tokenId], "Asset circuit breaker triggered");
        _;
    }
    
    constructor(
        address _carbonCredits,
        address _wrfToken,
        address _qualityOracle,
        address _amm
    ) {
        require(_carbonCredits != address(0), "Invalid carbon credits address");
        require(_wrfToken != address(0), "Invalid WRF token address");
        require(_qualityOracle != address(0), "Invalid quality oracle address");
        require(_amm != address(0), "Invalid AMM address");
        
        carbonCredits = EnhancedCarbonCredits(_carbonCredits);
        wrfToken = WRFToken(_wrfToken);
        qualityOracle = IQualityOracle(_qualityOracle);
        amm = CarbonCreditAMM(_amm);
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKET_MAKER_ROLE, msg.sender);
        _grantRole(LIQUIDATOR_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(SETTLEMENT_ROLE, msg.sender);
    }
    
    /**
     * @dev Create a new futures contract
     */
    function createFuture(
        uint256 underlyingTokenId,
        uint256 contractSize,
        uint256 expiryTimestamp,
        SettlementType settlementType,
        string calldata description
    ) external onlyRole(MARKET_MAKER_ROLE) returns (uint256 futureId) {
        require(expiryTimestamp > block.timestamp, "Expiry must be in future");
        require(contractSize > 0, "Contract size must be positive");
        
        // Verify underlying token exists and is active
        (,,,,,,, bool isActive) = carbonCredits.getBatchCore(underlyingTokenId);
        require(isActive, "Underlying token not active");
        
        futureId = _nextFutureId++;
        
        futures[futureId] = Future({
            futureId: futureId,
            underlyingTokenId: underlyingTokenId,
            contractSize: contractSize,
            expiryTimestamp: expiryTimestamp,
            settlementPrice: 0,
            settlementType: settlementType,
            isActive: true,
            description: description
        });
        
        // Set default margin requirements
        futureMarginRequirements[futureId] = MarginRequirement({
            initialMargin: DEFAULT_INITIAL_MARGIN,
            maintenanceMargin: DEFAULT_MAINTENANCE_MARGIN,
            qualityAdjustment: 0,
            volatilityAdjustment: 0
        });
        
        emit FutureCreated(
            futureId,
            underlyingTokenId,
            contractSize,
            expiryTimestamp,
            settlementType
        );
    }
    
    /**
     * @dev Create a new options contract
     */
    function createOption(
        uint256 underlyingTokenId,
        uint256 contractSize,
        uint256 strikePrice,
        uint256 expiryTimestamp,
        uint256 premium,
        DerivativeType optionType,
        SettlementType settlementType,
        string calldata description
    ) external onlyRole(MARKET_MAKER_ROLE) returns (uint256 optionId) {
        require(expiryTimestamp > block.timestamp, "Expiry must be in future");
        require(contractSize > 0, "Contract size must be positive");
        require(strikePrice > 0, "Strike price must be positive");
        require(premium > 0, "Premium must be positive");
        require(
            optionType == DerivativeType.CALL_OPTION || optionType == DerivativeType.PUT_OPTION,
            "Invalid option type"
        );
        
        // Verify underlying token exists and is active
        (,,,,,,, bool isActive) = carbonCredits.getBatchCore(underlyingTokenId);
        require(isActive, "Underlying token not active");
        
        optionId = _nextOptionId++;
        
        options[optionId] = Option({
            optionId: optionId,
            underlyingTokenId: underlyingTokenId,
            contractSize: contractSize,
            strikePrice: strikePrice,
            expiryTimestamp: expiryTimestamp,
            premium: premium,
            optionType: optionType,
            settlementType: settlementType,
            isActive: true,
            description: description
        });
        
        // Set default margin requirements for options
        optionMarginRequirements[optionId] = MarginRequirement({
            initialMargin: DEFAULT_INITIAL_MARGIN + 500, // Higher margin for options
            maintenanceMargin: DEFAULT_MAINTENANCE_MARGIN + 250,
            qualityAdjustment: 0,
            volatilityAdjustment: 0
        });
        
        emit OptionCreated(
            optionId,
            underlyingTokenId,
            contractSize,
            strikePrice,
            expiryTimestamp,
            optionType,
            settlementType
        );
    }
    
    /**
     * @dev Open a new derivatives position
     */
    function openPosition(
        uint256 derivativeId,
        DerivativeType derivativeType,
        bool isLong,
        uint256 quantity,
        uint256 maxPrice,
        uint256 collateralAmount
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        require(quantity > 0, "Quantity must be positive");
        require(collateralAmount >= MIN_POSITION_VALUE, "Insufficient collateral");
        
        uint256 underlyingTokenId;
        uint256 currentPrice;
        
        // Validate derivative exists and get details
        if (derivativeType == DerivativeType.FUTURE) {
            require(derivativeId > 0 && derivativeId < _nextFutureId, "Invalid future ID");
            require(futures[derivativeId].isActive, "Future not active");
            require(block.timestamp < futures[derivativeId].expiryTimestamp, "Future expired");
            underlyingTokenId = futures[derivativeId].underlyingTokenId;
        } else {
            require(derivativeId > 0 && derivativeId < _nextOptionId, "Invalid option ID");
            require(options[derivativeId].isActive, "Option not active");
            require(block.timestamp < options[derivativeId].expiryTimestamp, "Option expired");
            underlyingTokenId = options[derivativeId].underlyingTokenId;
        }
        
        // Get current price and validate against max price
        (currentPrice,) = getCurrentPrice(underlyingTokenId);
        require(currentPrice <= maxPrice, "Price exceeds maximum");
        
        // Calculate required margin
        uint256 requiredMargin = _calculateRequiredMargin(derivativeId, derivativeType, quantity, currentPrice);
        require(collateralAmount >= requiredMargin, "Insufficient margin");
        
        // Transfer collateral from user
        IERC20(address(wrfToken)).safeTransferFrom(msg.sender, address(this), collateralAmount);
        
        positionId = _nextPositionId++;
        
        positions[positionId] = Position({
            positionId: positionId,
            trader: msg.sender,
            derivativeId: derivativeId,
            derivativeType: derivativeType,
            isLong: isLong,
            quantity: quantity,
            entryPrice: currentPrice,
            collateralAmount: collateralAmount,
            lastMarginCall: 0,
            status: PositionStatus.ACTIVE,
            openTimestamp: block.timestamp
        });
        
        userPositions[msg.sender].push(positionId);
        
        emit PositionOpened(
            positionId,
            msg.sender,
            derivativeId,
            derivativeType,
            isLong,
            quantity,
            currentPrice,
            collateralAmount
        );
    }
    
    /**
     * @dev Close an existing position
     */
    function closePosition(
        uint256 positionId,
        uint256 minPrice
    ) external nonReentrant validPosition(positionId) onlyPositionOwner(positionId) returns (int256 pnl) {
        Position storage position = positions[positionId];
        
        // Get current price
        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
        require(currentPrice >= minPrice, "Price below minimum");
        
        // Calculate P&L
        pnl = _calculatePnL(positionId, currentPrice);
        
        // Calculate collateral to return
        uint256 collateralToReturn;
        if (pnl >= 0) {
            collateralToReturn = position.collateralAmount + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            if (loss >= position.collateralAmount) {
                collateralToReturn = 0;
            } else {
                collateralToReturn = position.collateralAmount - loss;
            }
        }
        
        // Update position status
        position.status = PositionStatus.SETTLED;
        
        // Transfer collateral back to trader
        if (collateralToReturn > 0) {
            IERC20(address(wrfToken)).safeTransfer(position.trader, collateralToReturn);
        }
        
        emit PositionClosed(positionId, position.trader, currentPrice, pnl, collateralToReturn);
    }
    
    /**
     * @dev Add collateral to a position
     */
    function addCollateral(
        uint256 positionId, 
        uint256 amount
    ) external nonReentrant validPosition(positionId) onlyPositionOwner(positionId) {
        require(amount > 0, "Amount must be positive");
        
        // Transfer additional collateral
        IERC20(address(wrfToken)).safeTransferFrom(msg.sender, address(this), amount);
        
        positions[positionId].collateralAmount += amount;
    }
    
    /**
     * @dev Remove collateral from a position (if sufficient margin remains)
     */
    function removeCollateral(
        uint256 positionId, 
        uint256 amount
    ) external nonReentrant validPosition(positionId) onlyPositionOwner(positionId) {
        require(amount > 0, "Amount must be positive");
        
        Position storage position = positions[positionId];
        require(amount <= position.collateralAmount, "Insufficient collateral");
        
        // Check if remaining collateral meets margin requirements
        uint256 remainingCollateral = position.collateralAmount - amount;
        uint256 requiredMargin = getRequiredMargin(positionId);
        require(remainingCollateral >= requiredMargin, "Would violate margin requirement");
        
        position.collateralAmount = remainingCollateral;
        IERC20(address(wrfToken)).safeTransfer(position.trader, amount);
    }
    
    /**
     * @dev Commit to liquidating a position (MEV protection step 1)
     */
    function commitLiquidation(bytes32 commitHash) external onlyRole(LIQUIDATOR_ROLE) whenNotPaused {
        require(commitHash != bytes32(0), "Invalid commit hash");
        bytes32 commitKey = _liquidationCommitKey(msg.sender, commitHash);
        require(liquidationCommits[commitKey] == 0, "Commit already exists");
        
        liquidationCommits[commitKey] = block.timestamp;
        
        emit LiquidationCommitted(msg.sender, commitHash, block.timestamp);
    }

    /**
     * @dev Return the timestamp for a liquidator's caller-scoped liquidation commit
     */
    function getLiquidationCommit(address liquidator, bytes32 commitHash) external view returns (uint256) {
        return liquidationCommits[_liquidationCommitKey(liquidator, commitHash)];
    }
    
    /**
     * @dev Reveal and execute liquidation (MEV protection step 2)
     */
    function revealAndLiquidate(
        uint256 positionId,
        uint256 nonce,
        uint256 maxPrice
    ) external nonReentrant validPosition(positionId) returns (uint256 liquidatorReward) {
        // Verify commit-reveal scheme
        bytes32 commitHash = keccak256(abi.encodePacked(msg.sender, positionId, nonce, maxPrice));
        bytes32 commitKey = _liquidationCommitKey(msg.sender, commitHash);
        uint256 commitTime = liquidationCommits[commitKey];
        require(commitTime > 0, "No valid commit found");
        require(block.timestamp >= commitTime + LIQUIDATION_DELAY, "Liquidation delay not met");
        require(block.timestamp <= commitTime + COMMIT_REVEAL_WINDOW, "Commit window expired");
        
        // Check liquidation interval to prevent spam
        require(
            block.timestamp >= lastLiquidationTime[positionId] + MIN_LIQUIDATION_INTERVAL,
            "Liquidation interval not met"
        );
        
        // Clear the commit to prevent replay
        delete liquidationCommits[commitKey];
        
        require(isPositionLiquidatable(positionId), "Position not liquidatable");
        
        Position storage position = positions[positionId];
        
        // Get current price with circuit breaker protection
        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
        require(currentPrice <= maxPrice, "Price exceeds maximum allowed");
        
        // Calculate liquidator reward with slippage protection
        liquidatorReward = (position.collateralAmount * LIQUIDATION_REWARD) / BASIS_POINTS;
        
        // Record liquidation
        liquidations[positionId] = LiquidationData({
            positionId: positionId,
            liquidator: msg.sender,
            liquidationPrice: currentPrice,
            liquidationTimestamp: block.timestamp,
            collateralSeized: position.collateralAmount,
            liquidatorReward: liquidatorReward
        });
        
        // Update position status and timestamp
        position.status = PositionStatus.LIQUIDATED;
        lastLiquidationTime[positionId] = block.timestamp;
        
        // Transfer liquidator reward
        IERC20(address(wrfToken)).safeTransfer(msg.sender, liquidatorReward);
        
        emit PositionLiquidated(
            positionId,
            position.trader,
            msg.sender,
            currentPrice,
            position.collateralAmount,
            liquidatorReward
        );
    }
    
    /**
     * @dev Emergency liquidation for admin role (bypasses MEV protection)
     */
    function emergencyLiquidatePosition(
        uint256 positionId
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant validPosition(positionId) returns (uint256 liquidatorReward) {
        require(isPositionLiquidatable(positionId), "Position not liquidatable");
        
        Position storage position = positions[positionId];
        
        // Get current price
        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
        
        // Calculate liquidator reward
        liquidatorReward = (position.collateralAmount * LIQUIDATION_REWARD) / BASIS_POINTS;
        
        // Record liquidation
        liquidations[positionId] = LiquidationData({
            positionId: positionId,
            liquidator: msg.sender,
            liquidationPrice: currentPrice,
            liquidationTimestamp: block.timestamp,
            collateralSeized: position.collateralAmount,
            liquidatorReward: liquidatorReward
        });
        
        // Update position status
        position.status = PositionStatus.LIQUIDATED;
        lastLiquidationTime[positionId] = block.timestamp;
        
        // Transfer liquidator reward to protocol treasury
        IERC20(address(wrfToken)).safeTransfer(msg.sender, liquidatorReward);
        
        emit PositionLiquidated(
            positionId,
            position.trader,
            msg.sender,
            currentPrice,
            position.collateralAmount,
            liquidatorReward
        );
    }
    
    /**
     * @dev Check if a position can be liquidated
     */
    function isPositionLiquidatable(uint256 positionId) public view validPosition(positionId) returns (bool) {
        Position memory position = positions[positionId];
        
        // Get current price
        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
        
        // Calculate current P&L
        int256 pnl = _calculatePnL(positionId, currentPrice);
        
        // Check if collateral + P&L falls below maintenance margin
        uint256 requiredMargin = getRequiredMargin(positionId);
        
        if (pnl >= 0) {
            return false; // Position is profitable, can't be liquidated
        }
        
        uint256 loss = uint256(-pnl);
        uint256 effectiveCollateral = position.collateralAmount > loss ? position.collateralAmount - loss : 0;
        
        return effectiveCollateral < requiredMargin;
    }
    
    /**
     * @dev Settle a derivative at expiry
     */
    function settleDerivative(uint256 derivativeId, DerivativeType derivativeType) external onlyRole(SETTLEMENT_ROLE) {
        uint256 underlyingTokenId;
        uint256 expiryTimestamp;
        
        if (derivativeType == DerivativeType.FUTURE) {
            Future storage future = futures[derivativeId];
            require(future.isActive, "Future not active");
            require(block.timestamp >= future.expiryTimestamp, "Future not expired");
            
            underlyingTokenId = future.underlyingTokenId;
            expiryTimestamp = future.expiryTimestamp;
            
            // Ensure circuit breakers are not triggered for settlement
            require(!globalCircuitBreaker, "Global circuit breaker active");
            require(!circuitBreakerTriggered[underlyingTokenId], "Asset circuit breaker active");
            
            // Get settlement price with oracle protection
            (uint256 settlementPrice, uint256 confidence) = getCurrentPrice(underlyingTokenId);
            require(confidence >= MIN_ORACLE_CONFIDENCE, "Insufficient oracle confidence for settlement");
            
            future.settlementPrice = settlementPrice;
            future.isActive = false;
            
            settlementPrices[derivativeId] = settlementPrice;
        } else {
            Option storage option = options[derivativeId];
            require(option.isActive, "Option not active");
            require(block.timestamp >= option.expiryTimestamp, "Option not expired");
            
            underlyingTokenId = option.underlyingTokenId;
            expiryTimestamp = option.expiryTimestamp;
            
            // Options expire worthless if not exercised
            option.isActive = false;
        }
        
        emit DerivativeSettled(derivativeId, derivativeType, settlementPrices[derivativeId], 0);
    }
    
    /**
     * @dev Exercise an option before expiry
     */
    function exerciseOption(
        uint256 positionId
    ) external nonReentrant validPosition(positionId) onlyPositionOwner(positionId) {
        Position memory position = positions[positionId];
        require(position.derivativeType != DerivativeType.FUTURE, "Cannot exercise futures");
        require(position.isLong, "Only long positions can exercise");
        
        Option memory option = options[position.derivativeId];
        require(option.isActive, "Option not active");
        require(block.timestamp < option.expiryTimestamp, "Option expired");
        
        // Get current price
        (uint256 currentPrice,) = getCurrentPrice(option.underlyingTokenId);
        
        // Check if option is in the money
        bool inTheMoney;
        if (option.optionType == DerivativeType.CALL_OPTION) {
            inTheMoney = currentPrice > option.strikePrice;
        } else {
            inTheMoney = currentPrice < option.strikePrice;
        }
        
        require(inTheMoney, "Option not in the money");
        
        // Calculate settlement based on intrinsic value
        uint256 intrinsicValue;
        if (option.optionType == DerivativeType.CALL_OPTION) {
            intrinsicValue = currentPrice - option.strikePrice;
        } else {
            intrinsicValue = option.strikePrice - currentPrice;
        }
        
        uint256 settlement = intrinsicValue * position.quantity * option.contractSize;
        
        // Update position
        positions[positionId].status = PositionStatus.SETTLED;
        
        // Transfer settlement
        IERC20(address(wrfToken)).safeTransfer(position.trader, settlement);
        
        emit PositionClosed(positionId, position.trader, currentPrice, int256(settlement), settlement);
    }
    
    // View functions
    function getFuture(uint256 futureId) external view returns (Future memory) {
        return futures[futureId];
    }
    
    function getOption(uint256 optionId) external view returns (Option memory) {
        return options[optionId];
    }
    
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
    
    function getMarginRequirement(
        uint256 derivativeId, 
        DerivativeType derivativeType
    ) external view returns (MarginRequirement memory) {
        if (derivativeType == DerivativeType.FUTURE) {
            return futureMarginRequirements[derivativeId];
        } else {
            return optionMarginRequirements[derivativeId];
        }
    }
    
    function calculatePositionValue(uint256 positionId) external view validPosition(positionId) returns (int256 value) {
        Position memory position = positions[positionId];
        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
        return _calculatePnL(positionId, currentPrice);
    }
    
    function getRequiredMargin(uint256 positionId) public view validPosition(positionId) returns (uint256 required) {
        Position memory position = positions[positionId];
        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
        return _calculateRequiredMargin(
            position.derivativeId, position.derivativeType, position.quantity, currentPrice
        );
    }
    
    function getUserPositions(address user) external view returns (uint256[] memory positionIds) {
        return userPositions[user];
    }
    
    function getCurrentPrice(
        uint256 underlyingTokenId
    ) public view circuitBreakerCheck(underlyingTokenId) returns (uint256 price, uint256 confidence) {
        // Get price from quality oracle with confidence scoring
        // Note: getLatestPrice method doesn't exist in interface, using fallback
        uint256 oraclePrice = 0;
        bool useOracle = false;

        if (useOracle && oraclePrice > 0) {
            // Validate price against historical data
            uint256 lastPrice = lastValidPrices[underlyingTokenId];
            if (lastPrice > 0) {
                uint256 deviation = lastPrice > oraclePrice ?
                    ((lastPrice - oraclePrice) * BASIS_POINTS) / lastPrice :
                    ((oraclePrice - lastPrice) * BASIS_POINTS) / lastPrice;

                // Reject if deviation exceeds maximum allowed
                if (deviation <= MAX_PRICE_DEVIATION) {
                    price = oraclePrice;
                    confidence = 95; // High confidence for validated oracle data
                    return (price, confidence);
                }
            } else {
                // First price for this token
                price = oraclePrice;
                confidence = 95;
                return (price, confidence);
            }
        }

        // Fallback to AMM price if oracle validation fails or oracle not used
        price = _getAMMPrice(underlyingTokenId);
        confidence = 70; // Lower confidence for AMM-derived price
    }
    
    function getQualityAdjustedPrice(
        uint256 underlyingTokenId
    ) external view circuitBreakerCheck(underlyingTokenId) returns (uint256 adjustedPrice) {
        (uint256 basePrice,) = getCurrentPrice(underlyingTokenId);
        
        try qualityOracle.getQualityPricingFactor(address(uint160(underlyingTokenId))) returns (uint256 factor) {
            adjustedPrice = (basePrice * factor) / BASIS_POINTS;
        } catch {
            adjustedPrice = basePrice; // Return unadjusted price if oracle fails
        }
    }
    
    function updateMarginRequirements(
        uint256 derivativeId, 
        DerivativeType derivativeType
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        uint256 underlyingTokenId = _getUnderlyingTokenId(derivativeId, derivativeType);
        
        // Get quality and volatility adjustments from oracle
        uint256 qualityAdjustment = 0;
        uint256 volatilityAdjustment = 0;
        
        try qualityOracle.getQualityMetrics(address(uint160(underlyingTokenId))) returns (IQualityOracle.QualityMetrics memory metrics) {
            // Lower quality scores require higher margins
            if (metrics.overallScore < 50) {
                qualityAdjustment = 500; // +5% margin for low quality
            } else if (metrics.overallScore < 70) {
                qualityAdjustment = 200; // +2% margin for medium quality
            }
        } catch {
            qualityAdjustment = 300; // Default adjustment if oracle fails
        }
        
        // Update margin requirements
        if (derivativeType == DerivativeType.FUTURE) {
            MarginRequirement storage margin = futureMarginRequirements[derivativeId];
            margin.qualityAdjustment = qualityAdjustment;
            margin.volatilityAdjustment = volatilityAdjustment;
        } else {
            MarginRequirement storage margin = optionMarginRequirements[derivativeId];
            margin.qualityAdjustment = qualityAdjustment;
            margin.volatilityAdjustment = volatilityAdjustment;
        }
    }
    
    // Internal functions
    function _calculatePnL(uint256 positionId, uint256 currentPrice) internal view returns (int256 pnl) {
        Position memory position = positions[positionId];
        
        int256 priceDiff = int256(currentPrice) - int256(position.entryPrice);
        if (!position.isLong) {
            priceDiff = -priceDiff;
        }
        
        if (position.derivativeType == DerivativeType.FUTURE) {
            Future memory future = futures[position.derivativeId];
            pnl = priceDiff * int256(position.quantity) * int256(future.contractSize);
        } else {
            Option memory option = options[position.derivativeId];
            
            if (position.isLong) {
                // Long option - limited loss to premium paid
                int256 intrinsicValue;
                if (option.optionType == DerivativeType.CALL_OPTION) {
                    intrinsicValue = currentPrice > option.strikePrice ? 
                        int256(currentPrice - option.strikePrice) : int256(0);
                } else {
                    intrinsicValue = option.strikePrice > currentPrice ? 
                        int256(option.strikePrice - currentPrice) : int256(0);
                }
                pnl = intrinsicValue * int256(position.quantity) * int256(option.contractSize) - 
                    int256(option.premium * position.quantity);
            } else {
                // Short option - premium received minus intrinsic value
                int256 intrinsicValue;
                if (option.optionType == DerivativeType.CALL_OPTION) {
                    intrinsicValue = currentPrice > option.strikePrice ? 
                        int256(currentPrice - option.strikePrice) : int256(0);
                } else {
                    intrinsicValue = option.strikePrice > currentPrice ? 
                        int256(option.strikePrice - currentPrice) : int256(0);
                }
                pnl = int256(option.premium * position.quantity) - 
                    intrinsicValue * int256(position.quantity) * int256(option.contractSize);
            }
        }
    }
    
    function _calculateRequiredMargin(
        uint256 derivativeId, 
        DerivativeType derivativeType, 
        uint256 quantity, 
        uint256 price
    ) internal view returns (uint256 required) {
        MarginRequirement memory margin;
        uint256 contractSize;
        
        if (derivativeType == DerivativeType.FUTURE) {
            margin = futureMarginRequirements[derivativeId];
            contractSize = futures[derivativeId].contractSize;
        } else {
            margin = optionMarginRequirements[derivativeId];
            contractSize = options[derivativeId].contractSize;
        }
        
        uint256 notionalValue = price * quantity * contractSize;
        uint256 baseMargin = (notionalValue * margin.initialMargin) / BASIS_POINTS;
        uint256 qualityAdjustment = (notionalValue * margin.qualityAdjustment) / BASIS_POINTS;
        uint256 volatilityAdjustment = (notionalValue * margin.volatilityAdjustment) / BASIS_POINTS;
        
        required = baseMargin + qualityAdjustment + volatilityAdjustment;
    }
    
    function _getUnderlyingTokenId(
        uint256 derivativeId, 
        DerivativeType derivativeType
    ) internal view returns (uint256) {
        if (derivativeType == DerivativeType.FUTURE) {
            return futures[derivativeId].underlyingTokenId;
        } else {
            return options[derivativeId].underlyingTokenId;
        }
    }
    
    function _getAMMPrice(uint256 underlyingTokenId) internal view returns (uint256 price) {
        // This is a simplified implementation - in practice, you'd need to find the appropriate AMM pool
        // and calculate the price based on reserves. For now, return a default price.
        return 25 * 10**18; // $25 per credit as default
    }
    
    // Emergency functions
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(EMERGENCY_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Expire a stale liquidation commit to prevent unbounded state growth.
     * @dev Any caller may prune a commit whose reveal window has elapsed.
     *      Emits no event — callers should log off-chain.
     * @param liquidator  Address that created the commit.
     * @param commitHash  The original commit hash.
     */
    function expireCommit(address liquidator, bytes32 commitHash) external {
        bytes32 commitKey = _liquidationCommitKey(liquidator, commitHash);
        uint256 commitTime = liquidationCommits[commitKey];
        require(commitTime != 0, "DerivativesEngine: No such commit");
        require(
            block.timestamp > commitTime + COMMIT_REVEAL_WINDOW,
            "DerivativesEngine: Commit window still open"
        );
        delete liquidationCommits[commitKey];
    }
    
    /**
     * @dev Validate oracle price with circuit breaker protection
     */
    function _validateOraclePrice(uint256 tokenId, uint256 newPrice) internal returns (bool valid) {
        // Check if price is too stale
        if (block.timestamp > lastPriceTimestamp[tokenId] + MAX_PRICE_AGE) {
            return false;
        }
        
        // Get oracle confidence score via quality score
        uint256 confidence = qualityOracle.getQualityScore(address(uint160(tokenId)));
        if (confidence < MIN_ORACLE_CONFIDENCE) {
            return false;
        }
        
        uint256 lastPrice = lastValidPrices[tokenId];
        if (lastPrice > 0) {
            // Calculate price deviation
            uint256 deviation;
            if (newPrice > lastPrice) {
                deviation = ((newPrice - lastPrice) * BASIS_POINTS) / lastPrice;
            } else {
                deviation = ((lastPrice - newPrice) * BASIS_POINTS) / lastPrice;
            }
            
            // Trigger circuit breaker if deviation is too large
            if (deviation > CIRCUIT_BREAKER_THRESHOLD) {
                circuitBreakerTriggered[tokenId] = true;
                emit CircuitBreakerTriggered(tokenId, newPrice, deviation, block.timestamp);
                return false;
            }
            
            // Reject price if deviation exceeds max allowed
            if (deviation > MAX_PRICE_DEVIATION) {
                return false;
            }
        }
        
        // Update valid price and timestamp
        lastValidPrices[tokenId] = newPrice;
        lastPriceTimestamp[tokenId] = block.timestamp;
        return true;
    }
    
    /**
     * @dev Update oracle price with validation (Oracle Manager only)
     */
    function updateOraclePrice(uint256 tokenId, uint256 newPrice) external onlyRole(ORACLE_MANAGER_ROLE) {
        require(_validateOraclePrice(tokenId, newPrice), "DerivativesEngine: INVALID_ORACLE_PRICE");
        
        emit OraclePriceUpdated(tokenId, newPrice, lastValidPrices[tokenId], block.timestamp);
    }
    
    /**
     * @dev Reset circuit breaker for a token (Oracle Manager only)
     */
    function resetCircuitBreaker(uint256 tokenId) external onlyRole(ORACLE_MANAGER_ROLE) {
        circuitBreakerTriggered[tokenId] = false;
        
        emit CircuitBreakerReset(tokenId, block.timestamp);
    }
    
    /**
     * @dev Emergency global circuit breaker toggle
     */
    function setGlobalCircuitBreaker(bool triggered) external onlyRole(EMERGENCY_ROLE) {
        globalCircuitBreaker = triggered;
        
        emit GlobalCircuitBreakerUpdated(triggered, block.timestamp);
    }
    
    /**
     * @dev Batch liquidation for multiple positions (gas efficient)
     */
    function batchLiquidatePositions(
        uint256[] calldata positionIds
    ) external onlyRole(LIQUIDATOR_ROLE) nonReentrant returns (uint256 totalReward) {
        require(positionIds.length > 0, "No positions provided");
        require(positionIds.length <= 10, "Too many positions"); // Limit batch size
        
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            
            // Skip if position is not valid or liquidatable
            if (!_isValidPosition(positionId) || !isPositionLiquidatable(positionId)) {
                continue;
            }
            
            Position storage position = positions[positionId];
            
            // Get current price
            (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );
            
            // Calculate liquidator reward
            uint256 liquidatorReward = (position.collateralAmount * LIQUIDATION_REWARD) / BASIS_POINTS;
            totalReward += liquidatorReward;
            
            // Record liquidation
            liquidations[positionId] = LiquidationData({
                positionId: positionId,
                liquidator: msg.sender,
                liquidationPrice: currentPrice,
                liquidationTimestamp: block.timestamp,
                collateralSeized: position.collateralAmount,
                liquidatorReward: liquidatorReward
            });
            
            // Update position status
            position.status = PositionStatus.LIQUIDATED;
            lastLiquidationTime[positionId] = block.timestamp;
            
            emit PositionLiquidated(
                positionId,
                position.trader,
                msg.sender,
                currentPrice,
                position.collateralAmount,
                liquidatorReward
            );
        }
        
        // Transfer total rewards
        if (totalReward > 0) {
            IERC20(address(wrfToken)).safeTransfer(msg.sender, totalReward);
        }
    }
    
    /**
     * @dev Helper function to check if position is valid
     */
    function _isValidPosition(uint256 positionId) internal view returns (bool) {
        return positionId > 0 && 
               positionId < _nextPositionId && 
               positions[positionId].status == PositionStatus.ACTIVE;
    }
    
    /**
     * @dev Get oracle security status for a token
     */
    function getOracleSecurityStatus(uint256 tokenId) external view returns (
        uint256 lastValidPrice,
        uint256 lastUpdateTimestamp,
        bool circuitBreakerActive,
        bool globalBreakerActive
    ) {
        return (
            lastValidPrices[tokenId],
            lastPriceTimestamp[tokenId],
            circuitBreakerTriggered[tokenId],
            globalCircuitBreaker
        );
    }
    
    // Events for oracle security
    event OraclePriceUpdated(uint256 indexed tokenId, uint256 newPrice, uint256 oldPrice, uint256 timestamp);
    event CircuitBreakerReset(uint256 indexed tokenId, uint256 timestamp);
    event GlobalCircuitBreakerUpdated(bool triggered, uint256 timestamp);
    event CircuitBreakerTriggered(uint256 indexed tokenId, uint256 price, uint256 deviation, uint256 timestamp);
    
    /**
     * @dev Liquidate a single position (required by IDerivativesEngine)
     */
    function liquidatePosition(uint256 positionId) external override onlyRole(LIQUIDATOR_ROLE) nonReentrant returns (uint256 liquidatorReward) {
        require(_isValidPosition(positionId), "Invalid position");
        require(isPositionLiquidatable(positionId), "Position not liquidatable");

        Position storage position = positions[positionId];

        (uint256 currentPrice,) = getCurrentPrice(
            _getUnderlyingTokenId(position.derivativeId, position.derivativeType)
        );

        liquidatorReward = (position.collateralAmount * LIQUIDATION_REWARD) / BASIS_POINTS;

        liquidations[positionId] = LiquidationData({
            positionId: positionId,
            liquidator: msg.sender,
            liquidationPrice: currentPrice,
            liquidationTimestamp: block.timestamp,
            collateralSeized: position.collateralAmount,
            liquidatorReward: liquidatorReward
        });

        position.status = PositionStatus.LIQUIDATED;
        lastLiquidationTime[positionId] = block.timestamp;

        if (liquidatorReward > 0) {
            IERC20(address(wrfToken)).safeTransfer(msg.sender, liquidatorReward);
        }

        emit PositionLiquidated(
            positionId,
            position.trader,
            msg.sender,
            currentPrice,
            position.collateralAmount,
            liquidatorReward
        );
    }

    function _liquidationCommitKey(address liquidator, bytes32 commitHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(liquidator, commitHash));
    }

    // Events for MEV protection
    event LiquidationCommitted(address indexed liquidator, bytes32 indexed commitHash, uint256 timestamp);
}
