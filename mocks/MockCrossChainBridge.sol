// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/ICrossChainBridge.sol";

/**
 * @title MockCrossChainBridge
 * @dev Mock implementation of cross-chain bridge for testing
 */
abstract contract MockCrossChainBridge is ICrossChainBridge {
    mapping(uint256 => BridgeRequest) private bridgeRequests;
    mapping(uint256 => bool) private supportedChains;
    
    uint256 public constant BRIDGE_FEE_PERCENTAGE = 100; // 1%
    uint256 private nextNonce = 1;
    bool public isOperational = true;
    uint256 public pendingCount = 0;
    uint256 public totalOperations = 0;
    uint256 public failedOperations = 0;

    constructor() {
        // Add some supported chains for testing
        supportedChains[1] = true; // Ethereum
        supportedChains[137] = true; // Polygon
        supportedChains[56] = true; // BSC
    }

    function initiateBridge(
        uint256 amount,
        uint256 destinationChain,
        address recipient,
        uint256 nonce
    ) external returns (bool success) {
        require(supportedChains[destinationChain], "Unsupported chain");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");

        bridgeRequests[nonce] = BridgeRequest({
            nonce: nonce,
            token: address(0), // Will be set by caller
            amount: amount,
            sourceChain: block.chainid,
            destinationChain: destinationChain,
            sender: tx.origin, // The original sender
            recipient: recipient,
            timestamp: block.timestamp,
            fee: (amount * BRIDGE_FEE_PERCENTAGE) / 10000,
            txHash: bytes32(0),
            status: BridgeStatus.PENDING
        });

        pendingCount++;
        totalOperations++;

        emit BridgeInitiated(
            nonce,
            address(0), // Token address
            amount,
            destinationChain,
            tx.origin,
            recipient
        );

        return true;
    }

    function confirmBridge(
        uint256 nonce,
        bytes32 txHash,
        BridgeStatus status
    ) external {
        require(bridgeRequests[nonce].nonce == nonce, "Invalid nonce");
        require(bridgeRequests[nonce].status == BridgeStatus.PENDING, "Not pending");

        bridgeRequests[nonce].txHash = txHash;
        bridgeRequests[nonce].status = status;

        if (status == BridgeStatus.CONFIRMED) {
            pendingCount--;
        } else if (status == BridgeStatus.FAILED) {
            pendingCount--;
            failedOperations++;
        }

        emit BridgeCompleted(nonce, txHash, status);
    }

    function refundBridge(
        uint256 nonce,
        string calldata reason
    ) external {
        require(bridgeRequests[nonce].nonce == nonce, "Invalid nonce");
        require(
            bridgeRequests[nonce].status == BridgeStatus.PENDING ||
            bridgeRequests[nonce].status == BridgeStatus.FAILED,
            "Cannot refund"
        );

        bridgeRequests[nonce].status = BridgeStatus.REFUNDED;
        
        if (bridgeRequests[nonce].status == BridgeStatus.PENDING) {
            pendingCount--;
        }

        emit BridgeRefunded(
            nonce,
            bridgeRequests[nonce].sender,
            bridgeRequests[nonce].amount,
            reason
        );
    }

    function getBridgeRequest(uint256 nonce) 
        external 
        view 
        
        returns (BridgeRequest memory request) 
    {
        return bridgeRequests[nonce];
    }

    function isSupportedChain(uint256 chainId) 
        external 
        view 
        
        returns (bool supported) 
    {
        return supportedChains[chainId];
    }

    function getBridgeFee(uint256 amount, uint256 destinationChain) 
        external 
        pure 
        
        returns (uint256 fee) 
    {
        destinationChain; // Suppress unused parameter warning
        return (amount * BRIDGE_FEE_PERCENTAGE) / 10000;
    }

    function getBridgeStatus() 
        external 
        view 
        
        returns (
            bool isOperational,
            uint256 pendingOperations,
            uint256 failureRate
        ) 
    {
        return (
            this.isOperational(),
            pendingCount,
            totalOperations > 0 ? (failedOperations * 100) / totalOperations : 0
        );
    }

    // Test helper functions
    function addSupportedChain(uint256 chainId) external {
        supportedChains[chainId] = true;
    }

    function removeSupportedChain(uint256 chainId) external {
        supportedChains[chainId] = false;
    }

    function setOperational(bool _operational) external {
        isOperational = _operational;
    }

    function simulateFailure(uint256 nonce) external {
        require(bridgeRequests[nonce].nonce == nonce, "Invalid nonce");
        bridgeRequests[nonce].status = BridgeStatus.FAILED;
        failedOperations++;
        if (pendingCount > 0) pendingCount--;
    }
}