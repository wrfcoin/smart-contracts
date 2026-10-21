// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IStationAdoptionCertificateNFT
 * @notice Minimal minting interface for station adoption certificates.
 */
interface IStationAdoptionCertificateNFT {
    function mintCertificate(
        address sponsor,
        uint256 projectId,
        bytes32 regionId,
        bytes32 stationId,
        uint256 sponsoredAmount,
        uint256 deploymentTimestamp,
        uint256 cumulativeDataRewards
    ) external returns (uint256 tokenId);
}
