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
  'entry/src/main/ets/services/StreamingAsrClient.ets',
  'entry/src/main/ets/services/StreamingTtsClient.ets',
  'entry/src/main/ets/services/SingleAgentController.ets',
  'entry/src/main/ets/services/PcmAudio.ets',
  'entry/src/main/ets/pages/Index.ets',
  'AppScope/app.json5',
  'build-profile.json5',
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
  ['message.complete', 'message complete event']
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

const ERRORS = [];
const warnings = [];

function readRel(rel) {
  const full = path.resolve(root, rel);
  if (!fs.existsSync(full)) {
    return '';
  }
  return fs.readFileSync(full, 'utf8');
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
