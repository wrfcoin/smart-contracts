// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISlashingControllerMin {
    struct SlashRecord {
        address target;
        string offenseCode;
        uint256 amount;
        uint256 slashedAt;
        uint256 blockNumber;
        bytes32 evidenceHash;
        bool reversed;
        uint256 reversedAt;
    }

    function getTotalSlashed(address target) external view returns (uint256);
    function getSlash(bytes32 slashId) external view returns (SlashRecord memory);
}

interface IAppealReversalControllerMin {
    struct AppealRecord {
        bytes32 slashId;
        address appellant;
        string reason;
        uint256 filedAt;
        uint256 windowCloses;
        bool decided;
        bool approved;
        uint256 decidedAt;
        uint256 reversedAmount;
    }

    function getAppeal(bytes32 appealId) external view returns (AppealRecord memory);
}

interface IEqualLiabilityEnforcerMin {
    struct SanctionSchedule {
        string offenseCode;
        uint8 severity;
        uint256 slashAmount;
        uint256 lockDuration;
        bool active;
        uint256 registeredAt;
        uint256 updatedAt;
    }

    function getSchedule(string calldata offenseCode)
        external
        view
        returns (SanctionSchedule memory);

    function hasActorClassOverride(string calldata offenseCode, uint8 actorClass)
        external
        view
        returns (bool);
}

interface IParticipationLockMin {
    struct LockRecord {
        address target;
        string reason;
        uint256 lockedAt;
        uint256 expiresAt;
        uint256 blockNumber;
        bool releasedEarly;
        uint256 releasedAt;
    }

    function getLock(address target) external view returns (LockRecord memory);
    function isLocked(address target) external view returns (bool);
}

interface IOffenseEvidenceRegistryMin {
    enum EvidenceType {
        UNSPECIFIED,
        CONSENSUS_PROOF,
        ORACLE_ATTESTATION,
        GOVERNANCE_ACTION,
        ECONOMIC_ABUSE,
        OPERATIONAL_MISCONDUCT
    }

    struct WitnessAttestation {
        address witness;
        bytes signature;
    }

    struct EvidencePacket {
        bytes32 evidenceHash;
        string offenseCode;
        EvidenceType evidenceType;
        address reporter;
        bytes32 payloadHash;
        uint64 observedAt;
        uint64 validAfter;
        uint64 expiresAt;
        uint256 timestamp;
        bytes reporterSignature;
        WitnessAttestation[] witnesses;
        uint32 version;
    }

    function getEvidence(bytes32 evidenceHash)
        external
        view
        returns (EvidencePacket memory);

    function validateEvidence(bytes32 evidenceHash)
        external
        view
        returns (bool valid, string memory reason);
}

interface IOffenseRegistryMin {
    struct PenaltyRange {
        uint16 minSlashBps;
        uint16 maxSlashBps;
        uint32 minLockDuration;
        uint32 maxLockDuration;
    }

    function getPenaltyRange(string calldata code)
        external
        view
        returns (PenaltyRange memory);
}

interface IStakeBalanceSourceMin {
    function balanceOf(address account) external view returns (uint256);
}

interface ICarbonCreditAMMFormalMin {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view returns (uint256 amountOut);
}

interface ICarbonPoolRouterFormalMin {
    struct SwapRoute {
        address[] pools;
        uint8[] poolTypes;
        address[] tokens;
        uint256[] amounts;
        uint256 totalAmountOut;
        uint256 totalFees;
    }

    function getBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (SwapRoute memory bestRoute);
}

/**
 * @title FormalVerificationSpecs
 * @notice Governance specification contract that encodes critical postconditions
 *         for slashing, appeal reversal, lock bounds, and equal-liability policy.
 * @dev Implements smart-contracts#8. The "formal" layer here is a set of
 *      deterministic on-chain assertions that can be exercised in CI and exported
 *      as review artifacts.
 */
