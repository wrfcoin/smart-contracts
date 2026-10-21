// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MaliciousERC20
 * @dev ERC20 token that attempts reentrancy on transfer() by calling back into
 *      processRecruitEarnings during the transfer to the advocate.
 */
contract MaliciousERC20 is ERC20 {
    address public attackTarget;
    address public attackRecruit;
    uint256 public attackEarnings;
    bool public attacking;
    uint256 public attackCount;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply
    ) ERC20(name_, symbol_) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function circulatingSupply() external view returns (uint256) {
        return totalSupply();
    }

    function isExemptFromFees(address) external pure returns (bool) {
        return false;
    }

    function setAttackParams(
        address _target,
        address _recruit,
        uint256 _earnings
    ) external {
        attackTarget = _target;
        attackRecruit = _recruit;
        attackEarnings = _earnings;
    }

    function enableAttack() external {
        attacking = true;
    }

    function disableAttack() external {
        attacking = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // On transfer, attempt to re-enter processRecruitEarnings
        if (attacking && attackCount < 1 && attackTarget != address(0)) {
            attackCount++;
            attacking = false; // prevent infinite loop
            (bool success, ) = attackTarget.call(
                abi.encodeWithSignature(
                    "processRecruitEarnings(address,uint256)",
                    attackRecruit,
                    attackEarnings
                )
            );
            // success will be false because of nonReentrant — that's expected
        }
        return super.transfer(to, amount);
    }
}
