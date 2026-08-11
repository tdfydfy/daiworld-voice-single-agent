// Single-Agent HarmonyOS project static verification.
// Replaces the Host project's verify script: checks that this client targets
// the Hermes JSON-RPC / streaming ASR / streaming TTS contract and contains
// no Host orchestration protocol remnants.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ETS = path.join(root, 'entry/src/main/ets');
const projectRoot = path.resolve(root, '..', '..');

const REQUIRED_FILES = [
  'entry/src/main/ets/models/HermesProtocol.ets',
  'entry/src/main/ets/models/VoiceProtocol.ets',
  'entry/src/main/ets/models/SingleAgentState.ets',
  'entry/src/main/ets/services/AuthSessionClient.ets',
  'entry/src/main/ets/services/AgentCatalogClient.ets',
  'entry/src/main/ets/services/ModelOptionsClient.ets',
  'entry/src/main/ets/services/HermesGatewayClient.ets',
  'entry/src/main/ets/services/HermesSessionDetailClient.ets',
  'entry/src/main/ets/services/SecureTokenStore.ets',
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

const DYNAMIC_AGENT_CHECKS = [
  ['entry/src/main/ets/services/AgentCatalogClient.ets', /\/api\/agents/, 'dynamic Agent catalog route'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /loadAgentCatalog\(generation\)/, 'catalog loaded before gateway'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /服务器暂未配置可用 Agent/, 'empty catalog state'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /agentsLoading: boolean/, 'catalog loading state'],
  ['entry/src/main/ets/pages/Index.ets', /this\.snapshot\.agents\.map/, 'dynamic Agent selector'],
  ['entry/src/main/ets/pages/Index.ets', /selectedAgentAvatar\(\)/, 'Agent avatar placeholder'],
  ['entry/src/main/ets/models/HermesProtocol.ets', /speech_text\?: string/, 'speech text compatibility field'],
  ['entry/src/main/ets/services/SpeechTextFilter.ets', /MEDIA:/, 'TTS media directive filtering']
];

const THINKING_LINE_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /private thinkingLines\(text: string\): string\[\]/, 'natural thinking line splitter'],
  ['entry/src/main/ets/pages/Index.ets', /ForEach\(this\.thinkingLines\(message\.thinking\)/, 'line-based thinking rendering'],
  ['entry/src/main/ets/pages/Index.ets', /const boundaries = '。！？!\?；;'/, 'sentence boundary grouping']
];

const MESSAGE_REPLAY_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /sys\.symbol\.speaker_wave_2/, 'assistant replay icon'],
  ['entry/src/main/ets/pages/Index.ets', /this\.controller\.replayMessage\(message\)/, 'assistant replay action'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /canReplayMessage\(message: ChatMessage\)/, 'replay availability guard'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /const text = SpeechTextFilter\.clean\(source\.text\)/, 'replay TTS-safe text'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /copy\.replaying = source\.replaying/, 'replay state reaches UI'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.finishSystemSpeechStream\(text\)/, 'long system replay chunking'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.player\.waitForDrain\([\s\S]{0,350}this\.clearActiveReplayState\(\)/, 'remote replay ends after PCM drain'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private replayGeneration: number = 0/, 'replay generation guard'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private replayCleanup: Promise<void> = Promise\.resolve\(\)/, 'serialized replay cleanup promise'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /startReplayAfterCleanup\(text, source\.id, replayGeneration, cleanup\)/, 'replay waits for cleanup before TTS start'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /if \(this\.useSystemSpeech\) \{[\s\S]{0,180}const cleanup = Promise\.resolve\(\)/, 'system replay does not wait for remote PCM cleanup'],
  ['entry/src/main/ets/services/SystemSpeechService.ets', /private ttsRequestGeneration: number = 0/, 'system TTS cancellation generation']
];

const MODEL_SWITCH_CHECKS = [
  ['entry/src/main/ets/services/ModelOptionsClient.ets', /\/api\/hermes\/model\/options\?profile=/, 'controlled model options route'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /modelOptionsLoading: boolean/, 'model options loading state'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /modelSwitching: boolean/, 'model switch progress state'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /model\.id \+ ' --provider ' \+ provider\.id \+ ' --session'/, 'session-only model switch command'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /confirmModelSwitch\(data\)/, 'session.info switch confirmation'],
  ['entry/src/main/ets/pages/Index.ets', /只切换当前 Session，不修改 Agent 的默认配置/, 'session-only scope explanation'],
  ['entry/src/main/ets/pages/Index.ets', /切换并确认中/, 'model switch progress feedback']
];

const CONVERSATIONAL_PROTOCOL_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /consumePendingProtocolReply\(value, existingMessage\)/, 'pending protocol replies bypass prompt.submit'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /APPROVAL_ALLOW_PHRASES/, 'exact approval allow phrases'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /APPROVAL_DENY_PHRASES/, 'exact approval deny phrases'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /approvalConversationText\(description, command\)/, 'approval request enters conversation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /clarifyConversationText\(question, parsedChoices\)/, 'clarification request enters conversation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /approvalResponseInFlight/, 'duplicate approval response guard'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /clarifyResponseInFlight/, 'duplicate clarification response guard']
];

