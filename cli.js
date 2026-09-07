#!/usr/bin/env node
/**
 * fx-companion — boosted fx for Apple Silicon.
 *
 *   npx github:ChloeVPin/fx-companion            install (default)
 *   npx github:ChloeVPin/fx-companion status     check what's installed
 *
 * Downloads the matching prebuilt boosted fx binary from GitHub Releases when
 * available. If no compatible release exists yet, it builds from the exact
 * source bundle shipped with this package. It never executes source fetched
 * from a mutable branch.
 */
'use strict';

const { spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const PKG_VERSION = require('./package.json').version;
const REPO = 'ChloeVPin/fx-companion';
const USER_AGENT = 'OpenAI File Downloader, XaiImageApiFetch/1.0';
const API = process.env.FXC_API_ROOT || `https://api.github.com/repos/${REPO}`;
const INSTALL_HOME = process.env.FX_COMPANION_HOME || path.join(os.homedir(), '.fx-companion');
const INSTALL_DIR = path.join(INSTALL_HOME, 'bin');
const RELEASE_TAG = `v${PKG_VERSION}`;
const RELEASE_ASSET = `fx-boosted-macos-arm64-${RELEASE_TAG}.tar.gz`;

const SOURCE_FILES = [
  'PINNED_FX',
  'product/fx_companion.zig',
  'product/inject_hook.py',
  'product/fxc',
  'product/tests_fxcompanion.zig',
  'product/install.sh',
  'product/sync.sh',
];

const MANAGER_FILES = SOURCE_FILES.map((relative) => ({
  relative,
  destination: relative === 'PINNED_FX'
    ? path.join(INSTALL_HOME, 'PINNED_FX')
    : path.join(INSTALL_HOME, path.basename(relative)),
  executable: ['product/fxc', 'product/install.sh', 'product/sync.sh'].includes(relative),
}));

class ReleaseUnavailable extends Error {}

const err = (msg) => {
  console.error(`fx-companion: ${msg}`);
  process.exit(1);
};

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { stdio: opts.capture ? 'pipe' : 'inherit', encoding: 'utf8', ...opts });
}

