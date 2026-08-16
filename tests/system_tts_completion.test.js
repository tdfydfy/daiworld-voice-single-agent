const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadCompletionGate() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/SystemTtsCompletionGate.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^export type .*;\r?\n/gm, '');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(
    /:\s*(?:SystemTtsPlaybackEvent|void|number|string|boolean)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

function readService(name) {
  return fs.readFileSync(path.resolve(
    __dirname,
    `../clients/harmony/entry/src/main/ets/services/${name}.ets`,
  ), 'utf8');
}

test('completion before plausible playback duration is an interruption', async () => {
  const { SystemTtsCompletionGate } = await loadCompletionGate();
  const gate = new SystemTtsCompletionGate();

  gate.begin('这是用于验证系统语音播放完成时长的一段中文测试文本', 1);
  gate.markStarted(10_000);

  assert.equal(gate.classifyCompletion(10_002), 'interrupted');
  assert.equal(gate.classifyCompletion(20_000), 'completed');
});

test('completion without a start callback is not trusted', async () => {
  const { SystemTtsCompletionGate } = await loadCompletionGate();
  const gate = new SystemTtsCompletionGate();

  gate.begin('completion requires a preceding start callback', 1);

  assert.equal(gate.classifyCompletion(10_000), 'interrupted');
});

test('interrupted system speech retains the active queue segment', () => {
  const source = readService('VoiceOutputCoordinator');
  const start = source.indexOf('onSystemSpeechState(');
  const body = source.slice(start, source.indexOf('onSystemSpeechError(', start));
  const interrupted = body.indexOf("event === 'interrupted'");
  const completion = body.indexOf('this.systemSpeechQueue.completeActive()');

  assert.ok(interrupted > 0);
  assert.ok(completion > interrupted);
  assert.match(body.slice(interrupted, completion), /this\.scheduleSystemSpeechRetry\(token\)[\s\S]*return/);
  assert.doesNotMatch(body.slice(interrupted, completion), /completeActive\(\)/);
});

test('page visibility resumes only a suspended complete segment', () => {
  const output = readService('VoiceOutputCoordinator');
  const controller = readService('SingleAgentController');

  assert.match(output, /resumeSuspendedSystemSpeech\(\): void[\s\S]{0,700}this\.systemSpeechQueue\.active\(\)/);
  assert.match(controller, /onPageVisible\(\): void[\s\S]{0,120}resumeSuspendedSystemSpeech\(\)/);
});
