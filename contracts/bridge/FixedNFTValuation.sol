// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/INFTValuation.sol";

/**
 * @title FixedNFTValuation
 * @notice Simple NFT valuation that returns a fixed floor price per collection.
 * @dev Admin-configurable. Reverts for collections without a configured floor value.
 */
contract FixedNFTValuation is INFTValuation, AccessControl {
    bytes32 public constant VALUATION_ADMIN_ROLE = keccak256("VALUATION_ADMIN_ROLE");

    mapping(address => uint256) public collectionFloorValues;

    event CollectionFloorValueSet(address indexed collection, uint256 floorValue);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VALUATION_ADMIN_ROLE, admin);
    }

    function setCollectionFloorValue(
        address collection,
        uint256 floorValue
    ) external onlyRole(VALUATION_ADMIN_ROLE) {
        require(collection != address(0), "FixedNFTValuation: zero address");
        collectionFloorValues[collection] = floorValue;
        emit CollectionFloorValueSet(collection, floorValue);
    }

    function getNFTValue(
        address collection,
        uint256 /* tokenId */
    ) external view override returns (uint256) {
        uint256 floor = collectionFloorValues[collection];
        require(floor > 0, "FixedNFTValuation: collection not configured");
        return floor;
    }
}
