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
  ...SYSTEM_TTS_STREAM_CHECKS
]) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing restored history/TTS streaming behavior (${label})`);
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
