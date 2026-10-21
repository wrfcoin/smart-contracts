// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IEconomicSecurityMechanisms {
    function unstakeTokens(uint256 amount) external;
}

/**
 * @title MaliciousERC20
 * @dev ERC20 token that re-enters unstakeTokens() on transfer() — for reentrancy testing only
 */
contract MaliciousERC20 is ERC20 {
    IEconomicSecurityMechanisms public target;
    bool public attackEnabled;
    uint256 public reentrancyAmount;

    constructor() ERC20("MaliciousToken", "MAL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(address _target, uint256 _amount) external {
        target = IEconomicSecurityMechanisms(_target);
        reentrancyAmount = _amount;
        attackEnabled = true;
    }

    function disableAttack() external {
        attackEnabled = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Re-enter unstakeTokens when ESM tries to transfer tokens back
        if (attackEnabled && address(target) != address(0) && to != address(0)) {
            attackEnabled = false; // prevent infinite loop
            try target.unstakeTokens(reentrancyAmount) {} catch {}
        }
        return super.transfer(to, amount);
    }
}
