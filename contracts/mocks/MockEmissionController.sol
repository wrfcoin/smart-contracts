// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockEmissionController {
    uint8 public lastProposalType;
    bytes public lastParams;
    bool public shouldRevert;
    uint256 public applyCount;

    event ProposalParamsApplied(uint8 indexed proposalType, bytes params);

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function applyProposalParams(uint8 proposalType, bytes calldata params) external {
        if (shouldRevert) {
            revert("MockEmissionController: revert requested");
        }

        lastProposalType = proposalType;
        lastParams = params;
        applyCount += 1;

        emit ProposalParamsApplied(proposalType, params);
    }
}
