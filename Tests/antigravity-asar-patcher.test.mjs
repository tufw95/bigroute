import test from 'node:test';
import assert from 'node:assert/strict';
import { checkPatchStatus, applyPatch, getAppPaths } from '../Sources/BigrouteCore/Resources/antigravity-asar-patcher.mjs';

test('getAppPaths generates expected subpaths', () => {
  const paths = getAppPaths('/Custom/Path/Antigravity.app');
  assert.equal(paths.appPath, '/Custom/Path/Antigravity.app');
  assert.equal(paths.asarPath, '/Custom/Path/Antigravity.app/Contents/Resources/app.asar');
  assert.equal(paths.infoPlistPath, '/Custom/Path/Antigravity.app/Contents/Info.plist');
});

test('checkPatchStatus handles nonexistent app gracefully', () => {
  const status = checkPatchStatus('/tmp/nonexistent-app-' + Date.now() + '.app');
  assert.equal(status.appExists, false);
  assert.equal(status.isPatched, false);
});

test('checkPatchStatus against current Antigravity.app succeeds', () => {
  const status = checkPatchStatus('/Applications/Antigravity.app');
  assert.equal(status.appExists, true);
  assert.equal(status.isPatched, true);
  assert.equal(status.integrityMatches, true);
});

test('applyPatch is idempotent when app is already patched', () => {
  const result = applyPatch('/Applications/Antigravity.app');
  assert.equal(result.status, 'ok');
  assert.equal(result.patched, true);
  assert.equal(result.alreadyPatched, true);
});
