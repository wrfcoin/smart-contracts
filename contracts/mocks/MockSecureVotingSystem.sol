// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockSecureVotingSystem {
    struct Votes {
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
    }

    mapping(uint256 => Votes) private _votes;

    function setVotes(uint256 proposalId, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes) external {
        _votes[proposalId] = Votes({forVotes: forVotes, againstVotes: againstVotes, abstainVotes: abstainVotes});
    }

    function getProposalVotes(
        uint256 proposalId
    ) external view returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes) {
        Votes memory votes = _votes[proposalId];
        return (votes.forVotes, votes.againstVotes, votes.abstainVotes);
    }
}
