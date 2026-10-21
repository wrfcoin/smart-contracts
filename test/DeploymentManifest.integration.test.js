'use strict';

const { expect } = require('chai');
const fs = require('fs').promises;
const os = require('os');
const path = require('path');
const { ethers, artifacts } = require('hardhat');
const { deployRelease } = require('../scripts/deploy');
const {
  RELEASE_INVENTORY,
  validateManifest,
  writeManifestAtomic,
} = require('../scripts/lib/deploymentManifest');
const { TestnetSecurityMonitor } = require('../testnet-security-monitoring');

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

describe('canonical release deployment manifest', function () {
  this.timeout(180000);

  let directory;
  let manifest;
  let manifestPath;

  before(async function () {
    directory = await fs.mkdtemp(
      path.join(os.tmpdir(), 'wrfcoin-deployment-manifest-')
    );
    manifestPath = path.join(directory, 'release-manifest.json');
    ({ manifest } = await deployRelease({ manifestPath }));
  });

  it('deploys and loads every schema-required contract into monitoring', async function () {
    const monitor = new TestnetSecurityMonitor({ manifestPath });
    monitor.providers.set('hardhat', ethers.provider);

    const loaded = await monitor.loadContracts('hardhat');

    expect([...monitor.contracts.keys()]).to.have.members(
      RELEASE_INVENTORY.map(entry => entry.name)
    );
    expect(loaded.contracts).to.have.length(RELEASE_INVENTORY.length);
    for (const entry of loaded.contracts) {
      expect(await ethers.provider.getCode(entry.address)).not.to.equal('0x');
    }
  });

  it('fails closed when one required contract is absent', async function () {
    const altered = clone(manifest);
    altered.contracts.pop();
    const alteredPath = path.join(directory, 'missing-entry.json');
    await writeManifestAtomic(alteredPath, altered);
    const monitor = new TestnetSecurityMonitor({ manifestPath: alteredPath });
    monitor.providers.set('hardhat', ethers.provider);

    await expect(monitor.loadContracts('hardhat')).to.be.rejectedWith(
      'required inventory'
    );
    expect(monitor.contracts.size).to.equal(0);
  });

  it('fails closed when the manifest chain differs from the provider', async function () {
    const altered = clone(manifest);
    altered.chainId += 1;
    const alteredPath = path.join(directory, 'wrong-chain.json');
    await writeManifestAtomic(alteredPath, altered);
    const monitor = new TestnetSecurityMonitor({ manifestPath: alteredPath });
    monitor.providers.set('hardhat', ethers.provider);

    await expect(monitor.loadContracts('hardhat')).to.be.rejectedWith(
      'chainId does not match provider'
    );
    expect(monitor.contracts.size).to.equal(0);
  });

  it('rejects zero-code, duplicate, and stale contract records', async function () {
    const zeroCode = clone(manifest);
    zeroCode.contracts[0].address =
      '0x0000000000000000000000000000000000000001';
    await expect(
      validateManifest(zeroCode, {
        provider: ethers.provider,
        artifacts,
        networkName: 'hardhat',
      })
    ).to.be.rejectedWith('has no deployed code');

    const duplicate = clone(manifest);
    duplicate.contracts[1].address = duplicate.contracts[0].address;
    await expect(
      validateManifest(duplicate, {
        provider: ethers.provider,
        artifacts,
        networkName: 'hardhat',
      })
    ).to.be.rejectedWith('has duplicate address');

    const stale = clone(manifest);
    stale.contracts[0].artifactHash = `0x${'0'.repeat(64)}`;
    await expect(
      validateManifest(stale, {
        provider: ethers.provider,
        artifacts,
        networkName: 'hardhat',
      })
    ).to.be.rejectedWith('artifact hash is stale');
  });
});
