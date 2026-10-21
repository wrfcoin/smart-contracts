// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/ICarbonCreditTracker.sol";

/**
 * @title CarbonVerificationOracle
 * @dev Oracle contract for verifying carbon offset claims before credits become active.
 *
 * Flow: requestVerification -> confirmVerification/rejectVerification
 * Dispute: disputeVerification -> resolveDispute
 * Timeout: handleTimeout (if oracle doesn't respond within VERIFICATION_TIMEOUT)
 *
 * @author WRFCoin Security Team
 */
contract CarbonVerificationOracle is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Roles ============

    bytes32 public constant VERIFICATION_ORACLE_ROLE = keccak256("VERIFICATION_ORACLE_ROLE");

    // ============ Constants ============

    uint256 public constant DISPUTE_WINDOW = 3 days;
    uint256 public constant VERIFICATION_TIMEOUT = 7 days;

    // ============ Enums ============

    enum VerificationRequestStatus {
        NONE,
        PENDING,
        CONFIRMED,
        REJECTED,
        DISPUTED,
        DISPUTE_RESOLVED,
        TIMED_OUT
    }

    // ============ Structs ============

    struct VerificationRequest {
        bytes32 lifecycleId;
        address requester;
        uint256 requestTimestamp;
        uint256 confirmationTimestamp;
        uint256 disputeDeadline;
        VerificationRequestStatus status;
        bytes32 attestationHash;
        string rejectionReason;
    }

    // ============ State ============

    ICarbonCreditTracker public carbonCreditTracker;

    mapping(bytes32 => VerificationRequest) public verificationRequests;

    uint256 public totalRequests;
    uint256 public totalConfirmed;
    uint256 public totalRejected;
    uint256 public totalDisputed;

    // ============ Events ============

    event VerificationRequested(
        bytes32 indexed lifecycleId,
        address indexed requester,
        uint256 timestamp
    );

    event VerificationConfirmed(
        bytes32 indexed lifecycleId,
        address indexed oracle,
        bytes32 attestationHash,
        uint256 disputeDeadline
    );

    event VerificationRejected(
        bytes32 indexed lifecycleId,
        address indexed oracle,
        string reason
    );

    event VerificationDisputed(
        bytes32 indexed lifecycleId,
        address indexed disputer,
        uint256 timestamp
    );

    event DisputeResolved(
        bytes32 indexed lifecycleId,
        address indexed oracle,
        bool verified
    );

    event VerificationTimedOut(
        bytes32 indexed lifecycleId,
        uint256 timestamp
    );

    // ============ Constructor ============

    constructor(address _carbonCreditTracker) {
        require(_carbonCreditTracker != address(0), "CarbonVerificationOracle: Invalid tracker");
        carbonCreditTracker = ICarbonCreditTracker(_carbonCreditTracker);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFICATION_ORACLE_ROLE, msg.sender);
    }

    // ============ External Functions ============

    /**
     * @notice Request verification for a carbon credit lifecycle
     * @param lifecycleId The lifecycle ID to verify
     */
    function requestVerification(bytes32 lifecycleId) external nonReentrant whenNotPaused {
        require(
            verificationRequests[lifecycleId].status == VerificationRequestStatus.NONE,
            "CarbonVerificationOracle: Request already exists"
        );

        verificationRequests[lifecycleId] = VerificationRequest({
            lifecycleId: lifecycleId,
            requester: msg.sender,
            requestTimestamp: block.timestamp,
            confirmationTimestamp: 0,
            disputeDeadline: 0,
            status: VerificationRequestStatus.PENDING,
            attestationHash: bytes32(0),
            rejectionReason: ""
        });

        carbonCreditTracker.setVerificationPending(lifecycleId);
        totalRequests++;

        emit VerificationRequested(lifecycleId, msg.sender, block.timestamp);
    }

    /**
     * @notice Confirm a verification request with a signed attestation
     * @param lifecycleId The lifecycle ID to confirm
     * @param attestation Signed attestation from the oracle
     */
    function confirmVerification(
        bytes32 lifecycleId,
        bytes calldata attestation
    ) external nonReentrant whenNotPaused onlyRole(VERIFICATION_ORACLE_ROLE) {
        VerificationRequest storage request = verificationRequests[lifecycleId];
        require(
            request.status == VerificationRequestStatus.PENDING,
            "CarbonVerificationOracle: Not pending"
        );

        bytes32 messageHash = keccak256(abi.encodePacked(lifecycleId, true, block.chainid));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(attestation);
        require(
            hasRole(VERIFICATION_ORACLE_ROLE, signer),
            "CarbonVerificationOracle: Invalid attestation signer"
        );

        request.status = VerificationRequestStatus.CONFIRMED;
        request.confirmationTimestamp = block.timestamp;
        request.disputeDeadline = block.timestamp + DISPUTE_WINDOW;
        request.attestationHash = keccak256(attestation);

        carbonCreditTracker.confirmVerification(lifecycleId);
        totalConfirmed++;

        emit VerificationConfirmed(lifecycleId, msg.sender, request.attestationHash, request.disputeDeadline);
    }

    /**
     * @notice Reject a verification request
     * @param lifecycleId The lifecycle ID to reject
     * @param reason Reason for rejection
     */
    function rejectVerification(
        bytes32 lifecycleId,
        string calldata reason
    ) external nonReentrant whenNotPaused onlyRole(VERIFICATION_ORACLE_ROLE) {
        VerificationRequest storage request = verificationRequests[lifecycleId];
        require(
            request.status == VerificationRequestStatus.PENDING,
            "CarbonVerificationOracle: Not pending"
        );

        request.status = VerificationRequestStatus.REJECTED;
        request.rejectionReason = reason;

        carbonCreditTracker.rejectVerification(lifecycleId);
        totalRejected++;

        emit VerificationRejected(lifecycleId, msg.sender, reason);
    }

    /**
     * @notice Dispute a confirmed verification during the dispute window
     * @param lifecycleId The lifecycle ID to dispute
     */
    function disputeVerification(bytes32 lifecycleId) external nonReentrant whenNotPaused {
        VerificationRequest storage request = verificationRequests[lifecycleId];
        require(
            request.status == VerificationRequestStatus.CONFIRMED,
            "CarbonVerificationOracle: Not confirmed"
        );
        require(
            block.timestamp <= request.disputeDeadline,
            "CarbonVerificationOracle: Dispute window closed"
        );

        request.status = VerificationRequestStatus.DISPUTED;

        carbonCreditTracker.setDisputed(lifecycleId);
        totalDisputed++;

        emit VerificationDisputed(lifecycleId, msg.sender, block.timestamp);
    }

    /**
     * @notice Resolve a dispute with a new oracle attestation
     * @param lifecycleId The lifecycle ID to resolve
     * @param verified Whether the credit is verified after review
     * @param attestation Signed attestation from the oracle
     */
    function resolveDispute(
        bytes32 lifecycleId,
        bool verified,
        bytes calldata attestation
    ) external nonReentrant whenNotPaused onlyRole(VERIFICATION_ORACLE_ROLE) {
        VerificationRequest storage request = verificationRequests[lifecycleId];
        require(
            request.status == VerificationRequestStatus.DISPUTED,
            "CarbonVerificationOracle: Not disputed"
        );

        bytes32 messageHash = keccak256(abi.encodePacked(lifecycleId, verified, block.chainid));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(attestation);
        require(
            hasRole(VERIFICATION_ORACLE_ROLE, signer),
            "CarbonVerificationOracle: Invalid attestation signer"
        );

        request.status = VerificationRequestStatus.DISPUTE_RESOLVED;
        request.attestationHash = keccak256(attestation);

        carbonCreditTracker.resolveDispute(lifecycleId, verified);

        emit DisputeResolved(lifecycleId, msg.sender, verified);
    }

    /**
     * @notice Handle timeout for a stalled verification
     * @param lifecycleId The lifecycle ID that timed out
     */
    function handleTimeout(bytes32 lifecycleId) external nonReentrant whenNotPaused {
        VerificationRequest storage request = verificationRequests[lifecycleId];
        require(
            request.status == VerificationRequestStatus.PENDING,
            "CarbonVerificationOracle: Not pending"
        );
        require(
            block.timestamp > request.requestTimestamp + VERIFICATION_TIMEOUT,
            "CarbonVerificationOracle: Not timed out yet"
        );

        request.status = VerificationRequestStatus.TIMED_OUT;

        carbonCreditTracker.rejectVerification(lifecycleId);

        emit VerificationTimedOut(lifecycleId, block.timestamp);
    }

    // ============ View Functions ============

    function getVerificationRequest(bytes32 lifecycleId) external view returns (VerificationRequest memory) {
        return verificationRequests[lifecycleId];
    }

    function getVerificationStatus(bytes32 lifecycleId) external view returns (VerificationRequestStatus) {
        return verificationRequests[lifecycleId].status;
    }

    function getStats() external view returns (
        uint256 requests,
        uint256 confirmed,
        uint256 rejected,
        uint256 disputed
    ) {
        return (totalRequests, totalConfirmed, totalRejected, totalDisputed);
    }

    // ============ Admin Functions ============

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
