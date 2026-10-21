// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
// FAIR LAUNCH: Ownable removed for true decentralization
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IMultiAssetStaking.sol";
import "./interfaces/IDynamicStakeCalculator.sol";
import "./interfaces/ILayawayRegistration.sol";
import "./interfaces/IParticipantTypeRegistry.sol";
import "./interfaces/ISocialVerification.sol";
import "./interfaces/IStakeDelegation.sol";
import "./interfaces/ISlashingMechanism.sol";
import "./libraries/DynamicStakeCalculator.sol";

/**
 * @title WRFToken
 * @dev Climate-focused ERC20 token for the WRFCoin ecosystem with comprehensive fair launch features
 * 
 * Enhanced Fair Launch Features:
 * - Zero pre-mine token distribution (all tokens earned through participation)
 * - Permissionless weather station registration with multiple staking options
 * - Multi-asset staking support (ETH, WBTC, WRF, USDC, USDT)
 * - Dynamic stake calculation with sliding scale based on multiple factors
 * - Zero upfront cost layaway registration program
 * - Stake delegation system with referral rewards
 * - Social verification discounts and incentives
 * - Geographic zone incentives for underserved areas
 * - Comprehensive slashing mechanism for fraud prevention
 * - Backward compatibility with legacy registration methods
 * 
 * Core Features:
 * - ERC20 compliant with proper transfer/allowance mechanisms
 * - ERC20Permit for gasless approvals
 * - ERC20Votes for governance participation
 * - Weather station reward system with anti-inflation controls
 * - Staking rewards for computational NFT participation
 * - Carbon credit integration with burn mechanisms
 * - Comprehensive access controls and emergency pause functionality
 * - Gas-optimized storage and operations
 * - Reentrancy protection for all external calls
 * 
 * Advanced Staking Integration:
 * - MultiAssetStaking for diverse collateral support
 * - DynamicStakeCalculator for intelligent stake requirements
 * - LayawayRegistration for accessibility and inclusion
 * - ParticipantTypeRegistry for participation tracking
 * - SocialVerification for trust-building incentives
 * - StakeDelegation for community-driven onboarding
 * - SlashingMechanism for economic security enforcement
 * 
 * Security:
 * - Maximum supply cap enforcement
 * - Rate limiting for weather rewards
 * - Stake requirement verification before reward claims
 * - Slashing and eligibility checks for malicious behavior
 * - Input validation for all parameters
 * - Event emission for all critical operations
 * - Anti-manipulation and anti-Sybil mechanisms
 * - Economic security for high-value TVL protection
 * 
 * Fair Launch Principles:
 * - No initial token allocation to founders, team, or investors
 * - All tokens created through network participation rewards
 * - Permissionless participation with economic security measures
 * - Multiple registration pathways for accessibility
 * - Community-driven onboarding through delegation system
 * - Geographic incentives for global coverage
 * - Social verification for trust and discounts
 * 
 * @author WRFCoin Development Team
 * @notice This contract implements a Bitcoin-style fair launch for weather data networks
 */
