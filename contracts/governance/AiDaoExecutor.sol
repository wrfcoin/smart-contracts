// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface ISecureVotingSystem {
    function getProposalVotes(
        uint256 proposalId
    ) external view returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes);
}

interface IEmissionController {
    function applyProposalParams(uint8 proposalType, bytes calldata params) external;
}

contract AiDaoExecutor is Ownable2Step, ReentrancyGuard, Pausable {
    mapping(address => bool) public aiOracles;
    uint256 public timelockSeconds;
    mapping(bytes32 => Proposal) public proposals;
    address public guardian;
    ISecureVotingSystem public secureVotingSystem;
    IEmissionController public emissionController;

    mapping(address => uint256) private _oracleNonces;

    enum ProposalType {
        EmissionRate,
        RegionWeights,
        CoverageThreshold
    }

    struct Proposal {
        ProposalType proposalType;
        bytes params;
        uint256 submittedAt;
        uint256 vetoDeadline;
        bool executed;
        bool vetoed;
        address aiOracle;
        uint256 secureVotingProposalId;
    }

    error AiDaoNotOracle();
    error AiDaoTimelockActive();
    error AiDaoAlreadyExecuted();
    error AiDaoVetoed();
    error AiDaoPaused();
    error AiDaoVetoWindowClosed();
    error AiDaoNotGuardian();
    error AiDaoProposalNotFound();
    error AiDaoVetoMajorityNotReached();
    error AiDaoInvalidAddress();
    error AiDaoInvalidTimelock();
    error AiDaoInvalidParams();

    event ProposalSubmitted(
        bytes32 indexed proposalId,
        address indexed oracle,
        ProposalType indexed proposalType,
        uint256 vetoDeadline
    );
    event ProposalExecuted(
        bytes32 indexed proposalId,
        ProposalType indexed proposalType,
        bytes params
    );
    event ProposalVetoed(
        bytes32 indexed proposalId,
        uint256 indexed secureVotingProposalId,
        uint256 againstVotes,
        uint256 forVotes
    );
    event AiOracleUpdated(address indexed oracle, bool enabled);
    event TimelockUpdated(uint256 previousTimelock, uint256 newTimelock);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event SecureVotingSystemUpdated(address indexed previousSystem, address indexed newSystem);
    event EmissionControllerUpdated(address indexed previousController, address indexed newController);
    event EmissionControllerApplyFailed(bytes32 indexed proposalId, address indexed controller);

    modifier onlyAiOracle() {
        if (!aiOracles[msg.sender]) revert AiDaoNotOracle();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert AiDaoNotGuardian();
        _;
    }

    constructor(
        address initialOwner,
        address guardian_,
        address secureVotingSystem_,
        address emissionController_,
        uint256 timelockSeconds_
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || guardian_ == address(0) || secureVotingSystem_ == address(0)) {
            revert AiDaoInvalidAddress();
        }

        guardian = guardian_;
        secureVotingSystem = ISecureVotingSystem(secureVotingSystem_);
        emissionController = IEmissionController(emissionController_);
        timelockSeconds = timelockSeconds_ == 0 ? 172800 : timelockSeconds_;
    }

    function submitProposal(ProposalType proposalType, bytes calldata params) external onlyAiOracle {
        if (paused()) revert AiDaoPaused();

        uint256 secureVotingProposalId = _decodeSecureVotingProposalId(params);
        uint256 nonce = _oracleNonces[msg.sender]++;
        bytes32 proposalId = keccak256(
            abi.encodePacked(msg.sender, proposalType, params, block.timestamp, nonce)
        );

        Proposal storage proposal = proposals[proposalId];
        proposal.proposalType = proposalType;
        proposal.params = params;
        proposal.submittedAt = block.timestamp;
        proposal.vetoDeadline = block.timestamp + timelockSeconds;
        proposal.executed = false;
        proposal.vetoed = false;
        proposal.aiOracle = msg.sender;
        proposal.secureVotingProposalId = secureVotingProposalId;

        emit ProposalSubmitted(proposalId, msg.sender, proposalType, proposal.vetoDeadline);
    }

    function execute(bytes32 proposalId) external nonReentrant {
        if (paused()) revert AiDaoPaused();

        Proposal storage proposal = proposals[proposalId];
        if (proposal.submittedAt == 0) revert AiDaoProposalNotFound();
        if (proposal.executed) revert AiDaoAlreadyExecuted();
        if (proposal.vetoed) revert AiDaoVetoed();
        if (block.timestamp < proposal.vetoDeadline) revert AiDaoTimelockActive();

        proposal.executed = true;

        address controller = address(emissionController);
        if (controller != address(0)) {
            try emissionController.applyProposalParams(uint8(proposal.proposalType), proposal.params) {
                // Emission policy applied by the configured controller.
            } catch {
                emit EmissionControllerApplyFailed(proposalId, controller);
            }
        }

        emit ProposalExecuted(proposalId, proposal.proposalType, proposal.params);
    }

    function veto(bytes32 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.submittedAt == 0) revert AiDaoProposalNotFound();
        if (proposal.executed) revert AiDaoAlreadyExecuted();
        if (proposal.vetoed) revert AiDaoVetoed();
        if (block.timestamp >= proposal.vetoDeadline) revert AiDaoVetoWindowClosed();

        (uint256 forVotes, uint256 againstVotes,) = secureVotingSystem.getProposalVotes(
            proposal.secureVotingProposalId
        );

        if (againstVotes <= forVotes) revert AiDaoVetoMajorityNotReached();

        proposal.vetoed = true;
        emit ProposalVetoed(proposalId, proposal.secureVotingProposalId, againstVotes, forVotes);
    }

    function addAiOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert AiDaoInvalidAddress();
        aiOracles[oracle] = true;
        emit AiOracleUpdated(oracle, true);
    }

    function removeAiOracle(address oracle) external onlyOwner {
        aiOracles[oracle] = false;
        emit AiOracleUpdated(oracle, false);
    }

    function pause() external onlyGuardian {
        _pause();
    }

    function unpause() external onlyGuardian {
        _unpause();
    }

    function setTimelock(uint256 newTimelockSeconds) external onlyOwner {
        if (newTimelockSeconds == 0) revert AiDaoInvalidTimelock();
        uint256 previousTimelock = timelockSeconds;
        timelockSeconds = newTimelockSeconds;
        emit TimelockUpdated(previousTimelock, newTimelockSeconds);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert AiDaoInvalidAddress();
        address previousGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(previousGuardian, newGuardian);
    }

    function setSecureVotingSystem(address newSecureVotingSystem) external onlyOwner {
        if (newSecureVotingSystem == address(0)) revert AiDaoInvalidAddress();
        address previousSystem = address(secureVotingSystem);
        secureVotingSystem = ISecureVotingSystem(newSecureVotingSystem);
        emit SecureVotingSystemUpdated(previousSystem, newSecureVotingSystem);
    }

    function setEmissionController(address newEmissionController) external onlyOwner {
        address previousController = address(emissionController);
        emissionController = IEmissionController(newEmissionController);
        emit EmissionControllerUpdated(previousController, newEmissionController);
    }

    function _decodeSecureVotingProposalId(
        bytes calldata params
    ) internal pure returns (uint256 secureVotingProposalId) {
        if (params.length < 32) revert AiDaoInvalidParams();
        assembly {
            secureVotingProposalId := calldataload(params.offset)
        }
    }
}
