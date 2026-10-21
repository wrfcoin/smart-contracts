// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./WRFToken.sol";

/**
 * @title WRFTokenTestnet
 * @notice Testnet version of WRFToken for fair launch testing
 * @dev Inherits from WRFToken but with modified parameters for testnet deployment
 * 
 * Key Differences from Mainnet:
 * - Lower stake requirement for easier testing
 * - Shorter cooldown periods for faster testing
 * - Higher reward rates for incentivization
 * - Special testnet tracking for genesis airdrop calculation
 * 
 * @author WRFCoin Development Team
 */
contract WRFTokenTestnet is WRFToken {
    
    /// @dev Testnet registration stake: 0.01 ETH (vs 0.1 ETH on mainnet)
    uint256 public constant TESTNET_REGISTRATION_STAKE = 0.01 ether;
    
    /// @dev Testnet reward cooldown: 10 minutes (vs 1 hour on mainnet)
    uint256 public constant TESTNET_REWARD_COOLDOWN = 10 minutes;
    
    /// @dev Testnet weather reward rate: 50 WRF (vs 17.5 WRF on mainnet) - higher to incentivize testing
    uint256 public constant TESTNET_WEATHER_REWARD_RATE = 50e18;
    
    /// @dev Testnet max daily reward: 1200 WRF (vs 420 WRF on mainnet)
    uint256 public constant TESTNET_MAX_DAILY_REWARD = 1200e18;
    
    /// @dev Track testnet participation for genesis airdrop calculation
    mapping(address => uint256) public testnetParticipationScore;
    mapping(address => uint256) public testnetDataSubmissions;
    mapping(address => uint256) public testnetQualityScore;
    
    /// @dev Testnet start time for participation tracking
    uint256 public immutable testnetLaunchTime;

    /// @dev Deployer address for testnet-only admin functions
    address public immutable testnetDeployer;
    
    /// @dev Event for testnet participation tracking
    event TestnetParticipationTracked(address indexed participant, uint256 score, string activity);
    
    /**
     * @notice Testnet constructor with fair launch principles
     * @dev Permissionless registration is permanently enabled in fair launch
     */
    constructor() WRFToken() {
        testnetLaunchTime = block.timestamp;
        testnetDeployer = msg.sender;
        // Permissionless registration is permanently enabled in fair launch version
    }
    
    /**
     * @notice Override registration function to use testnet stake amount
     * @param stationId Unique identifier for the station
     */
    function registerWeatherStationWithStake(string calldata stationId) 
        external 
        payable 
        override
        whenNotPaused 
        nonReentrant 
    {
        // Permissionless registration is always enabled in fair launch version
        
        if (msg.value != TESTNET_REGISTRATION_STAKE) {
            revert("WRFToken: Incorrect testnet stake amount");
        }
        
        if (weatherStations[msg.sender]) {
            revert("WRFToken: Station already registered");
        }
        
        if (bytes(stationId).length == 0) {
            revert("WRFToken: Invalid station ID");
        }
        
        // Register the station
        weatherStations[msg.sender] = true;
        stationIds[msg.sender] = stationId;
        stationStakes[msg.sender] = msg.value;
        // Record registration method + time so the inherited reward-eligibility
        // gates (_meetsRewardStakeGate, station-age tracking) evaluate correctly
        // for testnet stations. (#174)
        stationRegistrationMethod[msg.sender] = RegistrationMethod.LEGACY_STAKE;
        stationRegisteredAt[msg.sender] = block.timestamp;

        // Track testnet participation
        _updateTestnetParticipation(msg.sender, 100, "station_registration");
        
        emit WeatherStationStakeRegistered(msg.sender, stationId, msg.value);
        emit WeatherStationRegistered(msg.sender, stationId);
    }
    
    /**
     * @notice Override reward claiming with testnet parameters
     * @dev SECURITY (#174): the previous override enforced ONLY a per-station
     *      cooldown + per-station daily cap + max-supply, then minted 50 WRF and
     *      pumped `testnetParticipationScore` / `testnetDataSubmissions` with NO
     *      contribution proof and NO per-ADDRESS limits — bypassing every
     *      anti-Sybil gate the parent `WRFToken.claimWeatherReward` enforces.
     *      Because testnet stake is faucet-free it bounded nothing, and the
     *      pumped score feeds `calculateGenesisAirdrop`, letting a Sybil farm
     *      inflate its mainnet genesis airdrop.
     *
     *      This override now enforces the parent's full gate set — an unconsumed,
     *      owned, unexpired contribution proof; the stake gate; slashing/stake
     *      requirement modifiers; per-ADDRESS cooldown, per-address daily reward
     *      cap and per-address daily claim-count cap — while retaining the
     *      testnet reward RATE / cooldown / daily-cap parameters. The testnet
     *      keeps its relaxed station-age (no 1-day maturity wait) so the live
     *      per-block earn loop is not broken; every other anti-abuse control is
     *      at mainnet parity.
     */
    function claimWeatherReward()
        external
        override
        onlyWeatherStation
        whenNotPaused
        nonReentrant
        meetsStakeRequirements(msg.sender)
        notSlashed(msg.sender)
    {
        address station = msg.sender;
        uint256 currentTime = block.timestamp;

        // Stake-eligibility gate (parity with parent). Testnet registrations use
        // LEGACY_STAKE with a 0.01 ETH stake == REGISTRATION_STAKE, so this holds.
        if (!_meetsRewardStakeGate(station)) {
            revert("WRFToken: Minimum registration stake required for rewards");
        }

        // Contribution-proof requirement: a claim MUST consume a unique, owned,
        // unexpired, not-yet-consumed proof submitted via
        // submitWeatherContributionProof. This is the core anti-Sybil gate the
        // testnet path previously skipped entirely.
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

        // Per-station cooldown (testnet parameter).
        if (currentTime < lastRewardTime[station] + TESTNET_REWARD_COOLDOWN) {
            revert("WRFToken: Reward claimed too recently");
        }

        // Per-station daily cap (testnet parameter).
        uint256 currentDay = currentTime / 1 days;
        if (dailyRewards[station][currentDay] + TESTNET_WEATHER_REWARD_RATE > TESTNET_MAX_DAILY_REWARD) {
            revert("WRFToken: Daily reward limit exceeded");
        }

        // Per-ADDRESS anti-Sybil limits (ported from parent). The caller address
        // is the claiming station.
        address originAddress = msg.sender;
        if (currentTime < lastAddressRewardTime[originAddress] + ADDRESS_REWARD_COOLDOWN) {
            revert("WRFToken: Per-address reward cooldown not met");
        }
        if (dailyRewardsPerAddress[originAddress][currentDay] + TESTNET_WEATHER_REWARD_RATE > MAX_DAILY_REWARD_PER_ADDRESS) {
            revert("WRFToken: Per-address daily reward limit exceeded");
        }
        if (dailyClaimCountPerAddress[originAddress][currentDay] + 1 > MAX_CLAIMS_PER_ADDRESS_PER_DAY) {
            revert("WRFToken: Per-address daily claim count exceeded");
        }

        // Check max supply constraint
        if (totalSupply() + TESTNET_WEATHER_REWARD_RATE > MAX_SUPPLY) {
            revert("WRFToken: Max supply exceeded");
        }

        // Update state before external call (CEI pattern)
        lastRewardTime[station] = currentTime;
        lastAddressRewardTime[originAddress] = currentTime;
        totalWeatherRewards[station] += TESTNET_WEATHER_REWARD_RATE;
        dailyRewards[station][currentDay] += TESTNET_WEATHER_REWARD_RATE;
        dailyRewardsPerAddress[originAddress][currentDay] += TESTNET_WEATHER_REWARD_RATE;
        dailyClaimCountPerAddress[originAddress][currentDay] += 1;

        // Consume the contribution proof (global replay protection).
        consumedContributionProofs[proofHash] = true;
        delete contributionProofOwner[proofHash];
        delete stationPendingContributionProof[station];
        delete stationPendingContributionProofAt[station];

        // Track testnet participation
        _updateTestnetParticipation(station, 50, "data_submission");
        testnetDataSubmissions[station]++;

        // Mint reward tokens
        _mint(station, TESTNET_WEATHER_REWARD_RATE);

        emit WeatherRewardClaimed(station, TESTNET_WEATHER_REWARD_RATE, currentTime);
    }
    
    /**
     * @notice Update testnet participation score for genesis airdrop calculation
     * @param participant The participant address
     * @param points Points to add
     * @param activity Description of activity
     */
    function _updateTestnetParticipation(address participant, uint256 points, string memory activity) internal {
        testnetParticipationScore[participant] += points;
        emit TestnetParticipationTracked(participant, points, activity);
    }
    
    /**
     * @notice Manually update quality score for testing purposes
     * @dev Restricted to the testnet deployer (trusted operator/oracle role).
     *      The score feeds `calculateGenesisAirdrop`, so it MUST NOT be
     *      settable by the station itself — otherwise any address could
     *      inflate its own genesis-airdrop weighting by passing
     *      `station = msg.sender` (see issue #164). The previous
     *      `msg.sender == station` self-authorization branch is removed.
     * @param station Weather station address
     * @param score Quality score (0-100)
     */
    function updateTestnetQualityScore(address station, uint256 score) external {
        if (msg.sender != testnetDeployer) {
            revert("WRFToken: Only deployer can update quality score");
        }
        if (score > 100) {
            revert("WRFToken: Invalid quality score - must be <= 100");
        }
        testnetQualityScore[station] = score;
        _updateTestnetParticipation(station, score, "quality_update");
    }
    
    /**
     * @notice Calculate genesis airdrop amount for a testnet participant
     * @param participant The participant address
     * @return airdropAmount Amount of tokens to airdrop on mainnet launch
     */
    function calculateGenesisAirdrop(address participant) external view returns (uint256 airdropAmount) {
        uint256 participationScore = testnetParticipationScore[participant];
        uint256 dataSubmissions = testnetDataSubmissions[participant];
        uint256 qualityScore = testnetQualityScore[participant];
        uint256 timeOnTestnet = block.timestamp - testnetLaunchTime;
        
        // Complex formula considering multiple factors
        // Base airdrop = participation score * 100 WRF
        uint256 baseAirdrop = participationScore * 100e18;
        
        // Bonus for data submissions (up to 50% bonus)
        uint256 dataBonus = (dataSubmissions * 50e18) > (baseAirdrop / 2) ? (baseAirdrop / 2) : (dataSubmissions * 50e18);
        
        // Quality bonus (up to 25% bonus)
        uint256 qualityBonus = (baseAirdrop * qualityScore) / 400; // Divide by 400 to get max 25%
        
        // Time bonus for long-term participation (up to 25% bonus)
        uint256 timeBonus = timeOnTestnet > 30 days ? (baseAirdrop / 4) : (baseAirdrop * timeOnTestnet) / (30 days * 4);
        
        return baseAirdrop + dataBonus + qualityBonus + timeBonus;
    }
    
    /**
     * @notice Export testnet data for mainnet genesis airdrop
     * @param participants Array of participant addresses
     * @return airdropAmounts Array of corresponding airdrop amounts
     */
    function exportTestnetData(address[] calldata participants) external view returns (uint256[] memory airdropAmounts) {
        airdropAmounts = new uint256[](participants.length);
        
        for (uint256 i = 0; i < participants.length; i++) {
            airdropAmounts[i] = this.calculateGenesisAirdrop(participants[i]);
        }
        
        return airdropAmounts;
    }
    
    /**
     * @notice Get testnet participant statistics
     * @param participant The participant address
     * @return participationScore Total participation score
     * @return dataSubmissions Number of data submissions
     * @return qualityScore Current quality score
     * @return daysOnTestnet Days since testnet launch
     * @return projectedAirdrop Projected mainnet airdrop amount
     */
    function getTestnetStats(address participant) external view returns (
        uint256 participationScore,
        uint256 dataSubmissions,
        uint256 qualityScore,
        uint256 daysOnTestnet,
        uint256 projectedAirdrop
    ) {
        return (
            testnetParticipationScore[participant],
            testnetDataSubmissions[participant],
            testnetQualityScore[participant],
            (block.timestamp - testnetLaunchTime) / 1 days,
            this.calculateGenesisAirdrop(participant)
        );
    }
    
    /**
     * @notice Mint tokens for testing purposes (testnet only)
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function mintForTesting(address to, uint256 amount) external {
        require(msg.sender == testnetDeployer, "WRFToken: Only deployer can mint for testing");
        require(totalSupply() + amount <= MAX_SUPPLY, "WRFToken: Max supply exceeded");
        _mint(to, amount);
    }

    /**
     * @notice Get testnet configuration for transparency
     * @return stakeRequired Testnet stake requirement
     * @return rewardRate Testnet reward rate
     * @return cooldownPeriod Testnet cooldown period
     * @return maxDailyReward Testnet max daily reward
     */
    function getTestnetConfig() external pure returns (
        uint256 stakeRequired,
        uint256 rewardRate,
        uint256 cooldownPeriod,
        uint256 maxDailyReward
    ) {
        return (
            TESTNET_REGISTRATION_STAKE,
            TESTNET_WEATHER_REWARD_RATE,
            TESTNET_REWARD_COOLDOWN,
            TESTNET_MAX_DAILY_REWARD
        );
    }
}