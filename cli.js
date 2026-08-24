#!/usr/bin/env node
/**
 * fx-companion — boosted fx for Apple Silicon.
 *
 *   npx github:ChloeVPin/fx-companion            install (default)
 *   npx github:ChloeVPin/fx-companion status     check what's installed
 *
 * Downloads the prebuilt boosted fx binary from GitHub Releases, retires any
 * previously installed stock fx executables (backed up, user data untouched),
 * and prints the PATH line to activate.
 */
'use strict';

const { execFileSync, spawnSync } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const VERSION = require('./package.json').version;
const REPO = 'ChloeVPin/fx-companion';
const INSTALL_DIR = path.join(os.homedir(), '.fx-companion', 'bin');
const TARGET = `fx-boosted-macos-arm64-v${VERSION}.tar.gz`;

const err = (msg) => {
  console.error(`fx-companion: ${msg}`);
  process.exit(1);
};

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { stdio: opts.capture ? 'pipe' : 'inherit', encoding: 'utf8', ...opts });
}

async function download(url, dest) {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) err(`download failed (${res.status}): ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(dest, buf);
  return buf;
}

function retireOld() {
  // Move previously installed stock fx binaries aside. User data in ~/.fx
  // (sessions, chats, skills, settings) is never touched.
  for (const p of [
    path.join(os.homedir(), '.local/bin/fx'),
    '/usr/local/bin/fx',
    path.join(INSTALL_DIR, 'fx.stock'), // no-op safeguard
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

  console.log(`fx-companion v${VERSION} — installing boosted fx…`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fxc-'));
  const tgz = path.join(tmp, TARGET);

  process.stdout.write('↓ downloading prebuilt binary…\n');
  const buf = await download(
    `https://github.com/${REPO}/releases/download/v${VERSION}/${TARGET}`,
    tgz,
  );

  process.stdout.write('🔒 verifying checksum…\n');
  let expected = null;
  try {
    const sum = await (
      await fetch(`https://github.com/${REPO}/releases/download/v${VERSION}/SHA256SUMS`, { redirect: 'follow' })
    ).text();
    for (const line of sum.split('\n')) {
      const [hash, name] = line.trim().split(/\s+/);
      if (name === TARGET) expected = hash;
    }
  } catch {}
  const actual = crypto.createHash('sha256').update(buf).digest('hex');
  if (expected && expected !== actual) err(`checksum mismatch!\n  expected ${expected}\n  actual   ${actual}`);
  console.log(expected ? '✓ checksum ok' : '⚠ checksum file unavailable, skipped verification');

  retireOld();

  fs.mkdirSync(INSTALL_DIR, { recursive: true });
  sh('tar', ['-xzf', tgz, '-C', tmp]);
  const built = path.join(tmp, 'fx');
  if (!fs.existsSync(built)) err('archive did not contain an fx binary');
  fs.copyFileSync(built, path.join(INSTALL_DIR, 'fx'));
  fs.chmodSync(path.join(INSTALL_DIR, 'fx'), 0o755);
  fs.rmSync(tmp, { recursive: true, force: true });

  console.log(`✓ installed ${INSTALL_DIR}/fx`);
  console.log('');
  console.log('Activate (one time) — add to your ~/.zshrc:');
  console.log(`  export PATH="${INSTALL_DIR}:$PATH"`);
  console.log('');
  console.log('Then just run `fx` — same commands, same output, faster.');
  console.log('Stock anytime: FX_NO_COMPANION=1 fx …   ·   Sessions/skills/data untouched.');
}

function status() {
  const bin = path.join(INSTALL_DIR, 'fx');
  if (!fs.existsSync(bin)) return console.log('boosted fx: not installed (run without arguments to install)');
  const v = sh(bin, ['--version'], { capture: true });
  const hasBooster = (() => {
    try {
      const out = sh('strings', [bin], { capture: true });
      return out.stdout.includes('FX_NO_COMPANION');
    } catch {
      return '?';
    }
  })();
  console.log(`${bin} → v${(v.stdout || '').trim()} · booster: ${hasBooster ? 'PRESENT ✦' : 'absent'}`);
  const w = sh('which', ['fx'], { capture: true });
  console.log(`which fx → ${(w.stdout || '').trim() || '(not on PATH)'}`);
}

(async () => {
  const cmd = process.argv[2] || 'install';
  if (cmd === 'install') await install();
  else if (cmd === 'status') status();
  else if (cmd === '--version' || cmd === '-v') console.log(VERSION);
  else {
    console.log('usage: npx github:ChloeVPin/fx-companion [install|status]');
    process.exit(cmd === '-h' || cmd === '--help' ? 0 : 1);
  }
})();
