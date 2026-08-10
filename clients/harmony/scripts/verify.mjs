// Single-Agent HarmonyOS project static verification.
// Replaces the Host project's verify script: checks that this client targets
// the Hermes JSON-RPC / streaming ASR / streaming TTS contract and contains
// no Host orchestration protocol remnants.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ETS = path.join(root, 'entry/src/main/ets');

const REQUIRED_FILES = [
  'entry/src/main/ets/models/HermesProtocol.ets',
  'entry/src/main/ets/models/VoiceProtocol.ets',
  'entry/src/main/ets/models/SingleAgentState.ets',
  'entry/src/main/ets/services/AuthSessionClient.ets',
  'entry/src/main/ets/services/HermesGatewayClient.ets',
  'entry/src/main/ets/services/HermesSessionDetailClient.ets',
  'entry/src/main/ets/services/StreamingAsrClient.ets',
  'entry/src/main/ets/services/StreamingTtsClient.ets',
  'entry/src/main/ets/services/SingleAgentController.ets',
  'entry/src/main/ets/services/PcmAudio.ets',
  'entry/src/main/ets/services/AudioCuePlayer.ets',
  'entry/src/main/ets/services/SystemSpeechService.ets',
  'entry/src/main/ets/pages/Index.ets',
  'AppScope/resources/base/media/app_icon.svg',
  'entry/src/main/resources/base/media/app_icon.svg',
  'AppScope/app.json5',
  'build-profile.json5',
  'entry/build-profile.json5',
  'entry/src/main/module.json5'
];

const REQUIRED_TOKENS = [
  ['session.create', 'Hermes JSON-RPC session.create'],
  ['session.resume', 'Hermes JSON-RPC session.resume'],
  ['prompt.submit', 'Hermes JSON-RPC prompt.submit'],
  ['session.interrupt', 'Hermes JSON-RPC session.interrupt'],
  ['transcribe-stream', 'streaming ASR route'],
  ['speak-stream', 'streaming TTS route'],
  ['gateway.ready', 'gateway ready event'],
  ['message.complete', 'message complete event'],
  ['requestPermission', 'runtime microphone permission'],
  ['respondApproval', 'approval response'],
  ['respondClarify', 'clarification response'],
  ['@kit.CoreSpeechKit', 'HarmonyOS system speech API'],
  ['online: 1', 'offline system speech mode'],
  ['startBackgroundRunning', 'continuous background voice task'],
  ['BackgroundMode.AUDIO_RECORDING', 'background audio recording mode'],
  ['recognitionWanted', 'persistent local speech capture state'],
  ['ensureRecognitionCapture', 'persistent local speech capture startup'],
  ['stopRecognitionCapture', 'explicit local speech capture cleanup'],
  ['stopBackgroundRunning', 'background task cleanup']
];

// Host-only protocol remnants that must NOT appear in the single-agent client.
const FORBIDDEN = [
  ['host_route', 'Host routing event'],
  ['host_message', 'Host message event'],
  ['supplement_queued', 'Host supplement queue'],
  ['agent_result', 'Host agent result'],
  ['runtime_refresh', 'Host runtime refresh'],
  ['conversation_id=', 'old conversation_id query'],
  ['/voice/ws', 'old Host gateway path'],
  ['/api/conversations', 'old Host history API']
];

const CREDENTIAL_PATTERNS = [
  /sk-[A-Za-z0-9]{20,}/,
  /AKIA[0-9A-Z]{16}/,
  /BEGIN (RSA|OPENSSH|EC) PRIVATE KEY/,
  /native-test/,
  /native-dev-token/
];

