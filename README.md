# WRFCoin Smart Contracts

Solidity reference implementations for planned WRFCoin protocol features.

**These mirror planned protocol features and are NOT part of the running testnet.** Native-testnet deployment commands are parked; local Hardhat results are not evidence of a deployed EVM network.

## Public testnet

Public testnet launch: **2026-10-22**.

This is a test network. It may be reset without notice. Balances and tokens have no monetary value. No migration to mainnet is promised or implied. Please attach no production bridges, exchange listings or irreplaceable assets.

- [WRFCoin website](https://wrfcoin.com)
- [Public testnet quickstart](https://github.com/wrfcoin/docs/blob/main/testnet/quickstart.md)
- [Help and bug reports](https://github.com/wrfcoin/testnet-support)
- [Security reporting](SECURITY.md)

## Today and planned work

| Status | Scope |
| --- | --- |
| Available in this repository today | Solidity sources, local Hardhat compilation/tests, and guards against unsupported readiness claims. |
| Planned / not available here | EVM deployment and live protocol integration remain experimental future work. No audit certification, signed release or production readiness is claimed. |

## Build and use

See [CONTRIBUTING.md](CONTRIBUTING.md#build-and-test) for prerequisites and build/test commands. CI results apply only to the named commit and executed checks; they do not prove deployment.

Licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

## Local development

Use Node.js 18+ and npm with the checked-in lockfile:

```sh
npm ci
npm run compile
npm test
npm run lint:claims
```

The [package scripts](package.json) define local checks. Slither static analysis requires a separate installation; missing tools or zero executed tests are not successful validation.

## Source map

- [Token reference](contracts/WRFToken.sol)
- [Governance reference](contracts/CommunityGovernance.sol)
- [Staking reference](contracts/MultiAssetStaking.sol)
- [Readiness guards](test/LaunchReadinessGuards.test.js)

These are experimental implementations, not claims of conformance, certification or deployed protection.

---

_Note: issue and pull-request numbers mentioned in this repository refer to a private archive that predates this public repository; they are not links into this repo._
