// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../GovernanceSecurityFramework.sol";

/**
 * @notice Minimal compliance mock for governance security tests.
 */
contract MockGovernanceCompliance {
    bool public compliant = true;
    string public reason = "";

    function setValidation(bool _compliant, string calldata _reason) external {
        compliant = _compliant;
        reason = _reason;
    }

    function validateTransaction(
        address,
        string memory,
        uint256,
        ComplianceModule.Jurisdiction
    ) external view returns (bool approved, string memory failureReason) {
        if (compliant) {
            return (true, "");
        }
        return (false, reason);
    }
}

/**
 * @notice Placeholder timelock contract for constructor wiring in tests.
 */
contract MockGovernanceTimelock {
}

/**
 * @notice Test harness exposing controlled setup helpers for governance DoS tests.
 */
contract GovernanceSecurityFrameworkHarness is GovernanceSecurityFramework {
    mapping(uint256 => mapping(address => bool)) private _hasVotedForTesting;

    constructor(
        address admin_,
        address timelock_,
        address compliance_,
        address governanceToken_
    ) GovernanceSecurityFramework(admin_, timelock_, compliance_, governanceToken_) {}

    function setReputationForTesting(
        address user,
        uint256 baseReputation,
        uint256 stakingDuration,
        bool blacklisted
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ReputationData storage data = reputationData[user];
        data.baseReputation = baseReputation;
        data.stakingDuration = stakingDuration;
        data.blacklisted = blacklisted;
        data.lastUpdate = block.timestamp;
    }

    function setStakeForTesting(address user, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 previous = stakedTokens[user];
        stakedTokens[user] = amount;

        if (amount >= previous) {
            economicSecurity.totalStaked += (amount - previous);
        } else {
            economicSecurity.totalStaked -= (previous - amount);
        }
    }

    function getActiveProposalsCount() external view returns (uint256 count) {
        for (uint256 i = 1; i < nextProposalId; i++) {
            SecureProposal storage proposal = proposals[i];
            if (!proposal.executed && !proposal.slashed && proposal.currentPhase != VotingPhase.Finalized) {
                count++;
            }
        }
    }

    /**
     * @notice Compatibility helper for legacy tests that still call createProposal().
     * @dev Bypasses production proposer gating and creates a minimal active proposal.
     */
    function createProposal(
        string memory title,
        string memory description,
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas
    ) external returns (uint256 proposalId) {
        proposalId = nextProposalId++;
        bytes memory proposalData = abi.encode(targets, values, signatures, calldatas);

        SecureProposal storage proposal = proposals[proposalId];
        proposal.proposalId = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.proposalHash = keccak256(
            abi.encodePacked(title, description, proposalData, msg.sender, proposalId)
        );
        proposal.creationTime = block.timestamp;
        proposal.votingStartTime = block.timestamp;
        proposal.votingEndTime = block.timestamp + 7 days;
        proposal.currentPhase = VotingPhase.Commit;

        _incrementActiveProposals();
        emit ProposalCreated(proposalId, msg.sender, title, 0);
    }

    /**
     * @notice Compatibility helper for legacy tests that still call castVote().
     */
    function castVote(uint256 proposalId, bool support) external validProposal(proposalId) {
        require(!_hasVotedForTesting[proposalId][msg.sender], "GSF: Already voted");
        SecureProposal storage proposal = proposals[proposalId];
        require(!proposal.executed && !proposal.slashed, "GSF: Proposal inactive");

        uint256 votingWeight = stakedTokens[msg.sender] > 0 ? _sqrt(stakedTokens[msg.sender]) : 1;
        proposal.totalVotes += votingWeight;
        if (support) {
            proposal.forVotes += votingWeight;
        } else {
            proposal.againstVotes += votingWeight;
        }

        _hasVotedForTesting[proposalId][msg.sender] = true;
    }

    /**
     * @notice Compatibility helper for legacy tests that estimate proposal state reads.
     */
    function getProposalState(uint256 proposalId) external view validProposal(proposalId) returns (uint8) {
        return uint8(proposals[proposalId].currentPhase);
    }
}
