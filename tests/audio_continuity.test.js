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
    /:\s*(?:boolean|number|string|AudioDemand|DedicatedModePolicy|AudioContinuityAction|BackgroundAudioIntent)(?=\s*[,)=;{])/g,
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

test('recording lease stays stable when playback demand is added', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();

  state.setDemand(true, false);
  assert.equal(state.nextAction(), 'start');
  const startGeneration = state.begin('start');
  assert.equal(state.complete('start', startGeneration), true);
  assert.equal(state.nextAction(), 'none');
  assert.equal(state.isReady('recording'), true);

  state.setDemand(true, true);
  assert.equal(state.nextAction(), 'none');
  assert.equal(state.isReady('recording'), true);
  assert.equal(state.isDemandReady(), true);
});

test('playback completion restores the requested recording intent', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDemand(false, true);
  const generation = state.begin(state.nextAction());
  state.complete('start', generation);

  state.setDemand(true, false);
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
  state.setDemand(true, false);
  const firstGeneration = state.begin('start');
  state.fail('start', firstGeneration);

  const secondGeneration = state.begin('start');
  assert.equal(state.complete('start', firstGeneration), false);
  assert.equal(state.phase, 'starting');
  assert.equal(state.complete('start', secondGeneration), true);
  assert.equal(state.isReady('recording'), true);
});

test('playback demand does not supersede recording while recording is still starting', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDemand(true, false);
  const recordingGeneration = state.begin('start');
  state.setDemand(true, true);
  state.complete('start', recordingGeneration);

  assert.equal(state.isReady('recording'), true);
  assert.equal(state.nextAction(), 'none');
});

test('recording demand survives playback mode selection', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDemand(true, true);

  assert.equal(state.demand.recording, true);
  assert.equal(state.demand.playback, true);
  assert.equal(state.desiredIntent, 'recording');

  state.setDemand(true, false);
  assert.equal(state.desiredIntent, 'recording');
});

test('dual demand readiness follows the policy-selected recording intent', async () => {
  const { AudioContinuityState } = await loadProductionState();
  const state = new AudioContinuityState();
  state.setDemand(true, true);
  const generation = state.begin(state.nextAction());
  state.complete('start', generation);

  assert.equal(state.isReady('recording'), true);
  assert.equal(state.isReady('playback'), false);
  assert.equal(state.isDemandReady(), true);

  const owner = readHarmonyService('BackgroundAudioTaskOwner');
  assert.match(owner, /ensureReconcile\(\)\.then[\s\S]{0,160}!this\.state\.isDemandReady\(\)/);
});