const PROVIDER_IDENTITY_CHECKS = [
  ['entry/src/main/ets/services/ModelOptionsClient.ets', /active_provider_label/, 'active provider label from Adapter'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /ModelProviderInfo\.isGenericName\(suppliedName\)/, 'generic model option display replacement'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /reconcileRuntimeProvider\(catalog\)/, 'runtime provider identity reconciliation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /confirmedProvider\.name/, 'model switch keeps concrete provider identity']
];

const VERSION_DISPLAY_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /getBundleInfoForSelfSync/, 'manifest-derived app version'],
  ['entry/src/main/ets/pages/Index.ets', /Text\(this\.appVersion\)/, 'settings version display']
];

const SECURE_TOKEN_CHECKS = [
  ['entry/src/main/ets/services/SecureTokenStore.ets', /@kit\.UniversalKeystoreKit/, 'HUKS-backed token key'],
  ['entry/src/main/ets/services/SecureTokenStore.ets', /HUKS_AES_KEY_SIZE_256/, 'AES-256 token encryption'],
  ['entry/src/main/ets/services/SecureTokenStore.ets', /HUKS_MODE_GCM/, 'authenticated token encryption'],
  ['entry/src/main/ets/services/SecureTokenStore.ets', /generateRandomSync\(GCM_NONCE_BYTES\)/, 'fresh GCM nonce'],
  ['entry/src/main/ets/services/SecureTokenStore.ets', /HUKS_TAG_AE_TAG/, 'GCM authentication tag on decrypt'],
  ['entry/src/main/ets/services/SecureTokenStore.ets', /await this\.save\(store, legacyValue\)/, 'legacy plaintext migration'],
  ['entry/src/main/ets/services/SecureTokenStore.ets', /deleteSync\(LEGACY_TOKEN_KEY\)/, 'legacy plaintext deletion'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /async setContext\(context: common\.UIAbilityContext\): Promise<void>/, 'asynchronous secure startup'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /waitForConfigPersistence\(\): Promise<void>/, 'secure persistence completion boundary'],
  ['entry/src/main/ets/pages/Index.ets', /this\.controller\.waitForConfigPersistence\(\)/, 'settings waits for secure token persistence'],
  ['entry/src/main/ets/pages/Index.ets', /if \(!this\.controllerReady\)/, 'page startup waits for secure token load']
];

