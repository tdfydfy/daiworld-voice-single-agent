const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

async function loadProductionPolicy() {
  const sourcePath = path.resolve(
    root,
    'clients/harmony/entry/src/main/ets/services/ProtocolReplyPolicy.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^export type[\s\S]*?;\r?\n/m, '');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(
    /:\s*(?:string\[\]|string|number|ApprovalDecision)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('approval replies tolerate boundary ASR punctuation but remain exact', async () => {
  const { ProtocolReplyPolicy } = await loadProductionPolicy();

  assert.equal(ProtocolReplyPolicy.approvalDecision('同意。'), 'allow');
  assert.equal(ProtocolReplyPolicy.approvalDecision('（同意）。'), 'allow');
  assert.equal(ProtocolReplyPolicy.approvalDecision('取 消，'), 'deny');
  assert.equal(ProtocolReplyPolicy.approvalDecision('允许。'), 'none');
  assert.equal(ProtocolReplyPolicy.approvalDecision('拒绝。'), 'none');
  assert.equal(ProtocolReplyPolicy.approvalDecision('请同意。'), 'none');
  assert.equal(ProtocolReplyPolicy.approvalDecision('同，意'), 'none');
  assert.equal(ProtocolReplyPolicy.approvalDecision('同意或取消'), 'none');
});

test('clarification speech normalizes known labels without accepting ordinals', async () => {
  const { ProtocolReplyPolicy } = await loadProductionPolicy();
  const choices = ['保守方案', '快速方案', '暂不处理'];

  assert.equal(ProtocolReplyPolicy.clarifyAnswer('快速方案，', choices), '快速方案');
  assert.equal(ProtocolReplyPolicy.clarifyAnswer('暂不处理。', choices), '暂不处理');
  assert.equal(ProtocolReplyPolicy.clarifyAnswer('第一个。', choices), '第一个。');
  assert.equal(ProtocolReplyPolicy.clarifyAnswer('选项 2，', choices), '选项 2，');
  assert.equal(ProtocolReplyPolicy.clarifyAnswer('1。', choices), '1。');
  assert.equal(
    ProtocolReplyPolicy.clarifyAnswer('其他原因，稍后再处理。', choices),
    '其他原因，稍后再处理。',
  );
});

test('clarification stays semantic and waits for a complete utterance', () => {
  const controller = fs.readFileSync(path.join(
    root,
    'clients/harmony/entry/src/main/ets/services/SingleAgentController.ets',
  ), 'utf8');
  const input = fs.readFileSync(path.join(
    root,
    'clients/harmony/entry/src/main/ets/services/VoiceInputCoordinator.ets',
  ), 'utf8');

  const promptStart = controller.indexOf('private clarifyConversationText(');
  const promptEnd = controller.indexOf('\n  respondApproval(', promptStart);
  const promptBody = controller.slice(promptStart, promptEnd);
  assert.match(promptBody, /choices\.join\('、'\)/);
  assert.doesNotMatch(promptBody, /index\s*\+\s*1|编号|序号/);

  const finalizeStart = input.indexOf('private shouldFinalizeImmediately(');
  const finalizeEnd = input.indexOf('\n  private combinedText(', finalizeStart);
  const finalizeBody = input.slice(finalizeStart, finalizeEnd);
  assert.doesNotMatch(finalizeBody, /clarifyPending/);
  assert.match(finalizeBody, /approvalPending/);
});
