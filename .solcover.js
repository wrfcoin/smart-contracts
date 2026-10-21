module.exports = {
  // Keep coverage focused on production contracts; mock and harness code makes
  // the full repo coverage pass too heavy for the hosted runner.
  skipFiles: ['mocks', 'test-helpers', 'SimpleMockEnhancedCarbonCredits.sol', 'WRFTokenTestnet.sol'],
  // The repo compiles with viaIR enabled, so let solidity-coverage use the
  // faster minimum IR instrumentation path when it can.
  irMinimum: true,
  // Coverage runs need more time than the default Hardhat test timeout when the
  // runner is under load.
  mocha: {
    timeout: 1200000,
  },
  // Large skipped folders can still be expensive to walk; deepSkip keeps the
  // coverage pass from spending time instrumenting ignored trees.
  deepSkip: true,
};