const GATEWAY_RECOVERY_CHECKS = [
  ['entry/src/main/ets/services/AuthSessionClient.ets', /unauthorized: boolean = false/, 'terminal authentication failure classification'],
  ['entry/src/main/ets/services/AuthSessionClient.ets', /retryable: boolean = false/, 'transient authentication failure classification'],
  ['entry/src/main/ets/services/HermesGatewayClient.ets', /private socketGeneration: number = 0/, 'gateway socket generation isolation'],
  ['entry/src/main/ets/services/HermesGatewayClient.ets', /this\.socket !== socket \|\| this\.socketGeneration !== generation/, 'stale gateway callback guard'],
  ['entry/src/main/ets/models/HermesProtocol.ets', /GATEWAY_HEARTBEAT: string = 'gateway\.heartbeat'/, 'gateway heartbeat protocol event'],
  ['entry/src/main/ets/services/HermesGatewayClient.ets', /GATEWAY_HEARTBEAT_TIMEOUT_MS = 70000/, 'gateway heartbeat watchdog timeout'],
  ['entry/src/main/ets/services/HermesGatewayClient.ets', /this\.recordHeartbeat\(\)/, 'gateway heartbeat refreshes the watchdog'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /GATEWAY_RECONNECT_DELAYS_MS: number\[\] = \[500, 1500, 3000, 5000\]/, 'bounded gateway reconnect backoff'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /GATEWAY_RECONNECT_MAX_ATTEMPTS = 6/, 'gateway reconnect attempt cap'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /GATEWAY_READY_TIMEOUT_MS = 10000/, 'gateway ready watchdog'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /authResult\.unauthorized[\s\S]{0,100}gatewayReconnectBlocked = true/, 'invalid token stops automatic retries'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /scheduleGatewayReconnect\('网关连接已断开'\)/, 'unexpected gateway close recovery'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /restoreSessionAfterReconnect\(this\.snapshot\.storedSessionId\)/, 'non-destructive stored session recovery after reconnect'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /loadAgentCatalog\(generation\)/, 'catalog load follows the active connection generation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /generation !== this\.gatewayConnectGeneration \|\| this\.gatewayReconnectBlocked/, 'stale authentication and catalog attempt guard'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /scheduleGatewayReconnect\(this\.snapshot\.error\);[\s\S]{0,80}this\.notify\(\)/, 'catalog retry state reaches the UI']
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
  ['entry/src/main/ets/services/SingleAgentController.ets', /appendSystemSpeechStream\(speechDelta\)/, 'delta-fed system TTS'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /finishSystemSpeechStream\(speechText\)/, 'final system TTS flush'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /systemSpeechChunkEnd\(/, 'punctuation-aware TTS chunking']
];

const AUDIO_INPUT_ROUTE_CHECKS = [
  ['entry/src/main/ets/services/PcmAudio.ets', /source: audio\.SourceType\.SOURCE_TYPE_VOICE_COMMUNICATION/, 'communication capture source'],
  ['entry/src/main/ets/services/PcmAudio.ets', /audio\.StreamUsage\.STREAM_USAGE_VOICE_COMMUNICATION/, 'communication playback usage'],
  ['entry/src/main/ets/services/PcmAudio.ets', /AUDIO_SESSION_SCENE_VOICE_COMMUNICATION/, 'communication audio session scene'],
  ['entry/src/main/ets/services/PcmAudio.ets', /CONCURRENCY_MIX_WITH_OTHERS/, 'system TTS-compatible communication session'],
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
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.snapshot\.asrState = 'stopped';[\s\S]{0,120}this\.asr\.close\(\);/, 'capture failure clears ASR connecting state'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /CLOSE_MIC_PHRASES: string\[\] = \['关闭话筒', '关闭麦克风', '关闭microphone', '暂停收音'\]/, 'explicit close-microphone phrase allowlist'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private normalizeControlPhrase\(text: string\): string/, 'control phrase normalization boundary'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private isCloseMicPhrase\(text: string\): boolean[\s\S]{0,180}this\.normalizeControlPhrase\(text\)/, 'close-microphone exact normalized matching']
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

const AUDIO_PLAYBACK_RECOVERY_CHECKS = [
  ['entry/src/main/ets/services/PcmAudio.ets', /!this\.speakerphoneEnabled && this\.hasHeadsetOutput\(available\)/, 'headset output remains system-managed'],
  ['entry/src/main/ets/services/PcmAudio.ets', /PCM_RENDERER_WATCHDOG_MS = 1200/, 'queued PCM renderer watchdog'],
  ['entry/src/main/ets/services/PcmAudio.ets', /scheduleRendererRecovery\(\): void/, 'bounded PCM renderer retry'],
  ['entry/src/main/ets/services/PcmAudio.ets', /onCommunicationSessionRecovered\(\): void/, 'renderer recovery after communication-session recovery'],
  ['entry/src/main/ets/services/PcmAudio.ets', /renderer\.on\('audioInterrupt'/, 'renderer interruption observation'],
  ['entry/src/main/ets/services/PcmAudio.ets', /this\.cancelRendererRecovery\(\);[\s\S]{0,180}this\.queue = \[\]/, 'explicit stop cancels renderer recovery']
];

const ASR_FINALIZATION_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /ASR_FINALIZATION_GRACE_MS = 1100/, 'ASR final grace window'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /queueAsrFinal\(value, isLast\)/, 'system ASR final buffering'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /queueAsrFinal\(value, false\)/, 'remote ASR final buffering'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.asrPendingFinalText = this\.mergeAsrSegments/, 'consecutive ASR final accumulation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.snapshot\.asrState = 'finalizing'/, 'visible ASR finalizing state'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /shouldFinalizeAsrImmediately\(text: string\)/, 'immediate voice-control finalization'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /finalizeAsrAfterTermination\(\): void/, 'meaningful ASR text flush on termination'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /!this\.hasSemanticContent\(value\)\)[\s\S]{0,100}this\.discardAsrAndResumePlayback\(\)/, 'discarded ASR false positive resumes paused playback']
];

const REMOTE_VOICE_RECOVERY_CHECKS = [
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /reconnect\(url: string, cookie: string\): void[\s\S]{0,100}this\.open\(url, cookie, true\)/, 'ASR reconnect preserves buffered PCM'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /while \(this\.preReadyBuffer\.length >= 4\)/, 'ASR reconnect buffer remains bounded'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /generation !== this\.connectionGeneration \|\| this\.socket !== socket/, 'ASR stale socket callback isolation'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /failConnection\(socket, generation, 'ASR 连接超时'\)/, 'ASR connecting state has a timeout watchdog'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /reconnect\(url: string, cookie: string\): void[\s\S]{0,100}this\.open\(url, cookie, true\)/, 'TTS reconnect preserves pending frames'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /detachSocket\(!preservePendingFrames\)/, 'TTS explicit close and reconnect have separate buffer semantics'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /sendNextPendingFrame\(socket, generation\)[\s\S]{0,1600}this\.pendingFrames\.shift\(\)/, 'TTS pending frames flush in wire order'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /failConnection\(socket, generation, 'TTS 连接超时'\)/, 'TTS connecting state has a timeout watchdog'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /REMOTE_VOICE_RECONNECT_DELAYS_MS: number\[\] = \[250, 750, 1500, 3000\]/, 'bounded remote voice reconnect backoff'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /scheduleRemoteAsrReconnect\(\): void/, 'remote ASR reconnect scheduling'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /scheduleRemoteTtsReconnect\(\): void/, 'remote TTS reconnect scheduling'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /this\.cancelRemoteAsrReconnect\(\);[\s\S]{0,160}this\.voiceWanted = false|this\.voiceWanted = false;[\s\S]{0,160}this\.cancelRemoteAsrReconnect\(\);/, 'microphone shutdown cancels ASR reconnect'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /drainRemotePlaybackAfterDisconnect\(\): void/, 'received PCM drains across TTS reconnect']
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
  ...AUDIO_PLAYBACK_RECOVERY_CHECKS,
  ...ASR_FINALIZATION_CHECKS,
  ...REMOTE_VOICE_RECOVERY_CHECKS,
  ...AGENT_TERMINAL_STATE_CHECKS
]) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing restored history/TTS streaming behavior (${label})`);
  }
}

for (const [rel, pattern, label] of [
  ...DYNAMIC_AGENT_CHECKS,
  ...THINKING_LINE_CHECKS,
  ...MESSAGE_REPLAY_CHECKS,
  ...MODEL_SWITCH_CHECKS,
  ...CONVERSATIONAL_PROTOCOL_CHECKS,
  ...PROVIDER_IDENTITY_CHECKS,
  ...VOICE_CONTROL_CHECKS,
  ...VERSION_DISPLAY_CHECKS,
  ...SECURE_TOKEN_CHECKS,
  ...GATEWAY_RECOVERY_CHECKS
]) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing dynamic Agent behavior (${label})`);
  }
}

