// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IYieldSource.sol";

contract CarbonLottery is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public depositToken;
    IYieldSource public yieldSource;
    address public carbonOffsetTreasury;
    uint256 public epochDuration;
    uint256 public epochStart;
    uint256 public carbonDonationBps;
    mapping(address => uint256) public deposits;
    address[] public depositors;
    uint256 public totalDeposited;

    uint256 public epochNumber;
    mapping(address => bool) private _isDepositor;

    error LotteryEpochNotEnded();
    error LotteryNoDepositors();
    error LotteryZeroAmount();
    error LotteryInvalidAddress();
    error LotteryInvalidBps();
    error LotteryInsufficientDeposit();

    event Deposited(address indexed depositor, uint256 amount, uint256 totalDeposited);
    event Withdrawn(address indexed depositor, uint256 amount, uint256 totalDeposited);
    event WinnerDrawn(address indexed winner, uint256 jackpotAmount, uint256 epochNumber);
    event CarbonDonationSent(address indexed treasury, uint256 amount);
    event EpochDurationUpdated(uint256 previousDuration, uint256 newDuration);
    event CarbonDonationBpsUpdated(uint256 previousBps, uint256 newBps);
    event CarbonTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    constructor(
        address initialOwner,
        address depositToken_,
        address yieldSource_,
        address carbonOffsetTreasury_,
        uint256 epochDuration_,
        uint256 carbonDonationBps_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            depositToken_ == address(0) ||
            yieldSource_ == address(0) ||
            carbonOffsetTreasury_ == address(0)
        ) {
            revert LotteryInvalidAddress();
        }
        if (carbonDonationBps_ > 10000) revert LotteryInvalidBps();

        depositToken = IERC20(depositToken_);
        yieldSource = IYieldSource(yieldSource_);
        carbonOffsetTreasury = carbonOffsetTreasury_;

        epochDuration = epochDuration_ == 0 ? 7 days : epochDuration_;
        epochStart = block.timestamp;
        carbonDonationBps = carbonDonationBps_ == 0 ? 1000 : carbonDonationBps_;

        if (yieldSource.depositToken() != depositToken_) {
            revert LotteryInvalidAddress();
        }
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert LotteryZeroAmount();

        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        depositToken.forceApprove(address(yieldSource), amount);
        yieldSource.supplyTokensTo(amount, address(this));

        if (!_isDepositor[msg.sender]) {
            _isDepositor[msg.sender] = true;
            depositors.push(msg.sender);
        }

        deposits[msg.sender] += amount;
        totalDeposited += amount;

        emit Deposited(msg.sender, amount, totalDeposited);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert LotteryZeroAmount();
        if (deposits[msg.sender] < amount) revert LotteryInsufficientDeposit();

        deposits[msg.sender] -= amount;
        totalDeposited -= amount;

        // If the depositor has fully withdrawn, remove them from the eligible-winner array.
        // Without this, zero-balance addresses accumulate in `depositors` forever and can
        // "win" a draw with nothing at stake (wasting the jackpot or skewing selection odds).
        if (deposits[msg.sender] == 0) {
            _isDepositor[msg.sender] = false;
            _removeDepositor(msg.sender);
        }

        uint256 redeemedAmount = yieldSource.redeemToken(amount, address(this));
        depositToken.safeTransfer(msg.sender, redeemedAmount);

        emit Withdrawn(msg.sender, redeemedAmount, totalDeposited);
    }

    /**
     * @notice Remove a depositor from the `depositors` array via swap-and-pop.
     * @dev O(n) scan; safe because depositors.length is bounded by active participants.
     */
    function _removeDepositor(address depositor) internal {
        uint256 len = depositors.length;
        for (uint256 i = 0; i < len; i++) {
            if (depositors[i] == depositor) {
                depositors[i] = depositors[len - 1];
                depositors.pop();
                break;
            }
        }
    }

    function drawWinner() external nonReentrant whenNotPaused {
        if (block.timestamp < epochStart + epochDuration) revert LotteryEpochNotEnded();
        if (depositors.length == 0) revert LotteryNoDepositors();

        uint256 strategyBalance = yieldSource.balanceOfToken(address(this));
        uint256 yieldAmount = strategyBalance > totalDeposited ? strategyBalance - totalDeposited : 0;

        uint256 winnerIndex = _pseudorandom(depositors.length);
        address winner = depositors[winnerIndex];

        uint256 donationAmount;
        uint256 jackpotAmount;

        if (yieldAmount > 0) {
            donationAmount = (yieldAmount * carbonDonationBps) / 10000;
            jackpotAmount = yieldAmount - donationAmount;

            if (donationAmount > 0) {
                uint256 redeemedDonation = yieldSource.redeemToken(donationAmount, address(this));
                depositToken.safeTransfer(carbonOffsetTreasury, redeemedDonation);
                emit CarbonDonationSent(carbonOffsetTreasury, redeemedDonation);
            }

            if (jackpotAmount > 0) {
                uint256 redeemedJackpot = yieldSource.redeemToken(jackpotAmount, address(this));
                depositToken.safeTransfer(winner, redeemedJackpot);
                jackpotAmount = redeemedJackpot;
            }
        }

        epochNumber += 1;
        epochStart = block.timestamp;

        emit WinnerDrawn(winner, jackpotAmount, epochNumber);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setCarbonOffsetTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert LotteryInvalidAddress();
        address previousTreasury = carbonOffsetTreasury;
        carbonOffsetTreasury = newTreasury;
        emit CarbonTreasuryUpdated(previousTreasury, newTreasury);
    }

    function setEpochDuration(uint256 newEpochDuration) external onlyOwner {
        if (newEpochDuration == 0) revert LotteryZeroAmount();
        uint256 previousDuration = epochDuration;
        epochDuration = newEpochDuration;
        emit EpochDurationUpdated(previousDuration, newEpochDuration);
    }

    function setCarbonDonationBps(uint256 newBps) external onlyOwner {
        if (newBps > 10000) revert LotteryInvalidBps();
        uint256 previousBps = carbonDonationBps;
        carbonDonationBps = newBps;
        emit CarbonDonationBpsUpdated(previousBps, newBps);
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function _pseudorandom(uint256 range) internal view returns (uint256) {
        // Production should use Chainlink VRF for unbiased randomness.
        return
            uint256(
                keccak256(
                    abi.encodePacked(block.prevrandao, block.timestamp, depositors.length)
                )
            ) % range;
    }
}
