// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeReceiver {
    function receiveBlockReward(uint256 amount) external;
}

/**
 * @title StorageEndowment
 * @dev Manages the endowment treasury for permanent environmental data retention.
 * This contract receives a percentage of block rewards or network fees and allows
 * approved keeper bots to claim funds to pay for decentralized storage deals (e.g., Filecoin).
 */
contract StorageEndowment is AccessControl, Pausable, ReentrancyGuard, IFeeReceiver {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_BOT_ROLE = keccak256("KEEPER_BOT_ROLE");

    IERC20 public immutable wrfToken;

    // Configuration
    uint256 public maxClaimAmountPerDay;

    /// @dev Rate in basis points (e.g. 50 = 0.5%). Governance-adjustable.
    uint256 public endowmentRateBps;
    uint256 public constant MAX_RATE_BPS = 1000; // 10% ceiling

    // Tracking
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public dailyClaimedAmount;

    // Events
    event EndowmentReceived(address indexed sender, uint256 amount);
    event FundsClaimed(address indexed keeper, uint256 amount, string dealId);
    event MaxClaimUpdated(uint256 oldMax, uint256 newMax);
    event RateUpdated(uint256 oldRate, uint256 newRate);

    constructor(address _wrfToken, uint256 _maxClaimAmountPerDay, uint256 _initialRateBps) {
        require(_wrfToken != address(0), "Invalid WRF token address");

        uint256 initialRateBps = _initialRateBps == 0 ? 50 : _initialRateBps;
        require(initialRateBps <= MAX_RATE_BPS, "Rate exceeds ceiling");

        wrfToken = IERC20(_wrfToken);
        maxClaimAmountPerDay = _maxClaimAmountPerDay;
        endowmentRateBps = initialRateBps;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Allows the protocol (or anyone) to deposit WRF into the endowment.
     */
    function depositEndowment(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be > 0");
        wrfToken.safeTransferFrom(msg.sender, address(this), amount);
        emit EndowmentReceived(msg.sender, amount);
    }

    /**
     * @dev Called by the protocol's reward distributor with the endowment share amount.
     * Uses ERC-20 transferFrom for consistency with depositEndowment.
     */
    function receiveBlockReward(uint256 amount) external override whenNotPaused nonReentrant {
        require(amount > 0, "Amount must be > 0");
        wrfToken.safeTransferFrom(msg.sender, address(this), amount);
        emit EndowmentReceived(msg.sender, amount);
    }

    /**
     * @dev Allows an approved keeper bot to claim WRF to pay for a storage deal.
     * @param amount The amount of WRF needed for the storage deal.
     * @param dealId An identifier for the storage deal being funded.
     */
    function claimForStorageDeal(uint256 amount, string calldata dealId)
        external
        onlyRole(KEEPER_BOT_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(amount > 0, "Amount must be > 0");
        require(bytes(dealId).length > 0, "Deal ID required");

        // Reset daily limit if 24 hours have passed
        if (block.timestamp >= lastClaimTime[msg.sender] + 1 days) {
            dailyClaimedAmount[msg.sender] = 0;
            lastClaimTime[msg.sender] = block.timestamp;
        }

        require(dailyClaimedAmount[msg.sender] + amount <= maxClaimAmountPerDay, "Exceeds daily claim limit");
        require(wrfToken.balanceOf(address(this)) >= amount, "Insufficient endowment funds");

        dailyClaimedAmount[msg.sender] += amount;

        wrfToken.safeTransfer(msg.sender, amount);

        emit FundsClaimed(msg.sender, amount, dealId);
    }

    /**
     * @dev Admin function to update the maximum daily claim amount per keeper.
     */
    function setMaxClaimAmountPerDay(uint256 _maxClaimAmountPerDay) external onlyRole(ADMIN_ROLE) {
        emit MaxClaimUpdated(maxClaimAmountPerDay, _maxClaimAmountPerDay);
        maxClaimAmountPerDay = _maxClaimAmountPerDay;
    }

    function setEndowmentRateBps(uint256 _rateBps) external onlyRole(ADMIN_ROLE) {
        require(_rateBps <= MAX_RATE_BPS, "Rate exceeds ceiling");
        emit RateUpdated(endowmentRateBps, _rateBps);
        endowmentRateBps = _rateBps;
    }

    function getEndowmentBalance() external view returns (uint256) {
        return wrfToken.balanceOf(address(this));
    }

    /**
     * @dev Admin function to pause operations in case of emergency.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Admin function to unpause operations.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
