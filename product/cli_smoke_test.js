#!/usr/bin/env node
/*
 * Installer smoke test. It exercises the release-first path and hard failure
 * cases against a local HTTP fixture, so CI does not mutate a real home
 * directory or depend on a published GitHub release.
 */
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawn } = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const cli = path.join(repo, 'cli.js');
const pkgVersion = require(path.join(repo, 'package.json')).version;
const releaseTag = `v${pkgVersion}`;
const assetName = `fx-boosted-macos-arm64-${releaseTag}.tar.gz`;
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'fxc-cli-smoke-'));
const home = path.join(temp, 'home');
const release = path.join(temp, 'release');
fs.mkdirSync(path.join(home, '.local', 'bin'), { recursive: true });
fs.mkdirSync(path.join(home, '.fx-companion', 'bin'), { recursive: true });
fs.mkdirSync(release, { recursive: true });
const foreignFx = path.join(home, '.local', 'bin', 'fx');
const foreignContents = '#!/bin/sh\necho foreign-stock\n';
fs.writeFileSync(foreignFx, foreignContents);
fs.chmodSync(foreignFx, 0o755);
const priorInstalledFx = path.join(home, '.fx-companion', 'bin', 'fx');
const priorInstalledContents = '#!/bin/sh\necho prior-known-good\nFX_NO_COMPANION\n';
fs.writeFileSync(priorInstalledFx, priorInstalledContents);
fs.chmodSync(priorInstalledFx, 0o755);

const archive = path.join(release, assetName);
function writeReleaseBinary(marker, extraMember = false) {
  const built = path.join(release, 'fx');
  fs.writeFileSync(built, `#!/bin/sh\necho release-smoke\n${marker}\n`);
  fs.chmodSync(built, 0o755);
  const members = ['fx'];
  if (extraMember) {
    fs.writeFileSync(path.join(release, 'extra.txt'), 'unexpected\n');
    members.push('extra.txt');
  } else {
    fs.rmSync(path.join(release, 'extra.txt'), { force: true });
  }
  execFileSync('tar', ['-czf', archive, '-C', release, ...members]);
}
writeReleaseBinary('invalid-binary');

const server = http.createServer((req, res) => {
  const releaseMode = req.url.match(new RegExp(`^/api/releases/(invalid|valid|checksum|missing-sums|duplicate-sums|malformed|none)/releases/tags/${releaseTag.replace(/\./g, '\\.')}$`));
  if (releaseMode) {
    if (releaseMode[1] === 'none') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"message":"Not Found"}');
      return;
    }
    const mode = releaseMode[1];
    writeReleaseBinary(mode === 'invalid' ? 'invalid-binary' : 'FX_NO_COMPANION', mode === 'malformed');
    const digest = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    const assets = [{ name: assetName, browser_download_url: `${baseUrl()}/${assetName}` }];
    if (mode !== 'missing-sums') assets.push({ name: 'SHA256SUMS', browser_download_url: `${baseUrl()}/SHA256SUMS` });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      tag_name: releaseTag,
      assets,
    }));
    if (mode === 'checksum') server.expected = `${'0'.repeat(64)}  ${assetName}\n`;
    else if (mode === 'duplicate-sums') server.expected = `${digest}  ${assetName}\n${digest}  ${assetName}\n`;
    else server.expected = `${digest}  ${assetName}\n`;
    return;
  }
  if (req.url === `/${assetName}`) {
    res.writeHead(200, { 'content-type': 'application/gzip' });
    fs.createReadStream(archive).pipe(res);
    return;
  }
  if (req.url === '/SHA256SUMS') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(server.expected || '');
    return;
  }
  res.writeHead(404);
  res.end();
});

