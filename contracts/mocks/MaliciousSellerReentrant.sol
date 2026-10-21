// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICarbonCreditTrading {
    function purchaseCredit(uint256 creditId, string calldata purpose) external payable;
}

/**
 * @title MaliciousSellerReentrant
 * @dev A malicious seller contract that attempts to re-enter purchaseCredit() when it
 *      receives ETH payment. Used to verify the nonReentrant modifier blocks reentrancy.
 */
contract MaliciousSellerReentrant {
    ICarbonCreditTrading public target;
    uint256 public attackCreditId;
    bool public attackEnabled;
    uint256 public attackCount;
    uint256 public etherReceived;

    function setTarget(address _target, uint256 _creditId) external {
        target = ICarbonCreditTrading(_target);
        attackCreditId = _creditId;
    }

    function enableAttack() external {
        attackEnabled = true;
    }

    function disableAttack() external {
        attackEnabled = false;
    }

    receive() external payable {
        etherReceived += msg.value;
        if (attackEnabled && address(target) != address(0) && attackCount < 1) {
            attackCount++;
            attackEnabled = false; // prevent infinite loop
            // Attempt to re-enter purchaseCredit with a different credit ID
            try target.purchaseCredit{value: 0}(attackCreditId, "reentrant attack") {} catch {}
        }
    }

    function withdrawEther() external {
        payable(msg.sender).transfer(address(this).balance);
    }
}
