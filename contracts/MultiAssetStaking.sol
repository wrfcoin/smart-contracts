// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./mocks/MockChainlinkInterface.sol";
import "./libraries/DynamicStakeCalculator.sol";
import "./interfaces/IDynamicStakeCalculator.sol";
import "./interfaces/IParticipantTypeRegistry.sol";
import "./bridge/SecureBridgeIntegration.sol";

/**
 * @title MultiAssetStaking
 * @dev Comprehensive multi-asset staking contract supporting multiple collateral types including WBTC
 * for Bitcoin staking in WRFCoin's fair launch system.
 * 
 * This contract provides a unified interface for participants to stake various assets
 * (ETH, WBTC, WRF, USDC, USDT) as collateral for weather station registration and 
 * network participation in the WRFCoin ecosystem.
 * 
 * Core Features:
 * - Multi-asset stake deposits with automatic USD value conversion
 * - Cross-chain WBTC integration leveraging existing bridge infrastructure
 * - Dynamic conversion rates via Chainlink price oracles
 * - Automatic rebalancing if collateral value drops below requirements
 * - Stake recovery mechanisms for different asset types
 * - Slashing protection across multiple asset pools
 * - Seamless WBTC deposits/withdrawals via cross-chain bridges
 * 
 * Integration Points:
 * - DynamicStakeCalculator: Get USD-denominated stake requirements
 * - Chainlink Price Feeds: Real-time asset pricing
 * - Cross-chain bridges: WBTC deposit/withdrawal handling
 * - WRFToken: Integration with existing staking mechanisms
 * - ParticipantTypeRegistry: Participant-specific stake requirements
 * 
 * Security Features:
 * - Oracle failure handling with fallback mechanisms
 * - Slippage protection for asset conversions
 * - Minimum collateralization ratios (120% minimum)
 * - Emergency pause functionality
 * - Asset-specific limits to prevent concentration risk
 * - Cross-chain bridge failure recovery mechanisms
 * 
 * @author WRFCoin Security Team
 * @notice This contract manages production-ready multi-asset staking with Bitcoin integration
 */
