// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IYieldSource {
    function depositToken() external view returns (address);

    function supplyTokensTo(uint256 amount, address to) external;

    function redeemToken(uint256 amount, address to) external returns (uint256);

    function balanceOfToken(address addr) external view returns (uint256);
}
