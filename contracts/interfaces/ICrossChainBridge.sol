// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICrossChainBridge
 * @dev Interface for cross-chain bridge operations with BTC support
 * @notice Defines bridge functionality for WBTC and other cross-chain assets
 */
interface ICrossChainBridge {
    // ============ Structs ============

    struct BridgeRequest {
        uint256 nonce;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 destinationChain;
        address sender;
        address recipient;
        uint256 timestamp;
        uint256 fee;
        bytes32 txHash;
        BridgeStatus status;
    }

    enum BridgeStatus {
        PENDING,
        CONFIRMED,
        FAILED,
        TIMEOUT,
        REFUNDED
    }

    // ============ Events ============

    event BridgeInitiated(
        uint256 indexed nonce,
        address indexed token,
        uint256 amount,
        uint256 indexed destinationChain,
        address sender,
        address recipient
    );

    event BridgeCompleted(
        uint256 indexed nonce,
        bytes32 indexed txHash,
        BridgeStatus status
    );

    event BridgeRefunded(
        uint256 indexed nonce,
        address indexed recipient,
        uint256 amount,
        string reason
    );

    // ============ Core Functions ============

    /**
     * @notice Initiate a cross-chain bridge transfer
     * @param amount Amount to bridge
     * @param destinationChain Target chain ID
     * @param recipient Recipient address on destination chain
     * @param nonce Bridge operation nonce
     * @return success Whether initiation was successful
     */
    function initiateBridge(
        uint256 amount,
        uint256 destinationChain,
        address recipient,
        uint256 nonce
    ) external returns (bool success);

    /**
     * @notice Confirm bridge completion from destination chain
     * @param nonce Bridge operation nonce
     * @param txHash Transaction hash from destination chain
     * @param status Final status of the bridge operation
     */
    function confirmBridge(
        uint256 nonce,
        bytes32 txHash,
        BridgeStatus status
    ) external;

    /**
     * @notice Refund failed bridge operation
     * @param nonce Bridge operation nonce
     * @param reason Reason for refund
     */
    function refundBridge(
        uint256 nonce,
        string calldata reason
    ) external;

    // ============ View Functions ============

    /**
     * @notice Get bridge request details
     * @param nonce Bridge operation nonce
     * @return request Bridge request struct
     */
    function getBridgeRequest(uint256 nonce) 
        external 
        view 
        returns (BridgeRequest memory request);

    /**
     * @notice Check if bridge supports a specific chain
     * @param chainId Chain identifier
     * @return supported Whether chain is supported
     */
    function isSupportedChain(uint256 chainId) 
        external 
        view 
        returns (bool supported);

    /**
     * @notice Get bridge fee for an amount
     * @param amount Amount to bridge
     * @param destinationChain Target chain
     * @return fee Bridge fee amount
     */
    function getBridgeFee(uint256 amount, uint256 destinationChain) 
        external 
        view 
        returns (uint256 fee);

    /**
     * @notice Get bridge operational status
     * @return isOperational Whether bridge is operational
     * @return pendingOperations Number of pending operations
     * @return failureRate Recent failure rate percentage
     */
    function getBridgeStatus() 
        external 
        view 
        returns (
            bool isOperational,
            uint256 pendingOperations,
            uint256 failureRate
        );
}