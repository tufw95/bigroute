import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import { spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { checkPatchStatus, applyPatch, getAppPaths, patchArchive, readArchive } from '../Sources/BigrouteCore/Resources/antigravity-asar-patcher.mjs';

const script = fileURLToPath(new URL('../Sources/BigrouteCore/Resources/antigravity-asar-patcher.mjs', import.meta.url));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const official = 'https://daily-cloudcode-pa.googleapis.com';
const source = `const args = ['--cloud_code_endpoint', '${official}', '--enable_sidecars']; args;`;

// Independent fixture writer for Chromium's two length-prefixed Pickles.
function fixture(launcher = source) {
  const before = Buffer.from('other packed bytes');
  const content = Buffer.from(launcher);
  const after = Buffer.from('last packed file');
  const header = { files: {
    'before.txt': { offset: '0', size: before.length },
    dist: { files: { 'languageServer.js': {
      offset: String(before.length), size: content.length,
      integrity: { algorithm: 'SHA256', hash: hash(content), blockSize: 32, blocks: [] }
    } } },
    'after.txt': { offset: String(before.length + content.length), size: after.length },
    native: { files: { 'module.node': { size: 123, unpacked: true } }, unpacked: true },
    alias: { link: 'before.txt' }
  } };
  const json = Buffer.from(JSON.stringify(header));
  const padding = (4 - json.length % 4) % 4;
  const prefix = Buffer.alloc(16);
  prefix.writeUInt32LE(4, 0);
  prefix.writeUInt32LE(8 + json.length + padding, 4);
  prefix.writeUInt32LE(4 + json.length + padding, 8);
  prefix.writeUInt32LE(json.length, 12);
  return Buffer.concat([prefix, json, Buffer.alloc(padding), before, content, after]);
}

function launcher(buffer) {
  const { header, payload } = readArchive(buffer);
  const entry = header.files.dist.files['languageServer.js'];
  return payload.subarray(Number(entry.offset), Number(entry.offset) + entry.size);
}

test('patch preserves packed files, links and unpacked metadata and is idempotent', () => {
  const original = fixture();
  const originalCopy = Buffer.from(original);
  const patched = patchArchive(original);
  assert.deepEqual(original, originalCopy);
  assert.equal(patched.alreadyPatched, false);
  const old = readArchive(original);
  const next = readArchive(patched.buffer);
  for (const name of ['before.txt', 'after.txt', 'native', 'alias']) {
    assert.deepEqual(next.header.files[name], old.header.files[name]);
  }
  assert.deepEqual(next.payload.subarray(0, old.payload.length), old.payload);
  const content = launcher(patched.buffer);
  const integrity = next.header.files.dist.files['languageServer.js'].integrity;
  assert.equal(integrity.hash, hash(content));
  assert.deepEqual(integrity.blocks, Array.from({ length: Math.ceil(content.length / 32) }, (_, i) => hash(content.subarray(i * 32, (i + 1) * 32))));
  assert.equal(patched.hash, hash(patched.buffer.subarray(16, 16 + patched.buffer.readUInt32LE(12))));
  assert.notEqual(patched.hash, hash(patched.buffer));
  assert.deepEqual(patchArchive(patched.buffer), { buffer: patched.buffer, hash: patched.hash, alreadyPatched: true });
});

test('patches preload.js to inject bridge proxy indicator when present', () => {
  const launcherContent = Buffer.from(source);
  const preloadContent = Buffer.from('const x = 1;\n');
  const header = { files: {
    dist: { files: {
      'languageServer.js': {
        offset: '0', size: launcherContent.length,
        integrity: { algorithm: 'SHA256', hash: hash(launcherContent), blockSize: 32, blocks: [] }
      },
      'preload.js': {
        offset: String(launcherContent.length), size: preloadContent.length,
        integrity: { algorithm: 'SHA256', hash: hash(preloadContent), blockSize: 32, blocks: [] }
      }
    } }
  } };
  const json = Buffer.from(JSON.stringify(header));
  const padding = (4 - json.length % 4) % 4;
  const prefix = Buffer.alloc(16);
  prefix.writeUInt32LE(4, 0);
  prefix.writeUInt32LE(8 + json.length + padding, 4);
  prefix.writeUInt32LE(4 + json.length + padding, 8);
  prefix.writeUInt32LE(json.length, 12);
  const original = Buffer.concat([prefix, json, Buffer.alloc(padding), launcherContent, preloadContent]);

  const patched = patchArchive(original);
  assert.equal(patched.alreadyPatched, false);
  const next = readArchive(patched.buffer);
  const patchedPreloadEntry = next.header.files.dist.files['preload.js'];
  const patchedPreload = next.payload.subarray(Number(patchedPreloadEntry.offset), Number(patchedPreloadEntry.offset) + patchedPreloadEntry.size).toString('utf8');
  assert.ok(patchedPreload.includes('BIGROUTE_PRELOAD_BRIDGE_INDICATOR'));
  assert.ok(patchedPreload.includes('Settings (Proxy)'));

  // Test idempotency
  const doublePatched = patchArchive(patched.buffer);
  assert.equal(doublePatched.alreadyPatched, true);
});

test('patched launcher reads endpoint override, environment fallback and official default', () => {
  const code = launcher(patchArchive(fixture()).buffer).toString();
  function evaluate(endpoint, environment = {}) {
    return vm.runInNewContext(code, { process: { env: environment }, require(name) {
      if (name === 'os') return { homedir: () => '/home/test' };
      if (name === 'path') return path;
      if (name === 'fs') return { readFileSync(file) {
        assert.equal(file, '/home/test/.gemini/antigravity/cloud_code_endpoint.txt');
        if (endpoint === null) throw new Error('missing');
        return endpoint;
      } };
      throw new Error(`Unexpected module ${name}`);
    } });
  }
  assert.equal(evaluate(' http://127.0.0.1:50999\n')[1], 'http://127.0.0.1:50999');
  assert.equal(evaluate(null)[1], official);
  assert.equal(evaluate('', { ANTIGRAVITY_CLOUD_CODE_ENDPOINT: 'http://localhost:50999' })[1], 'http://localhost:50999');
  assert.equal(evaluate(null)[2], '--enable_sidecars');
});

test('targets the endpoint argument with either quote style and refuses unknown or ambiguous launchers', () => {
  const unrelated = `const url = '${official}';\n`;
  assert.ok(launcher(patchArchive(fixture(unrelated + source)).buffer).toString().startsWith(unrelated));
  assert.ok(launcher(patchArchive(fixture(source.replaceAll("'", '"'))).buffer).toString().includes('cloud_code_endpoint.txt'));
  assert.throws(() => patchArchive(fixture('const args = [];')), /not supported/);
  assert.throws(() => patchArchive(fixture(source + source)), /not supported/);
});

test('rejects malformed archives and corrupted launchers before mutation', () => {
  assert.throws(() => patchArchive(Buffer.from('invalid')), /Invalid ASAR/);
  const invalid = fixture();
  invalid.writeUInt32LE(0xffffffff, 4);
  assert.throws(() => patchArchive(invalid), /Invalid ASAR/);
  const corrupt = fixture();
  const archive = readArchive(corrupt);
  const entry = archive.header.files.dist.files['languageServer.js'];
  corrupt[8 + corrupt.readUInt32LE(4) + Number(entry.offset)] ^= 1;
  assert.throws(() => patchArchive(corrupt), /integrity check failed/);
});

test('module import works without running the CLI and CLI check needs no npm in PATH', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(new URL('../Sources/BigrouteCore/Resources/antigravity-asar-patcher.mjs', import.meta.url).href)}); console.log('imported');`], { encoding: 'utf8', env: { ...process.env, PATH: '/usr/bin:/bin' } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), 'imported');
  const check = spawnSync(process.execPath, [script, 'check', '/nonexistent-antigravity-test.app'], { encoding: 'utf8', env: { ...process.env, PATH: '/usr/bin:/bin' } });
  assert.equal(check.status, 1);
  assert.equal(JSON.parse(check.stdout).appExists, false);
});

test('status checks header hash, not whole archive hash, in a temporary app', { skip: process.platform !== 'darwin' }, t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bigroute-patcher-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const app = getAppPaths(path.join(dir, 'App with spaces.app'));
  fs.mkdirSync(path.dirname(app.asarPath), { recursive: true });
  const patched = patchArchive(fixture());
  fs.writeFileSync(app.asarPath, patched.buffer);
  fs.writeFileSync(app.infoPlistPath, `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>ElectronAsarIntegrity</key><dict><key>Resources/app.asar</key><dict><key>hash</key><string>${patched.hash}</string></dict></dict></dict></plist>`);
  let status = checkPatchStatus(app.appPath);
  assert.equal(status.isPatched, true);
  assert.equal(status.integrityMatches, true);
  execFileSync('/usr/libexec/PlistBuddy', ['-c', `Set :ElectronAsarIntegrity:Resources/app.asar:hash ${hash(patched.buffer)}`, app.infoPlistPath]);
  status = checkPatchStatus(app.appPath);
  assert.equal(status.integrityMatches, false);
  const original = fs.readFileSync(app.asarPath);
  assert.throws(() => applyPatch(app.appPath)); // Not a signable app: original stays intact.
  assert.deepEqual(fs.readFileSync(app.asarPath), original);
  assert.deepEqual(fs.readdirSync(dir), ['App with spaces.app']);
});

test('repairs and verifies a signed fixture offline with GUI PATH, preserving nested signatures and backup', { skip: process.platform !== 'darwin' }, t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bigroute-patcher-signed-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const app = getAppPaths(path.join(dir, 'App with spaces.app'));
  fs.mkdirSync(path.dirname(app.asarPath), { recursive: true });
  fs.mkdirSync(path.join(app.appPath, 'Contents', 'MacOS'));
  const helperPath = path.join(app.appPath, 'Contents', 'Helpers', 'ShipIt');
  fs.mkdirSync(path.dirname(helperPath), { recursive: true });
  fs.copyFileSync('/bin/echo', path.join(app.appPath, 'Contents', 'MacOS', 'Test'));
  fs.copyFileSync('/bin/echo', helperPath);
  const nestedBefore = fs.readFileSync(helperPath);
  const original = fixture();
  fs.writeFileSync(app.asarPath, original);
  fs.writeFileSync(app.infoPlistPath, `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.google.antigravity</string><key>CFBundleExecutable</key><string>Test</string><key>CFBundlePackageType</key><string>APPL</string><key>ElectronAsarIntegrity</key><dict><key>Resources/app.asar</key><dict><key>hash</key><string>${readArchive(original).headerHash}</string></dict></dict></dict></plist>`);
  execFileSync('/usr/bin/codesign', ['--force', '-s', '-', app.appPath], { stdio: 'pipe' });
  const result = spawnSync(process.execPath, [script, 'patch', app.appPath], { encoding: 'utf8', env: { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin' } });
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.deepEqual(fs.readFileSync(getAppPaths(output.backupPath).asarPath), original);
  assert.deepEqual(fs.readFileSync(helperPath), nestedBefore);
  assert.deepEqual(checkPatchStatus(app.appPath), { appExists: true, isPatched: true, integrityMatches: true, drMatches: true, error: null });
  assert.equal(applyPatch(app.appPath).alreadyPatched, true);
  assert.equal(fs.readdirSync(dir).length, 2); // One app and one complete rollback copy.
});
