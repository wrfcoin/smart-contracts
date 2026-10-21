'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');

function collectSolidityFiles(root) {
  if (!fs.existsSync(root)) return [];
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...collectSolidityFiles(entryPath));
    if (entry.isFile() && entry.name.endsWith('.sol')) files.push(entryPath);
  }
  return files.sort();
}

function runCommand(command, args, options = {}) {
  return new Promise(resolve => {
    const startedAt = Date.now();
    let stdout = '';
    let stderr = '';
    let settled = false;
    let timer = null;
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env || process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const finish = result => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({
        ...result,
        stdout,
        stderr,
        durationMs: Date.now() - startedAt,
      });
    };
    child.stdout.on('data', chunk => {
      stdout += chunk;
    });
    child.stderr.on('data', chunk => {
      stderr += chunk;
    });
    child.on('error', error =>
      finish({ exitStatus: 127, error: error.message })
    );
    child.on('close', (code, signal) =>
      finish({
        exitStatus: code ?? 1,
        signal: signal || null,
      })
    );
    if (options.timeoutMs) {
      timer = setTimeout(() => {
        child.kill('SIGTERM');
        finish({ exitStatus: 124, error: 'verification command timed out' });
      }, options.timeoutMs);
    }
  });
}

async function writeReport(reportPath, report) {
  await fsp.mkdir(path.dirname(reportPath), { recursive: true });
  await fsp.writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
}

async function runReleaseVerification(options = {}) {
  const contractRoot = path.resolve(
    options.contractRoot ||
      process.env.VERIFICATION_CONTRACT_ROOT ||
      'contracts'
  );
  const reportPath = path.resolve(
    options.reportPath ||
      process.env.VERIFICATION_REPORT_PATH ||
      'formal-verification/reports/release-verification.json'
  );
  const tool = options.tool || process.env.SLITHER_BIN || 'slither';
  const contractFiles = collectSolidityFiles(contractRoot);
  const analysisArgs = [contractRoot, '--fail-high', '--json', '-'];
  const report = {
    generatedAt: new Date().toISOString(),
    classification: 'RELEASE_EVIDENCE',
    command: [tool, ...analysisArgs],
    tool: 'slither',
    toolVersion: null,
    contractRoot,
    contractCount: contractFiles.length,
    executedCheckCount: 0,
    exitStatus: 1,
    status: 'VOID',
    stdout: '',
    stderr: '',
  };

  try {
    if (contractFiles.length === 0) {
      throw new Error(`zero Solidity contracts found under ${contractRoot}`);
    }

    const version = await runCommand(tool, ['--version'], {
      cwd: process.cwd(),
      timeoutMs: options.timeoutMs || 30000,
    });
    report.toolVersion = (version.stdout || version.stderr).trim() || null;
    if (version.exitStatus !== 0 || !report.toolVersion) {
      report.exitStatus = version.exitStatus || 1;
      throw new Error(
        `required tool ${tool} is unavailable: ${version.error || version.stderr.trim() || 'empty version output'}`
      );
    }

    const result = await runCommand(tool, analysisArgs, {
      cwd: process.cwd(),
      timeoutMs:
        options.timeoutMs ||
        Number(process.env.VERIFICATION_TIMEOUT_MS || 300000),
    });
    report.executedCheckCount = 1;
    report.exitStatus = result.exitStatus;
    report.stdout = result.stdout;
    report.stderr = result.stderr;
    report.durationMs = result.durationMs;
    report.status = result.exitStatus === 0 ? 'PASS' : 'RED';
    if (result.exitStatus !== 0) {
      throw new Error(`Slither returned exit ${result.exitStatus}`);
    }
    await writeReport(reportPath, report);
    return report;
  } catch (error) {
    report.error = error.message;
    if (report.executedCheckCount > 0) report.status = 'RED';
    await writeReport(reportPath, report);
    throw Object.assign(new Error(error.message), { report });
  }
}

async function main() {
  const report = await runReleaseVerification();
  console.log(
    `Release verification PASS: ${report.contractCount} contracts, ${report.executedCheckCount} executed check(s), ${report.toolVersion}`
  );
}

if (require.main === module) {
  main().catch(error => {
    console.error(
      `Release verification ${error.report?.status || 'RED'}: ${error.message}`
    );
    process.exitCode = error.report?.exitStatus || 1;
  });
}

module.exports = {
  collectSolidityFiles,
  runCommand,
  runReleaseVerification,
};