function baseUrl() {
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

function run(env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [cli, 'install'], {
      cwd: repo,
      env: { ...process.env, HOME: home, ...env, FX_COMPANION_HOME: path.join(home, '.fx-companion'), FXC_NO_PATH_ACTIVATION: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('close', (status, signal) => resolve({ status, signal, stdout, stderr }));
  });
}

server.listen(0, '127.0.0.1', async () => {
  try {
    const apiRoot = `${baseUrl()}/api/releases`;
    const invalid = await run({ FXC_API_ROOT: `${apiRoot}/invalid` });
    assert.notEqual(invalid.status, 0, invalid.stdout + invalid.stderr);
    assert.equal(fs.readFileSync(foreignFx, 'utf8'), foreignContents);
    assert.equal(fs.readFileSync(priorInstalledFx, 'utf8'), priorInstalledContents);
    assert.equal(fs.existsSync(path.join(home, '.local', 'bin', 'fx.stock.bak')), false);

    const checksum = await run({ FXC_API_ROOT: `${apiRoot}/checksum` });
    assert.notEqual(checksum.status, 0, checksum.stdout + checksum.stderr);
    assert.match(checksum.stdout + checksum.stderr, /checksum mismatch/i);
    assert.equal(fs.readFileSync(foreignFx, 'utf8'), foreignContents);
    assert.equal(fs.readFileSync(priorInstalledFx, 'utf8'), priorInstalledContents);

    const missingSums = await run({ FXC_API_ROOT: `${apiRoot}/missing-sums` });
    assert.notEqual(missingSums.status, 0, missingSums.stdout + missingSums.stderr);
    assert.match(missingSums.stdout + missingSums.stderr, /no SHA256SUMS/i);

    const duplicateSums = await run({ FXC_API_ROOT: `${apiRoot}/duplicate-sums` });
    assert.notEqual(duplicateSums.status, 0, duplicateSums.stdout + duplicateSums.stderr);
    assert.match(duplicateSums.stdout + duplicateSums.stderr, /exactly one valid entry/i);

    const malformed = await run({ FXC_API_ROOT: `${apiRoot}/malformed` });
    assert.notEqual(malformed.status, 0, malformed.stdout + malformed.stderr);
    assert.match(malformed.stdout + malformed.stderr, /exactly one top-level fx file/i);
    assert.equal(fs.readFileSync(priorInstalledFx, 'utf8'), priorInstalledContents);

    const valid = await run({ FXC_API_ROOT: `${apiRoot}/valid` });
    assert.equal(valid.status, 0, valid.stdout + valid.stderr);
    assert.equal(fs.readFileSync(foreignFx, 'utf8'), foreignContents);
    assert.equal(fs.existsSync(path.join(home, '.local', 'bin', 'fx.stock.bak')), false);
    assert.equal(fs.existsSync(path.join(home, '.fx-companion', 'bin', 'fx')), true);
    for (const managerFile of ['fxc', 'sync.sh', 'install.sh', 'fx_companion.zig', 'inject_hook.py', 'tests_fxcompanion.zig', 'PINNED_FX']) {
      assert.equal(fs.existsSync(path.join(home, '.fx-companion', managerFile)), true, `missing installed manager file ${managerFile}`);
    }
    assert.equal((fs.statSync(path.join(home, '.fx-companion', 'fxc')).mode & 0o111) !== 0, true);
    assert.equal((fs.statSync(path.join(home, '.fx-companion', 'sync.sh')).mode & 0o111) !== 0, true);
    const validInstalledContents = fs.readFileSync(priorInstalledFx, 'utf8');
    assert.notEqual(validInstalledContents, priorInstalledContents);

    // A missing release may use only the packaged source bundle. Force that
    // local build to fail immediately by exposing bash but no zig; this proves
    // the installer fails closed without making any mutable source requests.
    const noZigPath = path.join(temp, 'no-zig-bin');
    fs.mkdirSync(noZigPath);
    const bash = execFileSync('sh', ['-c', 'command -v bash'], { encoding: 'utf8' }).trim();
    fs.symlinkSync(bash, path.join(noZigPath, 'bash'));
    const noRelease = await run({
      FXC_API_ROOT: `${apiRoot}/none`,
      PATH: noZigPath,
    });
    assert.notEqual(noRelease.status, 0, noRelease.stdout + noRelease.stderr);
    assert.match(noRelease.stdout + noRelease.stderr, /zig is required|pinned source build failed/i);
    assert.equal(fs.readFileSync(foreignFx, 'utf8'), foreignContents);
    assert.equal(fs.readFileSync(priorInstalledFx, 'utf8'), validInstalledContents);

    process.stdout.write('cli smoke: exact release validation, checksum/archive rejection, foreign-fx preservation, and fail-closed packaged fallback passed\n');
  } catch (error) {
    console.error(error.stack || error);
    process.exitCode = 1;
  } finally {
    server.close();
  }
});
