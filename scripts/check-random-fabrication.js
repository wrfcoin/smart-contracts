'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
function scanFiles(root, files) {
  const findings = [];
  let scanned = 0;
  for (const file of files) {
    if (!file.endsWith('.js') || /(^|\/)(test|tests|__tests__)\//.test(file)) continue;
    if (!fs.existsSync(path.join(root, file))) continue;
    scanned += 1;
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    // Address/hash construction and fabricated verdicts. Not a general JS
    // security parser; real code/tree and planted-file controls pin this class.
    if (/["'](?:0x|Qm)["']\s*\+\s*Math\.random\s*\(/.test(source) || /\bverified\s*:\s*Math\.random\s*\(/.test(source)) findings.push(file);
  }
  return { scanned, findings };
}
function scanTracked(root) {
  const files = execFileSync('git', ['ls-files', '-z', '--', '*.js'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean);
  return scanFiles(root, files);
}
if (require.main === module) {
  const result = scanTracked(path.resolve(__dirname, '..'));
  console.log(`${result.findings.length || !result.scanned ? 'FAIL' : 'PASS'} scanned=${result.scanned} findings=${result.findings.length}`);
  for (const file of result.findings) console.error(file);
  process.exitCode = result.findings.length || !result.scanned ? 1 : 0;
}
module.exports = { scanFiles, scanTracked };
