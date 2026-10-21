// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./CarbonCreditAMM.sol";

/**
 * @title CarbonCreditAMMFactory
 * @dev Factory contract for deploying carbon credit AMM pools
 * Supports multiple fee tiers and deterministic pool addresses
 */
contract CarbonCreditAMMFactory is AccessControl, ReentrancyGuard, Pausable {
    
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");
    
    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        uint256 feeBasisPoints;
        uint256 createdAt;
        bool isActive;
    }
    
    struct FeeTier {
        uint256 feeBasisPoints;
        uint256 tickSpacing;
        bool isActive;
    }
    
    mapping(address => mapping(address => mapping(uint256 => address))) public pools;
    mapping(address => PoolInfo) public poolInfo;
    mapping(uint256 => FeeTier) public feeTiers;
    
    address[] public allPools;
    uint256[] public supportedFeeTiers;
    
    address public feeTo;
    address public governance;
    
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint256 indexed feeTier,
        address pool,
        uint256 poolCount
    );
    
    event FeeToChanged(address indexed oldFeeTo, address indexed newFeeTo);
    event FeeTierAdded(uint256 feeBasisPoints, uint256 tickSpacing);
    event FeeTierUpdated(uint256 feeBasisPoints, bool isActive);
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POOL_CREATOR_ROLE, msg.sender);
        _grantRole(FEE_SETTER_ROLE, msg.sender);
        
        governance = msg.sender;
        
        // Initialize default fee tiers
        _addFeeTier(30, 60, true);   // 0.3% - Standard
        _addFeeTier(50, 100, true);  // 0.5% - Medium
        _addFeeTier(100, 200, true); // 1.0% - High volatility
        _addFeeTier(300, 600, true); // 3.0% - Exotic pairs
    }
    
    /**
     * @dev Create a new AMM pool
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint256 feeBasisPoints
    ) external nonReentrant whenNotPaused returns (address pool) {
        require(
            hasRole(POOL_CREATOR_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "CarbonCreditAMMFactory: FORBIDDEN"
        );
        require(tokenA != tokenB, "CarbonCreditAMMFactory: IDENTICAL_ADDRESSES");
        require(feeTiers[feeBasisPoints].isActive, "CarbonCreditAMMFactory: INVALID_FEE_TIER");
        
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "CarbonCreditAMMFactory: ZERO_ADDRESS");
        require(
            pools[token0][token1][feeBasisPoints] == address(0),
            "CarbonCreditAMMFactory: POOL_EXISTS"
        );
        
        bytes memory bytecode = _poolCreationCode();
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, feeBasisPoints));
        
        assembly {
            pool := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        require(pool != address(0), "CarbonCreditAMMFactory: CREATE2_FAILED");
        
        // Initialize the pool
        CarbonCreditAMM(pool).initialize(token0, token1, address(this), feeBasisPoints);
        
        // Store pool information
        pools[token0][token1][feeBasisPoints] = pool;
        pools[token1][token0][feeBasisPoints] = pool; // populate mapping in the reverse direction
        
        poolInfo[pool] = PoolInfo({
            pool: pool,
            token0: token0,
            token1: token1,
            feeBasisPoints: feeBasisPoints,
            createdAt: block.timestamp,
            isActive: true
        });
        
        allPools.push(pool);
        
        emit PoolCreated(token0, token1, feeBasisPoints, pool, allPools.length);
    }
    
    /**
     * @dev Get pool address deterministically
     */
    function getPool(
        address tokenA,
        address tokenB,
        uint256 feeBasisPoints
    ) external view returns (address pool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[token0][token1][feeBasisPoints];
    }
    
    /**
     * @dev Check if a pool is active
     */
    function isPoolActive(address pool) external view returns (bool) {
        return poolInfo[pool].isActive;
    }

    /**
     * @dev Predict pool address before creation
     */
    function predictPoolAddress(
        address tokenA,
        address tokenB,
        uint256 feeBasisPoints
    ) external view returns (address pool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, feeBasisPoints));
        
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(_poolCreationCode())
            )
        );
        
        return address(uint160(uint256(hash)));
    }
    
    /**
     * @dev Add a new fee tier
     */
    function addFeeTier(
        uint256 feeBasisPoints,
        uint256 tickSpacing
    ) external onlyRole(FEE_SETTER_ROLE) {
        _addFeeTier(feeBasisPoints, tickSpacing, true);
    }
    
    /**
     * @dev Internal function to add fee tier
     */
    function _addFeeTier(
        uint256 feeBasisPoints,
        uint256 tickSpacing,
        bool isActive
    ) internal {
        require(feeBasisPoints <= 1000, "CarbonCreditAMMFactory: FEE_TOO_HIGH"); // Max 10%
        require(tickSpacing > 0, "CarbonCreditAMMFactory: INVALID_TICK_SPACING");
        require(!feeTiers[feeBasisPoints].isActive, "CarbonCreditAMMFactory: FEE_TIER_EXISTS");
        
        feeTiers[feeBasisPoints] = FeeTier({
            feeBasisPoints: feeBasisPoints,
            tickSpacing: tickSpacing,
            isActive: isActive
        });
        
        supportedFeeTiers.push(feeBasisPoints);
        
        emit FeeTierAdded(feeBasisPoints, tickSpacing);
    }

    function _poolCreationCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            type(CarbonCreditAMM).creationCode,
            abi.encode(address(this))
        );
    }
    
    /**
     * @dev Update fee tier status
     */
    function updateFeeTier(
        uint256 feeBasisPoints,
        bool isActive
    ) external onlyRole(FEE_SETTER_ROLE) {
        require(feeTiers[feeBasisPoints].feeBasisPoints != 0, "CarbonCreditAMMFactory: FEE_TIER_NOT_EXISTS");
        
        feeTiers[feeBasisPoints].isActive = isActive;
        
        emit FeeTierUpdated(feeBasisPoints, isActive);
    }
    
    /**
     * @dev Set fee recipient
     */
    function setFeeTo(address _feeTo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldFeeTo = feeTo;
        feeTo = _feeTo;
        
        emit FeeToChanged(oldFeeTo, _feeTo);
    }
    
    /**
     * @dev Set governance address
     */
    function setGovernance(address _governance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_governance != address(0), "CarbonCreditAMMFactory: ZERO_ADDRESS");
        governance = _governance;
    }
    
    /**
     * @dev Enable pool creation for an address
     */
    function grantPoolCreatorRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(POOL_CREATOR_ROLE, account);
    }
    
    /**
     * @dev Disable pool creation for an address
     */
    function revokePoolCreatorRole(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(POOL_CREATOR_ROLE, account);
    }
    
    /**
     * @dev Pause/unpause pool (emergency only)
     */
    function setPoolStatus(address pool, bool isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolInfo[pool].pool != address(0), "CarbonCreditAMMFactory: POOL_NOT_EXISTS");
        
        poolInfo[pool].isActive = isActive;
        
        if (isActive) {
            CarbonCreditAMM(pool).unpause();
        } else {
            CarbonCreditAMM(pool).pause();
        }
    }
    
    /**
     * @dev Get all pools
     */
    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }
    
    /**
     * @dev Get pools for a token pair
     */
    function getPoolsForPair(
        address tokenA,
        address tokenB
    ) external view returns (address[] memory poolAddresses, uint256[] memory fees) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        uint256 count = 0;
        for (uint256 i = 0; i < supportedFeeTiers.length; i++) {
            if (pools[token0][token1][supportedFeeTiers[i]] != address(0)) {
                count++;
            }
        }
        
        poolAddresses = new address[](count);
        fees = new uint256[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < supportedFeeTiers.length; i++) {
            address pool = pools[token0][token1][supportedFeeTiers[i]];
            if (pool != address(0)) {
                poolAddresses[index] = pool;
                fees[index] = supportedFeeTiers[i];
                index++;
            }
        }
    }
    
    /**
     * @dev Get supported fee tiers
     */
    function getSupportedFeeTiers() external view returns (uint256[] memory) {
        return supportedFeeTiers;
    }
    
    /**
     * @dev Get pool count
     */
    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }
    
    /**
     * @dev Get factory stats
     */
    function getFactoryStats() external view returns (
        uint256 totalPools,
        uint256 activePools,
        uint256 totalFeeTiers,
        address feeRecipient
    ) {
        uint256 active = 0;
        for (uint256 i = 0; i < allPools.length; i++) {
            if (poolInfo[allPools[i]].isActive) {
                active++;
            }
        }
        
        return (
            allPools.length,
            active,
            supportedFeeTiers.length,
            feeTo
        );
    }
    
    /**
     * @dev Check if pool exists
     */
    function poolExists(
        address tokenA,
        address tokenB,
        uint256 feeBasisPoints
    ) external view returns (bool) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[token0][token1][feeBasisPoints] != address(0);
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Emergency unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
