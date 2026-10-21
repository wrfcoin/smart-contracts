# EVM deployment lane

The native WRFCoin testnet EVM deployment lane is **NOT_APPLICABLE/PARKED**.
The native node API is not Ethereum JSON-RPC, and native-testnet release gates
must not invoke a Solidity deployment command or accept Solidity deployment
receipts as evidence of native-testnet readiness.

`npm run deploy:evm:experimental` is the only non-local release-shaped EVM
command. It targets an explicitly configured external EVM and reports:

- the exact RPC URL and actual chain ID;
- `EXPERIMENTAL_EXTERNAL_EVM_DEPLOYMENT_RECEIPTS_REQUIRED` as its evidence class;
- the approved decision record used to reactivate the lane; and
- `NATIVE_TESTNET_EVM=NOT_APPLICABLE/PARKED`.

The command fails before deployment unless all of
`EXTERNAL_EVM_RPC_URL`, `EXTERNAL_EVM_CHAIN_ID`,
`WRFCOIN_APPROVED_EVM_CHAIN_IDS`, `WRFCOIN_EVM_DECISION_RECORD`, and deployer
credentials are present and mutually consistent. Localhost, the native Core4
API, and chain IDs absent from the explicit allowlist are rejected.

The legacy `deploy:testnet`, `testnet:deploy`, and `testnet:full` names are
retained only as fail-closed operator guidance. They never deploy.
