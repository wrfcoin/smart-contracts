// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title StationAdoptionCertificateNFT
 * @notice Shareable proof-of-adoption NFT for sponsored weather stations.
 * @dev A compact first-pass certificate that stores adoption metadata on-chain
 *      and renders tokenURI as a base64-encoded JSON document.
 */
contract StationAdoptionCertificateNFT is ERC721, AccessControl, Pausable, ReentrancyGuard {
    using Strings for uint256;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    struct CertificateData {
        address sponsor;
        uint256 projectId;
        bytes32 regionId;
        bytes32 stationId;
        uint256 sponsoredAmount;
        uint256 deploymentTimestamp;
        uint256 cumulativeDataRewards;
        uint256 mintedAt;
    }

    uint256 private _nextTokenId = 1;

    mapping(uint256 => CertificateData) private _certificates;

    event CertificateMinted(
        address indexed sponsor,
        uint256 indexed tokenId,
        uint256 indexed projectId,
        bytes32 regionId,
        bytes32 stationId,
        uint256 sponsoredAmount
    );

    error ZeroAddress();
    error ZeroAmount();
    error UnknownCertificate();

    constructor() ERC721("WRF Station Adoption Certificate", "WRF-ADOPT") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function mintCertificate(
        address sponsor,
        uint256 projectId,
        bytes32 regionId,
        bytes32 stationId,
        uint256 sponsoredAmount,
        uint256 deploymentTimestamp,
        uint256 cumulativeDataRewards
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant returns (uint256 tokenId) {
        if (sponsor == address(0)) revert ZeroAddress();
        if (sponsoredAmount == 0) revert ZeroAmount();

        tokenId = _nextTokenId++;
        _safeMint(sponsor, tokenId);

        _certificates[tokenId] = CertificateData({
            sponsor: sponsor,
            projectId: projectId,
            regionId: regionId,
            stationId: stationId,
            sponsoredAmount: sponsoredAmount,
            deploymentTimestamp: deploymentTimestamp,
            cumulativeDataRewards: cumulativeDataRewards,
            mintedAt: block.timestamp
        });

        emit CertificateMinted(
            sponsor,
            tokenId,
            projectId,
            regionId,
            stationId,
            sponsoredAmount
        );
    }

    function certificateData(uint256 tokenId)
        external
        view
        returns (
            address sponsor,
            uint256 projectId,
            bytes32 regionId,
            bytes32 stationId,
            uint256 sponsoredAmount,
            uint256 deploymentTimestamp,
            uint256 cumulativeDataRewards,
            uint256 mintedAt
        )
    {
        CertificateData memory cert = _getCertificate(tokenId);
        return (
            cert.sponsor,
            cert.projectId,
            cert.regionId,
            cert.stationId,
            cert.sponsoredAmount,
            cert.deploymentTimestamp,
            cert.cumulativeDataRewards,
            cert.mintedAt
        );
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        CertificateData memory cert = _getCertificate(tokenId);

        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name":"Station Adoption Certificate #',
                        tokenId.toString(),
                        '","description":"Proof of sponsoring a weather station deployment in a data desert region.","attributes":[',
                        '{"trait_type":"Project ID","value":"',
                        cert.projectId.toString(),
                        '"},',
                        '{"trait_type":"Region ID","value":"',
                        _bytes32ToHex(cert.regionId),
                        '"},',
                        '{"trait_type":"Station ID","value":"',
                        _bytes32ToHex(cert.stationId),
                        '"},',
                        '{"trait_type":"Sponsor","value":"',
                        _addressToHex(cert.sponsor),
                        '"},',
                        '{"trait_type":"Sponsored Amount","display_type":"number","value":"',
                        cert.sponsoredAmount.toString(),
                        '"},',
                        '{"trait_type":"Deployment Timestamp","display_type":"date","value":"',
                        cert.deploymentTimestamp.toString(),
                        '"},',
                        '{"trait_type":"Cumulative Data Rewards","display_type":"number","value":"',
                        cert.cumulativeDataRewards.toString(),
                        '"},',
                        '{"trait_type":"Minted At","display_type":"date","value":"',
                        cert.mintedAt.toString(),
                        '"}]}'
                    )
                )
            )
        );

        return string.concat("data:application/json;base64,", json);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _getCertificate(uint256 tokenId) internal view returns (CertificateData memory) {
        if (!_ownerExists(tokenId)) revert UnknownCertificate();
        return _certificates[tokenId];
    }

    function _ownerExists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _bytes32ToHex(bytes32 value) internal pure returns (string memory) {
        return Strings.toHexString(uint256(value), 32);
    }

    function _addressToHex(address value) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(value)), 20);
    }
}
