# Smart Contracts Deploy + Fund Handling Audit

Date: 2026-05-30
Branch: chore/sc-launch-readiness-audit
Dispatch: docs/plans/2026-05-30-sprinters-testnet-dispatch.md, pane 7 / Henry

## Plan

1. Audit Hardhat network configuration for launch-readiness hazards around live RPC defaults, deployer key selection, and local test accounts.
2. Audit deploy scripts for unsafe funding behavior, silent placeholder credentials, and address-reporting gaps.
3. Apply small fixes only where the behavior can be made safer without changing contract semantics.
4. File GitHub issues for any larger launch-readiness gaps that should not be solved in this PR.
5. Validate with `npx hardhat compile` and `npx hardhat test`.

## Initial Preflight

- `gh issue list --repo wrfcoin/smart-contracts --state open --limit 100 --json number,title,url,labels` returned no open issues, so this audit is driven by the sprint dispatch rather than an existing issue.
- The assigned worktree was reset to `origin/main` before this plan note.

## Findings

### Fixed In This PR

- Live Hardhat networks (`testnet`, `sepolia`, `goerli`, `mainnet`) no longer inherit the default Hardhat mnemonic when deployment credentials are absent. Local defaults remain limited to `hardhat` and `testnet_local`.
- `scripts/deploy.js` now refuses live-network deployments without explicit credentials, refuses localhost RPC fallback for live network names, rejects the all-zero private-key placeholder, and checks a minimum deployer balance before deploying.
- `scripts/deploy-aa.js` now uses the same live-network guard, prints configurable paymaster stake/deposit amounts, and checks that the deployer can fund those paymaster transactions before sending them.

### Follow-Up Issues Filed

- smart-contracts #127: retire or harden the legacy `deploy/deploy-contracts.js` path, which still simulates deployments and defaults to an all-zero deployer key with localhost RPC.

## Validation

- PASS: `npx hardhat compile` completed successfully. The compiler emitted pre-existing Solidity warnings, including several contract-size warnings, but no compile errors.
- PASS: `npx hardhat test` completed with `983 passing` and `63 pending`.
