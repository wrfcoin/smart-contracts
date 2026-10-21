const fs = require('fs/promises');
const path = require('path');

async function main() {
  const outDir = path.join(process.cwd(), 'test-reports', 'formal-verification');
  await fs.mkdir(outDir, { recursive: true });

  const artifact = {
    generatedAt: new Date().toISOString(),
    suite: 'CarbonCreditMarketFormalVerification',
    command: 'npm run formal:market',
    specs: [
      'amm_configuration_sorted_and_bounded',
      'amm_pricing_bounded_by_reserves',
      'router_pair_lookup_symmetric',
      'router_route_shape_consistent',
    ],
    contract: 'contracts/security/CarbonCreditMarketFormalVerification.sol',
    testFile: 'test/CarbonCreditMarketFormalVerification.test.js',
  };

  await fs.writeFile(
    path.join(outDir, 'carbon-credit-market-invariants.json'),
    JSON.stringify(artifact, null, 2)
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
