# Contributing

Read the [README](README.md) for this repository's purpose and technical details.
Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build and test

Use Node.js 20, matching pull-request CI:

```sh
npm ci
npm run compile
npx hardhat test test/launch-blockers.test.js test/SecureBridgeIntegration.security.test.js test/ProofOfObservationMintGate.test.js
npm run lint
npm run lint:claims
npm run type-check
```

Use `npm test` for the wider Hardhat suite. The type-check script currently reports that this workspace has no TypeScript files. Read the README for the native-testnet and experimental EVM scope before proposing deployment changes.

## Branch and pull request flow

Fork the repository and create a focused branch from current `main`.
Add tests for behavior changes and run the checks above before submitting a pull request.
Describe the change, its motivation, and validation results; use `Refs #N` to link the issue.
Keep unrelated changes separate and wait for maintainer review before merging.
Report vulnerabilities through [SECURITY.md](SECURITY.md).
