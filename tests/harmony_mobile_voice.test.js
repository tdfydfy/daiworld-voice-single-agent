const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const harmonyRoot = path.resolve(__dirname, '../clients/harmony');

function read(relativePath) {
  return fs.readFileSync(path.join(harmonyRoot, relativePath), 'utf8');
}

function methodBody(source, signature, nextSignature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `missing ${signature}`);
  const end = source.indexOf(nextSignature, start);
  assert.ok(end > start, `missing boundary ${nextSignature}`);
  return source.slice(start, end);
}

test('mobile instructions are editable, persistent, and sent only when a session is created', () => {
  const settings = read('entry/src/main/ets/services/AppSettingsStore.ets');
  const gateway = read('entry/src/main/ets/services/HermesGatewayClient.ets');
  const controller = read('entry/src/main/ets/services/SingleAgentController.ets');
  const page = read('entry/src/main/ets/pages/Index.ets');

  assert.match(settings, /DEFAULT_MOBILE_INSTRUCTIONS\s*=\s*\r?\n\s*'当前使用语音交互，生成的文字回复应当尽量简洁、口语。'/);
  assert.match(settings, /getSync\('mobileInstructions', DEFAULT_MOBILE_INSTRUCTIONS\)/);
  assert.match(settings, /putSync\('mobileInstructions', config\.mobileInstructions\)/);
  assert.match(settings, /normalized\.length === 0[\s\S]{0,100}DEFAULT_MOBILE_INSTRUCTIONS/);
  assert.match(gateway, /class CreateSessionParams[\s\S]{0,200}instructions: string/);
  assert.match(gateway, /createSession\(cols: number, instructions: string\)[\s\S]{0,120}new CreateSessionParams\(cols, instructions\)/);
  assert.equal((controller.match(/createSession\(100, this\.config\.mobileInstructions\)/g) || []).length, 3);
  assert.match(page, /TextArea\(\{[\s\S]{0,140}text: this\.mobileInstructions/);
  assert.match(page, /恢复默认[\s\S]{0,500}DEFAULT_MOBILE_INSTRUCTIONS/);
  assert.match(page, /保存后只对新建移动端会话生效，不修改 Hermes 后台提示词。/);
});

test('HarmonyOS help teaches all four local voice commands and their boundaries', () => {
  const page = read('entry/src/main/ets/pages/Index.ets');
  const help = methodBody(page, 'private HelpPanel()', 'private HistoryPanel()');

  for (const phrase of ['关闭话筒', '打开话筒', '停止任务', '退出软件']) {
    assert.match(help, new RegExp(`'${phrase}'`));
  }
  assert.match(help, /暂时只想听 Agent 工作/);
  assert.match(help, /仅系统口令/);
  assert.match(help, /恢复普通语音对话/);
  assert.match(help, /当前思考、工具调用、排队任务或播报/);
  assert.match(help, /服务端队列状态以 Hermes 确认为准/);
  assert.match(help, /不会停止远端 Agent 任务/);
  assert.match(help, /以下口令需要整句说出/);
});

test('closed microphone keeps recognition alive and routes only exact control commands', () => {
  const input = read('entry/src/main/ets/services/VoiceInputCoordinator.ets');
  const policy = read('entry/src/main/ets/services/VoiceControlPolicy.ets');
  const closeRoute = methodBody(input, 'closeConversationRoute(): boolean', 'openConversationRoute(): boolean');
  const openRoute = methodBody(input, 'openConversationRoute(): boolean', 'startRemote(): void');
  const finalRoute = methodBody(input, 'private onFinal(epoch: number, text: string): void', 'private updateInterim(');

  assert.match(policy, /STOP_PHRASES: string\[\] = \['停止任务', '停止', 'stop'\]/);
  assert.match(policy, /OPEN_MIC_PHRASES: string\[\] = \['打开话筒', '打开麦克风', '打开microphone', '恢复收音'\]/);
  assert.match(policy, /EXIT_PHRASES: string\[\] = \['退出软件'\]/);
  assert.match(closeRoute, /this\.snapshot\.inputRouting = 'commands_only'/);
  assert.doesNotMatch(closeRoute, /this\.wanted = false|this\.capture\.stop|this\.asr\.close|systemAsr\?\.stop/);
  assert.match(openRoute, /this\.snapshot\.inputRouting = 'conversation'/);
  assert.match(finalRoute, /isExitPhrase\(value\)[\s\S]{0,140}callbacks\.exitApplication\(\)/);
  assert.match(finalRoute, /epoch !== this\.epoch \|\| !this\.wanted \|\| this\.submissionFrozen/);
  assert.match(finalRoute, /isOpenMicPhrase\(value\)[\s\S]{0,180}openConversationRoute\(\)/);
  assert.match(finalRoute, /isStopPhrase\(value\)[\s\S]{0,120}callbacks\.interrupt\(value, preview\)/);
  assert.match(finalRoute, /if \(this\.isCommandsOnly\(\)\) \{[\s\S]{0,180}discardAndResumePlayback\(\)/);
  assert.ok(finalRoute.indexOf('isExitPhrase(value)') < finalRoute.indexOf('if (this.isCommandsOnly())'));
  assert.ok(finalRoute.indexOf('if (this.isCommandsOnly())') < finalRoute.indexOf('callbacks.submit(value, preview)'));
});

test('exit disposes local resources before terminating the ability', () => {
  const controller = read('entry/src/main/ets/services/SingleAgentController.ets');
  const exit = methodBody(
    controller,
    'exitApplication(): Promise<void>',
    'private async disposeResources(epoch: number): Promise<void>',
  );
  const submit = methodBody(
    controller,
    'submitText(text: string, existingMessage?: ChatMessage): boolean',
    'toggleVoice(): void',
  );

  assert.match(exit, /this\.dispose\(\)\.then\([\s\S]{0,120}context\.terminateSelf\(\)/);
  assert.ok(exit.indexOf('this.dispose()') < exit.indexOf('context.terminateSelf()'));
  assert.doesNotMatch(exit, /interrupt\(/);
  assert.match(submit, /isExitPhrase\(value\)[\s\S]{0,120}exitApplication\(\)/);
  assert.match(submit, /if \(this\.disposed\) \{[\s\S]{0,60}return false/);
  assert.ok(submit.indexOf('isExitPhrase(value)') < submit.indexOf("this.snapshot.connection !== 'online'"));
});

test('stop task only confirms the request and never claims queue cancellation', () => {
  const controller = read('entry/src/main/ets/services/SingleAgentController.ets');
  const interrupt = methodBody(controller, 'private interrupt(displayText: string', 'stopCurrentTask(): void');

  assert.match(interrupt, /const requestGeneration = this\.stopTaskState\.beginRequest\(\)/);
  assert.match(interrupt, /StopTaskState\.localStoppedPendingConfirmation\(\)/);
  assert.match(interrupt, /StopTaskState\.requestConfirmedPendingConfirmation\(\)/);
  assert.match(interrupt, /StopTaskState\.requestFailedPendingConfirmation\(\)/);
  assert.match(interrupt, /isCurrentInterruptRequest\(requestGeneration, interruptedSessionId\)/);
  assert.doesNotMatch(interrupt, /已停止当前任务|队列已清空/);
});
