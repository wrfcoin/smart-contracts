#!/usr/bin/env node
'use strict';

// Regenerates docs/coverage/* from the working tree. Run from anywhere:
//   node scripts/generate-coverage-inventory.js
// Output is deterministic for a given tree: same inputs, byte-identical outputs.
// The method is documented in the generated docs/coverage/inventory.md; the
// rules below ARE the method — if you change them, the doc section updates with
// them because it is emitted from the same constants.

const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const repo = path.resolve(__dirname, '..');
const sh = (cmd) => cp.execSync(cmd, { cwd: repo, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });

// ---------------------------------------------------------------------------
// Method constants
// ---------------------------------------------------------------------------

// Row unit: one row per tracked .sol file under contracts/. contract_name is
// the file basename. Top-level declarations that differ from the basename are
// listed in extra_decls so multi-contract files hide nothing.
const CONTRACT_PATHSPEC = ['contracts/*.sol', 'contracts/**/*.sol'];

// covered=yes requires one of exactly two signals:
//  (a) focused: a test file matching *.test.js / *.test.ts whose basename's
//      first dot-delimited token equals the contract name
//      (e.g. BTCStakeRegistry.focused.test.js, CarbonCreditInsurance.pause.test.js);
//  (b) bundle: the contract is instantiated via getContractFactory('Name') in
//      one of the explicit multi-contract tier guard bundles
//      (test/coverage-tier*-guarded.test.js). Bundle credit applies to
//      implementation-class rows only — mocks and helpers deployed there are
//      scaffolding, not targets.
// A bare name mention anywhere under test/ is NOT coverage; it is reported
// separately as referenced_test_count for transparency.
const FOCUSED_FILE_RE = /\.test\.(js|ts)$/;
const BUNDLE_FILE_RE = /^test\/coverage-tier\d+-.*-guarded\.test\.js$/;
const FACTORY_RE = /getContractFactory\(\s*['"]([A-Za-z0-9_]+)['"]/g;

// class is path-derived, nothing else.
function classify(p) {
  if (p.startsWith('contracts/interfaces/')) return 'interface';
  if (p.startsWith('contracts/mocks/')) return 'mock';
  if (p.startsWith('contracts/test-helpers/')) return 'test-helper';
  return 'implementation';
}

// risk_score: sum of the weights of the blast-radius groups whose pattern
// matches the contract source; each group counts at most once per contract.
const RISK_GROUPS = [
  ['minting', 5, /\b_?mint\w*\s*\(/i],
  ['fund-custody', 5, /payable|msg\.value|address\(this\)\.balance/],
  ['fund-movement', 5, /\b(withdraw|sweep|rescue|safeTransfer|transferFrom)\w*\s*\(/i],
  ['treasury', 4, /\btreasury\b/i],
  ['bridge-validation', 4, /\b(bridge|crossChain|cross_chain|relayer)\w*\b/i],
  ['upgrade-or-delegate', 4, /\b(delegatecall|upgradeTo|selfdestruct)\b/i],
  ['oracle-input', 3, /\b(oracle|priceFeed|latestRoundData|aggregator)\w*\b/i],
  ['access-control', 2, /\b(onlyOwner|onlyRole|AccessControl|Ownable)\b/],
];

const DECL_RE = /^\s*(?:abstract\s+)?(?:contract|library|interface)\s+([A-Za-z0-9_]+)/gm;

// ---------------------------------------------------------------------------
// Scan
// ---------------------------------------------------------------------------

const solFiles = sh(`git ls-files -- ${CONTRACT_PATHSPEC.map((p) => `'${p}'`).join(' ')}`)
  .trim().split('\n').filter(Boolean).sort();

const testFiles = sh(`git ls-files -- 'test/*' 'test/**/*'`)
  .trim().split('\n').filter((f) => /\.(js|ts|sol)$/.test(f)).sort();

const testContents = new Map(testFiles.map((f) => [f, fs.readFileSync(path.join(repo, f), 'utf8')]));

// focused index: first dot-token of *.test.js|ts basenames -> files
const focusedIndex = new Map();
for (const f of testFiles) {
  if (!FOCUSED_FILE_RE.test(f)) continue;
  const token = path.basename(f).split('.')[0];
  if (!focusedIndex.has(token)) focusedIndex.set(token, []);
  focusedIndex.get(token).push(f);
}

// bundle targets
const bundleFiles = testFiles.filter((f) => BUNDLE_FILE_RE.test(f));
const bundleTargets = new Set();
for (const f of bundleFiles) {
  for (const m of testContents.get(f).matchAll(FACTORY_RE)) bundleTargets.add(m[1]);
}

const rows = solFiles.map((p) => {
  const name = path.basename(p, '.sol');
  const cls = classify(p);
  const src = fs.readFileSync(path.join(repo, p), 'utf8');

  const extraDecls = [...src.matchAll(DECL_RE)].map((m) => m[1]).filter((d) => d !== name);

  const focusedFiles = (focusedIndex.get(name) || []).slice().sort();
  const bundleGuarded = cls === 'implementation' && bundleTargets.has(name);

  const nameRe = new RegExp(`\\b${name}\\b`);
  const referenced = testFiles.filter((f) => nameRe.test(testContents.get(f)));

  const riskGroups = RISK_GROUPS.filter(([, , re]) => re.test(src));
  const riskScore = riskGroups.reduce((s, [, w]) => s + w, 0);

  const signal = focusedFiles.length > 0 ? 'focused' : bundleGuarded ? 'bundle' : 'none';
  return {
    path: p, name, cls,
    covered: signal !== 'none',
    signal,
    focusedFiles, bundleGuarded,
    referencedCount: referenced.length,
    riskScore,
    riskGroups: riskGroups.map(([g]) => g),
    extraDecls: [...new Set(extraDecls)].sort(),
  };
});

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

const outDir = path.join(repo, 'docs', 'coverage');
fs.mkdirSync(outDir, { recursive: true });
const q = (s) => `"${String(s).replace(/"/g, '""')}"`;

const rawCsv = [
  'contract_path,contract_name,class,covered,coverage_signal,focused_test_count,focused_test_files,bundle_guarded,referenced_test_count,risk_score,risk_groups,extra_decls',
  ...rows.map((r) => [
    r.path, r.name, r.cls, r.covered ? 'yes' : 'no', r.signal,
    r.focusedFiles.length, q(r.focusedFiles.join(';')), r.bundleGuarded ? 'yes' : 'no',
    r.referencedCount, r.riskScore, q(r.riskGroups.join(';')), q(r.extraDecls.join(';')),
  ].join(',')),
].join('\n') + '\n';
fs.writeFileSync(path.join(outDir, 'contract-coverage-inventory-raw.csv'), rawCsv);

const uncovered = rows.filter((r) => !r.covered)
  .sort((a, b) => b.riskScore - a.riskScore || a.path.localeCompare(b.path));
const rankCsv = (list) => [
  'rank,contract_path,contract_name,class,referenced_test_count,risk_score,risk_groups',
  ...list.map((r, i) => [i + 1, r.path, r.name, r.cls, r.referencedCount, r.riskScore, q(r.riskGroups.join(';'))].join(',')),
].join('\n') + '\n';
fs.writeFileSync(path.join(outDir, 'uncovered-risk-ranking.csv'), rankCsv(uncovered));
const uncoveredProd = uncovered.filter((r) => r.cls === 'implementation');
fs.writeFileSync(path.join(outDir, 'uncovered-risk-ranking-production.csv'), rankCsv(uncoveredProd));

// summary numbers.
// The stamp hashes the INPUT trees (contracts/ + test/), not HEAD: a HEAD
// stamp changes on every commit — including the commit of this file — making
// inventory.md non-idempotent by construction and foreclosing the
// `regenerate && git diff --quiet` freshness gate (#189 review).
const base = sh('git ls-tree HEAD contracts test | git hash-object --stdin').trim().slice(0, 7);
const dirty = sh('git status --porcelain -- contracts/ test/').trim() ? ' (contracts/ or test/ dirty)' : '';
const byClass = {};
for (const r of rows) {
  byClass[r.cls] = byClass[r.cls] || { total: 0, covered: 0 };
  byClass[r.cls].total++;
  if (r.covered) byClass[r.cls].covered++;
}
const covered = rows.filter((r) => r.covered);
const refOnly = rows.filter((r) => !r.covered && r.referencedCount > 0);
const looseYes = rows.filter((r) => r.referencedCount > 0);

const md = `# Smart-contract coverage inventory (strict method)

Generated by \`scripts/generate-coverage-inventory.js\` for source tree \`${base}\`${dirty}
(a hash of the \`contracts/\` + \`test/\` trees — it moves only when a regeneration
is actually needed, so this file reproduces byte-for-byte at any commit with the
same inputs). Do not hand-edit: rerun the script (\`npm run coverage:inventory\`).
All artifacts in this directory come from the same single run and cannot
disagree with each other; \`regenerate && git diff --quiet docs/coverage\` is the
freshness check.

## Method

- **Row unit:** one row per tracked \`.sol\` file under \`contracts/\`;
  \`contract_name\` is the file basename. Top-level declarations that differ from
  the basename are listed in \`extra_decls\` — multi-contract files hide nothing.
- **\`covered=yes\` requires a focused signal**, one of exactly two:
  1. a \`*.test.js\`/\`*.test.ts\` file whose basename's first dot-delimited token
     equals the contract name (e.g. \`BTCStakeRegistry.focused.test.js\`);
  2. instantiation via \`getContractFactory('Name')\` inside an explicit tier
     guard bundle (\`test/coverage-tier*-guarded.test.js\`) — implementation-class
     rows only; mocks/helpers deployed there are scaffolding, not targets.
- **A bare name mention under \`test/\` is NOT coverage.** The old method counted
  it (\`basename_reference\`); it is retained only as \`referenced_test_count\` so
  the strict-vs-loose delta stays visible.
- **\`covered\` never means measured line/branch coverage.** No coverage tool ran.
  It means a focused test artifact exists and names this contract.
- **class** is path-derived only: \`contracts/interfaces/\` → interface,
  \`contracts/mocks/\` → mock, \`contracts/test-helpers/\` → test-helper, else
  implementation.
- **risk_score** is the sum of blast-radius group weights whose pattern matches
  the contract source (each group at most once):
${RISK_GROUPS.map(([g, w, re]) => `  - \`${g}\` (${w}): \`${re.source}\``).join('\n')}
- **Regenerate with:** \`node scripts/generate-coverage-inventory.js\`

## Summary

| metric | count |
|---|---:|
| total rows (tracked .sol under contracts/) | ${rows.length} |
| covered (strict) | ${covered.length} |
| — via focused file | ${rows.filter((r) => r.signal === 'focused').length} |
| — via tier bundle | ${rows.filter((r) => r.signal === 'bundle').length} |
| uncovered (strict) | ${uncovered.length} |
| — of those, referenced-only (loose method called these covered) | ${refOnly.length} |
| loose method would report covered | ${looseYes.length} |

Per class (covered/total): ${Object.entries(byClass).sort()
    .map(([c, v]) => `${c} ${v.covered}/${v.total}`).join(' · ')}

The strict uncovered set (${uncovered.length}) is the census this method supports.
The previous inventory's 49 was a floor produced by loose matching; the gap
between ${looseYes.length} loose-covered and ${covered.length} strict-covered is
exactly the over-count the #189 review identified.

## Uncovered implementation contracts, risk-ranked (production queue)

| rank | contract_path | referenced_test_count | risk_score | risk groups |
|---|---|---:|---:|---|
${uncoveredProd.map((r, i) => `| ${i + 1} | \`${r.path}\` | ${r.referencedCount} | ${r.riskScore} | ${r.riskGroups.join(', ')} |`).join('\n')}

Full artifacts: \`contract-coverage-inventory-raw.csv\` (all ${rows.length} rows),
\`uncovered-risk-ranking.csv\` (all classes), \`uncovered-risk-ranking-production.csv\`
(the table above).

## Proof boundary

- Name-based static inventory of the working tree. No tests were executed and no
  coverage instrumentation ran; a focused file's existence says nothing about
  what its assertions pin.
- Interface/mock/test-helper rows are inventoried but not queue candidates;
  they are excluded from the production ranking, not from the census.
- risk_score is a keyword heuristic for ordering a work queue, not an audit
  severity.
`;
fs.writeFileSync(path.join(outDir, 'inventory.md'), md);

console.log(`rows=${rows.length} covered=${covered.length} (focused=${rows.filter((r) => r.signal === 'focused').length} bundle=${rows.filter((r) => r.signal === 'bundle').length}) uncovered=${uncovered.length} prod-queue=${uncoveredProd.length} base=${base}${dirty}`);
