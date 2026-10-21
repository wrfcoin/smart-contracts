// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISlashingControllerAppeals {
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

    function getSlash(bytes32 slashId) external view returns (SlashRecord memory);
    function reverseSlash(bytes32 slashId) external;
    function updateSlashAmount(bytes32 slashId, uint256 newAmount) external;
}

interface IParticipationLockAppeals {
    function isLocked(address target) external view returns (bool);
    function unlock(address target) external;
}

/**
 * @title AppealReversalController
 * @notice Governed reversal windows for slashing outcomes.  Any address may
 *         file an appeal against a slash; only APPEAL_ADMIN_ROLE holders may
 *         decide (approve/reject) appeals.
 * @dev Implements smart-contracts#5.  Appeal records are keyed by
 *      keccak256(abi.encodePacked(slashId, appellant, filedAt)) so that the
 *      same appellant may re-file after a prior appeal is decided.
 *
 * Equal liability: appeals apply identically to humans, AI agents, and robots.
 */
contract AppealReversalController is AccessControl, ReentrancyGuard {
    bytes32 public constant APPEAL_ADMIN_ROLE = keccak256("APPEAL_ADMIN_ROLE");

    uint256 private constant MIN_WINDOW = 1 days;   // 86 400 seconds
    uint256 private constant MAX_WINDOW = 30 days;  // 2 592 000 seconds

    struct AppealRecord {
        bytes32 slashId;
        address appellant;
        string  reason;
        uint256 filedAt;
        uint256 windowCloses;
        bool    decided;
        bool    approved;
        uint256 decidedAt;
        uint256 reversedAmount;
    }

    mapping(bytes32 => AppealRecord) private _appeals;
    bytes32[] private _appealKeys;

    // slashId => list of appealIds for fast enumeration
    mapping(bytes32 => bytes32[]) private _appealsBySlash;

    uint256 public appealWindowDuration;
    address public slashingController;
    address public participationLock;

    event AppealFiled(
        bytes32 indexed appealId,
        bytes32 indexed slashId,
        address indexed appellant,
        uint256 windowCloses
    );
    event AppealDecided(
        bytes32 indexed appealId,
        bool    approved,
        uint256 reversedAmount
    );
    event AppealExecutionApplied(
        bytes32 indexed appealId,
        bool slashAdjusted,
        bool lockReleased,
        uint256 resultingSlashAmount
    );
    event AppealWindowUpdated(uint256 oldDuration, uint256 newDuration);
    event AppealControllersUpdated(address slashingController, address participationLock);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(APPEAL_ADMIN_ROLE,  msg.sender);
        appealWindowDuration = 7 days; // 604 800 seconds
    }

    // ─── Mutating functions ───────────────────────────────────────────────────

    /**
     * @notice File an appeal against a slash record.  No role required — any
     *         address may appeal.
     * @param slashId The slash record identifier being contested.
     * @param reason  Human-readable reason for the appeal.
     */
    function fileAppeal(
        bytes32 slashId,
        string calldata reason
    ) external nonReentrant {
        require(slashId != bytes32(0), "AppealReversalController: zero slash id");
        require(bytes(reason).length > 0, "AppealReversalController: empty reason");

        uint256 ts = block.timestamp;
        bytes32 appealId = keccak256(abi.encodePacked(slashId, msg.sender, ts));
        require(
            _appeals[appealId].filedAt == 0,
            "AppealReversalController: duplicate appeal"
        );

        uint256 windowCloses = ts + appealWindowDuration;

        _appeals[appealId] = AppealRecord({
            slashId:        slashId,
            appellant:      msg.sender,
            reason:         reason,
            filedAt:        ts,
            windowCloses:   windowCloses,
            decided:        false,
            approved:       false,
            decidedAt:      0,
            reversedAmount: 0
        });
        _appealKeys.push(appealId);
        _appealsBySlash[slashId].push(appealId);

        emit AppealFiled(appealId, slashId, msg.sender, windowCloses);
    }

    /**
     * @notice Decide (approve or reject) an appeal.  Must be called within the
     *         appeal window.
     * @param appealId      The appeal record identifier.
     * @param approve       True to approve the reversal; false to reject.
     * @param reversalAmount Token-equivalent amount to reverse (must be 0 when
     *                       rejecting; may be 0 when approving a non-token appeal).
     */
    function decideAppeal(
        bytes32 appealId,
        bool    approve,
        uint256 reversalAmount
    ) external onlyRole(APPEAL_ADMIN_ROLE) nonReentrant {
        AppealRecord storage record = _appeals[appealId];
        require(record.filedAt != 0,     "AppealReversalController: appeal not found");
        require(!record.decided,          "AppealReversalController: already decided");
        require(
            block.timestamp <= record.windowCloses,
            "AppealReversalController: window closed"
        );

        record.decided        = true;
        record.approved       = approve;
        record.decidedAt      = block.timestamp;
        record.reversedAmount = approve ? reversalAmount : 0;

        if (approve) {
            _applyApprovedAppeal(appealId, record, reversalAmount);
        }

        emit AppealDecided(appealId, approve, record.reversedAmount);
    }

    /**
     * @notice Update the appeal window duration.
     * @param newDuration New duration in seconds; must be in [1 day, 30 days].
     */
    function setAppealWindow(
        uint256 newDuration
    ) external onlyRole(APPEAL_ADMIN_ROLE) nonReentrant {
        require(
            newDuration >= MIN_WINDOW,
            "AppealReversalController: window too short"
        );
        require(
            newDuration <= MAX_WINDOW,
            "AppealReversalController: window too long"
        );
        uint256 oldDuration = appealWindowDuration;
        appealWindowDuration = newDuration;
        emit AppealWindowUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Configure sibling governance controllers for executed appeals.
     */
    function setAppealControllers(
        address slashingController_,
        address participationLock_
    ) external onlyRole(APPEAL_ADMIN_ROLE) nonReentrant {
        slashingController = slashingController_;
        participationLock = participationLock_;

        emit AppealControllersUpdated(slashingController_, participationLock_);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Retrieve an appeal record by its identifier.
     */
    function getAppeal(bytes32 appealId) external view returns (AppealRecord memory) {
        require(
            _appeals[appealId].filedAt != 0,
            "AppealReversalController: appeal not found"
        );
        return _appeals[appealId];
    }

    /**
     * @notice Return all appeal IDs associated with a specific slash record.
     */
    function getAppealsBySlash(
        bytes32 slashId
    ) external view returns (bytes32[] memory) {
        return _appealsBySlash[slashId];
    }

    /**
     * @notice Return true if the appeal window is still open (not yet expired
     *         and the appeal has not been decided).
     */
    function isWithinWindow(bytes32 appealId) external view returns (bool) {
        AppealRecord storage record = _appeals[appealId];
        if (record.filedAt == 0) return false;
        if (record.decided)      return false;
        return block.timestamp <= record.windowCloses;
    }

    /**
     * @notice Return aggregate counts: total, pending (undecided), approved,
     *         and rejected appeals.
     */
    function getAppealCount()
        external
        view
        returns (
            uint256 total,
            uint256 pending,
            uint256 approved,
            uint256 rejected
        )
    {
        total = _appealKeys.length;
        for (uint256 i = 0; i < _appealKeys.length; i++) {
            AppealRecord storage r = _appeals[_appealKeys[i]];
            if (!r.decided) {
                pending++;
            } else if (r.approved) {
                approved++;
            } else {
                rejected++;
            }
        }
    }

    function _applyApprovedAppeal(
        bytes32 appealId,
        AppealRecord storage record,
        uint256 reversalAmount
    ) internal {
        bool slashAdjusted = false;
        bool lockReleased = false;
        uint256 resultingSlashAmount = 0;

        if (slashingController != address(0)) {
            try ISlashingControllerAppeals(slashingController).getSlash(record.slashId)
                returns (ISlashingControllerAppeals.SlashRecord memory slashRecord)
            {
                if (!slashRecord.reversed) {
                    if (reversalAmount == 0) {
                        resultingSlashAmount = slashRecord.amount;
                    } else if (reversalAmount >= slashRecord.amount) {
                        ISlashingControllerAppeals(slashingController).reverseSlash(record.slashId);
                        slashAdjusted = true;
                    } else {
                        resultingSlashAmount = slashRecord.amount - reversalAmount;
                        ISlashingControllerAppeals(slashingController).updateSlashAmount(
                            record.slashId,
                            resultingSlashAmount
                        );
                        slashAdjusted = true;
                    }
                }
            } catch {}
        }

        if (participationLock != address(0)) {
            try IParticipationLockAppeals(participationLock).isLocked(record.appellant)
                returns (bool locked)
            {
                if (locked) {
                    IParticipationLockAppeals(participationLock).unlock(record.appellant);
                    lockReleased = true;
                }
            } catch {}
        }

        emit AppealExecutionApplied(appealId, slashAdjusted, lockReleased, resultingSlashAmount);
    }
}
