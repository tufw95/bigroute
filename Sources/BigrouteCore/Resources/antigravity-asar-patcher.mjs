#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const PATCH_CODE = "(() => { try { const os = require('os'); const fs = require('fs'); const ep = fs.readFileSync(require('path').join(os.homedir(), '.gemini', 'antigravity', 'cloud_code_endpoint.txt'), 'utf8').trim(); if (ep) return ep; } catch (e) {} return process.env.ANTIGRAVITY_CLOUD_CODE_ENDPOINT || 'https://daily-cloudcode-pa.googleapis.com'; })()";
export const PRELOAD_PATCH_MARKER = '/* BIGROUTE_PRELOAD_BRIDGE_INDICATOR */';
const PRELOAD_PATCH_CODE = `${PRELOAD_PATCH_MARKER}
(() => {
  try {
    const fs = require('fs');
    const path = require('path');
    const os = require('os');
    const epPath = path.join(os.homedir(), '.gemini', 'antigravity', 'cloud_code_endpoint.txt');

    function isBridgeEndpointActive() {
      try {
        if (!fs.existsSync(epPath)) return false;
        const ep = fs.readFileSync(epPath, 'utf8').trim();
        return ep.includes('127.0.0.1:50999') || ep.includes('localhost:50999');
      } catch (e) {
        return false;
      }
    }

    function applyIndicator() {
      const active = isBridgeEndpointActive();
      const settingsBtn = document.querySelector('[data-testid="settings-button"], button[aria-label="Settings"], button[aria-label="Settings (Proxy)"]');
      if (settingsBtn) {
        const spans = settingsBtn.querySelectorAll('span');
        for (const span of spans) {
          const text = (span.textContent || '').trim();
          if (active && text === 'Settings') {
            span.textContent = 'Settings (Proxy)';
          } else if (!active && text === 'Settings (Proxy)') {
            span.textContent = 'Settings';
          }
        }
        if (active) {
          if (settingsBtn.getAttribute('aria-label') === 'Settings') {
            settingsBtn.setAttribute('aria-label', 'Settings (Proxy)');
          }
          if (settingsBtn.getAttribute('title') === 'Settings') {
            settingsBtn.setAttribute('title', 'Settings (Proxy)');
          }
        } else {
          if (settingsBtn.getAttribute('aria-label') === 'Settings (Proxy)') {
            settingsBtn.setAttribute('aria-label', 'Settings');
          }
          if (settingsBtn.getAttribute('title') === 'Settings (Proxy)') {
            settingsBtn.setAttribute('title', 'Settings');
          }
        }
      }

      const tooltips = document.querySelectorAll('[role="tooltip"], [data-tooltip]');
      for (const tt of tooltips) {
        const text = (tt.textContent || '').trim();
        if (active && text === 'Settings') {
          tt.textContent = 'Settings (Proxy)';
        } else if (!active && text === 'Settings (Proxy)') {
          tt.textContent = 'Settings';
        }
      }
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', applyIndicator);
    } else {
      applyIndicator();
    }

    const observer = new MutationObserver(applyIndicator);
    observer.observe(document.documentElement, { childList: true, subtree: true });
  } catch (err) {}
})();
`;
const GOOGLE_DESIGNATED_REQUIREMENT = 'designated => anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = EQHXZ8M8AV';
const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120_000 });

export function getAppPaths(customAppPath) {
  const appPath = path.resolve(customAppPath || '/Applications/Antigravity.app');
  const asarPath = path.join(appPath, 'Contents', 'Resources', 'app.asar');
  const infoPlistPath = path.join(appPath, 'Contents', 'Info.plist');
  const shipItPath = path.join(appPath, 'Contents', 'Frameworks', 'Squirrel.framework', 'Versions', 'A', 'Resources', 'ShipIt');
  return { appPath, asarPath, infoPlistPath, shipItPath };
}

// ASAR uses two Chromium Pickles: a header size, followed by a JSON string.
// Edit only the packed launcher and preload script. Preserve every other file, link, unpacked flag
// and integrity record, without npm, network access or shell PATH dependencies.
export function readArchive(buffer) {
  if (buffer.length < 16 || buffer.readUInt32LE(0) !== 4) throw new Error('Invalid ASAR size header');
  const headerSize = buffer.readUInt32LE(4);
  const jsonSize = buffer.readUInt32LE(12);
  if (headerSize < 8 || headerSize % 4 !== 0 || 8 + headerSize > buffer.length
      || buffer.readUInt32LE(8) !== headerSize - 4 || jsonSize > headerSize - 8) {
    throw new Error('Invalid ASAR JSON header');
  }
  const headerJSON = buffer.subarray(16, 16 + jsonSize);
  const header = JSON.parse(headerJSON.toString('utf8'));
  const payload = buffer.subarray(8 + headerSize);
  return { header, payload, headerHash: sha256(headerJSON) };
}

