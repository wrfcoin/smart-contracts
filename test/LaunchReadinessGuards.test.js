const { expect } = require('chai');
const { ethers } = require('hardhat');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const {
  describeExperimentalEvmTarget,
  isLocalNetwork,
  requireExperimentalEvmApproval,
  requireLiveDeployConfig,
  requireMinimumBalance,
} = require('../scripts/lib/launchReadiness');

const DEFAULT_HARDHAT_MNEMONIC = 'test test test test test test test test test test test junk';
const ZERO_PRIVATE_KEY = `0x${'0'.repeat(64)}`;
const VALID_PRIVATE_KEY = `0x${'1'.repeat(64)}`;
const LIVE_NETWORK = {
  name: 'testnet',
  config: {
    url: 'https://rpc.testnet.wrfcoin.invalid',
  },
};

describe('Launch readiness deploy guards', function () {
  it('runs the tracked-document readiness claims gate against a non-empty tree', function () {
    const output = execFileSync(
      process.execPath,
      [path.join(__dirname, '..', 'scripts', 'check-readiness-claims.js')],
      { cwd: path.join(__dirname, '..'), encoding: 'utf8' }
    );

    expect(output).to.match(/PASS scanned=[1-9]\d* markdown_files/);
  });

  describe('legacy testnet deploy orchestrator retirement', function () {
    const packageJson = JSON.parse(
      fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8')
    );

    it('parks native-testnet names and exposes only an experimental external EVM command', function () {
      expect(packageJson.scripts['testnet:deploy'])
        .to.equal('node scripts/parked-native-testnet.js');
      expect(packageJson.scripts['testnet:full'])
        .to.equal('node scripts/parked-native-testnet.js');
      expect(packageJson.scripts['deploy:testnet'])
        .to.equal('node scripts/parked-native-testnet.js');
      expect(packageJson.scripts['deploy:evm:experimental'])
        .to.include('scripts/deploy.js --network external_evm');
    });

    it('removes the legacy orchestrator from launch-facing package scripts', function () {
      for (const [name, command] of Object.entries(packageJson.scripts)) {
        expect(
          command,
          `${name} must not invoke retired testnet-deployment-scripts.js`
        ).to.not.include('testnet-deployment-scripts.js');
      }
    });

    it('direct execution of the legacy orchestrator is retired with operator guidance', function () {
      const script = fs.readFileSync(
        path.join(__dirname, '..', 'testnet-deployment-scripts.js'),
        'utf8'
      );

      expect(script).to.include('testnet-deployment-scripts.js is retired');
      expect(script).to.include('npm run deploy:evm:experimental');
      expect(script).to.match(/process\.exit\(1\)/);
    });
  });

  describe('experimental external EVM boundary', function () {
    const approvedEnv = {
      PRIVATE_KEY: VALID_PRIVATE_KEY,
      WRFCOIN_APPROVED_EVM_CHAIN_IDS: '11155111,84532',
      WRFCOIN_EVM_DECISION_RECORD: 'ADR-3208-successor-approved',
    };
    const externalNetwork = {
      name: 'external_evm',
      config: {
        url: 'https://sepolia.example.invalid',
        chainId: 11155111,
      },
    };

    it('accepts only an allowlisted external target with an explicit decision record', function () {
      expect(() => requireLiveDeployConfig(externalNetwork, approvedEnv)).not.to.throw();
      expect(describeExperimentalEvmTarget(externalNetwork, 11155111, approvedEnv))
        .to.deep.equal({
          target: 'https://sepolia.example.invalid',
          chainId: 11155111,
          decisionRecord: 'ADR-3208-successor-approved',
          evidenceClass: 'EXPERIMENTAL_EXTERNAL_EVM_DEPLOYMENT_RECEIPTS_REQUIRED',
          nativeTestnet: 'NOT_APPLICABLE/PARKED',
        });
    });

    it('rejects localhost, native Core4 API URLs, and unapproved chain ids', function () {
      expect(() => requireExperimentalEvmApproval({
        name: 'external_evm',
        config: { url: 'http://127.0.0.1:8545', chainId: 11155111 },
      }, approvedEnv)).to.throw('rejects localhost');
      expect(() => requireExperimentalEvmApproval({
        name: 'external_evm',
        config: { url: 'https://native.example.invalid:8080', chainId: 11155111 },
      }, approvedEnv)).to.throw('rejects native Core4 API URLs');
      expect(() => requireExperimentalEvmApproval({
        name: 'external_evm',
        config: { url: 'https://evm.example.invalid', chainId: 99999 },
      }, approvedEnv)).to.throw('not listed in WRFCOIN_APPROVED_EVM_CHAIN_IDS');
    });

    it('rejects missing approval records and RPC chain-id mismatches', function () {
      expect(() => requireExperimentalEvmApproval(externalNetwork, {
        ...approvedEnv,
        WRFCOIN_EVM_DECISION_RECORD: '',
      })).to.throw('requires WRFCOIN_EVM_DECISION_RECORD');
      expect(() => describeExperimentalEvmTarget(externalNetwork, 84532, approvedEnv))
        .to.throw('RPC reports chain id 84532');
    });
  });

  describe('deploy entrypoint coverage', function () {
    const guardedDeployEntrypoints = [
      '../scripts/deploy.js',
      '../scripts/deploy-aa.js',
      '../scripts/deploy-ai-dao.js',
      '../scripts/deploy-carbon-lottery.js',
      '../scripts/deploy-mvp.js',
      '../scripts/deploy-nfts.js',
      '../scripts/deploy-storage-endowment.js',
      '../deploy/deploy-btc-stake-registry.js',
      '../deploy/deploy-multi-asset-staking.js',
      '../deploy/deploy-nft-marketplace.js',
      '../deploy/deploy-slashing-mechanism.js',
      '../deploy/deploy-stake-delegation.js',
    ];

    for (const relativePath of guardedDeployEntrypoints) {
      it(`${relativePath} calls requireLiveDeployConfig`, function () {
        const script = fs.readFileSync(
          path.join(__dirname, relativePath),
          'utf8'
        );

        expect(script).to.include('requireLiveDeployConfig');
        expect(script).to.match(/requireLiveDeployConfig\(/);
      });
    }
  });

  describe('requireLiveDeployConfig', function () {
    it('skips live guards for local networks', function () {
      expect(isLocalNetwork('hardhat')).to.equal(true);
      expect(isLocalNetwork('localhost')).to.equal(true);
      expect(isLocalNetwork('testnet_local')).to.equal(true);

      expect(() => requireLiveDeployConfig({
        name: 'hardhat',
        config: { url: 'http://127.0.0.1:8545' },
      }, {})).to.not.throw();
    });

    it('rejects live deployment without explicit deploy credentials', function () {
      expect(() => requireLiveDeployConfig(LIVE_NETWORK, {}))
        .to.throw('requires PRIVATE_KEY or MNEMONIC');
    });

    it('rejects the default Hardhat mnemonic on live networks', function () {
      expect(() => requireLiveDeployConfig(LIVE_NETWORK, {
        MNEMONIC: DEFAULT_HARDHAT_MNEMONIC,
      })).to.throw('refuses the default Hardhat mnemonic');
    });

    it('rejects an all-zero private key on live networks', function () {
      expect(() => requireLiveDeployConfig(LIVE_NETWORK, {
        PRIVATE_KEY: ZERO_PRIVATE_KEY,
      })).to.throw('all-zero placeholder');
    });

    it('rejects localhost RPC fallback on live networks', function () {
      expect(() => requireLiveDeployConfig({
        name: 'testnet',
        config: { url: 'http://127.0.0.1:8545' },
      }, {
        PRIVATE_KEY: VALID_PRIVATE_KEY,
      })).to.throw('requires an explicit live RPC URL');

      expect(() => requireLiveDeployConfig({
        name: 'mainnet',
        config: { url: 'http://localhost:8545' },
      }, {
        PRIVATE_KEY: VALID_PRIVATE_KEY,
      })).to.throw('requires an explicit live RPC URL');
    });

    it('accepts explicit live RPC and deploy credentials', function () {
      expect(() => requireLiveDeployConfig(LIVE_NETWORK, {
        PRIVATE_KEY: VALID_PRIVATE_KEY,
      })).to.not.throw();

      expect(() => requireLiveDeployConfig(LIVE_NETWORK, {
        MNEMONIC: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
      })).to.not.throw();
    });
  });

  describe('requireMinimumBalance', function () {
    it('rejects deployers below the required minimum balance', async function () {
      const [deployer] = await ethers.getSigners();

      try {
        await requireMinimumBalance(ethers, deployer.address, '10000001');
        throw new Error('expected requireMinimumBalance to reject');
      } catch (error) {
        expect(error.message).to.include('is below required 10000001 ETH');
      }
    });

    it('accepts deployers at or above the required minimum balance', async function () {
      const [deployer] = await ethers.getSigners();
      const balance = await ethers.provider.getBalance(deployer.address);

      expect(await requireMinimumBalance(ethers, deployer.address, '0.05'))
        .to.equal(balance);
    });
  });
});

// #246: executable local authority; no live RPC or deploy.
describe('retired fabrication removal', function () {
  const root = path.join(__dirname, '..');
  const { scanFiles, scanTracked } = require('../scripts/check-random-fabrication');
  it('no tracked JS outside tests fabricates addresses, hashes or verdicts', function () {
    const result = scanTracked(root);
    expect(result.scanned).to.be.greaterThan(10);
    expect(result.findings).to.deep.equal([]);
  });
  it('planted random-address/hash/verdict patterns are REAL-RED controls', function () {
    const temp = fs.mkdtempSync(path.join(require('os').tmpdir(), 'loop-b18-pattern-'));
    try {
      for (const [i, source] of ["const address = '0x' + Math.random();", 'const hash = "Qm" + Math.random();', 'const result = {verified: Math.random() > 0.1};'].entries()) {
        const name = `planted-${i}.js`; fs.writeFileSync(path.join(temp, name), source);
        expect(scanFiles(temp, [name]).findings).to.deep.equal([name]);
      }
      fs.writeFileSync(path.join(temp, 'clean.js'), 'const address = actualReceipt.contractAddress;');
      expect(scanFiles(temp, ['clean.js'])).to.deep.equal({scanned:1,findings:[]});
    } finally {fs.rmSync(temp, {recursive:true,force:true});}
  });
  it('npm exposes no Goerli command or deploy command rejected by the parked guard', function () {
    const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
    for (const [name, cmd] of Object.entries(pkg.scripts)) {
      expect(`${name} ${cmd}`).not.to.match(/goerli/i);
      if (name.startsWith('deploy:')) expect(cmd).not.to.match(/--network (mainnet|sepolia)\b/);
    }
  });
  it('formal:verify alias fails closed with the static-analysis rename notice', function () {
    const result = require('child_process').spawnSync('npm', ['run','formal:verify'], {cwd:root,encoding:'utf8'});
    expect(result.status).to.equal(1);expect(result.stdout).to.include('renamed: static:analyze');
  });
  it('retired orchestrator exports no callable fabrication classes', function () {
    expect(require('../testnet-deployment-scripts')).to.deep.equal({});
  });
  it('missing Slither remains VOID with zero executed checks', async function () {
    const {runReleaseVerification} = require('../testnet-formal-verification');
    const temp=fs.mkdtempSync(path.join(require('os').tmpdir(),'loop-b18-slither-'));
    try {
      const report=path.join(temp,'report.json');
      let failed=false;
      try {await runReleaseVerification({tool:path.join(temp,'absent-slither'),contractRoot:path.join(root,'contracts'),reportPath:report});}catch {failed=true;}
      expect(failed).to.equal(true);const result=JSON.parse(fs.readFileSync(report,'utf8'));
      expect(result.status).to.equal('VOID');expect(result.executedCheckCount).to.equal(0);
    } finally {fs.rmSync(temp,{recursive:true,force:true});}
  });
});

describe('unconfigured integration adapters fail closed', function () {
  for (const file of ['integrations/contract-integration-server.js','contracts/integrations/contract-integration-server.js']) {
    // Load only the class definitions; never construct an HTTP server/provider.
    const source = fs.readFileSync(path.join(__dirname,'..',file),'utf8');
    const context = {module:{exports:{}},require:()=>({}),process:{env:{}},console};
    require('vm').runInNewContext(source,context,{filename:file});
    const prototype = context.module.exports.ContractIntegrationServer.prototype;
    for (const method of ['uploadToIPFS','submitPollutionData','getPollutionData','registerSensor','submitResearch','submitReview','registerCarbonProject','purchaseCarbonCredit','submitGrantProposal','submitMilestone','createTrainingJob','submitTrainingContribution']) {
      it(`${file} ${method} refuses to invent a result`,async function () {
        let error;
        try {await prototype[method].call({},{});}catch(caught){error=caught;}
        expect(error?.message).to.match(/not configured/);
      });
    }
  }
});
