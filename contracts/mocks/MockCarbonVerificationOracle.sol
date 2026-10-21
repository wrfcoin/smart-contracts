// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockCarbonVerificationOracle {
    mapping(bytes32 => bool) public verifiedCredits;
    mapping(bytes32 => uint8) public requestStatus;

    function setVerificationStatus(bytes32 lifecycleId, bool verified) external {
        verifiedCredits[lifecycleId] = verified;
        requestStatus[lifecycleId] = verified ? 2 : 3;
    }

    function isVerified(bytes32 lifecycleId) external view returns (bool) {
        return verifiedCredits[lifecycleId];
    }

    function getRequestStatus(bytes32 lifecycleId) external view returns (uint8) {
        return requestStatus[lifecycleId];
    }
}
