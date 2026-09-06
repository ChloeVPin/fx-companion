#!/usr/bin/env node
/*
 * Installer smoke test. It exercises the release-first path and the no-release
 * source fallback against a local HTTP fixture, so CI does not mutate a real
 * home directory or depend on a published GitHub release.
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
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'fxc-cli-smoke-'));
const home = path.join(temp, 'home');
const release = path.join(temp, 'release');
fs.mkdirSync(path.join(home, '.local', 'bin'), { recursive: true });
fs.mkdirSync(release, { recursive: true });
fs.writeFileSync(path.join(home, '.local', 'bin', 'fx'), '#!/bin/sh\necho stock\n');
fs.chmodSync(path.join(home, '.local', 'bin', 'fx'), 0o755);

const sourceInstaller = path.join(temp, 'source-installer.sh');
fs.writeFileSync(sourceInstaller, [
  '#!/bin/sh',
  'set -eu',
  'mkdir -p "$FX_COMPANION_HOME/bin"',
  'printf "#!/bin/sh\\necho source-fallback\\nFX_NO_COMPANION\\n" > "$FX_COMPANION_HOME/bin/fx"',
  'chmod 755 "$FX_COMPANION_HOME/bin/fx"',
  '',
].join('\n'));
fs.chmodSync(sourceInstaller, 0o755);

const archive = path.join(release, 'fx-boosted-macos-arm64-v0.0.0.tar.gz');
function writeReleaseBinary(marker) {
  const built = path.join(release, 'fx');
  fs.writeFileSync(built, `#!/bin/sh\necho release-smoke\n${marker}\n`);
  fs.chmodSync(built, 0o755);
  execFileSync('tar', ['-czf', archive, '-C', release, 'fx']);
}
writeReleaseBinary('invalid-binary');

const server = http.createServer((req, res) => {
  if (req.url === '/api/releases/latest') {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"message":"Not Found"}');
    return;
  }
  const releaseMode = req.url.match(/^\/api\/releases\/(invalid|valid|none)\/releases\/latest$/);
  if (releaseMode) {
    if (releaseMode[1] === 'none') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"message":"Not Found"}');
      return;
    }
    writeReleaseBinary(releaseMode[1] === 'valid' ? 'FX_NO_COMPANION' : 'invalid-binary');
    const asset = path.basename(archive);
    const digest = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      tag_name: 'v0.0.0',
      assets: [
        { name: asset, browser_download_url: `${baseUrl()}/${asset}` },
        { name: 'SHA256SUMS', browser_download_url: `${baseUrl()}/SHA256SUMS` },
      ],
    }));
    server.expected = `${digest}  ${asset}\n`;
    return;
  }
  if (req.url === `/${path.basename(archive)}`) {
    res.writeHead(200, { 'content-type': 'application/gzip' });
    fs.createReadStream(archive).pipe(res);
    return;
  }
  if (req.url === '/SHA256SUMS') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(server.expected || '');
    return;
  }
  if (req.url.startsWith('/source/')) {
    const relative = decodeURIComponent(req.url.slice('/source/'.length));
    const file = path.resolve(repo, relative);
    if (!file.startsWith(`${repo}${path.sep}`) || !fs.existsSync(file)) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200);
    fs.createReadStream(file).pipe(res);
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
    assert.equal(fs.existsSync(path.join(home, '.local', 'bin', 'fx')), true);
    assert.equal(fs.existsSync(path.join(home, '.local', 'bin', 'fx.stock.bak')), false);

    const valid = await run({ FXC_API_ROOT: `${apiRoot}/valid` });
    assert.equal(valid.status, 0, valid.stdout + valid.stderr);
    assert.equal(fs.existsSync(path.join(home, '.local', 'bin', 'fx.stock.bak')), true);
    assert.equal(fs.existsSync(path.join(home, '.fx-companion', 'bin', 'fx')), true);

    const noRelease = await run({
      FXC_API_ROOT: `${apiRoot}/none`,
      FXC_RAW_BASE: `${baseUrl()}/source`,
      FXC_SOURCE_INSTALL_SCRIPT: sourceInstaller,
    });
    assert.equal(noRelease.status, 0, noRelease.stdout + noRelease.stderr);
    const fallback = fs.readFileSync(path.join(home, '.fx-companion', 'bin', 'fx'), 'utf8');
    assert.match(fallback, /source-fallback/);
    process.stdout.write('cli smoke: release validation, stock preservation, and no-release fallback passed\n');
  } catch (error) {
    console.error(error.stack || error);
    process.exitCode = 1;
  } finally {
    server.close();
  }
});
