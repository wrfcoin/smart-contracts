// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../interfaces/IExtremeWeatherOracle.sol";
import "./lib/WeatherSVG.sol";

contract StormChaserNFT is ERC721URIStorage, AccessControl, Ownable2Step {
    using Strings for uint256;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    uint256 public constant VERIFICATION_WINDOW = 48 hours;

    struct StormRecord {
        bytes32 eventId;
        uint8 severity;
        string eventType;
        address oracleAddress;
        uint256 submissionTimestamp;
        uint256 accuracyScore;
    }

    uint256 private _nextTokenId = 1;

    IExtremeWeatherOracle public extremeWeatherOracle;

    mapping(uint256 => StormRecord) public storms;
    mapping(bytes32 => mapping(address => bool)) public hasMintedForEvent;

    error DuplicateStormSubmission(bytes32 eventId, address oracle);
    error EventNotExtreme(bytes32 eventId);
    error TransferLocked(uint256 tokenId);
    error UnauthorizedOracle(address account);
    error ZeroAddress();

    event AccuracyUpdated(uint256 indexed tokenId, uint256 previousScore, uint256 newScore);
    event ExtremeWeatherOracleUpdated(address indexed previousOracle, address indexed newOracle);

    constructor(
        address authorizedOracle,
        address extremeWeatherOracleAddress
    ) ERC721("WRFCoin Storm Chaser", "WRFSTORM") Ownable(msg.sender) {
        if (authorizedOracle == address(0) || extremeWeatherOracleAddress == address(0)) {
            revert ZeroAddress();
        }
        extremeWeatherOracle = IExtremeWeatherOracle(extremeWeatherOracleAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, authorizedOracle);
    }

    function grantOracleRole(address account) external onlyOwner {
        _grantRole(ORACLE_ROLE, account);
    }

    function revokeOracleRole(address account) external onlyOwner {
        _revokeRole(ORACLE_ROLE, account);
    }

    function setExtremeWeatherOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) {
            revert ZeroAddress();
        }
        address previousOracle = address(extremeWeatherOracle);
        extremeWeatherOracle = IExtremeWeatherOracle(newOracle);
        emit ExtremeWeatherOracleUpdated(previousOracle, newOracle);
    }

    function mintForEvent(address oracle, bytes32 eventId) external returns (uint256 tokenId) {
        if (!hasRole(ORACLE_ROLE, msg.sender)) {
            revert UnauthorizedOracle(msg.sender);
        }
        if (hasMintedForEvent[eventId][oracle]) {
            revert DuplicateStormSubmission(eventId, oracle);
        }

        (bool isExtreme, uint8 severity, string memory eventType) = extremeWeatherOracle
            .getEventClassification(eventId);
        if (!isExtreme) {
            revert EventNotExtreme(eventId);
        }

        tokenId = _nextTokenId++;
        hasMintedForEvent[eventId][oracle] = true;
        storms[tokenId] = StormRecord({
            eventId: eventId,
            severity: severity,
            eventType: eventType,
            oracleAddress: oracle,
            submissionTimestamp: block.timestamp,
            accuracyScore: 0
        });
        _safeMint(oracle, tokenId);
        emit MetadataUpdate(tokenId);
    }

    function updateAccuracy(uint256 tokenId, uint256 score) external {
        if (!hasRole(ORACLE_ROLE, msg.sender)) {
            revert UnauthorizedOracle(msg.sender);
        }
        require(score <= 100, "StormChaserNFT: accuracy out of range");
        _requireOwned(tokenId);

        uint256 previousScore = storms[tokenId].accuracyScore;
        storms[tokenId].accuracyScore = score;
        emit AccuracyUpdated(tokenId, previousScore, score);
        emit MetadataUpdate(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        StormRecord storage record = storms[tokenId];
        string memory image = Base64.encode(
            bytes(
                WeatherSVG.generateStormSVG(
                    record.severity,
                    record.eventType,
                    record.accuracyScore
                )
            )
        );
        string memory json = Base64.encode(
            bytes(
                string.concat(
                    '{"name":"Storm Chaser #',
                    tokenId.toString(),
                    '","description":"Dynamic NFT for extreme-weather oracle submissions.",',
                    '"attributes":[',
                    '{"trait_type":"Event Type","value":"',
                    record.eventType,
                    '"},',
                    '{"trait_type":"Severity","value":',
                    uint256(record.severity).toString(),
                    "},",
                    '{"trait_type":"Accuracy Score","value":',
                    record.accuracyScore.toString(),
                    "},",
                    '{"trait_type":"Verification Locked","value":"',
                    _isTransferLocked(record) ? "true" : "false",
                    '"}],',
                    '"image":"data:image/svg+xml;base64,',
                    image,
                    '"}'
                )
            )
        );
        return string.concat("data:application/json;base64,", json);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && _isTransferLocked(storms[tokenId])) {
            revert TransferLocked(tokenId);
        }
        return super._update(to, tokenId, auth);
    }

    function _isTransferLocked(StormRecord storage record) internal view returns (bool) {
        return block.timestamp < record.submissionTimestamp + VERIFICATION_WINDOW;
    }
}
