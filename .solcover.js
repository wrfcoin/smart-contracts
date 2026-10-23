module.exports = {
  // Keep coverage focused on production contracts; mock and harness code makes
  // the full repo coverage pass too heavy for the hosted runner.
  skipFiles: ['mocks', 'test-helpers', 'SimpleMockEnhancedCarbonCredits.sol', 'WRFTokenTestnet.sol'],
  // irMinimum turned the optimizer off for coverage builds, and with viaIR
  // that fails on CarbonBasketToken with "YulException: Variable expr_15 is 1
  // too deep in the stack". Leave it off so solidity-coverage keeps the
  // optimizer running under viaIR (its default for viaIR projects). Production
  // solc settings in hardhat.config.js are untouched.
  irMinimum: false,
  // Coverage runs need more time than the default Hardhat test timeout when the
  // runner is under load.
  mocha: {
    timeout: 1200000,
    // Excluded from the coverage run only (they all run in `hardhat test`):
    // - DoS gas-bomb simulations (10k-250k-operation nested loops): coverage
    //   traces every opcode and exhausts the 4 GB test heap (CI uses
    //   --max-old-space-size=4096).
    // - "Mass proposal creation DoS" asserts a wall-clock degradation ratio and
    //   "genesis airdrop via quality score" asserts a time-accrued amount; both
    //   shift under the slower instrumented run.
    grep: 'nested loop complexity|Nested loop complexity|Nested operation complexity|Array processing complexity|Mass proposal creation DoS|inflating its own genesis airdrop via quality score',
    invert: true,
  },
  // Large skipped folders can still be expensive to walk; deepSkip keeps the
  // coverage pass from spending time instrumenting ignored trees.
  deepSkip: true,
};
