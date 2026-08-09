const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'web_native/index.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'web_native/styles.css'), 'utf8');
const app = fs.readFileSync(path.join(root, 'web_native/app.js'), 'utf8');

function mobileCss() {
  return css.split('@media(max-width:640px){')[1].split('@media(max-width:420px)')[0];
}

test('mobile footer is voice-first and text composer is secondary', () => {
  assert.match(html, /id="textToggle"/);
  assert.doesNotMatch(html, /id="voiceStatus"/);
  assert.match(mobileCss(), /\.text-composer-row\{display:none/);
  assert.match(mobileCss(), /\.composer-bar\.text-open \.text-composer-row\{display:flex/);
  assert.match(mobileCss(), /\.voice-row\{display:flex/);
  assert.match(mobileCss(), /\.stop:disabled\{display:none\}/);
});

test('microphone button exposes only enabled and disabled labels', () => {
  assert.match(app, /voiceEnabled\?'关闭实时对话':'开启实时对话'/);
  assert.doesNotMatch(app, /voiceStatus/);
  assert.match(app, /aria-pressed/);
});

test('mobile header hides runtime detail while message identity keeps provider', () => {
  assert.match(mobileCss(), /\.runtime\{display:none\}/);
  assert.match(app, /provider\?' · '\+provider/);
  assert.match(app, /activityRow\('status','当前状态',text\)/);
  assert.match(css, /\.conn\.online::before\{box-shadow:/);
  assert.match(css, /\.conn\.connecting/);
});
