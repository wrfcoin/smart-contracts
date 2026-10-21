// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IGeoStaking {
    function stakeInZone(string calldata zoneId) external payable;
    function unstake(string calldata zoneId, uint256 amount) external;
    function claimRewards(string calldata zoneId) external;
}

/**
 * @title GeoStakingReentrancyAttacker
 * @dev Malicious staker used to verify that GeoStakingContracts is not drainable
 *      via re-entrancy (issue #162). When it receives ETH (a reward or unstake
 *      payout) it attempts to re-enter `unstake()` before the outer call has
 *      finished updating state. With the fix in place the re-entrant call must
 *      revert (ReentrancyGuard), so the attacker can never withdraw more than it
 *      legitimately staked.
 */
contract GeoStakingReentrancyAttacker {
    IGeoStaking public target;
    string public zoneId;
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;
    bool private attacking;

    constructor(address _target, string memory _zoneId) {
        target = IGeoStaking(_target);
        zoneId = _zoneId;
    }

    function stake() external payable {
        target.stakeInZone{value: msg.value}(zoneId);
    }

    /// Kick off an unstake; the reentrancy is attempted from `receive()`.
    function attackUnstake(uint256 amount) external {
        attacking = true;
        target.unstake(zoneId, amount);
        attacking = false;
    }

    receive() external payable {
        if (attacking && reentryAttempts == 0) {
            reentryAttempts++;
            // Re-enter with the full remaining amount. If the guard is missing
            // this would queue a second payout and drain the pool; with the
            // guard it reverts and we record that it did NOT succeed.
            try target.unstake(zoneId, msg.value) {
                reentrySuccesses++;
            } catch {
                // expected: ReentrancyGuard reverts the nested call
            }
        }
    }

    function withdraw() external {
        (bool ok,) = payable(msg.sender).call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}
