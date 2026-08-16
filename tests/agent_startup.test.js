const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const runtime = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/services/HermesRuntime.ets',
), 'utf8');
const controller = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/services/SingleAgentController.ets',
), 'utf8');
const page = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/pages/Index.ets',
), 'utf8');
const catalogClient = fs.readFileSync(path.join(
  root,
  'clients/harmony/entry/src/main/ets/services/AgentCatalogClient.ets',
), 'utf8');

function methodBody(source, start, next) {
  const startIndex = source.indexOf(start);
  assert.notEqual(startIndex, -1, `missing ${start}`);
  const endIndex = source.indexOf(next, startIndex + start.length);
  assert.notEqual(endIndex, -1, `missing ${next}`);
  return source.slice(startIndex, endIndex);
}

test('Agent catalog can be loaded before gateway authentication and connection', () => {
  assert.match(runtime, /async prepareAgentCatalog\(/);
  assert.match(runtime, /agentCatalogClient\.fetch\(baseUrl, accessToken\)/);
  const connectGateway = methodBody(
    runtime,
    'private async connectGateway(',
    'private async authenticate()',
  );
  assert.doesNotMatch(connectGateway, /loadAgentCatalog|agentCatalogClient\.fetch/);
});

test('Agent catalog only forces a Hermes refresh after the initial login load', () => {
  assert.match(catalogClient, /private hasFetched: boolean = false/);
  assert.match(catalogClient, /this\.hasFetched \? '\/api\/agents\?refresh=1' : '\/api\/agents'/);
  assert.match(catalogClient, /this\.hasFetched = true/);
});

test('controller initialization prepares the catalog without connecting', () => {
  const setContext = methodBody(controller, 'async setContext(', 'getConfig(): ClientConfig');
  assert.match(setContext, /await this\.refreshAgents\(\)/);
  assert.doesNotMatch(setContext, /this\.connect\(\)/);
  assert.match(controller, /refreshAgents\(\): Promise<boolean>/);
});

test('page startup waits for explicit Agent confirmation', () => {
  const onPageShow = methodBody(page, 'onPageShow(): void', 'private openSettings()');
  const finishInitialization = methodBody(
    page,
    'private finishControllerInitialization(): void',
    'private loadVoiceOptions()',
  );
  assert.doesNotMatch(onPageShow, /controller\.connect\(\)/);
  assert.doesNotMatch(finishInitialization, /controller\.connect\(\)/);
  assert.match(page, /private AgentEntryPanel\(\)/);
  assert.match(page, /this\.AgentEntryPanel\(\)/);
  assert.match(page, /this\.controller\.connect\(\)/);
});

test('Agent selection works offline and does not reconnect until confirmed', () => {
  assert.match(page, /!this\.snapshot\.agentsLoading[\s\S]{0,180}this\.snapshot\.connection !== 'connecting'/);
  const switchProfile = methodBody(
    controller,
    'switchProfile(profile: ProfileKey): void',
    '// Text input path.',
  );
  assert.match(switchProfile, /if \(this\.snapshot\.connection !== 'online'\)/);
  assert.match(switchProfile, /return;/);
});