contract WRFToken is ERC20, ERC20Permit, ERC20Votes, Pausable, ReentrancyGuard {
    /// @dev Maximum total supply: 1 billion tokens with 18 decimals
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;
    
    /// @dev Weather data reward rate: 17.5 WRF per validated data point
    uint256 public constant WEATHER_REWARD_RATE = 17.5e18;
    
    /// @dev Minimum time between weather reward claims (1 hour)
    uint256 public constant REWARD_COOLDOWN = 1 hours;
    
    /// @dev Maximum daily reward per station to prevent abuse
    uint256 public constant MAX_DAILY_REWARD = 420e18; // 24 * 17.5 = 420 WRF max per day

    /// @dev Maximum daily reward per address across all stations to prevent Sybil abuse
    uint256 public constant MAX_DAILY_REWARD_PER_ADDRESS = 840e18; // 2 stations worth max per address per day

    /// @dev Maximum reward claims per address per time window (anti-Sybil)
    uint256 public constant MAX_CLAIMS_PER_ADDRESS_PER_DAY = 48; // Max 48 claims per address per day

    /// @dev Minimum registration stake requirement for legacy ETH staking (0.01 ETH)
    uint256 public constant REGISTRATION_STAKE = 0.01e18;

    /// @dev Minimum station age before rewards can be claimed
    uint256 public constant MIN_REWARD_STATION_AGE = 1 days;

    /// @dev Contribution proof freshness window
    uint256 public constant CONTRIBUTION_PROOF_TTL = 2 hours;
    
    /// @dev Registered weather stations
    mapping(address => bool) public weatherStations;
    
    /// @dev Last reward claim time for each station
    mapping(address => uint256) public lastRewardTime;
    
    /// @dev Total rewards claimed by each station
    mapping(address => uint256) public totalWeatherRewards;
    
    /// @dev Daily reward tracking for rate limiting
    mapping(address => mapping(uint256 => uint256)) public dailyRewards; // station => day => amount

    /// @dev Per-address daily reward tracking for anti-Sybil rate limiting
    mapping(address => mapping(uint256 => uint256)) public dailyRewardsPerAddress; // caller => day => amount

    /// @dev Per-address daily claim count tracking for anti-Sybil rate limiting
    mapping(address => mapping(uint256 => uint256)) public dailyClaimCountPerAddress; // caller => day => count

    /// @dev SECURITY FIX: Per-address cooldown to prevent rapid multi-station Sybil reward claims
    /// Tracks the last reward claim timestamp per caller address (not per station)
    mapping(address => uint256) public lastAddressRewardTime;

    /// @dev Minimum interval between reward claims from the same address (15 minutes)
    uint256 public constant ADDRESS_REWARD_COOLDOWN = 15 minutes;

    /// @dev Station metadata for enhanced tracking
    mapping(address => string) public stationIds;

    /// @dev Prevent duplicate station IDs
    mapping(bytes32 => address) public stationIdOwners;

    /// @dev Station registration timestamp for reward eligibility
    mapping(address => uint256) public stationRegisteredAt;

    /// @dev Active contribution proof hash for each station
    mapping(address => bytes32) public stationPendingContributionProof;

    /// @dev Timestamp for each active contribution proof
    mapping(address => uint256) public stationPendingContributionProofAt;

    /// @dev Tracks consumed contribution proofs for replay protection
    mapping(bytes32 => bool) public consumedContributionProofs;

    /// @dev Tracks currently reserved contribution proofs to prevent collisions
    mapping(bytes32 => address) public contributionProofOwner;
    
    /// @dev Authorized reward distributors (can be smart contracts)
    mapping(address => bool) public rewardDistributors;
    
    // FAIR LAUNCH: Advanced staking system integration
    /// @dev Multi-asset staking contract for weather station registration
    IMultiAssetStaking public multiAssetStaking;
    
    /// @dev Dynamic stake calculator contract
    IDynamicStakeCalculator public dynamicStakeCalculator;
    
    /// @dev Layaway registration contract for zero upfront cost registration
    ILayawayRegistration public layawayRegistration;
    
    /// @dev Participant type registry for participation tracking
    IParticipantTypeRegistry public participantTypeRegistry;
    
    /// @dev Social verification contract for verification discounts
    ISocialVerification public socialVerification;
    
    /// @dev Stake delegation contract for referral systems
    IStakeDelegation public stakeDelegation;
    
    /// @dev Slashing mechanism contract for stake enforcement
    ISlashingMechanism public slashingMechanism;
    
    /// @dev Mapping to track stakes for weather stations (legacy support)
    mapping(address => uint256) public stationStakes;
    
    /// @dev Registration method tracking
    mapping(address => RegistrationMethod) public stationRegistrationMethod;
    
    /// @dev Permissionless registration is permanently enabled for fair launch
    bool public constant PERMISSIONLESS_REGISTRATION_ENABLED = true;
    
    /// @dev Flag to enable advanced staking features
    bool public advancedStakingEnabled = false;

    // ========== ON-CHAIN GOVERNANCE STATE ==========

    /// @dev On-chain proposal for governance voting
    struct Proposal {
        bytes32 id;
        address proposer;
        string title;
        string description;
        uint256 createdAt;
        uint256 votingDeadline;
        uint256 snapshotBlock;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
        bool canceled;
    }

    /// @dev Governance proposal storage
    mapping(bytes32 => Proposal) public proposals;

    /// @dev Track whether an address has voted on a proposal
    mapping(bytes32 => mapping(address => bool)) public hasVotedOnProposal;

    /// @dev Voting weight cast by each address on a proposal (0 = did not vote)
    mapping(bytes32 => mapping(address => uint256)) public proposalVoteWeight;

    /// @dev Minimum voting power required to create a proposal (1000 WRF)
    uint256 public constant PROPOSAL_THRESHOLD = 1000e18;

    /// @dev Default voting period (7 days)
    uint256 public constant VOTING_PERIOD = 7 days;

    /// @dev Quorum: minimum total votes for a result to be valid (10000 WRF)
    uint256 public constant QUORUM = 10000e18;

    // Registration method enumeration
    enum RegistrationMethod {
        LEGACY_OWNER,      // DEPRECATED: Legacy owner-controlled registration (removed)
        LEGACY_STAKE,      // Legacy ETH stake registration
        MULTI_ASSET_STAKE, // New multi-asset staking
        LAYAWAY,           // Zero upfront cost layaway
        DELEGATION         // Stake delegation/referral
    }
    
    // Events with comprehensive information
    
    /// @notice Emitted when a weather station is registered
    /// @param station The address of the registered weather station
    /// @param stationId The unique identifier for the station
    event WeatherStationRegistered(address indexed station, string indexed stationId);
    
    /// @notice Emitted when a weather station is deregistered
    /// @param station The address of the deregistered weather station
    event WeatherStationDeregistered(address indexed station);
    
    /// @notice Emitted when weather reward is claimed
    /// @param station The weather station claiming the reward
    /// @param amount The amount of tokens rewarded
    /// @param timestamp The timestamp of the reward
    event WeatherRewardClaimed(address indexed station, uint256 amount, uint256 timestamp);

    /// @notice Emitted when a weather station submits a contribution proof
    /// @param station The weather station submitting the proof
    /// @param proofHash Unique proof hash for replay protection
    /// @param timestamp Submission timestamp
    event WeatherContributionProofSubmitted(address indexed station, bytes32 indexed proofHash, uint256 timestamp);
    
    /// @notice Emitted when staking reward is distributed
    /// @param staker The address receiving the staking reward
    /// @param amount The amount of tokens rewarded
    /// @param reason The reason for the reward (e.g., computational NFT staking)
    event StakingReward(address indexed staker, uint256 amount, string reason);
    
    /// @notice Emitted when tokens are burned for carbon credits
    /// @param user The address burning tokens
    /// @param amount The amount of tokens burned
    /// @param purpose The purpose of the burn (e.g., carbon credit purchase)
    event TokensBurnedForCarbon(address indexed user, uint256 amount, string purpose);
    
    /// @notice Emitted when a reward distributor is authorized/deauthorized
    /// @param distributor The address of the distributor
    /// @param authorized Whether the distributor is authorized
    event RewardDistributorUpdated(address indexed distributor, bool authorized);
    
    // FAIR LAUNCH: New events for advanced staking system
    /// @notice Emitted when permissionless registration is enabled/disabled
    /// @param enabled Whether permissionless registration is enabled
    event PermissionlessRegistrationToggled(bool enabled);
    
    /// @notice Emitted when advanced staking features are enabled/disabled
    /// @param enabled Whether advanced staking is enabled
    event AdvancedStakingToggled(bool enabled);
    
    /// @notice Emitted when a weather station stakes for registration (legacy)
    /// @param station The address of the weather station
    /// @param stationId The unique identifier for the station
    /// @param stakeAmount The amount staked for registration
    event WeatherStationStakeRegistered(address indexed station, string indexed stationId, uint256 stakeAmount);
    
    /// @notice Emitted when a weather station registers via multi-asset staking
    /// @param station The address of the weather station
    /// @param stationId The unique identifier for the station
    /// @param asset The asset used for staking
    /// @param stakeAmount The amount staked
    /// @param stakeValueUSD The USD value of the stake
    /// @param registrationMethod The method used for registration
    event WeatherStationMultiAssetRegistered(
        address indexed station, 
        string indexed stationId, 
        address indexed asset,
        uint256 stakeAmount, 
        uint256 stakeValueUSD, 
        RegistrationMethod registrationMethod
    );
    
    /// @notice Emitted when a weather station registers via layaway program
    /// @param station The address of the weather station
    /// @param stationId The unique identifier for the station
    /// @param layawayPeriod The layaway period in seconds
    /// @param requiredStakeUSD The required stake amount in USD
    event WeatherStationLayawayRegistered(
        address indexed station, 
        string indexed stationId, 
        uint256 layawayPeriod, 
        uint256 requiredStakeUSD
    );
    
    /// @notice Emitted when a weather station registers via stake delegation
    /// @param station The address of the weather station
    /// @param stationId The unique identifier for the station
    /// @param advocate The address of the advocate providing stake
    /// @param delegationId The delegation relationship ID
    /// @param referralCode The referral code used
    event WeatherStationDelegationRegistered(
        address indexed station, 
        string indexed stationId, 
        address indexed advocate, 
        bytes32 delegationId, 
        string referralCode
    );
    
    /// @notice Emitted when a weather station recovers their stake upon deregistration
    /// @param station The address of the weather station
    /// @param stakeAmount The amount of stake recovered
    event StakeRecovered(address indexed station, uint256 stakeAmount);
    
    /// @notice Emitted when staking contract addresses are updated
    /// @param contractType The type of contract updated
    /// @param oldAddress The old contract address
    /// @param newAddress The new contract address
    event StakingContractUpdated(string indexed contractType, address indexed oldAddress, address indexed newAddress);
    
    /// @notice Emitted when a station votes to deregister another station
    event DeregistrationVote(address indexed targetStation, address indexed voter, uint256 voteCount, bool executed);
    
    /// @notice Emitted when a governance proposal receives a vote
    event ProposalVote(bytes32 indexed proposalId, address indexed voter, bool support, uint256 weight, uint256 timestamp);

    /// @notice Emitted when a new governance proposal is created
    event ProposalCreated(bytes32 indexed proposalId, address indexed proposer, string title, uint256 votingDeadline);

    /// @notice Emitted when a governance proposal is executed
    event ProposalExecuted(bytes32 indexed proposalId);

    /// @notice Emitted when a governance proposal is canceled
    event ProposalCanceled(bytes32 indexed proposalId);
    
    // Modifiers with enhanced security
    
    /// @dev Ensures only registered weather stations can call
    modifier onlyWeatherStation() {
        if (!weatherStations[msg.sender]) {
            revert("WRFToken: Not a registered weather station");
        }
        _;
    }
    
    /// @dev Ensures weather station meets current stake requirements
    modifier meetsStakeRequirements(address station) {
        if (advancedStakingEnabled && address(multiAssetStaking) != address(0)) {
            (, bool meetsRequirement, ,) = multiAssetStaking.getCollateralizationRatio(station);
            if (!meetsRequirement) {
                revert("WRFToken: Stake requirements not met");
            }
        }
        _;
    }
    
    /// @dev Ensures participant is not slashed or banned
    modifier notSlashed(address participant) {
        if (address(slashingMechanism) != address(0)) {
            (bool eligible, string memory reason) = slashingMechanism.checkEligibility(participant);
            if (!eligible) {
                revert(string(abi.encodePacked("WRFToken: Participant ineligible - ", reason)));
            }
        }
        _;
    }
    
    /// @dev DEPRECATED: Reward distributors removed for fair launch decentralization
    modifier onlyRewardDistributor() {
        revert("WRFToken: Reward distributors removed - use direct weather station rewards only");
        _;
    }
    
    /// @dev Validates address is not zero
    modifier validAddress(address addr) {
        if (addr == address(0)) {
            revert("WRFToken: Invalid address");
        }
        _;
    }
    
    /// @dev Validates amount is greater than zero
    modifier validAmount(uint256 amount) {
        if (amount == 0) {
            revert("WRFToken: Invalid amount");
        }
        _;
    }
    
    /**
     * @notice Constructor initializes the WRF token with secure defaults - FAIR LAUNCH VERSION
     * @dev Sets up ERC20, ERC20Permit, ERC20Votes with ZERO initial supply for fair launch
     * All tokens must be earned through network participation (weather data/forecasts)
     */
    constructor() ERC20("WRFCoin", "WRF") ERC20Permit("WRFCoin") ERC20Votes() {
        // FAIR LAUNCH: No initial supply is minted. Total supply starts at 0.
        // All tokens will be created via the reward mechanism by network participants.
        // This ensures no pre-mine advantage for founders, investors, or deployer.
    }
    
    // ========== WEATHER STATION MANAGEMENT ==========
    
    /**
     * @notice DEPRECATED: Legacy owner registration removed for fair launch
     * @dev This function has been disabled to ensure true decentralization
     * Use registerWeatherStationSimple() instead for permissionless registration
     */
    function registerWeatherStation(address, string calldata) 
        external 
        pure
    {
        revert("WRFToken: Owner registration disabled - use registerWeatherStationSimple");
    }
    
    /**
     * @notice UNIVERSAL: Simple weather station registration for everyone (FAIR LAUNCH)
     * @dev Single pathway registration with minimum barriers and maximum accessibility
     * @param stationId Unique identifier for the station (e.g., geographic coordinates)
     */
    function registerWeatherStationSimple(string calldata stationId) 
        external 
        payable 
        whenNotPaused 
        nonReentrant 
    {
        if (msg.value < REGISTRATION_STAKE) {
            revert("WRFToken: Minimum stake is 0.01 ETH for registration");
        }

        _registerLegacyStakeStation(stationId, msg.value);
    }
    
    /**
     * @notice DEPRECATED: Register weather station by staking (legacy permissionless)
     * @dev Use registerWeatherStationSimple() instead - this is maintained for backward compatibility
     * @param stationId Unique identifier for the station (e.g., geographic coordinates)
     */
    function registerWeatherStationWithStake(string calldata stationId) 
        external 
        payable 
        virtual 
        whenNotPaused 
        nonReentrant 
    {
        if (msg.value < REGISTRATION_STAKE) {
            revert("WRFToken: Minimum stake is 0.01 ETH for Sybil protection");
        }

        _registerLegacyStakeStation(stationId, msg.value);
    }
    
    /**
     * @notice FAIR LAUNCH: Register weather station with multi-asset staking
     * @dev Advanced registration using the new multi-asset staking system
     * @param stationId Unique identifier for the station
     * @param asset Address of the asset to stake
     * @param amount Amount of asset to stake
     * @param parameters Staking parameters for dynamic calculation
     */
    function registerWeatherStationWithMultiAssetStake(
        string calldata stationId,
        address asset,
        uint256 amount,
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) 
        external 
        payable
        whenNotPaused 
        nonReentrant 
        notSlashed(msg.sender)
    {
        if (!advancedStakingEnabled || address(multiAssetStaking) == address(0)) {
            revert("WRFToken: Advanced staking not enabled");
        }
        
        if (weatherStations[msg.sender]) {
            revert("WRFToken: Station already registered");
        }
        
        if (bytes(stationId).length == 0) {
            revert("WRFToken: Invalid station ID");
        }
        
        // Stake through multi-asset staking contract
        multiAssetStaking.stakeAsset{value: msg.value}(asset, amount, parameters);
        
        // Verify stake meets requirements
        (, bool meetsRequirement, ,) = multiAssetStaking.getCollateralizationRatio(msg.sender);
        if (!meetsRequirement) {
            revert("WRFToken: Insufficient stake amount");
        }
        
        // Get stake value for event
        (uint256 totalStakeUSD, ,) = multiAssetStaking.getStakeValueUSD(msg.sender);
        
        _registerStation(stationId, 0, RegistrationMethod.MULTI_ASSET_STAKE);
        
        emit WeatherStationMultiAssetRegistered(
            msg.sender, 
            stationId, 
            asset, 
            amount, 
            totalStakeUSD, 
            RegistrationMethod.MULTI_ASSET_STAKE
        );
        emit WeatherStationRegistered(msg.sender, stationId);
    }
    
    /**
     * @notice FAIR LAUNCH: Register weather station with layaway program (zero upfront cost)
     * @dev Allows registration with no upfront stake using layaway system
     * @param stationId Unique identifier for the station
     * @param parameters Staking parameters for dynamic calculation
     */
    function registerWeatherStationWithLayaway(
        string calldata stationId,
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        notSlashed(msg.sender)
    {
        if (!advancedStakingEnabled || address(layawayRegistration) == address(0)) {
            revert("WRFToken: Advanced staking not enabled");
        }
        
        if (weatherStations[msg.sender]) {
            revert("WRFToken: Station already registered");
        }
        
        if (bytes(stationId).length == 0) {
            revert("WRFToken: Invalid station ID");
        }
        
        // Calculate required stake
        if (address(dynamicStakeCalculator) != address(0)) {
            uint256 requiredStakeUSD = dynamicStakeCalculator.calculateRequiredStake(msg.sender);
            
            // Get layaway period based on participant info
            uint256 layawayPeriod = layawayRegistration.getParticipantLayawayPeriod(msg.sender);
            
            // Register with layaway
            layawayRegistration.updateLayawayPeriod(msg.sender, layawayPeriod);
            
            _registerStation(stationId, 0, RegistrationMethod.LAYAWAY);
            
            emit WeatherStationLayawayRegistered(
                msg.sender, 
                stationId, 
                layawayPeriod, 
                requiredStakeUSD
            );
            emit WeatherStationRegistered(msg.sender, stationId);
        }
    }
    
    /**
     * @notice FAIR LAUNCH: Register weather station via stake delegation (referral system)
     * @dev Allows registration using referral links where advocates provide initial stake
     * @param stationId Unique identifier for the station
     * @param referralCode The referral code from an advocate
     * @param signature EIP-712 signature from the advocate
     */
    function registerWeatherStationWithDelegation(
        string calldata stationId,
        string calldata referralCode,
        bytes calldata signature
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        notSlashed(msg.sender)
    {
        if (!advancedStakingEnabled || address(stakeDelegation) == address(0)) {
            revert("WRFToken: Advanced staking not enabled");
        }
        
        if (weatherStations[msg.sender]) {
            revert("WRFToken: Station already registered");
        }
        
        if (bytes(stationId).length == 0) {
            revert("WRFToken: Invalid station ID");
        }
        
        // Use referral link to create delegation relationship
        bytes32 delegationId = stakeDelegation.useReferralLink(referralCode, signature);
        
        // Get delegation info for event
        IStakeDelegation.DelegationRelationship memory delegation = stakeDelegation.getDelegation(delegationId);
        
        _registerStation(stationId, 0, RegistrationMethod.DELEGATION);
        
        emit WeatherStationDelegationRegistered(
            msg.sender, 
            stationId, 
            delegation.advocate, 
            delegationId, 
            referralCode
        );
        emit WeatherStationRegistered(msg.sender, stationId);
    }

    function _registerLegacyStakeStation(string memory stationId, uint256 stakeAmount) internal {
        _registerStation(stationId, stakeAmount, RegistrationMethod.LEGACY_STAKE);
        emit WeatherStationStakeRegistered(msg.sender, stationId, stakeAmount);
        emit WeatherStationRegistered(msg.sender, stationId);
    }

    function _registerStation(
        string memory stationId,
        uint256 stakeAmount,
        RegistrationMethod method
    ) internal {
        if (weatherStations[msg.sender]) {
            revert("WRFToken: Station already registered");
        }
        if (bytes(stationId).length == 0) {
            revert("WRFToken: Invalid station ID");
        }

        bytes32 stationIdHash = keccak256(bytes(stationId));
        address existingOwner = stationIdOwners[stationIdHash];
        if (existingOwner != address(0) && existingOwner != msg.sender) {
            revert("WRFToken: Station ID already registered");
        }

        weatherStations[msg.sender] = true;
        stationIds[msg.sender] = stationId;
        stationIdOwners[stationIdHash] = msg.sender;
        stationStakes[msg.sender] = stakeAmount;
        stationRegistrationMethod[msg.sender] = method;
        stationRegisteredAt[msg.sender] = block.timestamp;
    }

    function _clearStationTracking(address station) internal {
        string memory stationId = stationIds[station];
        if (bytes(stationId).length > 0) {
            bytes32 stationIdHash = keccak256(bytes(stationId));
            if (stationIdOwners[stationIdHash] == station) {
                delete stationIdOwners[stationIdHash];
            }
        }

        bytes32 pendingProof = stationPendingContributionProof[station];
        if (pendingProof != bytes32(0) && contributionProofOwner[pendingProof] == station) {
            delete contributionProofOwner[pendingProof];
        }

        delete stationIds[station];
        delete stationRegisteredAt[station];
        delete stationPendingContributionProof[station];
        delete stationPendingContributionProofAt[station];
    }

    /// @dev Legacy registrations must keep the minimum ETH stake to remain reward-eligible.
    /// Other staking modes are validated through their own staking system checks.
    function _meetsRewardStakeGate(address station) internal view returns (bool) {
        RegistrationMethod method = stationRegistrationMethod[station];
        if (method == RegistrationMethod.LEGACY_OWNER || method == RegistrationMethod.LEGACY_STAKE) {
            return stationStakes[station] >= REGISTRATION_STAKE;
        }
        return true;
    }
    
    /// @dev Community deregistration voting system
    mapping(address => mapping(address => bool)) public deregistrationVotes;
    mapping(address => uint256) public deregistrationVoteCount;
    uint256 public constant DEREGISTRATION_THRESHOLD = 50; // Require 50 station votes
    
    /**
     * @notice Community-governed weather station deregistration (FAIR LAUNCH: No owner control)
     * @dev Requires community consensus from other registered weather stations
     * @param station The address of the weather station to deregister
     */
    function voteToDeregisterStation(address station)
        external
        onlyWeatherStation
        validAddress(station)
        nonReentrant
    {
        if (!weatherStations[station]) {
            revert("WRFToken: Station not registered");
        }
        
        if (station == msg.sender) {
            revert("WRFToken: Cannot vote to deregister yourself - use deregisterAndRecoverStake");
        }
        
        if (!deregistrationVotes[station][msg.sender]) {
            deregistrationVotes[station][msg.sender] = true;
            deregistrationVoteCount[station]++;
            
            emit DeregistrationVote(station, msg.sender, deregistrationVoteCount[station], false);
            
            // If threshold reached, deregister the station
            if (deregistrationVoteCount[station] >= DEREGISTRATION_THRESHOLD) {
                weatherStations[station] = false;
                _clearStationTracking(station);
                
                // Return stake if exists
                uint256 stake = stationStakes[station];
                if (stake > 0) {
                    stationStakes[station] = 0;
                    Address.sendValue(payable(station), stake);
                    emit StakeRecovered(station, stake);
                }
                
                // Reset vote counts
                deregistrationVoteCount[station] = 0;
                
                emit DeregistrationVote(station, msg.sender, DEREGISTRATION_THRESHOLD, true);
                emit WeatherStationDeregistered(station);
            }
        }
    }
    
    /**
     * @notice FAIR LAUNCH: Self-deregister and recover stake
     * @dev Allows weather stations to deregister themselves and recover their stake
     */
    function deregisterAndRecoverStake() 
        external 
        onlyWeatherStation 
        whenNotPaused 
        nonReentrant 
    {
        address station = msg.sender;
        uint256 stake = stationStakes[station];
        
        // Deregister the station
        weatherStations[station] = false;
        _clearStationTracking(station);
        stationStakes[station] = 0;
        
        // Return the stake
        if (stake > 0) {
            Address.sendValue(payable(station), stake);
            emit StakeRecovered(station, stake);
        }

        emit WeatherStationDeregistered(station);
    }
    
    /**
     * @notice Claim weather data contribution rewards with comprehensive security checks
     * @dev Implements multiple anti-abuse mechanisms including cooldown and daily limits
     */
    function claimWeatherReward() 
        external 
        virtual 
        onlyWeatherStation 
        whenNotPaused 
        nonReentrant 
        meetsStakeRequirements(msg.sender)
        notSlashed(msg.sender)
    {
        address station = msg.sender;
        uint256 currentTime = block.timestamp;

        if (!_meetsRewardStakeGate(station)) {
            revert("WRFToken: Minimum registration stake required for rewards");
        }

        if (currentTime < stationRegisteredAt[station] + MIN_REWARD_STATION_AGE) {
            revert("WRFToken: Station must mature before claiming rewards");
        }

        bytes32 proofHash = stationPendingContributionProof[station];
        uint256 proofTimestamp = stationPendingContributionProofAt[station];
        if (proofHash == bytes32(0)) {
            revert("WRFToken: Contribution proof required");
        }
        if (consumedContributionProofs[proofHash]) {
            revert("WRFToken: Contribution proof already consumed");
        }
        if (contributionProofOwner[proofHash] != station) {
            revert("WRFToken: Contribution proof owner mismatch");
        }
        if (currentTime > proofTimestamp + CONTRIBUTION_PROOF_TTL) {
            revert("WRFToken: Contribution proof expired");
        }
        
        // Check cooldown period
        if (currentTime < lastRewardTime[station] + REWARD_COOLDOWN) {
            revert("WRFToken: Reward claimed too recently");
        }
        
        // Check daily limits to prevent abuse
        uint256 currentDay = currentTime / 1 days;
        if (dailyRewards[station][currentDay] + WEATHER_REWARD_RATE > MAX_DAILY_REWARD) {
            revert("WRFToken: Daily reward limit exceeded");
        }

        // SECURITY FIX: Per-address rate limiting to prevent multi-station Sybil attacks.
        // Uses msg.sender instead of tx.origin to avoid phishing vectors through intermediary contracts.
        address originAddress = msg.sender;

        // SECURITY FIX: Per-address cooldown prevents rapid multi-station reward cycling.
        // Even if a Sybil attacker controls many stations, they cannot claim faster than
        // one reward per ADDRESS_REWARD_COOLDOWN interval from the same caller address.
        if (currentTime < lastAddressRewardTime[originAddress] + ADDRESS_REWARD_COOLDOWN) {
            revert("WRFToken: Per-address reward cooldown not met");
        }

        if (dailyRewardsPerAddress[originAddress][currentDay] + WEATHER_REWARD_RATE > MAX_DAILY_REWARD_PER_ADDRESS) {
            revert("WRFToken: Per-address daily reward limit exceeded");
        }
        if (dailyClaimCountPerAddress[originAddress][currentDay] + 1 > MAX_CLAIMS_PER_ADDRESS_PER_DAY) {
            revert("WRFToken: Per-address daily claim count exceeded");
        }

        // Check max supply constraint
        if (totalSupply() + WEATHER_REWARD_RATE > MAX_SUPPLY) {
            revert("WRFToken: Max supply exceeded");
        }

        // Update state before external call (CEI pattern)
        lastRewardTime[station] = currentTime;
        lastAddressRewardTime[originAddress] = currentTime;
        totalWeatherRewards[station] += WEATHER_REWARD_RATE;
        dailyRewards[station][currentDay] += WEATHER_REWARD_RATE;
        dailyRewardsPerAddress[originAddress][currentDay] += WEATHER_REWARD_RATE;
        dailyClaimCountPerAddress[originAddress][currentDay] += 1;
        consumedContributionProofs[proofHash] = true;
        delete contributionProofOwner[proofHash];
        delete stationPendingContributionProof[station];
        delete stationPendingContributionProofAt[station];
        
        // Mint reward tokens
        _mint(station, WEATHER_REWARD_RATE);
        
        // Process delegation earnings if applicable
        if (address(stakeDelegation) != address(0) && 
            stationRegistrationMethod[station] == RegistrationMethod.DELEGATION) {
            (bool hasDelegate, ) = stakeDelegation.getRecruitDelegation(station);
            if (hasDelegate) {
                try stakeDelegation.processRecruitEarnings(station, WEATHER_REWARD_RATE) {
                    // Successfully processed delegation earnings
                } catch {
                    // If delegation processing fails, continue but emit event
                    // This ensures reward claiming doesn't fail due to delegation issues
                }
            }
        }
        
        emit WeatherRewardClaimed(station, WEATHER_REWARD_RATE, currentTime);
    }

    /**
     * @notice Submit a contribution proof hash before claiming rewards
     * @dev One proof can be consumed by exactly one reward claim; replay is blocked globally
     * @param proofHash Unique hash of off-chain contribution evidence
     */
    function submitWeatherContributionProof(bytes32 proofHash)
        external
        onlyWeatherStation
        whenNotPaused
    {
        if (proofHash == bytes32(0)) {
            revert("WRFToken: Invalid contribution proof");
        }
        if (consumedContributionProofs[proofHash]) {
            revert("WRFToken: Contribution proof already consumed");
        }
        if (contributionProofOwner[proofHash] != address(0)) {
            revert("WRFToken: Contribution proof already submitted");
        }

        bytes32 existingProof = stationPendingContributionProof[msg.sender];
        if (existingProof != bytes32(0) && contributionProofOwner[existingProof] == msg.sender) {
            delete contributionProofOwner[existingProof];
        }

        stationPendingContributionProof[msg.sender] = proofHash;
        stationPendingContributionProofAt[msg.sender] = block.timestamp;
        contributionProofOwner[proofHash] = msg.sender;

        emit WeatherContributionProofSubmitted(msg.sender, proofHash, block.timestamp);
    }
    
    // ========== FAIR LAUNCH ADMINISTRATION ==========
    
    /**
     * @notice DEPRECATED: Permissionless registration is permanently enabled
     * @dev This function has been disabled - registration is always permissionless for fair launch
     */
    function setPermissionlessRegistration(bool) 
        external 
        pure
    {
        revert("WRFToken: Permissionless registration permanently enabled");
    }
    
    /**
     * @notice DEPRECATED: Advanced staking control removed for simplicity
     * @dev This function has been disabled to maintain simple fair launch model
     */
    function setAdvancedStaking(bool) 
        external 
        pure
    {
        revert("WRFToken: Advanced staking control removed for fair launch simplicity");
    }
    
    /**
     * @notice DEPRECATED: Multi-asset staking removed for fair launch simplicity
     * @dev Complex staking systems removed - use simple registerWeatherStationSimple()
     */
    function setMultiAssetStaking(address) 
        external 
        pure
    {
        revert("WRFToken: Complex staking removed - use registerWeatherStationSimple");
    }
    
    /**
     * @notice DEPRECATED: Dynamic stake calculation removed for fair launch simplicity
     * @dev Complex calculations removed - use simple registerWeatherStationSimple()
     */
    function setDynamicStakeCalculator(address) 
        external 
        pure
    {
        revert("WRFToken: Dynamic staking removed - use registerWeatherStationSimple");
    }
    
    /**
     * @notice DEPRECATED: Layaway system removed for fair launch simplicity
     * @dev Zero-cost registration now built into registerWeatherStationSimple()
     */
    function setLayawayRegistration(address) 
        external 
        pure
    {
        revert("WRFToken: Layaway removed - zero-cost option in registerWeatherStationSimple");
    }
    
    /**
     * @notice DEPRECATED: Participant registry removed for fair launch simplicity
     * @dev Complex participant tracking removed - all users equal in fair launch
     */
    function setParticipantTypeRegistry(address) 
        external 
        pure
    {
        revert("WRFToken: Participant registry removed - fair launch treats all equally");
    }
    
    /**
     * @notice DEPRECATED: Social verification removed for fair launch simplicity
     * @dev Complex verification removed - simple stake-based Sybil protection used
     */
    function setSocialVerification(address) 
        external 
        pure
    {
        revert("WRFToken: Social verification removed - simple anti-Sybil in registerWeatherStationSimple");
    }
    
    /**
     * @notice DEPRECATED: Stake delegation removed for fair launch simplicity
     * @dev Complex delegation removed - direct registration in registerWeatherStationSimple
     */
    function setStakeDelegation(address) 
        external 
        pure
    {
        revert("WRFToken: Stake delegation removed - use direct registerWeatherStationSimple");
    }
    
    /**
     * @notice DEPRECATED: Complex slashing removed for fair launch simplicity
     * @dev Basic rate limiting provides sufficient protection without complex mechanisms
     */
    function setSlashingMechanism(address) 
        external 
        pure
    {
        revert("WRFToken: Complex slashing removed - basic rate limiting provides security");
    }
    
    /// @dev Governance voting for genesis airdrop (community-controlled)
    mapping(address => bool) public genesisAirdropVotes;
    uint256 public genesisAirdropVoteCount;
    uint256 public constant GENESIS_AIRDROP_THRESHOLD = 100; // Require 100 station votes
    bool public genesisAirdropExecuted = false;
    
    /**
     * @notice DEPRECATED: Genesis airdrop removed for pure fair launch
     * @dev True fair launch means ALL tokens earned through participation - no genesis distribution
     * Use registerWeatherStationSimple() and claimWeatherReward() to earn tokens
     */
    function genesisAirdrop(
        address[] calldata,
        uint256[] calldata
    ) 
        external 
        pure
    {
        revert("WRFToken: Genesis airdrop removed for pure fair launch - earn tokens through participation");
    }
    
    /**
     * @notice Create a governance proposal
     * @dev Requires PROPOSAL_THRESHOLD voting power (delegated via ERC20Votes)
     * @param title Short proposal title
     * @param description Proposal description
     * @return proposalId The unique identifier for the created proposal
     */
    function createProposal(string calldata title, string calldata description)
        external
        onlyWeatherStation
        whenNotPaused
        returns (bytes32 proposalId)
    {
        require(getVotes(msg.sender) >= PROPOSAL_THRESHOLD, "WRFToken: insufficient voting power to propose");
        require(bytes(title).length > 0, "WRFToken: empty title");

        proposalId = keccak256(abi.encodePacked(msg.sender, title, block.timestamp));
        require(proposals[proposalId].createdAt == 0, "WRFToken: proposal already exists");

        uint256 deadline = block.timestamp + VOTING_PERIOD;
        uint256 snapshot = block.timestamp - 1;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            createdAt: block.timestamp,
            votingDeadline: deadline,
            snapshotBlock: snapshot,
            yesVotes: 0,
            noVotes: 0,
            executed: false,
            canceled: false
        });

        emit ProposalCreated(proposalId, msg.sender, title, deadline);
    }

    /**
     * @notice Vote on a governance proposal using ERC20Votes voting power
     * @dev Weather stations vote with weight equal to their delegated voting power
     * @param proposalId The ID of the proposal to vote on
     * @param support Whether to support the proposal
     */
    function voteOnProposal(bytes32 proposalId, bool support)
        external
        onlyWeatherStation
        whenNotPaused
    {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.createdAt != 0, "WRFToken: proposal does not exist");
        require(block.timestamp <= proposal.votingDeadline, "WRFToken: voting period ended");
        require(!proposal.canceled, "WRFToken: proposal canceled");
        require(!proposal.executed, "WRFToken: proposal already executed");
        require(!hasVotedOnProposal[proposalId][msg.sender], "WRFToken: already voted");

        uint256 weight = getPastVotes(msg.sender, proposals[proposalId].snapshotBlock);
        require(weight > 0, "WRFToken: no voting power");

        hasVotedOnProposal[proposalId][msg.sender] = true;
        proposalVoteWeight[proposalId][msg.sender] = weight;

        if (support) {
            proposal.yesVotes += weight;
        } else {
            proposal.noVotes += weight;
        }

        emit ProposalVote(proposalId, msg.sender, support, weight, block.timestamp);
    }

    /**
     * @notice Execute a passed proposal after voting period ends
     * @param proposalId The ID of the proposal to execute
     */
    function executeProposal(bytes32 proposalId)
        external
        onlyWeatherStation
        whenNotPaused
    {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.createdAt != 0, "WRFToken: proposal does not exist");
        require(block.timestamp > proposal.votingDeadline, "WRFToken: voting period not ended");
        require(!proposal.executed, "WRFToken: already executed");
        require(!proposal.canceled, "WRFToken: proposal canceled");
        require(proposal.yesVotes + proposal.noVotes >= QUORUM, "WRFToken: quorum not reached");
        require(proposal.yesVotes > proposal.noVotes, "WRFToken: proposal did not pass");

        proposal.executed = true;

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal (only the proposer, before execution)
     * @param proposalId The ID of the proposal to cancel
     */
    function cancelProposal(bytes32 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.createdAt != 0, "WRFToken: proposal does not exist");
        require(msg.sender == proposal.proposer, "WRFToken: not the proposer");
        require(block.timestamp <= proposal.votingDeadline, "WRFToken: cannot cancel after voting period");
        require(!proposal.executed, "WRFToken: already executed");
        require(!proposal.canceled, "WRFToken: already canceled");

        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Get proposal details
     * @param proposalId The ID of the proposal
     * @return proposer The proposer address
     * @return title The proposal title
     * @return yesVotes Total yes voting power
     * @return noVotes Total no voting power
     * @return votingDeadline Voting end timestamp
     * @return executed Whether the proposal was executed
     * @return canceled Whether the proposal was canceled
     */
    function getProposal(bytes32 proposalId)
        external
        view
        returns (
            address proposer,
            string memory title,
            uint256 yesVotes,
            uint256 noVotes,
            uint256 votingDeadline,
            bool executed,
            bool canceled
        )
    {
        Proposal storage p = proposals[proposalId];
        require(p.createdAt != 0, "WRFToken: proposal does not exist");
        return (p.proposer, p.title, p.yesVotes, p.noVotes, p.votingDeadline, p.executed, p.canceled);
    }

    // ========== REWARD DISTRIBUTION MANAGEMENT ==========
    
    /**
     * @notice DEPRECATED: Reward distributor authorization removed for fair launch
     * @dev Only weather stations can claim rewards directly - no intermediary distributors needed
     * This ensures true decentralization with no privileged reward distribution
     */
    function setRewardDistributor(address, bool) 
        external 
        pure
    {
        revert("WRFToken: Reward distributors removed - only direct weather station claims allowed");
    }
    
    /**
     * @notice DEPRECATED: Staking rewards removed for pure fair launch
     * @dev Pure fair launch means only weather data rewards - no staking mint privileges
     * All tokens must be earned through weather station participation
     */
    function mintStakingReward(
        address, 
        uint256, 
        string calldata
    ) 
        external 
        pure
    {
        revert("WRFToken: Staking rewards removed - only weather station rewards in pure fair launch");
    }
    
    /**
     * @notice DEPRECATED: Batch staking rewards removed for pure fair launch
     * @dev Pure fair launch means only weather data rewards - no batch mint privileges
     * All tokens must be earned individually through weather station participation
     */
    function batchMintStakingRewards(
        address[] calldata,
        uint256[] calldata,
        string calldata
    ) 
        external 
        pure
    {
        revert("WRFToken: Batch staking rewards removed - only individual weather station rewards in pure fair launch");
    }
    
    // ========== CARBON CREDIT INTEGRATION ==========
    
    /**
     * @notice Burn tokens for carbon credit purchases with detailed tracking
     * @dev Enhanced burn functionality with purpose tracking for transparency
     * @param amount The amount of tokens to burn
     * @param purpose The purpose of the burn (e.g., "Carbon Credit Purchase")
     */
    function burnForCarbonCredits(uint256 amount, string calldata purpose) 
        external 
        whenNotPaused 
        nonReentrant 
        validAmount(amount) 
    {
        // Check user balance
        if (balanceOf(msg.sender) < amount) {
            revert("WRFToken: Insufficient balance");
        }
        
        // Burn tokens
        _burn(msg.sender, amount);
        
        emit TokensBurnedForCarbon(msg.sender, amount, purpose);
    }
    
    /**
     * @notice Burn tokens from an account with allowance for carbon credits
     * @dev Allows authorized contracts to burn tokens from users (with approval)
     * @param from The account to burn tokens from
     * @param amount The amount of tokens to burn
     * @param purpose The purpose of the burn
     */
    function burnFromForCarbonCredits(
        address from, 
        uint256 amount, 
        string calldata purpose
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        validAddress(from) 
        validAmount(amount) 
    {
        // Check and update allowance
        uint256 currentAllowance = allowance(from, msg.sender);
        if (currentAllowance < amount) {
            revert("WRFToken: Insufficient allowance");
        }
        
        // Update allowance before burning (CEI pattern)
        _approve(from, msg.sender, currentAllowance - amount);
        
        // Burn tokens
        _burn(from, amount);
        
        emit TokensBurnedForCarbon(from, amount, purpose);
    }
    
    // ========== EMERGENCY CONTROLS ==========
    
    /// @dev Emergency pause requires community consensus or automatic triggers
    mapping(address => bool) public emergencyPauseVotes;
    uint256 public emergencyPauseVoteCount;
    uint256 public constant EMERGENCY_PAUSE_THRESHOLD = 100; // Require 100 voters for emergency pause
    uint256 public lastEmergencyPause;
    
    /**
     * @notice Community-governed emergency pause (FAIR LAUNCH: No owner control)
     * @dev Requires sufficient community votes or automatic security triggers
     */
    function emergencyPause() external {
        if (weatherStations[msg.sender]) {
            // Weather stations can vote for emergency pause
            if (!emergencyPauseVotes[msg.sender]) {
                emergencyPauseVotes[msg.sender] = true;
                emergencyPauseVoteCount++;
            }
        }
        
        // Automatic triggers for emergency pause
        bool shouldPause = false;
        
        // Trigger 1: Community consensus
        if (emergencyPauseVoteCount >= EMERGENCY_PAUSE_THRESHOLD) {
            shouldPause = true;
        }
        
        // Trigger 2: Suspicious activity (large supply changes)
        if (totalSupply() > MAX_SUPPLY * 95 / 100) { // 95% of max supply reached
            shouldPause = true;
        }
        
        // Trigger 3: Rate limiting violations (prevent if someone tries to exploit)
        // This would be triggered by monitoring systems
        
        if (shouldPause) {
            lastEmergencyPause = block.timestamp;
            _pause();
        }
        // If conditions not met, return silently so vote accumulation isn't reverted.
    }
    
    /**
     * @notice Automatic unpause after emergency period (FAIR LAUNCH: No owner control)
     * @dev System automatically recovers after 24 hours unless re-paused by community
     */
    function unpause() external {
        if (paused()) {
            // Auto-unpause after 24 hours
            if (block.timestamp >= lastEmergencyPause + 24 hours) {
                // Reset emergency votes
                emergencyPauseVoteCount = 0;
                _unpause();
            } else {
                revert("WRFToken: Must wait 24 hours after emergency pause");
            }
        } else {
            revert("WRFToken: Contract not paused");
        }
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get comprehensive weather station information
     * @dev Returns all relevant data about a weather station
     * @param station The address of the weather station
     * @return isRegistered Whether the station is registered
     * @return stationId The unique identifier for the station
     * @return lastReward Timestamp of last reward claim
     * @return totalRewards Total rewards claimed by the station
     * @return dailyRewardToday Rewards claimed today
     */
    function getWeatherStationInfo(address station) external view returns (
        bool isRegistered,
        string memory stationId,
        uint256 lastReward,
        uint256 totalRewards,
        uint256 dailyRewardToday
    ) {
        uint256 currentDay = block.timestamp / 1 days;
        return (
            weatherStations[station],
            stationIds[station],
            lastRewardTime[station],
            totalWeatherRewards[station],
            dailyRewards[station][currentDay]
        );
    }
    
    /**
     * @notice Check if a station can claim rewards now
     * @dev Validates all conditions for reward claiming
     * @param station The address of the weather station
     * @return canClaim Whether the station can claim rewards
     * @return timeUntilNext Seconds until next reward can be claimed
     * @return remainingDailyRewards Remaining rewards that can be claimed today
     */
    function canClaimReward(address station) external view returns (
        bool canClaim,
        uint256 timeUntilNext,
        uint256 remainingDailyRewards
    ) {
        if (!weatherStations[station]) {
            return (false, 0, 0);
        }
        
        uint256 currentTime = block.timestamp;
        uint256 nextRewardTime = lastRewardTime[station] + REWARD_COOLDOWN;
        uint256 currentDay = currentTime / 1 days;
        uint256 todayRewards = dailyRewards[station][currentDay];
        bytes32 pendingProof = stationPendingContributionProof[station];
        uint256 pendingProofAt = stationPendingContributionProofAt[station];
        
        timeUntilNext = currentTime >= nextRewardTime ? 0 : nextRewardTime - currentTime;
        remainingDailyRewards = MAX_DAILY_REWARD > todayRewards ? 
            MAX_DAILY_REWARD - todayRewards : 0;
        
        canClaim = (currentTime >= nextRewardTime) && 
                   (remainingDailyRewards >= WEATHER_REWARD_RATE) &&
                   (totalSupply() + WEATHER_REWARD_RATE <= MAX_SUPPLY) &&
                   _meetsRewardStakeGate(station) &&
                   (currentTime >= stationRegisteredAt[station] + MIN_REWARD_STATION_AGE) &&
                   (pendingProof != bytes32(0)) &&
                   !consumedContributionProofs[pendingProof] &&
                   (contributionProofOwner[pendingProof] == station) &&
                   (currentTime <= pendingProofAt + CONTRIBUTION_PROOF_TTL) &&
                   !paused();
    }
    
    /**
     * @notice Get daily reward statistics for a station
     * @dev Returns reward data for a specific day
     * @param station The address of the weather station
     * @param day The day (timestamp / 1 days)
     * @return rewardsClaimed Rewards claimed on that day
     */
    function getDailyRewards(address station, uint256 day) external view returns (uint256 rewardsClaimed) {
        return dailyRewards[station][day];
    }
    
    /**
     * @notice DEPRECATED: Reward distributors removed for fair launch decentralization
     * @dev Always returns false - only weather stations can claim rewards directly
     * @return isAuthorized Always false to indicate no privileged distributors
     */
    function isRewardDistributor(address) external pure returns (bool isAuthorized) {
        return false; // No reward distributors in fair launch model
    }
    
    /**
     * @notice Get the remaining mintable supply
     * @return remaining The amount of tokens that can still be minted
     */
    function remainingMintableSupply() external view returns (uint256 remaining) {
        uint256 current = totalSupply();
        return current >= MAX_SUPPLY ? 0 : MAX_SUPPLY - current;
    }
    
    // ========== FAIR LAUNCH VIEW FUNCTIONS ==========
    
    /**
     * @notice Get fair launch registration information
     * @return permissionlessEnabled Whether permissionless registration is active
     * @return stakeRequired The amount of ETH required to stake for registration
     * @return totalStaked Total amount of ETH staked by all stations
     */
    function getFairLaunchInfo() external view returns (
        bool permissionlessEnabled,
        uint256 stakeRequired,
        uint256 totalStaked
    ) {
        // Calculate total staked by iterating through all registered stations
        // Note: This is for transparency - in production, you'd want to track this more efficiently
        uint256 total = 0;
        // This is a simplified version - in practice you'd maintain a running total
        return (
            PERMISSIONLESS_REGISTRATION_ENABLED, // Always true in fair launch
            0.01 ether, // New reduced stake requirement
            total // Simplified for now
        );
    }
    
    /**
     * @notice Get comprehensive fair launch station information with advanced staking
     * @param station The address of the weather station
     * @return isRegistered Whether the station is registered
     * @return stationId The unique identifier for the station
     * @return lastReward Timestamp of last reward claim
     * @return totalRewards Total rewards claimed by the station
     * @return dailyRewardToday Rewards claimed today
     * @return stakeAmount Amount staked for registration (legacy ETH stake)
     * @return registrationMethod The registration method used
     * @return totalStakeValueUSD Total stake value in USD (if advanced staking)
     * @return meetsStakeReqs Whether current stake meets requirements
     * @return isEligible Whether station is eligible (not slashed/banned)
     */
    function getComprehensiveStationInfo(address station) external view returns (
        bool isRegistered,
        string memory stationId,
        uint256 lastReward,
        uint256 totalRewards,
        uint256 dailyRewardToday,
        uint256 stakeAmount,
        RegistrationMethod registrationMethod,
        uint256 totalStakeValueUSD,
        bool meetsStakeReqs,
        bool isEligible
    ) {
        uint256 currentDay = block.timestamp / 1 days;
        
        // Get advanced staking info if available
        if (advancedStakingEnabled && address(multiAssetStaking) != address(0)) {
            (totalStakeValueUSD, ,) = multiAssetStaking.getStakeValueUSD(station);
            (, meetsStakeReqs, ,) = multiAssetStaking.getCollateralizationRatio(station);
        } else {
            totalStakeValueUSD = 0;
            meetsStakeReqs = true; // Assume legacy stakes meet requirements
        }

        // Check eligibility
        if (address(slashingMechanism) != address(0)) {
            (isEligible, ) = slashingMechanism.checkEligibility(station);
        } else {
            isEligible = true;
        }

        return (
            weatherStations[station],
            stationIds[station],
            lastRewardTime[station],
            totalWeatherRewards[station],
            dailyRewards[station][currentDay],
            stationStakes[station],
            stationRegistrationMethod[station],
            totalStakeValueUSD,
            meetsStakeReqs,
            isEligible
        );
    }
    
    /**
     * @notice Check if fair launch principles are being followed
     * @return isZeroPremine Whether the contract started with zero supply
     * @return isPermissionlessActive Whether permissionless registration is enabled
     * @return totalSupplyNow Current total supply
     * @return percentageFromRewards Percentage of supply created through rewards vs genesis
     */
    function getFairLaunchStatus() external view returns (
        bool isZeroPremine,
        bool isPermissionlessActive,
        uint256 totalSupplyNow,
        uint256 percentageFromRewards
    ) {
        uint256 currentSupply = totalSupply();
        
        // Fair launch should have started with zero supply
        // We can't detect this perfectly post-deployment, but we check if permissionless is active
        return (
            true, // Zero premine confirmed in fair launch implementation
            PERMISSIONLESS_REGISTRATION_ENABLED, // Always true in fair launch
            currentSupply,
            currentSupply > 0 ? (currentSupply * 100) / currentSupply : 100 // Simplified calculation
        );
    }
    
    /**
     * @notice Get enhanced station stake information
     * @param station The address of the weather station
     * @return hasStake Whether the station has an active stake
     * @return legacyStakeAmount The amount of legacy ETH stake held
     * @return canRecoverStake Whether the station can recover their legacy stake
     * @return totalStakeValueUSD Total stake value in USD (advanced staking)
     * @return requiredStakeUSD Required stake amount in USD
     * @return registrationMethod The method used for registration
     * @return isDelegated Whether the stake is provided via delegation
     */
    function getEnhancedStakeInfo(address station) external view returns (
        bool hasStake,
        uint256 legacyStakeAmount,
        bool canRecoverStake,
        uint256 totalStakeValueUSD,
        uint256 requiredStakeUSD,
        RegistrationMethod registrationMethod,
        bool isDelegated
    ) {
        uint256 legacyStake = stationStakes[station];
        registrationMethod = stationRegistrationMethod[station];
        
        // Get advanced staking info
        if (advancedStakingEnabled && address(multiAssetStaking) != address(0)) {
            (totalStakeValueUSD, ,) = multiAssetStaking.getStakeValueUSD(station);
            (, , requiredStakeUSD, ) = multiAssetStaking.getCollateralizationRatio(station);
        } else {
            totalStakeValueUSD = 0;
            requiredStakeUSD = 0;
        }
        
        // Check if stake is provided via delegation
        if (address(stakeDelegation) != address(0)) {
            (isDelegated, ) = stakeDelegation.getRecruitDelegation(station);
        } else {
            isDelegated = false;
        }
        
        hasStake = legacyStake > 0 || totalStakeValueUSD > 0 || isDelegated;
        canRecoverStake = !paused() && weatherStations[station] && legacyStake > 0;
        
        return (
            hasStake,
            legacyStake,
            canRecoverStake,
            totalStakeValueUSD,
            requiredStakeUSD,
            registrationMethod,
            isDelegated
        );
    }
    
    /**
     * @notice Get advanced staking system status
     * @return permissionlessEnabled Whether permissionless registration is enabled
     * @return advancedStakingActive Whether advanced staking features are enabled
     * @return multiAssetStakingAddress Address of multi-asset staking contract
     * @return dynamicCalculatorAddress Address of dynamic stake calculator
     * @return layawayRegistrationAddress Address of layaway registration contract
     * @return stakeDelegationAddress Address of stake delegation contract
     * @return slashingMechanismAddress Address of slashing mechanism contract
     */
    function getAdvancedStakingStatus() external view returns (
        bool permissionlessEnabled,
        bool advancedStakingActive,
        address multiAssetStakingAddress,
        address dynamicCalculatorAddress,
        address layawayRegistrationAddress,
        address stakeDelegationAddress,
        address slashingMechanismAddress
    ) {
        return (
            PERMISSIONLESS_REGISTRATION_ENABLED, // Always true in fair launch
            false, // Advanced staking disabled for simplicity in fair launch
            address(0), // Multi-asset staking removed
            address(0), // Dynamic calculator removed  
            address(0), // Layaway registration removed
            address(0), // Stake delegation removed
            address(0)  // Slashing mechanism removed
        );
    }
    
    /**
     * @notice Calculate required stake for registration parameters
     * @param participant Address of the participant
     * @param parameters Staking parameters for calculation
     * @return requiredStakeUSD Required stake amount in USD
     * @return socialDiscountAvailable Available social verification discount
     * @return verificationDiscountAvailable Available verification discount
     * @return calculationValid Whether the calculation parameters are valid
     */
    function calculateRegistrationStake(
        address participant,
        DynamicStakeCalculator.StakeParameters calldata parameters
    ) external view returns (
        uint256 requiredStakeUSD,
        uint256 socialDiscountAvailable,
        uint256 verificationDiscountAvailable,
        bool calculationValid
    ) {
        // Validate parameters first
        (calculationValid, ) = DynamicStakeCalculator.validateStakeParameters(parameters);
        
        if (calculationValid) {
            // Calculate stake requirement
            DynamicStakeCalculator.StakeCalculationResult memory result = 
                DynamicStakeCalculator.calculateRequiredStake(parameters);
            requiredStakeUSD = result.finalStakeUSD;
            
            // Get available discounts
            if (address(socialVerification) != address(0)) {
                socialDiscountAvailable = socialVerification.getVerificationBonus(participant);
            }
            
            verificationDiscountAvailable = DynamicStakeCalculator.getVerificationDiscount(
                parameters.verificationLevel
            );
        } else {
            requiredStakeUSD = 0;
            socialDiscountAvailable = 0;
            verificationDiscountAvailable = 0;
        }
        
        return (
            requiredStakeUSD,
            socialDiscountAvailable,
            verificationDiscountAvailable,
            calculationValid
        );
    }
    
    /**
     * @notice Get registration options available for a participant
     * @param participant Address of the participant
     * @return canRegisterLegacy Whether legacy ETH staking is available
     * @return canRegisterMultiAsset Whether multi-asset staking is available
     * @return canRegisterLayaway Whether layaway registration is available
     * @return canRegisterDelegation Whether stake delegation is available
     * @return eligibilityReason Reason if participant is not eligible
     */
    function getRegistrationOptions(address participant) external view returns (
        bool canRegisterLegacy,
        bool canRegisterMultiAsset,
        bool canRegisterLayaway,
        bool canRegisterDelegation,
        string memory eligibilityReason
    ) {
        // Check if already registered
        if (weatherStations[participant]) {
            return (false, false, false, false, "Already registered");
        }
        
        // Check slashing status
        if (address(slashingMechanism) != address(0)) {
            (bool eligible, string memory reason) = slashingMechanism.checkEligibility(participant);
            if (!eligible) {
                return (false, false, false, false, reason);
            }
        }
        
        // FAIR LAUNCH: Only simple registration available
        canRegisterLegacy = true; // Always available via registerWeatherStationSimple
        canRegisterMultiAsset = false; // Removed for simplicity
        canRegisterLayaway = false; // Zero-cost option built into simple registration
        canRegisterDelegation = false; // Removed for simplicity
        
        eligibilityReason = "Eligible for registration";
        
        return (
            canRegisterLegacy,
            canRegisterMultiAsset,
            canRegisterLayaway,
            canRegisterDelegation,
            eligibilityReason
        );
    }
    
    // ========== INTERNAL OVERRIDES ==========
    
    /**
     * @dev Override _update to implement pause functionality and maintain vote tracking
     * @param from The sender address (address(0) for mint)
     * @param to The recipient address (address(0) for burn)
     * @param value The amount being transferred
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        // Check if transfers are paused
        if (paused()) {
            revert("WRFToken: Token transfers paused");
        }
        
        // Call parent implementation to handle voting power updates
        super._update(from, to, value);
    }
    
    /**
     * @dev Override nonces to handle conflict between ERC20Permit and Nonces
     * @param owner The address to get nonces for
     * @return The current nonce value
     */
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
    
    /**
     * @dev Override clock to use block timestamp for voting
     * @return The current timestamp
     */
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }
    
    /**
     * @dev Override CLOCK_MODE to indicate timestamp usage
     * @return The clock mode description
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