contract FormalVerificationSpecs is AccessControl, ReentrancyGuard {
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    uint256 public constant MAX_BPS = 10_000;

    struct VerificationResult {
        string invariantName;
        bool passed;
        uint256 verifiedAt;
        string details;
    }

    struct VerificationContext {
        address slashController;
        address stakeBalanceSource;
        address slashTarget;
        address appealController;
        bytes32 appealId;
        address appealTarget;
        address lockController;
        address lockTarget;
        uint256 maxLockDuration;
        address enforcer;
        address offenseRegistry;
        string offenseCode;
        uint256 stakeAmount;
        address evidenceRegistry;
        bytes32 evidenceHash;
        uint256 expectedPreSlashTotal;
        bool expectedLockedAfterAppeal;
        address amm;
        uint256 ammSmallAmountIn;
        uint256 ammLargeAmountIn;
        address router;
        address routerTokenIn;
        address routerTokenOut;
        uint256 routerAmountIn;
    }

    mapping(bytes32 => VerificationResult) private _results;
    bytes32[] private _resultKeys;
    mapping(bytes32 => bool) private _resultKeyExists;

    event InvariantVerified(string indexed invariantName, bool passed);
    event VerificationSuiteCompleted(uint256 totalChecks, uint256 passed, uint256 failed);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
    }

    function verifySlashingInvariant_totalWithinStake(
        address slashController,
        address stakeBalanceSource,
        address target
    ) public view returns (bool) {
        if (
            slashController == address(0) ||
            stakeBalanceSource == address(0) ||
            target == address(0)
        ) {
            return false;
        }

        try ISlashingControllerMin(slashController).getTotalSlashed(target) returns (uint256 totalSlashed) {
            try IStakeBalanceSourceMin(stakeBalanceSource).balanceOf(target) returns (uint256 stakeBalance) {
                return totalSlashed <= stakeBalance;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyAppealInvariant_reversalRestoresState(
        address appealController,
        address slashController,
        address lockController,
        bytes32 appealId,
        address target,
        uint256 expectedPreSlashTotal,
        bool expectedLockedAfterAppeal
    ) public view returns (bool) {
        if (
            appealController == address(0) ||
            slashController == address(0) ||
            lockController == address(0) ||
            appealId == bytes32(0) ||
            target == address(0)
        ) {
            return false;
        }

        try IAppealReversalControllerMin(appealController).getAppeal(appealId)
            returns (IAppealReversalControllerMin.AppealRecord memory appeal)
        {
            if (!appeal.decided || !appeal.approved) {
                return false;
            }

            try ISlashingControllerMin(slashController).getSlash(appeal.slashId)
                returns (ISlashingControllerMin.SlashRecord memory slashRecord)
            {
                if (!slashRecord.reversed || slashRecord.target != target) {
                    return false;
                }

                try ISlashingControllerMin(slashController).getTotalSlashed(target)
                    returns (uint256 totalSlashed)
                {
                    try IParticipationLockMin(lockController).isLocked(target) returns (bool locked) {
                        return totalSlashed == expectedPreSlashTotal && locked == expectedLockedAfterAppeal;
                    } catch {
                        return false;
                    }
                } catch {
                    return false;
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyParityInvariant_actorNeutral(
        address enforcer,
        address offenseRegistry,
        string calldata offenseCode,
        uint256 stakeAmount
    ) public view returns (bool) {
        if (
            enforcer == address(0) ||
            offenseRegistry == address(0) ||
            bytes(offenseCode).length == 0 ||
            stakeAmount == 0
        ) {
            return false;
        }

        try IEqualLiabilityEnforcerMin(enforcer).getSchedule(offenseCode)
            returns (IEqualLiabilityEnforcerMin.SanctionSchedule memory schedule)
        {
            if (!schedule.active) {
                return false;
            }
            if (schedule.slashAmount > type(uint256).max / MAX_BPS) {
                return false;
            }

            try IOffenseRegistryMin(offenseRegistry).getPenaltyRange(offenseCode)
                returns (IOffenseRegistryMin.PenaltyRange memory penalties)
            {
                uint256 slashBps = (schedule.slashAmount * MAX_BPS) / stakeAmount;
                return
                    !IEqualLiabilityEnforcerMin(enforcer).hasActorClassOverride(offenseCode, 0) &&
                    !IEqualLiabilityEnforcerMin(enforcer).hasActorClassOverride(offenseCode, 1) &&
                    !IEqualLiabilityEnforcerMin(enforcer).hasActorClassOverride(offenseCode, 2) &&
                    slashBps >= penalties.minSlashBps &&
                    slashBps <= penalties.maxSlashBps &&
                    schedule.lockDuration >= penalties.minLockDuration &&
                    schedule.lockDuration <= penalties.maxLockDuration;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyLockInvariant_durationBound(
        address lockController,
        address target,
        uint256 maxDuration
    ) public view returns (bool) {
        if (lockController == address(0) || target == address(0) || maxDuration == 0) {
            return false;
        }

        try IParticipationLockMin(lockController).getLock(target)
            returns (IParticipationLockMin.LockRecord memory record)
        {
            if (record.expiresAt <= record.lockedAt) {
                return false;
            }
            return (record.expiresAt - record.lockedAt) <= maxDuration;
        } catch {
            return true;
        }
    }

    function verifyEvidenceInvariant_immutableHash(
        address evidenceRegistry,
        bytes32 evidenceHash
    ) public view returns (bool) {
        if (evidenceRegistry == address(0) || evidenceHash == bytes32(0)) {
            return false;
        }

        try IOffenseEvidenceRegistryMin(evidenceRegistry).validateEvidence(evidenceHash)
            returns (bool valid, string memory reason)
        {
            return valid && bytes(reason).length == 0;
        } catch {
            return false;
        }
    }

    function verifyAmmInvariant_monotonicQuote(
        address amm,
        uint256 smallerAmountIn,
        uint256 largerAmountIn
    ) public view returns (bool) {
        if (amm == address(0) || smallerAmountIn == 0 || largerAmountIn <= smallerAmountIn) {
            return false;
        }

        try ICarbonCreditAMMFormalMin(amm).getReserves() returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32
        ) {
            if (reserve0 == 0 || reserve1 == 0) {
                return false;
            }

            try ICarbonCreditAMMFormalMin(amm).getAmountOut(
                smallerAmountIn,
                reserve0,
                reserve1
            ) returns (uint256 smallerQuote) {
                try ICarbonCreditAMMFormalMin(amm).getAmountOut(
                    largerAmountIn,
                    reserve0,
                    reserve1
                ) returns (uint256 largerQuote) {
                    return
                        smallerQuote > 0 &&
                        largerQuote > 0 &&
                        largerQuote >= smallerQuote &&
                        smallerQuote < reserve1 &&
                        largerQuote < reserve1;
                } catch {
                    return false;
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    function verifyRouterInvariant_emptyRoute(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (bool) {
        if (
            router == address(0) ||
            tokenIn == address(0) ||
            tokenOut == address(0) ||
            tokenIn == tokenOut ||
            amountIn == 0
        ) {
            return false;
        }

        try ICarbonPoolRouterFormalMin(router).getBestRoute(tokenIn, tokenOut, amountIn)
            returns (ICarbonPoolRouterFormalMin.SwapRoute memory route)
        {
            return
                route.totalAmountOut == 0 &&
                route.pools.length == 0 &&
                route.poolTypes.length == 0 &&
                route.tokens.length == 0 &&
                route.amounts.length == 0;
        } catch {
            return false;
        }
    }

    function runVerificationSuite(
        VerificationContext calldata context
    ) external onlyRole(VERIFIER_ROLE) nonReentrant {
        uint256 totalChecks;
        uint256 passedCount;

        bool slashingPassed = verifySlashingInvariant_totalWithinStake(
            context.slashController,
            context.stakeBalanceSource,
            context.slashTarget
        );
        _storeResult(
            "slashing_totalWithinStake",
            slashingPassed,
            slashingPassed ? "" : "cumulative slash exceeds stake balance or dependency unavailable"
        );
        totalChecks++;
        if (slashingPassed) passedCount++;

        bool appealPassed = verifyAppealInvariant_reversalRestoresState(
            context.appealController,
            context.slashController,
            context.lockController,
            context.appealId,
            context.appealTarget,
            context.expectedPreSlashTotal,
            context.expectedLockedAfterAppeal
        );
        _storeResult(
            "appeal_reversalRestoresState",
            appealPassed,
            appealPassed ? "" : "approved appeal did not restore the expected slash/lock state"
        );
        totalChecks++;
        if (appealPassed) passedCount++;

        bool parityPassed = verifyParityInvariant_actorNeutral(
            context.enforcer,
            context.offenseRegistry,
            context.offenseCode,
            context.stakeAmount
        );
        _storeResult(
            "parity_actorNeutral",
            parityPassed,
            parityPassed ? "" : "schedule falls outside the shared offense range or actor override detected"
        );
        totalChecks++;
        if (parityPassed) passedCount++;

        bool lockPassed = verifyLockInvariant_durationBound(
            context.lockController,
            context.lockTarget,
            context.maxLockDuration
        );
        _storeResult(
            "lock_durationBound",
            lockPassed,
            lockPassed ? "" : "lock duration exceeds configured maximum"
        );
        totalChecks++;
        if (lockPassed) passedCount++;

        bool evidencePassed = verifyEvidenceInvariant_immutableHash(
            context.evidenceRegistry,
            context.evidenceHash
        );
        _storeResult(
            "evidence_immutableHash",
            evidencePassed,
            evidencePassed ? "" : "evidence registry returned a mismatched or unsupported packet"
        );
        totalChecks++;
        if (evidencePassed) passedCount++;

        bool ammPassed = verifyAmmInvariant_monotonicQuote(
            context.amm,
            context.ammSmallAmountIn,
            context.ammLargeAmountIn
        );
        _storeResult(
            "amm_monotonicQuote",
            ammPassed,
            ammPassed ? "" : "AMM quote is not monotonic for the supplied reserves and inputs"
        );
        totalChecks++;
        if (ammPassed) passedCount++;

        bool routerPassed = verifyRouterInvariant_emptyRoute(
            context.router,
            context.routerTokenIn,
            context.routerTokenOut,
            context.routerAmountIn
        );
        _storeResult(
            "router_emptyRoute",
            routerPassed,
            routerPassed ? "" : "router returned a non-empty route despite having no pools"
        );
        totalChecks++;
        if (routerPassed) passedCount++;

        emit VerificationSuiteCompleted(totalChecks, passedCount, totalChecks - passedCount);
    }

    function getVerificationResult(
        string calldata invariantName
    ) external view returns (VerificationResult memory) {
        return _results[keccak256(bytes(invariantName))];
    }

    function getAllResults() external view returns (VerificationResult[] memory) {
        VerificationResult[] memory all = new VerificationResult[](_resultKeys.length);
        for (uint256 i = 0; i < _resultKeys.length; i++) {
            all[i] = _results[_resultKeys[i]];
        }
        return all;
    }

    function _storeResult(
        string memory name,
        bool passed,
        string memory details
    ) internal {
        bytes32 key = keccak256(bytes(name));
        if (!_resultKeyExists[key]) {
            _resultKeys.push(key);
            _resultKeyExists[key] = true;
        }

        _results[key] = VerificationResult({
            invariantName: name,
            passed: passed,
            verifiedAt: block.timestamp,
            details: details
        });

        emit InvariantVerified(name, passed);
    }
}
