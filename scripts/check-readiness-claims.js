#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const CLAIM_PATTERN = /OFFICIAL SECURITY CERTIFICATION|APPROVED FOR PRODUCTION|PRODUCTION[ -]READY|CERTIFIED ✅|mainnet[- ]ready/i;

function fail(message, code = 1) {
  console.error(`readiness-claims: ${message}`);
  process.exit(code);
}

function loadAllowlist(repoRoot) {
  const configuredPath = process.env.READINESS_CLAIMS_ALLOWLIST;
  const allowlistPath = configuredPath
    ? path.resolve(repoRoot, configuredPath)
    : path.join(repoRoot, 'config', 'readiness-claims-allowlist.json');

  let entries;
  try {
    entries = JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
  } catch (error) {
    fail(`cannot read allowlist ${allowlistPath}: ${error.message}`);
  }

  if (!Array.isArray(entries)) {
    fail('allowlist must be a JSON array');
  }

  return entries.map((entry, index) => {
    for (const field of ['path', 'pattern', 'evidence_url', 'reason']) {
      if (typeof entry[field] !== 'string' || entry[field].trim() === '') {
        fail(`allowlist entry ${index} requires non-empty ${field}`);
      }
    }

    if (!/^https?:\/\//i.test(entry.evidence_url)) {
      const evidencePath = path.resolve(repoRoot, entry.evidence_url);
      const relativeEvidencePath = path.relative(repoRoot, evidencePath);
      if (relativeEvidencePath.startsWith('..') || path.isAbsolute(relativeEvidencePath)) {
        fail(`allowlist entry ${index} evidence_url escapes the repository`);
      }
      if (!fs.existsSync(evidencePath)) {
        fail(`allowlist entry ${index} evidence_url does not resolve: ${entry.evidence_url}`);
      }
    }

    let pattern;
    try {
      pattern = new RegExp(entry.pattern, 'i');
    } catch (error) {
      fail(`allowlist entry ${index} has invalid pattern: ${error.message}`);
    }

    return { ...entry, pattern };
  });
}

function trackedMarkdown(repoRoot) {
  let output;
  try {
    output = execFileSync('git', ['ls-files', '-z', '--', '*.md'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    fail(`cannot enumerate tracked markdown: ${error.stderr || error.message}`, 2);
  }

  return output.split('\0').filter(Boolean).filter((file) => {
    const normalized = file.replaceAll('\\', '/');
    return !normalized.startsWith('docs/archive/')
      && !normalized.startsWith('node_modules/')
      && !normalized.includes('/node_modules/');
  });
}

function main() {
  const repoRoot = path.resolve(process.env.READINESS_CLAIMS_ROOT || process.cwd());
  const allowlist = loadAllowlist(repoRoot);
  const files = trackedMarkdown(repoRoot);

  if (files.length === 0) {
    fail('VOID: zero markdown files scanned', 2);
  }

  const findings = [];
  let lineCount = 0;

  for (const file of files) {
    const lines = fs.readFileSync(path.join(repoRoot, file), 'utf8').split(/\r?\n/);
    lineCount += lines.length;
    lines.forEach((line, index) => {
      if (!CLAIM_PATTERN.test(line)) return;

      const allowed = allowlist.some((entry) => entry.path === file && entry.pattern.test(line));
      if (!allowed) findings.push(`${file}:${index + 1}: ${line.trim()}`);
    });
  }

  if (findings.length > 0) {
    console.error(`readiness-claims: ${findings.length} unallowlisted claim(s)`);
    findings.forEach((finding) => console.error(finding));
    process.exit(1);
  }

  console.log(`readiness-claims: PASS scanned=${files.length} markdown_files lines=${lineCount} allowlist_entries=${allowlist.length}`);
}

main();