function launcherFromArchive(archive) {
  const entry = archive.header.files?.dist?.files?.['languageServer.js'];
  if (!entry || entry.unpacked || entry.link || entry.files) throw new Error('Packed dist/languageServer.js not found in Antigravity');
  const offset = Number(entry.offset);
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(entry.size)
      || entry.size < 0 || offset + entry.size > archive.payload.length) throw new Error('Invalid languageServer.js bounds');
  const content = archive.payload.subarray(offset, offset + entry.size);
  if (entry.integrity && (entry.integrity.algorithm !== 'SHA256' || entry.integrity.hash !== sha256(content))) {
    throw new Error('languageServer.js integrity check failed');
  }
  return { entry, content };
}

function preloadFromArchive(archive) {
  const entry = archive.header.files?.dist?.files?.['preload.js'];
  if (!entry || entry.unpacked || entry.link || entry.files) return null;
  const offset = Number(entry.offset);
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(entry.size)
      || entry.size < 0 || offset + entry.size > archive.payload.length) return null;
  const content = archive.payload.subarray(offset, offset + entry.size);
  if (entry.integrity && (entry.integrity.algorithm !== 'SHA256' || entry.integrity.hash !== sha256(content))) {
    throw new Error('preload.js integrity check failed');
  }
  return { entry, content };
}

function encodeArchive(header, payload) {
  const json = Buffer.from(JSON.stringify(header));
  const headerSize = 8 + Math.ceil(json.length / 4) * 4;
  const prefix = Buffer.alloc(8 + headerSize);
  prefix.writeUInt32LE(4, 0);
  prefix.writeUInt32LE(headerSize, 4);
  prefix.writeUInt32LE(headerSize - 4, 8);
  prefix.writeUInt32LE(json.length, 12);
  json.copy(prefix, 16);
  return Buffer.concat([prefix, payload]);
}

