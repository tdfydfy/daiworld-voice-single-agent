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
  assert.doesNotMatch(mobileCss(), /\.stop:disabled\{display:none\}/);
});

test('microphone button exposes only enabled and disabled labels', () => {
  assert.match(app, /voiceEnabled\?'关闭实时对话':'开启实时对话'/);
  assert.doesNotMatch(app, /voiceStatus/);
  assert.match(app, /aria-pressed/);
});

test('usage tips are concise and live behind the help entry', () => {
  assert.match(html, /id="helpButton"/);
  assert.match(html, /id="helpBackdrop"[^>]*hidden/);
  assert.equal((html.match(/<div class="help-content">[\s\S]*?<\/div>/)?.[0].match(/<p>/g) || []).length, 4);
  assert.match(html, /说“停止”或点击“停止”可终止当前任务/);
  assert.doesNotMatch(html, /模型、Provider和执行过程/);
  assert.match(app, /\$\('helpButton'\)\.onclick=openHelp/);
  assert.match(app, /helpBackdrop\.onclick/);
});

test('mobile header hides runtime detail while message identity keeps provider', () => {
  assert.match(mobileCss(), /\.runtime\{display:none\}/);
  assert.match(app, /provider\?' · '\+provider/);
  assert.match(app, /activityRow\('status','当前状态',text\)/);
  assert.match(css, /\.conn\.online::before\{box-shadow:/);
  assert.match(css, /\.conn\.connecting/);
});

test('settings exposes Hermes model switching without config-file editing', () => {
  assert.match(html, /id="settingsButton"/);
  assert.match(html, /id="settingsBackdrop"[^>]*hidden/);
  assert.match(html, /id="providerSelect"/);
  assert.match(html, /id="modelSelect"/);
  assert.match(app, /config\.set/);
  assert.match(app, /api\/hermes\/model\/options/);
});

test('messages expose replay and thinking renders as separate lines', () => {
  assert.match(app, /message-replay/);
  assert.match(app, /splitThinkingLines/);
  assert.match(css, /\.thinking-line/);
});

test('voice input filters punctuation and supports close-microphone command', () => {
  assert.match(app, /hasSemanticContent/);
  assert.match(app, /isCloseMicCommand/);
  assert.match(html, /“闭麦”/);
});