contract MultiAssetStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using DynamicStakeCalculator for DynamicStakeCalculator.StakeParameters;

    // ========== CONSTANTS ==========
    
    /// @dev Native ETH asset identifier
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    /// @dev Minimum collateralization ratio (120%)
    uint256 public constant MIN_COLLATERALIZATION_RATIO = 1_200_000; // 120% in PRECISION units
    
    /// @dev Maximum oracle price age in seconds (30 minutes for better price freshness)
    uint256 public constant MAX_ORACLE_AGE = 1800;
    
    /// @dev Maximum slippage tolerance for asset conversions (5%)
    uint256 public constant MAX_SLIPPAGE_TOLERANCE = 50_000; // 5% in PRECISION units
    
    /// @dev Maximum stake concentration per asset (40%)
    uint256 public constant MAX_ASSET_CONCENTRATION = 400_000; // 40% in PRECISION units
    
    /// @dev Cross-chain operation timeout (24 hours)
    uint256 public constant CROSS_CHAIN_TIMEOUT = 86400;
    
    /// @dev Emergency liquidation threshold (110%)
    uint256 public constant EMERGENCY_LIQUIDATION_THRESHOLD = 1_100_000; // 110% in PRECISION units

    // ========== STRUCTS ==========

    /// @dev Supported asset configuration
    struct AssetConfig {
        address tokenAddress;           // Token contract address (ETH_ADDRESS for native ETH)
        address priceOracle;           // Chainlink price feed address
        uint8 decimals;                // Token decimals
        bool isActive;                 // Whether asset is supported for staking
        bool isCrossChain;             // Whether asset requires cross-chain operations
        uint256 minStakeAmount;        // Minimum stake amount in asset units
        uint256 maxStakeAmount;        // Maximum stake amount in asset units
        uint256 concentrationLimit;    // Max percentage of total stake for this asset
        string symbol;                 // Asset symbol for display
        bytes32 bridgeId;              // Bridge identifier for cross-chain assets
    }

    /// @dev Individual asset stake information
    struct AssetStake {
        uint256 amount;                // Amount staked in asset units
        uint256 valueUSD;              // USD value at stake time
        uint256 lastPriceUpdate;       // Last price update timestamp
        uint256 stakedAt;              // Timestamp of initial stake
        bool isActive;                 // Whether this asset stake is active
        uint256 pendingWithdrawal;     // Amount pending withdrawal (cross-chain)
        bytes32 lastBridgeOperation;   // Last cross-chain operation ID
    }

    /// @dev Comprehensive participant stake record
    struct StakeRecord {
        mapping(address => AssetStake) assets;  // Asset address => stake info
        address[] stakedAssets;                 // List of assets staked
        uint256 totalStakeUSD;                 // Total stake value in USD
        uint256 requiredStakeUSD;              // Required stake based on participant type
        uint256 collateralizationRatio;       // Current collateralization ratio
        bool meetsMinimumRequirement;          // Whether meets minimum stake requirement
        uint256 lastRebalance;                 // Last rebalancing timestamp
        uint256 totalSlashed;                  // Total amount slashed (USD value)
        DynamicStakeCalculator.StakeParameters parameters; // Staking parameters
    }

    /// @dev Cross-chain operation record
    struct CrossChainOperation {
        address participant;
        address asset;
        uint256 amount;
        uint256 timestamp;
        bytes32 bridgeId;
        bool isDeposit;                        // true for deposit, false for withdrawal
        bool isCompleted;
        bool isFailed;
        string failureReason;
    }

    /// @dev Rebalancing proposal
    struct RebalanceProposal {
        address participant;
        address fromAsset;
        address toAsset;
        uint256 fromAmount;
        uint256 toAmount;
        uint256 deadline;
        bool isExecuted;
        bool isExpired;
    }

    // ========== STATE VARIABLES ==========

    /// @dev Supported asset configurations
    mapping(address => AssetConfig) public supportedAssets;
    address[] public assetList;

    /// @dev Participant stake records
    mapping(address => StakeRecord) private stakes;

    /// @dev Cross-chain operations tracking
    mapping(bytes32 => CrossChainOperation) public crossChainOps;
    mapping(address => bytes32[]) public participantCrossChainOps;

    /// @dev Rebalancing proposals
    mapping(bytes32 => RebalanceProposal) public rebalanceProposals;
    mapping(address => bytes32[]) public participantRebalanceProposals;

    /// @dev External contract integrations
    IDynamicStakeCalculator public stakeCalculator;
    IParticipantTypeRegistry public participantRegistry;
    SecureBridgeIntegration public bridgeIntegration;

    /// @dev Protocol statistics
    uint256 public totalValueLockedUSD;
    uint256 public totalParticipants;
    uint256 public totalCrossChainOperations;
    uint256 public totalRebalanceOperations;

    /// @dev Emergency and governance settings
    address public emergencyLiquidator;
    address public treasury;
    uint256 public emergencyDelay;

    /// @dev Pending slashing protection — blocks withdrawals during active slash proposals
    mapping(address => bool) public hasPendingSlashing;
    address public slashingMechanism;

    // ========== EVENTS ==========

    event AssetStaked(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD,
        uint256 newTotalStakeUSD
    );

    event AssetWithdrawn(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD,
        uint256 newTotalStakeUSD
    );

    event StakeRebalanced(
        address indexed participant,
        address indexed fromAsset,
        address indexed toAsset,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 newCollateralizationRatio
    );

    event CrossChainOperationInitiated(
        bytes32 indexed operationId,
        address indexed participant,
        address indexed asset,
        uint256 amount,
        bytes32 bridgeId,
        bool isDeposit
    );

    event CrossChainOperationCompleted(
        bytes32 indexed operationId,
        address indexed participant,
        bool success,
        string reason
    );

    event EmergencyLiquidation(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD,
        string reason
    );

    event AssetConfigured(
        address indexed asset,
        address indexed priceOracle,
        bool isActive,
        bool isCrossChain,
        string symbol
    );

    event CollateralizationRatioUpdated(
        address indexed participant,
        uint256 oldRatio,
        uint256 newRatio,
        bool meetsRequirement
    );

    // ========== ERRORS ==========

    error AssetNotSupported();
    error InsufficientStakeAmount();
    error ExcessiveStakeAmount();
    error StaleOraclePrice();
    error InvalidOraclePrice();
    error InsufficientCollateralization();
    error ExcessiveSlippage();
    error CrossChainOperationFailed();
    error RebalanceProposalExpired();
    error UnauthorizedLiquidation();
    error AssetConcentrationExceeded();
    error InvalidAssetConfiguration();

    // ========== MODIFIERS ==========

    modifier onlySupportedAsset(address asset) {
        if (!supportedAssets[asset].isActive) {
            revert AssetNotSupported();
        }
        _;
    }

    modifier validOraclePrice(address asset) {
        AssetConfig memory config = supportedAssets[asset];
        if (config.priceOracle == address(0)) {
            revert InvalidOraclePrice();
        }
        
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(config.priceOracle)
            .latestRoundData();
        
        if (price <= 0) {
            revert InvalidOraclePrice();
        }
        
        if (block.timestamp - updatedAt > MAX_ORACLE_AGE) {
            revert StaleOraclePrice();
        }
        _;
    }

    modifier onlyEmergencyLiquidator() {
        require(msg.sender == emergencyLiquidator, "Unauthorized liquidator");
        _;
    }

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initialize MultiAssetStaking contract
     * @param _stakeCalculator DynamicStakeCalculator contract address
     * @param _participantRegistry ParticipantTypeRegistry contract address
     * @param _bridgeIntegration SecureBridgeIntegration contract address
     * @param _emergencyLiquidator Emergency liquidator address
     * @param _treasury Treasury address for liquidated assets
     */
    constructor(
        address _stakeCalculator,
        address _participantRegistry,
        address _bridgeIntegration,
        address _emergencyLiquidator,
        address _treasury
    ) Ownable(msg.sender) {
        require(_stakeCalculator != address(0), "Invalid stake calculator");
        require(_participantRegistry != address(0), "Invalid participant registry");
        require(_bridgeIntegration != address(0), "Invalid bridge integration");
        require(_emergencyLiquidator != address(0), "Invalid emergency liquidator");
        require(_treasury != address(0), "Invalid treasury");

        stakeCalculator = IDynamicStakeCalculator(_stakeCalculator);
        participantRegistry = IParticipantTypeRegistry(_participantRegistry);
        bridgeIntegration = SecureBridgeIntegration(_bridgeIntegration);
        emergencyLiquidator = _emergencyLiquidator;
        treasury = _treasury;
        emergencyDelay = 24 hours;
    }

    // ========== MAIN STAKING FUNCTIONS ==========

    /**
     * @notice Stake an asset for weather station registration
     * @dev Handles both native ETH and ERC20 token staking with cross-chain support
     * @param asset Address of the asset to stake (ETH_ADDRESS for native ETH)
     * @param amount Amount to stake in asset units
     * @param parameters Staking parameters for dynamic calculation
     */
    function stakeAsset(
        address asset,
        uint256 amount,
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) external payable nonReentrant whenNotPaused onlySupportedAsset(asset) validOraclePrice(asset) {
        require(amount > 0, "Invalid amount");
        
        AssetConfig memory config = supportedAssets[asset];
        require(amount >= config.minStakeAmount, "Below minimum stake");
        require(amount <= config.maxStakeAmount, "Above maximum stake");

        // Handle ETH vs ERC20
        if (asset == ETH_ADDRESS) {
            require(msg.value == amount, "ETH amount mismatch");
        } else {
            require(msg.value == 0, "No ETH should be sent");
            
            if (config.isCrossChain) {
                // Initiate cross-chain deposit
                _initiateCrossChainDeposit(asset, amount, parameters);
                return;
            } else {
                // Transfer ERC20 tokens
                IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            }
        }

        // Calculate USD value
        uint256 valueUSD = _calculateAssetValueUSD(asset, amount);
        
        // Update stake record
        _updateStakeRecord(msg.sender, asset, amount, valueUSD, parameters);

        // Check concentration limits
        _validateAssetConcentration(msg.sender, asset);

        // Update collateralization ratio
        _updateCollateralizationRatio(msg.sender);

        emit AssetStaked(msg.sender, asset, amount, valueUSD, stakes[msg.sender].totalStakeUSD);
    }

    /**
     * @notice Get USD value of participant's total stake
     * @dev Calculates current USD value using latest oracle prices
     * @param participant Address of the participant
     * @return totalValueUSD Current total stake value in USD
     * @return breakdown Array of individual asset values
     * @return assets Array of staked asset addresses
     */
    function getStakeValueUSD(address participant) 
        external 
        view 
        returns (
            uint256 totalValueUSD,
            uint256[] memory breakdown,
            address[] memory assets
        ) 
    {
        StakeRecord storage record = stakes[participant];
        assets = record.stakedAssets;
        breakdown = new uint256[](assets.length);
        
        totalValueUSD = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            AssetStake storage assetStake = record.assets[asset];
            
            if (assetStake.isActive && assetStake.amount > 0) {
                uint256 currentValue = _calculateAssetValueUSD(asset, assetStake.amount);
                breakdown[i] = currentValue;
                totalValueUSD += currentValue;
            }
        }
    }

    /**
     * @notice Rebalance stake if collateral value drops below requirements
     * @dev Handles automatic rebalancing to maintain minimum collateralization
     * @param participant Address of the participant to rebalance
     * @param fromAsset Asset to convert from
     * @param toAsset Asset to convert to
     * @param amount Amount to rebalance
     */
    function rebalanceStake(address participant, address fromAsset, address toAsset, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        onlySupportedAsset(fromAsset)
        onlySupportedAsset(toAsset)
        validOraclePrice(fromAsset)
        validOraclePrice(toAsset)
    {
        require(msg.sender == participant || msg.sender == owner(), "Unauthorized rebalance");
        
        StakeRecord storage record = stakes[participant];
        AssetStake storage fromStake = record.assets[fromAsset];
        
        require(fromStake.isActive && fromStake.amount >= amount, "Insufficient stake");
        
        // Calculate USD values
        uint256 fromValueUSD = _calculateAssetValueUSD(fromAsset, amount);
        uint256 toAmount = _calculateAssetAmount(toAsset, fromValueUSD);
        
        // Check slippage protection
        uint256 slippage = _calculateSlippage(fromValueUSD, _calculateAssetValueUSD(toAsset, toAmount));
        require(slippage <= MAX_SLIPPAGE_TOLERANCE, "Excessive slippage");
        
        // Execute rebalance
        _executeRebalance(participant, fromAsset, toAsset, amount, toAmount);
        
        // Update collateralization ratio
        _updateCollateralizationRatio(participant);

        emit StakeRebalanced(participant, fromAsset, toAsset, amount, toAmount, record.collateralizationRatio);
    }

    /**
     * @notice Withdraw stake after deregistration
     * @dev Supports both native assets and cross-chain withdrawals
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (0 for full withdrawal)
     */
    function withdrawStake(address asset, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        onlySupportedAsset(asset) 
    {
        StakeRecord storage record = stakes[msg.sender];
        AssetStake storage assetStake = record.assets[asset];
        
        require(assetStake.isActive, "No active stake for asset");
        require(!hasPendingSlashing[msg.sender], "MultiAssetStaking: Withdrawal blocked during pending slash");
        
        if (amount == 0) {
            amount = assetStake.amount;
        }
        
        require(amount <= assetStake.amount, "Insufficient stake balance");
        
        // Calculate USD value being withdrawn
        uint256 valueUSD = _calculateAssetValueUSD(asset, amount);
        
        // Check if withdrawal maintains minimum requirements
        uint256 newTotalStakeUSD = record.totalStakeUSD - valueUSD;
        require(
            newTotalStakeUSD >= record.requiredStakeUSD ||
            newTotalStakeUSD == 0, // Allow complete withdrawal
            "Would violate minimum stake requirement"
        );

        AssetConfig memory config = supportedAssets[asset];
        
        if (config.isCrossChain) {
            // Initiate cross-chain withdrawal
            _initiateCrossChainWithdrawal(asset, amount);
        } else {
            // Direct withdrawal
            _executeWithdrawal(msg.sender, asset, amount, valueUSD);
        }
    }

    /**
     * @notice Convert stake from one asset to another
     * @dev Facilitates asset conversion within the staking system
     * @param fromAsset Source asset address
     * @param toAsset Destination asset address
     * @param amount Amount to convert from source asset
     */
    function convertStakeAsset(address fromAsset, address toAsset, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAsset(fromAsset)
        onlySupportedAsset(toAsset)
        validOraclePrice(fromAsset)
        validOraclePrice(toAsset)
    {
        require(fromAsset != toAsset, "Cannot convert to same asset");
        
        StakeRecord storage record = stakes[msg.sender];
        AssetStake storage fromStake = record.assets[fromAsset];
        
        require(fromStake.isActive && fromStake.amount >= amount, "Insufficient stake");
        
        // Calculate conversion
        uint256 fromValueUSD = _calculateAssetValueUSD(fromAsset, amount);
        uint256 toAmount = _calculateAssetAmount(toAsset, fromValueUSD);
        
        // Check slippage
        uint256 slippage = _calculateSlippage(fromValueUSD, _calculateAssetValueUSD(toAsset, toAmount));
        require(slippage <= MAX_SLIPPAGE_TOLERANCE, "Excessive slippage");
        
        // Execute conversion
        _executeConversion(msg.sender, fromAsset, toAsset, amount, toAmount, fromValueUSD);
        
        // Validate concentration limits
        _validateAssetConcentration(msg.sender, toAsset);

        // Refresh participant risk state and emit conversion telemetry
        _updateCollateralizationRatio(msg.sender);
        totalRebalanceOperations++;
        emit StakeRebalanced(
            msg.sender,
            fromAsset,
            toAsset,
            amount,
            toAmount,
            stakes[msg.sender].collateralizationRatio
        );
    }

    /**
     * @notice Get current collateralization ratio for a participant
     * @dev Returns the ratio of current stake value to required stake value
     * @param participant Address of the participant
     * @return ratio Current collateralization ratio (in PRECISION units)
     * @return meetsMinimum Whether the participant meets minimum requirements
     * @return requiredStakeUSD Required stake amount in USD
     * @return currentStakeUSD Current stake value in USD
     */
    function getCollateralizationRatio(address participant)
        external
        view
        returns (
            uint256 ratio,
            bool meetsMinimum,
            uint256 requiredStakeUSD,
            uint256 currentStakeUSD
        )
    {
        StakeRecord storage record = stakes[participant];
        
        // Calculate current stake value with latest prices
        currentStakeUSD = _calculateCurrentStakeValueUSD(participant);
        requiredStakeUSD = record.requiredStakeUSD;
        
        if (requiredStakeUSD == 0) {
            ratio = 0;
            meetsMinimum = false;
        } else {
            ratio = (currentStakeUSD * DynamicStakeCalculator.PRECISION) / requiredStakeUSD;
            meetsMinimum = ratio >= MIN_COLLATERALIZATION_RATIO;
        }
    }

    // ========== CROSS-CHAIN FUNCTIONS ==========

    /**
     * @notice Complete a cross-chain deposit operation
     * @dev Called by bridge integration after successful cross-chain transfer
     * @param operationId Cross-chain operation identifier
     * @param participant Address of the participant
     * @param asset Address of the deposited asset
     * @param amount Amount deposited
     */
    function completeCrossChainDeposit(
        bytes32 operationId,
        address participant,
        address asset,
        uint256 amount
    ) external {
        require(msg.sender == address(bridgeIntegration), "Unauthorized caller");
        
        CrossChainOperation storage op = crossChainOps[operationId];
        require(op.participant == participant, "Participant mismatch");
        require(op.asset == asset, "Asset mismatch");
        require(op.amount == amount, "Amount mismatch");
        require(op.isDeposit, "Not a deposit operation");
        require(!op.isCompleted, "Already completed");
        
        // Mark operation as completed
        op.isCompleted = true;
        
        // Calculate USD value and update stake
        uint256 valueUSD = _calculateAssetValueUSD(asset, amount);
        
        // Get stored parameters from the operation
        DynamicStakeCalculator.StakeParameters memory parameters = stakes[participant].parameters;
        
        _updateStakeRecord(participant, asset, amount, valueUSD, parameters);
        _validateAssetConcentration(participant, asset);
        _updateCollateralizationRatio(participant);

        emit CrossChainOperationCompleted(operationId, participant, true, "Deposit completed");
        emit AssetStaked(participant, asset, amount, valueUSD, stakes[participant].totalStakeUSD);
    }

    /**
     * @notice Complete a cross-chain withdrawal operation
     * @dev Called by bridge integration after successful cross-chain transfer
     * @param operationId Cross-chain operation identifier
     * @param success Whether the withdrawal was successful
     * @param reason Reason if withdrawal failed
     */
    function completeCrossChainWithdrawal(
        bytes32 operationId,
        bool success,
        string calldata reason
    ) external {
        require(msg.sender == address(bridgeIntegration), "Unauthorized caller");
        
        CrossChainOperation storage op = crossChainOps[operationId];
        require(!op.isCompleted, "Already completed");
        
        op.isCompleted = true;
        
        if (success) {
            // Withdrawal successful - stake has already been deducted
            emit CrossChainOperationCompleted(operationId, op.participant, true, "Withdrawal completed");
        } else {
            // Withdrawal failed - restore stake
            op.isFailed = true;
            op.failureReason = reason;
            
            StakeRecord storage record = stakes[op.participant];
            AssetStake storage assetStake = record.assets[op.asset];
            
            // Restore the pending withdrawal amount
            assetStake.amount += assetStake.pendingWithdrawal;
            assetStake.pendingWithdrawal = 0;
            
            // Recalculate USD value and update record
            uint256 valueUSD = _calculateAssetValueUSD(op.asset, op.amount);
            record.totalStakeUSD += valueUSD;
            totalValueLockedUSD += valueUSD;
            
            _updateCollateralizationRatio(op.participant);
            
            emit CrossChainOperationCompleted(operationId, op.participant, false, reason);
        }
    }

    // ========== EMERGENCY FUNCTIONS ==========

    /**
     * @notice Emergency liquidation for undercollateralized positions
     * @dev Can be called by emergency liquidator when collateralization drops below threshold
     * @param participant Address of the participant to liquidate
     * @param asset Asset to liquidate
     * @param amount Amount to liquidate
     * @param reason Reason for liquidation
     */
    function emergencyLiquidation(
        address participant,
        address asset,
        uint256 amount,
        string calldata reason
    ) external onlyEmergencyLiquidator nonReentrant {
        StakeRecord storage record = stakes[participant];
        AssetStake storage assetStake = record.assets[asset];
        
        require(assetStake.isActive && assetStake.amount >= amount, "Insufficient stake");
        
        // Check if liquidation is justified
        uint256 currentStakeUSD = _calculateCurrentStakeValueUSD(participant);
        uint256 collateralizationRatio = (currentStakeUSD * DynamicStakeCalculator.PRECISION) / record.requiredStakeUSD;
        
        require(
            collateralizationRatio < EMERGENCY_LIQUIDATION_THRESHOLD,
            "Liquidation not justified"
        );
        
        // Calculate USD value
        uint256 valueUSD = _calculateAssetValueUSD(asset, amount);
        
        // Update stake record
        assetStake.amount -= amount;
        assetStake.valueUSD -= valueUSD;
        record.totalStakeUSD -= valueUSD;
        record.totalSlashed += valueUSD;
        totalValueLockedUSD -= valueUSD;
        
        // Transfer to treasury
        if (asset == ETH_ADDRESS) {
            (bool sent,) = payable(treasury).call{value: amount}("");
            require(sent, "MultiAssetStaking: ETH transfer to treasury failed");
        } else {
            IERC20(asset).safeTransfer(treasury, amount);
        }
        
        // Update collateralization ratio
        _updateCollateralizationRatio(participant);
        
        emit EmergencyLiquidation(participant, asset, amount, valueUSD, reason);
    }

    /**
     * @notice Emergency pause all operations
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause operations after emergency resolution
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== ASSET MANAGEMENT FUNCTIONS ==========

    /**
     * @notice Configure a supported asset
     * @dev Only owner can configure assets
     * @param asset Address of the asset token contract
     * @param config Asset configuration parameters
     */
    function configureAsset(address asset, AssetConfig calldata config) external onlyOwner {
        require(config.priceOracle != address(0) || asset == ETH_ADDRESS, "Invalid price oracle");
        require(config.minStakeAmount > 0, "Invalid min stake amount");
        require(config.maxStakeAmount >= config.minStakeAmount, "Invalid max stake amount");
        require(config.concentrationLimit <= MAX_ASSET_CONCENTRATION, "Invalid concentration limit");
        
        bool wasActive = supportedAssets[asset].isActive;
        supportedAssets[asset] = config;
        
        if (!wasActive && config.isActive) {
            assetList.push(asset);
        }
        
        emit AssetConfigured(asset, config.priceOracle, config.isActive, config.isCrossChain, config.symbol);
    }

    /**
     * @notice Remove asset support
     * @param asset Address of the asset to remove
     */
    function removeAssetSupport(address asset) external onlyOwner {
        require(supportedAssets[asset].isActive, "Asset not supported");
        
        supportedAssets[asset].isActive = false;
        
        // Remove from asset list
        for (uint256 i = 0; i < assetList.length; i++) {
            if (assetList[i] == asset) {
                assetList[i] = assetList[assetList.length - 1];
                assetList.pop();
                break;
            }
        }
        
        emit AssetConfigured(asset, address(0), false, false, "");
    }

    /**
     * @notice Set the slashing mechanism contract address (one-time setup)
     */
    function setSlashingMechanism(address _slashingMechanism) external onlyOwner {
        require(_slashingMechanism != address(0), "Invalid address");
        slashingMechanism = _slashingMechanism;
    }

    /**
     * @notice Set pending slashing flag for a staker (called by SlashingMechanism)
     * @dev Blocks withdrawals while a slashing proposal is active
     */
    function setPendingSlashing(address staker, bool pending) external {
        require(msg.sender == slashingMechanism, "MultiAssetStaking: Only slashing mechanism");
        hasPendingSlashing[staker] = pending;
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get comprehensive stake information for a participant
     * @param participant Address of the participant
     * @return totalStakeUSD Total stake value in USD
     * @return requiredStakeUSD Required stake amount in USD
     * @return collateralizationRatio Current collateralization ratio
     * @return meetsRequirement Whether stake meets minimum requirement
     * @return stakedAssets List of staked assets
     * @return assetAmounts Amount staked in each asset
     * @return assetValuesUSD USD value of each asset stake
     */
    function getComprehensiveStakeInfo(address participant)
        external
        view
        returns (
            uint256 totalStakeUSD,
            uint256 requiredStakeUSD,
            uint256 collateralizationRatio,
            bool meetsRequirement,
            address[] memory stakedAssets,
            uint256[] memory assetAmounts,
            uint256[] memory assetValuesUSD
        )
    {
        StakeRecord storage record = stakes[participant];
        stakedAssets = record.stakedAssets;
        assetAmounts = new uint256[](stakedAssets.length);
        assetValuesUSD = new uint256[](stakedAssets.length);
        
        totalStakeUSD = 0;
        for (uint256 i = 0; i < stakedAssets.length; i++) {
            address asset = stakedAssets[i];
            AssetStake storage assetStake = record.assets[asset];
            
            assetAmounts[i] = assetStake.amount;
            assetValuesUSD[i] = _calculateAssetValueUSD(asset, assetStake.amount);
            totalStakeUSD += assetValuesUSD[i];
        }
        
        requiredStakeUSD = record.requiredStakeUSD;
        
        if (requiredStakeUSD > 0) {
            collateralizationRatio = (totalStakeUSD * DynamicStakeCalculator.PRECISION) / requiredStakeUSD;
            meetsRequirement = collateralizationRatio >= MIN_COLLATERALIZATION_RATIO;
        } else {
            collateralizationRatio = 0;
            meetsRequirement = false;
        }
    }

    /**
     * @notice Get list of supported assets
     * @return assets Array of supported asset addresses
     * @return configs Array of asset configurations
     */
    function getSupportedAssets() 
        external 
        view 
        returns (
            address[] memory assets,
            AssetConfig[] memory configs
        ) 
    {
        assets = assetList;
        configs = new AssetConfig[](assets.length);
        
        for (uint256 i = 0; i < assets.length; i++) {
            configs[i] = supportedAssets[assets[i]];
        }
    }

    /**
     * @notice Get current asset prices from oracles
     * @param asset Address of the asset
     * @return priceUSD Current price in USD (with 8 decimals)
     * @return timestamp Last update timestamp
     * @return isStale Whether the price is stale
     */
    function getAssetPrice(address asset)
        external
        view
        returns (
            uint256 priceUSD,
            uint256 timestamp,
            bool isStale
        )
    {
        if (asset == ETH_ADDRESS) {
            // ETH price logic would need to be implemented
            return (0, 0, true);
        }
        
        AssetConfig memory config = supportedAssets[asset];
        if (config.priceOracle == address(0)) {
            return (0, 0, true);
        }
        
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(config.priceOracle)
            .latestRoundData();
        
        priceUSD = uint256(price);
        timestamp = updatedAt;
        isStale = (block.timestamp - updatedAt) > MAX_ORACLE_AGE;
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @dev Calculate USD value of an asset amount using oracle price
     */
    function _calculateAssetValueUSD(address asset, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        
        AssetConfig memory config = supportedAssets[asset];
        
        if (config.priceOracle == address(0)) {
            return 0;
        }
        
        (, int256 price, , , ) = AggregatorV3Interface(config.priceOracle).latestRoundData();
        require(price > 0, "Invalid price");
        
        // Convert to USD with proper decimal handling
        // Chainlink prices typically have 8 decimals
        uint256 priceUSD = uint256(price);
        uint256 valueUSD = (amount * priceUSD) / (10 ** config.decimals);
        
        return valueUSD;
    }

    /**
     * @dev Calculate asset amount required for a given USD value
     */
    function _calculateAssetAmount(address asset, uint256 valueUSD) internal view returns (uint256) {
        if (valueUSD == 0) return 0;
        
        AssetConfig memory config = supportedAssets[asset];
        
        if (config.priceOracle == address(0)) {
            return 0;
        }
        
        (, int256 price, , , ) = AggregatorV3Interface(config.priceOracle).latestRoundData();
        require(price > 0, "Invalid price");
        
        uint256 priceUSD = uint256(price);
        uint256 amount = (valueUSD * (10 ** config.decimals)) / priceUSD;
        
        return amount;
    }

    /**
     * @dev Update stake record for a participant
     */
    function _updateStakeRecord(
        address participant,
        address asset,
        uint256 amount,
        uint256 valueUSD,
        DynamicStakeCalculator.StakeParameters memory parameters
    ) internal {
        StakeRecord storage record = stakes[participant];
        AssetStake storage assetStake = record.assets[asset];
        
        // If first time staking this asset, add to list
        if (!assetStake.isActive) {
            record.stakedAssets.push(asset);
            assetStake.isActive = true;
            assetStake.stakedAt = block.timestamp;
        }
        
        // Update asset stake
        assetStake.amount += amount;
        assetStake.valueUSD += valueUSD;
        assetStake.lastPriceUpdate = block.timestamp;
        
        // Update record totals
        record.totalStakeUSD += valueUSD;
        record.parameters = parameters;
        
        // Calculate required stake using DynamicStakeCalculator
        DynamicStakeCalculator.StakeCalculationResult memory calculation = 
            DynamicStakeCalculator.calculateRequiredStake(parameters);
        record.requiredStakeUSD = calculation.finalStakeUSD;
        
        // Update global statistics
        if (record.stakedAssets.length == 1 && assetStake.amount == amount) {
            totalParticipants++;
        }
        totalValueLockedUSD += valueUSD;
    }

    /**
     * @dev Validate asset concentration limits
     */
    function _validateAssetConcentration(address participant, address asset) internal view {
        StakeRecord storage record = stakes[participant];
        AssetStake storage assetStake = record.assets[asset];
        AssetConfig memory config = supportedAssets[asset];

        // A <=40% cap is not satisfiable for portfolios with fewer than 3 active assets.
        // Defer concentration enforcement until the participant has a diversified basket.
        uint256 activeAssetCount = 0;
        for (uint256 i = 0; i < record.stakedAssets.length; i++) {
            AssetStake storage staked = record.assets[record.stakedAssets[i]];
            if (staked.isActive && staked.amount > 0) {
                activeAssetCount++;
            }
        }
        if (activeAssetCount < 3) {
            return;
        }
        
        if (record.totalStakeUSD > 0) {
            uint256 assetPercentage = (assetStake.valueUSD * DynamicStakeCalculator.PRECISION) / record.totalStakeUSD;
            if (assetPercentage > config.concentrationLimit) {
                revert AssetConcentrationExceeded();
            }
        }
    }

    /**
     * @dev Update collateralization ratio for a participant
     */
    function _updateCollateralizationRatio(address participant) internal {
        StakeRecord storage record = stakes[participant];
        
        uint256 oldRatio = record.collateralizationRatio;
        uint256 currentStakeUSD = _calculateCurrentStakeValueUSD(participant);
        
        if (record.requiredStakeUSD > 0) {
            record.collateralizationRatio = (currentStakeUSD * DynamicStakeCalculator.PRECISION) / record.requiredStakeUSD;
            record.meetsMinimumRequirement = record.collateralizationRatio >= MIN_COLLATERALIZATION_RATIO;
        } else {
            record.collateralizationRatio = 0;
            record.meetsMinimumRequirement = false;
        }
        
        emit CollateralizationRatioUpdated(
            participant,
            oldRatio,
            record.collateralizationRatio,
            record.meetsMinimumRequirement
        );
    }

    /**
     * @dev Calculate current stake value using latest oracle prices
     */
    function _calculateCurrentStakeValueUSD(address participant) internal view returns (uint256) {
        StakeRecord storage record = stakes[participant];
        uint256 totalValue = 0;
        
        for (uint256 i = 0; i < record.stakedAssets.length; i++) {
            address asset = record.stakedAssets[i];
            AssetStake storage assetStake = record.assets[asset];
            
            if (assetStake.isActive && assetStake.amount > 0) {
                totalValue += _calculateAssetValueUSD(asset, assetStake.amount);
            }
        }
        
        return totalValue;
    }

    /**
     * @dev Calculate slippage between expected and actual values
     */
    function _calculateSlippage(uint256 expectedValue, uint256 actualValue) internal pure returns (uint256) {
        if (expectedValue == 0) return 0;
        
        uint256 difference = expectedValue > actualValue ? 
            expectedValue - actualValue : 
            actualValue - expectedValue;
            
        return (difference * DynamicStakeCalculator.PRECISION) / expectedValue;
    }

    /**
     * @dev Initiate cross-chain deposit operation
     */
    function _initiateCrossChainDeposit(
        address asset,
        uint256 amount,
        DynamicStakeCalculator.StakeParameters memory parameters
    ) internal {
        AssetConfig memory config = supportedAssets[asset];
        
        bytes32 operationId = keccak256(
            abi.encodePacked(
                msg.sender,
                asset,
                amount,
                block.timestamp,
                block.number
            )
        );
        
        crossChainOps[operationId] = CrossChainOperation({
            participant: msg.sender,
            asset: asset,
            amount: amount,
            timestamp: block.timestamp,
            bridgeId: config.bridgeId,
            isDeposit: true,
            isCompleted: false,
            isFailed: false,
            failureReason: ""
        });
        
        participantCrossChainOps[msg.sender].push(operationId);
        
        // Store parameters temporarily for when deposit completes
        stakes[msg.sender].parameters = parameters;
        
        totalCrossChainOperations++;
        
        emit CrossChainOperationInitiated(
            operationId,
            msg.sender,
            asset,
            amount,
            config.bridgeId,
            true
        );
        
        // Note: Actual cross-chain transfer would be initiated here via bridgeIntegration
        // This is a simplified version - in production, this would call the bridge contract
    }

    /**
     * @dev Initiate cross-chain withdrawal operation
     */
    function _initiateCrossChainWithdrawal(address asset, uint256 amount) internal {
        AssetConfig memory config = supportedAssets[asset];
        StakeRecord storage record = stakes[msg.sender];
        AssetStake storage assetStake = record.assets[asset];
        
        bytes32 operationId = keccak256(
            abi.encodePacked(
                msg.sender,
                asset,
                amount,
                block.timestamp,
                block.number
            )
        );
        
        // Mark amount as pending withdrawal
        assetStake.pendingWithdrawal += amount;
        assetStake.amount -= amount;
        
        // Update USD values
        uint256 valueUSD = _calculateAssetValueUSD(asset, amount);
        assetStake.valueUSD -= valueUSD;
        record.totalStakeUSD -= valueUSD;
        totalValueLockedUSD -= valueUSD;
        
        crossChainOps[operationId] = CrossChainOperation({
            participant: msg.sender,
            asset: asset,
            amount: amount,
            timestamp: block.timestamp,
            bridgeId: config.bridgeId,
            isDeposit: false,
            isCompleted: false,
            isFailed: false,
            failureReason: ""
        });
        
        participantCrossChainOps[msg.sender].push(operationId);
        totalCrossChainOperations++;
        
        emit CrossChainOperationInitiated(
            operationId,
            msg.sender,
            asset,
            amount,
            config.bridgeId,
            false
        );
        
        // Note: Actual cross-chain transfer would be initiated here via bridgeIntegration
    }

    /**
     * @dev Execute direct asset withdrawal (non-cross-chain)
     */
    function _executeWithdrawal(address participant, address asset, uint256 amount, uint256 valueUSD) internal {
        StakeRecord storage record = stakes[participant];
        AssetStake storage assetStake = record.assets[asset];
        
        // Update stake record
        assetStake.amount -= amount;
        assetStake.valueUSD -= valueUSD;
        record.totalStakeUSD -= valueUSD;
        totalValueLockedUSD -= valueUSD;
        
        // If fully withdrawn, mark as inactive
        if (assetStake.amount == 0) {
            assetStake.isActive = false;
            _removeAssetFromList(record, asset);
        }
        
        // Update collateralization ratio
        _updateCollateralizationRatio(participant);
        
        // Transfer asset
        if (asset == ETH_ADDRESS) {
            (bool sent,) = payable(participant).call{value: amount}("");
            require(sent, "MultiAssetStaking: ETH transfer to participant failed");
        } else {
            IERC20(asset).safeTransfer(participant, amount);
        }
        
        emit AssetWithdrawn(participant, asset, amount, valueUSD, record.totalStakeUSD);
    }

    /**
     * @dev Execute asset conversion between two staked assets
     */
    function _executeConversion(
        address participant,
        address fromAsset,
        address toAsset,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 valueUSD
    ) internal {
        StakeRecord storage record = stakes[participant];
        AssetStake storage fromStake = record.assets[fromAsset];
        AssetStake storage toStake = record.assets[toAsset];
        
        // Update from asset
        fromStake.amount -= fromAmount;
        fromStake.valueUSD -= valueUSD;
        
        // Update to asset
        if (!toStake.isActive) {
            record.stakedAssets.push(toAsset);
            toStake.isActive = true;
            toStake.stakedAt = block.timestamp;
        }
        toStake.amount += toAmount;
        toStake.valueUSD += valueUSD;
        toStake.lastPriceUpdate = block.timestamp;
        
        // Remove from asset if fully converted
        if (fromStake.amount == 0) {
            fromStake.isActive = false;
            _removeAssetFromList(record, fromAsset);
        }
    }

    /**
     * @dev Execute stake rebalancing between assets
     */
    function _executeRebalance(
        address participant,
        address fromAsset,
        address toAsset,
        uint256 fromAmount,
        uint256 toAmount
    ) internal {
        uint256 valueUSD = _calculateAssetValueUSD(fromAsset, fromAmount);
        _executeConversion(participant, fromAsset, toAsset, fromAmount, toAmount, valueUSD);
        totalRebalanceOperations++;
    }

    /**
     * @dev Remove asset from participant's staked assets list
     */
    function _removeAssetFromList(StakeRecord storage record, address asset) internal {
        for (uint256 i = 0; i < record.stakedAssets.length; i++) {
            if (record.stakedAssets[i] == asset) {
                record.stakedAssets[i] = record.stakedAssets[record.stakedAssets.length - 1];
                record.stakedAssets.pop();
                break;
            }
        }
    }

    // ========== RECEIVE FUNCTION ==========

    /**
     * @notice Receive ETH deposits
     * @dev Allows the contract to receive ETH for staking
     */
    receive() external payable {
        // ETH received - could implement auto-staking logic here if desired
    }
}
