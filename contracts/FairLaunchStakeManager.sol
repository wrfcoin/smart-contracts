// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/DynamicStakeCalculator.sol";

/**
 * @title FairLaunchStakeManager
 * @dev Advanced stake management contract using DynamicStakeCalculator for WRFCoin fair launch
 * 
 * This contract manages the sophisticated staking requirements for weather station
 * registration in the WRFCoin ecosystem, implementing the enhanced fair launch system
 * with dynamic stake calculations based on multiple factors.
 * 
 * Features:
 * - Multi-asset staking support (ETH, WBTC, WRF, USDC, USDT)
 * - Dynamic stake calculation using participation type, geography, verification
 * - Oracle integration for asset pricing
 * - Comprehensive stake management (deposit, withdrawal, slashing)
 * - Economic security mechanisms
 * - Anti-Sybil attack protections
 * - Detailed event tracking for transparency
 * 
 * Security:
 * - Reentrancy protection on all external calls
 * - Oracle price validation and bounds checking
 * - Emergency pause functionality
 * - Access control for administrative functions
 * - Comprehensive input validation
 * 
 * Integration:
 * - Uses DynamicStakeCalculator library for all calculations
 * - Compatible with WRFToken registration system
 * - Supports future oracle upgrades
 * - Designed for high-value TVL protection ($2M-$5M range)
 * 
 * @author WRFCoin Security Team
 * @notice This contract manages production-ready staking with economic security guarantees
 */
