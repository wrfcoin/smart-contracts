// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Provides a current, wei-denominated value for an individual NFT.
/// @dev Implementations must report the timestamp for the value they return.
interface INFTValueOracle {
    function getNFTValue(address nftContract, uint256 tokenId)
        external
        view
        returns (uint256 valueWei, uint256 updatedAt);
}
