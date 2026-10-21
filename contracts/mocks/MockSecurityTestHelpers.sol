// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @dev Mock contracts for security fix verification tests
 */

/// @dev A contract that uses >2300 gas in its receive function (simulates a multisig)
contract GasHeavyReceiver {
    uint256 public receiveCount;

    receive() external payable {
        // This uses ~5000+ gas, which exceeds .transfer()'s 2300 gas limit
        receiveCount += 1;
        receiveCount += 1;
        receiveCount += 1;
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}

/// @dev A contract that attempts reentrancy on CarbonCreditTrading.purchaseCredit
contract ReentrantBuyer {
    address public target;
    uint256 public creditId;
    uint256 public attackCount;

    constructor(address _target) {
        target = _target;
    }

    function attack(uint256 _creditId) external payable {
        creditId = _creditId;
        attackCount = 0;
        (bool success, bytes memory data) = target.call{value: msg.value}(
            abi.encodeWithSignature("purchaseCredit(uint256,string)", _creditId, "attack")
        );
        if (!success) {
            // Propagate the revert reason
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    receive() external payable {
        if (attackCount < 1) {
            attackCount++;
            // Attempt reentry
            (bool success, ) = target.call{value: msg.value}(
                abi.encodeWithSignature("purchaseCredit(uint256,string)", creditId, "reentry")
            );
            // We expect this to fail with nonReentrant guard
            require(!success, "Reentrancy should have been blocked");
        }
    }
}