const HISTORY_PAGINATION_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /listHistory\(limit: number = 20\)/, 'history starts with 20 entries'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /historyLoading\)\s*\{\s*return;/, 'duplicate history requests are blocked'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /historyLimit \+ 20/, 'history grows in 20-entry steps'],
  ['entry/src/main/ets/services/HermesGatewayClient.ets', /new ListSessionsParams\(limit\)/, 'history limit reaches the gateway request'],
  ['entry/src/main/ets/pages/Index.ets', /\.onReachEnd\(\(\) => \{\s*this\.controller\.loadMoreHistory\(\);/, 'scroll end requests the next history page']
];

const AUDIO_CUE_CHECKS = [
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /playAccepted\(\)/, 'input accepted cue'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /setRunning\(active: boolean\)/, 'running pulse cue'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /playStop\(\)/, 'stop cue'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /playError\(\)/, 'error cue'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.audioCues\.playAccepted\(\)/, 'ASR accepted cue integration'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.audioCues\.playStop\(\)/, 'hard stop cue integration'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.audioCues\.setRunning\(running\)/, 'agent running cue integration'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.audioCues\.playError\(\)/, 'voice error cue integration']
];

const HISTORY_TIMESTAMP_CHECKS = [
  ['entry/src/main/ets/services/HermesSessionDetailClient.ets', /\/api\/hermes\/sessions\//, 'timestamped history detail route'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /completeSessionResume\(result, detail\)/, 'history detail resume integration'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /message\.timestamp = this\.parseTimestamp/, 'stored message timestamp restoration'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.timestampMillis\(message\.timestamp\)/, 'history duration timestamp normalization'],
  ['entry/src/main/ets/pages/Index.ets', /date\.getFullYear\(\) === now\.getFullYear\(\)/, 'today-aware message timestamp formatting'],
  ['entry/src/main/ets/pages/Index.ets', /year \+ '-' \+ month \+ '-' \+ day/, 'full date for older messages']
];

const HISTORY_TOOL_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /if \(roleValue === 'tool'\)/, 'stored tool messages excluded from reply bubbles'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /restoreHistoryToolResult\(row, pendingActivities\)/, 'stored tool results restored as process activities'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /message\.activities = pendingActivities/, 'stored activities attached to the assistant response']
];

const SYSTEM_TTS_STREAM_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /SYSTEM_TTS_FIRST_MIN = 20/, 'small first speech chunk'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /SYSTEM_TTS_HARD_MAX = 300/, 'system TTS hard text limit'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /appendSystemSpeechStream\(text\)/, 'delta-fed system TTS'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /finishSystemSpeechStream\(speechText\)/, 'final system TTS flush'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /systemSpeechChunkEnd\(/, 'punctuation-aware TTS chunking']
];