const controllerSource = readRel('entry/src/main/ets/services/SingleAgentController.ets');
const indexSource = readRel('entry/src/main/ets/pages/Index.ets');
const pcmAudioSource = readRel('entry/src/main/ets/services/PcmAudio.ets');
const nativeAdapterSource = fs.readFileSync(path.join(projectRoot, 'app/native_main.py'), 'utf8');
if (/putSync\(['"]accessToken['"]/.test(allSource)) {
  ERRORS.push('access token must never be written to Preferences as plaintext');
}
const gatewayReconnectStart = controllerSource.indexOf('private scheduleGatewayReconnect(reason: string): void');
const gatewayReconnectEnd = controllerSource.indexOf('private cancelGatewayReconnect(): void', gatewayReconnectStart);
if (gatewayReconnectStart >= 0 && gatewayReconnectEnd > gatewayReconnectStart &&
  controllerSource.slice(gatewayReconnectStart, gatewayReconnectEnd).includes('submitPrompt(')) {
  ERRORS.push('gateway reconnect must resume server state and never resubmit a user prompt');
}
if (pcmAudioSource.includes('selectMediaInputDevice(')) {
  ERRORS.push('headset capture must not be blocked by global explicit media-input selection');
}
for (const forbiddenRouteOverride of [
  'clearSelectedMediaInputDevice(',
  'setBluetoothAndNearlinkPreferredRecordCategory(',
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
if (pcmAudioSource.includes('this.ensureRenderer().catch(() => undefined)')) {
  ERRORS.push('queued PCM must use renderer recovery instead of swallowing renderer startup failures');
}
const outputPreferenceStart = pcmAudioSource.indexOf('private async applyOutputPreference(): Promise<void>');
const outputPreferenceEnd = pcmAudioSource.indexOf('private communicationRendererInfo()', outputPreferenceStart);
if (outputPreferenceStart >= 0 && outputPreferenceEnd > outputPreferenceStart) {
  const outputPreferenceSource = pcmAudioSource.slice(outputPreferenceStart, outputPreferenceEnd);
  const headsetGuard = outputPreferenceSource.indexOf('this.hasHeadsetOutput(available)');
  const defaultOutput = outputPreferenceSource.indexOf('setDefaultOutputDevice(device)');
  if (headsetGuard < 0 || defaultOutput < 0 || headsetGuard > defaultOutput) {
    ERRORS.push('headset guard must run before applying the phone fallback output device');
  }
}
for (const immediateAsrFinal of [
  'if (isFinal) {\n      this.onAsrFinal(value);',
  'if (final) {\n      this.onAsrFinal(value);'
]) {
  if (controllerSource.includes(immediateAsrFinal)) {
    ERRORS.push('ordinary ASR final must pass through the finalization grace window');
  }
}
for (const removedPanel of ['ApprovalPanel', 'ClarifyPanel']) {
  if (indexSource.includes(removedPanel)) {
    ERRORS.push(`${removedPanel} must be represented in the conversation stream instead of a standalone card`);
  }
}
if (controllerSource.includes('onSnapshot(this.snapshot)')) {
  ERRORS.push('UI listeners must receive a fresh snapshot so stable message keys still repaint');
}
if (controllerSource.includes('fallbackToRemoteVoice')) {
  ERRORS.push('explicit local speech selection must never fall back to the remote backend');
}
for (const [pattern, label] of [
  ['def has_semantic_content(text: object) -> bool:', 'Adapter ASR semantic predicate'],
  ['def normalize_asr_transcript_frame(message: str) -> str:', 'Adapter ASR final-frame normalizer'],
  ['transform_text=normalize_asr_transcript_frame', 'ASR route uses the common boundary'],
  ['GATEWAY_HEARTBEAT_INTERVAL_SECONDS = 25.0', 'Gateway downstream heartbeat interval'],
  ['await send_client_text(GATEWAY_HEARTBEAT_FRAME)', 'Gateway heartbeat reaches the client'],
  ['heartbeat_interval=GATEWAY_HEARTBEAT_INTERVAL_SECONDS', 'Hermes route enables downstream heartbeats'],
]) {
  if (!nativeAdapterSource.includes(pattern)) {
    ERRORS.push(`missing ASR semantic boundary (${label})`);
  }
}
const reconnectRestoreStart = controllerSource.indexOf('private restoreSessionAfterReconnect(storedId: string): void');
const reconnectMissingStart = controllerSource.indexOf('if (this.isSessionNotFound(error))', reconnectRestoreStart);
if (reconnectRestoreStart < 0 || reconnectMissingStart <= reconnectRestoreStart) {
  ERRORS.push('gateway reconnect must have a distinct non-destructive Session restore path');
} else {
  const reconnectRestoreSource = controllerSource.slice(reconnectRestoreStart, reconnectMissingStart);
  if (!reconnectRestoreSource.includes('this.gateway.resumeSession(storedId, 100)')) {
    ERRORS.push('gateway reconnect must resume the existing Session');
  }
  for (const destructiveRestoreAction of ['this.stopVoice()', 'this.snapshot.messages = []']) {
    if (reconnectRestoreSource.includes(destructiveRestoreAction)) {
      ERRORS.push(`gateway reconnect must preserve voice and messages (${destructiveRestoreAction})`);
    }
  }
}
if (!controllerSource.includes('private hasSemanticContent(text: string): boolean')) {
  ERRORS.push('HarmonyOS must retain the ASR semantic predicate as a defensive client boundary');
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
