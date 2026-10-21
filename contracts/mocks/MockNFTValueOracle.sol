// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/INFTValueOracle.sol";

/// @dev Test-only deterministic NFT valuation oracle.
contract MockNFTValueOracle is INFTValueOracle {
    struct Quote {
        uint256 valueWei;
        uint256 updatedAt;
    }

    mapping(address => mapping(uint256 => Quote)) private quotes;
    bool public shouldRevert;

    function setQuote(address nftContract, uint256 tokenId, uint256 valueWei, uint256 updatedAt) external {
        quotes[nftContract][tokenId] = Quote({valueWei: valueWei, updatedAt: updatedAt});
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getNFTValue(address nftContract, uint256 tokenId)
        external
        view
        override
        returns (uint256 valueWei, uint256 updatedAt)
    {
        require(!shouldRevert, "MockNFTValueOracle: forced revert");
        Quote memory quote = quotes[nftContract][tokenId];
        return (quote.valueWei, quote.updatedAt);
    }
}
