// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVolatilityOracle
 * @dev Interface for volatility oracle that provides real-time volatility data for token pairs
 */
interface IVolatilityOracle {
    
    struct VolatilityData {
        uint256 volatility;        // Volatility score (0-10000, where 100 = 1%)
        uint256 timestamp;         // Last update timestamp
        uint256 confidence;        // Confidence level (0-100%)
        uint256 sampleSize;        // Number of data points used
    }
    
    /**
     * @dev Get current volatility for a token pair
     * @param token0 First token address
     * @param token1 Second token address
     * @return volatility Volatility score (basis points)
     */
    function getVolatility(address token0, address token1) external view returns (uint256 volatility);
    
    /**
     * @dev Get detailed volatility data for a token pair
     * @param token0 First token address
     * @param token1 Second token address
     * @return data Detailed volatility information
     */
    function getVolatilityData(address token0, address token1) external view returns (VolatilityData memory data);
    
    /**
     * @dev Get time-weighted average volatility over a period
     * @param token0 First token address
     * @param token1 Second token address
     * @param period Time period in seconds
     * @return avgVolatility Average volatility over the period
     */
    function getTWAVolatility(
        address token0, 
        address token1, 
        uint256 period
    ) external view returns (uint256 avgVolatility);
    
    /**
     * @dev Update volatility data for a token pair
     * @param token0 First token address
     * @param token1 Second token address
     * @param newPrice Current price for volatility calculation
     */
    function updateVolatility(address token0, address token1, uint256 newPrice) external;
    
    /**
     * @dev Check if volatility data is fresh (updated recently)
     * @param token0 First token address
     * @param token1 Second token address
     * @param maxAge Maximum age in seconds
     * @return isFresh True if data is fresh
     */
    function isDataFresh(address token0, address token1, uint256 maxAge) external view returns (bool isFresh);
    
    /**
     * @dev Get volatility threshold for dynamic fee adjustment
     * @param token0 First token address
     * @param token1 Second token address
     * @return threshold Volatility threshold above which fees should increase
     */
    function getVolatilityThreshold(address token0, address token1) external view returns (uint256 threshold);
    
    /**
     * @dev Check if current volatility exceeds threshold
     * @param token0 First token address
     * @param token1 Second token address
     * @return isHigh True if volatility is above threshold
     */
    function isHighVolatility(address token0, address token1) external view returns (bool isHigh);
    
    event VolatilityUpdated(
        address indexed token0, 
        address indexed token1, 
        uint256 volatility, 
        uint256 timestamp
    );
    
    event ThresholdExceeded(
        address indexed token0, 
        address indexed token1, 
        uint256 volatility, 
        uint256 threshold
    );
}