const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', 'clients/harmony');
const appScopeIcon = fs.readFileSync(path.join(
  root,
  'AppScope/resources/base/media/app_icon_v3.svg',
), 'utf8');
const entryIcon = fs.readFileSync(path.join(
  root,
  'entry/src/main/resources/base/media/app_icon_v3.svg',
), 'utf8');
const appConfig = fs.readFileSync(path.join(root, 'AppScope/app.json5'), 'utf8');
const moduleConfig = fs.readFileSync(path.join(root, 'entry/src/main/module.json5'), 'utf8');

test('launcher icon copies remain identical', () => {
  assert.equal(entryIcon, appScopeIcon);
});

test('launcher and start window use the cache-busting icon resource', () => {
  assert.match(appConfig, /"icon": "\$media:app_icon_v3"/);
  assert.match(moduleConfig, /"icon": "\$media:app_icon_v3"/);
  assert.match(moduleConfig, /"startWindowIcon": "\$media:app_icon_v3"/);
});

test('launcher icon uses the voice mark and avoids the old default waveform', () => {
  assert.match(appScopeIcon, /<rect width="512" height="512" rx="112" fill="#0F1718"\/>/);
  assert.match(appScopeIcon, /<circle cx="256" cy="256" r="164" fill="#172729"\/>/);
  assert.match(appScopeIcon, /<rect x="212" y="122" width="88" height="178" rx="44" fill="#55E1C1"\/>/);
  assert.match(appScopeIcon, /stroke="#F4F7F5"/);
  assert.equal((appScopeIcon.match(/fill="#F4B66A"/g) || []).length, 2);
  assert.doesNotMatch(appScopeIcon, /#101312|#45C2A3|gradient/);
});
