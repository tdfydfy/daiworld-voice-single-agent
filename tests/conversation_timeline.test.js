const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const model = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/models/SingleAgentState.ets',
), 'utf8');
const conversation = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/services/ConversationState.ets',
), 'utf8');
const controller = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/services/SingleAgentController.ets',
), 'utf8');
const page = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/pages/Index.ets',
), 'utf8');

test('thinking, tools, statuses, and errors share one ordered activity model', () => {
  assert.match(model, /ActivityKind = 'thinking' \| 'tool' \| 'status' \| 'error'/);
  assert.match(model, /kind: ActivityKind = 'status'/);
  assert.match(conversation, /activity\.kind = 'thinking'/);
  assert.match(conversation, /lastActivity\.kind === 'thinking'/);
  assert.match(conversation, /THINKING_ACTIVITY_MAX_CHARS = 180/);
  assert.match(conversation, /thinkingChunkLength\(remaining, capacity\)/);
  assert.match(conversation, /activity\.detail = text/);
  assert.match(conversation, /activities\.push\(activity\)/);
  assert.match(conversation, /activity\.kind = 'tool'/);
  assert.match(conversation, /activity\.kind = 'status'/);
  assert.match(conversation, /activity\.kind = 'error'/);
});

test('tool activities expose bounded input, progress, result, and duration summaries', () => {
  assert.match(conversation, /activityExcerpt\(context\)/);
  assert.match(conversation, /'输入：' \+ this\.activityExcerpt\(context\)/);
  assert.match(conversation, /'进展：' \+ this\.activityExcerpt\(preview\)/);
  assert.match(conversation, /'结果：' \+ this\.activityExcerpt\(summary\.length > 0 \? summary : '执行完成'\)/);
  assert.match(conversation, /'失败：' \+ this\.activityExcerpt\(error\)/);
  assert.match(conversation, /activity\.duration_s = data\['duration_s'\]/);
});

test('live and restored reasoning render through the same ordered timeline', () => {
  assert.match(conversation, /appendHistoryThinkingActivity\(pendingActivities, row\)/);
  assert.match(conversation, /appendHistoryThinkingActivity\([\s\S]*activities\.push\(activity\)/);
  assert.match(page, /ForEach\(message\.activities/);
  assert.match(page, /activity\.kind === 'thinking'/);
  assert.match(page, /this\.thinkingLines\(activity\.detail\)/);
  assert.doesNotMatch(page, /this\.thinkingLines\(message\.thinking\)/);
});

test('activity kind survives immutable UI snapshots', () => {
  assert.match(controller, /activity\.kind = sourceActivity\.kind/);
});
