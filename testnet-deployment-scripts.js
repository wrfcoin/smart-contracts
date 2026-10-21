'use strict';

const RETIRED_TESTNET_DEPLOY_MESSAGE = [
  'testnet-deployment-scripts.js is retired for launch deployments.',
  'Native testnet EVM deployment is NOT_APPLICABLE/PARKED.',
  'For an approved external EVM only: `npm run deploy:evm:experimental`.',
  'Use `npm run audit:prepare` for real validation artifacts.',
].join('\n');

if (require.main === module) {
  console.error(RETIRED_TESTNET_DEPLOY_MESSAGE);
  process.exit(1);
}

module.exports = {};
