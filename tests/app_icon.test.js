const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', 'clients/harmony');
const appScopeIcon = fs.readFileSync(path.join(
  root,
  'AppScope/resources/base/media/app_icon_v2.svg',
), 'utf8');
const entryIcon = fs.readFileSync(path.join(
  root,
  'entry/src/main/resources/base/media/app_icon_v2.svg',
), 'utf8');
const appConfig = fs.readFileSync(path.join(root, 'AppScope/app.json5'), 'utf8');
const moduleConfig = fs.readFileSync(path.join(root, 'entry/src/main/module.json5'), 'utf8');

test('launcher icon copies remain identical', () => {
  assert.equal(entryIcon, appScopeIcon);
});

test('launcher and start window use the cache-busting icon resource', () => {
  assert.match(appConfig, /"icon": "\$media:app_icon_v2"/);
  assert.match(moduleConfig, /"icon": "\$media:app_icon_v2"/);
  assert.match(moduleConfig, /"startWindowIcon": "\$media:app_icon_v2"/);
});

test('launcher mask owns the outer shape and the mark is a simple waveform', () => {
  assert.match(appScopeIcon, /<rect width="512" height="512" fill="#101312"\/>/);
  assert.equal((appScopeIcon.match(/<rect /g) || []).length, 6);
  assert.equal((appScopeIcon.match(/fill="#E8ECEA"/g) || []).length, 4);
  assert.equal((appScopeIcon.match(/fill="#45C2A3"/g) || []).length, 1);
  assert.doesNotMatch(appScopeIcon, /<circle|<path|gradient/);
});
