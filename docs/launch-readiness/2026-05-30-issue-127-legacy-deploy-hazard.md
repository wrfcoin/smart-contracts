# Issue 127 Legacy Deploy Hazard

Date: 2026-05-30
Branch: fix/127-legacy-deploy-hazard
Issue: smart-contracts #127

## Plan

1. Retire the simulated legacy deployer behavior in `deploy/deploy-contracts.js`.
2. Keep the legacy entrypoint available only as a compatibility wrapper around the canonical Hardhat deploy path in `scripts/deploy.js`.
3. Require explicit RPC and deployer credentials for `wrfcoin_testnet` and `wrfcoin_mainnet`; do not allow localhost or all-zero key fallbacks.
4. Preserve local development by mapping only local-compatible network names to the local Hardhat deploy path.
5. Validate with `npx hardhat compile` and `npx hardhat test`.

## Issue Preflight

`gh issue view 127 --repo wrfcoin/smart-contracts --json number,title,state,body,url,labels` confirmed the hazard: `deploy/deploy-contracts.js` simulates deployments and defaults to localhost plus an all-zero deployer key.

## Implementation

- Replaced the simulated deployer with a compatibility wrapper that calls `scripts/deploy.js` through Hardhat.
- Mapped legacy WRFCoin network names to canonical Hardhat networks:
  - `wrfcoin_testnet` -> `testnet`
  - `wrfcoin_mainnet` -> `mainnet`
  - `wrfcoin_local` -> `testnet_local`
- Required explicit live RPC and deployer credentials for `wrfcoin_testnet` and `wrfcoin_mainnet`.
- Kept local defaults available only through `wrfcoin_local`.

## Validation

- PASS: `node deploy/deploy-contracts.js` without live env aborts before any deployment attempt: `wrfcoin_testnet requires WRFCOIN_TESTNET_RPC or TESTNET_RPC_URL; refusing localhost fallback`.
- PASS: local env mapping smoke check maps `WRFCOIN_LOCAL_RPC` and `WRFCOIN_DEPLOYER_KEY` to the canonical Hardhat variables.
- PASS: `git diff --check`
- PASS: `npx hardhat compile` completed successfully. Solidity emitted pre-existing warnings, including contract-size warnings, but no compile errors.
- PASS: `npx hardhat test` completed with `983 passing` and `63 pending`.
