// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./CryptographicSecurityModule.sol";

/**
 * @title CryptographicSecurityModuleHarness
 * @dev Test-only harness exposing internal verification behavior for deterministic
 *      algorithm-path assertions.
 */
contract CryptographicSecurityModuleHarness is CryptographicSecurityModule {
    constructor() CryptographicSecurityModule() {}

    function seedSigner(
        address _signer,
        bytes32 _publicKeyHash,
        CryptoAlgorithm _algorithm,
        SecurityLevel _clearanceLevel
    ) external {
        authorizedSigners[_signer] = AuthorizedSigner({
            signerAddress: _signer,
            publicKeyHash: _publicKeyHash,
            algorithm: _algorithm,
            addedAt: block.timestamp,
            lastUsed: 0,
            isActive: true,
            clearanceLevel: _clearanceLevel
        });
    }

    function verifySignatureForSigner(
        bytes32 _txHash,
        bytes calldata _signature,
        address _signer
    ) external view returns (bool) {
        return _verifySignature(_txHash, _signature, _signer);
    }
}
