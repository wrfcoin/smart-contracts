// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Oracle-triggered breaker that revokes an agent's key-access authorization on unsafe usage.
/// @dev An off-chain key custodian must call keyAccessAllowed before releasing a signing operation.
contract PaperclipCircuitBreaker is AccessControl {
    bytes32 public constant USAGE_ORACLE_ROLE = keccak256("USAGE_ORACLE_ROLE");
    bytes32 public constant HUMAN_APPROVER_ROLE = keccak256("HUMAN_APPROVER_ROLE");

    uint64 public constant SPEND_WINDOW_SECONDS = 24 hours;
    uint64 public constant SPEND_WINDOW_BUCKET_SIZE = 1 hours;
    uint8 public constant SPEND_WINDOW_BUCKET_COUNT = 24;

    struct Policy {
        uint128 spendLimit;
        uint128 fanoutLimit;
        bool configured;
    }

    struct SpendWindow {
        uint128 spent;
        uint64 startedAt;
    }

    struct SpendWindowBucket {
        uint64 bucketId;
        uint128 spent;
    }

    mapping(address => Policy) private _policies;
    mapping(address => SpendWindow) private _spendWindows;
    mapping(address => mapping(uint8 => SpendWindowBucket)) private _spendBuckets;
    mapping(address => bool) public paused;

    event PolicyConfigured(address indexed agent, uint256 spendLimit, uint256 fanoutLimit);
    event UsageReported(address indexed agent, uint256 spendDelta, uint256 fanout);
    event AgentPaused(address indexed agent, bytes32 indexed reason, uint256 observedValue, uint256 limit);
    event AgentResumed(address indexed agent, address indexed approver);

    constructor(address dao, address usageOracle, address humanApprover) {
        require(dao != address(0) && usageOracle != address(0) && humanApprover != address(0), "PaperclipBreaker: zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, dao);
        _grantRole(USAGE_ORACLE_ROLE, usageOracle);
        _grantRole(HUMAN_APPROVER_ROLE, humanApprover);
    }

    function configurePolicy(address agent, uint128 spendLimit, uint128 fanoutLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(agent != address(0), "PaperclipBreaker: zero agent");
        require(spendLimit > 0 && fanoutLimit > 0, "PaperclipBreaker: zero limit");
        _policies[agent] = Policy(spendLimit, fanoutLimit, true);
        emit PolicyConfigured(agent, spendLimit, fanoutLimit);
    }

    /// @notice Report usage for one agent. A crossing report pauses the agent immediately.
    function reportUsage(address agent, uint128 spendDelta, uint128 workflowFanout) external onlyRole(USAGE_ORACLE_ROLE) {
        Policy memory policy = _policies[agent];
        require(policy.configured, "PaperclipBreaker: unconfigured agent");
        require(!paused[agent], "PaperclipBreaker: agent paused");

        SpendWindow storage window = _spendWindows[agent];
        _accrueSpend(agent, window, spendDelta);
        emit UsageReported(agent, spendDelta, workflowFanout);

        if (window.spent > policy.spendLimit) {
            paused[agent] = true;
            emit AgentPaused(agent, keccak256("SPEND_LIMIT"), window.spent, policy.spendLimit);
        } else if (workflowFanout > policy.fanoutLimit) {
            paused[agent] = true;
            emit AgentPaused(agent, keccak256("FANOUT_LIMIT"), workflowFanout, policy.fanoutLimit);
        }
    }

    function _accrueSpend(address agent, SpendWindow storage window, uint128 spendDelta) internal {
        uint64 nowBucketId = uint64(block.timestamp / SPEND_WINDOW_BUCKET_SIZE);
        uint64 cutoffBucketId = nowBucketId >= SPEND_WINDOW_BUCKET_COUNT - 1
            ? nowBucketId - (SPEND_WINDOW_BUCKET_COUNT - 1)
            : 0;

        for (uint8 i = 0; i < SPEND_WINDOW_BUCKET_COUNT; i++) {
            SpendWindowBucket storage bucket = _spendBuckets[agent][i];
            if (bucket.bucketId > 0 && bucket.bucketId < cutoffBucketId) {
                if (window.spent >= bucket.spent) {
                    window.spent -= bucket.spent;
                } else {
                    window.spent = 0;
                }
                bucket.bucketId = 0;
                bucket.spent = 0;
            }
        }

        uint8 idx = uint8(nowBucketId % SPEND_WINDOW_BUCKET_COUNT);
        SpendWindowBucket storage active = _spendBuckets[agent][idx];
        if (active.bucketId != nowBucketId) {
            if (active.bucketId > 0) {
                if (window.spent >= active.spent) {
                    window.spent -= active.spent;
                } else {
                    window.spent = 0;
                }
            }
            active.bucketId = nowBucketId;
            active.spent = 0;
        }

        active.spent += spendDelta;
        window.spent += spendDelta;
        window.startedAt = nowBucketId * SPEND_WINDOW_BUCKET_SIZE;
    }

    /// @notice Explicit human action required to restore a paused agent's key-access authorization.
    function approveResumption(address agent) external onlyRole(HUMAN_APPROVER_ROLE) {
        require(paused[agent], "PaperclipBreaker: agent not paused");
        paused[agent] = false;
        delete _spendWindows[agent];
        for (uint8 i = 0; i < SPEND_WINDOW_BUCKET_COUNT; i++) {
            delete _spendBuckets[agent][i];
        }
        emit AgentResumed(agent, msg.sender);
    }

    function keyAccessAllowed(address agent) external view returns (bool) {
        return _policies[agent].configured && !paused[agent];
    }

    function getPolicy(address agent) external view returns (Policy memory) {
        return _policies[agent];
    }

    function getSpendWindow(address agent) external view returns (SpendWindow memory) {
        return _spendWindows[agent];
    }
}