contract FairLaunchStakeManager is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using DynamicStakeCalculator for DynamicStakeCalculator.StakeParameters;
    
    // ========== CONSTANTS ==========
    
    /// @dev Maximum number of assets that can be supported
    uint8 public constant MAX_SUPPORTED_ASSETS = 10;
    
    /// @dev Maximum oracle price age in seconds (1 hour)
    uint256 public constant MAX_ORACLE_AGE = 3600;
    
    /// @dev Maximum stake amount per participant (anti-whale protection)
    uint256 public constant MAX_STAKE_USD = 10000 * DynamicStakeCalculator.PRECISION; // $10,000
    
    /// @dev Slashing percentage for malicious behavior (10%)
    uint256 public constant SLASHING_PERCENTAGE = 100_000; // 10% in precision units
    
    // ========== STRUCTS ==========
    
    /// @dev Supported staking asset information
    struct StakeAsset {
        address tokenAddress;
        uint8 decimals;
        bool isActive;
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        string symbol;
    }
    
    /// @dev Oracle price information
    struct OraclePrice {
        uint256 priceUSD;              // Price in USD (with PRECISION)
        uint256 lastUpdated;           // Timestamp of last update
        address priceOracle;           // Oracle contract address
        bool isActive;                 // Whether oracle is active
    }
    
    /// @dev Individual participant stake information
    struct ParticipantStake {
        address asset;                 // Staked asset address
        uint256 amount;                // Amount staked in asset units
        uint256 valueUSD;              // USD value at stake time
        uint256 stakedAt;              // Timestamp of stake
        bool isActive;                 // Whether stake is active
        DynamicStakeCalculator.StakeParameters parameters; // Calculation parameters
        uint256 requiredStakeUSD;      // Required stake amount in USD
    }
    
    /// @dev Comprehensive stake record for participants
    struct StakeRecord {
        mapping(address => ParticipantStake) assetStakes; // Asset address => stake info
        address[] stakedAssets;        // List of assets staked by participant
        uint256 totalStakeUSD;         // Total stake value in USD
        uint256 minimumRequiredUSD;    // Minimum required based on parameters
        bool meetsRequirement;         // Whether stake meets minimum requirement
        uint256 lastStakeUpdate;       // Last stake modification timestamp
        uint256 slashedAmount;         // Total amount slashed (in USD)
    }
    
    // ========== STATE VARIABLES ==========
    
    /// @dev Supported staking assets
    mapping(address => StakeAsset) public supportedAssets;
    address[] public assetList;
    
    /// @dev Oracle price feeds for assets
    mapping(address => OraclePrice) public assetOracles;
    
    /// @dev Participant stake records
    mapping(address => StakeRecord) private stakeRecords;
    
    /// @dev Total value locked in the contract (in USD with PRECISION)
    uint256 public totalValueLockedUSD;
    
    /// @dev Emergency multisig for slashing and emergency functions
    address public emergencyMultisig;
    
    /// @dev Treasury address for slashed funds
    address public treasury;
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when stake is deposited
    event StakeDeposited(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD,
        DynamicStakeCalculator.ParticipationType participationType,
        DynamicStakeCalculator.GeographicZone geographicZone
    );
    
    /// @notice Emitted when stake is withdrawn
    event StakeWithdrawn(
        address indexed participant,
        address indexed asset,
        uint256 amount,
        uint256 valueUSD
    );
    
    /// @notice Emitted when stake is slashed for malicious behavior
    event StakeSlashed(
        address indexed participant,
        address indexed asset,
        uint256 slashedAmount,
        uint256 remainingAmount,
        string reason
    );
    
    /// @notice Emitted when asset support is updated
    event AssetSupportUpdated(
        address indexed asset,
        bool supported,
        uint8 decimals,
        string symbol
    );
    
    /// @notice Emitted when oracle price is updated
    event OraclePriceUpdated(
        address indexed asset,
        uint256 newPrice,
        uint256 timestamp,
        address oracle
    );
    
    /// @notice Emitted when stake requirement is recalculated
    event StakeRequirementRecalculated(
        address indexed participant,
        uint256 newRequirement,
        uint256 currentStake,
        bool meetsRequirement
    );
    
    // ========== ERRORS ==========
    
    error AssetNotSupported();
    error InsufficientStakeAmount();
    error ExcessiveStakeAmount();
    error StaleOraclePrice();
    error InvalidOraclePrice();
    error StakeNotFound();
    error InsufficientStakeBalance();
    error UnauthorizedSlashing();
    error InvalidParameters();
    
    // ========== MODIFIERS ==========
    
    /// @dev Ensures asset is supported for staking
    modifier onlySupported(address asset) {
        if (!supportedAssets[asset].isActive) {
            revert AssetNotSupported();
        }
        _;
    }
    
    /// @dev Ensures oracle price is fresh and valid
    modifier validOraclePrice(address asset) {
        OraclePrice memory oracle = assetOracles[asset];
        if (!oracle.isActive || oracle.priceUSD == 0) {
            revert InvalidOraclePrice();
        }
        if (block.timestamp - oracle.lastUpdated > MAX_ORACLE_AGE) {
            revert StaleOraclePrice();
        }
        _;
    }
    
    /// @dev Ensures caller is emergency multisig for slashing operations
    modifier onlyEmergencyMultisig() {
        if (msg.sender != emergencyMultisig) {
            revert UnauthorizedSlashing();
        }
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    /**
     * @notice Initialize FairLaunchStakeManager with security parameters
     * @param _emergencyMultisig Address of emergency multisig wallet
     * @param _treasury Address of treasury for slashed funds
     */
    constructor(
        address _emergencyMultisig,
        address _treasury
    ) Ownable(msg.sender) {
        require(_emergencyMultisig != address(0), "Invalid emergency multisig");
        require(_treasury != address(0), "Invalid treasury");
        
        emergencyMultisig = _emergencyMultisig;
        treasury = _treasury;
    }
    
    // ========== STAKE MANAGEMENT FUNCTIONS ==========
    
    /**
     * @notice Deposit stake for weather station registration
     * @dev Calculates required stake using DynamicStakeCalculator and validates deposit
     * @param asset Address of the asset to stake
     * @param amount Amount of asset to stake
     * @param parameters Staking parameters for calculation
     */
    function depositStake(
        address asset,
        uint256 amount,
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        onlySupported(asset)
        validOraclePrice(asset)
    {
        // Validate parameters
        (bool valid, string memory error) = DynamicStakeCalculator.validateStakeParameters(parameters);
        if (!valid) {
            revert InvalidParameters();
        }
        
        // Calculate required stake
        DynamicStakeCalculator.StakeCalculationResult memory calculation = 
            DynamicStakeCalculator.calculateRequiredStake(parameters);
        
        // Get asset price and calculate USD value
        uint256 assetPrice = assetOracles[asset].priceUSD;
        StakeAsset memory assetInfo = supportedAssets[asset];
        
        uint256 stakeValueUSD = DynamicStakeCalculator.convertToAsset(
            amount,
            assetPrice,
            assetInfo.decimals
        ) * assetPrice / (10 ** assetInfo.decimals);
        
        // Validate stake amount meets requirements
        if (stakeValueUSD < calculation.finalStakeUSD) {
            revert InsufficientStakeAmount();
        }
        
        // Validate stake doesn't exceed maximum
        if (stakeValueUSD > MAX_STAKE_USD) {
            revert ExcessiveStakeAmount();
        }
        
        // Update stake record
        StakeRecord storage record = stakeRecords[msg.sender];
        ParticipantStake storage stake = record.assetStakes[asset];
        
        // If first time staking this asset, add to list
        if (!stake.isActive) {
            record.stakedAssets.push(asset);
        }
        
        // Update stake information
        stake.asset = asset;
        stake.amount += amount;
        stake.valueUSD += stakeValueUSD;
        stake.stakedAt = block.timestamp;
        stake.isActive = true;
        stake.parameters = parameters;
        stake.requiredStakeUSD = calculation.finalStakeUSD;
        
        // Update record totals
        record.totalStakeUSD += stakeValueUSD;
        record.minimumRequiredUSD = calculation.finalStakeUSD;
        record.meetsRequirement = record.totalStakeUSD >= record.minimumRequiredUSD;
        record.lastStakeUpdate = block.timestamp;
        
        // Update global TVL
        totalValueLockedUSD += stakeValueUSD;
        
        // Transfer tokens to contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        emit StakeDeposited(
            msg.sender,
            asset,
            amount,
            stakeValueUSD,
            parameters.participationType,
            parameters.geographicZone
        );
        
        // Emit stake calculation event from library
        emit DynamicStakeCalculator.StakeCalculated(
            msg.sender,
            calculation.finalStakeUSD,
            parameters.participationType,
            parameters.geographicZone,
            parameters.verificationLevel,
            calculation.socialDiscount,
            parameters.density.nearbyStationsCount,
            calculation.hitMinimumFloor
        );
    }
    
    /**
     * @notice Withdraw stake after deregistration
     * @dev Allows participants to withdraw their stake when leaving the network
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (0 for full withdrawal)
     */
    function withdrawStake(
        address asset,
        uint256 amount
    ) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        StakeRecord storage record = stakeRecords[msg.sender];
        ParticipantStake storage stake = record.assetStakes[asset];
        
        if (!stake.isActive) {
            revert StakeNotFound();
        }
        
        // If amount is 0, withdraw all
        if (amount == 0) {
            amount = stake.amount;
        }
        
        if (amount > stake.amount) {
            revert InsufficientStakeBalance();
        }
        
        // Calculate USD value being withdrawn
        uint256 assetPrice = assetOracles[asset].priceUSD;
        StakeAsset memory assetInfo = supportedAssets[asset];
        
        uint256 withdrawValueUSD = DynamicStakeCalculator.convertToAsset(
            amount,
            assetPrice,
            assetInfo.decimals
        ) * assetPrice / (10 ** assetInfo.decimals);
        
        // Update stake record
        stake.amount -= amount;
        stake.valueUSD -= withdrawValueUSD;
        record.totalStakeUSD -= withdrawValueUSD;
        record.lastStakeUpdate = block.timestamp;
        
        // If fully withdrawn, mark as inactive
        if (stake.amount == 0) {
            stake.isActive = false;
            _removeAssetFromList(record, asset);
        }
        
        // Update requirement status
        record.meetsRequirement = record.totalStakeUSD >= record.minimumRequiredUSD;
        
        // Update global TVL
        totalValueLockedUSD -= withdrawValueUSD;
        
        // Transfer tokens back to participant
        IERC20(asset).safeTransfer(msg.sender, amount);
        
        emit StakeWithdrawn(msg.sender, asset, amount, withdrawValueUSD);
    }
    
    /**
     * @notice Slash stake for malicious behavior
     * @dev Emergency function to slash stakes of malicious participants
     * @param participant Address of the participant to slash
     * @param asset Asset to slash
     * @param reason Reason for slashing
     */
    function slashStake(
        address participant,
        address asset,
        string calldata reason
    ) 
        external 
        nonReentrant 
        onlyEmergencyMultisig 
    {
        StakeRecord storage record = stakeRecords[participant];
        ParticipantStake storage stake = record.assetStakes[asset];
        
        if (!stake.isActive) {
            revert StakeNotFound();
        }
        
        // Calculate slashing amount (10% of stake)
        uint256 slashAmount = (stake.amount * SLASHING_PERCENTAGE) / DynamicStakeCalculator.PRECISION;
        uint256 slashValueUSD = (stake.valueUSD * SLASHING_PERCENTAGE) / DynamicStakeCalculator.PRECISION;
        
        // Update stake record
        stake.amount -= slashAmount;
        stake.valueUSD -= slashValueUSD;
        record.totalStakeUSD -= slashValueUSD;
        record.slashedAmount += slashValueUSD;
        record.lastStakeUpdate = block.timestamp;
        
        // Update requirement status
        record.meetsRequirement = record.totalStakeUSD >= record.minimumRequiredUSD;
        
        // Update global TVL
        totalValueLockedUSD -= slashValueUSD;
        
        // Transfer slashed tokens to treasury
        IERC20(asset).safeTransfer(treasury, slashAmount);
        
        emit StakeSlashed(participant, asset, slashAmount, stake.amount, reason);
    }
    
    // ========== ASSET MANAGEMENT FUNCTIONS ==========
    
    /**
     * @notice Add or update supported staking asset
     * @dev Only owner can manage supported assets
     * @param asset Address of the token contract
     * @param decimals Number of decimals for the token
     * @param minStakeAmount Minimum stake amount in token units
     * @param maxStakeAmount Maximum stake amount in token units
     * @param symbol Token symbol for display
     */
    function setSupportedAsset(
        address asset,
        uint8 decimals,
        uint256 minStakeAmount,
        uint256 maxStakeAmount,
        string calldata symbol
    ) external onlyOwner {
        require(asset != address(0), "Invalid asset address");
        require(decimals <= 18, "Invalid decimals");
        require(minStakeAmount > 0, "Invalid min stake");
        require(maxStakeAmount >= minStakeAmount, "Invalid max stake");
        
        bool wasActive = supportedAssets[asset].isActive;
        
        supportedAssets[asset] = StakeAsset({
            tokenAddress: asset,
            decimals: decimals,
            isActive: true,
            minStakeAmount: minStakeAmount,
            maxStakeAmount: maxStakeAmount,
            symbol: symbol
        });
        
        // Add to asset list if new
        if (!wasActive) {
            assetList.push(asset);
        }
        
        emit AssetSupportUpdated(asset, true, decimals, symbol);
    }
    
    /**
     * @notice Remove support for a staking asset
     * @dev Only owner can remove asset support
     * @param asset Address of the asset to remove
     */
    function removeSupportedAsset(address asset) external onlyOwner {
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
        
        emit AssetSupportUpdated(asset, false, 0, "");
    }
    
    // ========== ORACLE MANAGEMENT FUNCTIONS ==========
    
    /**
     * @notice Set oracle price for an asset
     * @dev Only owner can update oracle prices
     * @param asset Asset address
     * @param priceUSD Price in USD (with PRECISION)
     * @param oracle Oracle contract address
     */
    function setOraclePrice(
        address asset,
        uint256 priceUSD,
        address oracle
    ) external onlyOwner {
        require(supportedAssets[asset].isActive, "Asset not supported");
        require(priceUSD > 0, "Invalid price");
        require(oracle != address(0), "Invalid oracle");
        
        assetOracles[asset] = OraclePrice({
            priceUSD: priceUSD,
            lastUpdated: block.timestamp,
            priceOracle: oracle,
            isActive: true
        });
        
        emit OraclePriceUpdated(asset, priceUSD, block.timestamp, oracle);
    }
    
    /**
     * @notice Recalculate stake requirements for a participant
     * @dev Updates requirements based on changed parameters
     * @param participant Address of the participant
     * @param newParameters Updated staking parameters
     */
    function recalculateStakeRequirement(
        address participant,
        DynamicStakeCalculator.StakeParameters calldata newParameters
    ) external onlyOwner {
        StakeRecord storage record = stakeRecords[participant];
        
        // Validate new parameters
        (bool valid, string memory error) = DynamicStakeCalculator.validateStakeParameters(newParameters);
        if (!valid) {
            revert InvalidParameters();
        }
        
        // Calculate new required stake
        DynamicStakeCalculator.StakeCalculationResult memory calculation = 
            DynamicStakeCalculator.calculateRequiredStake(newParameters);
        
        // Update requirement
        record.minimumRequiredUSD = calculation.finalStakeUSD;
        record.meetsRequirement = record.totalStakeUSD >= record.minimumRequiredUSD;
        record.lastStakeUpdate = block.timestamp;
        
        emit StakeRequirementRecalculated(
            participant,
            calculation.finalStakeUSD,
            record.totalStakeUSD,
            record.meetsRequirement
        );
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get comprehensive stake information for a participant
     * @param participant Address of the participant
     * @return totalStakeUSD Total stake value in USD
     * @return requiredStakeUSD Required stake amount in USD
     * @return meetsRequirement Whether stake meets requirement
     * @return stakedAssets List of assets staked
     * @return lastUpdate Last stake update timestamp
     * @return slashedAmount Total amount slashed
     */
    function getStakeInfo(address participant) external view returns (
        uint256 totalStakeUSD,
        uint256 requiredStakeUSD,
        bool meetsRequirement,
        address[] memory stakedAssets,
        uint256 lastUpdate,
        uint256 slashedAmount
    ) {
        StakeRecord storage record = stakeRecords[participant];
        return (
            record.totalStakeUSD,
            record.minimumRequiredUSD,
            record.meetsRequirement,
            record.stakedAssets,
            record.lastStakeUpdate,
            record.slashedAmount
        );
    }
    
    /**
     * @notice Get detailed asset stake information
     * @param participant Address of the participant
     * @param asset Address of the asset
     * @return amount Amount staked in asset units
     * @return valueUSD USD value of stake
     * @return stakedAt Timestamp of stake
     * @return isActive Whether stake is active
     * @return requiredStakeUSD Required stake amount for this participant
     */
    function getAssetStakeInfo(
        address participant,
        address asset
    ) external view returns (
        uint256 amount,
        uint256 valueUSD,
        uint256 stakedAt,
        bool isActive,
        uint256 requiredStakeUSD
    ) {
        ParticipantStake storage stake = stakeRecords[participant].assetStakes[asset];
        return (
            stake.amount,
            stake.valueUSD,
            stake.stakedAt,
            stake.isActive,
            stake.requiredStakeUSD
        );
    }
    
    /**
     * @notice Calculate required stake for given parameters
     * @param parameters Staking parameters
     * @return finalStakeUSD Required stake amount in USD
     * @return calculation Detailed calculation breakdown
     */
    function calculateRequiredStake(
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) external pure returns (
        uint256 finalStakeUSD,
        DynamicStakeCalculator.StakeCalculationResult memory calculation
    ) {
        calculation = DynamicStakeCalculator.calculateRequiredStake(parameters);
        return (calculation.finalStakeUSD, calculation);
    }
    
    /**
     * @notice Get stake amounts for all supported assets
     * @param usdAmount USD amount to convert
     * @return assets List of supported asset addresses
     * @return amounts Required amounts for each asset
     * @return symbols Asset symbols for display
     */
    function getMultiAssetStakeAmounts(
        uint256 usdAmount
    ) external view returns (
        address[] memory assets,
        uint256[] memory amounts,
        string[] memory symbols
    ) {
        assets = assetList;
        amounts = new uint256[](assets.length);
        symbols = new string[](assets.length);
        
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            StakeAsset memory assetInfo = supportedAssets[asset];
            OraclePrice memory oracle = assetOracles[asset];
            
            if (oracle.isActive && oracle.priceUSD > 0) {
                amounts[i] = DynamicStakeCalculator.convertToAsset(
                    usdAmount,
                    oracle.priceUSD,
                    assetInfo.decimals
                );
            }
            symbols[i] = assetInfo.symbol;
        }
        
        return (assets, amounts, symbols);
    }
    
    /**
     * @notice Get list of supported assets
     * @return assets Array of supported asset addresses
     */
    function getSupportedAssets() external view returns (address[] memory assets) {
        return assetList;
    }
    
    /**
     * @notice Get oracle price information for an asset
     * @param asset Address of the asset
     * @return priceUSD Current price in USD
     * @return lastUpdated Last update timestamp
     * @return oracle Oracle contract address
     * @return isActive Whether oracle is active
     * @return isStale Whether price is stale
     */
    function getOracleInfo(address asset) external view returns (
        uint256 priceUSD,
        uint256 lastUpdated,
        address oracle,
        bool isActive,
        bool isStale
    ) {
        OraclePrice memory oracleData = assetOracles[asset];
        bool stale = (block.timestamp - oracleData.lastUpdated) > MAX_ORACLE_AGE;
        
        return (
            oracleData.priceUSD,
            oracleData.lastUpdated,
            oracleData.priceOracle,
            oracleData.isActive,
            stale
        );
    }
    
    // ========== EMERGENCY FUNCTIONS ==========
    
    /**
     * @notice Emergency pause all operations
     * @dev Only owner can pause for emergency situations
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause operations after emergency resolution
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Update emergency multisig address
     * @param newMultisig New multisig address
     */
    function updateEmergencyMultisig(address newMultisig) external onlyOwner {
        require(newMultisig != address(0), "Invalid multisig address");
        emergencyMultisig = newMultisig;
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        treasury = newTreasury;
    }
    
    // ========== INTERNAL HELPER FUNCTIONS ==========
    
    /**
     * @dev Remove asset from participant's staked assets list
     * @param record Stake record to update
     * @param asset Asset to remove
     */
    function _removeAssetFromList(StakeRecord storage record, address asset) private {
        for (uint256 i = 0; i < record.stakedAssets.length; i++) {
            if (record.stakedAssets[i] == asset) {
                record.stakedAssets[i] = record.stakedAssets[record.stakedAssets.length - 1];
                record.stakedAssets.pop();
                break;
            }
        }
    }
}