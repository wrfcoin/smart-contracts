// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ActorBindingRegistry
 * @notice Binds actor-class attestations to stake-identity epochs.
 * @dev Wave 4 completion makes bindings epoch-aware: once the epoch advances,
 *      prior-epoch attestations remain queryable but are no longer valid for
 *      current participation and must be refreshed.
 */
contract ActorBindingRegistry is AccessControl, ReentrancyGuard {
    bytes32 public constant BINDING_ADMIN_ROLE = keccak256("BINDING_ADMIN_ROLE");

    enum ActorClass { Human, AI, Robot }

    struct ActorBinding {
        address actor;
        ActorClass actorClass;
        uint256 epoch;
        bytes32 attestationHash;
        uint256 boundAt;
        uint256 expiresAt;
        bool active;
        uint256 deactivatedAt;
    }

    mapping(address => ActorBinding) private _bindings;
    mapping(uint256 => address[]) private _epochActors;

    uint256 public currentEpoch;

    event ActorBound(
        address indexed actor,
        uint8 indexed actorClass,
        uint256 indexed epoch,
        bytes32 attestationHash
    );
    event ActorDeactivated(address indexed actor, uint256 epoch);
    event EpochAdvanced(uint256 newEpoch);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BINDING_ADMIN_ROLE, msg.sender);
        currentEpoch = 1;
    }

    function bindActor(
        address actor,
        ActorClass actorClass,
        bytes32 attestationHash,
        uint256 duration
    ) external onlyRole(BINDING_ADMIN_ROLE) nonReentrant {
        require(actor != address(0), "ActorBindingRegistry: zero address");
        require(attestationHash != bytes32(0), "ActorBindingRegistry: zero attestation hash");
        require(duration > 0, "ActorBindingRegistry: zero duration");

        ActorBinding storage existing = _bindings[actor];
        if (_isValidForCurrentEpoch(existing)) {
            revert("ActorBindingRegistry: already bound");
        }

        uint256 epoch = currentEpoch;
        _bindings[actor] = ActorBinding({
            actor: actor,
            actorClass: actorClass,
            epoch: epoch,
            attestationHash: attestationHash,
            boundAt: block.timestamp,
            expiresAt: block.timestamp + duration,
            active: true,
            deactivatedAt: 0
        });
        _epochActors[epoch].push(actor);

        emit ActorBound(actor, uint8(actorClass), epoch, attestationHash);
    }

    function deactivateActor(address actor) external onlyRole(BINDING_ADMIN_ROLE) nonReentrant {
        ActorBinding storage binding = _bindings[actor];
        require(binding.boundAt != 0, "ActorBindingRegistry: binding not found");
        require(binding.active, "ActorBindingRegistry: already inactive");

        binding.active = false;
        binding.deactivatedAt = block.timestamp;

        emit ActorDeactivated(actor, binding.epoch);
    }

    function advanceEpoch() external onlyRole(BINDING_ADMIN_ROLE) nonReentrant {
        currentEpoch++;
        emit EpochAdvanced(currentEpoch);
    }

    function getBinding(address actor) external view returns (ActorBinding memory) {
        require(_bindings[actor].boundAt != 0, "ActorBindingRegistry: binding not found");
        return _bindings[actor];
    }

    function isActiveBound(address actor) external view returns (bool) {
        return _isValidForCurrentEpoch(_bindings[actor]);
    }

    function isBindingValidForCurrentEpoch(address actor) external view returns (bool) {
        return _isValidForCurrentEpoch(_bindings[actor]);
    }

    function getEpochActors(uint256 epoch) external view returns (address[] memory) {
        return _epochActors[epoch];
    }

    function getActorClass(address actor) external view returns (ActorClass) {
        require(_bindings[actor].boundAt != 0, "ActorBindingRegistry: binding not found");
        return _bindings[actor].actorClass;
    }

    function _isValidForCurrentEpoch(
        ActorBinding storage binding
    ) internal view returns (bool) {
        if (binding.boundAt == 0) {
            return false;
        }
        if (!binding.active) {
            return false;
        }
        if (binding.epoch != currentEpoch) {
            return false;
        }
        return binding.expiresAt > block.timestamp;
    }
}
