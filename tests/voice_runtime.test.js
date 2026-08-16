const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionState() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/VoiceRuntimeState.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^export type[\s\S]*?;\r?\n/gm, '');
  source = source.replace(/\breadonly\s+/g, '');
  source = source.replace(/\?:\s*VoiceFailure(?=;)/g, '');
  source = source.replace(
    /:\s*(?:void|boolean|number|string|VoiceRuntimePhase|VoiceInputIntent|VoiceResourceHealth|VoiceFailureDomain|VoiceFailure|VoiceRuntimeState)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test('a newer epoch rejects a stale session completion', async () => {
  const { VoiceRuntimeReducer } = await loadProductionState();
  const runtime = new VoiceRuntimeReducer();
  const first = runtime.begin('switching_session');
  const second = runtime.begin('switching_session');

  assert.equal(runtime.commitSession(first, 'old', 'runtime-old'), false);
  assert.equal(runtime.commitSession(second, 'new', 'runtime-new'), true);
  assert.equal(runtime.state.storedSessionId, 'new');
});

test('recording and playback demands remain independent', async () => {
  const { VoiceRuntimeReducer } = await loadProductionState();
  const runtime = new VoiceRuntimeReducer();
  runtime.setInputIntent('conversation');
  runtime.setPlaybackDemand(true);

  assert.equal(runtime.state.recordingDemand, true);
  assert.equal(runtime.state.playbackDemand, true);
});

test('stale ASR and playback events cannot change current state', async () => {
  const { VoiceRuntimeReducer } = await loadProductionState();
  const runtime = new VoiceRuntimeReducer();
  const oldEpoch = runtime.begin('ready');
  const currentEpoch = runtime.begin('switching_session');

  assert.equal(runtime.setAsrHealth(oldEpoch, 'healthy'), false);
  assert.equal(runtime.setPlaybackHealth(oldEpoch, 'old-job', 'healthy'), false);
  assert.equal(runtime.setAsrHealth(currentEpoch, 'healthy'), true);
  assert.equal(runtime.state.activePlaybackJobId, '');
});

test('dispose can invalidate a start effect that never completed', async () => {
  const { VoiceRuntimeReducer } = await loadProductionState();
  const runtime = new VoiceRuntimeReducer();
  const startEpoch = runtime.begin('reconfiguring');
  const pending = deferred();
  const completion = pending.promise.then(() => runtime.complete(startEpoch));

  const disposeEpoch = runtime.begin('disposing');
  assert.ok(disposeEpoch > startEpoch);
  assert.equal(runtime.state.phase, 'disposing');
  pending.resolve();
  assert.equal(await completion, false);
  assert.equal(runtime.state.phase, 'disposing');
  assert.equal(runtime.completeDispose(disposeEpoch), true);
  assert.equal(runtime.state.phase, 'idle');
});
