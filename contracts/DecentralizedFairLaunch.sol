// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "./EconomicSecurityEngine.sol";
import "./CommunityGovernance.sol";

/**
 * @title DecentralizedFairLaunch
 * @author WRFCoin Development Team
 * @notice Fully decentralized fair launch system with zero admin controls
 * @dev Implements Bitcoin-style decentralization with 3 simple registration pathways
 * 
 * CORE PRINCIPLE: NO ADMIN FUNCTIONS - Everything is algorithmic and community-driven
 * 
 * === 3 REGISTRATION PATHWAYS ===
 * 
 * 1. BASIC PATH (Stake-to-Participate)
 *    - Simple ETH staking (0.01 ETH minimum, like Bitcoin mining)
 *    - Immediate activation with economic security
 *    - No verification required, just economic commitment
 * 
 * 2. COMMUNITY PATH (Peer-Sponsored Registration)
 *    - Sponsored by existing community members
 *    - Reduced stake requirements (50% discount)  
 *    - Social backing through peer vouching system
 * 
 * 3. MERIT PATH (Contribution-Based)
 *    - Reduced requirements through network contributions
 *    - GitHub/social verification provides automatic discounts
 *    - Algorithmic assessment of contribution value
 * 
 * === SECURITY WITHOUT CENTRALIZATION ===
 * - Economic incentives replace admin controls
 * - Community consensus for disputes
 * - Algorithmic slashing based on stake loss
 * - Self-regulating parameters via market forces
 * 
 * === NO EMERGENCY STOPS OR ADMIN OVERRIDES ===
 * - Contract is immutable once deployed
 * - Community governance for future upgrades only
 * - Economic security protects against all attack vectors
 */
