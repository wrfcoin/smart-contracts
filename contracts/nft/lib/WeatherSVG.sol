// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

library WeatherSVG {
    using Strings for uint256;

    function generateStreakSVG(
        string memory tier,
        uint256 streakDays,
        address oracleAddress
    ) public pure returns (string memory) {
        string memory accent = _tierColor(tier);
        string memory oracleText = Strings.toHexString(uint160(oracleAddress), 20);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320">',
            '<rect width="320" height="320" fill="#07111f"/>',
            '<circle cx="255" cy="64" r="34" fill="',
            accent,
            '" opacity="0.92"/>',
            '<rect x="24" y="170" width="272" height="96" rx="18" fill="#0f1d33" stroke="',
            accent,
            '" stroke-width="4"/>',
            '<text x="24" y="54" fill="#f6fbff" font-size="26" font-family="serif">Weather Streak</text>',
            '<text x="24" y="100" fill="',
            accent,
            '" font-size="42" font-family="serif">',
            tier,
            "</text>",
            '<text x="24" y="150" fill="#9ec4ff" font-size="64" font-family="monospace">',
            streakDays.toString(),
            "d</text>",
            '<text x="24" y="210" fill="#d7e7ff" font-size="16" font-family="monospace">oracle</text>',
            '<text x="24" y="236" fill="#f6fbff" font-size="13" font-family="monospace">',
            oracleText,
            "</text>",
            '<text x="24" y="286" fill="#9ec4ff" font-size="14" font-family="serif">Consecutive verified submission days</text>',
            "</svg>"
        );
    }

    function generateStormSVG(
        uint8 severity,
        string memory eventType,
        uint256 accuracyScore
    ) public pure returns (string memory) {
        string memory accent = _stormColor(severity);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320">',
            '<rect width="320" height="320" fill="#140b18"/>',
            '<path d="M0 90C54 58 112 34 177 43C240 51 281 88 320 118V0H0Z" fill="',
            accent,
            '" opacity="0.82"/>',
            '<rect x="24" y="176" width="272" height="108" rx="18" fill="#23152a" stroke="',
            accent,
            '" stroke-width="4"/>',
            '<text x="24" y="54" fill="#fff7fb" font-size="26" font-family="serif">Storm Chaser</text>',
            '<text x="24" y="105" fill="',
            accent,
            '" font-size="40" font-family="serif">',
            eventType,
            "</text>",
            '<text x="24" y="152" fill="#f9d4ea" font-size="24" font-family="monospace">Severity ',
            uint256(severity).toString(),
            "</text>",
            '<text x="24" y="226" fill="#fff7fb" font-size="16" font-family="monospace">Accuracy</text>',
            '<text x="24" y="266" fill="#f8badc" font-size="46" font-family="monospace">',
            accuracyScore.toString(),
            "</text>",
            '<text x="104" y="266" fill="#f8badc" font-size="28" font-family="monospace">/100</text>',
            "</svg>"
        );
    }

    function _tierColor(string memory tier) private pure returns (string memory) {
        bytes32 tierHash = keccak256(bytes(tier));
        if (tierHash == keccak256("Diamond")) {
            return "#8be9ff";
        }
        if (tierHash == keccak256("Gold")) {
            return "#ffd166";
        }
        if (tierHash == keccak256("Silver")) {
            return "#d7dde8";
        }
        return "#c07a2c";
    }

    function _stormColor(uint8 severity) private pure returns (string memory) {
        if (severity >= 5) {
            return "#ff4f87";
        }
        if (severity == 4) {
            return "#ff7a59";
        }
        if (severity == 3) {
            return "#ff9f43";
        }
        if (severity == 2) {
            return "#7c67ff";
        }
        return "#53d2dc";
    }
}
