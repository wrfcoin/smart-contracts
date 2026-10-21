// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice DAO-owned registry of IP corpus commitments and revocable publishing authority.
/// @dev This contract deliberately stores public-key fingerprints, never private keys.
///      Human and AI operators are both represented only by an EVM address.
contract SovereignIPAuthority is AccessControl {
    bytes32 public constant IP_CURATOR_ROLE = keccak256("IP_CURATOR_ROLE");
    bytes32 public constant PUBLICATION_ADMIN_ROLE = keccak256("PUBLICATION_ADMIN_ROLE");

    uint8 public constant GITHUB_RELEASE = 1;
    uint8 public constant MEDIA_PUBLICATION = 2;

    struct Asset {
        bytes32 corpusCommitment;
        bytes32 keyFingerprint;
        bool active;
        uint64 version;
    }

    struct Grant {
        uint8 capabilities;
        uint64 validUntil;
        uint64 assetVersion;
    }

    mapping(bytes32 => Asset) private _assets;
    mapping(bytes32 => mapping(address => Grant)) private _grants;

    event AssetRegistered(bytes32 indexed assetId, bytes32 indexed corpusCommitment, bytes32 indexed keyFingerprint);
    event AssetRevoked(bytes32 indexed assetId);
    event AssetReactivated(bytes32 indexed assetId);
    event AssetKeyFingerprintRotated(bytes32 indexed assetId, bytes32 indexed previousKeyFingerprint, bytes32 indexed nextKeyFingerprint);
    event PublicationGrantSet(bytes32 indexed assetId, address indexed operator, uint8 capabilities, uint64 validUntil);
    event PublicationGrantRevoked(bytes32 indexed assetId, address indexed operator);

    constructor(address dao) {
        require(dao != address(0), "SovereignIPAuthority: zero dao");
        _grantRole(DEFAULT_ADMIN_ROLE, dao);
        _grantRole(IP_CURATOR_ROLE, dao);
        _grantRole(PUBLICATION_ADMIN_ROLE, dao);
    }

    function registerAsset(bytes32 assetId, bytes32 corpusCommitment, bytes32 keyFingerprint)
        external
        onlyRole(IP_CURATOR_ROLE)
    {
        require(assetId != bytes32(0), "SovereignIPAuthority: zero asset");
        require(corpusCommitment != bytes32(0), "SovereignIPAuthority: zero corpus commitment");
        require(keyFingerprint != bytes32(0), "SovereignIPAuthority: zero key fingerprint");
        require(_assets[assetId].corpusCommitment == bytes32(0), "SovereignIPAuthority: asset exists");

        _assets[assetId] = Asset(corpusCommitment, keyFingerprint, true, 1);
        emit AssetRegistered(assetId, corpusCommitment, keyFingerprint);
    }

    function revokeAsset(bytes32 assetId) external onlyRole(IP_CURATOR_ROLE) {
        require(_assets[assetId].corpusCommitment != bytes32(0), "SovereignIPAuthority: unknown asset");
        _assets[assetId].active = false;
        _assets[assetId].version += 1;
        emit AssetRevoked(assetId);
    }

    function reactivateAsset(bytes32 assetId) external onlyRole(IP_CURATOR_ROLE) {
        Asset storage asset = _assets[assetId];
        require(asset.corpusCommitment != bytes32(0), "SovereignIPAuthority: unknown asset");
        require(!asset.active, "SovereignIPAuthority: asset already active");
        asset.active = true;
        emit AssetReactivated(assetId);
    }

    function rotateAssetKeyFingerprint(bytes32 assetId, bytes32 newKeyFingerprint) external onlyRole(IP_CURATOR_ROLE) {
        Asset storage asset = _assets[assetId];
        require(asset.corpusCommitment != bytes32(0), "SovereignIPAuthority: unknown asset");
        require(newKeyFingerprint != bytes32(0), "SovereignIPAuthority: zero key fingerprint");
        bytes32 previousKeyFingerprint = asset.keyFingerprint;
        require(newKeyFingerprint != previousKeyFingerprint, "SovereignIPAuthority: duplicate key fingerprint");
        asset.keyFingerprint = newKeyFingerprint;
        asset.version += 1;
        emit AssetKeyFingerprintRotated(assetId, previousKeyFingerprint, newKeyFingerprint);
    }

    function setPublicationGrant(bytes32 assetId, address operator, uint8 capabilities, uint64 validUntil)
        external
        onlyRole(PUBLICATION_ADMIN_ROLE)
    {
        require(_assets[assetId].active, "SovereignIPAuthority: inactive asset");
        require(operator != address(0), "SovereignIPAuthority: zero operator");
        require(capabilities != 0 && capabilities <= (GITHUB_RELEASE | MEDIA_PUBLICATION), "SovereignIPAuthority: invalid capabilities");
        require(validUntil > block.timestamp, "SovereignIPAuthority: expired grant");
        _grants[assetId][operator] = Grant(
            capabilities,
            validUntil,
            _assets[assetId].version
        );
        emit PublicationGrantSet(assetId, operator, capabilities, validUntil);
    }

    function revokePublicationGrant(bytes32 assetId, address operator) external onlyRole(PUBLICATION_ADMIN_ROLE) {
        Asset storage asset = _assets[assetId];
        require(asset.corpusCommitment != bytes32(0), "SovereignIPAuthority: unknown asset");
        Grant memory grant = _grants[assetId][operator];
        require(grant.capabilities != 0 && grant.assetVersion == asset.version, "SovereignIPAuthority: unknown grant");
        delete _grants[assetId][operator];
        emit PublicationGrantRevoked(assetId, operator);
    }

    function isAuthorized(bytes32 assetId, address operator, uint8 capability) public view returns (bool) {
        Grant memory grant = _grants[assetId][operator];
        Asset memory asset = _assets[assetId];
        return asset.active
            && grant.assetVersion == asset.version
            && asset.corpusCommitment != bytes32(0)
            && capability != 0
            && (grant.capabilities & capability) == capability
            && grant.validUntil >= block.timestamp;
    }

    function isAuthorizedForContent(bytes32 assetId, bytes32 contentHash, address operator, uint8 capability)
        public
        view
        returns (bool)
    {
        return isAuthorized(assetId, operator, capability) && _assets[assetId].corpusCommitment == contentHash;
    }

    /// @notice Reverting seam for a release/publication executor to enforce the DAO decision.
    function requireAuthorized(bytes32 assetId, address operator, uint8 capability) external view {
        require(isAuthorized(assetId, operator, capability), "SovereignIPAuthority: operator not authorized");
    }

    /// @notice Payload-bound authorization variant for publication executors.
    function requireAuthorizedForContent(
        bytes32 assetId,
        bytes32 contentHash,
        address operator,
        uint8 capability
    ) external view {
        require(
            isAuthorizedForContent(assetId, contentHash, operator, capability),
            "SovereignIPAuthority: operator not authorized for payload"
        );
    }

    function getAsset(bytes32 assetId) external view returns (Asset memory) {
        return _assets[assetId];
    }

    function getGrant(bytes32 assetId, address operator) external view returns (Grant memory) {
        return _grants[assetId][operator];
    }
}
