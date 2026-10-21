/**
 * Hardhat Documentation Generation Configuration
 *
 * Generates comprehensive documentation for smart contracts including:
 * - Contract ABIs and interfaces
 * - Function signatures and parameters
 * - Event definitions
 * - Usage examples and deployment guides
 */

module.exports = {
  // Source directory for contracts
  sources: './contracts',

  // Output directory for generated documentation
  outputDir: './docs/generated/contracts',

  // Templates directory
  templates: './docs/templates/contracts',

  // Documentation theme
  theme: 'markdown',

  // Include patterns
  include: ['contracts/**/*.sol'],

  // Exclude patterns
  exclude: [
    'contracts/test/**/*.sol',
    'contracts/mocks/**/*.sol',
    'contracts/libraries/external/**/*.sol',
    'contracts/WRFGovernor.sol',
  ],

  // Page generation
  pages: 'files',

  // Output format
  outputFormat: 'html',

  // Solidity compiler settings
  solcSettings: {
    version: '0.8.19',
    optimizer: {
      enabled: true,
      runs: 200,
    },
  },

  // Custom rendering options
  helpers: {
    // Custom helper to format function signatures
    formatSignature: function (signature) {
      return signature.replace(/([a-zA-Z0-9_]+)\s*\(/g, '<strong>$1</strong>(');
    },

    // Helper to generate example usage
    generateExample: function (contractName, functionName) {
      return `
\`\`\`javascript
// Example usage of ${contractName}.${functionName}()
const contract = await ethers.getContractFactory("${contractName}");
const instance = await contract.deploy();
await instance.${functionName}();
\`\`\`
      `;
    },
  },

  // Contract categorization
  contractCategories: {
    Tokens: ['WRFToken', 'BaseERC20Token', 'RewardToken'],
    Governance: ['WRFGovernor', 'BasicDAO', 'TimelockController'],
    DeFi: ['BasicAMM', 'LiquidityPool', 'YieldFarming'],
    NFT: ['ComputationalNFT', 'WeatherNFT', 'CarbonCreditNFT'],
    Infrastructure: ['WeatherOracle', 'CrossChainBridge', 'Proxy'],
    Utilities: ['Multicall', 'TimelockController', 'AccessControl'],
  },

  // Documentation sections to include
  sections: {
    overview: true,
    functions: true,
    events: true,
    modifiers: true,
    structs: true,
    enums: true,
    errors: true,
    inheritance: true,
    usage: true,
    security: true,
    deployment: true,
  },

  // Custom metadata
  metadata: {
    title: 'WRFCoin Smart Contract Documentation',
    description:
      'Comprehensive documentation for WRFCoin platform smart contracts',
    version: '1.0.0',
    author: 'WRFCoin Development Team',
    repository: 'https://github.com/wrfcoin/core',
    license: 'MIT',
  },

  // Security annotations
  securityNotes: {
    onlyOwner: 'This function can only be called by the contract owner.',
    nonReentrant: 'This function is protected against reentrancy attacks.',
    whenNotPaused:
      'This function can only be called when the contract is not paused.',
    payable: 'This function accepts Ether payments.',
    external: 'This function can only be called from outside the contract.',
    internal:
      'This function can only be called from within the contract or derived contracts.',
  },

  // Gas estimation notes
  gasEstimation: true,

  // Include source code
  includeSource: true,

  // Generate deployment scripts documentation
  deploymentDocs: true,

  // Custom CSS for styling
  customCSS: './docs/assets/contract-docs.css',

  // Navigation configuration
  navigation: {
    showPrivate: false,
    showInternal: true,
    groupByCategory: true,
    sortAlphabetically: true,
  },

  // Output file naming
  fileNaming: {
    contract: '{{contractName}}.md',
    index: 'index.md',
    category: '{{categoryName}}/index.md',
  },

  // Include NatSpec documentation
  natspec: {
    title: true,
    author: true,
    notice: true,
    dev: true,
    param: true,
    return: true,
    custom: true,
  },
};
