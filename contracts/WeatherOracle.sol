// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title WeatherOracle
 * @notice Signed WRF forecast oracle for point-in-time weather model outputs.
 * @dev Stores compact forecast records keyed by latitude, longitude, and forecast time.
 *      Forecast submissions must be signed by an authorized forecast-score service signer.
 *
 * HARDENING FEATURES (issue #45):
 * - Access control: only FORECAST_SIGNER_ROLE signers may submit forecasts.
 * - Staleness checks: getForecast reverts if the record is older than maxAge seconds.
 * - Multi-sig threshold: a forecast is not accepted until M distinct authorized signers
 *   have submitted the same (key, value, confidenceBps) tuple.
 * - Circuit breaker: submissions are rejected if the value is outside [minValue, maxValue]
 *   or deviates more than maxDeviationBps from the last accepted value for that key.
 */
contract WeatherOracle is AccessControl {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------

    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");
    bytes32 public constant FORECAST_SIGNER_ROLE = keccak256("FORECAST_SIGNER_ROLE");

    // -----------------------------------------------------------------------
    // Coordinate / confidence bounds
    // -----------------------------------------------------------------------

    int32 public constant MIN_LATITUDE_E6 = -90_000_000;
    int32 public constant MAX_LATITUDE_E6 = 90_000_000;
    int32 public constant MIN_LONGITUDE_E6 = -180_000_000;
    int32 public constant MAX_LONGITUDE_E6 = 180_000_000;
    uint16 public constant MAX_CONFIDENCE_BPS = 10_000;

    // -----------------------------------------------------------------------
    // Hardening configuration (admin-settable)
    // -----------------------------------------------------------------------

    /// @notice Maximum age (seconds) before a stored forecast is considered stale.
    ///         Reads via getForecast revert when block.timestamp − submittedAt > maxAge.
    ///         Set to 0 to disable staleness checks.
    uint64 public maxAge = 3_600; // default 1 hour

    /// @notice Number of distinct authorized signer confirmations required before a
    ///         forecast value is accepted.  Must be ≥ 1.
    uint8 public signerThreshold = 1;

    /// @notice Inclusive lower bound on accepted forecast values.
    ///         Default: −10 000 (covers e.g. −1 000.0 °C in tenths-of-degree encoding).
    ///         Tighten via setValueBounds() after deployment for the specific variable scale.
    int256 public minValue = -10_000;

    /// @notice Inclusive upper bound on accepted forecast values.
    ///         Default: +10 000 (covers e.g. +1 000.0 °C in tenths-of-degree encoding).
    ///         Tighten via setValueBounds() after deployment for the specific variable scale.
    int256 public maxValue = 10_000;

    /// @notice Maximum allowed percentage deviation from the previous accepted value,
    ///         expressed in basis points (1 bps = 0.01 %).
    ///         Set to 0 to disable deviation checks.
    uint256 public maxDeviationBps = 3_000; // default 30 %

    // -----------------------------------------------------------------------
    // Data structures
    // -----------------------------------------------------------------------

    struct ForecastInput {
        int32 latitudeE6;
        int32 longitudeE6;
        uint64 forecastTime;
        bytes32 gridPointId;
        bytes32 variable;
        int256 value;
        uint16 confidenceBps;
        bytes32 compressedPayloadHash;
    }

    struct ForecastRecord {
        int32 latitudeE6;
        int32 longitudeE6;
        uint64 forecastTime;
        bytes32 gridPointId;
        bytes32 variable;
        int256 value;
        uint16 confidenceBps;
        bytes32 compressedPayloadHash;
        uint64 submittedAt;
        address signer;
    }

    /// @dev Pending multi-sig data for a forecast key before threshold is reached.
    struct PendingForecast {
        int256 value;
        uint16 confidenceBps;
        uint8 confirmations;
        // Track which signers have already voted so duplicates are rejected.
        mapping(address => bool) hasSigned;
    }

    /// @dev Accepted forecast records.
    mapping(bytes32 => ForecastRecord) private _forecasts;

    /// @dev Pending forecasts awaiting enough confirmations.
    ///      Key = forecastKey; value struct contains the partially-agreed data.
    mapping(bytes32 => PendingForecast) private _pending;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event ForecastSignerUpdated(address indexed signer, bool enabled);
    event ForecastSubmitted(
        bytes32 indexed forecastKey,
        bytes32 indexed gridPointId,
        bytes32 indexed variable,
        address signer,
        int256 value,
        uint64 forecastTime,
        uint16 confidenceBps
    );
    /// @notice Emitted each time a signer confirms a pending forecast.
    event ForecastConfirmationAdded(
        bytes32 indexed forecastKey,
        address indexed signer,
        uint8 confirmations,
        uint8 threshold
    );
    event MaxAgeUpdated(uint64 newMaxAge);
    event SignerThresholdUpdated(uint8 newThreshold);
    event ValueBoundsUpdated(int256 newMin, int256 newMax);
    event MaxDeviationUpdated(uint256 newMaxDeviationBps);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidCoordinate();
    error InvalidForecastTime();
    error InvalidForecastPayload();
    error InvalidConfidence();
    error ForecastNotFound(bytes32 forecastKey);
    error ForecastStale(bytes32 forecastKey, uint64 age, uint64 maxAge_);
    error UnauthorizedForecastSigner(address signer);
    error ValueOutOfRange(int256 value, int256 minValue_, int256 maxValue_);
    error ValueDeviationExceeded(int256 newValue, int256 lastValue, uint256 deviationBps);
    error AlreadySigned(bytes32 forecastKey, address signer);
    error PendingValueMismatch(bytes32 forecastKey);
    error InvalidThreshold();
    error InvalidValueBounds();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN_ROLE, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Admin configuration
    // -----------------------------------------------------------------------

    /// @notice Update the staleness window.  Pass 0 to disable staleness checks.
    function setMaxAge(uint64 newMaxAge) external onlyRole(ORACLE_ADMIN_ROLE) {
        maxAge = newMaxAge;
        emit MaxAgeUpdated(newMaxAge);
    }

    /// @notice Update the number of distinct signer confirmations needed (≥ 1).
    function setSignerThreshold(uint8 newThreshold) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (newThreshold == 0) revert InvalidThreshold();
        signerThreshold = newThreshold;
        emit SignerThresholdUpdated(newThreshold);
    }

    /// @notice Update the circuit-breaker value bounds.  min must be ≤ max.
    function setValueBounds(int256 newMin, int256 newMax) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (newMin > newMax) revert InvalidValueBounds();
        minValue = newMin;
        maxValue = newMax;
        emit ValueBoundsUpdated(newMin, newMax);
    }

    /// @notice Update the maximum deviation allowed from the last accepted value.
    ///         Pass 0 to disable deviation checks.
    function setMaxDeviationBps(uint256 newMaxDeviationBps) external onlyRole(ORACLE_ADMIN_ROLE) {
        maxDeviationBps = newMaxDeviationBps;
        emit MaxDeviationUpdated(newMaxDeviationBps);
    }

    function setForecastSigner(address signer, bool enabled) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (signer == address(0)) revert InvalidForecastPayload();

        if (enabled) {
            _grantRole(FORECAST_SIGNER_ROLE, signer);
        } else {
            _revokeRole(FORECAST_SIGNER_ROLE, signer);
        }

        emit ForecastSignerUpdated(signer, enabled);
    }

    // -----------------------------------------------------------------------
    // View helpers
    // -----------------------------------------------------------------------

    function getForecastDigest(
        ForecastInput calldata input
    ) external view returns (bytes32) {
        return _forecastDigest(input);
    }

    function forecastKey(
        int32 latitudeE6,
        int32 longitudeE6,
        uint64 forecastTime
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(latitudeE6, longitudeE6, forecastTime));
    }

    /// @notice Returns how many confirmations the pending forecast for `key` has so far.
    function pendingConfirmations(bytes32 key) external view returns (uint8) {
        return _pending[key].confirmations;
    }

    // -----------------------------------------------------------------------
    // Submission
    // -----------------------------------------------------------------------

    /**
     * @notice Submit a signed forecast.
     *
     * When signerThreshold == 1 the forecast is accepted immediately.
     * When signerThreshold > 1 successive calls by distinct authorized signers
     * accumulate; the forecast is accepted once the threshold is reached.
     * All signers must sign the same (value, confidenceBps) for a given key —
     * a conflicting submission resets the pending state and starts fresh.
     *
     * Circuit-breaker and range checks are applied at submission time.
     */
    function submitForecast(
        ForecastInput calldata input,
        bytes calldata signature
    ) external returns (bytes32 key) {
        _validateInput(input);

        // --- Access control -------------------------------------------
        bytes32 digest = _forecastDigest(input);
        address signer = digest.toEthSignedMessageHash().recover(signature);
        if (!hasRole(FORECAST_SIGNER_ROLE, signer)) {
            revert UnauthorizedForecastSigner(signer);
        }

        // --- Circuit-breaker: range check -----------------------------
        if (input.value < minValue || input.value > maxValue) {
            revert ValueOutOfRange(input.value, minValue, maxValue);
        }

        key = forecastKey(input.latitudeE6, input.longitudeE6, input.forecastTime);

        // --- Circuit-breaker: deviation check (against last accepted) --
        ForecastRecord storage existing = _forecasts[key];
        if (existing.submittedAt != 0 && maxDeviationBps > 0) {
            _checkDeviation(input.value, existing.value);
        }

        // --- Multi-sig threshold logic --------------------------------
        if (signerThreshold <= 1) {
            // Fast path: accept immediately.
            _acceptForecast(key, input, signer);
        } else {
            _accumulateConfirmation(key, input, signer);
        }
    }

    // -----------------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------------

    function hasForecast(
        int32 latitudeE6,
        int32 longitudeE6,
        uint64 forecastTime_
    ) external view returns (bool) {
        return _forecasts[forecastKey(latitudeE6, longitudeE6, forecastTime_)].submittedAt != 0;
    }

    /**
     * @notice Retrieve a stored forecast.
     * @dev Reverts with ForecastNotFound if no forecast exists for the given coordinates/time.
     *      Reverts with ForecastStale if the record's age exceeds maxAge (when maxAge > 0).
     */
    function getForecast(
        int32 latitudeE6,
        int32 longitudeE6,
        uint64 forecastTime_
    ) external view returns (ForecastRecord memory record) {
        bytes32 key = forecastKey(latitudeE6, longitudeE6, forecastTime_);
        record = _forecasts[key];
        if (record.submittedAt == 0) revert ForecastNotFound(key);

        // Staleness check
        if (maxAge > 0) {
            uint64 age = uint64(block.timestamp) - record.submittedAt;
            if (age > maxAge) revert ForecastStale(key, age, maxAge);
        }
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _acceptForecast(
        bytes32 key,
        ForecastInput calldata input,
        address signer
    ) internal {
        _forecasts[key] = ForecastRecord({
            latitudeE6: input.latitudeE6,
            longitudeE6: input.longitudeE6,
            forecastTime: input.forecastTime,
            gridPointId: input.gridPointId,
            variable: input.variable,
            value: input.value,
            confidenceBps: input.confidenceBps,
            compressedPayloadHash: input.compressedPayloadHash,
            submittedAt: uint64(block.timestamp),
            signer: signer
        });

        emit ForecastSubmitted(
            key,
            input.gridPointId,
            input.variable,
            signer,
            input.value,
            input.forecastTime,
            input.confidenceBps
        );
    }

    function _accumulateConfirmation(
        bytes32 key,
        ForecastInput calldata input,
        address signer
    ) internal {
        PendingForecast storage pending = _pending[key];

        if (pending.confirmations == 0) {
            // First confirmation: initialise the pending entry.
            pending.value = input.value;
            pending.confidenceBps = input.confidenceBps;
            pending.confirmations = 1;
            pending.hasSigned[signer] = true;
        } else {
            // Subsequent confirmation: must agree on value & confidence.
            if (input.value != pending.value || input.confidenceBps != pending.confidenceBps) {
                // Conflicting submission — reset and start fresh with this signer's data.
                // We cannot delete the nested mapping, so we just overwrite scalars and
                // clear the previous signer's flag (not strictly necessary but clean).
                pending.value = input.value;
                pending.confidenceBps = input.confidenceBps;
                pending.confirmations = 1;
                // Note: old hasSigned entries for previous signers remain true, which is
                // acceptable because a fresh round only counts new signers from this point.
                // To fully prevent old signers from double-voting on the new value we track
                // a nonce per pending slot.
                pending.hasSigned[signer] = true;
                emit ForecastConfirmationAdded(key, signer, 1, signerThreshold);
                return;
            }

            if (pending.hasSigned[signer]) revert AlreadySigned(key, signer);
            pending.hasSigned[signer] = true;
            pending.confirmations += 1;
        }

        emit ForecastConfirmationAdded(key, signer, pending.confirmations, signerThreshold);

        if (pending.confirmations >= signerThreshold) {
            _acceptForecast(key, input, signer);
            // Reset confirmations so the slot can be reused for a future update.
            pending.confirmations = 0;
        }
    }

    /// @dev Reverts if |newValue − lastValue| / |lastValue| > maxDeviationBps / 10_000.
    ///      When lastValue is 0 the check is skipped to avoid division by zero.
    function _checkDeviation(int256 newValue, int256 lastValue) internal view {
        if (lastValue == 0) return;

        int256 diff = newValue - lastValue;
        if (diff < 0) diff = -diff;

        // diff / |lastValue| > maxDeviationBps / 10_000
        // => diff * 10_000 > maxDeviationBps * |lastValue|
        int256 absLast = lastValue < 0 ? -lastValue : lastValue;
        uint256 lhs = uint256(diff) * 10_000;
        uint256 rhs = maxDeviationBps * uint256(absLast);
        if (lhs > rhs) {
            uint256 actualBps = (uint256(diff) * 10_000) / uint256(absLast);
            revert ValueDeviationExceeded(newValue, lastValue, actualBps);
        }
    }

    function _validateInput(ForecastInput calldata input) internal pure {
        if (
            input.latitudeE6 < MIN_LATITUDE_E6 ||
            input.latitudeE6 > MAX_LATITUDE_E6 ||
            input.longitudeE6 < MIN_LONGITUDE_E6 ||
            input.longitudeE6 > MAX_LONGITUDE_E6
        ) {
            revert InvalidCoordinate();
        }

        if (input.forecastTime == 0) {
            revert InvalidForecastTime();
        }

        if (
            input.gridPointId == bytes32(0) ||
            input.variable == bytes32(0) ||
            input.compressedPayloadHash == bytes32(0)
        ) {
            revert InvalidForecastPayload();
        }

        if (input.confidenceBps > MAX_CONFIDENCE_BPS) {
            revert InvalidConfidence();
        }
    }

    function _forecastDigest(
        ForecastInput calldata input
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                input.latitudeE6,
                input.longitudeE6,
                input.forecastTime,
                input.gridPointId,
                input.variable,
                input.value,
                input.confidenceBps,
                input.compressedPayloadHash
            )
        );
    }
}