test('continuity coordinator owns background entitlement but not an empty audio session', () => {
  const source = readHarmonyService('AudioContinuityCoordinator');

  assert.match(source, /this\.owner\.syncDemand\(this\.demand/);
  assert.match(source, /this\.owner\.ensureReady\(intent, this\.demand/);
  assert.doesNotMatch(source, /CommunicationAudioSessionLease|sessionWanted|sessionHeld/);
});

test('audio session timeout is a normal expiry and separate recoveries get fresh budgets', () => {
  const source = readHarmonyService('CommunicationAudioSession');
  const listenerStart = source.indexOf('private sessionDeactivatedListener');
  const listenerBody = source.slice(listenerStart, source.indexOf('async acquire()', listenerStart));
  const timeoutGuard = listenerBody.indexOf('AudioSessionDeactivatedReason.DEACTIVATED_TIMEOUT');
  const recoveryCall = listenerBody.indexOf('this.scheduleRecovery()');
  const recoveryStart = source.indexOf('private scheduleRecovery(): void');
  const recoveryBody = source.slice(recoveryStart, source.indexOf('private cancelRecovery()', recoveryStart));

  assert.ok(timeoutGuard >= 0 && recoveryCall > timeoutGuard);
  assert.match(listenerBody, /DEACTIVATED_TIMEOUT[\s\S]{0,360}return;/);
  assert.match(recoveryBody, /ensureActivated\(\)\.then[\s\S]{0,160}recoveryBudget\.reset\(\)/);
});

test('communication session failure cannot terminate a healthy PCM renderer', () => {
  const source = readHarmonyService('PcmPlayer');
  const constructorStart = source.indexOf('constructor(');
  const constructorBody = source.slice(constructorStart, source.indexOf('setFailureListener(', constructorStart));

  assert.match(constructorBody, /setRecoveryListener/);
  assert.doesNotMatch(constructorBody, /session\.setFailureListener/);
});

test('headset topology chooses a stable product route without persisting device callbacks', () => {
  const sessionSource = readHarmonyService('CommunicationAudioSession');
  const controllerSource = readHarmonyService('SingleAgentController');
  const routeStart = controllerSource.indexOf('private onOutputRouteChanged(');
  const routeBody = controllerSource.slice(routeStart, controllerSource.indexOf('toggleMute()', routeStart));

  assert.match(sessionSource, /lastHeadsetAvailable !== headsetAvailable[\s\S]{0,160}speakerphoneEnabled = !headsetAvailable/);
  assert.doesNotMatch(sessionSource, /preferredOutputListener[\s\S]{0,120}speakerphoneEnabled\s*=/);
  assert.doesNotMatch(routeBody, /this\.config\.speakerphoneEnabled|persistConfig\(\)/);
});

test('thinking cue remains eligible while it owns the playback gate', () => {
  const source = readHarmonyService('VoiceOutputCoordinator');
  const start = source.indexOf('syncAudioCues(): void');
  const body = source.slice(start, source.indexOf('hasBackgroundOutput(): boolean', start));
  const streamStart = source.indexOf('beginAssistantStream(): void');
  const streamBody = source.slice(streamStart, source.indexOf('appendAssistantDelta(', streamStart));
  const systemStart = source.indexOf('private startSystemSpeech(text: string): void');
  const systemBody = source.slice(systemStart, source.indexOf('private isSystemSpeechStartCurrent(', systemStart));

  assert.match(body, /activeJob\?\.kind === 'cue' && activeJob\.cue === 'thinking'/);
  assert.match(body, /!this\.playbackQueue\.hasOutput\(\) \|\| thinkingOwnsQueue/);
  assert.doesNotMatch(streamBody, /audioCues\.silence\(\)|beginPlaybackJob\('assistant'/);
  assert.match(systemBody, /ensureAssistantPlaybackJob\(\)[\s\S]*audioCues\.yieldForSpeech\(\)/);
  assert.match(source, /appendAssistantDelta\([\s\S]{0,1200}!this\.ensureAssistantPlaybackJob\(\)/);
});

test('thinking cue resumes after the accepted cue releases the playback gate', () => {
  const source = readHarmonyService('VoiceOutputCoordinator');
  const constructorStart = source.indexOf('constructor(snapshot: SingleAgentSnapshot');
  const constructorBody = source.slice(constructorStart, source.indexOf('setSystemTts(', constructorStart));
  const beginTurnStart = source.indexOf('beginAgentTurn(): void');
  const beginTurnBody = source.slice(beginTurnStart, source.indexOf('endAgentTurn(): void', beginTurnStart));
  const acceptedStart = source.indexOf('playAcceptedCue(): void');
  const acceptedBody = source.slice(acceptedStart, source.indexOf('playStopCue(): void', acceptedStart));

  assert.match(beginTurnBody, /this\.agentTurnActive = true;[\s\S]{0,80}this\.syncAudioCues\(\)/);
  assert.match(constructorBody, /if \(cueCompleted\) \{[\s\S]{0,80}this\.syncAudioCues\(\)/);
  assert.match(acceptedBody, /active\?\.kind === 'cue' && active\.cue === 'thinking'/);
  assert.match(acceptedBody, /this\.lastThinkingCueActive = false;[\s\S]{0,80}this\.audioCues\.setRunning\(false\)/);
  assert.ok(acceptedBody.indexOf("active.cue === 'thinking'") < acceptedBody.indexOf("this.audioCues.playAccepted()"));
});

test('short cues avoid Bluetooth communication-route cold start', () => {
  const cues = readHarmonyService('AudioCuePlayer');
  const output = readHarmonyService('VoiceOutputCoordinator');
  const player = readHarmonyService('PcmPlayer');

  assert.match(cues, /const player = new PcmPlayer\(false\)/);
  assert.match(output, /private player: PcmPlayer = new PcmPlayer\(\)/);
  assert.match(player, /this\.communication[\s\S]{0,180}STREAM_USAGE_VOICE_COMMUNICATION[\s\S]{0,100}STREAM_USAGE_VOICE_ASSISTANT/);
});

test('terminal local ASR failure cancels and stops capture ownership', () => {
  const source = readHarmonyService('VoiceInputCoordinator');
  const start = source.indexOf('failSystemRecognition(reason: string, phase: string): void');
  const body = source.slice(start, source.indexOf('onSystemRecognitionStartupPhase(', start));

  assert.match(body, /this\.captureStartGeneration \+= 1/);
  assert.match(body, /this\.capturing = false/);
  assert.match(body, /this\.captureReady = false/);
  assert.match(body, /this\.capture\.stop\(\)\.catch\(\(\) => undefined\)/);
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
  assert.match(remoteStart, /isCaptureStartCurrent\(generation\)[\s\S]*ensureRecordingReady\(\)/);
  assert.match(remoteStart, /ensureRecordingReady\(\)[\s\S]*isCaptureStartCurrent\(generation\)[\s\S]*syncBackgroundState\(\)/);
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
