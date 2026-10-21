'use strict';

const { expect } = require('chai');
const { execFile } = require('child_process');
const fs = require('fs').promises;
const http = require('http');
const os = require('os');
const path = require('path');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);

async function expectCommandFailure(promise) {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error('expected command to fail');
}

describe('release evidence runners', function () {
  this.timeout(30000);

  let directory;
  let rpcServer;
  let rpcUrl;
  let zeroCodeAddress = null;
  let goodManifestPath;
  let emptyManifestPath;
  let fakeSlitherPath;
  let goodContracts;
  let badContracts;
  let emptyContracts;

  before(async function () {
    directory = await fs.mkdtemp(
      path.join(os.tmpdir(), 'wrfcoin-release-runners-')
    );
    goodContracts = path.join(directory, 'contracts-good');
    badContracts = path.join(directory, 'contracts-bad');
    emptyContracts = path.join(directory, 'contracts-empty');
    await Promise.all([
      fs.mkdir(goodContracts),
      fs.mkdir(badContracts),
      fs.mkdir(emptyContracts),
    ]);
    await fs.writeFile(
      path.join(goodContracts, 'Good.sol'),
      '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.28; contract Good {}\n'
    );
    await fs.writeFile(
      path.join(badContracts, 'KnownBad.sol'),
      '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.28; contract KnownBad { string constant MARKER = "KNOWN_BAD"; }\n'
    );

    fakeSlitherPath = path.join(directory, 'fake-slither');
    await fs.writeFile(
      fakeSlitherPath,
      `#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
if (process.argv.includes('--version')) {
  console.log('Slither 0.test-real-runner');
  process.exit(0);
}
function files(root) {
  return fs.readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    const target = path.join(root, entry.name);
    return entry.isDirectory() ? files(target) : [target];
  });
}
const root = process.argv[2];
const bad = files(root).some(file => fs.readFileSync(file, 'utf8').includes('KNOWN_BAD'));
console.log(JSON.stringify({ success: !bad, analyzed: files(root).length }));
process.exit(bad ? 3 : 0);
`
    );
    await fs.chmod(fakeSlitherPath, 0o755);

    const firstAddress = '0x1111111111111111111111111111111111111111';
    const secondAddress = '0x2222222222222222222222222222222222222222';
    goodManifestPath = path.join(directory, 'manifest.json');
    emptyManifestPath = path.join(directory, 'empty-manifest.json');
    await fs.writeFile(
      goodManifestPath,
      JSON.stringify({
        chainId: 1337,
        contracts: [
          { name: 'First', address: firstAddress },
          { name: 'Second', address: secondAddress },
        ],
      })
    );
    await fs.writeFile(
      emptyManifestPath,
      JSON.stringify({ chainId: 1337, contracts: [] })
    );

    rpcServer = http.createServer((request, response) => {
      let body = '';
      request.on('data', chunk => {
        body += chunk;
      });
      request.on('end', () => {
        const payload = JSON.parse(body);
        let result;
        if (payload.method === 'web3_clientVersion') result = 'fixture-rpc/1.0';
        if (payload.method === 'eth_chainId') result = '0x539';
        if (payload.method === 'eth_getCode') {
          result =
            payload.params[0].toLowerCase() === zeroCodeAddress
              ? '0x'
              : '0x6000';
        }
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(
          JSON.stringify({ jsonrpc: '2.0', id: payload.id, result })
        );
      });
    });
    await new Promise(resolve => rpcServer.listen(0, '127.0.0.1', resolve));
    rpcUrl = `http://127.0.0.1:${rpcServer.address().port}`;
  });

  after(async function () {
    await new Promise(resolve => rpcServer.close(resolve));
  });

  it('runs real RPC checks from the canonical monitoring command', async function () {
    const reportPath = path.join(directory, 'monitor-pass.json');
    await execFileAsync('npm', ['run', '--silent', 'testnet:monitor'], {
      env: {
        ...process.env,
        DEPLOYMENT_MANIFEST: goodManifestPath,
        MONITORING_REPORT_PATH: reportPath,
        TESTNET_RPC_URL: rpcUrl,
      },
    });
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report).to.include({
      status: 'PASS',
      exitStatus: 0,
      toolVersion: 'fixture-rpc/1.0',
      contractCount: 2,
      executedCheckCount: 4,
    });
  });

  it('classifies zero-contract monitoring as VOID and exits nonzero', async function () {
    const reportPath = path.join(directory, 'monitor-empty.json');
    await expectCommandFailure(
      execFileAsync('npm', ['run', '--silent', 'testnet:monitor'], {
        env: {
          ...process.env,
          DEPLOYMENT_MANIFEST: emptyManifestPath,
          MONITORING_REPORT_PATH: reportPath,
          TESTNET_RPC_URL: rpcUrl,
        },
      })
    );
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report).to.include({
      status: 'VOID',
      contractCount: 0,
      exitStatus: 1,
    });
  });

  it('runs the required analyzer and records command/version/counts/status', async function () {
    const reportPath = path.join(directory, 'verify-pass.json');
    await execFileAsync('npm', ['run', '--silent', 'testnet:verify'], {
      env: {
        ...process.env,
        SLITHER_BIN: fakeSlitherPath,
        VERIFICATION_CONTRACT_ROOT: goodContracts,
        VERIFICATION_REPORT_PATH: reportPath,
      },
    });
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report).to.include({
      status: 'PASS',
      exitStatus: 0,
      toolVersion: 'Slither 0.test-real-runner',
      contractCount: 1,
      executedCheckCount: 1,
    });
    expect(report.command).to.include('--fail-high');
  });

  it('classifies a missing required tool as VOID and exits nonzero', async function () {
    const reportPath = path.join(directory, 'verify-missing-tool.json');
    await expectCommandFailure(
      execFileAsync('npm', ['run', '--silent', 'testnet:verify'], {
        env: {
          ...process.env,
          SLITHER_BIN: path.join(directory, 'does-not-exist'),
          VERIFICATION_CONTRACT_ROOT: goodContracts,
          VERIFICATION_REPORT_PATH: reportPath,
        },
      })
    );
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report).to.include({
      status: 'VOID',
      exitStatus: 127,
      contractCount: 1,
      executedCheckCount: 0,
    });
  });

  it('turns a disposable known-bad fixture RED through the canonical command', async function () {
    const reportPath = path.join(directory, 'verify-known-bad.json');
    const failure = await expectCommandFailure(
      execFileAsync('npm', ['run', '--silent', 'testnet:verify'], {
        env: {
          ...process.env,
          SLITHER_BIN: fakeSlitherPath,
          VERIFICATION_CONTRACT_ROOT: badContracts,
          VERIFICATION_REPORT_PATH: reportPath,
        },
      })
    );
    expect(failure.code).not.to.equal(0);
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report).to.include({
      status: 'RED',
      exitStatus: 3,
      contractCount: 1,
      executedCheckCount: 1,
    });
  });

  it('classifies zero-contract verification as VOID', async function () {
    const reportPath = path.join(directory, 'verify-empty.json');
    await expectCommandFailure(
      execFileAsync('npm', ['run', '--silent', 'testnet:verify'], {
        env: {
          ...process.env,
          SLITHER_BIN: fakeSlitherPath,
          VERIFICATION_CONTRACT_ROOT: emptyContracts,
          VERIFICATION_REPORT_PATH: reportPath,
        },
      })
    );
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report).to.include({
      status: 'VOID',
      contractCount: 0,
      executedCheckCount: 0,
    });
  });

  it('turns a zero-code monitoring fixture RED', async function () {
    zeroCodeAddress = '0x2222222222222222222222222222222222222222';
    const reportPath = path.join(directory, 'monitor-zero-code.json');
    await expectCommandFailure(
      execFileAsync('npm', ['run', '--silent', 'testnet:monitor'], {
        env: {
          ...process.env,
          DEPLOYMENT_MANIFEST: goodManifestPath,
          MONITORING_REPORT_PATH: reportPath,
          TESTNET_RPC_URL: rpcUrl,
        },
      })
    );
    const report = JSON.parse(await fs.readFile(reportPath, 'utf8'));
    expect(report.status).to.equal('RED');
    expect(report.error).to.include('zero deployed code');
  });
});
