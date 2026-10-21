// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ISlashingMechanism
 * @notice Comprehensive interface for fraud detection and penalty enforcement system
 */
interface ISlashingMechanism {
    
    // ============ ENUMS ============
    
    enum SlashingReason {
        DATA_MANIPULATION,           // 0
        SYBIL_ATTACK,               // 1
        NETWORK_DISRUPTION,         // 2
        REPEATED_VIOLATIONS,        // 3
        FRAUD,                      // 4
        GAMING_SYSTEM,              // 5
        CONSENSUS_ATTACK,           // 6
        // core4 SlashingReason variants (security/slashing.rs)
        INVALID_REVEAL,             // 7
        ORACLE_ATTESTATION_FRAUD,   // 8
        DATA_QUALITY_VIOLATION,     // 9
        INVALID_ZK_PROOF,          // 10
        REPEATED_LOW_QUALITY_DATA  // 11
    }
    
    enum SlashingStatus {
        PENDING,
        CONFIRMED,
        APPEALED,
        OVERTURNED,
        EXECUTED,
        EXPIRED
    }
    
    enum ViolationSeverity {
        MINOR,
        MAJOR,
        CRITICAL,
        TERMINAL
    }
    
    // ============ EVENTS ============
    
    event SlashingProposed(
        uint256 indexed slashingId,
        address indexed participant,
        SlashingReason reason,
        ViolationSeverity severity,
        uint256 proposedAmount,
        bytes32 evidenceHash
    );
    
    event SlashingExecuted(
        uint256 indexed slashingId,
        address indexed participant,
        uint256 slashedAmount,
        uint256 treasuryAmount,
        uint256 burnedAmount
    );
    
    event AppealSubmitted(
        uint256 indexed appealId,
        uint256 indexed slashingId,
        address indexed appellant,
        bytes32 evidenceHash
    );
    
    event StakeRefilled(
        address indexed participant,
        uint256 amount,
        uint256 newLayawayPeriod
    );
    
    event ParticipantBanned(
        address indexed participant,
        uint256 banDuration,
        SlashingReason reason
    );
    
    // ============ CORE FUNCTIONS ============
    
    /**
     * @notice Propose a slashing event with evidence
     * @param participant Address to be slashed
     * @param reason Reason for slashing
     * @param severity Severity level of violation
     * @param evidenceHash Hash of evidence supporting the slashing
     * @param description Human-readable description of the violation
     */
    function proposeSlashing(
        address participant,
        SlashingReason reason,
        ViolationSeverity severity,
        bytes32 evidenceHash,
        string calldata description
    ) external;
    
    /**
     * @notice Validate a pending slashing proposal
     * @param slashingId ID of the slashing event to validate
     */
    function validateSlashing(uint256 slashingId) external;
    
    /**
     * @notice Execute a confirmed slashing after delay period
     * @param slashingId ID of the slashing event to execute
     */
    function executeSlashing(uint256 slashingId) external;
    
    /**
     * @notice Submit an appeal for a slashing decision
     * @param slashingId ID of the slashing to appeal
     * @param defendingEvidenceHash Hash of evidence supporting the appeal
     * @param appealReason Reason for the appeal
     */
    function appealSlashing(
        uint256 slashingId,
        bytes32 defendingEvidenceHash,
        string calldata appealReason
    ) external;
    
    /**
     * @notice Refill stake after being slashed
     * @param amount Amount to refill
     */
    function refillStake(uint256 amount) external;
    
    /**
     * @notice Submit evidence for slashing or appeals
     * @param evidenceHash Hash of the evidence
     * @param ipfsHash IPFS hash for evidence storage
     */
    function submitEvidence(bytes32 evidenceHash, string calldata ipfsHash) external;
    
    /**
     * @notice Emergency slashing for critical situations
     * @param participant Address to slash
     * @param amount Amount to slash
     * @param reason Reason for emergency slashing
     */
    function emergencySlashing(
        address participant,
        uint256 amount,
        string calldata reason
    ) external;
    
    // ============ VIEW FUNCTIONS ============
    
    /**
     * @notice Check if participant is eligible to continue after slashing
     * @param participant Address to check
     * @return eligible True if participant can continue
     * @return reason Reason if not eligible
     */
    function checkEligibility(address participant) 
        external 
        view 
        returns (bool eligible, string memory reason);
    
    /**
     * @notice Get participant violation record
     * @param participant Address to query
     * @return violationCount Number of violations
     * @return totalSlashed Total amount slashed
     * @return lastViolation Timestamp of last violation
     * @return isBanned Whether participant is banned
     * @return banExpiry When ban expires
     * @return graceDeadline Deadline to refill stake
     * @return requiresRefill Whether refill is required
     * @return layawayMultiplier Current layaway multiplier
     */
    function getParticipantRecord(address participant) 
        external 
        view 
        returns (
            uint256 violationCount,
            uint256 totalSlashed,
            uint256 lastViolation,
            bool isBanned,
            uint256 banExpiry,
            uint256 graceDeadline,
            bool requiresRefill,
            uint256 layawayMultiplier
        );
    
    /**
     * @notice Get slashing event details
     * @param slashingId ID of the slashing event
     * @return participant Address of participant
     * @return reason Slashing reason
     * @return severity Violation severity
     * @return slashedAmount Amount to be slashed
     * @return timestamp When proposed
     * @return executionTime When can be executed
     * @return status Current status
     * @return appealDeadline Deadline for appeals
     * @return description Violation description
     * @return validators Array of validator addresses
     * @return approvalCount Current approval count
     */
    function getSlashingEvent(uint256 slashingId) 
        external 
        view 
        returns (
            address participant,
            SlashingReason reason,
            ViolationSeverity severity,
            uint256 slashedAmount,
            uint256 timestamp,
            uint256 executionTime,
            SlashingStatus status,
            uint256 appealDeadline,
            string memory description,
            address[] memory validators,
            uint256 approvalCount
        );
    
    /**
     * @notice Get pending slashing events for a validator
     * @param validator Address of validator
     * @return pendingIds Array of pending slashing IDs
     */
    function getPendingSlashings(address validator) 
        external 
        view 
        returns (uint256[] memory pendingIds);
    
    /**
     * @notice Verify evidence hash against IPFS content
     * @param evidenceHash Hash to verify
     * @return verified True if evidence is valid
     */
    function verifyEvidence(bytes32 evidenceHash) external view returns (bool verified);
    
    // ============ LEGACY COMPATIBILITY ============
    
    /**
     * @notice Check if participant has slashing history
     * @param participant Address to check
     * @return hasSlashing True if participant has been slashed
     * @return slashingCount Number of times slashed
     * @return lastSlashTime Timestamp of last slashing
     */
    function getSlashingHistory(address participant)
        external
        view
        returns (
            bool hasSlashing,
            uint256 slashingCount,
            uint256 lastSlashTime
        );

    /**
     * @notice Get slashing severity for participant
     * @param participant Address to check
     * @return severity Slashing severity (0-10000)
     */
    function getSlashingSeverity(address participant)
        external
        view
        returns (uint256 severity);

    /**
     * @notice Check if participant is currently suspended
     * @param participant Address to check
     * @return suspended True if participant is suspended
     * @return suspensionEnd Timestamp when suspension ends
     */
    function isSuspended(address participant)
        external
        view
        returns (bool suspended, uint256 suspensionEnd);
}