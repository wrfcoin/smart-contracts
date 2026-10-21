// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SimpleMockEnhancedCarbonCredits
 * @author WRFCoin Team
 * @notice Minimal mock carbon credit contract for testing
 * @dev Simplified version to avoid stack depth compilation issues
 */
contract SimpleMockEnhancedCarbonCredits is ERC1155, AccessControl {
    
    bytes32 public constant AUTHORIZED_ISSUER_ROLE = keccak256("AUTHORIZED_ISSUER_ROLE");
    bytes32 public constant REGISTRY_CONNECTOR_ROLE = keccak256("REGISTRY_CONNECTOR_ROLE");
    
    // Simplified carbon credit batch structure
    struct CarbonCreditBatch {
        uint256 totalSupply;
        uint256 circulatingSupply;
        string projectId;
        uint256 vintage;
        string projectType;
        uint256 qualityScore;
        uint256 creationTime;
        bool isActive;
        string location;
        address certifyingBody;
    }
    
    mapping(uint256 => CarbonCreditBatch) public batches;
    mapping(string => uint256) public projectIdToTokenId;
    mapping(address => mapping(uint256 => uint256)) public retiredBalances;
    
    uint256 private _currentTokenId = 1;
    
    event CreditCreated(uint256 indexed tokenId, string projectId, uint256 totalSupply);
    event CreditsRetired(address indexed account, uint256 indexed tokenId, uint256 amount, string reason);
    
    constructor() ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUTHORIZED_ISSUER_ROLE, msg.sender);
        _grantRole(REGISTRY_CONNECTOR_ROLE, msg.sender);
    }
    
    function createBatch(
        uint256 totalSupply,
        string memory projectId,
        uint256 vintage,
        string memory location
    ) external onlyRole(AUTHORIZED_ISSUER_ROLE) returns (uint256) {
        require(totalSupply > 0, "SMEC: Invalid supply amount");
        require(bytes(projectId).length > 0, "SMEC: Empty project ID");
        
        uint256 tokenId = _currentTokenId++;
        
        batches[tokenId] = CarbonCreditBatch({
            totalSupply: totalSupply,
            circulatingSupply: totalSupply,
            projectId: projectId,
            vintage: vintage,
            projectType: "generic",
            qualityScore: 500,
            creationTime: block.timestamp,
            isActive: true,
            location: location,
            certifyingBody: msg.sender
        });
        
        projectIdToTokenId[projectId] = tokenId;
        
        emit CreditCreated(tokenId, projectId, totalSupply);
        
        return tokenId;
    }
    
    function immobilizeCredits(
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external onlyRole(REGISTRY_CONNECTOR_ROLE) {
        require(batches[tokenId].isActive, "Credit not active");
        _mint(recipient, tokenId, amount, "");
    }
    
    function retireCredits(
        uint256 tokenId,
        uint256 amount,
        string memory reason
    ) external {
        require(balanceOf(msg.sender, tokenId) >= amount, "Insufficient balance");
        
        _burn(msg.sender, tokenId, amount);
        retiredBalances[msg.sender][tokenId] += amount;
        
        emit CreditsRetired(msg.sender, tokenId, amount, reason);
    }
    
    function getUserRetirementStats(
        address account
    ) external view returns (uint256 totalRetired, uint256 uniqueProjects) {
        totalRetired = retiredBalances[account][1];
        uniqueProjects = totalRetired > 0 ? 1 : 0;
    }
    
    function getBatchInfo(uint256 tokenId) external view returns (CarbonCreditBatch memory) {
        return batches[tokenId];
    }
    
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}