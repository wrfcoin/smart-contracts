// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title PolicyHashRegistry
 * @notice Anchors compiled sanction policy hashes on-chain for tamper-evidence.
 * @dev Wave 4 completion stores signature-backed keccak256 policy anchors and
 *      explicit document verification helpers while preserving historical
 *      lookup for previously anchored versions.
 */
contract PolicyHashRegistry is AccessControl, ReentrancyGuard {
    bytes32 public constant POLICY_ANCHOR_ROLE = keccak256("POLICY_ANCHOR_ROLE");

    struct PolicyEpoch {
        bytes32 policyHash;
        uint256 activationBlock;
        uint256 deactivationBlock;
        uint32 version;
        uint256 anchoredAt;
        bytes adminSignature;
        address adminSigner;
    }

    PolicyEpoch[] private _epochs;
    mapping(uint32 => uint256) private _versionToEpochIndexPlusOne;

    event PolicyHashAnchored(
        bytes32 indexed policyHash,
        uint256 activationBlock,
        uint32 version,
        address indexed adminSigner
    );
    event PolicyHashDeactivated(bytes32 indexed policyHash, uint256 deactivationBlock);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(POLICY_ANCHOR_ROLE, msg.sender);
    }

    function anchorPolicyHash(
        bytes32 policyHash,
        uint32 version,
        bytes calldata adminSignature
    ) external onlyRole(POLICY_ANCHOR_ROLE) nonReentrant {
        require(policyHash != bytes32(0), "PolicyHashRegistry: zero hash");
        require(version > 0, "PolicyHashRegistry: zero version");
        require(adminSignature.length > 0, "PolicyHashRegistry: empty admin signature");

        address signer = _recoverAnchorSigner(policyHash, version, adminSignature);
        require(
            hasRole(POLICY_ANCHOR_ROLE, signer),
            "PolicyHashRegistry: invalid admin signature"
        );
        require(
            _versionToEpochIndexPlusOne[version] == 0,
            "PolicyHashRegistry: version already anchored"
        );

        if (_epochs.length > 0) {
            PolicyEpoch storage previous = _epochs[_epochs.length - 1];
            if (previous.deactivationBlock == 0) {
                previous.deactivationBlock = block.number;
                emit PolicyHashDeactivated(previous.policyHash, block.number);
            }
        }

        _epochs.push(
            PolicyEpoch({
                policyHash: policyHash,
                activationBlock: block.number,
                deactivationBlock: 0,
                version: version,
                anchoredAt: block.timestamp,
                adminSignature: adminSignature,
                adminSigner: signer
            })
        );
        _versionToEpochIndexPlusOne[version] = _epochs.length;

        emit PolicyHashAnchored(policyHash, block.number, version, signer);
    }

    function computeDocumentHash(bytes calldata policyDocument) public pure returns (bytes32) {
        return keccak256(policyDocument);
    }

    function verifyPolicyDocument(bytes calldata policyDocument) external view returns (bool) {
        return _getActivePolicy().policyHash == computeDocumentHash(policyDocument);
    }

    function verifyPolicyDocumentForVersion(
        uint32 version,
        bytes calldata policyDocument
    ) external view returns (bool) {
        return getPolicyByVersion(version).policyHash == computeDocumentHash(policyDocument);
    }

    function getActivePolicy() external view returns (PolicyEpoch memory) {
        return _getActivePolicy();
    }

    function getPolicyByEpoch(uint256 epochIndex) external view returns (PolicyEpoch memory) {
        require(epochIndex < _epochs.length, "PolicyHashRegistry: invalid epoch");
        return _epochs[epochIndex];
    }

    function getPolicyByVersion(uint32 version) public view returns (PolicyEpoch memory) {
        uint256 indexPlusOne = _versionToEpochIndexPlusOne[version];
        require(indexPlusOne != 0, "PolicyHashRegistry: unknown version");
        return _epochs[indexPlusOne - 1];
    }

    function getPolicyAtBlock(uint256 blockNumber) external view returns (PolicyEpoch memory) {
        for (uint256 i = _epochs.length; i > 0; i--) {
            PolicyEpoch storage epoch = _epochs[i - 1];
            if (blockNumber >= epoch.activationBlock) {
                if (epoch.deactivationBlock == 0 || blockNumber < epoch.deactivationBlock) {
                    return epoch;
                }
            }
        }
        revert("PolicyHashRegistry: no policy at block");
    }

    function validateEnforcementReference(bytes32 policyHash) external view returns (bool) {
        if (_epochs.length == 0) return false;
        PolicyEpoch storage current = _epochs[_epochs.length - 1];
        return current.deactivationBlock == 0 && current.policyHash == policyHash;
    }

    function getEpochCount() external view returns (uint256) {
        return _epochs.length;
    }

    function anchorDigest(bytes32 policyHash, uint32 version) external view returns (bytes32) {
        return _anchorDigest(policyHash, version);
    }

    function _getActivePolicy() internal view returns (PolicyEpoch memory) {
        require(_epochs.length > 0, "PolicyHashRegistry: no epochs");
        PolicyEpoch storage current = _epochs[_epochs.length - 1];
        require(current.deactivationBlock == 0, "PolicyHashRegistry: no active policy");
        return current;
    }

    function _anchorDigest(bytes32 policyHash, uint32 version) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, policyHash, version));
    }

    function _recoverAnchorSigner(
        bytes32 policyHash,
        uint32 version,
        bytes calldata adminSignature
    ) internal view returns (address) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(_anchorDigest(policyHash, version));
        return ECDSA.recover(digest, adminSignature);
    }
}
