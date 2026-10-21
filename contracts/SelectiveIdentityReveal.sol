// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Selective Identity Reveal Contract
 * @dev Opt-in identity reveal for publishing verifiable work under pseudonymous reputation
 * Enables researchers to build reputation while maintaining privacy controls
 */
contract SelectiveIdentityReveal {
    
    struct PseudonymousProfile {
        bytes32 pseudonymId;
        address controllerAddress;
        uint256 reputationScore;
        uint256 totalPublications;
        uint256 verifiedPublications;
        uint256 totalCitations;
        string researchAreas; // Encoded research specializations
        bool isVerified;
        uint256 creationTime;
        mapping(bytes32 => Publication) publications;
        bytes32[] publicationHashes;
    }
    
    struct Publication {
        bytes32 publicationHash;
        bytes32 pseudonymId;
        string title;
        string abstractHash; // IPFS hash
        string fullPaperHash; // IPFS hash (encrypted or public)
        uint256 publishTime;
        uint256 citationCount;
        bool isVerified;
        IdentityRevealLevel revealLevel;
        string verifiedInstitution; // Only if revealed
        string authorName; // Only if fully revealed
    }
    
    struct IdentityReveal {
        bytes32 pseudonymId;
        address revealer;
        IdentityRevealLevel level;
        string encryptedIdentityData; // IPFS hash of encrypted identity
        string institutionVerificationHash; // Verification from institution
        uint256 revealTime;
        bool isPermanent;
        string reason; // Why revealing identity
    }
    
    struct CitationRecord {
        bytes32 citingPaper;
        bytes32 citedPaper;
        bytes32 citingAuthor;
        uint256 citationTime;
        string citationContext; // Brief context of citation
    }
    
    enum IdentityRevealLevel {
        ANONYMOUS,          // Fully anonymous
        INSTITUTIONAL,      // Reveal institution only
        PARTIAL,           // Reveal name and institution
        FULL              // Full public profile
    }
    
    mapping(bytes32 => PseudonymousProfile) public profiles;
    mapping(address => bytes32[]) public userPseudonyms;
    mapping(bytes32 => IdentityReveal) public identityReveals;
    mapping(bytes32 => CitationRecord[]) public citationsByPaper;
    
    bytes32[] public allPseudonyms;
    uint256 public totalPublications;
    uint256 public verifiedInstitutions;
    address public governance;
    address public verificationOracle;
    
    event PseudonymCreated(
        bytes32 indexed pseudonymId,
        address indexed controller,
        string researchAreas
    );
    
    event PublicationSubmitted(
        bytes32 indexed publicationHash,
        bytes32 indexed pseudonymId,
        string title,
        IdentityRevealLevel revealLevel
    );
    
    event IdentityRevealed(
        bytes32 indexed pseudonymId,
        IdentityRevealLevel level,
        string reason
    );
    
    event CitationAdded(
        bytes32 indexed citingPaper,
        bytes32 indexed citedPaper,
        bytes32 indexed citingAuthor
    );
    
    event ReputationUpdated(
        bytes32 indexed pseudonymId,
        uint256 newScore,
        string reason
    );
    
    modifier onlyGovernance() {
        require(msg.sender == governance, "Only governance can execute");
        _;
    }
    
    modifier onlyOracle() {
        require(msg.sender == verificationOracle, "Only oracle can verify");
        _;
    }
    
    modifier onlyPseudonymController(bytes32 pseudonymId) {
        require(profiles[pseudonymId].controllerAddress == msg.sender, "Not pseudonym controller");
        _;
    }
    
    constructor(address _governance, address _verificationOracle) {
        governance = _governance;
        verificationOracle = _verificationOracle;
    }
    
    /**
     * @dev Create new pseudonymous research profile
     */
    function createPseudonym(
        string memory researchAreas,
        bytes32 saltValue
    ) external returns (bytes32) {
        bytes32 pseudonymId = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp,
            saltValue
        ));
        
        require(profiles[pseudonymId].controllerAddress == address(0), "Pseudonym already exists");
        
        PseudonymousProfile storage profile = profiles[pseudonymId];
        profile.pseudonymId = pseudonymId;
        profile.controllerAddress = msg.sender;
        profile.researchAreas = researchAreas;
        profile.creationTime = block.timestamp;
        profile.reputationScore = 1000; // Starting reputation
        
        userPseudonyms[msg.sender].push(pseudonymId);
        allPseudonyms.push(pseudonymId);
        
        emit PseudonymCreated(pseudonymId, msg.sender, researchAreas);
        
        return pseudonymId;
    }
    
    /**
     * @dev Submit publication under pseudonym
     */
    function submitPublication(
        bytes32 pseudonymId,
        string memory title,
        string memory abstractHash,
        string memory fullPaperHash,
        IdentityRevealLevel revealLevel
    ) external onlyPseudonymController(pseudonymId) {
        bytes32 publicationHash = keccak256(abi.encodePacked(
            pseudonymId,
            title,
            abstractHash,
            block.timestamp
        ));
        
        PseudonymousProfile storage profile = profiles[pseudonymId];
        Publication storage publication = profile.publications[publicationHash];
        
        publication.publicationHash = publicationHash;
        publication.pseudonymId = pseudonymId;
        publication.title = title;
        publication.abstractHash = abstractHash;
        publication.fullPaperHash = fullPaperHash;
        publication.publishTime = block.timestamp;
        publication.revealLevel = revealLevel;
        
        profile.publicationHashes.push(publicationHash);
        profile.totalPublications++;
        totalPublications++;
        
        // Reputation boost for publishing
        _updateReputation(pseudonymId, 50, "Publication submitted");
        
        emit PublicationSubmitted(publicationHash, pseudonymId, title, revealLevel);
    }
    
    /**
     * @dev Reveal identity at specified level
     */
    function revealIdentity(
        bytes32 pseudonymId,
        IdentityRevealLevel level,
        string memory encryptedIdentityData,
        string memory institutionVerificationHash,
        string memory reason,
        bool isPermanent
    ) public onlyPseudonymController(pseudonymId) {
        require(level != IdentityRevealLevel.ANONYMOUS, "Cannot reveal as anonymous");
        
        IdentityReveal storage reveal = identityReveals[pseudonymId];
        
        // Can only increase reveal level, not decrease (unless temporary)
        if (reveal.revealer != address(0) && reveal.isPermanent) {
            require(uint8(level) >= uint8(reveal.level), "Cannot decrease permanent reveal level");
        }
        
        reveal.pseudonymId = pseudonymId;
        reveal.revealer = msg.sender;
        reveal.level = level;
        reveal.encryptedIdentityData = encryptedIdentityData;
        reveal.institutionVerificationHash = institutionVerificationHash;
        reveal.revealTime = block.timestamp;
        reveal.isPermanent = isPermanent;
        reveal.reason = reason;
        
        // Reputation boost for identity verification
        uint256 reputationBoost = 0;
        if (level == IdentityRevealLevel.INSTITUTIONAL) reputationBoost = 100;
        else if (level == IdentityRevealLevel.PARTIAL) reputationBoost = 200;
        else if (level == IdentityRevealLevel.FULL) reputationBoost = 300;
        
        _updateReputation(pseudonymId, int256(reputationBoost), "Identity revealed");
        
        emit IdentityRevealed(pseudonymId, level, reason);
    }
    
    /**
     * @dev Add citation between papers
     */
    function addCitation(
        bytes32 citingPaper,
        bytes32 citedPaper,
        string memory citationContext
    ) external {
        // Verify the citing paper belongs to the sender's pseudonyms
        bool canCite = false;
        bytes32[] memory userPseudos = userPseudonyms[msg.sender];
        
        for (uint256 i = 0; i < userPseudos.length; i++) {
            PseudonymousProfile storage profile = profiles[userPseudos[i]];
            if (profile.publications[citingPaper].pseudonymId == userPseudos[i]) {
                canCite = true;
                break;
            }
        }
        
        require(canCite, "Can only cite from your own publications");
        
        // Find the cited paper's pseudonym and update citation count
        bytes32 citedPseudonym = bytes32(0);
        for (uint256 i = 0; i < allPseudonyms.length; i++) {
            if (profiles[allPseudonyms[i]].publications[citedPaper].pseudonymId != bytes32(0)) {
                citedPseudonym = allPseudonyms[i];
                break;
            }
        }
        
        require(citedPseudonym != bytes32(0), "Cited paper not found");
        
        // Record citation
        CitationRecord memory citation = CitationRecord({
            citingPaper: citingPaper,
            citedPaper: citedPaper,
            citingAuthor: profiles[citedPseudonym].pseudonymId,
            citationTime: block.timestamp,
            citationContext: citationContext
        });
        
        citationsByPaper[citedPaper].push(citation);
        
        // Update citation counts and reputation
        profiles[citedPseudonym].publications[citedPaper].citationCount++;
        profiles[citedPseudonym].totalCitations++;
        
        _updateReputation(citedPseudonym, 25, "Paper cited");
        
        emit CitationAdded(citingPaper, citedPaper, citedPseudonym);
    }
    
    /**
     * @dev Verify publication and update reputation
     */
    function verifyPublication(
        bytes32 publicationHash,
        bool isValid,
        string memory verificationNotes
    ) external onlyOracle {
        // Find the publication's pseudonym
        bytes32 pseudonymId = bytes32(0);
        for (uint256 i = 0; i < allPseudonyms.length; i++) {
            if (profiles[allPseudonyms[i]].publications[publicationHash].pseudonymId == allPseudonyms[i]) {
                pseudonymId = allPseudonyms[i];
                break;
            }
        }
        
        require(pseudonymId != bytes32(0), "Publication not found");
        
        PseudonymousProfile storage profile = profiles[pseudonymId];
        Publication storage publication = profile.publications[publicationHash];
        
        publication.isVerified = isValid;
        
        if (isValid) {
            profile.verifiedPublications++;
            _updateReputation(pseudonymId, 100, "Publication verified");
        } else {
            _updateReputation(pseudonymId, -50, "Publication rejected");
        }
    }
    
    /**
     * @dev Update institutional verification
     */
    function updateInstitutionalVerification(
        bytes32 pseudonymId,
        string memory institutionName,
        string memory verificationHash
    ) external onlyOracle {
        PseudonymousProfile storage profile = profiles[pseudonymId];
        profile.isVerified = true;
        
        // Update any revealed publications with institution info
        IdentityReveal storage reveal = identityReveals[pseudonymId];
        if (reveal.level >= IdentityRevealLevel.INSTITUTIONAL) {
            for (uint256 i = 0; i < profile.publicationHashes.length; i++) {
                bytes32 pubHash = profile.publicationHashes[i];
                profile.publications[pubHash].verifiedInstitution = institutionName;
            }
        }
        
        verifiedInstitutions++;
        _updateReputation(pseudonymId, 150, "Institution verified");
    }
    
    /**
     * @dev Internal reputation update function
     */
    function _updateReputation(
        bytes32 pseudonymId,
        int256 change,
        string memory reason
    ) internal {
        PseudonymousProfile storage profile = profiles[pseudonymId];
        
        if (change > 0) {
            profile.reputationScore += uint256(change);
        } else if (change < 0 && profile.reputationScore > uint256(-change)) {
            profile.reputationScore -= uint256(-change);
        } else if (change < 0) {
            profile.reputationScore = 0;
        }
        
        emit ReputationUpdated(pseudonymId, profile.reputationScore, reason);
    }
    
    /**
     * @dev Get user's pseudonyms
     */
    function getUserPseudonyms(address user) external view returns (bytes32[] memory) {
        return userPseudonyms[user];
    }
    
    /**
     * @dev Get pseudonym's publications
     */
    function getPseudonymPublications(bytes32 pseudonymId) external view returns (bytes32[] memory) {
        return profiles[pseudonymId].publicationHashes;
    }
    
    /**
     * @dev Get paper citations
     */
    function getPaperCitations(bytes32 paperHash) external view returns (CitationRecord[] memory) {
        return citationsByPaper[paperHash];
    }
    
    /**
     * @dev Get publication with respect to reveal level
     */
    function getPublicationInfo(bytes32 publicationHash) external view returns (
        string memory title,
        string memory abstractHash,
        uint256 publishTime,
        uint256 citationCount,
        bool isVerified,
        IdentityRevealLevel revealLevel,
        string memory verifiedInstitution,
        string memory authorName
    ) {
        // Find the publication
        for (uint256 i = 0; i < allPseudonyms.length; i++) {
            if (profiles[allPseudonyms[i]].publications[publicationHash].pseudonymId == allPseudonyms[i]) {
                Publication storage publication = profiles[allPseudonyms[i]].publications[publicationHash];
                return (
                    publication.title,
                    publication.abstractHash,
                    publication.publishTime,
                    publication.citationCount,
                    publication.isVerified,
                    publication.revealLevel,
                    publication.verifiedInstitution,
                    publication.authorName
                );
            }
        }

        revert("Publication not found");
    }
    
    /**
     * @dev Calculate research impact score
     */
    function calculateImpactScore(bytes32 pseudonymId) external view returns (uint256) {
        PseudonymousProfile storage profile = profiles[pseudonymId];
        
        uint256 baseScore = profile.reputationScore;
        uint256 publicationScore = profile.totalPublications * 10;
        uint256 verificationBonus = profile.verifiedPublications * 25;
        uint256 citationScore = profile.totalCitations * 15;
        
        // Verification multiplier
        uint256 multiplier = profile.isVerified ? 120 : 100;
        
        return ((baseScore + publicationScore + verificationBonus + citationScore) * multiplier) / 100;
    }
    
    /**
     * @dev Temporary identity reveal (expires after duration)
     */
    function temporaryReveal(
        bytes32 pseudonymId,
        IdentityRevealLevel level,
        uint256 duration,
        string memory reason
    ) external onlyPseudonymController(pseudonymId) {
        require(duration <= 30 days, "Max 30 days for temporary reveal");
        
        revealIdentity(pseudonymId, level, "", "", reason, false);
        
        // Could implement automatic reversion here with a scheduler
    }
    
    /**
     * @dev Update contract parameters
     */
    function updateParameters(address _verificationOracle) external onlyGovernance {
        verificationOracle = _verificationOracle;
    }
}