function packagedSourcePath(relative) {
  const packaged = path.join(__dirname, relative);
  let stat;
  try {
    stat = fs.lstatSync(packaged);
  } catch {
    throw new Error(`packaged source fallback is incomplete: missing ${relative}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`packaged source fallback rejected non-regular file: ${relative}`);
  return packaged;
}

function atomicCopyFile(source, destination, mode = null) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const staged = `${destination}.tmp-${process.pid}`;
  try {
    fs.copyFileSync(source, staged);
    if (mode !== null) fs.chmodSync(staged, mode);
    fs.renameSync(staged, destination);
  } finally {
    fs.rmSync(staged, { force: true });
  }
}

function installManagerBundle() {
  for (const entry of MANAGER_FILES) {
    atomicCopyFile(packagedSourcePath(entry.relative), entry.destination, entry.executable ? 0o755 : null);
  }
  console.log(`✓ installed manager bundle in ${INSTALL_HOME}`);
}

async function api(pathName) {
  const res = await fetch(`${API}${pathName}`, {
    headers: { 'user-agent': USER_AGENT, accept: 'application/vnd.github+json' },
  });
  if (!res.ok) throw new ReleaseUnavailable(`GitHub API failed (${res.status}): ${pathName}`);
  return res.json();
}

async function resolveRelease() {
  try {
    const rel = await api(`/releases/tags/${encodeURIComponent(RELEASE_TAG)}`);
    const asset = (rel.assets || []).find((a) => a.name === RELEASE_ASSET);
    const sums = (rel.assets || []).find((a) => a.name === 'SHA256SUMS');
    if (rel.tag_name !== RELEASE_TAG) throw new ReleaseUnavailable(`release tag mismatch: expected ${RELEASE_TAG}`);
    if (!asset) throw new ReleaseUnavailable(`release ${RELEASE_TAG} has no ${RELEASE_ASSET}`);
    console.log(`release: ${rel.tag_name}`);
    return {
      tag: rel.tag_name,
      assetName: asset.name,
      assetUrl: asset.browser_download_url,
      sumsUrl: sums ? sums.browser_download_url : null,
    };
  } catch (e) {
    console.log(`prebuilt release unavailable (${e.message}); falling back to pinned source build`);
    return null;
  }
}

async function download(url, dest) {
  let res;
  try {
    res = await fetch(url, { redirect: 'follow', headers: { 'user-agent': USER_AGENT } });
  } catch (e) {
    throw new ReleaseUnavailable(`download failed (${e.message}): ${url}`);
  }
  if (!res.ok) throw new ReleaseUnavailable(`download failed (${res.status}): ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(dest, buf);
  return buf;
}

async function installRelease(rel, tmp) {
  const tgz = path.join(tmp, 'fx.tar.gz');
  process.stdout.write('↓ downloading prebuilt binary…\n');
  const buf = await download(rel.assetUrl, tgz);

  process.stdout.write('🔒 verifying checksum…\n');
  if (!rel.sumsUrl) throw new Error(`release ${rel.tag} has no SHA256SUMS; refusing an unverified install`);
  let sumsResponse;
  try {
    sumsResponse = await fetch(rel.sumsUrl, { redirect: 'follow', headers: { 'user-agent': USER_AGENT } });
  } catch (e) {
    throw new Error(`could not download SHA256SUMS (${e.message}); refusing an unverified install`);
  }
  if (!sumsResponse.ok) throw new Error(`checksum download failed (${sumsResponse.status}); refusing an unverified install`);
  const sum = await sumsResponse.text();
  const assetName = rel.assetName;
  const matches = [];
  for (const line of sum.split('\n')) {
    const [hash, name] = line.trim().split(/\s+/);
    if (name === assetName && /^[a-f0-9]{64}$/i.test(hash)) matches.push(hash.toLowerCase());
  }
  if (matches.length !== 1) throw new Error(`SHA256SUMS must contain exactly one valid entry for ${assetName}`);
  const expected = matches[0];
  const actual = crypto.createHash('sha256').update(buf).digest('hex');
  if (expected !== actual) throw new Error(`checksum mismatch!\n  expected ${expected}\n  actual   ${actual}`);
  console.log('✓ checksum ok');

  const listing = sh('tar', ['-tzf', tgz], { capture: true });
  if (listing.status !== 0) throw new Error('could not inspect release archive');
  const members = (listing.stdout || '').split(/\r?\n/).filter(Boolean);
  if (members.length !== 1 || members[0] !== 'fx') throw new Error('release archive must contain exactly one top-level fx file');

  const extracted = path.join(tmp, 'fx');
  const tar = sh('tar', ['-xzf', tgz, '-C', tmp, 'fx']);
  if (tar.status !== 0 || !fs.existsSync(extracted) || !fs.lstatSync(extracted).isFile()) throw new Error('archive did not contain a regular fx binary');
  if (!hasBooster(fs.readFileSync(extracted))) throw new Error('binary failed the booster integrity check; refusing to install');
  installManagerBundle();
  installBinary(extracted);
}

async function installFromSource(tmp) {
  const sourceRoot = path.join(tmp, 'source');
  const productRoot = path.join(sourceRoot, 'product');
  fs.mkdirSync(productRoot, { recursive: true });
  for (const relative of SOURCE_FILES) {
    const packaged = packagedSourcePath(relative);
    const destination = path.join(sourceRoot, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(packaged, destination);
  }
  for (const executable of ['fxc', 'install.sh', 'sync.sh']) fs.chmodSync(path.join(productRoot, executable), 0o755);

  const installer = path.join(productRoot, 'install.sh');
  const sourceEnv = { ...process.env, FX_COMPANION_HOME: INSTALL_HOME };
  // The automatic fallback is deliberately bound to the package's PINNED_FX
  // and owned upstream directory. Developer overrides remain available when
  // running sync.sh explicitly, but cannot silently change an npm install.
  delete sourceEnv.FX_PIN_FILE;
  delete sourceEnv.FX_UPSTREAM_DIR;
  const result = sh('bash', [installer], {
    env: sourceEnv,
  });
  if (result.status !== 0) throw new Error(`pinned source build failed with exit ${result.status ?? 'signal'}`);
  if (!fs.existsSync(path.join(INSTALL_DIR, 'fx'))) throw new Error('pinned source build produced no fx binary');
  activateOnPath();
  console.log(`✓ installed pinned source build from packaged sources`);
}

function installBinary(built) {
  const staged = path.join(INSTALL_DIR, `.fx.tmp-${process.pid}`);
  fs.mkdirSync(INSTALL_DIR, { recursive: true });
  try {
    fs.copyFileSync(built, staged);
    fs.chmodSync(staged, 0o755);
    const fd = fs.openSync(staged, 'r');
    try {
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(staged, path.join(INSTALL_DIR, 'fx'));
    try {
      const dirfd = fs.openSync(INSTALL_DIR, 'r');
      try { fs.fsyncSync(dirfd); } finally { fs.closeSync(dirfd); }
    } catch {}
  } finally {
    fs.rmSync(staged, { force: true });
  }
  console.log(`✓ installed ${INSTALL_DIR}/fx`);
  activateOnPath();
}

function hasBooster(buf) {
  // The kill-switch env name is compiled into every boosted binary.
  return buf.includes(Buffer.from('FX_NO_COMPANION', 'ascii'));
}

async function install() {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    err(`this package boosts fx on macOS Apple Silicon only (you have ${process.platform}/${process.arch}).`);
  }

  console.log(`fx-companion v${PKG_VERSION} — installing boosted fx…`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fxc-'));
  try {
    const rel = await resolveRelease();
    if (rel) {
      try {
        await installRelease(rel, tmp);
      } catch (e) {
        if (!(e instanceof ReleaseUnavailable)) throw e;
        console.log(`prebuilt release unavailable (${e.message}); falling back to pinned source build`);
        await installFromSource(tmp);
      }
    } else {
      await installFromSource(tmp);
    }
  } catch (e) {
    err(e.message);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  console.log('');
  console.log('Then just run `fx` — same commands, same output, faster.');
  console.log('Stock anytime: FX_NO_COMPANION=1 fx …   ·   Sessions/skills/data untouched.');
  console.log('Diagnostics stay outside fx; use the repository benchmark tooling when profiling.');
}

function activateOnPath() {
  if (process.env.FXC_NO_PATH_ACTIVATION === '1') return;
  const ours = path.join(INSTALL_DIR, 'fx');
  const candidates = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    ...(process.env.PATH || '')
      .split(':')
      .filter((d) => d && /(\.local\/bin|\.cargo\/bin)$/.test(d)),
  ];
  for (const d of candidates) {
    try {
      if (!fs.existsSync(d)) continue;
      const st = fs.statSync(d);
      if (!st.isDirectory()) continue;
      fs.accessSync(d, fs.constants.W_OK);
      const link = path.join(d, 'fx');
      if (fs.existsSync(link) || fs.lstatSync(link, { throwIfNoEntry: false })) {
        const lst = fs.lstatSync(link);
        if (lst.isSymbolicLink()) {
          const resolved = fs.realpathSync(link);
          if (resolved === ours) {
            console.log(`✓ ${link} → boosted fx (already active)`);
            return;
          }
          if (!fs.existsSync(resolved)) {
            fs.rmSync(link); // dangling
          } else {
            continue; // owned by something else
          }
        } else {
          continue; // real file owned by something else; never replace it
        }
      }
      fs.symlinkSync(ours, link);
      console.log(`✓ linked ${link} → boosted fx (already on your PATH)`);
      return;
    } catch {}
  }
  // Fallback: add our bin dir to ~/.zshrc once, between markers.
  const zshrc = path.join(os.homedir(), '.zshrc');
  const begin = '# >>> fx-companion >>>';
  const end = '# <<< fx-companion <<<';
  try {
    let cur = '';
    if (fs.existsSync(zshrc)) cur = fs.readFileSync(zshrc, 'utf8');
    if (!cur.includes(begin)) {
      const block = `\n${begin}\nexport PATH="${INSTALL_DIR}:$PATH"\n${end}\n`;
      fs.appendFileSync(zshrc, block);
      console.log(`✓ added ${INSTALL_DIR} to your ~/.zshrc (open a new tab to pick it up)`);
    } else {
      console.log('✓ ~/.zshrc already activates fx-companion');
    }
  } catch {
    console.log(`add to your ~/.zshrc:  export PATH="${INSTALL_DIR}:$PATH"`);
  }
}

function status() {
  const bin = path.join(INSTALL_DIR, 'fx');
  if (!fs.existsSync(bin)) return console.log('boosted fx: not installed (run without arguments to install)');
  const v = sh(bin, ['--version'], { capture: true });
  const hasBoosterFlag = (() => {
    try {
      const b = fs.readFileSync(bin);
      return b.includes(Buffer.from('FX_NO_COMPANION', 'ascii'));
    } catch {
      return '?';
    }
  })();
  console.log(`${bin} → v${(v.stdout || '').trim()} · booster: ${hasBoosterFlag ? 'PRESENT ✦' : 'absent'}`);
  const w = sh('which', ['fx'], { capture: true });
  console.log(`which fx → ${(w.stdout || '').trim() || '(not on PATH)'}`);
}

(async () => {
  const cmd = process.argv[2] || 'install';
  if (cmd === 'install') await install();
  else if (cmd === 'status') status();
  else if (cmd === '--version' || cmd === '-v') console.log(PKG_VERSION);
  else {
    console.log('usage: npx github:ChloeVPin/fx-companion [install|status]');
    process.exit(cmd === '-h' || cmd === '--help' ? 0 : 1);
  }
})();