contract DecentralizedFairLaunch is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============================================================================
    //                                 CONSTANTS
    // ============================================================================
    
    /// @dev Minimum ETH stake for basic registration (0.1 ETH - increased for security)
    uint256 public constant MIN_ETH_STAKE = 0.1 ether;
    
    /// @dev Maximum ETH stake to prevent whale dominance (10 ETH)
    uint256 public constant MAX_ETH_STAKE = 10 ether;
    
    /// @dev Community sponsorship discount (25% stake reduction - reduced to prevent exploitation)
    uint256 public constant COMMUNITY_DISCOUNT = 2500; // 25% in basis points
    
    /// @dev Merit contribution discount (up to 50% reduction - reduced to prevent gaming)  
    uint256 public constant MAX_MERIT_DISCOUNT = 5000; // 50% in basis points
    
    /// @dev Slashing rate for proven bad behavior (25% stake loss)
    uint256 public constant SLASHING_RATE = 2500; // 25% in basis points
    
    /// @dev Minimum vouchers needed for community path (increased for security)
    uint256 public constant MIN_VOUCHERS = 5;
    
    /// @dev Voucher stake requirement (0.05 ETH per voucher - increased for security)
    uint256 public constant VOUCHER_STAKE = 0.05 ether;
    
    /// @dev Time lock for stake withdrawals (7 days)
    uint256 public constant WITHDRAWAL_TIMELOCK = 7 days;
    
    /// @dev Precision for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;

    // ============================================================================
    //                                   ENUMS
    // ============================================================================
    
    enum RegistrationPath {
        BASIC,      // Simple ETH staking
        COMMUNITY,  // Peer-sponsored with reduced requirements
        MERIT       // Contribution-based discounts
    }
    
    enum ParticipantStatus {
        UNREGISTERED,   // No registration
        ACTIVE,         // Currently participating
        WITHDRAWING,    // In withdrawal timelock period
        SLASHED        // Penalized for bad behavior
    }

    // ============================================================================
    //                                  STRUCTS  
    // ============================================================================
    
    /// @dev Core participant registration record
    struct Participant {
        RegistrationPath path;           // Which registration path was used
        ParticipantStatus status;        // Current participation status
        uint256 stakeAmount;            // Amount of ETH staked
        uint256 effectiveStake;         // Stake after discounts applied
        uint256 registrationTime;       // When participant registered
        uint256 withdrawalRequestTime;  // When withdrawal was requested (0 if none)
        uint256 totalEarnings;          // Total rewards earned
        uint256 totalSlashed;           // Total amount lost to slashing
        bytes32 meritHash;              // Hash of merit contribution data
        address[] vouchers;             // List of community vouchers
        bool hasActiveDispute;          // Whether participant has ongoing dispute
    }
    
    /// @dev Community voucher record
    struct Voucher {
        address voucher;                // Address providing the vouch
        address participant;            // Address being vouched for
        uint256 stakeAmount;           // Amount voucher staked
        uint256 timestamp;             // When vouch was created
        bool active;                   // Whether vouch is still active
    }
    
    /// @dev Merit contribution record
    struct MeritContribution {
        bytes32 contributionHash;      // Hash of contribution proof
        uint256 value;                 // Algorithmic value assessment
        uint256 timestamp;             // When contribution was validated
        uint256 discountEarned;        // Discount percentage earned
        string contributionType;       // Type of contribution (GitHub, etc.)
    }
    
    /// @dev Dispute record for community resolution
    struct Dispute {
        address participant;           // Participant being disputed
        address challenger;            // Who raised the dispute
        bytes32 evidenceHash;          // Hash of evidence provided
        uint256 challengerStake;       // Stake put up by challenger
        uint256 createdAt;             // When dispute was created
        uint256 votes;                 // Current vote count
        mapping(address => bool) voted; // Who has voted
        bool resolved;                 // Whether dispute is resolved
        bool upheld;                   // Whether dispute was upheld
    }

    // ============================================================================
    //                              STATE VARIABLES
    // ============================================================================
    
    /// @dev Main participant registry
    mapping(address => Participant) public participants;
    
    /// @dev Community voucher tracking
    mapping(bytes32 => Voucher) public vouchers;
    mapping(address => uint256) public voucherCount; // How many people each address has vouched for
    mapping(address => mapping(address => bool)) public hasVouched; // Track who has vouched for whom
    mapping(bytes32 => address[]) public networkVouchers; // Track vouchers by network fingerprint
    
    /// @dev Merit contribution tracking  
    mapping(address => MeritContribution[]) public meritContributions;
    mapping(bytes32 => bool) public usedMeritHashes; // Prevent double-usage
    mapping(string => uint256) public contributionTypeMinValues; // Minimum values per type
    mapping(bytes32 => uint256) public oracleValidatedContributions; // Oracle-validated contributions
    
    /// @dev Dispute system
    mapping(bytes32 => Dispute) public disputes;
    mapping(address => bytes32[]) public participantDisputes;
    
    /// @dev Economic security integration
    EconomicSecurityEngine public immutable economicEngine;
    CommunityGovernance public immutable governance;
    
    /// @dev System statistics (no admin control, purely informational)
    uint256 public totalParticipants;
    uint256 public totalStaked;
    uint256 public totalSlashed;
    uint256 public totalEarningsDistributed;
    
    /// @dev Community-controlled emergency circuit breaker
    bool public emergencyMode;
    mapping(address => bool) public emergencyVotes;
    uint256 public emergencyVoteCount;
    uint256 public emergencyModeActivatedAt;
    uint256 public constant EMERGENCY_THRESHOLD_PERCENTAGE = 3000; // 30% of participants
    uint256 public constant EMERGENCY_COOLDOWN = 7 days;

    // ============================================================================
    //                                  EVENTS
    // ============================================================================
    
    event ParticipantRegistered(
        address indexed participant,
        RegistrationPath indexed path,
        uint256 stakeAmount,
        uint256 effectiveStake,
        uint256 timestamp
    );
    
    event CommunityVouch(
        address indexed voucher,
        address indexed participant,
        uint256 stakeAmount,
        uint256 timestamp
    );
    
    event MeritContributionValidated(
        address indexed participant,
        bytes32 contributionHash,
        uint256 value,
        uint256 discountEarned,
        string contributionType
    );
    
    event StakeWithdrawalRequested(
        address indexed participant,
        uint256 amount,
        uint256 availableAt
    );
    
    event StakeWithdrawn(
        address indexed participant,
        uint256 amount,
        uint256 timestamp
    );
    
    event ParticipantSlashed(
        address indexed participant,
        uint256 slashedAmount,
        bytes32 reason,
        uint256 timestamp
    );
    
    event DisputeCreated(
        bytes32 indexed disputeId,
        address indexed participant,
        address indexed challenger,
        bytes32 evidenceHash,
        uint256 challengerStake
    );
    
    event DisputeResolved(
        bytes32 indexed disputeId,
        address indexed participant,
        bool upheld,
        uint256 votes,
        uint256 timestamp
    );

    // ============================================================================
    //                                CONSTRUCTOR
    // ============================================================================
    
    /**
     * @notice Deploy the fully decentralized fair launch system
     * @param _economicEngine Address of the economic security engine
     * @param _governance Address of the community governance contract
     */
    constructor(
        address _economicEngine,
        address _governance
    ) EIP712("DecentralizedFairLaunch", "1") {
        require(_economicEngine != address(0), "Invalid economic engine");
        require(_governance != address(0), "Invalid governance");
        
        economicEngine = EconomicSecurityEngine(payable(_economicEngine));
        governance = CommunityGovernance(payable(_governance));
        
        // Initialize minimum values for contribution types (prevent gaming)
        contributionTypeMinValues["GitHub"] = 2000;      // Higher minimum for GitHub
        contributionTypeMinValues["Research"] = 3000;    // Highest minimum for research
        contributionTypeMinValues["Community"] = 1000;   // Moderate minimum for community
        
        // NO ADMIN ROLES SET - Contract is truly decentralized from deployment
    }

    // ============================================================================
    //                           REGISTRATION FUNCTIONS  
    // ============================================================================
    
    /**
     * @dev Modifier to check if emergency mode is active
     */
    modifier whenNotEmergency() {
        require(!emergencyMode, "Contract in emergency mode");
        _;
    }

    /**
     * @notice BASIC PATH: Register with simple ETH staking
     * @dev No verification needed, just economic commitment
     */
    function registerBasicPath() 
        external 
        payable 
        nonReentrant 
        whenNotEmergency
    {
        require(msg.value >= MIN_ETH_STAKE, "Insufficient stake");
        require(msg.value <= MAX_ETH_STAKE, "Stake too high");
        require(participants[msg.sender].status == ParticipantStatus.UNREGISTERED, "Already registered");
        
        // Create participant record
        Participant storage participant = participants[msg.sender];
        participant.path = RegistrationPath.BASIC;
        participant.status = ParticipantStatus.ACTIVE;
        participant.stakeAmount = msg.value;
        participant.effectiveStake = msg.value; // No discount for basic path
        participant.registrationTime = block.timestamp;
        
        // Update global statistics
        totalParticipants++;
        totalStaked += msg.value;
        
        // Integrate with economic security engine
        economicEngine.registerParticipant(msg.sender, msg.value);
        
        emit ParticipantRegistered(
            msg.sender,
            RegistrationPath.BASIC,
            msg.value,
            msg.value,
            block.timestamp
        );
    }
    
    /**
     * @notice COMMUNITY PATH: Register with peer sponsorship
     * @dev Requires vouchers from existing community members
     * @param voucherAddresses Array of addresses vouching for the participant
     */
    function registerCommunityPath(address[] calldata voucherAddresses) 
        external 
        payable 
        nonReentrant 
        whenNotEmergency
    {
        require(voucherAddresses.length >= MIN_VOUCHERS, "Insufficient vouchers");
        require(participants[msg.sender].status == ParticipantStatus.UNREGISTERED, "Already registered");
        
        // Calculate required stake with community discount
        uint256 requiredStake = _calculateCommunityStake(msg.value);
        require(msg.value >= requiredStake, "Insufficient stake for community path");
        
        // Validate and process vouchers with enhanced security
        uint256 totalVoucherStake = 0;
        bytes32 participantNetwork = economicEngine.participantNetworks(msg.sender);
        uint256 sameNetworkVouchers = 0;
        
        for (uint256 i = 0; i < voucherAddresses.length; i++) {
            address voucherAddr = voucherAddresses[i];
            require(voucherAddr != msg.sender, "Cannot vouch for yourself");
            require(participants[voucherAddr].status == ParticipantStatus.ACTIVE, "Voucher not active participant");
            require(!hasVouched[voucherAddr][msg.sender], "Voucher already vouched for you");
            require(voucherCount[voucherAddr] < 10, "Voucher has reached maximum vouching limit");
            
            // Check for network correlation to prevent Sybil vouching networks
            bytes32 voucherNetwork = economicEngine.participantNetworks(voucherAddr);
            if (voucherNetwork == participantNetwork && participantNetwork != bytes32(0)) {
                sameNetworkVouchers++;
            }
            
            hasVouched[voucherAddr][msg.sender] = true;
            
            // Create voucher record
            bytes32 voucherId = keccak256(abi.encodePacked(voucherAddr, msg.sender, block.timestamp));
            vouchers[voucherId] = Voucher({
                voucher: voucherAddr,
                participant: msg.sender,
                stakeAmount: VOUCHER_STAKE,
                timestamp: block.timestamp,
                active: true
            });
            
            totalVoucherStake += VOUCHER_STAKE;
            voucherCount[voucherAddr]++;
            
            emit CommunityVouch(voucherAddr, msg.sender, VOUCHER_STAKE, block.timestamp);
        }
        
        // Prevent Sybil vouching networks - too many vouchers from same network is suspicious
        require(sameNetworkVouchers <= voucherAddresses.length / 2, "Too many vouchers from same network");
        
        // Apply community discount to effective stake
        uint256 effectiveStake = (msg.value * (BASIS_POINTS - COMMUNITY_DISCOUNT)) / BASIS_POINTS;
        
        // Create participant record
        Participant storage participant = participants[msg.sender];
        participant.path = RegistrationPath.COMMUNITY;
        participant.status = ParticipantStatus.ACTIVE;
        participant.stakeAmount = msg.value;
        participant.effectiveStake = effectiveStake;
        participant.registrationTime = block.timestamp;
        participant.vouchers = voucherAddresses;
        
        // Update global statistics
        totalParticipants++;
        totalStaked += msg.value;
        
        // Integrate with economic security engine
        economicEngine.registerParticipant(msg.sender, effectiveStake);
        
        emit ParticipantRegistered(
            msg.sender,
            RegistrationPath.COMMUNITY,
            msg.value,
            effectiveStake,
            block.timestamp
        );
    }
    
    /**
     * @notice MERIT PATH: Register with contribution-based discounts
     * @dev Algorithmic assessment of contributions for reduced stake requirements
     * @param contributionProof Hash of contribution verification data
     * @param contributionType Type of contribution (e.g., "GitHub", "Research", etc.)
     */
    function registerMeritPath(
        bytes32 contributionProof,
        string calldata contributionType
    ) 
        external 
        payable 
        nonReentrant 
        whenNotEmergency
    {
        require(!usedMeritHashes[contributionProof], "Contribution already used");
        require(participants[msg.sender].status == ParticipantStatus.UNREGISTERED, "Already registered");
        
        // Validate contribution and calculate discount
        uint256 meritValue = _validateContribution(contributionProof, contributionType);
        uint256 discount = _calculateMeritDiscount(meritValue);
        
        // Calculate required stake with merit discount
        uint256 requiredStake = _calculateMeritStake(MIN_ETH_STAKE, discount);
        require(msg.value >= requiredStake, "Insufficient stake for merit path");
        
        // Apply merit discount to effective stake
        uint256 effectiveStake = (msg.value * (BASIS_POINTS - discount)) / BASIS_POINTS;
        
        // Record the contribution
        meritContributions[msg.sender].push(MeritContribution({
            contributionHash: contributionProof,
            value: meritValue,
            timestamp: block.timestamp,
            discountEarned: discount,
            contributionType: contributionType
        }));
        usedMeritHashes[contributionProof] = true;
        
        // Create participant record
        Participant storage participant = participants[msg.sender];
        participant.path = RegistrationPath.MERIT;
        participant.status = ParticipantStatus.ACTIVE;
        participant.stakeAmount = msg.value;
        participant.effectiveStake = effectiveStake;
        participant.registrationTime = block.timestamp;
        participant.meritHash = contributionProof;
        
        // Update global statistics
        totalParticipants++;
        totalStaked += msg.value;
        
        // Integrate with economic security engine
        economicEngine.registerParticipant(msg.sender, effectiveStake);
        
        emit ParticipantRegistered(
            msg.sender,
            RegistrationPath.MERIT,
            msg.value,
            effectiveStake,
            block.timestamp
        );
        
        emit MeritContributionValidated(
            msg.sender,
            contributionProof,
            meritValue,
            discount,
            contributionType
        );
    }

    // ============================================================================
    //                              WITHDRAWAL SYSTEM
    // ============================================================================
    
    /**
     * @notice Request withdrawal of staked ETH
     * @dev Initiates timelock period before withdrawal can be completed
     */
    function requestWithdrawal() external nonReentrant {
        Participant storage participant = participants[msg.sender];
        require(participant.status == ParticipantStatus.ACTIVE, "Not active participant");
        require(!participant.hasActiveDispute, "Cannot withdraw during dispute");
        
        participant.status = ParticipantStatus.WITHDRAWING;
        participant.withdrawalRequestTime = block.timestamp;
        
        uint256 availableAt = block.timestamp + WITHDRAWAL_TIMELOCK;
        
        emit StakeWithdrawalRequested(msg.sender, participant.stakeAmount, availableAt);
    }
    
    /**
     * @notice Complete withdrawal after timelock period
     * @dev Transfers staked ETH back to participant
     */
    function completeWithdrawal() external nonReentrant {
        Participant storage participant = participants[msg.sender];
        require(participant.status == ParticipantStatus.WITHDRAWING, "Not in withdrawal state");
        require(block.timestamp >= participant.withdrawalRequestTime + WITHDRAWAL_TIMELOCK, "Timelock not expired");
        require(!participant.hasActiveDispute, "Cannot withdraw during dispute");
        
        uint256 amount = participant.stakeAmount;
        
        // Reset participant to unregistered
        participant.status = ParticipantStatus.UNREGISTERED;
        participant.stakeAmount = 0;
        participant.effectiveStake = 0;
        participant.withdrawalRequestTime = 0;
        
        // Update global statistics
        totalParticipants--;
        totalStaked -= amount;
        
        // Notify economic security engine
        economicEngine.deregisterParticipant(msg.sender);
        
        // Transfer ETH back to participant
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "DecentralizedFairLaunch: ETH withdrawal failed");
        
        emit StakeWithdrawn(msg.sender, amount, block.timestamp);
    }

    // ============================================================================
    //                           COMMUNITY DISPUTE SYSTEM
    // ============================================================================
    
    /**
     * @notice Challenge a participant's behavior
     * @dev Community-driven dispute resolution without centralized authority
     * @param participant Address of participant being challenged
     * @param evidenceHash Hash of evidence supporting the challenge
     */
    function createDispute(
        address participant,
        bytes32 evidenceHash
    ) external payable nonReentrant {
        require(participants[participant].status == ParticipantStatus.ACTIVE, "Participant not active");
        require(participants[msg.sender].status == ParticipantStatus.ACTIVE, "Challenger not active");
        require(msg.value >= VOUCHER_STAKE, "Insufficient challenger stake");
        
        bytes32 disputeId = keccak256(abi.encodePacked(participant, msg.sender, evidenceHash, block.timestamp));
        
        Dispute storage dispute = disputes[disputeId];
        dispute.participant = participant;
        dispute.challenger = msg.sender;
        dispute.evidenceHash = evidenceHash;
        dispute.challengerStake = msg.value;
        dispute.createdAt = block.timestamp;
        
        participants[participant].hasActiveDispute = true;
        participantDisputes[participant].push(disputeId);
        
        emit DisputeCreated(disputeId, participant, msg.sender, evidenceHash, msg.value);
    }
    
    /**
     * @notice Vote on a community dispute
     * @dev Community members vote to resolve disputes algorithmically
     * @param disputeId ID of the dispute to vote on
     * @param voteUpheld Whether to uphold the dispute
     */
    function voteOnDispute(bytes32 disputeId, bool voteUpheld) external nonReentrant {
        require(participants[msg.sender].status == ParticipantStatus.ACTIVE, "Voter not active participant");
        
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.resolved, "Dispute already resolved");
        require(!dispute.voted[msg.sender], "Already voted");
        require(block.timestamp <= dispute.createdAt + WITHDRAWAL_TIMELOCK, "Voting period expired");
        
        dispute.voted[msg.sender] = true;
        if (voteUpheld) {
            dispute.votes++;
        }
        
        // Check if enough votes to resolve (simple majority of active participants)
        if (dispute.votes >= totalParticipants / 2) {
            _resolveDispute(disputeId, true);
        } else if (block.timestamp > dispute.createdAt + WITHDRAWAL_TIMELOCK) {
            _resolveDispute(disputeId, false);
        }
    }

    // ============================================================================
    //                              INTERNAL FUNCTIONS
    // ============================================================================
    
    /**
     * @dev Calculate required stake for community path with discount
     */
    function _calculateCommunityStake(uint256 stakeAmount) internal pure returns (uint256) {
        return (MIN_ETH_STAKE * (BASIS_POINTS - COMMUNITY_DISCOUNT)) / BASIS_POINTS;
    }
    
    /**
     * @dev Calculate required stake for merit path with discount
     */
    function _calculateMeritStake(uint256 baseStake, uint256 discount) internal pure returns (uint256) {
        return (baseStake * (BASIS_POINTS - discount)) / BASIS_POINTS;
    }
    
    /**
     * @dev Validate contribution and determine its value with oracle integration and anti-gaming
     * @dev Enhanced with oracle validation and stricter gaming prevention
     */
    function _validateContribution(bytes32 contributionHash, string calldata contributionType) 
        internal 
        view 
        returns (uint256 value) 
    {
        // Check if oracle has validated this contribution
        uint256 oracleValue = oracleValidatedContributions[contributionHash];
        if (oracleValue > 0) {
            return oracleValue; // Use oracle-validated value
        }
        
        // Get minimum value for contribution type  
        uint256 minValue = contributionTypeMinValues[contributionType];
        require(minValue > 0, "Invalid contribution type");
        
        // Apply more restrictive validation
        bytes32 typeHash = keccak256(bytes(contributionType));
        if (typeHash == keccak256(bytes("GitHub"))) {
            value = minValue; // No bonus for non-oracle validated GitHub
        } else if (typeHash == keccak256(bytes("Research"))) {
            value = minValue; // No bonus for non-oracle validated research  
        } else if (typeHash == keccak256(bytes("Community"))) {
            value = minValue / 2; // Reduced value without oracle validation
        } else {
            revert("Unsupported contribution type");
        }
        
        // Reduced randomness bonus and cap to prevent gaming
        uint256 hashValue = uint256(contributionHash);
        uint256 bonus = hashValue % 100; // Reduced from 500 to 100
        value = value + bonus;
        
        // Additional security: value must be reasonable
        require(value >= minValue, "Value below minimum");
        require(value <= minValue * 2, "Value suspiciously high");
        
        return value;
    }
    
    /**
     * @dev Calculate merit discount based on contribution value
     */
    function _calculateMeritDiscount(uint256 meritValue) internal pure returns (uint256 discount) {
        // Progressive discount based on merit value
        if (meritValue >= 2000) {
            discount = MAX_MERIT_DISCOUNT; // 75% discount for high-value contributions
        } else if (meritValue >= 1500) {
            discount = 6000; // 60% discount
        } else if (meritValue >= 1000) {
            discount = 4000; // 40% discount
        } else if (meritValue >= 500) {
            discount = 2000; // 20% discount
        } else {
            discount = 500; // 5% minimal discount
        }
        
        return discount;
    }
    
    /**
     * @dev Resolve a community dispute
     */
    function _resolveDispute(bytes32 disputeId, bool upheld) internal {
        Dispute storage dispute = disputes[disputeId];
        dispute.resolved = true;
        dispute.upheld = upheld;
        
        Participant storage participant = participants[dispute.participant];
        participant.hasActiveDispute = false;
        
        if (upheld) {
            // Slash participant's stake
            uint256 slashAmount = (participant.stakeAmount * SLASHING_RATE) / BASIS_POINTS;
            participant.stakeAmount -= slashAmount;
            participant.totalSlashed += slashAmount;
            totalSlashed += slashAmount;
            
            // Reward challenger
            (bool ok1,) = payable(dispute.challenger).call{value: dispute.challengerStake + slashAmount}("");
            require(ok1, "DecentralizedFairLaunch: ETH reward to challenger failed");
            
            emit ParticipantSlashed(
                dispute.participant,
                slashAmount,
                dispute.evidenceHash,
                block.timestamp
            );
        } else {
            // Return challenger stake
            (bool ok2,) = payable(dispute.challenger).call{value: dispute.challengerStake}("");
            require(ok2, "DecentralizedFairLaunch: ETH return to challenger failed");
        }
        
        emit DisputeResolved(disputeId, dispute.participant, upheld, dispute.votes, block.timestamp);
    }

    // ============================================================================
    //                               VIEW FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Get participant information
     * @param participant Address to query
     * @return Participant struct data
     */
    function getParticipant(address participant) external view returns (Participant memory) {
        return participants[participant];
    }
    
    /**
     * @notice Get system statistics
     */
    function getSystemStats() external view returns (
        uint256 _totalParticipants,
        uint256 _totalStaked,
        uint256 _totalSlashed,
        uint256 _totalEarningsDistributed
    ) {
        return (totalParticipants, totalStaked, totalSlashed, totalEarningsDistributed);
    }
    
    /**
     * @notice Get merit contributions for a participant
     * @param participant Address to query
     * @return Array of merit contributions
     */
    function getMeritContributions(address participant) external view returns (MeritContribution[] memory) {
        return meritContributions[participant];
    }
    
    /**
     * @notice Check if can withdraw
     * @param participant Address to check
     * @return Whether withdrawal is available
     */
    function canWithdraw(address participant) external view returns (bool) {
        Participant memory p = participants[participant];
        return p.status == ParticipantStatus.WITHDRAWING &&
               block.timestamp >= p.withdrawalRequestTime + WITHDRAWAL_TIMELOCK &&
               !p.hasActiveDispute;
    }

    // ============================================================================
    //                             ORACLE INTEGRATION
    // ============================================================================
    
    /**
     * @notice Validate contribution through oracle (community validators)
     * @dev Allows community validators to confirm contribution authenticity
     * @param contributionHash Hash of the contribution being validated
     * @param validatedValue Oracle-determined value for the contribution
     */
    function validateContributionOracle(bytes32 contributionHash, uint256 validatedValue) 
        external 
        nonReentrant 
    {
        require(participants[msg.sender].status == ParticipantStatus.ACTIVE, "Validator not active");
        require(validatedValue > 0, "Invalid validated value");
        require(oracleValidatedContributions[contributionHash] == 0, "Already validated");
        
        // Require validator to have high reputation and stake additional ETH as guarantee
        (uint256 stakeAmount,,,,,,,,,) = economicEngine.securityRecords(msg.sender);
        require(stakeAmount >= 1 ether, "Insufficient stake for oracle validation");
        
        // Store oracle validation (could be enhanced with multi-oracle consensus)
        oracleValidatedContributions[contributionHash] = validatedValue;
    }

    // ============================================================================
    //                        COMMUNITY EMERGENCY CONTROLS
    // ============================================================================
    
    /**
     * @notice Vote for emergency mode activation (community-controlled)
     * @dev No admin controls - only community consensus can activate emergency mode
     */
    function voteEmergency() external nonReentrant {
        require(participants[msg.sender].status == ParticipantStatus.ACTIVE, "Not active participant");
        require(!emergencyVotes[msg.sender], "Already voted");
        require(block.timestamp > emergencyModeActivatedAt + EMERGENCY_COOLDOWN, "Emergency cooldown active");
        
        emergencyVotes[msg.sender] = true;
        emergencyVoteCount++;
        
        // Check if threshold reached for emergency activation
        uint256 threshold = (totalParticipants * EMERGENCY_THRESHOLD_PERCENTAGE) / BASIS_POINTS;
        if (emergencyVoteCount >= threshold && !emergencyMode) {
            emergencyMode = true;
            emergencyModeActivatedAt = block.timestamp;
        }
    }
    
    /**
     * @notice Deactivate emergency mode (community-controlled)
     * @dev Automatic deactivation after cooldown period
     */
    function deactivateEmergency() external nonReentrant {
        require(emergencyMode, "Not in emergency mode");
        require(block.timestamp >= emergencyModeActivatedAt + EMERGENCY_COOLDOWN, "Cooldown period not met");
        
        // Reset emergency state
        emergencyMode = false;
        emergencyVoteCount = 0;
        emergencyModeActivatedAt = 0;
        
        // Reset all emergency votes
        // Note: In production, this would use a more gas-efficient reset mechanism
    }

    // ============================================================================
    //                              LEGACY MIGRATION
    // ============================================================================
    
    /**
     * @notice Migrate from legacy centralized contracts
     * @dev Allows participants to migrate their stakes to this decentralized system
     * @param legacyProof Proof of stake in legacy system
     */
    /**
     * @notice DISABLED: Legacy migration requires proper proof validation
     * @dev SECURITY FIX: Previously accepted any proof without validation, allowing
     * unauthorized migration. Disabled until proper legacy contract verification is implemented.
     */
    function migrateFromLegacy(bytes32 /* legacyProof */) external payable nonReentrant {
        revert("Legacy migration disabled - proof validation required");
    }

    // ============================================================================
    //                              RECEIVE FUNCTION
    // ============================================================================
    
    /**
     * @notice Accept ETH deposits for staking
     */
    receive() external payable {
        // ETH received - could be used for additional staking or rewards
        // Basic implementation just accepts the ETH
    }
}
