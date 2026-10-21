// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal endpoint used to prove SecureBridgeIntegration's approval
///         gates without coupling the tests to NFT custody and bridge fees.
contract MockNFTCrossChainBridgeEndpoint {
    uint256 public callCount;
    bytes32 public lastTransferId;

    function bridgeNFT(
        address nftContract,
        uint256 tokenId,
        uint8 destinationChain,
        address recipient,
        string calldata metadata
    ) external payable returns (bytes32 transferId) {
        callCount++;
        transferId = keccak256(
            abi.encode(
                nftContract,
                tokenId,
                destinationChain,
                recipient,
                metadata,
                callCount
            )
        );
        lastTransferId = transferId;
    }
}
