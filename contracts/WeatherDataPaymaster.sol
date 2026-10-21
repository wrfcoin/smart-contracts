// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title WeatherDataPaymaster
 * @notice ERC-4337-style paymaster for fee-less weather data submissions.
 * @dev Sponsors gas only for approved weather-data calldata routed to approved
 *      validator contracts. Supports direct calldata, `execute(address,uint256,bytes)`,
 *      and `executeBatch(address[],uint256[],bytes[])` smart-account wrappers.
 */
contract WeatherDataPaymaster is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant PAYMASTER_ADMIN_ROLE = keccak256("PAYMASTER_ADMIN_ROLE");

    uint256 public constant DAY = 1 days;

    bytes4 public constant UPDATE_WEATHER_SELECTOR =
        bytes4(keccak256("updateWeatherData(bytes32,(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint256))"));
    bytes4 public constant BATCH_UPDATE_WEATHER_SELECTOR =
        bytes4(keccak256("batchUpdateWeatherData(bytes32[],(bytes32,uint256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint256)[])"));
    bytes4 public constant EXECUTE_SELECTOR =
        bytes4(keccak256("execute(address,uint256,bytes)"));
    bytes4 public constant EXECUTE_BATCH_SELECTOR =
        bytes4(keccak256("executeBatch(address[],uint256[],bytes[])"));

    struct UserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        bytes32 accountGasLimits;
        uint256 preVerificationGas;
        bytes32 gasFees;
        bytes paymasterAndData;
        bytes signature;
    }

    struct DailyRateLimit {
        uint256 maxTransactionsPerDay;
        uint256 windowStart;
        uint256 sponsoredCount;
    }

    mapping(address => bool) public sponsoredTargets;
    mapping(address => DailyRateLimit) private _rateLimits;

    uint256 public defaultMaxTransactionsPerDay;
    uint256 public minimumPaymasterBalance;

    event SponsoredTargetUpdated(address indexed target, bool allowed);
    event DefaultRateLimitUpdated(uint256 previousLimit, uint256 newLimit);
    event AddressRateLimitUpdated(address indexed contributor, uint256 newLimit);
    event TreasuryFunded(address indexed funder, uint256 amount, uint256 newBalance);
    event TreasuryWithdrawal(address indexed recipient, uint256 amount, uint256 newBalance);
    event MinimumBalanceUpdated(uint256 previousMinimum, uint256 newMinimum);
    event MinimumBalanceAlert(uint256 currentBalance, uint256 minimumBalance);
    event SponsorshipValidated(
        address indexed contributor,
        address indexed target,
        bytes4 indexed selector,
        uint256 sponsoredCount,
        uint256 windowStart
    );

    error WeatherDataPaymasterUnsupportedCall();
    error WeatherDataPaymasterTargetNotAllowed();
    error WeatherDataPaymasterInsufficientBalance();
    error WeatherDataPaymasterRateLimitExceeded();
    error WeatherDataPaymasterInvalidArrayLengths();
    error WeatherDataPaymasterZeroAddress();
    error WeatherDataPaymasterZeroLimit();
    error WeatherDataPaymasterZeroAmount();

    constructor(
        address admin,
        address initialSponsoredTarget,
        uint256 defaultDailyLimit,
        uint256 minimumBalance_
    ) {
        if (admin == address(0) || initialSponsoredTarget == address(0)) {
            revert WeatherDataPaymasterZeroAddress();
        }
        if (defaultDailyLimit == 0) revert WeatherDataPaymasterZeroLimit();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAYMASTER_ADMIN_ROLE, admin);

        sponsoredTargets[initialSponsoredTarget] = true;
        emit SponsoredTargetUpdated(initialSponsoredTarget, true);

        defaultMaxTransactionsPerDay = defaultDailyLimit;
        minimumPaymasterBalance = minimumBalance_;
    }

    receive() external payable {
        emit TreasuryFunded(msg.sender, msg.value, address(this).balance);
        _emitMinimumBalanceAlertIfNeeded();
    }

    function fundTreasury() external payable whenNotPaused {
        emit TreasuryFunded(msg.sender, msg.value, address(this).balance);
        _emitMinimumBalanceAlertIfNeeded();
    }

    function setSponsoredTarget(
        address target,
        bool allowed
    ) external onlyRole(PAYMASTER_ADMIN_ROLE) {
        if (target == address(0)) revert WeatherDataPaymasterZeroAddress();
        sponsoredTargets[target] = allowed;
        emit SponsoredTargetUpdated(target, allowed);
    }

    function setDefaultRateLimit(
        uint256 newLimit
    ) external onlyRole(PAYMASTER_ADMIN_ROLE) {
        if (newLimit == 0) revert WeatherDataPaymasterZeroLimit();
        uint256 previousLimit = defaultMaxTransactionsPerDay;
        defaultMaxTransactionsPerDay = newLimit;
        emit DefaultRateLimitUpdated(previousLimit, newLimit);
    }

    function setAddressRateLimit(
        address contributor,
        uint256 newLimit
    ) external onlyRole(PAYMASTER_ADMIN_ROLE) {
        if (contributor == address(0)) revert WeatherDataPaymasterZeroAddress();
        if (newLimit == 0) revert WeatherDataPaymasterZeroLimit();

        DailyRateLimit storage limit = _rateLimits[contributor];
        limit.maxTransactionsPerDay = newLimit;
        emit AddressRateLimitUpdated(contributor, newLimit);
    }

    function setMinimumPaymasterBalance(
        uint256 newMinimum
    ) external onlyRole(PAYMASTER_ADMIN_ROLE) {
        uint256 previousMinimum = minimumPaymasterBalance;
        minimumPaymasterBalance = newMinimum;
        emit MinimumBalanceUpdated(previousMinimum, newMinimum);
        _emitMinimumBalanceAlertIfNeeded();
    }

    function withdrawTreasury(
        address payable recipient,
        uint256 amount
    ) external onlyRole(PAYMASTER_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert WeatherDataPaymasterZeroAddress();
        if (amount == 0) revert WeatherDataPaymasterZeroAmount();
        if (amount > address(this).balance) revert WeatherDataPaymasterInsufficientBalance();

        (bool success,) = recipient.call{value: amount}("");
        require(success, "WeatherDataPaymaster: withdraw failed");

        emit TreasuryWithdrawal(recipient, amount, address(this).balance);
        _emitMinimumBalanceAlertIfNeeded();
    }

    /**
     * @notice ERC-4337 paymaster validation entrypoint.
     * @dev Returns an encoded sponsorship context and validationData=0 on
     *      success. Reverts if the operation is not a supported weather-data
     *      submission or if funding / rate-limit checks fail.
     */
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32,
        uint256 requiredPreFund
    ) external whenNotPaused nonReentrant returns (bytes memory context, uint256 validationData) {
        if (address(this).balance < requiredPreFund) {
            revert WeatherDataPaymasterInsufficientBalance();
        }
        _emitMinimumBalanceAlertIfNeeded();

        (address target, bytes4 selector) = _extractWeatherCall(userOp.callData);
        if (!sponsoredTargets[target]) {
            revert WeatherDataPaymasterTargetNotAllowed();
        }

        DailyRateLimit storage limit = _rateLimits[userOp.sender];
        uint256 windowStart = _normalizeWindow(limit.windowStart);
        if (windowStart != limit.windowStart) {
            limit.windowStart = windowStart;
            limit.sponsoredCount = 0;
        }

        uint256 maxTransactions = limit.maxTransactionsPerDay == 0
            ? defaultMaxTransactionsPerDay
            : limit.maxTransactionsPerDay;

        if (limit.sponsoredCount >= maxTransactions) {
            revert WeatherDataPaymasterRateLimitExceeded();
        }

        limit.sponsoredCount += 1;

        emit SponsorshipValidated(
            userOp.sender,
            target,
            selector,
            limit.sponsoredCount,
            limit.windowStart
        );

        return (abi.encode(userOp.sender, target, selector), 0);
    }

    function getRateLimit(
        address contributor
    ) external view returns (uint256 maxTransactionsPerDay, uint256 windowStart, uint256 sponsoredCount) {
        DailyRateLimit storage limit = _rateLimits[contributor];
        maxTransactionsPerDay = limit.maxTransactionsPerDay == 0
            ? defaultMaxTransactionsPerDay
            : limit.maxTransactionsPerDay;
        windowStart = _normalizeWindow(limit.windowStart);
        sponsoredCount = windowStart == limit.windowStart ? limit.sponsoredCount : 0;
    }

    function pause() external onlyRole(PAYMASTER_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAYMASTER_ADMIN_ROLE) {
        _unpause();
    }

    function _extractWeatherCall(
        bytes calldata accountCallData
    ) internal view returns (address target, bytes4 selector) {
        if (accountCallData.length < 4) revert WeatherDataPaymasterUnsupportedCall();

        bytes4 outerSelector = bytes4(accountCallData[:4]);

        if (outerSelector == EXECUTE_SELECTOR) {
            uint256 value;
            bytes memory innerCallData;
            (target, value, innerCallData) = abi.decode(
                accountCallData[4:],
                (address, uint256, bytes)
            );
            value;
            selector = _weatherSelector(innerCallData);
            return (target, selector);
        }

        if (outerSelector == EXECUTE_BATCH_SELECTOR) {
            (
                address[] memory targets,
                uint256[] memory values,
                bytes[] memory innerCalls
            ) = abi.decode(accountCallData[4:], (address[], uint256[], bytes[]));

            if (targets.length == 0 || targets.length != values.length || targets.length != innerCalls.length) {
                revert WeatherDataPaymasterInvalidArrayLengths();
            }

            target = targets[0];
            selector = _weatherSelector(innerCalls[0]);

            for (uint256 i = 1; i < targets.length; i++) {
                if (targets[i] != target) revert WeatherDataPaymasterUnsupportedCall();
                if (_weatherSelector(innerCalls[i]) != selector) {
                    revert WeatherDataPaymasterUnsupportedCall();
                }
            }

            return (target, selector);
        }

        selector = _weatherSelector(accountCallData);
        return (address(0), selector);
    }

    function _weatherSelector(bytes memory callData) internal pure returns (bytes4 selector) {
        if (callData.length < 4) revert WeatherDataPaymasterUnsupportedCall();
        selector = bytes4(callData);
        if (selector != UPDATE_WEATHER_SELECTOR && selector != BATCH_UPDATE_WEATHER_SELECTOR) {
            revert WeatherDataPaymasterUnsupportedCall();
        }
    }

    function _normalizeWindow(uint256 storedWindowStart) internal view returns (uint256) {
        uint256 currentWindow = (block.timestamp / DAY) * DAY;
        if (storedWindowStart == 0 || storedWindowStart < currentWindow) {
            return currentWindow;
        }
        return storedWindowStart;
    }

    function _emitMinimumBalanceAlertIfNeeded() internal {
        if (address(this).balance < minimumPaymasterBalance) {
            emit MinimumBalanceAlert(address(this).balance, minimumPaymasterBalance);
        }
    }
}
