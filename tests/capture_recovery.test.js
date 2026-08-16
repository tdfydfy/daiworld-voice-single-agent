const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionState() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/CaptureRecoveryState.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/\breadonly\s+/g, '');
  source = source.replace(/:\s*(?:boolean|number|string)(?=\s*[,)=;{])/g, '');
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('capture recovery serializes repeated health failures', async () => {
  const { CaptureRecoveryState } = await loadProductionState();
  const state = new CaptureRecoveryState(3);
  const startGeneration = state.beginStart();
  assert.equal(state.markRunning(startGeneration), true);

  const recoveryGeneration = state.beginRecovery();
  assert.ok(recoveryGeneration > startGeneration);
  assert.equal(state.beginRecovery(), 0);
  assert.equal(state.recoveryAttempt, 1);
  assert.equal(state.phase, 'recovering');
});

test('stale capture generations cannot change recovery state', async () => {
  const { CaptureRecoveryState } = await loadProductionState();
  const state = new CaptureRecoveryState(3);
  const startGeneration = state.beginStart();
  state.markRunning(startGeneration);
  const recoveryGeneration = state.beginRecovery();

  assert.equal(state.markRunning(startGeneration), false);
  assert.equal(state.failRecovery(startGeneration), false);
  assert.equal(state.observePcm(startGeneration), false);
  assert.equal(state.markRunning(recoveryGeneration), true);
  assert.equal(state.phase, 'running');
});

test('capture recovery stops after the bounded retry budget', async () => {
  const { CaptureRecoveryState } = await loadProductionState();
  const state = new CaptureRecoveryState(3);
  const startGeneration = state.beginStart();
  state.markRunning(startGeneration);

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const generation = state.beginRecovery();
    assert.ok(generation > 0);
    assert.equal(state.recoveryAttempt, attempt);
    assert.equal(state.failRecovery(generation), true);
  }

  assert.equal(state.phase, 'failed');
  assert.equal(state.beginRecovery(), -1);
  assert.equal(state.recoveryAttempt, 3);
});

test('one observed PCM does not restore the capture retry budget', async () => {
  const { CaptureRecoveryState } = await loadProductionState();
  const state = new CaptureRecoveryState(3, 60000, 10000);
  const startGeneration = state.beginStart(1000);
  state.markRunning(startGeneration, 1000);
  const recoveryGeneration = state.beginRecovery(2000);
  state.markRunning(recoveryGeneration, 3000);

  assert.equal(state.recoveryAttempt, 1);
  assert.equal(state.observePcm(recoveryGeneration, 3001), true);
  assert.equal(state.recoveryAttempt, 1);
  assert.equal(state.observePcm(recoveryGeneration, 13000), true);
  assert.equal(state.recoveryAttempt, 0);
});

test('capture recovery budget resets after the time window expires', async () => {
  const { CaptureRecoveryState } = await loadProductionState();
  const state = new CaptureRecoveryState(1, 60000, 10000);
  const startGeneration = state.beginStart(1000);
  state.markRunning(startGeneration, 1000);
  const recoveryGeneration = state.beginRecovery(2000);
  state.markRunning(recoveryGeneration, 3000);

  assert.equal(state.beginRecovery(4000), -1);
  state.phase = 'running';
  assert.ok(state.beginRecovery(62001) > 0);
  assert.equal(state.recoveryAttempt, 1);
});

test('explicit stop cancels pending capture recovery generations', async () => {
  const { CaptureRecoveryState } = await loadProductionState();
  const state = new CaptureRecoveryState(3);
  const startGeneration = state.beginStart();
  state.markRunning(startGeneration);
  const recoveryGeneration = state.beginRecovery();
  const stoppedGeneration = state.stop();

  assert.ok(stoppedGeneration > recoveryGeneration);
  assert.equal(state.phase, 'idle');
  assert.equal(state.recoveryAttempt, 0);
  assert.equal(state.markRunning(recoveryGeneration), false);
  assert.equal(state.failRecovery(recoveryGeneration), false);
});

test('communication session recovery does not tear down a healthy capturer', () => {
  const source = fs.readFileSync(path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/PcmCapture.ets',
  ), 'utf8');
  const constructorStart = source.indexOf('constructor()');
  const constructorBody = source.slice(constructorStart, source.indexOf('async requestPermission(', constructorStart));

  assert.match(constructorBody, /'communication-session-recovered', true/);
  assert.doesNotMatch(constructorBody, /'communication-session-recovered', false/);
  assert.doesNotMatch(constructorBody, /session\.setFailureListener/);
});
