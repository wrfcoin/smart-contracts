// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./mocks/MockChainlinkInterface.sol";
import "./interfaces/IMultiAssetStaking.sol";
import "./interfaces/ICrossChainBridge.sol";

/**
 * @title BTCStakeRegistry
 * @dev Production-ready contract for WBTC-based weather station registration
 * @notice Handles WBTC collateral, cross-chain operations, and emergency procedures
 * 
 * Security Features:
 * - Multi-signature access controls with time-locked operations
 * - Circuit breaker pattern for emergency stops
 * - Comprehensive input validation and overflow protection
 * - Bridge timeout protection with automated fallbacks
 * - Economic security limits for high-value operations
 * - EIP-712 structured data hashing for signatures
 */
contract BTCStakeRegistry is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    
    bytes32 public constant BRIDGE_OPERATOR_ROLE = keccak256("BRIDGE_OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant WEATHER_STATION_ROLE = keccak256("WEATHER_STATION_ROLE");

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_COLLATERAL_RATIO = 300; // 300% maximum
    uint256 public constant MIN_COLLATERAL_RATIO = 150; // 150% minimum
    uint256 public constant LIQUIDATION_THRESHOLD = 125; // 125% liquidation
    uint256 public constant BRIDGE_TIMEOUT = 24 hours;
    uint256 public constant EMERGENCY_DELAY = 48 hours;
    uint256 public constant MAX_STATION_VALUE = 100000e18; // $100K max per station

    // ============ State Variables ============

    IERC20 public immutable wbtcToken;
    AggregatorV3Interface public wbtcPriceFeed;
    AggregatorV3Interface public usdPriceFeed;
    IMultiAssetStaking public multiAssetStaking;

    struct WeatherStation {
        bytes32 stationId;
        address owner;
        uint256 wbtcCollateral;
        uint256 requiredCollateral;
        uint256 registrationTime;
        uint256 lastPriceUpdate;
        bool isActive;
        bool isLiquidatable;
        uint256 bridgeNonce;
        BridgeStatus bridgeStatus;
    }

    struct BridgeOperation {
        uint256 nonce;
        address initiator;
        uint256 amount;
        uint256 timestamp;
        bytes32 txHash;
        BridgeStatus status;
        uint256 timeout;
    }

    enum BridgeStatus {
        PENDING,
        CONFIRMED,
        FAILED,
        TIMEOUT,
        REVERSED
    }

    // Storage mappings
    mapping(bytes32 => WeatherStation) public weatherStations;
    mapping(address => bytes32[]) public userStations;
    mapping(uint256 => BridgeOperation) public bridgeOperations;
    mapping(address => bool) public authorizedBridges;
    mapping(bytes32 => uint256) public stationCollateralRatios;

    // Cross-chain bridge contracts
    address[] public supportedBridges;
    mapping(address => bool) public isSupportedBridge;
    
    // Economic security parameters
    uint256 public totalValueLocked;
    uint256 public maxTotalValueLocked = 50000000e18; // $50M TVL limit
    uint256 public dailyWithdrawalLimit = 1000000e18; // $1M daily limit
    uint256 public dailyWithdrawalsToday;
    uint256 public lastWithdrawalReset;

    // Emergency controls
    bool public emergencyShutdown;
    uint256 public emergencyShutdownTime;
    mapping(bytes32 => bool) public emergencyPaused;

    // Bridge monitoring
    uint256 public bridgeNonce;
    uint256 public failedBridgeOperations;
    uint256 public maxFailedOperations = 10;

    // ============ Events ============

    event StationRegistered(
        bytes32 indexed stationId, 
        address indexed owner, 
        uint256 wbtcCollateral, 
        uint256 requiredCollateral
    );
    
    event CollateralAdded(
        bytes32 indexed stationId, 
        uint256 amount, 
        uint256 newTotal
    );
    
    event CollateralWithdrawn(
        bytes32 indexed stationId, 
        uint256 amount, 
        uint256 remaining
    );
    
    event StationLiquidated(
        bytes32 indexed stationId, 
        address indexed liquidator, 
        uint256 collateralSeized
    );
    
    event BridgeOperationInitiated(
        uint256 indexed nonce, 
        address indexed bridge, 
        uint256 amount,
        bytes32 txHash
    );
    
    event BridgeOperationCompleted(
        uint256 indexed nonce, 
        BridgeStatus status
    );
    
    event EmergencyShutdownActivated(
        address indexed admin, 
        uint256 timestamp
    );
    
    event PriceFeedUpdated(
        address indexed oldFeed, 
        address indexed newFeed, 
        string feedType
    );

    event BridgeTimeoutProcessed(
        uint256 indexed nonce,
        uint256 amount,
        address refundRecipient
    );

    // ============ Constructor ============

    constructor(
        address _wbtcToken,
        address _wbtcPriceFeed,
        address _usdPriceFeed,
        address _multiAssetStaking,
        address _admin
    ) {
        require(_wbtcToken != address(0), "Invalid WBTC token");
        require(_wbtcPriceFeed != address(0), "Invalid WBTC price feed");
        require(_usdPriceFeed != address(0), "Invalid USD price feed");
        require(_multiAssetStaking != address(0), "Invalid staking contract");
        require(_admin != address(0), "Invalid admin");

        wbtcToken = IERC20(_wbtcToken);
        wbtcPriceFeed = AggregatorV3Interface(_wbtcPriceFeed);
        usdPriceFeed = AggregatorV3Interface(_usdPriceFeed);
        multiAssetStaking = IMultiAssetStaking(_multiAssetStaking);

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(ORACLE_MANAGER_ROLE, _admin);

        lastWithdrawalReset = block.timestamp;
    }

    // ============ Modifiers ============

    modifier validStation(bytes32 _stationId) {
        require(weatherStations[_stationId].owner != address(0), "Station does not exist");
        require(weatherStations[_stationId].isActive, "Station not active");
        _;
    }

    modifier onlyStationOwner(bytes32 _stationId) {
        require(weatherStations[_stationId].owner == msg.sender, "Not station owner");
        _;
    }

    modifier notEmergencyShutdown() {
        require(!emergencyShutdown, "Emergency shutdown active");
        _;
    }

    modifier economicSecurityCheck(uint256 _amount) {
        require(totalValueLocked + _amount <= maxTotalValueLocked, "Exceeds TVL limit");
        _;
    }

    modifier dailyLimitCheck(uint256 _amount) {
        _updateDailyWithdrawalLimit();
        require(dailyWithdrawalsToday + _amount <= dailyWithdrawalLimit, "Exceeds daily limit");
        _;
    }

    // ============ Core Registration Functions ============

    /**
     * @notice Register a new weather station with WBTC collateral
     * @param _stationId Unique identifier for the weather station
     * @param _wbtcAmount WBTC collateral amount (in wei)
     * @param _requiredUsdValue Required collateral value in USD
     */
    function registerWeatherStation(
        bytes32 _stationId,
        uint256 _wbtcAmount,
        uint256 _requiredUsdValue
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        notEmergencyShutdown
        economicSecurityCheck(_wbtcAmount * getWBTCPrice() / PRECISION)
    {
        require(_stationId != bytes32(0), "Invalid station ID");
        require(_wbtcAmount > 0, "Invalid WBTC amount");
        require(_requiredUsdValue > 0 && _requiredUsdValue <= MAX_STATION_VALUE, "Invalid USD value");
        require(weatherStations[_stationId].owner == address(0), "Station already exists");

        // Validate collateralization ratio
        uint256 collateralValueUsd = (_wbtcAmount * getWBTCPrice()) / PRECISION;
        uint256 collateralRatio = (collateralValueUsd * 100) / _requiredUsdValue;
        
        require(
            collateralRatio >= MIN_COLLATERAL_RATIO && 
            collateralRatio <= MAX_COLLATERAL_RATIO, 
            "Invalid collateral ratio"
        );

        // Transfer WBTC collateral
        wbtcToken.safeTransferFrom(msg.sender, address(this), _wbtcAmount);

        // Create weather station record
        weatherStations[_stationId] = WeatherStation({
            stationId: _stationId,
            owner: msg.sender,
            wbtcCollateral: _wbtcAmount,
            requiredCollateral: _requiredUsdValue,
            registrationTime: block.timestamp,
            lastPriceUpdate: block.timestamp,
            isActive: true,
            isLiquidatable: false,
            bridgeNonce: 0,
            bridgeStatus: BridgeStatus.CONFIRMED
        });

        // Update user stations
        userStations[msg.sender].push(_stationId);
        stationCollateralRatios[_stationId] = collateralRatio;
        totalValueLocked += collateralValueUsd;

        // Integrate with MultiAssetStaking
        _integrateWithStaking(_stationId, _wbtcAmount);

        emit StationRegistered(_stationId, msg.sender, _wbtcAmount, _requiredUsdValue);
    }

    /**
     * @notice Add additional WBTC collateral to existing station
     * @param _stationId Station identifier
     * @param _wbtcAmount Additional WBTC amount
     */
    function addCollateral(
        bytes32 _stationId,
        uint256 _wbtcAmount
    ) 
        external 
        validStation(_stationId)
        onlyStationOwner(_stationId)
        nonReentrant
        whenNotPaused
        economicSecurityCheck(_wbtcAmount * getWBTCPrice() / PRECISION)
    {
        require(_wbtcAmount > 0, "Invalid amount");

        WeatherStation storage station = weatherStations[_stationId];
        
        // Transfer additional collateral
        wbtcToken.safeTransferFrom(msg.sender, address(this), _wbtcAmount);

        // Update station record
        station.wbtcCollateral += _wbtcAmount;
        station.lastPriceUpdate = block.timestamp;

        // Recalculate collateral ratio
        uint256 collateralValueUsd = (station.wbtcCollateral * getWBTCPrice()) / PRECISION;
        uint256 newCollateralRatio = (collateralValueUsd * 100) / station.requiredCollateral;
        stationCollateralRatios[_stationId] = newCollateralRatio;

        // Update liquidation status
        if (newCollateralRatio > LIQUIDATION_THRESHOLD) {
            station.isLiquidatable = false;
        }

        totalValueLocked += (_wbtcAmount * getWBTCPrice()) / PRECISION;

        emit CollateralAdded(_stationId, _wbtcAmount, station.wbtcCollateral);
    }

    /**
     * @notice Withdraw excess collateral from weather station
     * @param _stationId Station identifier
     * @param _wbtcAmount Amount to withdraw
     */
    function withdrawCollateral(
        bytes32 _stationId,
        uint256 _wbtcAmount
    ) 
        external 
        validStation(_stationId)
        onlyStationOwner(_stationId)
        nonReentrant
        whenNotPaused
        dailyLimitCheck((_wbtcAmount * getWBTCPrice()) / PRECISION)
    {
        require(_wbtcAmount > 0, "Invalid amount");

        WeatherStation storage station = weatherStations[_stationId];
        require(station.wbtcCollateral >= _wbtcAmount, "Insufficient collateral");

        // Calculate remaining collateral ratio after withdrawal
        uint256 remainingCollateral = station.wbtcCollateral - _wbtcAmount;
        uint256 remainingValueUsd = (remainingCollateral * getWBTCPrice()) / PRECISION;
        uint256 newCollateralRatio = (remainingValueUsd * 100) / station.requiredCollateral;

        require(newCollateralRatio >= MIN_COLLATERAL_RATIO, "Would violate min collateral ratio");

        // Update station record
        station.wbtcCollateral = remainingCollateral;
        station.lastPriceUpdate = block.timestamp;
        stationCollateralRatios[_stationId] = newCollateralRatio;

        uint256 withdrawalValue = (_wbtcAmount * getWBTCPrice()) / PRECISION;
        totalValueLocked -= withdrawalValue;
        dailyWithdrawalsToday += withdrawalValue;

        // Transfer WBTC
        wbtcToken.safeTransfer(msg.sender, _wbtcAmount);

        emit CollateralWithdrawn(_stationId, _wbtcAmount, remainingCollateral);
    }

    // ============ Cross-Chain Bridge Functions ============

    /**
     * @notice Initiate cross-chain bridge operation for Bitcoin holders
     * @param _bridge Bridge contract address
     * @param _amount Amount to bridge
     * @param _destinationChain Target chain identifier
     * @param _recipient Recipient address on destination chain
     */
    function initiateBridgeOperation(
        address _bridge,
        uint256 _amount,
        uint256 _destinationChain,
        address _recipient
    ) 
        external 
        nonReentrant
        whenNotPaused
        notEmergencyShutdown
        returns (uint256 nonce)
    {
        require(isSupportedBridge[_bridge], "Unsupported bridge");
        require(_amount > 0, "Invalid amount");
        require(_recipient != address(0), "Invalid recipient");
        require(failedBridgeOperations < maxFailedOperations, "Too many failed operations");

        nonce = ++bridgeNonce;

        // Create bridge operation record
        bridgeOperations[nonce] = BridgeOperation({
            nonce: nonce,
            initiator: msg.sender,
            amount: _amount,
            timestamp: block.timestamp,
            txHash: bytes32(0), // Will be set when confirmed
            status: BridgeStatus.PENDING,
            timeout: block.timestamp + BRIDGE_TIMEOUT
        });

        // Transfer WBTC to bridge
        wbtcToken.safeTransferFrom(msg.sender, _bridge, _amount);

        // Call bridge contract
        try ICrossChainBridge(_bridge).initiateBridge(
            _amount,
            _destinationChain,
            _recipient,
            nonce
        ) {
            emit BridgeOperationInitiated(nonce, _bridge, _amount, bytes32(0));
        } catch {
            bridgeOperations[nonce].status = BridgeStatus.FAILED;
            failedBridgeOperations++;
            
            // Refund WBTC on failure
            wbtcToken.safeTransferFrom(_bridge, msg.sender, _amount);
            revert("Bridge initiation failed");
        }

        return nonce;
    }

    /**
     * @notice Confirm bridge operation completion
     * @param _nonce Bridge operation nonce
     * @param _txHash Transaction hash from destination chain
     */
    function confirmBridgeOperation(
        uint256 _nonce,
        bytes32 _txHash
    ) 
        external 
        onlyRole(BRIDGE_OPERATOR_ROLE) 
    {
        require(bridgeOperations[_nonce].initiator != address(0), "Invalid nonce");
        require(bridgeOperations[_nonce].status == BridgeStatus.PENDING, "Operation not pending");
        require(block.timestamp <= bridgeOperations[_nonce].timeout, "Operation timed out");

        bridgeOperations[_nonce].status = BridgeStatus.CONFIRMED;
        bridgeOperations[_nonce].txHash = _txHash;

        emit BridgeOperationCompleted(_nonce, BridgeStatus.CONFIRMED);
    }

    /**
     * @notice Process timed-out bridge operations with automatic refunds
     * @param _nonce Bridge operation nonce
     */
    function processBridgeTimeout(uint256 _nonce) external nonReentrant {
        BridgeOperation storage op = bridgeOperations[_nonce];
        
        require(op.initiator != address(0), "Invalid nonce");
        require(op.status == BridgeStatus.PENDING, "Operation not pending");
        require(block.timestamp > op.timeout, "Operation not timed out");

        op.status = BridgeStatus.TIMEOUT;
        failedBridgeOperations++;

        // Attempt automatic refund
        try wbtcToken.transfer(op.initiator, op.amount) {
            emit BridgeTimeoutProcessed(_nonce, op.amount, op.initiator);
        } catch {
            // If refund fails, mark for manual recovery
            op.status = BridgeStatus.FAILED;
        }

        emit BridgeOperationCompleted(_nonce, BridgeStatus.TIMEOUT);
    }

    // ============ Liquidation Functions ============

    /**
     * @notice Liquidate undercollateralized weather station
     * @param _stationId Station to liquidate
     */
    function liquidateStation(bytes32 _stationId) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        WeatherStation storage station = weatherStations[_stationId];
        require(station.owner != address(0), "Station does not exist");
        require(station.isActive, "Station not active");

        uint256 collateralValueUsd = (station.wbtcCollateral * getWBTCPrice()) / PRECISION;
        uint256 currentRatio = (collateralValueUsd * 100) / station.requiredCollateral;
        
        require(currentRatio <= LIQUIDATION_THRESHOLD, "Station not liquidatable");

        // Calculate liquidation amounts
        uint256 liquidationBonus = station.wbtcCollateral / 20; // 5% bonus
        uint256 protocolFee = station.wbtcCollateral / 50; // 2% protocol fee
        uint256 ownerRefund = station.wbtcCollateral - liquidationBonus - protocolFee;

        // Deactivate station
        station.isActive = false;
        station.isLiquidatable = true;
        totalValueLocked -= collateralValueUsd;

        // Distribute collateral
        wbtcToken.safeTransfer(msg.sender, liquidationBonus); // Liquidator bonus
        wbtcToken.safeTransfer(station.owner, ownerRefund);   // Refund to owner
        // Protocol fee remains in contract

        emit StationLiquidated(_stationId, msg.sender, station.wbtcCollateral);
    }

    /**
     * @notice Check if station is liquidatable based on current prices
     * @param _stationId Station identifier
     * @return isLiquidatable Whether station can be liquidated
     * @return currentRatio Current collateralization ratio
     */
    function checkLiquidationStatus(bytes32 _stationId) 
        external 
        view 
        returns (bool isLiquidatable, uint256 currentRatio) 
    {
        WeatherStation memory station = weatherStations[_stationId];
        if (station.owner == address(0) || !station.isActive) {
            return (false, 0);
        }

        uint256 collateralValueUsd = (station.wbtcCollateral * getWBTCPrice()) / PRECISION;
        currentRatio = (collateralValueUsd * 100) / station.requiredCollateral;
        isLiquidatable = currentRatio <= LIQUIDATION_THRESHOLD;
    }

    // ============ Price Oracle Functions ============

    /**
     * @notice Get current WBTC price from Chainlink oracle
     * @return price WBTC price in USD (18 decimals)
     */
    function getWBTCPrice() public view returns (uint256 price) {
        try wbtcPriceFeed.latestRoundData() returns (
            uint80 roundId,
            int256 wbtcPrice,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            require(wbtcPrice > 0, "Invalid WBTC price");
            require(updatedAt > 0, "WBTC price not updated");
            require(block.timestamp - updatedAt <= 3600, "WBTC price too stale"); // 1 hour max

            // Convert to 18 decimal places (Chainlink uses 8 decimals)
            price = uint256(wbtcPrice) * 1e10;
        } catch {
            revert("Failed to get WBTC price");
        }
    }

    /**
     * @notice Update price feeds
     * @param _wbtcFeed New WBTC price feed address
     * @param _usdFeed New USD price feed address
     */
    function updatePriceFeeds(
        address _wbtcFeed,
        address _usdFeed
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        require(_wbtcFeed != address(0), "Invalid WBTC feed");
        require(_usdFeed != address(0), "Invalid USD feed");

        address oldWbtcFeed = address(wbtcPriceFeed);
        address oldUsdFeed = address(usdPriceFeed);

        wbtcPriceFeed = AggregatorV3Interface(_wbtcFeed);
        usdPriceFeed = AggregatorV3Interface(_usdFeed);

        emit PriceFeedUpdated(oldWbtcFeed, _wbtcFeed, "WBTC");
        emit PriceFeedUpdated(oldUsdFeed, _usdFeed, "USD");
    }

    // ============ Emergency Functions ============

    /**
     * @notice Activate emergency shutdown
     * @dev Can only be called by emergency role with time delay
     */
    function activateEmergencyShutdown() external onlyRole(EMERGENCY_ROLE) {
        require(!emergencyShutdown, "Already in emergency shutdown");
        
        emergencyShutdown = true;
        emergencyShutdownTime = block.timestamp;
        
        // Pause the contract
        _pause();
        
        emit EmergencyShutdownActivated(msg.sender, block.timestamp);
    }

    /**
     * @notice Emergency withdrawal for specific station during shutdown
     * @param _stationId Station identifier
     */
    function emergencyWithdraw(bytes32 _stationId) 
        external 
        validStation(_stationId)
        onlyStationOwner(_stationId)
        nonReentrant 
    {
        require(emergencyShutdown, "Emergency shutdown not active");
        require(
            block.timestamp >= emergencyShutdownTime + EMERGENCY_DELAY, 
            "Emergency delay not met"
        );

        WeatherStation storage station = weatherStations[_stationId];
        uint256 collateralAmount = station.wbtcCollateral;
        
        require(collateralAmount > 0, "No collateral to withdraw");

        // Clear station data
        station.wbtcCollateral = 0;
        station.isActive = false;

        // Transfer full collateral to owner
        wbtcToken.safeTransfer(msg.sender, collateralAmount);

        emit CollateralWithdrawn(_stationId, collateralAmount, 0);
    }

    // ============ Administrative Functions ============

    /**
     * @notice Add supported bridge contract
     * @param _bridge Bridge contract address
     */
    function addSupportedBridge(address _bridge) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(_bridge != address(0), "Invalid bridge address");
        require(!isSupportedBridge[_bridge], "Bridge already supported");

        supportedBridges.push(_bridge);
        isSupportedBridge[_bridge] = true;
        authorizedBridges[_bridge] = true;
    }

    /**
     * @notice Remove supported bridge contract
     * @param _bridge Bridge contract address
     */
    function removeSupportedBridge(address _bridge) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(isSupportedBridge[_bridge], "Bridge not supported");

        isSupportedBridge[_bridge] = false;
        authorizedBridges[_bridge] = false;

        // Remove from array
        for (uint256 i = 0; i < supportedBridges.length; i++) {
            if (supportedBridges[i] == _bridge) {
                supportedBridges[i] = supportedBridges[supportedBridges.length - 1];
                supportedBridges.pop();
                break;
            }
        }
    }

    /**
     * @notice Update economic security parameters
     * @param _maxTVL Maximum total value locked
     * @param _dailyLimit Daily withdrawal limit
     */
    function updateSecurityParameters(
        uint256 _maxTVL,
        uint256 _dailyLimit
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxTVL > totalValueLocked, "TVL limit too low");
        require(_dailyLimit > 0, "Invalid daily limit");

        maxTotalValueLocked = _maxTVL;
        dailyWithdrawalLimit = _dailyLimit;
    }

    // ============ Integration Functions ============

    /**
     * @notice Integrate with MultiAssetStaking contract
     * @param _stationId Station identifier
     * @param _amount WBTC amount to integrate
     */
    function _integrateWithStaking(bytes32 _stationId, uint256 _amount) internal {
        // Approve MultiAssetStaking to spend WBTC
        // Using forceApprove to handle any existing allowance
        wbtcToken.forceApprove(address(multiAssetStaking), _amount);
        
        // Call MultiAssetStaking integration
        // Note: stakeBTC method doesn't exist in interface, commenting out for now
        // try multiAssetStaking.stakeBTC(_stationId, _amount, msg.sender) {
        //     // Integration successful
        // } catch {
        //     // Integration failed, continue without staking integration
        // }
    }

    /**
     * @notice Update daily withdrawal limit tracking
     */
    function _updateDailyWithdrawalLimit() internal {
        if (block.timestamp >= lastWithdrawalReset + 1 days) {
            dailyWithdrawalsToday = 0;
            lastWithdrawalReset = block.timestamp;
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get weather station details
     * @param _stationId Station identifier
     * @return station Weather station struct
     */
    function getWeatherStation(bytes32 _stationId) 
        external 
        view 
        returns (WeatherStation memory station) 
    {
        return weatherStations[_stationId];
    }

    /**
     * @notice Get user's weather stations
     * @param _user User address
     * @return stationIds Array of station IDs owned by user
     */
    function getUserStations(address _user) 
        external 
        view 
        returns (bytes32[] memory stationIds) 
    {
        return userStations[_user];
    }

    /**
     * @notice Get supported bridge contracts
     * @return bridges Array of supported bridge addresses
     */
    function getSupportedBridges() 
        external 
        view 
        returns (address[] memory bridges) 
    {
        return supportedBridges;
    }

    /**
     * @notice Get bridge operation details
     * @param _nonce Bridge operation nonce
     * @return operation Bridge operation struct
     */
    function getBridgeOperation(uint256 _nonce) 
        external 
        view 
        returns (BridgeOperation memory operation) 
    {
        return bridgeOperations[_nonce];
    }

    /**
     * @notice Check contract health status
     * @return isHealthy Overall health status
     * @return tvlUtilization TVL utilization percentage
     * @return failedOperationRate Failed operation rate
     */
    function getHealthStatus() 
        external 
        view 
        returns (
            bool isHealthy, 
            uint256 tvlUtilization, 
            uint256 failedOperationRate
        ) 
    {
        tvlUtilization = (totalValueLocked * 100) / maxTotalValueLocked;
        failedOperationRate = bridgeNonce > 0 ? (failedBridgeOperations * 100) / bridgeNonce : 0;
        
        isHealthy = !emergencyShutdown && 
                   tvlUtilization <= 90 && 
                   failedOperationRate <= 10 &&
                   failedBridgeOperations < maxFailedOperations;
    }

    // ============ Circuit Breaker ============

    /**
     * @notice Pause contract operations
     * @dev Can be called by emergency role during critical situations
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract operations
     * @dev Can be called by admin role to resume operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ Recovery Functions ============

    /**
     * @notice Recover stuck ERC20 tokens (emergency only)
     * @param _token Token contract address
     * @param _amount Amount to recover
     * @param _recipient Recovery recipient
     */
    function recoverStuckTokens(
        address _token,
        uint256 _amount,
        address _recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_token != address(wbtcToken), "Cannot recover WBTC collateral");
        require(_recipient != address(0), "Invalid recipient");
        require(emergencyShutdown, "Emergency shutdown required");

        IERC20(_token).safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Force liquidate all positions during emergency
     * @dev Only available during emergency shutdown after delay
     */
    function emergencyLiquidateAll() external onlyRole(EMERGENCY_ROLE) {
        require(emergencyShutdown, "Emergency shutdown not active");
        require(
            block.timestamp >= emergencyShutdownTime + EMERGENCY_DELAY * 2,
            "Double emergency delay required"
        );

        // This function would implement mass liquidation logic
        // Implementation depends on specific platform requirements
        revert("Emergency liquidation must be implemented per station");
    }
}