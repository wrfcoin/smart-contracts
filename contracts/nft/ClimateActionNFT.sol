// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ClimateActionNFT
 * @notice ERC-721 certificates representing verifiable carbon-offset contributions
 *         from WRFCoin weather data contributors.
 *
 * Each token encodes:
 *   - offsetTonnes   — estimated CO₂ offset in kg (e.g., 2300 = 2.3 tonnes)
 *   - vintageYear    — the calendar year the contribution was made
 *   - readingsCount  — number of verified sensor readings backing this certificate
 *   - verified       — whether a third-party oracle has attested the impact
 *   - retired        — whether the certificate has been burned for ESG reporting
 *
 * Tier upgrades (Bronze → Silver → Gold → Diamond) are driven by accumulated
 * `offsetTonnes` across all unretired tokens held by the contributor.
 *
 * Dynamic on-chain SVG metadata is generated from live token state.
 */
contract ClimateActionNFT is ERC721URIStorage, AccessControl, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------
    bytes32 public constant ORACLE_ROLE     = keccak256("ORACLE_ROLE");
    bytes32 public constant MINTER_ROLE     = keccak256("MINTER_ROLE");
    bytes32 public constant VERIFIER_ROLE   = keccak256("VERIFIER_ROLE");

    // -----------------------------------------------------------------------
    // Tier thresholds (offsetKg parameter is in whole kg)
    // -----------------------------------------------------------------------
    uint256 public constant SILVER_THRESHOLD  =   500; //   500 kg
    uint256 public constant GOLD_THRESHOLD    = 2_000; // 2 000 kg
    uint256 public constant DIAMOND_THRESHOLD = 5_000; // 5 000 kg

    // -----------------------------------------------------------------------
    // Data model
    // -----------------------------------------------------------------------
    enum Tier { Bronze, Silver, Gold, Diamond }

    struct CarbonRecord {
        uint256 offsetKg;       // CO₂ offset in whole kilograms
        uint16  vintageYear;
        uint32  readingsCount;
        bool    verified;       // third-party oracle attestation
        bool    retired;        // burned for ESG claim; prevents double-counting
    }

    uint256 private _nextTokenId = 1;

    mapping(uint256 => CarbonRecord) public carbonRecords;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event ClimateNFTMinted(
        address indexed to,
        uint256 indexed tokenId,
        uint256 offsetKg,
        uint16  vintageYear,
        uint32  readingsCount
    );
    event RecordVerified(uint256 indexed tokenId, address indexed verifier);
    event RecordRetired(uint256 indexed tokenId, address indexed retirer);
    event OffsetUpdated(uint256 indexed tokenId, uint256 newOffsetKg, uint32 newReadingsCount);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error ZeroAddress();
    error AlreadyVerified(uint256 tokenId);
    error AlreadyRetired(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId, address caller);
    error ZeroOffset();
    error InvalidYear();
    error TokenDoesNotExist(uint256 tokenId);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(address oracle, address minter) ERC721("WRFCoin Climate Action", "WRFCLIMATE") Ownable(msg.sender) {
        if (oracle == address(0) || minter == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, oracle);
        _grantRole(MINTER_ROLE, minter);
    }

    // -----------------------------------------------------------------------
    // Minting
    // -----------------------------------------------------------------------

    /**
     * @notice Mint a new Climate Action certificate.
     * @param to            Recipient address (the contributor).
     * @param offsetKg      Estimated CO₂ offset in kg.
     * @param vintageYear   Calendar year of contribution (e.g., 2025).
     * @param readingsCount Number of verified sensor readings.
     */
    function mint(
        address to,
        uint256 offsetKg,
        uint16  vintageYear,
        uint32  readingsCount
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (to == address(0))          revert ZeroAddress();
        if (offsetKg == 0)             revert ZeroOffset();
        if (vintageYear < 2020 || vintageYear > 2100) revert InvalidYear();

        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        carbonRecords[tokenId] = CarbonRecord({
            offsetKg:      offsetKg,
            vintageYear:   vintageYear,
            readingsCount: readingsCount,
            verified:      false,
            retired:       false
        });

        _setTokenURI(tokenId, _buildMetadata(tokenId));

        emit ClimateNFTMinted(to, tokenId, offsetKg, vintageYear, readingsCount);
    }

    // -----------------------------------------------------------------------
    // Oracle: update impact stats
    // -----------------------------------------------------------------------

    /**
     * @notice Update the offset and readings figures for an existing token.
     *         Called by the oracle backend as more data is validated.
     * @dev Security: requires the token to exist. Without this check, an oracle could
     *      write carbonRecords entries for arbitrary un-minted tokenIds, causing state
     *      corruption if those IDs are later minted (data would appear pre-populated).
     */
    function updateOffset(
        uint256 tokenId,
        uint256 newOffsetKg,
        uint32  newReadingsCount
    ) external onlyRole(ORACLE_ROLE) {
        if (!_exists(tokenId)) revert TokenDoesNotExist(tokenId);
        CarbonRecord storage rec = carbonRecords[tokenId];
        if (rec.retired)      revert AlreadyRetired(tokenId);
        if (newOffsetKg == 0) revert ZeroOffset();

        rec.offsetKg      = newOffsetKg;
        rec.readingsCount = newReadingsCount;
        _setTokenURI(tokenId, _buildMetadata(tokenId));

        emit OffsetUpdated(tokenId, newOffsetKg, newReadingsCount);
    }

    // -----------------------------------------------------------------------
    // Verification
    // -----------------------------------------------------------------------

    /**
     * @notice Mark a token as third-party verified (on-chain attestation).
     * @dev Security: requires the token to exist. Without this check, a verifier could
     *      set the verified flag on an un-minted tokenId, pre-polluting its record before
     *      the legitimate mint occurs and bypassing the mint-time verification workflow.
     */
    function verify(uint256 tokenId) external onlyRole(VERIFIER_ROLE) {
        if (!_exists(tokenId)) revert TokenDoesNotExist(tokenId);
        CarbonRecord storage rec = carbonRecords[tokenId];
        if (rec.verified) revert AlreadyVerified(tokenId);
        if (rec.retired)  revert AlreadyRetired(tokenId);

        rec.verified = true;
        _setTokenURI(tokenId, _buildMetadata(tokenId));

        emit RecordVerified(tokenId, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Retirement (burn-to-claim)
    // -----------------------------------------------------------------------

    /**
     * @notice Retire (permanently burn) a token to claim its offset for ESG
     *         reporting. Prevents double-counting.
     */
    function retire(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId, msg.sender);
        CarbonRecord storage rec = carbonRecords[tokenId];
        if (rec.retired) revert AlreadyRetired(tokenId);

        rec.retired = true;
        _burn(tokenId);

        emit RecordRetired(tokenId, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Role management helpers
    // -----------------------------------------------------------------------

    function grantOracleRole(address account)    external onlyOwner { _grantRole(ORACLE_ROLE,   account); }
    function grantMinterRole(address account)    external onlyOwner { _grantRole(MINTER_ROLE,   account); }
    function grantVerifierRole(address account)  external onlyOwner { _grantRole(VERIFIER_ROLE, account); }
    function revokeOracleRole(address account)   external onlyOwner { _revokeRole(ORACLE_ROLE,   account); }
    function revokeMinterRole(address account)   external onlyOwner { _revokeRole(MINTER_ROLE,   account); }
    function revokeVerifierRole(address account) external onlyOwner { _revokeRole(VERIFIER_ROLE, account); }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function tierOf(uint256 tokenId) public view returns (Tier) {
        return _tierForOffset(carbonRecords[tokenId].offsetKg);
    }

    function totalSupply() public view returns (uint256) {
        return _nextTokenId - 1;
    }

    // -----------------------------------------------------------------------
    // ERC-165 supportsInterface
    // -----------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /**
     * @notice Returns true if the given tokenId has been minted and not yet burned.
     * @dev Used by updateOffset() and verify() to prevent writing to non-existent token records.
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _tierForOffset(uint256 offsetKg) internal pure returns (Tier) {
        if (offsetKg >= DIAMOND_THRESHOLD) return Tier.Diamond;
        if (offsetKg >= GOLD_THRESHOLD)    return Tier.Gold;
        if (offsetKg >= SILVER_THRESHOLD)  return Tier.Silver;
        return Tier.Bronze;
    }

    function _tierName(Tier t) internal pure returns (string memory) {
        if (t == Tier.Diamond) return "Diamond";
        if (t == Tier.Gold)    return "Gold";
        if (t == Tier.Silver)  return "Silver";
        return "Bronze";
    }

    function _tierColor(Tier t) internal pure returns (string memory) {
        if (t == Tier.Diamond) return "#a8f0ff";
        if (t == Tier.Gold)    return "#ffd700";
        if (t == Tier.Silver)  return "#c0c0c0";
        return "#cd7f32"; // bronze
    }

    function _buildMetadata(uint256 tokenId) internal view returns (string memory) {
        CarbonRecord memory rec = carbonRecords[tokenId];
        Tier t = _tierForOffset(rec.offsetKg);
        string memory tierStr = _tierName(t);
        string memory accent  = _tierColor(t);

        string memory svg = _buildSVG(rec, tierStr, accent, tokenId);
        string memory svgB64 = Base64.encode(bytes(svg));

        string memory attributes = string.concat(
            '[{"trait_type":"Tier","value":"',               tierStr,              '"},'
            '{"trait_type":"Offset (kg CO2)","value":',     rec.offsetKg.toString(), '},'
            '{"trait_type":"Vintage Year","value":',        uint256(rec.vintageYear).toString(), '},'
            '{"trait_type":"Readings","value":',            uint256(rec.readingsCount).toString(), '},'
            '{"trait_type":"Verified","value":"',           rec.verified ? "true" : "false", '"},'
            '{"trait_type":"Retired","value":"',            rec.retired  ? "true" : "false", '"}]'
        );

        string memory json = Base64.encode(bytes(string.concat(
            '{"name":"Climate Action #', tokenId.toString(), ' - ', tierStr, '",'
            '"description":"Verifiable carbon-offset certificate backed by WRFCoin weather data contributions.",'
            '"image":"data:image/svg+xml;base64,', svgB64, '",'
            '"attributes":', attributes, '}'
        )));

        return string.concat("data:application/json;base64,", json);
    }

    function _buildSVG(
        CarbonRecord memory rec,
        string memory tierStr,
        string memory accent,
        uint256 tokenId
    ) internal pure returns (string memory) {
        // Simple but expressive on-chain SVG (pattern from WeatherStreakNFT)
        string memory offsetStr = string.concat(rec.offsetKg.toString(), " kg CO2");

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320">',
            '<rect width="320" height="320" fill="#071a10"/>',
            '<circle cx="260" cy="60" r="36" fill="', accent, '" opacity="0.85"/>',
            '<text x="260" y="66" fill="#071a10" font-size="20" text-anchor="middle" font-family="serif">&#9752;</text>',
            '<rect x="20" y="170" width="280" height="100" rx="16" fill="#0b2015" stroke="', accent, '" stroke-width="3"/>',
            '<text x="20" y="44" fill="#e8f5e9" font-size="22" font-family="serif">Climate Action</text>',
            '<text x="20" y="76" fill="', accent, '" font-size="36" font-family="serif">', tierStr, '</text>',
            '<text x="20" y="150" fill="#a5d6a7" font-size="28" font-family="monospace">', offsetStr, '</text>',
            '<text x="28" y="204" fill="#d7ffdc" font-size="14" font-family="monospace">Vintage: ', uint256(rec.vintageYear).toString(), '</text>',
            '<text x="28" y="228" fill="#d7ffdc" font-size="14" font-family="monospace">Readings: ', uint256(rec.readingsCount).toString(), '</text>',
            '<text x="28" y="252" fill="', rec.verified ? "#69f0ae" : "#ef9a9a", '" font-size="14" font-family="monospace">',
            rec.verified ? "Verified [OK]" : "Pending verification", '</text>',
            '<text x="28" y="292" fill="#558b2f" font-size="12" font-family="monospace">wrfcoin.io/climate #', tokenId.toString(), '</text>',
            '</svg>'
        );
    }

}
