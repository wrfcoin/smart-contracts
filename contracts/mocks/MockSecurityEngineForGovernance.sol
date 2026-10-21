// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockSecurityEngineForGovernance
 * @dev Minimal ISecurityEngine stand-in for CommunityGovernance tests.
 *      Governance only reads `securityRecords(addr).stakeAmount` and the
 *      aggregate `totalSecurityStake()` (quorum denominator), so this mock
 *      exposes settable per-address stake plus an explicit total.
 */
contract MockSecurityEngineForGovernance {
    mapping(address => uint256) public stakeOf;
    uint256 public totalSecurityStake;

    /// @dev Set a voter's stake and bump the global total by the delta.
    function setStake(address account, uint256 amount) external {
        uint256 prev = stakeOf[account];
        stakeOf[account] = amount;
        totalSecurityStake = totalSecurityStake - prev + amount;
    }

    /// @dev Override the global staked supply independently (for quorum tests).
    function setTotalSecurityStake(uint256 amount) external {
        totalSecurityStake = amount;
    }

    /// @dev Matches ISecurityEngine.securityRecords tuple shape used by governance.
    function securityRecords(address account)
        external
        view
        returns (
            uint256 stakeAmount,
            uint256 effectiveStake,
            uint8 level,
            uint256 lastUpdate,
            uint256 totalSlashed,
            uint256 violationCount,
            uint256 reputationScore,
            uint256 totalEarned,
            bool isValidator
        )
    {
        uint256 s = stakeOf[account];
        return (s, s, 0, 0, 0, 0, 0, 0, false);
    }
}
