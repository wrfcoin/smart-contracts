# Launch Readiness Guard Spec

Date: 2026-05-30
Branch: test/launch-readiness-guards-spec
Follow-up: merged smart-contracts PRs #126 and #128

## Plan

1. Add a Mocha/Hardhat spec for `scripts/lib/launchReadiness.js`.
2. Cover live-network refusals for missing deploy credentials, default Hardhat mnemonic, all-zero private key, and localhost RPC fallback.
3. Cover accept paths for explicit live RPC plus deploy credentials and for local networks.
4. Cover `requireMinimumBalance` failure and success behavior against the Hardhat in-memory signer balance.
5. Validate with `npx hardhat test`.

## Preflight

- `scripts/lib/launchReadiness.js` currently has no direct automated test file.
- The merged helper exports `requireLiveDeployConfig`, `requireMinimumBalance`, and `isLocalNetwork`, which can be exercised without starting live network services.

## Implementation

- Added `test/LaunchReadinessGuards.test.js`.
- Covered live-network refusal paths for missing deploy credentials, the default Hardhat mnemonic, all-zero private key, and localhost RPC fallback.
- Covered local-network and explicit live-credential accept paths.
- Covered `requireMinimumBalance` rejection and acceptance using the Hardhat signer balance.
- Tightened `requireLiveDeployConfig` so live networks explicitly reject the default Hardhat mnemonic when it is supplied directly.

## Validation

- PASS: `git diff --check`
- PASS: `npx hardhat test test/LaunchReadinessGuards.test.js` completed with `8 passing`.
- PASS: `npx hardhat test` completed with `991 passing` and `63 pending`.
