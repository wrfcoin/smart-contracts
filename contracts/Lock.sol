// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./interfaces/IQualityOracle.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title VerificationOracle
 * @dev Oracle contract for carbon credit project verification status
 */
contract VerificationOracle is IVerificationOracle, AccessControl, ReentrancyGuard, Pausable {
    
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant VERIFIER_ADMIN_ROLE = keccak256("VERIFIER_ADMIN_ROLE");
    bytes32 public constant DOCUMENT_ADMIN_ROLE = keccak256("DOCUMENT_ADMIN_ROLE");
    
    // State variables
    mapping(bytes32 => VerificationData) public verificationData;
    mapping(bytes32 => VerificationData[]) public verificationHistory;
    mapping(bytes32 => string) public verifierNames;
    mapping(bytes32 => VerificationStandard) public verifierStandards;
    mapping(bytes32 => bool) public authorizedVerifiers;
    mapping(bytes32 => bytes32[]) public projectDocuments;
    mapping(bytes32 => mapping(bytes32 => bool)) public documentExists;
    mapping(bytes32 => mapping(bytes32 => string)) public documentTypes;
    
    // Verification tracking
    mapping(bytes32 => uint256) public lastVerificationUpdate;
    mapping(bytes32 => uint256) public verificationCount;
    mapping(VerificationStandard => uint256) public standardCount;
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(DOCUMENT_ADMIN_ROLE, msg.sender);
    }
    
    modifier validProjectId(bytes32 projectId) {
        require(projectId != bytes32(0), "Invalid project ID");
        _;
    }
    
    modifier validVerifierId(bytes32 verifierId) {
        require(verifierId != bytes32(0), "Invalid verifier ID");
        _;
    }
    
    modifier authorizedVerifier(bytes32 verifierId) {
        require(authorizedVerifiers[verifierId], "Verifier not authorized");
        _;
    }
    
    /**
     * @dev Update verification status for a project
     */
    function updateVerificationStatus(bytes32 projectId, VerificationData calldata data) 
        external 
        onlyRole(VERIFIER_ROLE) 
        validProjectId(projectId)
        authorizedVerifier(data.verifierId)
        whenNotPaused
        nonReentrant
    {
        require(data.projectId == projectId, "Project ID mismatch");
        require(data.verificationDate <= block.timestamp, "Future verification date not allowed");
        require(data.expiryDate > data.verificationDate, "Expiry date must be after verification date");
        require(data.creditAmount > 0, "Credit amount must be positive");
        require(data.confidence >= 50 && data.confidence <= 100, "Invalid confidence level");
        
        // Store current verification data
        verificationData[projectId] = data;
        lastVerificationUpdate[projectId] = block.timestamp;
        
        // Add to history
        verificationHistory[projectId].push(data);
        
        // Update counters
        verificationCount[projectId]++;
        standardCount[data.standard]++;
        
        emit VerificationUpdated(projectId, data.status, block.timestamp);
    }
    
    /**
     * @dev Get verification status for a project
     */
    function getVerificationStatus(bytes32 projectId) 
        external 
        view 
        validProjectId(projectId)
        returns (VerificationStatus) 
    {
        return verificationData[projectId].status;
    }
    
    /**
     * @dev Get verification data for a project
     */
    function getVerificationData(bytes32 projectId) 
        external 
        view 
        validProjectId(projectId)
        returns (VerificationData memory) 
    {
        return verificationData[projectId];
    }
    
    /**
     * @dev Check if project is verified
     */
    function isProjectVerified(bytes32 projectId) 
        external 
        view 
        validProjectId(projectId)
        returns (bool) 
    {
        VerificationData memory data = verificationData[projectId];
        return data.status == VerificationStatus.VERIFIED;
    }
    
    /**
     * @dev Check if verification is valid (not expired)
     */
    function isVerificationValid(bytes32 projectId) 
        external 
        view 
        validProjectId(projectId)
        returns (bool) 
    {
        VerificationData memory data = verificationData[projectId];
        
        // Check if verified and not expired
        if (data.status != VerificationStatus.VERIFIED) {
            return false;
        }
        
        // Check expiry date
        if (data.expiryDate > 0 && block.timestamp > data.expiryDate) {
            return false;
        }
        
        return true;
    }
    
    /**
     * @dev Add authorized verifier
     */
    function addVerifier(bytes32 verifierId, string calldata name, VerificationStandard standard) 
        external 
        onlyRole(VERIFIER_ADMIN_ROLE) 
        validVerifierId(verifierId)
    {
        require(!authorizedVerifiers[verifierId], "Verifier already exists");
        require(bytes(name).length > 0, "Verifier name cannot be empty");
        
        authorizedVerifiers[verifierId] = true;
        verifierNames[verifierId] = name;
        verifierStandards[verifierId] = standard;
        
        emit VerifierAdded(verifierId, name);
    }
    
    /**
     * @dev Remove authorized verifier
     */
    function removeVerifier(bytes32 verifierId) 
        external 
        onlyRole(VERIFIER_ADMIN_ROLE) 
        validVerifierId(verifierId)
        authorizedVerifier(verifierId)
    {
        authorizedVerifiers[verifierId] = false;
        delete verifierNames[verifierId];
        delete verifierStandards[verifierId];
        
        emit VerifierRemoved(verifierId);
    }
    
    /**
     * @dev Check if verifier is authorized
     */
    function isVerifierAuthorized(bytes32 verifierId) 
        external 
        view 
        validVerifierId(verifierId)
        returns (bool) 
    {
        return authorizedVerifiers[verifierId];
    }
    
    /**
     * @dev Get verifier information
     */
    function getVerifierInfo(bytes32 verifierId) 
        external 
        view 
        validVerifierId(verifierId)
        authorizedVerifier(verifierId)
        returns (string memory name, VerificationStandard standard) 
    {
        return (verifierNames[verifierId], verifierStandards[verifierId]);
    }
    
    /**
     * @dev Upload document for a project
     */
    function uploadDocument(bytes32 projectId, bytes32 documentHash, string calldata documentType) 
        external 
        onlyRole(DOCUMENT_ADMIN_ROLE) 
        validProjectId(projectId)
        whenNotPaused
    {
        require(documentHash != bytes32(0), "Invalid document hash");
        require(bytes(documentType).length > 0, "Document type cannot be empty");
        require(!documentExists[projectId][documentHash], "Document already exists");
        
        // Add document to project
        projectDocuments[projectId].push(documentHash);
        documentExists[projectId][documentHash] = true;
        documentTypes[projectId][documentHash] = documentType;
        
        emit DocumentUploaded(projectId, documentHash);
    }
    
    /**
     * @dev Verify if document exists for project
     */
    function verifyDocument(bytes32 projectId, bytes32 documentHash) 
        external 
        view 
        validProjectId(projectId)
        returns (bool) 
    {
        return documentExists[projectId][documentHash];
    }
    
    /**
     * @dev Get all documents for a project
     */
    function getProjectDocuments(bytes32 projectId) 
        external 
        view 
        validProjectId(projectId)
        returns (bytes32[] memory) 
    {
        return projectDocuments[projectId];
    }
    
    /**
     * @dev Batch update verification for multiple projects
     */
    function batchUpdateVerification(bytes32[] calldata projectIds, VerificationData[] calldata data) 
        external 
        onlyRole(VERIFIER_ROLE) 
        whenNotPaused
    {
        require(projectIds.length == data.length, "Array length mismatch");
        require(projectIds.length <= 50, "Too many projects");
        
        for (uint256 i = 0; i < projectIds.length; i++) {
            if (projectIds[i] != bytes32(0) && 
                authorizedVerifiers[data[i].verifierId] &&
                data[i].projectId == projectIds[i]) {
                
                verificationData[projectIds[i]] = data[i];
                verificationHistory[projectIds[i]].push(data[i]);
                lastVerificationUpdate[projectIds[i]] = block.timestamp;
                verificationCount[projectIds[i]]++;
                standardCount[data[i].standard]++;
                
                emit VerificationUpdated(projectIds[i], data[i].status, block.timestamp);
            }
        }
    }
    
    /**
     * @dev Get verification history for a project
     */
    function getVerificationHistory(bytes32 projectId, uint256 fromTimestamp, uint256 toTimestamp) 
        external 
        view 
        validProjectId(projectId)
        returns (VerificationData[] memory) 
    {
        VerificationData[] storage history = verificationHistory[projectId];
        VerificationData[] memory filteredHistory = new VerificationData[](history.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < history.length; i++) {
            if (history[i].verificationDate >= fromTimestamp && 
                history[i].verificationDate <= toTimestamp) {
                filteredHistory[count] = history[i];
                count++;
            }
        }
        
        // Resize array to actual count
        VerificationData[] memory result = new VerificationData[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = filteredHistory[i];
        }
        
        return result;
    }
    
    /**
     * @dev Get verification statistics
     */
    function getVerificationStats() 
        external 
        view 
        returns (
            uint256 totalVCSVerifications,
            uint256 totalGoldStandardVerifications,
            uint256 totalCDMVerifications,
            uint256 totalCARVerifications,
            uint256 totalACRVerifications,
            uint256 totalCustomVerifications
        ) 
    {
        return (
            standardCount[VerificationStandard.VCS],
            standardCount[VerificationStandard.GOLD_STANDARD],
            standardCount[VerificationStandard.CDM],
            standardCount[VerificationStandard.CAR],
            standardCount[VerificationStandard.ACR],
            standardCount[VerificationStandard.CUSTOM]
        );
    }
    
    /**
     * @dev Bulk verify multiple projects (admin function)
     */
    function bulkVerifyProjects(
        bytes32[] calldata projectIds, 
        bytes32 verifierId, 
        VerificationStandard standard,
        uint256 expiryDate
    ) 
        external 
        onlyRole(VERIFIER_ADMIN_ROLE) 
        authorizedVerifier(verifierId)
        whenNotPaused
    {
        require(projectIds.length <= 100, "Too many projects");
        require(expiryDate > block.timestamp, "Expiry date must be in the future");
        
        for (uint256 i = 0; i < projectIds.length; i++) {
            if (projectIds[i] != bytes32(0)) {
                VerificationData memory data = VerificationData({
                    status: VerificationStatus.VERIFIED,
                    standard: standard,
                    projectId: projectIds[i],
                    verifierId: verifierId,
                    verificationDate: block.timestamp,
                    expiryDate: expiryDate,
                    creditAmount: 1000, // Default amount, can be adjusted
                    documentHash: bytes32(0),
                    confidence: 95,
                    metadata: "Bulk verification"
                });
                
                verificationData[projectIds[i]] = data;
                verificationHistory[projectIds[i]].push(data);
                lastVerificationUpdate[projectIds[i]] = block.timestamp;
                verificationCount[projectIds[i]]++;
                standardCount[standard]++;
                
                emit VerificationUpdated(projectIds[i], VerificationStatus.VERIFIED, block.timestamp);
            }
        }
    }
    
    /**
     * @dev Emergency expire verification (in case of fraud detection)
     */
    function emergencyExpireVerification(bytes32 projectId, string calldata reason) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        validProjectId(projectId)
    {
        VerificationData storage data = verificationData[projectId];
        data.status = VerificationStatus.REVOKED;
        data.metadata = string(abi.encodePacked(data.metadata, " | EMERGENCY REVOKED: ", reason));
        
        emit VerificationUpdated(projectId, VerificationStatus.REVOKED, block.timestamp);
    }
    
    /**
     * @dev Emergency pause
     */
    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
