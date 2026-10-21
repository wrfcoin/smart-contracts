// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWRFToken
 * @notice Interface for WRF token contract with additional functionality
 */
interface IWRFToken is IERC20 {
    /**
     * @notice Transfer tokens from contract reserves
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success True if transfer successful
     */
    function transfer(address to, uint256 amount) external override returns (bool success);

    /**
     * @notice Mint new tokens (if contract has minting capability)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burn tokens from address
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external;

    /**
     * @notice Get circulating supply
     * @return supply Current circulating supply
     */
    function circulatingSupply() external view returns (uint256 supply);

    /**
     * @notice Check if address is exempt from fees
     * @param account Address to check
     * @return exempt True if exempt from fees
     */
    function isExemptFromFees(address account) external view returns (bool exempt);
}