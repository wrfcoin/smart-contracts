// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title INFTValuation
 * @notice Interface for NFT valuation strategies used by the cross-chain bridge.
 * @dev Implementations may use fixed floor prices, oracle feeds, or on-chain AMM data.
 */
interface INFTValuation {
    /**
     * @notice Returns the value of an NFT in wei.
     * @param collection The NFT contract address.
     * @param tokenId The token ID within that collection.
     * @return value The valuation in wei.
     */
    function getNFTValue(address collection, uint256 tokenId) external view returns (uint256 value);
}
