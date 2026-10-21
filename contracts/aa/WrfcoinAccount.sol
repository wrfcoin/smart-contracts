// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@account-abstraction/contracts/core/BaseAccount.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title WrfcoinAccount
 * @notice Minimal ERC-4337 account for WRFCoin weather relaying.
 * @dev The weather-specific helper emits a relay event instead of attempting any
 * off-chain network interaction.
 */
contract WrfcoinAccount is BaseAccount, Ownable2Step {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    IEntryPoint private immutable _entryPoint;

    event WeatherSubmissionRequested(
        address indexed account,
        bytes32 indexed packetHash,
        bytes packetData
    );

    constructor(IEntryPoint entryPoint_, address initialOwner) Ownable(initialOwner) {
        _entryPoint = entryPoint_;
    }

    receive() external payable {}

    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireFromEntryPointOrOwner();
        _call(dest, value, func);
    }

    /// @notice Execute a batch of calls, each with value = 0.
    /// @dev Retained for ABI compatibility with callers that don't pass ETH per call.
    function executeBatch(address[] calldata dest, bytes[] calldata func) external {
        _requireFromEntryPointOrOwner();
        require(dest.length == func.length, "WrfcoinAccount: wrong array lengths");

        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], 0, func[i]);
        }
    }

    /// @notice Execute a batch of calls each with an explicit ETH value.
    /// @dev FIX for audit finding aa/WrfcoinAccount.sol:43: the two-argument variant
    ///      hard-codes value=0, which prevents the account from sending ETH to multiple
    ///      destinations in a single UserOperation. This overload adds a `values` array
    ///      so payable batch calls work correctly.
    /// @param dest   Array of target addresses.
    /// @param values Array of ETH amounts (wei) to forward to each call.
    /// @param func   Array of encoded calldata for each call.
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata values,
        bytes[] calldata func
    ) external {
        _requireFromEntryPointOrOwner();
        require(
            dest.length == values.length && dest.length == func.length,
            "WrfcoinAccount: wrong array lengths"
        );
        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], values[i], func[i]);
        }
    }

    function executeWeatherSubmission(bytes calldata packetData) external {
        _requireFromEntryPointOrOwner();
        require(packetData.length > 0, "WrfcoinAccount: empty packet");

        emit WeatherSubmissionRequested(address(this), keccak256(packetData), packetData);
    }

    function addDeposit() external payable onlyOwner {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) external onlyOwner {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    function _requireFromEntryPointOrOwner() internal view {
        require(
            msg.sender == address(entryPoint()) || msg.sender == owner(),
            "WrfcoinAccount: not owner or EntryPoint"
        );
    }

    function _validateSignature(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) internal view override returns (uint256 validationData) {
        bytes32 digest = userOpHash.toEthSignedMessageHash();
        if (digest.recover(userOp.signature) != owner()) {
            return SIG_VALIDATION_FAILED;
        }
        return 0;
    }

    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
