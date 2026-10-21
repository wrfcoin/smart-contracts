// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@account-abstraction/contracts/core/BasePaymaster.sol";
import "@account-abstraction/contracts/interfaces/UserOperation.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import "./WrfcoinAccount.sol";

/**
 * @title WrfcoinPaymaster
 * @notice ERC-4337 paymaster that only sponsors weather submission user ops
 * signed by an authorized EVM oracle address.
 */
contract WrfcoinPaymaster is BasePaymaster, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 public constant MAX_SPONSORED_GAS = 500_000;
    bytes4 public constant EXECUTE_WEATHER_SUBMISSION_SELECTOR =
        WrfcoinAccount.executeWeatherSubmission.selector;

    mapping(address => bool) public authorizedOracles;
    address public relayer;

    event OracleAuthorizationUpdated(address indexed oracle, bool authorized);
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event OraclesSynced(uint256 added, uint256 removed);
    event WeatherSubmissionSponsored(
        address indexed oracle,
        address indexed sender,
        bytes32 indexed weatherDataHash,
        uint256 actualGasCost
    );

    error WrfcoinPaymasterInvalidPaymasterData();
    error WrfcoinPaymasterUnauthorizedOracle();
    error WrfcoinPaymasterInvalidOracleSignature();
    error WrfcoinPaymasterUnsupportedCall();
    error WrfcoinPaymasterGasLimitTooHigh();
    error WrfcoinPaymasterExpiredSponsorship();
    error WrfcoinPaymasterWeatherHashMismatch();
    error WrfcoinPaymasterZeroAddress();

    constructor(
        IEntryPoint entryPoint_,
        address initialOwner
    ) BasePaymaster(entryPoint_) Ownable(initialOwner) {
        require(initialOwner != address(0), "WrfcoinPaymaster: zero owner");
    }

    receive() external payable {}

    function addOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert WrfcoinPaymasterZeroAddress();
        authorizedOracles[oracle] = true;
        emit OracleAuthorizationUpdated(oracle, true);
    }

    function removeOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert WrfcoinPaymasterZeroAddress();
        authorizedOracles[oracle] = false;
        emit OracleAuthorizationUpdated(oracle, false);
    }

    function setRelayer(address _relayer) external onlyOwner {
        emit RelayerUpdated(relayer, _relayer);
        relayer = _relayer;
    }

    /**
     * @notice Batch-sync the authorized oracle set. Callable by relayer or owner.
     * @dev Intended for a backend service that watches core4's OracleRegistry.
     */
    function syncOracles(
        address[] calldata toAdd,
        address[] calldata toRemove
    ) external {
        require(msg.sender == owner() || msg.sender == relayer, "WrfcoinPaymaster: unauthorized");
        for (uint256 i = 0; i < toAdd.length; i++) {
            if (toAdd[i] != address(0) && !authorizedOracles[toAdd[i]]) {
                authorizedOracles[toAdd[i]] = true;
                emit OracleAuthorizationUpdated(toAdd[i], true);
            }
        }
        for (uint256 i = 0; i < toRemove.length; i++) {
            if (toRemove[i] != address(0) && authorizedOracles[toRemove[i]]) {
                authorizedOracles[toRemove[i]] = false;
                emit OracleAuthorizationUpdated(toRemove[i], false);
            }
        }
        emit OraclesSynced(toAdd.length, toRemove.length);
    }

    function _validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32,
        uint256
    ) internal view override returns (bytes memory context, uint256 validationData) {
        if (userOp.paymasterAndData.length <= 20) {
            revert WrfcoinPaymasterInvalidPaymasterData();
        }
        if (userOp.callGasLimit > MAX_SPONSORED_GAS) {
            revert WrfcoinPaymasterGasLimitTooHigh();
        }
        if (userOp.callData.length < 4) {
            revert WrfcoinPaymasterUnsupportedCall();
        }

        bytes4 selector = bytes4(userOp.callData[:4]);
        if (selector != EXECUTE_WEATHER_SUBMISSION_SELECTOR) {
            revert WrfcoinPaymasterUnsupportedCall();
        }

        bytes calldata encoded = userOp.paymasterAndData[20:];
        (
            address oracle,
            bytes32 weatherDataHash,
            uint48 validUntil,
            bytes memory signature
        ) = abi.decode(encoded, (address, bytes32, uint48, bytes));

        if (!authorizedOracles[oracle]) {
            revert WrfcoinPaymasterUnauthorizedOracle();
        }
        if (validUntil < block.timestamp) {
            revert WrfcoinPaymasterExpiredSponsorship();
        }

        bytes memory packetData = abi.decode(userOp.callData[4:], (bytes));
        if (keccak256(packetData) != weatherDataHash) {
            revert WrfcoinPaymasterWeatherHashMismatch();
        }

        bytes32 sponsorshipDigest = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                userOp.sender,
                keccak256(userOp.callData),
                weatherDataHash,
                validUntil
            )
        ).toEthSignedMessageHash();

        if (sponsorshipDigest.recover(signature) != oracle) {
            revert WrfcoinPaymasterInvalidOracleSignature();
        }

        context = abi.encode(oracle, userOp.sender, weatherDataHash);
        validationData = _packValidationData(false, validUntil, 0);
    }

    function _postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost
    ) internal override nonReentrant {
        (address oracle, address sender, bytes32 weatherDataHash) = abi.decode(
            context,
            (address, address, bytes32)
        );
        emit WeatherSubmissionSponsored(oracle, sender, weatherDataHash, actualGasCost);
    }
}