export function patchArchive(buffer) {
  const archive = readArchive(buffer);
  const { entry: lsEntry, content: lsContent } = launcherFromArchive(archive);
  const lsSource = lsContent.toString('utf8');
  const lsNeedsPatch = !lsSource.includes(PATCH_CODE);

  const preloadInfo = preloadFromArchive(archive);
  const preloadNeedsPatch = preloadInfo !== null && !preloadInfo.content.toString('utf8').includes(PRELOAD_PATCH_MARKER);

  if (!lsNeedsPatch && !preloadNeedsPatch) {
    return { buffer, hash: archive.headerHash, alreadyPatched: true };
  }

  const appends = [];
  let currentOffset = archive.payload.length;

  if (lsNeedsPatch) {
    const target = /(['\"])--cloud_code_endpoint\1\s*,\s*(['\"])https:\/\/daily-cloudcode-pa\.googleapis\.com\2/g;
    const matches = [...lsSource.matchAll(target)];
    if (matches.length !== 1) throw new Error('Expected one Cloud Code endpoint argument in languageServer.js; this Antigravity version is not supported');
    const updatedLs = Buffer.from(lsSource.replace(target, match => match.slice(0, match.lastIndexOf(matches[0][2] + 'https://')) + PATCH_CODE));
    const blockSize = lsEntry.integrity?.blockSize ?? 4 * 1024 * 1024;
    if (!Number.isSafeInteger(blockSize) || blockSize <= 0) throw new Error('Invalid ASAR integrity block size');
    const blocks = [];
    for (let offset = 0; offset < updatedLs.length; offset += blockSize) blocks.push(sha256(updatedLs.subarray(offset, offset + blockSize)));
    lsEntry.offset = String(currentOffset);
    lsEntry.size = updatedLs.length;
    lsEntry.integrity = { algorithm: 'SHA256', hash: sha256(updatedLs), blockSize, blocks };
    appends.push(updatedLs);
    currentOffset += updatedLs.length;
  }

  if (preloadNeedsPatch && preloadInfo) {
    const updatedPreload = Buffer.from(preloadInfo.content.toString('utf8') + '\n' + PRELOAD_PATCH_CODE);
    const blockSize = preloadInfo.entry.integrity?.blockSize ?? 4 * 1024 * 1024;
    if (!Number.isSafeInteger(blockSize) || blockSize <= 0) throw new Error('Invalid ASAR integrity block size');
    const blocks = [];
    for (let offset = 0; offset < updatedPreload.length; offset += blockSize) blocks.push(sha256(updatedPreload.subarray(offset, offset + blockSize)));
    preloadInfo.entry.offset = String(currentOffset);
    preloadInfo.entry.size = updatedPreload.length;
    preloadInfo.entry.integrity = { algorithm: 'SHA256', hash: sha256(updatedPreload), blockSize, blocks };
    appends.push(updatedPreload);
    currentOffset += updatedPreload.length;
  }

  const patched = encodeArchive(archive.header, Buffer.concat([archive.payload, ...appends]));
  return { buffer: patched, hash: readArchive(patched).headerHash, alreadyPatched: false };
}

export function checkPatchStatus(customAppPath) {
  const { appPath, asarPath, infoPlistPath } = getAppPaths(customAppPath);
  const result = { appExists: fs.existsSync(appPath), isPatched: false, integrityMatches: false, drMatches: false, error: null };
  try {
    if (!result.appExists) throw new Error(`Antigravity.app not found at ${appPath}`);
    const archive = readArchive(fs.readFileSync(asarPath));
    const lsPatched = launcherFromArchive(archive).content.toString('utf8').includes(PATCH_CODE);
    const preloadInfo = preloadFromArchive(archive);
    const preloadPatched = preloadInfo === null || preloadInfo.content.toString('utf8').includes(PRELOAD_PATCH_MARKER);
    result.isPatched = lsPatched && preloadPatched;
    const plistHash = run('/usr/libexec/PlistBuddy', ['-c', 'Print :ElectronAsarIntegrity:Resources/app.asar:hash', infoPlistPath]).trim();
    result.integrityMatches = plistHash.toLowerCase() === archive.headerHash;
    result.drMatches = run('/usr/bin/codesign', ['-d', '-r-', appPath]).includes('EQHXZ8M8AV');
  } catch (error) {
    result.error = error.message;
  }
  return result;
}

export function applyPatch(customAppPath) {
  const { appPath, asarPath } = getAppPaths(customAppPath);
  const status = checkPatchStatus(appPath);
  if (!status.appExists) throw new Error(status.error);
  if (status.isPatched && status.integrityMatches && status.drMatches) {
    return { status: 'ok', patched: true, alreadyPatched: true };
  }
  const original = fs.readFileSync(asarPath);
  const patched = patchArchive(original); // Refuse unknown formats before any writes.
  const stagingDir = fs.mkdtempSync(path.join(path.dirname(appPath), '.bigroute-antigravity-'));
  const staged = getAppPaths(path.join(stagingDir, 'Antigravity.app'));
  const backupPath = path.join(stagingDir, 'Original.app');
  let backedUp = false;
  try {
    run('/usr/bin/ditto', [appPath, staged.appPath]);
    fs.writeFileSync(staged.asarPath, patched.buffer);
    run('/usr/libexec/PlistBuddy', ['-c', `Set :ElectronAsarIntegrity:Resources/app.asar:hash ${patched.hash}`, staged.infoPlistPath]);
    // Only the outer bundle changed. Keep Google's signed helpers/frameworks
    // (including ShipIt) intact; --deep would replace their valid signatures.
    run('/usr/bin/codesign', ['--force', '-s', '-', '--preserve-metadata=entitlements', '-r', `=${GOOGLE_DESIGNATED_REQUIREMENT}`, staged.appPath]);
    // The local ad-hoc signature cannot satisfy Google's certificate DR. Keep
    // that DR for Squirrel's incoming official updates, but verify the local
    // seal and all nested code with an explicit bundle-identity requirement.
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '-R', '=identifier "com.google.antigravity"', staged.appPath]);
    const verification = checkPatchStatus(staged.appPath);
    if (!verification.isPatched || !verification.integrityMatches || !verification.drMatches) {
      throw new Error(`Patched Antigravity verification failed: ${verification.error ?? 'archive or signature mismatch'}`);
    }
    if (!fs.readFileSync(asarPath).equals(original)) throw new Error('Antigravity changed during repair; retry after its update finishes');
    fs.renameSync(appPath, backupPath);
    backedUp = true;
    try {
      fs.renameSync(staged.appPath, appPath);
    } catch (error) {
      fs.renameSync(backupPath, appPath);
      backedUp = false;
      throw error;
    }
    // Retain the complete previous signed app outside its bundle for rollback.
    return { status: 'ok', patched: true, hash: patched.hash, backupPath };
  } finally {
    if (!backedUp) fs.rmSync(stagingDir, { recursive: true, force: true });
  }
}

// Importing this module in tests must never execute the CLI or touch a real app.
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const mode = process.argv[2] || 'check';
  try {
    if (mode === 'check') {
      const result = checkPatchStatus(process.argv[3]);
      console.log(JSON.stringify(result));
      process.exitCode = result.isPatched && result.integrityMatches && result.drMatches ? 0 : 1;
    } else if (mode === 'patch') {
      console.log(JSON.stringify(applyPatch(process.argv[3])));
    } else {
      throw new Error('Usage: node antigravity-asar-patcher.mjs [check|patch] [appPath]');
    }
  } catch (error) {
    console.error(JSON.stringify({ status: 'error', message: error.message }));
    process.exitCode = 2;
  }
}
