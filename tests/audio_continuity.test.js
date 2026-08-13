const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionState() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/AudioContinuityState.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^export type .*;\r?\n/gm, '');
  source = source.replace(
    /:\s*(?:boolean|number|string|AudioContinuityAction|BackgroundAudioIntent)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

function readHarmonyService(name) {
  return fs.readFileSync(path.resolve(
    __dirname,
    `../clients/harmony/entry/src/main/ets/services/${name}.ets`,
  ), 'utf8');
}

test('recording switches through stop before playback starts', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();

  state.setDesiredIntent('recording');
  assert.equal(state.nextAction(), 'start');
  const startGeneration = state.begin('start');
  assert.equal(state.complete('start', startGeneration), true);
  assert.equal(state.nextAction(), 'none');
  assert.equal(state.isReady('recording'), true);

  state.setDesiredIntent('playback');
  assert.equal(state.nextAction(), 'stop');
  const stopGeneration = state.begin('stop');
  assert.equal(state.complete('stop', stopGeneration), true);
  assert.equal(state.nextAction(), 'start');

  const playbackGeneration = state.begin('start');
  assert.equal(state.complete('start', playbackGeneration), true);
  assert.equal(state.isReady('playback'), true);
});

test('playback completion restores the requested recording intent', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDesiredIntent('playback');
  const generation = state.begin(state.nextAction());
  state.complete('start', generation);

  state.setDesiredIntent('recording');
  const stopGeneration = state.begin(state.nextAction());
  state.complete('stop', stopGeneration);
  assert.equal(state.nextAction(), 'start');
  const recordingGeneration = state.begin('start');
  state.complete('start', recordingGeneration);
  assert.equal(state.isReady('recording'), true);
});

test('stale lease completion cannot overwrite the current generation', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDesiredIntent('recording');
  const firstGeneration = state.begin('start');
  state.fail('start', firstGeneration);

  const secondGeneration = state.begin('start');
  assert.equal(state.complete('start', firstGeneration), false);
  assert.equal(state.phase, 'starting');
  assert.equal(state.complete('start', secondGeneration), true);
  assert.equal(state.isReady('recording'), true);
});

test('playback demand supersedes recording while recording is still starting', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDesiredIntent('recording');
  const recordingGeneration = state.begin('start');
  state.setDesiredIntent('playback');
  state.complete('start', recordingGeneration);

  assert.equal(state.isReady('recording'), true);
  assert.equal(state.nextAction(), 'stop');
});

test('stale system speech cannot request or retain playback readiness', () => {
  const source = readHarmonyService('VoiceOutputCoordinator');
  const start = source.indexOf('private startSystemSpeech(text: string): void');
  const end = source.indexOf('private isSystemSpeechStartCurrent(', start);
  const body = source.slice(start, end);
  const readiness = body.indexOf('this.callbacks.ensurePlaybackReady()');
  const guards = [...body.matchAll(/this\.isSystemSpeechStartCurrent\(generation, text\)/g)]
    .map((match) => match.index);
  const resync = body.indexOf('this.callbacks.syncBackgroundState()', readiness);

  assert.ok(readiness > 0);
  assert.ok(guards.length >= 3);
  assert.ok(guards[0] < readiness);
  assert.ok(guards[1] > readiness);
  assert.ok(resync > readiness);
});

test('stale recording readiness restores the current background intent', () => {
  const source = readHarmonyService('VoiceInputCoordinator');
  const systemStartOffset = source.indexOf('startSystem(): void');
  const systemStart = source.slice(
    systemStartOffset,
    source.indexOf('\n  failSystemRecognition(', systemStartOffset),
  );
  const remoteStartOffset = source.indexOf('private startCapture(): void');
  const remoteStart = source.slice(
    remoteStartOffset,
    source.indexOf('private onRemoteCaptureState(', remoteStartOffset),
  );

  assert.match(systemStart, /ensureRecordingReady\(\)[\s\S]*isSystemRecognitionStartCurrent\(attempt\)[\s\S]*syncBackgroundState\(\)/);
  assert.match(remoteStart, /isRemoteCaptureStartCurrent\(generation\)[\s\S]*ensureRecordingReady\(\)/);
  assert.match(remoteStart, /ensureRecordingReady\(\)[\s\S]*isRemoteCaptureStartCurrent\(generation\)[\s\S]*syncBackgroundState\(\)/);
});

test('capture cleanup cannot revive a cancelled start request', () => {
  const source = readHarmonyService('CaptureSupervisor');
  const startOffset = source.indexOf('async start(');
  const start = source.slice(startOffset, source.indexOf('async stop()', startOffset));
  const cleanupWait = start.indexOf('await cleanup.catch(() => undefined)');
  const staleGuard = start.indexOf('requestGeneration !== this.requestGeneration');
  const listenerAssignment = start.indexOf('this.listener = listener');

  assert.ok(cleanupWait > 0);
  assert.ok(staleGuard > cleanupWait);
  assert.ok(listenerAssignment > staleGuard);
  assert.match(source, /async stop\(\): Promise<void> \{[\s\S]{0,100}this\.requestGeneration \+= 1/);
});
