// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IWeatherDataValidator
 * @notice Interface for weather data validation contract
 */
interface IWeatherDataValidator {
    /**
     * @notice Report data quality violation
     * @param participant Address of participant who violated
     * @param violationType Type of violation
     * @param evidenceHash Hash of evidence
     */
    function reportDataQualityViolation(
        address participant,
        uint8 violationType,
        bytes32 evidenceHash
    ) external;

    /**
     * @notice Validate weather data submission
     * @param participant Address of participant
     * @param dataHash Hash of weather data
     * @return isValid True if data is valid
     * @return qualityScore Quality score (0-100)
     */
    function validateWeatherData(address participant, bytes32 dataHash)
        external
        view
        returns (bool isValid, uint256 qualityScore);

    /**
     * @notice Get participant's data quality history
     * @param participant Address of participant
     * @return averageQuality Average quality score
     * @return violationCount Number of violations
     * @return lastViolation Timestamp of last violation
     */
    function getDataQualityHistory(address participant)
        external
        view
        returns (
            uint256 averageQuality,
            uint256 violationCount,
            uint256 lastViolation
        );
}