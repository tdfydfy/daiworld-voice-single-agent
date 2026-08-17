const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionPolicy() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/VoiceControlPolicy.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^export type[\s\S]*?;\r?\n/m, '');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(
    /:\s*(?:string\[\]|string|boolean|VoiceControlAction)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('voice controls resolve from one production policy', async () => {
  const { VoiceControlPolicy } = await loadProductionPolicy();

  assert.equal(VoiceControlPolicy.resolve('停止任务。'), 'stop_task');
  assert.equal(VoiceControlPolicy.resolve('关闭话筒'), 'close_microphone');
  assert.equal(VoiceControlPolicy.resolve('打开话筒'), 'open_microphone');
  assert.equal(VoiceControlPolicy.resolve('退出软件'), 'exit_application');
});

test('exit command is exact after whitespace and punctuation normalization', async () => {
  const { VoiceControlPolicy } = await loadProductionPolicy();

  assert.equal(VoiceControlPolicy.resolve('退 出 软 件！'), 'exit_application');
  assert.equal(VoiceControlPolicy.resolve('退出软件后提醒我'), 'none');
  assert.equal(VoiceControlPolicy.resolve('请退出软件'), 'none');
});
