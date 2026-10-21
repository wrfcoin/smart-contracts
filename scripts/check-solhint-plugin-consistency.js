#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const readJson = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const config = readJson('.solhintrc.json');
const manifest = readJson('package.json');
const lock = readJson('package-lock.json');
const rootLock = lock.packages && lock.packages[''];
const declared = { ...(manifest.dependencies || {}), ...(manifest.devDependencies || {}) };
const locked = {
  ...((rootLock && rootLock.dependencies) || {}),
  ...((rootLock && rootLock.devDependencies) || {}),
};
const plugins = config.plugins || [];
const lintScript = manifest.scripts && manifest.scripts.lint;

if (!Array.isArray(plugins)) {
  throw new Error('.solhintrc.json plugins must be an array');
}

for (const plugin of plugins) {
  if (typeof plugin !== 'string' || !plugin) {
    throw new Error('Each Solhint plugin must be a non-empty string');
  }

  const packageName = plugin.startsWith('solhint-plugin-')
    ? plugin
    : `solhint-plugin-${plugin}`;

  if (!declared[packageName]) {
    throw new Error(`Configured ${packageName} is not declared in package.json`);
  }
  if (!locked[packageName]) {
    throw new Error(`Configured ${packageName} is not declared in package-lock.json root`);
  }
}

if (!lintScript || !lintScript.includes('--ignore-path .solhintignore')) {
  throw new Error('lint must use .solhintignore to exclude dependency-owned Solidity');
}

const ignoreRules = fs.readFileSync(path.join(root, '.solhintignore'), 'utf8')
  .split(/\r?\n/)
  .map(rule => rule.trim())
  .filter(rule => rule && !rule.startsWith('#'));

if (!ignoreRules.includes('node_modules/**')) {
  throw new Error('.solhintignore must exclude node_modules/** without narrowing project Solidity sources');
}

console.log(`Solhint configuration consistency passed for ${plugins.length} configured plugin(s).`);
