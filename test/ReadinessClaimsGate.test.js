const { expect } = require('chai');
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const gate = path.join(__dirname, '..', 'scripts', 'check-readiness-claims.js');

function fixture(files = {}, allowlist = []) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'readiness-claims-'));
  execFileSync('git', ['init', '--quiet'], { cwd: root });
  for (const [relativePath, contents] of Object.entries(files)) {
    const target = path.join(root, relativePath);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, contents);
  }
  fs.mkdirSync(path.join(root, 'config'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'config', 'readiness-claims-allowlist.json'),
    `${JSON.stringify(allowlist, null, 2)}\n`
  );
  execFileSync('git', ['add', '.'], { cwd: root });
  return root;
}

function run(root) {
  return spawnSync(process.execPath, [gate], {
    cwd: root,
    env: { ...process.env, READINESS_CLAIMS_ROOT: root },
    encoding: 'utf8',
  });
}

describe('Readiness claims gate', function () {
  const roots = [];
  afterEach(function () {
    while (roots.length) fs.rmSync(roots.pop(), { recursive: true, force: true });
  });

  it('clean_tree_passes', function () {
    const root = fixture({ 'README.md': 'No unsupported launch claims.\n' });
    roots.push(root);
    const result = run(root);
    expect(result.status, result.stderr).to.equal(0);
    expect(result.stdout).to.match(/PASS scanned=1 markdown_files/);
  });

  it('planted_claim_fails', function () {
    const root = fixture({ 'claim.md': 'APPROVED FOR PRODUCTION DEPLOYMENT\n' });
    roots.push(root);
    const result = run(root);
    expect(result.status).to.equal(1);
    expect(result.stderr).to.include('claim.md:1');
  });

  it('allowlist_entry_without_evidence_url_fails', function () {
    const root = fixture(
      { 'claim.md': 'NOT production ready\n' },
      [{ path: 'claim.md', pattern: 'NOT production ready', reason: 'negated statement' }]
    );
    roots.push(root);
    const result = run(root);
    expect(result.status).to.equal(1);
    expect(result.stderr).to.include('requires non-empty evidence_url');
  });

  it('archive_dir_is_exempt', function () {
    const root = fixture({
      'README.md': 'Current repository status is documented without readiness claims.\n',
      'docs/archive/claim.md': 'OFFICIAL SECURITY CERTIFICATION\n',
    });
    roots.push(root);
    const result = run(root);
    expect(result.status, result.stderr).to.equal(0);
    expect(result.stdout).to.match(/scanned=1 markdown_files/);
  });

  it('zero_files_scanned_is_void', function () {
    const root = fixture({ 'docs/archive/claim.md': 'PRODUCTION READY\n' });
    roots.push(root);
    const result = run(root);
    expect(result.status).to.equal(2);
    expect(result.stderr).to.include('VOID: zero markdown files scanned');
  });
});