const AUDIO_INPUT_ROUTE_CHECKS = [
  ['entry/src/main/ets/services/PcmAudio.ets', /source: audio\.SourceType\.SOURCE_TYPE_VOICE_COMMUNICATION/, 'communication capture source'],
  ['entry/src/main/ets/services/PcmAudio.ets', /audio\.StreamUsage\.STREAM_USAGE_VOICE_COMMUNICATION/, 'communication playback usage'],
  ['entry/src/main/ets/services/PcmAudio.ets', /AUDIO_SESSION_SCENE_VOICE_COMMUNICATION/, 'communication audio session scene'],
  ['entry/src/main/ets/services/PcmAudio.ets', /activateAudioSession\(strategy\)/, 'communication audio session activation'],
  ['entry/src/main/ets/services/PcmAudio.ets', /audio\.DeviceType\.SPEAKER : audio\.DeviceType\.EARPIECE/, 'earpiece and speakerphone fallback selection'],
  ['entry/src/main/ets/services/PcmAudio.ets', /setDefaultOutputDevice\(device\)/, 'communication fallback application'],
  ['entry/src/main/ets/services/PcmAudio.ets', /on\([\s\S]{0,80}'audioSessionDeactivated'/, 'communication session deactivation recovery'],
  ['entry/src/main/ets/services/PcmAudio.ets', /getPreferredInputDeviceForCapturerInfoSync/, 'preferred input device inspection'],
  ['entry/src/main/ets/services/PcmAudio.ets', /getCurrentInputDevices\(\)/, 'active input device verification'],
  ['entry/src/main/ets/services/PcmAudio.ets', /on\('inputDeviceChange'/, 'system-managed input route observation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /onMicrophoneRouteChanged\(label\)/, 'live microphone route UI update'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /new PcmPlayer\(false\)/, 'audio cues do not acquire the communication route']
];

const VOICE_CONTROL_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /private stopVoiceInput\(\)/, 'separate microphone input shutdown'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private voiceOutputEnabled: boolean = true/, 'automatic TTS output state'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /speakerphoneEnabled/, 'persistent speakerphone preference'],
  ['entry/src/main/ets/pages/Index.ets', /toggleSpeakerphone\(\)/, 'speakerphone UI control'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.asr\.isConnected\(\)/, 'ASR reconnect avoids unnecessary TTS reconnect'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /isConnected\(\): boolean/, 'ASR connection state inspection'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.snapshot\.asrState = 'stopped';[\s\S]{0,120}this\.asr\.close\(\);/, 'capture failure clears ASR connecting state']
];

const MESSAGE_BUBBLE_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /ForEach\(this\.snapshot\.messages/, 'device-reliable reactive message list'],
  ['entry/src/main/ets/pages/Index.ets', /message\.id \+ '-' \+ String\(message\.revision\)/, 'revision-keyed streaming repaint'],
  ['entry/src/main/ets/pages/Index.ets', /isMessageListNearBottom\(\)/, 'near-bottom scroll tracking'],
  ['entry/src/main/ets/pages/Index.ets', /message\.role === 'assistant' && this\.hasMessageProcess\(message\)/, 'process block separated from answer body'],
  ['entry/src/main/ets/pages/Index.ets', /message\.artifacts\.length > 0/, 'artifacts rendered with the assistant body'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /ensureAsrPreview\(\)/, 'persistent ASR preview message'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /submitText\(text: string, existingMessage\?: ChatMessage\)/, 'ASR final upgrades the preview in place'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /provider: string = ''/, 'message provider metadata'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /transient: boolean = false/, 'transient message state']
];

const REACTIVE_UI_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /snapshotForUi\(\): SingleAgentSnapshot/, 'fresh UI snapshot delivery'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /messageForUi\(source: ChatMessage\): ChatMessage/, 'fresh streamed message delivery'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /onSnapshot\(this\.snapshotForUi\(\)\)/, 'listener receives immutable UI snapshot'],
  ['entry/src/main/ets/services/PcmAudio.ets', /getInputRouteLabel\(\): string/, 'active microphone route inspection'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /microphoneRoute: string = ''/, 'microphone route UI state'],
  ['entry/src/main/ets/pages/Index.ets', /microphoneButtonText\(\)/, 'microphone route button label']
];

const SYSTEM_ASR_STARTUP_CHECKS = [
  ['entry/src/main/ets/services/SystemSpeechService.ets', /reportRecognitionStartupPhase\('创建本地识别引擎'\)/, 'system ASR engine-creation phase reporting'],
  ['entry/src/main/ets/services/SystemSpeechService.ets', /reportRecognitionStartupPhase\('启动音频采集'\)/, 'system ASR capture phase reporting'],
  ['entry/src/main/ets/services/SystemSpeechService.ets', /reportRecognitionStartupPhase\('等待识别引擎 ready'\)/, 'system ASR ready phase reporting'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /本地 ASR 启动超时，停在：/, 'stuck system ASR reports its startup phase'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private failSystemRecognition\(reason: string, phase: string\): void/, 'failed local ASR stops locally'],
  ['entry/src/main/ets/pages/Index.ets', /statusDetail\.startsWith\('本地 ASR：'\)/, 'current system ASR startup phase is visible']
];

