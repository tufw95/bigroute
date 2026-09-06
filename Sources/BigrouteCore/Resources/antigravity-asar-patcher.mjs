#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execSync } from 'node:child_process';

const TARGET_STR = "'https://daily-cloudcode-pa.googleapis.com'";
const PATCH_CODE = "(() => { try { const os = require('os'); const fs = require('fs'); const ep = fs.readFileSync(require('path').join(os.homedir(), '.gemini', 'antigravity', 'cloud_code_endpoint.txt'), 'utf8').trim(); if (ep) return ep; } catch (e) {} return process.env.ANTIGRAVITY_CLOUD_CODE_ENDPOINT || 'https://daily-cloudcode-pa.googleapis.com'; })()";

export function getAppPaths(customAppPath) {
  const appPath = customAppPath || '/Applications/Antigravity.app';
  const asarPath = path.join(appPath, 'Contents', 'Resources', 'app.asar');
  const infoPlistPath = path.join(appPath, 'Contents', 'Info.plist');
  const shipItPath = path.join(appPath, 'Contents', 'Frameworks', 'Squirrel.framework', 'Versions', 'A', 'Resources', 'ShipIt');
  return { appPath, asarPath, infoPlistPath, shipItPath };
}

export function checkPatchStatus(customAppPath) {
  const { appPath, asarPath, infoPlistPath } = getAppPaths(customAppPath);
  if (!fs.existsSync(appPath)) {
    return { appExists: false, isPatched: false, error: 'Antigravity.app not found' };
  }
  if (!fs.existsSync(asarPath)) {
    return { appExists: true, isPatched: false, error: 'app.asar not found' };
  }
  try {
    const buf = fs.readFileSync(asarPath);
    const isPatched = buf.includes('cloud_code_endpoint.txt');
    let integrityMatches = false;
    if (fs.existsSync(infoPlistPath)) {
      const hash = crypto.createHash('sha256').update(buf).digest('hex');
      try {
        const plistHash = execSync(`/usr/libexec/PlistBuddy -c "Print :ElectronAsarIntegrity:Resources/app.asar:hash" "${infoPlistPath}" 2>/dev/null`, { encoding: 'utf8' }).trim();
        integrityMatches = (plistHash.toLowerCase() === hash.toLowerCase());
      } catch {}
    }
    return { appExists: true, isPatched, integrityMatches, error: null };
  } catch (err) {
    return { appExists: true, isPatched: false, error: err.message };
  }
}

export function applyPatch(customAppPath) {
  const { appPath, asarPath, infoPlistPath, shipItPath } = getAppPaths(customAppPath);
  const status = checkPatchStatus(customAppPath);
  if (!status.appExists) {
    throw new Error(`Antigravity.app not found at ${appPath}`);
  }
  if (status.isPatched && status.integrityMatches) {
    return { status: 'ok', patched: true, alreadyPatched: true };
  }

  const tempDir = fs.mkdtempSync(path.join('/tmp', 'agy-patch-'));
  try {
    // Extract asar
    execSync(`npx --yes asar extract "${asarPath}" "${tempDir}"`, { stdio: 'pipe' });

    const lsPath = path.join(tempDir, 'dist', 'languageServer.js');
    if (!fs.existsSync(lsPath)) {
      throw new Error(`languageServer.js not found in extracted asar at ${lsPath}`);
    }

    let content = fs.readFileSync(lsPath, 'utf8');
    if (!content.includes('cloud_code_endpoint.txt')) {
      if (!content.includes(TARGET_STR)) {
        throw new Error('Target endpoint string not found in languageServer.js');
      }
      content = content.replace(TARGET_STR, PATCH_CODE);
      fs.writeFileSync(lsPath, content, 'utf8');
    }

    // Repack asar preserving unpacked node_modules if any
    const repackedAsar = path.join(tempDir, 'repacked.asar');
    const unpackedDir = path.join(appPath, 'Contents', 'Resources', 'app.asar.unpacked');
    let packCmd = `npx --yes asar pack "${tempDir}" "${repackedAsar}"`;
    if (fs.existsSync(unpackedDir)) {
      packCmd += ' --unpack-dir "node_modules/chrome-devtools-mcp"';
    }
    execSync(packCmd, { stdio: 'pipe' });

    // Atomically replace app.asar
    fs.copyFileSync(repackedAsar, asarPath);

    // Update ElectronAsarIntegrity in Info.plist
    const newBuf = fs.readFileSync(asarPath);
    const newHash = crypto.createHash('sha256').update(newBuf).digest('hex');
    execSync(`/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash ${newHash}" "${infoPlistPath}"`, { stdio: 'pipe' });

    // Codesign ShipIt if present (prevents dyld Team ID mismatch on Mantle.framework)
    if (fs.existsSync(shipItPath)) {
      try {
        execSync(`codesign --force -s - "${shipItPath}"`, { stdio: 'pipe' });
      } catch {}
    }

    // Deep ad-hoc codesign of the entire app bundle
    execSync(`codesign --force --deep -s - "${appPath}"`, { stdio: 'pipe' });

    return { status: 'ok', patched: true, hash: newHash };
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

// CLI entry point
const mode = process.argv[2] || 'check';
const targetApp = process.argv[3];

if (mode === 'check') {
  const result = checkPatchStatus(targetApp);
  console.log(JSON.stringify(result));
  process.exit(result.isPatched && result.integrityMatches ? 0 : 1);
} else if (mode === 'patch') {
  try {
    const result = applyPatch(targetApp);
    console.log(JSON.stringify(result));
    process.exit(0);
  } catch (err) {
    console.error(JSON.stringify({ status: 'error', message: err.message }));
    process.exit(2);
  }
} else {
  console.error(`Usage: node antigravity-asar-patcher.mjs [check|patch] [appPath]`);
  process.exit(1);
}
