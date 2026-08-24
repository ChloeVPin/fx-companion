#!/usr/bin/env node
/**
 * fx-companion — boosted fx for Apple Silicon.
 *
 *   npx github:ChloeVPin/fx-companion            install (default)
 *   npx github:ChloeVPin/fx-companion status     check what's installed
 *
 * Downloads the newest prebuilt boosted fx binary from GitHub Releases,
 * retires any previously installed stock fx executables (backed up, user
 * data untouched), and links it onto your PATH.
 */
'use strict';

const { execFileSync, spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const PKG_VERSION = require('./package.json').version;
const REPO = 'ChloeVPin/fx-companion';
const API = `https://api.github.com/repos/${REPO}`;
const INSTALL_DIR = path.join(os.homedir(), '.fx-companion', 'bin');

const err = (msg) => {
  console.error(`fx-companion: ${msg}`);
  process.exit(1);
};

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { stdio: opts.capture ? 'pipe' : 'inherit', encoding: 'utf8', ...opts });
}

async function api(pathName) {
  const res = await fetch(`${API}${pathName}`, {
    headers: { 'user-agent': 'fx-companion-installer', accept: 'application/vnd.github+json' },
  });
  if (!res.ok) err(`GitHub API failed (${res.status}): ${pathName}`);
  return res.json();
}

async function resolveLatestRelease() {
  try {
    const rel = await api('/releases/latest');
    const asset = (rel.assets || []).find((a) => /^fx-boosted-macos-arm64-.*\.tar\.gz$/.test(a.name));
    const sums = (rel.assets || []).find((a) => a.name === 'SHA256SUMS');
    if (!asset) throw new Error('no macos-arm64 asset');
    console.log(`latest release: ${rel.tag_name}`);
    return { tag: rel.tag_name, version: rel.tag_name.replace(/^v/, ''), assetUrl: asset.browser_download_url, sumsUrl: sums ? sums.browser_download_url : null };
  } catch (e) {
    // API unavailable: fall back to this package's pinned version.
    console.log(`could not query latest release (${e.message}); using package version ${PKG_VERSION}`);
    const v = PKG_VERSION;
    return {
      tag: `v${v}`,
      version: v,
      assetUrl: `https://github.com/${REPO}/releases/download/v${v}/fx-boosted-macos-arm64-v${v}.tar.gz`,
      sumsUrl: `https://github.com/${REPO}/releases/download/v${v}/SHA256SUMS`,
    };
  }
}

async function download(url, dest) {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) err(`download failed (${res.status}): ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(dest, buf);
  return buf;
}

function hasBooster(buf) {
  // The kill-switch env name is compiled into every boosted binary.
  return buf.includes(Buffer.from('FX_NO_COMPANION', 'ascii'));
}

function retireOld() {
  // Move previously installed stock fx binaries aside. User data in ~/.fx
  // (sessions, chats, skills, settings) is never touched.
  for (const p of [
    path.join(os.homedir(), '.local/bin/fx'),
    '/usr/local/bin/fx',
  ]) {
    try {
      if (fs.existsSync(p) && !fs.lstatSync(p).isSymbolicLink()) {
        const bak = `${p}.stock.bak`;
        fs.renameSync(p, bak);
        console.log(`✓ retired previous ${p} (backup at ${bak})`);
      }
    } catch {}
  }
}

async function install() {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    err(`this package boosts fx on macOS Apple Silicon only (you have ${process.platform}/${process.arch}).`);
  }

  console.log(`fx-companion v${PKG_VERSION} — installing boosted fx…`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fxc-'));
  const rel = await resolveLatestRelease();
  const tgz = path.join(tmp, 'fx.tar.gz');

  process.stdout.write('↓ downloading prebuilt binary…\n');
  const buf = await download(rel.assetUrl, tgz);

  process.stdout.write('🔒 verifying checksum…\n');
  if (!rel.sumsUrl) err(`release ${rel.tag} has no SHA256SUMS; refusing an unverified install`);
  let sumsResponse;
  try {
    sumsResponse = await fetch(rel.sumsUrl, { redirect: 'follow' });
  } catch (e) {
    err(`could not download SHA256SUMS (${e.message}); refusing an unverified install`);
  }
  if (!sumsResponse.ok) {
    err(`checksum download failed (${sumsResponse.status}); refusing an unverified install`);
  }
  const sum = await sumsResponse.text();
  const assetName = path.basename(rel.assetUrl);
  let expected = null;
  for (const line of sum.split('\n')) {
    const [hash, name] = line.trim().split(/\s+/);
    if (name === assetName && /^[a-f0-9]{64}$/i.test(hash)) expected = hash.toLowerCase();
  }
  if (!expected) err(`SHA256SUMS has no valid entry for ${assetName}`);
  const actual = crypto.createHash('sha256').update(buf).digest('hex');
  if (expected !== actual) err(`checksum mismatch!\n  expected ${expected}\n  actual   ${actual}`);
  console.log('✓ checksum ok');

  retireOld();

  fs.mkdirSync(INSTALL_DIR, { recursive: true });
  sh('tar', ['-xzf', tgz, '-C', tmp]);
  const built = path.join(tmp, 'fx');
  if (!fs.existsSync(built)) err('archive did not contain an fx binary');

  // Post-extraction booster check (authoritative).
  if (!hasBooster(fs.readFileSync(built))) err('binary failed the booster integrity check; refusing to install');

  fs.copyFileSync(built, path.join(INSTALL_DIR, 'fx'));
  fs.chmodSync(path.join(INSTALL_DIR, 'fx'), 0o755);
  fs.rmSync(tmp, { recursive: true, force: true });

  console.log(`✓ installed ${INSTALL_DIR}/fx`);
  activateOnPath();
  console.log('');
  console.log('Then just run `fx` — same commands, same output, faster.');
  console.log('Stock anytime: FX_NO_COMPANION=1 fx …   ·   Sessions/skills/data untouched.');
  console.log('In any fx session: /benchmark runs the raw speed tests.');
}

function activateOnPath() {
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
          continue; // real file; retireOld handled known stock paths
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
