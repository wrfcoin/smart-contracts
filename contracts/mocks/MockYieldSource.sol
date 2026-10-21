// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    mapping(address => uint256) private _balances;

    constructor(address token) {
        underlying = IERC20(token);
    }

    function depositToken() external view returns (address) {
        return address(underlying);
    }

    function supplyTokensTo(uint256 amount, address to) external {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        _balances[to] += amount;
    }

    function redeemToken(uint256 amount, address to) external returns (uint256) {
        uint256 available = _balances[msg.sender];
        uint256 payout = amount > available ? available : amount;
        _balances[msg.sender] = available - payout;
        underlying.safeTransfer(to, payout);
        return payout;
    }

    function balanceOfToken(address addr) external view returns (uint256) {
        return _balances[addr];
    }

    function addYield(uint256 amount, address beneficiary) external {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        _balances[beneficiary] += amount;
    }
}
