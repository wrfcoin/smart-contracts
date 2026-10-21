// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IWRFToken.sol";

/**
 * @title MockWRFToken
 * @notice Mock implementation for testing LayawayRegistration
 */
abstract contract MockWRFToken is ERC20, IWRFToken {
    mapping(address => bool) public exemptFromFees;

    constructor() ERC20("Mock WRF Token", "mWRF") {
        _mint(msg.sender, 100000000e18); // 100M tokens
    }

    // Override transfer to resolve conflict
    function transfer(address to, uint256 amount) public virtual override(ERC20, IWRFToken) returns (bool) {
        return super.transfer(to, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function circulatingSupply() external view returns (uint256 supply) {
        return totalSupply();
    }

    function isExemptFromFees(address account) external view returns (bool exempt) {
        return exemptFromFees[account];
    }

    function setExemptFromFees(address account, bool exempt) external {
        exemptFromFees[account] = exempt;
    }
}