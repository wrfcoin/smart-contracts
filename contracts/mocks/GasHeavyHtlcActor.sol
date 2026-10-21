// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IHtlcEthereum {
    function createHtlc(
        bytes32 contractId,
        bytes32 hashLock,
        uint8 hashAlgorithm,
        uint256 timeLock,
        address recipient,
        address tokenAddress,
        uint256 amount,
        bytes calldata signature
    ) external payable;

    function claimHtlc(bytes32 contractId, bytes32 secret) external;

    function refundHtlc(bytes32 contractId) external;
}

contract GasHeavyHtlcActor {
    uint256 public receiveCount;
    uint256 public lastValueReceived;

    receive() external payable {
        receiveCount += 1;
        lastValueReceived = msg.value;
    }

    function createEthHtlc(
        address htlc,
        bytes32 contractId,
        bytes32 hashLock,
        uint8 hashAlgorithm,
        uint256 timeLock,
        address recipient,
        uint256 amount
    ) external payable {
        IHtlcEthereum(htlc).createHtlc{value: msg.value}(
            contractId,
            hashLock,
            hashAlgorithm,
            timeLock,
            recipient,
            address(0),
            amount,
            ""
        );
    }

    function claim(address htlc, bytes32 contractId, bytes32 secret) external {
        IHtlcEthereum(htlc).claimHtlc(contractId, secret);
    }

    function refund(address htlc, bytes32 contractId) external {
        IHtlcEthereum(htlc).refundHtlc(contractId);
    }
}