const SYSTEM_ASR_SESSION_CHECKS = [
  ['entry/src/main/ets/services/SystemSpeechService.ets', /SPEECH_SESSION_MAX_AUDIO_BYTES = 16000 \* 2 \* 18/, 'bounded local recognition session audio budget'],
  ['entry/src/main/ets/services/SystemSpeechService.ets', /recognitionSessionAudioBytes \+ SPEECH_FRAME_BYTES > SPEECH_SESSION_MAX_AUDIO_BYTES/, 'proactive recognition session length guard'],
  ['entry/src/main/ets/services/SystemSpeechService.ets', /finishRecognitionSessionForRotation\(sessionId\)/, 'recognition session rotation without stopping capture'],
  ['entry/src/main/ets/services/SystemSpeechService.ets', /this\.pendingAudio = audioBytes\.slice\(offset\)/, 'PCM carryover across recognition sessions']
];

const AGENT_TERMINAL_STATE_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /onGatewayError\(message: string\): void[\s\S]{0,700}this\.failAssistantMessage\(errorText\)/, 'gateway error finalizes pending assistant process'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /onGatewayClosed\(\): void[\s\S]{0,700}this\.failAssistantMessage\(this\.snapshot\.error\)/, 'gateway close finalizes pending assistant process'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /gateway event dropped reason=session-mismatch/, 'gateway session mismatch diagnostics'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /assistant message finalized/, 'assistant completion diagnostics']
];

const ERRORS = [];
const warnings = [];

function readRel(rel) {
  const full = path.resolve(root, rel);
  if (!fs.existsSync(full)) {
    return '';
  }
  return fs.readFileSync(full, 'utf8');
}

const systemSpeechSource = readRel('entry/src/main/ets/services/SystemSpeechService.ets');
for (const callback of ['onComplete', 'onError']) {
  const callbackStart = systemSpeechSource.indexOf(`${callback}: (sessionId: string`);
  const callbackEnd = callbackStart >= 0 ? systemSpeechSource.indexOf('\n      }', callbackStart) : -1;
  const callbackSource = callbackStart >= 0 && callbackEnd > callbackStart
    ? systemSpeechSource.slice(callbackStart, callbackEnd)
    : '';
  if (callbackSource.includes('capture.stop')) {
    ERRORS.push(`system STT ${callback} must not stop persistent microphone capture`);
  }
}

function scanDir(dir, out) {
  if (!fs.existsSync(dir)) {
    return;
  }
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      scanDir(full, out);
    } else if (entry.name.endsWith('.ets')) {
      out.push(full);
    }
  }
}

for (const rel of REQUIRED_FILES) {
  const full = path.resolve(root, rel);
  if (!fs.existsSync(full)) {
    ERRORS.push(`missing required file: ${rel}`);
  }
}

const sources = [];
scanDir(ETS, sources);
const allSource = sources.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

for (const [token, label] of REQUIRED_TOKENS) {
  if (!allSource.includes(token)) {
    ERRORS.push(`missing protocol token "${token}" (${label})`);
  }
}

for (const [token, label] of FORBIDDEN) {
  if (allSource.includes(token)) {
    ERRORS.push(`forbidden Host remnant "${token}" (${label})`);
  }
}

for (const pattern of CREDENTIAL_PATTERNS) {
  const match = allSource.match(pattern);
  if (match) {
    ERRORS.push(`credential-like content found: ${match[0].slice(0, 32)}`);
  }
}

for (const [rel, pattern, label] of HISTORY_PAGINATION_CHECKS) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing history pagination behavior (${label})`);
  }
}

for (const [rel, pattern, label] of AUDIO_CUE_CHECKS) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing audio cue behavior (${label})`);
  }
}

