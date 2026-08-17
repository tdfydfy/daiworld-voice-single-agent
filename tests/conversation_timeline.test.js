const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

async function loadTimelineReducer() {
  const sourcePath = path.join(
    root,
    'clients/harmony/entry/src/main/ets/services/ActivityTimelineReducer.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^import .*\r?\n/, '');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(/\?:\s*number/g, '');
  source = source.replace(
    /:\s*(?:MessageActivity\[\]|MessageActivity\s*\|\s*undefined|MessageActivity|string\[\]|string|number|boolean|void|'thinking'\s*\|\s*'tool'\s*\|\s*'status'\s*\|\s*'error'|'thinking'\s*\|\s*'status')(?=\s*[,)=;{])/g,
    '',
  );
  const model = `
class MessageActivity {
  constructor() {
    this.id = '';
    this.kind = 'status';
    this.title = '';
    this.summary = '';
    this.detail = '';
    this.state = 'running';
    this.startedAt = 0;
    this.endedAt = 0;
    this.duration_s = undefined;
    this.expanded = false;
  }
}
`;
  const encoded = Buffer.from(model + source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

async function loadHistoryPolicy() {
  const sourcePath = path.join(
    root,
    'clients/harmony/entry/src/main/ets/services/HistoryRestorePolicy.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/\s+as\s+Record<string,\s*Object>/g, '');
  source = source.replace(/\s+as\s+Object\[\]/g, '');
  source = source.replace(/\?:\s*Object/g, '');
  source = source.replace(
    /:\s*(?:Object\[\]|Object|boolean|HistoryRestoreSelection)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

function readHarmonyFile(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8');
}

test('live activity fixture keeps arrival order and updates tools in place', async () => {
  const { ActivityTimelineReducer } = await loadTimelineReducer();
  const activities = [];

  ActivityTimelineReducer.appendThinking(activities, 'thinking-0', '先检查资料。', 1000);
  ActivityTimelineReducer.startTool(activities, 'tool-first', '信息检索', '关键词：计划', 1200);
  ActivityTimelineReducer.appendThinking(activities, 'thinking-2', '根据结果继续核对。', 1400);
  ActivityTimelineReducer.startTool(activities, 'tool-second', '读取文件', 'docs/PLAN.md', 1600);
  ActivityTimelineReducer.completeTool(
    activities, 'tool-first', '信息检索', '找到 3 条结果', false, 1800, 0.4,
  );
  ActivityTimelineReducer.completeTool(
    activities, 'tool-second', '读取文件', '读取完成', false, 2000,
  );

  assert.deepEqual(
    activities.map((activity) => [activity.kind, activity.id]),
    [
      ['thinking', 'thinking-0'],
      ['tool', 'tool-first'],
      ['thinking', 'thinking-2'],
      ['tool', 'tool-second'],
    ],
  );
  assert.equal(activities[1].state, 'completed');
  assert.equal(activities[1].duration_s, 0.4);
  assert.match(activities[1].detail, /输入：关键词：计划/);
  assert.match(activities[1].detail, /结果：找到 3 条结果/);
});

test('duplicate completion and late results do not append or reorder activities', async () => {
  const { ActivityTimelineReducer } = await loadTimelineReducer();
  const activities = [];

  ActivityTimelineReducer.startTool(activities, 'tool-one', '工具一', '', 1000);
  ActivityTimelineReducer.appendThinking(activities, 'thinking-after-tool', '工具后继续思考。', 1100);
  ActivityTimelineReducer.completeTool(activities, 'tool-one', '工具一', '首次完成', false, 1200);
  ActivityTimelineReducer.completeTool(activities, 'tool-one', '工具一', '重复完成', false, 1500);

  assert.equal(activities.length, 2);
  assert.equal(activities[0].id, 'tool-one');
  assert.equal(activities[1].id, 'thinking-after-tool');
  assert.match(activities[0].detail, /首次完成/);
  assert.doesNotMatch(activities[0].detail, /重复完成/);
});

test('activity timing freezes on boundaries and prefers backend tool duration', async () => {
  const { ActivityTimelineReducer } = await loadTimelineReducer();
  const activities = [];

  ActivityTimelineReducer.appendThinking(activities, 'thinking-0', '计时。', 1000);
  ActivityTimelineReducer.startTool(activities, 'tool-one', '工具', '', 1750);
  ActivityTimelineReducer.completeTool(activities, 'tool-one', '工具', '完成', false, 2600, 0.25);

  assert.equal(activities[0].duration_s, 0.75);
  assert.equal(activities[0].endedAt, 1750);
  assert.equal(activities[1].duration_s, 0.25);
  assert.equal(activities[1].endedAt, 2600);
});

test('history detail is authoritative even when empty and fallback is marked incomplete', async () => {
  const { HistoryRestorePolicy } = await loadHistoryPolicy();
  const fallback = [{ role: 'assistant', content: '简化正文' }];

  const complete = HistoryRestorePolicy.select({ messages: fallback }, { messages: [] });
  assert.deepEqual(complete.messages, []);
  assert.equal(complete.processComplete, true);

  const incomplete = HistoryRestorePolicy.select({ messages: fallback });
  assert.deepEqual(incomplete.messages, fallback);
  assert.equal(incomplete.processComplete, false);
});

test('client integrates shared reducer, explicit incomplete state, and per-activity expansion', () => {
  const conversation = readHarmonyFile(
    'clients/harmony/entry/src/main/ets/services/ConversationState.ets',
  );
  const controller = readHarmonyFile(
    'clients/harmony/entry/src/main/ets/services/SingleAgentController.ets',
  );
  const page = readHarmonyFile('clients/harmony/entry/src/main/ets/pages/Index.ets');

  assert.match(conversation, /ActivityTimelineReducer\.appendThinking/);
  assert.match(conversation, /ActivityTimelineReducer\.startTool/);
  assert.match(conversation, /processWarning = processComplete \? '' : '历史过程未完整载入'/);
  assert.match(controller, /HistoryRestorePolicy\.select\(result, detail\)/);
  assert.match(page, /toggleMessageActivity\(messageId, activity\.id\)/);
  assert.match(page, /activity\.expanded && activity\.detail\.length > 0/);
  assert.match(page, /activityElapsedSeconds\(activity\)/);
});
