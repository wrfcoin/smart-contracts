// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockComprehensiveFraudDetection
 * @notice Minimal mock for FraudPreventionIntegrationManager testing.
 *         Only implements getAddressStatus (used via try/catch in cross-system validation).
 */
contract MockComprehensiveFraudDetection {
    function getAddressStatus(address)
        external
        pure
        returns (bool isQuarantined, uint256 riskScore, uint256 trustScore)
    {
        return (false, 0, 100);
    }
}

/**
 * @title MockEnhancedFraudPreventionSystem
 * @notice Minimal mock. Exposes TrustLevel and PreventionLevel enums plus getRiskAssessment.
 */
contract MockEnhancedFraudPreventionSystem {
    enum PreventionLevel { NONE, MONITORING, RATE_LIMITED, RESTRICTED, QUARANTINED, BANNED }
    enum TrustLevel { UNTRUSTED, PROVISIONAL, ESTABLISHED, VERIFIED, TRUSTED, HIGHLY_TRUSTED }

    function getRiskAssessment(address)
        external
        pure
        returns (uint256 currentRisk, TrustLevel trustLevel, PreventionLevel preventionLevel, bool interventionRequired)
    {
        return (0, TrustLevel.ESTABLISHED, PreventionLevel.NONE, false);
    }
}

/**
 * @title MockRealTimeFraudMonitor
 * @notice Minimal mock. Exposes MonitoringLevel enum and configureMonitoring stub.
 */
contract MockRealTimeFraudMonitor {
    enum MonitoringLevel { DISABLED, BASIC, ENHANCED, INTENSIVE, MAXIMUM }

    function configureMonitoring(
        address,
        MonitoringLevel,
        bool,
        bool,
        bool
    ) external {}
}