for (const [rel, pattern, label] of [
  ...HISTORY_TIMESTAMP_CHECKS,
  ...HISTORY_TOOL_CHECKS,
  ...SYSTEM_TTS_STREAM_CHECKS,
  ...AUDIO_INPUT_ROUTE_CHECKS,
  ...VOICE_CONTROL_CHECKS,
  ...MESSAGE_BUBBLE_CHECKS,
  ...REACTIVE_UI_CHECKS,
  ...SYSTEM_ASR_STARTUP_CHECKS,
  ...SYSTEM_ASR_SESSION_CHECKS,
  ...AGENT_TERMINAL_STATE_CHECKS
]) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing restored history/TTS streaming behavior (${label})`);
  }
}

const controllerSource = readRel('entry/src/main/ets/services/SingleAgentController.ets');
const indexSource = readRel('entry/src/main/ets/pages/Index.ets');
const pcmAudioSource = readRel('entry/src/main/ets/services/PcmAudio.ets');
if (pcmAudioSource.includes('selectMediaInputDevice(')) {
  ERRORS.push('headset capture must not be blocked by global explicit media-input selection');
}
for (const forbiddenRouteOverride of [
  'clearSelectedMediaInputDevice(',
  'setBluetoothAndNearlinkPreferredRecordCategory(',
  'getPreferredOutputDeviceForRendererInfoSync',
  'SOURCE_TYPE_VOICE_RECOGNITION'
]) {
  if (pcmAudioSource.includes(forbiddenRouteOverride)) {
    ERRORS.push(`communication audio must leave device routing to HarmonyOS (${forbiddenRouteOverride})`);
  }
}
if (!indexSource.includes("message.id + '-' + String(message.revision)")) {
  ERRORS.push('streaming messages must use revision as the ForEach key on device');
}
if (indexSource.includes('LiveAsrBubble')) {
  ERRORS.push('ASR preview must be represented by the persistent user message');
}
if (controllerSource.includes('onSnapshot(this.snapshot)')) {
  ERRORS.push('UI listeners must receive a fresh snapshot so stable message keys still repaint');
}
if (controllerSource.includes('fallbackToRemoteVoice')) {
  ERRORS.push('explicit local speech selection must never fall back to the remote backend');
}
const systemAsrStart = controllerSource.indexOf('private startSystemRecognition(): void');
const systemAsrEnd = controllerSource.indexOf('private failSystemRecognition(', systemAsrStart);
if (systemAsrStart >= 0 && systemAsrEnd > systemAsrStart) {
  const systemAsrSource = controllerSource.slice(systemAsrStart, systemAsrEnd);
  const timeoutStart = systemAsrSource.indexOf('this.systemRecognitionReadyTimeout = setTimeout');
  const recognitionStart = systemAsrSource.indexOf('speech.startRecognition()');
  if (timeoutStart < 0 || recognitionStart < 0 || timeoutStart > recognitionStart) {
    ERRORS.push('system ASR startup timeout must cover the complete startRecognition operation');
  }
}
const inputStopStart = controllerSource.indexOf('private stopVoiceInput(): void');
const inputStopEnd = controllerSource.indexOf('private stopVoice(): void', inputStopStart);
if (inputStopStart >= 0 && inputStopEnd > inputStopStart) {
  const inputStopSource = controllerSource.slice(inputStopStart, inputStopEnd);
  for (const forbiddenInputAction of ['tts.sendStop', 'systemSpeech?.stopSpeaking', 'player.stop', 'gateway.interrupt']) {
    if (inputStopSource.includes(forbiddenInputAction)) {
      ERRORS.push(`microphone shutdown must not perform ${forbiddenInputAction}`);
    }
  }
}

if (!allSource.includes('webSocket.WebSocketRequestOptions')) {
  warnings.push('no WebSocketRequestOptions usage; verify Cookie header handshake is implemented');
}

const etsCount = sources.length;
const jsons = [
  path.join(root, 'build-profile.json5'),
  path.join(root, 'oh-package.json5'),
  path.join(root, 'entry/src/main/module.json5'),
  path.join(root, 'AppScope/app.json5')
];
for (const file of jsons) {
  try {
    JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    ERRORS.push(`invalid JSON in ${path.relative(root, file)}`);
  }
}

if (ERRORS.length > 0) {
  console.error(`HarmonyOS single-agent verification FAILED (${ERRORS.length})`);
  for (const error of ERRORS) {
    console.error(`  [error] ${error}`);
  }
  process.exit(1);
}

console.log(`HarmonyOS single-agent project verification passed (${etsCount} ets files).`);
if (warnings.length > 0) {
  for (const warning of warnings) {
    console.warn(`  [warn] ${warning}`);
  }
}
