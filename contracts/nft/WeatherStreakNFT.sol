// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./lib/WeatherSVG.sol";

contract WeatherStreakNFT is ERC721URIStorage, AccessControl, Ownable2Step {
    using Strings for uint256;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    uint256 public constant STREAK_GRACE_PERIOD = 25 hours;

    enum Tier {
        Bronze,
        Silver,
        Gold,
        Diamond
    }

    struct StreakRecord {
        uint256 tokenId;
        uint256 streakDays;
        uint256 lastSubmissionTimestamp;
        uint256 lastSubmissionDay;
        Tier tier;
    }

    uint256 private _nextTokenId = 1;

    mapping(address => StreakRecord) public streaks;
    mapping(uint256 => address) public streakOracle;

    error ActiveStreakSoulbound(uint256 tokenId);
    error UnauthorizedOracle(address account);
    error ZeroAddress();

    event SubmissionRecorded(
        address indexed oracle,
        uint256 indexed tokenId,
        uint256 streakDays,
        Tier tier
    );

    constructor(address authorizedOracle) ERC721("WRFCoin Weather Streak", "WRFSTREAK") Ownable(msg.sender) {
        if (authorizedOracle == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, authorizedOracle);
    }

    function grantOracleRole(address account) external onlyOwner {
        _grantRole(ORACLE_ROLE, account);
    }

    function revokeOracleRole(address account) external onlyOwner {
        _revokeRole(ORACLE_ROLE, account);
    }

    function recordSubmission(address oracle, uint256 submissionTimestamp) external {
        if (!hasRole(ORACLE_ROLE, msg.sender)) {
            revert UnauthorizedOracle(msg.sender);
        }

        StreakRecord storage record = streaks[oracle];
        uint256 submissionDay = submissionTimestamp / 1 days;

        if (record.tokenId == 0) {
            uint256 tokenId = _nextTokenId++;
            _safeMint(oracle, tokenId);
            streakOracle[tokenId] = oracle;
            record.tokenId = tokenId;
            record.streakDays = 1;
            record.lastSubmissionTimestamp = submissionTimestamp;
            record.lastSubmissionDay = submissionDay;
            record.tier = _tierForDays(1);
            emit MetadataUpdate(tokenId);
            emit SubmissionRecorded(oracle, tokenId, 1, record.tier);
            return;
        }

        if (submissionDay > record.lastSubmissionDay) {
            if (submissionTimestamp > record.lastSubmissionTimestamp + STREAK_GRACE_PERIOD) {
                record.streakDays = 1;
            } else {
                record.streakDays += 1;
            }
            record.lastSubmissionDay = submissionDay;
        }

        record.lastSubmissionTimestamp = submissionTimestamp;
        record.tier = _tierForDays(record.streakDays);

        emit MetadataUpdate(record.tokenId);
        emit SubmissionRecorded(oracle, record.tokenId, record.streakDays, record.tier);
    }

    function streakData(
        address oracle
    )
        external
        view
        returns (
            uint256 tokenId,
            uint256 streakDays,
            uint256 lastSubmissionTimestamp,
            uint256 lastSubmissionDay,
            Tier tier,
            bool active
        )
    {
        StreakRecord storage record = streaks[oracle];
        tokenId = record.tokenId;
        streakDays = record.streakDays;
        lastSubmissionTimestamp = record.lastSubmissionTimestamp;
        lastSubmissionDay = record.lastSubmissionDay;
        tier = record.tier;
        active = _isStreakActive(record);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address oracle = streakOracle[tokenId];
        _requireOwned(tokenId);

        StreakRecord storage record = streaks[oracle];
        string memory tierLabel = _tierLabel(record.tier);
        string memory image = Base64.encode(
            bytes(WeatherSVG.generateStreakSVG(tierLabel, record.streakDays, oracle))
        );
        string memory json = Base64.encode(
            bytes(
                string.concat(
                    '{"name":"Weather Streak #',
                    tokenId.toString(),
                    '","description":"Dynamic streak NFT for verified weather submissions.",',
                    '"attributes":[',
                    '{"trait_type":"Tier","value":"',
                    tierLabel,
                    '"},',
                    '{"trait_type":"Streak Days","value":',
                    record.streakDays.toString(),
                    "},",
                    '{"trait_type":"Active","value":"',
                    _isStreakActive(record) ? "true" : "false",
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
        if (from != address(0) && to != address(0)) {
            address oracle = streakOracle[tokenId];
            if (_isStreakActive(streaks[oracle])) {
                revert ActiveStreakSoulbound(tokenId);
            }
        }
        return super._update(to, tokenId, auth);
    }

    function _isStreakActive(StreakRecord storage record) internal view returns (bool) {
        return
            record.tokenId != 0 &&
            record.lastSubmissionTimestamp != 0 &&
            block.timestamp <= record.lastSubmissionTimestamp + STREAK_GRACE_PERIOD;
    }

    function _tierForDays(uint256 streakDays) internal pure returns (Tier) {
        if (streakDays >= 365) {
            return Tier.Diamond;
        }
        if (streakDays >= 90) {
            return Tier.Gold;
        }
        if (streakDays >= 30) {
            return Tier.Silver;
        }
        return Tier.Bronze;
    }

    function _tierLabel(Tier tier) internal pure returns (string memory) {
        if (tier == Tier.Diamond) {
            return "Diamond";
        }
        if (tier == Tier.Gold) {
            return "Gold";
        }
        if (tier == Tier.Silver) {
            return "Silver";
        }
        return "Bronze";
    }
}
