const fs = require('fs/promises');
const path = require('path');

async function main() {
  const outDir = path.join(process.cwd(), 'test-reports', 'formal-verification');
  await fs.mkdir(outDir, { recursive: true });

  const artifact = {
    generatedAt: new Date().toISOString(),
    suite: 'FormalVerificationSpecs',
    command: 'npm run formal:governance',
    specs: [
      'slashing_totalWithinStake',
      'appeal_reversalRestoresState',
      'parity_actorNeutral',
      'lock_durationBound',
      'evidence_immutableHash',
    ],
    contract: 'contracts/governance/FormalVerificationSpecs.sol',
    testFile: 'test/FormalVerificationSpecs.test.js',
    counterexampleWorkflow: 'docs/security/FORMAL_COUNTEREXAMPLE_WORKFLOW.md',
  };

  await fs.writeFile(
    path.join(outDir, 'governance-invariants.json'),
    JSON.stringify(artifact, null, 2)
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
