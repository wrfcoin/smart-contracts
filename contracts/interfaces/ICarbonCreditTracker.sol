// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICarbonCreditTracker {
    function setVerificationPending(bytes32 lifecycleId) external;
    function confirmVerification(bytes32 lifecycleId) external;
    function rejectVerification(bytes32 lifecycleId) external;
    function setDisputed(bytes32 lifecycleId) external;
    function resolveDispute(bytes32 lifecycleId, bool verified) external;
}
