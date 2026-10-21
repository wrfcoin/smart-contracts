// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@account-abstraction/contracts/interfaces/UserOperation.sol";
import "@account-abstraction/contracts/interfaces/IPaymaster.sol";

/**
 * @title MockAAEntryPoint
 * @notice Minimal entry point facade for local AA unit tests.
 */
contract MockAAEntryPoint {
    mapping(address => uint256) private _deposits;
    mapping(address => uint256) private _stakes;
    mapping(address => uint32) private _unstakeDelaySec;
    mapping(address => uint256) private _nonces;

    function balanceOf(address account) external view returns (uint256) {
        return _deposits[account];
    }

    function depositTo(address account) external payable {
        _deposits[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) external {
        require(_deposits[msg.sender] >= amount, "MockAAEntryPoint: insufficient deposit");
        _deposits[msg.sender] -= amount;
        (bool success, ) = withdrawAddress.call{value: amount}("");
        require(success, "MockAAEntryPoint: withdraw failed");
    }

    function addStake(uint32 unstakeDelaySec) external payable {
        _stakes[msg.sender] += msg.value;
        if (unstakeDelaySec > _unstakeDelaySec[msg.sender]) {
            _unstakeDelaySec[msg.sender] = unstakeDelaySec;
        }
    }

    function unlockStake() external {}

    function withdrawStake(address payable withdrawAddress) external {
        uint256 amount = _stakes[msg.sender];
        _stakes[msg.sender] = 0;
        (bool success, ) = withdrawAddress.call{value: amount}("");
        require(success, "MockAAEntryPoint: stake withdraw failed");
    }

    function getNonce(address sender, uint192) external view returns (uint256) {
        return _nonces[sender];
    }

    function setNonce(address sender, uint256 nonce) external {
        _nonces[sender] = nonce;
    }

    function callValidatePaymasterUserOp(
        address paymaster,
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        return IPaymaster(paymaster).validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    function callPostOp(
        address paymaster,
        IPaymaster.PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external {
        IPaymaster(paymaster).postOp(mode, context, actualGasCost);
    }

    receive() external payable {}
}
