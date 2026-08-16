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
  'entry/src/main/ets/services/HermesRuntime.ets',
  'entry/src/main/ets/services/HermesSessionDetailClient.ets',
  'entry/src/main/ets/services/GatewayTokenStore.ets',
  'entry/src/main/ets/services/AppSettingsStore.ets',
  'entry/src/main/ets/services/ConversationState.ets',
  'entry/src/main/ets/services/StreamingAsrClient.ets',
  'entry/src/main/ets/services/StreamingTtsClient.ets',
  'entry/src/main/ets/services/SingleAgentController.ets',
  'entry/src/main/ets/services/CommunicationAudioSession.ets',
  'entry/src/main/ets/services/PcmCapture.ets',
  'entry/src/main/ets/services/CaptureRecoveryState.ets',
  'entry/src/main/ets/services/CaptureSupervisor.ets',
  'entry/src/main/ets/services/RecoveryBudget.ets',
  'entry/src/main/ets/services/PcmPlayer.ets',
  'entry/src/main/ets/services/AudioCuePlayer.ets',
  'entry/src/main/ets/services/AudioContinuityState.ets',
  'entry/src/main/ets/services/AudioContinuityCoordinator.ets',
  'entry/src/main/ets/services/BackgroundAudioTaskOwner.ets',
  'entry/src/main/ets/services/HermesRuntime.ets',
  'entry/src/main/ets/services/RuntimeIdentitySync.ets',
  'entry/src/main/ets/services/SystemSpeechQueue.ets',
  'entry/src/main/ets/services/SystemTtsCompletionGate.ets',
  'entry/src/main/ets/services/SystemAsrEngine.ets',
  'entry/src/main/ets/services/SystemTtsPlayer.ets',
  'entry/src/main/ets/services/SpeechPlaybackQueue.ets',
  'entry/src/main/ets/services/VoiceRuntimeState.ets',
  'entry/src/main/ets/services/VoiceRuntime.ets',
  'entry/src/main/ets/services/VoiceInputCoordinator.ets',
  'entry/src/main/ets/services/VoiceOutputCoordinator.ets',
  'entry/src/main/ets/pages/Index.ets',
  'AppScope/resources/base/media/app_icon_v2.svg',
  'entry/src/main/resources/base/media/app_icon_v2.svg',
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
  ['BackgroundMode.AUDIO_PLAYBACK', 'dedicated background playback mode'],
  ['BackgroundMode.AUDIO_RECORDING', 'dedicated background recording mode'],
  ['CaptureSupervisor', 'single supervised capture boundary'],
  ['SpeechPlaybackQueue', 'single audible playback boundary'],
  ['completeDispose', 'idempotent voice-runtime disposal'],
  ['stopBackgroundRunning', 'background task cleanup']
];

const DYNAMIC_AGENT_CHECKS = [
  ['entry/src/main/ets/services/AgentCatalogClient.ets', /\/api\/agents/, 'dynamic Agent catalog route'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /prepareAgentCatalog\(/, 'catalog can load before gateway'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /await this\.refreshAgents\(\)/, 'startup prepares Agent catalog'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /服务器暂未配置可用 Agent/, 'empty catalog state'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /agentsLoading: boolean/, 'catalog loading state'],
  ['entry/src/main/ets/pages/Index.ets', /this\.snapshot\.agents\.map/, 'dynamic Agent selector'],
  ['entry/src/main/ets/pages/Index.ets', /private AgentEntryPanel\(\)/, 'explicit Agent entry panel'],
  ['entry/src/main/ets/pages/Index.ets', /selectedAgentAvatar\(\)/, 'Agent avatar placeholder'],
  ['entry/src/main/ets/models/HermesProtocol.ets', /speech_text\?: string/, 'speech text compatibility field'],
  ['entry/src/main/ets/services/SpeechTextFilter.ets', /MEDIA:/, 'TTS media directive filtering']
];

const THINKING_LINE_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /private thinkingLines\(text: string\): string\[\]/, 'natural thinking line splitter'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /ActivityKind = 'thinking' \| 'tool' \| 'status' \| 'error'/, 'ordered process activity kinds'],
  ['entry/src/main/ets/services/ConversationState.ets', /activity\.kind = 'thinking'/, 'thinking enters the activity timeline'],
  ['entry/src/main/ets/pages/Index.ets', /this\.thinkingLines\(activity\.detail\)/, 'line-based thinking activity rendering'],
  ['entry/src/main/ets/pages/Index.ets', /const boundaries = '。！？!\?；;'/, 'sentence boundary grouping']
];

const MESSAGE_REPLAY_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /sys\.symbol\.speaker_wave_2/, 'assistant replay icon'],
  ['entry/src/main/ets/pages/Index.ets', /this\.controller\.replayMessage\(message\)/, 'assistant replay action'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /canReplayMessage\(message: ChatMessage\)/, 'replay availability guard'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /const text = SpeechTextFilter\.clean\(source\.text\)/, 'replay TTS-safe text'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /copy\.replaying = source\.replaying/, 'replay state reaches UI'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.startSystemReplay\(text\)/, 'system replay has a dedicated first-chunk start'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /for \(let index = 1; index < chunks\.length; index \+= 1\)[\s\S]{0,420}this\.startSystemSpeech\(chunks\[0\]\)/, 'system replay starts first chunk and queues only the remainder'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.player\.waitForDrain\([\s\S]{0,350}this\.clearActiveReplayState\(\)/, 'remote replay ends after PCM drain'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /private replayGeneration: number = 0/, 'replay generation guard'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /private replayCleanup: Promise<void> = Promise\.resolve\(\)/, 'serialized replay cleanup promise'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /startReplayAfterCleanup\(text, source\.id, replayGeneration, cleanup\)/, 'replay waits for cleanup before TTS start'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /if \(this\.useSystemSpeech\) \{[\s\S]{0,220}const cleanup = this\.systemTts\?\.stop\(\) \?\? Promise\.resolve\(\)/, 'system replay waits for local TTS cleanup'],
  ['entry/src/main/ets/services/SystemTtsPlayer.ets', /private requestGeneration: number = 0/, 'system TTS cancellation generation'],
  ['entry/src/main/ets/services/SystemTtsPlayer.ets', /const extraParams:[\s\S]{0,180}'speed': normalizedRate[\s\S]{0,500}engine\.speak/, 'system TTS uses platform playback without requiring PCM callbacks'],
  ['entry/src/main/ets/services/SystemTtsPlayer.ets', /onComplete:[\s\S]{0,500}response\.type === 1[\s\S]{0,500}classifyCompletion\(now\)[\s\S]{0,500}this\.activeRequestId = ''/, 'system TTS completion is verified before queue advancement'],
  ['entry/src/main/ets/services/SystemTtsPlayer.ets', /stop\(\): Promise<void> \{[\s\S]{0,260}this\.activeRequestId = ''/, 'system replay cleanup cannot stop an already completed request'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /message replay requested/, 'replay button request logging'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /message replay state cleared/, 'replay cleanup logging'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /!source\.pending && !this\.snapshot\.agentBusy &&\s*this\.enabled/, 'continuous ASR does not disable replay'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /resumeSession\(storedId: string\): void[\s\S]{0,500}this\.output\.bindEpoch\(epoch\)[\s\S]{0,500}this\.output\.stopForConversationChange\(\)/, 'history resume preserves output intent while cancelling stale playback']
];

const MODEL_SWITCH_CHECKS = [
  ['entry/src/main/ets/services/ModelOptionsClient.ets', /\/api\/hermes\/model\/options\?profile=/, 'controlled model options route'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /modelOptionsLoading: boolean/, 'model options loading state'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /modelSwitching: boolean/, 'model switch progress state'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /model\.id \+ ' --provider ' \+ provider\.id \+ ' --session'/, 'session-only model switch command'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /confirmModelSwitch\(data\)/, 'session.info switch confirmation'],
  ['entry/src/main/ets/pages/Index.ets', /只切换当前 Session，不修改 Agent 的默认配置/, 'session-only scope explanation'],
  ['entry/src/main/ets/pages/Index.ets', /切换并确认中/, 'model switch progress feedback']
];

const CONVERSATIONAL_PROTOCOL_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /consumePendingProtocolReply\(value, existingMessage\)/, 'pending protocol replies bypass prompt.submit'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /APPROVAL_ALLOW_PHRASES/, 'exact approval allow phrases'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /APPROVAL_DENY_PHRASES/, 'exact approval deny phrases'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /approvalConversationText\(description, command\)/, 'approval request enters conversation'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /clarifyConversationText\(question, parsedChoices\)/, 'clarification request enters conversation'],
  ['entry/src/main/ets/services/ConversationState.ets', /approvalResponseInFlight/, 'duplicate approval response guard'],
  ['entry/src/main/ets/services/ConversationState.ets', /clarifyResponseInFlight/, 'duplicate clarification response guard']
];

const PROVIDER_IDENTITY_CHECKS = [
  ['entry/src/main/ets/services/ModelOptionsClient.ets', /active_provider_label/, 'active provider label from Adapter'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /ModelProviderInfo\.isGenericName\(suppliedName\)/, 'generic model option display replacement'],
  ['entry/src/main/ets/services/RuntimeIdentitySync.ets', /reconcileCatalog\(catalog: ModelOptionsCatalog/, 'runtime provider identity reconciliation'],
  ['entry/src/main/ets/services/RuntimeIdentitySync.ets', /resetCatalog\(\): void \{[\s\S]{0,100}this\.lastCatalog = undefined/, 'Agent changes clear stale provider catalog identity'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /resetModelSelection\(\): void \{[\s\S]{0,160}this\.identity\.resetCatalog\(\)/, 'runtime reset clears provider identity cache'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /resetModelSelection\(\): void \{[\s\S]{0,300}this\.snapshot\.runtimeModel = ''[\s\S]{0,100}this\.snapshot\.runtimeProvider = ''/, 'Agent changes clear unconfirmed runtime identity'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /if \(selected === undefined\) \{[\s\S]{0,120}this\.resetModelSelection\(\)/, 'catalog fallback clears the previous Agent identity'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /onSessionCreated\(result: Object\): void[\s\S]{0,700}this\.syncRuntimeIdentity\(info\)/, 'created and resumed sessions actively synchronize identity'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /completeSessionResume\(result: Object, detail\?: Object\): void[\s\S]{0,900}this\.onSessionCreated\(result\)/, 'history resume uses the common Session identity path'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /restoreSessionAfterReconnect\(storedId: string\): void[\s\S]{0,700}this\.onSessionCreated\(result\)/, 'gateway reconnect uses the common Session identity path'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /if \(type === 'session\.info'\) \{[\s\S]{0,100}syncRuntimeIdentity\(data\)/, 'live session.info actively synchronizes identity'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /confirmedProvider\.name/, 'model switch keeps concrete provider identity']
];

const VERSION_DISPLAY_CHECKS = [
  ['entry/src/main/ets/pages/Index.ets', /getBundleInfoForSelfSync/, 'manifest-derived app version'],
  ['entry/src/main/ets/pages/Index.ets', /Text\(this\.appVersion\)/, 'settings version display']
];

const TOKEN_PERSISTENCE_CHECKS = [
  ['entry/src/main/ets/services/GatewayTokenStore.ets', /putSync\(LEGACY_TOKEN_KEY, token\)/, 'gateway token Preferences persistence'],
  ['entry/src/main/ets/services/GatewayTokenStore.ets', /saveAndVerify\(store: preferences\.Preferences, token: string\)/, 'gateway token save-readback verification'],
  ['entry/src/main/ets/services/GatewayTokenStore.ets', /deleteSync\(SECURE_TOKEN_KEY\)/, 'retired HUKS record cleanup'],
  ['entry/src/main/ets/services/GatewayTokenStore.ets', /token save record=%\{public\}s/, 'non-sensitive token persistence diagnostics'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /CredentialState = 'unconfigured' \| 'ready' \| 'storage_error' \| 'unauthorized'/, 'distinct credential recovery states'],
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
  ['entry/src/main/ets/services/HermesRuntime.ets', /GATEWAY_RECONNECT_DELAYS_MS: number\[\] = \[500, 1500, 3000, 5000\]/, 'bounded gateway reconnect backoff'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /GATEWAY_RECONNECT_MAX_ATTEMPTS = 6/, 'gateway reconnect attempt cap'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /GATEWAY_READY_TIMEOUT_MS = 10000/, 'gateway ready watchdog'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /authResult\.unauthorized[\s\S]{0,100}gatewayReconnectBlocked = true/, 'invalid token stops automatic retries'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /scheduleGatewayReconnect\('网关连接已断开'\)/, 'unexpected gateway close recovery'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /restoreSessionAfterReconnect\(this\.snapshot\.storedSessionId\)/, 'non-destructive stored session recovery after reconnect'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /sequence !== this\.agentCatalogSequence/, 'stale Agent catalog request guard'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /generation === this\.gatewayConnectGeneration && !this\.gatewayReconnectBlocked/, 'stale authentication attempt guard'],
  ['entry/src/main/ets/pages/Index.ets', /this\.controller\.refreshAgents\(\)/, 'catalog retry reaches the UI']
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
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.audioCues\.playAccepted\(\)/, 'ASR accepted cue integration'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.audioCues\.playStop\(\)/, 'hard stop cue integration'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.audioCues\.setRunning\(running\)/, 'agent running cue integration'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /beginAgentTurn\(\): void/, 'explicit Agent turn cue start boundary'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /endAgentTurn\(\): void/, 'explicit Agent turn cue end boundary'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.agentTurnActive && this\.snapshot\.agentBusy/, 'thinking cue requires active Agent turn'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.audioCues\.playError\(\)/, 'voice error cue integration'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /yieldForSpeech\(\): Promise<void>/, 'cue-to-speech drain boundary'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /this\.audioCues\.yieldForSpeech\(\)\.then/, 'system TTS waits for cue drain'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /generation !== this\.systemSpeechStartGeneration/, 'stale cue wait cannot start old speech']
];

const HISTORY_TIMESTAMP_CHECKS = [
  ['entry/src/main/ets/services/HermesSessionDetailClient.ets', /\/api\/hermes\/sessions\//, 'timestamped history detail route'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /completeSessionResume\(result, detail\)/, 'history detail resume integration'],
  ['entry/src/main/ets/services/ConversationState.ets', /message\.timestamp = this\.parseTimestamp/, 'stored message timestamp restoration'],
  ['entry/src/main/ets/pages/Index.ets', /date\.getFullYear\(\) === now\.getFullYear\(\)/, 'today-aware message timestamp formatting'],
  ['entry/src/main/ets/pages/Index.ets', /year \+ '-' \+ month \+ '-' \+ day/, 'full date for older messages']
];

const HISTORY_TOOL_CHECKS = [
  ['entry/src/main/ets/services/ConversationState.ets', /if \(roleValue === 'tool'\)/, 'stored tool messages excluded from reply bubbles'],
  ['entry/src/main/ets/services/ConversationState.ets', /restoreHistoryToolResult\(row, pendingActivities\)/, 'stored tool results restored as process activities'],
  ['entry/src/main/ets/services/ConversationState.ets', /message\.activities = pendingActivities/, 'stored activities attached to the assistant response']
];

const SYSTEM_TTS_STREAM_CHECKS = [
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /FIRST_MIN = 20/, 'small first speech chunk'],
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /NEXT_MIN = 40/, 'common sentence-sized continuation minimum'],
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /NEXT_PREFERRED_MAX = 80/, 'common continuation target'],
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /HARD_MAX = 96/, 'common system TTS hard text limit'],
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /finalLimit = this\.firstChunkQueued \? NEXT_PREFERRED_MAX : FIRST_MAX/, 'all final tails obey the common short chunk limit'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /beginAssistantStream\(\): void[\s\S]{0,400}this\.systemSpeechQueue\.beginStream\(\)/, 'live speech uses the common chunk mode'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /replayAwaitingSystemStart = true;[\s\S]{0,100}this\.systemSpeechQueue\.beginStream\(\)/, 'message replay uses the common chunk mode'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /appendSystemSpeechStream\(speechDelta\)/, 'delta-fed system TTS'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /finishSystemSpeechStream\(speechText\)/, 'final system TTS flush'],
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /private chunkEnd\(text: string, final: boolean\)/, 'punctuation-aware TTS chunking'],
  ['entry/src/main/ets/services/SystemSpeechQueue.ets', /pause\(_speechRate: number\): void \{[\s\S]{0,100}this\.pausedText = this\.activeText/, 'system TTS resumes from a complete segment checkpoint'],
  ['entry/src/main/ets/services/SystemTtsCompletionGate.ets', /classifyCompletion\(now: number\): SystemTtsPlaybackEvent[\s\S]{0,220}return 'interrupted'/, 'premature system TTS completion is an interruption'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /event === 'interrupted'[\s\S]{0,400}scheduleSystemSpeechRetry\(token\)/, 'interrupted system TTS retains its active segment'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /const next = this\.systemSpeechQueue\.completeActive\(\)/, 'next chunk starts without restarting ASR']
];

const BACKGROUND_AUDIO_CHECKS = [
  ['entry/src/main/ets/services/AudioContinuityState.ets', /if \(demand\.recording\)[\s\S]{0,80}return 'recording'/, 'recording entitlement wins dual demand'],
  ['entry/src/main/ets/services/BackgroundAudioTaskOwner.ets', /BackgroundMode\.AUDIO_RECORDING[\s\S]{0,120}BackgroundMode\.AUDIO_PLAYBACK/, 'recording and playback use dedicated background modes'],
  ['entry/src/main/ets/services/AudioContinuityState.ets', /this\.runningIntent !== this\.desiredIntent[\s\S]{0,80}return 'stop'/, 'background mode changes stop the old task first'],
  ['entry/src/main/ets/services/AudioContinuityCoordinator.ets', /ensureRecordingReady\(\): Promise<void>/, 'capture waits for recording mode'],
  ['entry/src/main/ets/services/AudioContinuityCoordinator.ets', /ensurePlaybackReady\(\): Promise<void>/, 'playback waits for playback mode'],
  ['entry/src/main/ets/services/BackgroundAudioTaskOwner.ets', /stopBackgroundRunning\(context\)/, 'background cleanup uses the context-owned compatibility path'],
  ['entry/src/main/ets/services/BackgroundAudioTaskOwner.ets', /background stop reported 9800005; treating the stale task as already stopped/, 'stale background task stop is idempotent'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.callbacks\.ensureRecordingReady\(\)[\s\S]{0,300}engine\.start\(epoch\)/, 'system capture waits for lease readiness'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.callbacks\.ensureRecordingReady\(\)[\s\S]{0,300}this\.capture\.start/, 'remote capture waits for lease readiness'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /yieldForSpeech\(\)[\s\S]{0,180}ensurePlaybackReady\(\)[\s\S]{0,500}speech\.speak/, 'system TTS waits for lease readiness'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /const recordingDemand = this\.input\.isWanted\(\);[\s\S]{0,120}const playbackDemand = this\.output\.hasBackgroundOutput\(\);[\s\S]{0,220}syncDemand\(recordingDemand, playbackDemand\)/, 'controller preserves independent recording and playback demand'],
  ['entry/src/main/ets/services/AudioContinuityCoordinator.ets', /this\.owner\.syncDemand\(this\.demand[\s\S]{0,800}this\.owner\.ensureReady\(intent, this\.demand/, 'continuity coordinator owns only background entitlement'],
  ['entry/src/main/ets/services/BackgroundAudioTaskOwner.ets', /background action=/, 'background mode generation logging'],
  ['entry/src/main/module.json5', /"backgroundModes": \["audioPlayback", "audioRecording"\]/, 'manifest declares playback and recording modes']
];

const AUDIO_INPUT_ROUTE_CHECKS = [
  ['entry/src/main/ets/services/PcmCapture.ets', /source: audio\.SourceType\.SOURCE_TYPE_VOICE_COMMUNICATION/, 'communication capture source'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /audio\.StreamUsage\.STREAM_USAGE_VOICE_COMMUNICATION/, 'communication playback usage'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /AUDIO_SESSION_SCENE_VOICE_COMMUNICATION/, 'communication audio session scene'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /CONCURRENCY_MIX_WITH_OTHERS/, 'system TTS-compatible communication session'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /activateAudioSession\(strategy\)/, 'communication audio session activation'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /const speakerActive = this\.speakerphoneEnabled/, 'explicit speaker override remains available with a headset'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /setCommunicationDevice\([\s\S]{0,100}speakerActive/, 'native earpiece and speakerphone switching'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /DEACTIVATED_TIMEOUT[\s\S]{0,360}return;[\s\S]{0,160}this\.scheduleRecovery\(\)/, 'communication session timeout is a normal expiry'],
  ['entry/src/main/ets/services/PcmCapture.ets', /getPreferredInputDeviceForCapturerInfoSync/, 'preferred input device inspection'],
  ['entry/src/main/ets/services/PcmCapture.ets', /getCurrentInputDevices\(\)/, 'active input device verification'],
  ['entry/src/main/ets/services/PcmCapture.ets', /on\('inputDeviceChange'/, 'system-managed input route observation'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.onMicrophoneRouteChanged\(label\)/, 'live microphone route UI update'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /toggleSpeakerphone\(\): void \{[\s\S]{0,220}showCommunicationOutputPicker\(context\)/, 'phone output opens the native communication picker'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /toggleSpeakerphoneFallback\(\): void \{[\s\S]{0,160}this\.snapshot\.audioOutputRoute !== 'speaker'/, 'phone output keeps a direct fallback from the actual route'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /AVCastPickerHelper\(context\)[\s\S]{0,160}sessionType: 'voice_call'/, 'native output picker uses the voice-call device list'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /const player = new PcmPlayer\(\)/, 'audio cues use the communication route']
];

const VOICE_CONTROL_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /private stopVoiceInput\(\)/, 'separate microphone input shutdown'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /private enabled: boolean = true/, 'automatic TTS output state'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /speakerphoneEnabled/, 'persistent speakerphone preference'],
  ['entry/src/main/ets/pages/Index.ets', /toggleSpeakerphone\(\)/, 'speakerphone UI control'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.asr\.isConnected\(\)/, 'ASR reconnect avoids unnecessary TTS reconnect'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /isConnected\(\): boolean/, 'ASR connection state inspection'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.snapshot\.asrState = 'stopped';[\s\S]{0,160}this\.asr\.close\(\);/, 'capture failure clears ASR connecting state'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /CLOSE_MIC_PHRASES: string\[\] = \['关闭话筒', '关闭麦克风', '关闭microphone', '暂停收音'\]/, 'explicit close-microphone phrase allowlist'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /private normalizeControlPhrase\(text: string\): string/, 'control phrase normalization boundary'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /isCloseMicPhrase\(text: string\): boolean[\s\S]{0,180}this\.normalizeControlPhrase\(text\)/, 'close-microphone exact normalized matching']
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
  ['entry/src/main/ets/services/PcmCapture.ets', /getInputRouteLabel\(\): string/, 'active microphone route inspection'],
  ['entry/src/main/ets/models/SingleAgentState.ets', /microphoneRoute: string = ''/, 'microphone route UI state'],
  ['entry/src/main/ets/pages/Index.ets', /microphoneButtonText\(\)/, 'microphone route button label']
];

const SYSTEM_ASR_STARTUP_CHECKS = [
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /reportStartup\(epoch, '创建本地识别引擎'\)/, 'system ASR engine-creation phase reporting'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /reportStartup\(epoch, '启动识别会话'\)/, 'system ASR session phase reporting'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /reportStartup\(epoch, '等待识别引擎 ready'\)/, 'system ASR ready phase reporting'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /本地 ASR 启动超时，停在：/, 'stuck system ASR reports its startup phase'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /failSystemRecognition\(reason: string, phase: string\): void/, 'failed local ASR stops locally'],
  ['entry/src/main/ets/pages/Index.ets', /statusDetail\.startsWith\('本地 ASR：'\)/, 'current system ASR startup phase is visible']
];

const SYSTEM_ASR_SESSION_CHECKS = [
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /SPEECH_SESSION_MAX_AUDIO_BYTES = 16000 \* 2 \* 18/, 'bounded local recognition session audio budget'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /this\.sessionAudioBytes \+ SPEECH_FRAME_BYTES > SPEECH_SESSION_MAX_AUDIO_BYTES/, 'proactive recognition session length guard'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /finishForRotation\(sessionId\)/, 'recognition session rotation without stopping capture'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /this\.pendingAudio = audioBytes\.slice\(offset\)/, 'PCM carryover across recognition sessions'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /rotating && this\.wanted[\s\S]{0,260}this\.startSession\(this\.recognizer, epoch, false\)/, 'recognition rotation preserves PCM carryover']
];

const AUDIO_PLAYBACK_RECOVERY_CHECKS = [
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /speakerActive \? 'speaker' : 'system-preferred'/, 'disabled speaker override returns output to system routing'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /lastHeadsetAvailable !== headsetAvailable[\s\S]{0,180}this\.speakerphoneEnabled = !headsetAvailable/, 'device topology chooses headset or speaker deterministically'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /PCM_RENDERER_WATCHDOG_MS = 1200/, 'queued PCM renderer watchdog'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /getAudioTimestampInfoSync\(\)\.framePos/, 'renderer watchdog follows hardware playback progress'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /const drain = renderer\.drain\(\)/, 'playback completion waits for the system renderer to drain'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /restoreUnconfirmedRendererTail\(\): void \{[\s\S]{0,160}this\.queue\.unshift\(this\.rendererReplayTail\)/, 'renderer reconstruction replays its last unconfirmed PCM buffer'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /STATE_STOPPED[\s\S]{0,180}this\.scheduleRendererRecovery\(`/, 'terminal renderer states enter the common recovery boundary'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /scheduleRendererRecovery\(reason: string\): void[\s\S]{0,500}this\.rendererRecoveryBudget\.beginAttempt\(\)/, 'bounded PCM renderer retry'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /onCommunicationSessionRecovered\(\): void \{[\s\S]{0,180}this\.requestPlayback\(\);/, 'communication-session recovery preserves the current renderer buffer'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /renderer\.on\('audioInterrupt'/, 'renderer interruption observation'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /channels: this\.channelForRenderer\(channelCount\)/, 'PCM renderer follows the source channel count'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /channelCount === 2[\s\S]{0,100}audio\.AudioChannel\.CHANNEL_2/, 'stereo PCM uses a two-channel renderer'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /async stop\(\): Promise<void> \{[\s\S]{0,180}this\.cancelRendererRecovery\(true\)[\s\S]{0,180}this\.queue = \[\]/, 'explicit stop cancels renderer recovery']
];

const AUDIO_CAPTURE_RECOVERY_CHECKS = [
  ['entry/src/main/ets/services/PcmCapture.ets', /capturer\.on\('stateChange'/, 'capturer state observation'],
  ['entry/src/main/ets/services/PcmCapture.ets', /capturer\.on\('audioInterrupt'/, 'capturer interruption observation'],
  ['entry/src/main/ets/services/PcmCapture.ets', /generation !== this\.captureGeneration \|\| this\.capturer !== capturer/, 'stale capturer callback isolation'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /CAPTURE_NO_PCM_TIMEOUT_MS = 2000/, 'no-PCM capture watchdog'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /CAPTURE_RECOVERY_DELAYS_MS: number\[\] = \[100, 500, 1500\]/, 'bounded capture recovery delays'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /this\.recoveryTask !== undefined/, 'serialized capture reconstruction'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /await this\.capture\.stop\(\)\.catch\(\(\) => undefined\)[\s\S]{0,180}await this\.startCapture\(generation\)/, 'old capturer released before reconstruction'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /this\.recovery\.observePcm\(generation\)[\s\S]{0,100}this\.markReady\(generation\)/, 'first healthy PCM completes capture readiness'],
  ['entry/src/main/ets/services/CaptureRecoveryState.ets', /if \(this\.phase === 'recovering'\) \{[\s\S]{0,80}return 0;/, 'one capture recovery at a time'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /private capture: CaptureSupervisor/, 'single input coordinator owns supervised capture'],
  ['entry/src/main/ets/services/SystemAsrEngine.ets', /acceptPcm\(epoch: number, buffer: ArrayBuffer\)/, 'system ASR consumes shared PCM'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /远端 ASR：音频采集正在恢复/, 'remote capture recovery reaches UI state'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /本地 ASR：音频采集正在恢复/, 'system capture recovery reaches UI state'],
  ['entry/src/main/ets/pages/Index.ets', /statusDetail\.startsWith\('远端 ASR：'\)/, 'remote capture recovery state is visible'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /const cleanup = this\.cleanupTask;[\s\S]{0,100}await cleanup\.catch/, 'new capture waits for exhausted cleanup']
];

const ASR_FINALIZATION_CHECKS = [
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /ASR_FINALIZATION_GRACE_MS = 1800/, 'ASR final grace window'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /queueFinal\(epoch, value, isLast\)/, 'system ASR final buffering'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /queueFinal\(epoch, value, false\)/, 'remote ASR final buffering'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.asrPendingFinalText = this\.mergeSegments/, 'consecutive ASR final accumulation'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.snapshot\.asrState = 'finalizing'/, 'visible ASR finalizing state'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /private updateInterim\(epoch: number, text: string\): void[\s\S]{0,700}this\.scheduleFinalization\(epoch\)/, 'ASR interim resets finalization window'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /private queueFinal\(epoch: number, text: string, isLast: boolean\): void[\s\S]{0,1600}this\.scheduleFinalization\(epoch\)/, 'ASR final resets finalization window'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /shouldFinalizeImmediately\(text: string\): boolean[\s\S]{0,220}this\.isStopPhrase\(text\)[\s\S]{0,220}this\.isCloseMicPhrase\(text\)[\s\S]{0,220}this\.snapshot\.clarifyPending[\s\S]{0,220}this\.snapshot\.approvalPending/, 'immediate voice-control finalization'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /finalizeAfterTermination\(\): void/, 'meaningful ASR text flush on termination'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /!this\.hasSemanticContent\(value\)\)[\s\S]{0,100}this\.discardAndResumePlayback\(\)/, 'discarded ASR false positive resumes paused playback']
];

const REMOTE_VOICE_RECOVERY_CHECKS = [
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /reconnect\(url: string, cookie: string\): void[\s\S]{0,100}this\.open\(url, cookie, true\)/, 'ASR reconnect preserves buffered PCM'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /while \(this\.preReadyBuffer\.length >= 4\)/, 'ASR reconnect buffer remains bounded'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /generation !== this\.connectionGeneration \|\| this\.socket !== socket/, 'ASR stale socket callback isolation'],
  ['entry/src/main/ets/services/StreamingAsrClient.ets', /failConnection\(socket, generation, 'ASR 连接超时'\)/, 'ASR connecting state has a timeout watchdog'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /reconnect\(url: string, cookie: string\): void[\s\S]{0,100}this\.open\(url, cookie, false\)/, 'TTS reconnect drops stale job frames'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /failConnection\(socket: webSocket\.WebSocket[\s\S]{0,400}this\.detachSocket\(true\)/, 'TTS failure clears pending frames before a new connection'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /sendNextPendingFrame\(socket, generation\)[\s\S]{0,1600}this\.pendingFrames\.shift\(\)/, 'TTS pending frames flush in wire order'],
  ['entry/src/main/ets/services/StreamingTtsClient.ets', /failConnection\(socket, generation, 'TTS 连接超时'\)/, 'TTS connecting state has a timeout watchdog'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /REMOTE_VOICE_RECONNECT_DELAYS_MS: number\[\] = \[250, 750, 1500, 3000\]/, 'bounded remote voice reconnect backoff'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /REMOTE_ASR_STABLE_RESET_MS = 10000/, 'remote ASR retry budget needs a stable connection before reset'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /REMOTE_VOICE_STABLE_RESET_MS = 10000/, 'remote TTS retry budget needs a stable connection before reset'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /scheduleRemoteReconnect\(\): void/, 'remote ASR reconnect scheduling'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /scheduleRemoteTtsReconnect\(\): void/, 'remote TTS reconnect scheduling'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /this\.wanted = false;[\s\S]{0,160}this\.cancelRemoteReconnect\(\)/, 'microphone shutdown cancels ASR reconnect'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /drainRemotePlaybackAfterDisconnect\(\): void/, 'received PCM drains across TTS reconnect']
];

const AGENT_TERMINAL_STATE_CHECKS = [
  ['entry/src/main/ets/services/SingleAgentController.ets', /onRuntimeUnavailable\(message: string, shouldFinalizeTurn: boolean\): void[\s\S]{0,500}this\.conversation\.failAssistantMessage\(message\)/, 'gateway failure finalizes pending assistant process'],
  ['entry/src/main/ets/services/HermesRuntime.ets', /onClosed\(\): void[\s\S]{0,700}this\.callbacks\.unavailable\('网关连接已断开', wasOnline\)/, 'gateway close delegates conversation finalization'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /gateway event dropped reason=session-mismatch/, 'gateway session mismatch diagnostics'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /assistant message finalized/, 'assistant completion diagnostics']
];

const VOICE_RUNTIME_ARCHITECTURE_CHECKS = [
  ['entry/src/main/ets/services/AudioContinuityState.ets', /isDemandReady\(\): boolean[\s\S]{0,180}this\.isReady\(this\.desiredIntent\)/, 'background readiness follows the policy-selected intent'],
  ['entry/src/main/ets/services/BackgroundAudioTaskOwner.ets', /ensureReady\([\s\S]{0,500}this\.state\.isDemandReady\(\)/, 'background owner validates aggregate demand readiness'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /thinkingOwnsQueue[\s\S]{0,400}!this\.playbackQueue\.hasOutput\(\) \|\| thinkingOwnsQueue/, 'thinking cue may retain its own playback gate'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /ensureAssistantPlaybackJob\(\): boolean[\s\S]{0,500}this\.audioCues\.silence\(\)[\s\S]{0,300}beginPlaybackJob\('assistant'/, 'assistant acquires playback only when speech is ready'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /startSystemSpeech\(text: string\): void[\s\S]{0,300}ensureAssistantPlaybackJob\(\)[\s\S]{0,900}yieldForSpeech\(\)/, 'first system speech chunk owns cue handoff'],
  ['entry/src/main/ets/services/PcmCapture.ets', /setRecoveryListener[\s\S]{0,240}'communication-session-recovered', true/, 'audio-session recovery preserves a healthy Capturer'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /ensureActivated\(\)\.then[\s\S]{0,160}recoveryBudget\.reset\(\)/, 'successful audio-session recovery starts a fresh incident budget'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /type !== 'message\.delta'[\s\S]{0,160}type !== 'thinking\.delta'/, 'high-frequency gateway deltas do not evict lifecycle diagnostics'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /failSystemRecognition\(reason: string, phase: string\): void[\s\S]{0,900}this\.captureStartGeneration \+= 1[\s\S]{0,900}this\.capture\.stop\(\)/, 'failed local ASR releases the capture owner'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /const ready = this\.createReadyWaiter\(\)[\s\S]{0,400}await ready/, 'capture start resolves only through its readiness gate'],
  ['entry/src/main/ets/services/CaptureSupervisor.ets', /markReady\(generation: number\): void[\s\S]{0,400}onState\('running', 'first-pcm'\)/, 'capture readiness requires first PCM'],
  ['entry/src/main/ets/services/CommunicationAudioSession.ets', /communication audio session recovery exhausted users=/, 'audio-session recovery has a logged terminal boundary'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /failPlayback\(message: string\): void[\s\S]{0,900}this\.failureListener\?\.\(message\)/, 'renderer recovery exhaustion reaches its owner'],
  ['entry/src/main/ets/services/PcmPlayer.ets', /async dispose\(\): Promise<void> \{[\s\S]{0,900}await this\.releaseRenderer\(renderer, true\)/, 'PCM dispose waits for renderer and audio-session release'],
  ['entry/src/main/ets/services/SystemTtsPlayer.ets', /private activeToken: string = ''/, 'system TTS carries playback job identity'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /token !== this\.systemSpeechToken/, 'stale system TTS callbacks are rejected'],
  ['entry/src/main/ets/services/VoiceOutputCoordinator.ets', /private playbackQueue: SpeechPlaybackQueue/, 'all audible output shares one playback gate'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /playCue\(buffer: ArrayBuffer[\s\S]{0,180}this\.stopActiveCue\(false\)/, 'cue replacement does not publish a false idle boundary'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /isRunning\(\): boolean \{[\s\S]{0,180}this\.playerCleanup !== undefined/, 'cue playback demand includes pending player cleanup'],
  ['entry/src/main/ets/services/AudioCuePlayer.ets', /yieldForSpeech\(\): Promise<void> \{[\s\S]{0,700}return this\.playerCleanup \?\? Promise\.resolve\(\)/, 'speech waits for a replaced cue player to release'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /scheduleRemoteReconnect\(\): void[\s\S]{0,600}remoteAsrRecoveryBudget\.beginAttempt\(\)[\s\S]{0,180}failRemoteRecovery/, 'remote ASR recovery has a terminal boundary'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /scheduleRemoteTtsReconnect\(\): void[\s\S]{0,700}remoteTtsRecoveryBudget\.beginAttempt\(\)[\s\S]{0,220}远端 TTS 已停止恢复/, 'remote TTS recovery has a terminal boundary'],
  ['entry/src/main/ets/services/VoiceInputCoordinator.ets', /markRemoteReady\(epoch: number\): void[\s\S]{0,700}remoteAsrRecoveryBudget\.observeHealthy\(\)/, 'remote ASR readiness resets its budget only through stable health'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /markRemoteTtsReady\(\): void[\s\S]{0,700}remoteTtsRecoveryBudget\.observeHealthy\(\)/, 'remote TTS readiness resets its budget only through stable health'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /disposeResources\(epoch: number\): Promise<void>[\s\S]{0,900}this\.output\.dispose\(\)[\s\S]{0,300}this\.input\.stop\(\)[\s\S]{0,300}this\.audioContinuity\.release\(\)[\s\S]{0,400}this\.systemAsr\?\.release[\s\S]{0,400}this\.runtime\.disconnect\(\)/, 'dispose follows the resource ownership order'],
  ['entry/src/main/ets/services/SingleAgentController.ets', /DISPOSE_STEP_TIMEOUT_MS = 3000[\s\S]{0,30000}waitForDisposeStep\(task: Promise<void>/, 'dispose cannot wait forever on a platform resource'],
  ['entry/src/main/ets/pages/Index.ets', /aboutToDisappear\(\): void[\s\S]{0,300}this\.controller\.dispose\(\)/, 'page destruction invokes runtime disposal']
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
const captureOwnerCount = sources
  .map((file) => fs.readFileSync(file, 'utf8'))
  .filter((source) => source.includes('new CaptureSupervisor('))
  .length;
if (captureOwnerCount !== 1) {
  ERRORS.push(`voice runtime must have exactly one CaptureSupervisor owner (found ${captureOwnerCount})`);
}
if (allSource.includes('new PcmPlayer(false)')) {
  ERRORS.push('audio cues and remote speech must share the communication playback route');
}

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
  ...AUDIO_CAPTURE_RECOVERY_CHECKS,
  ...BACKGROUND_AUDIO_CHECKS,
  ...ASR_FINALIZATION_CHECKS,
  ...REMOTE_VOICE_RECOVERY_CHECKS,
  ...AGENT_TERMINAL_STATE_CHECKS,
  ...VOICE_RUNTIME_ARCHITECTURE_CHECKS
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
  ...TOKEN_PERSISTENCE_CHECKS,
  ...GATEWAY_RECOVERY_CHECKS
]) {
  if (!pattern.test(readRel(rel))) {
    ERRORS.push(`missing dynamic Agent behavior (${label})`);
  }
}

const controllerSource = readRel('entry/src/main/ets/services/SingleAgentController.ets');
const voiceInputSource = readRel('entry/src/main/ets/services/VoiceInputCoordinator.ets');
const indexSource = readRel('entry/src/main/ets/pages/Index.ets');
const audioSessionSource = readRel('entry/src/main/ets/services/CommunicationAudioSession.ets');
const audioContinuitySource = readRel('entry/src/main/ets/services/AudioContinuityCoordinator.ets');
const pcmCaptureSource = readRel('entry/src/main/ets/services/PcmCapture.ets');
const pcmPlayerSource = readRel('entry/src/main/ets/services/PcmPlayer.ets');
const pcmAudioSource = audioSessionSource + '\n' + pcmCaptureSource + '\n' + pcmPlayerSource;
const nativeAdapterSource = fs.readFileSync(path.join(projectRoot, 'app/native_main.py'), 'utf8');
const gatewayReconnectStart = controllerSource.indexOf('private scheduleGatewayReconnect(reason: string): void');
const gatewayReconnectEnd = controllerSource.indexOf('private cancelGatewayReconnect(): void', gatewayReconnectStart);
if (gatewayReconnectStart >= 0 && gatewayReconnectEnd > gatewayReconnectStart &&
  controllerSource.slice(gatewayReconnectStart, gatewayReconnectEnd).includes('submitPrompt(')) {
  ERRORS.push('gateway reconnect must resume server state and never resubmit a user prompt');
}
if (pcmAudioSource.includes('selectMediaInputDevice(')) {
  ERRORS.push('headset capture must not be blocked by global explicit media-input selection');
}
if (audioContinuitySource.includes('CommunicationAudioSessionLease') ||
  audioContinuitySource.includes('sessionWanted')) {
  ERRORS.push('background continuity must not hold an empty communication audio session');
}
if (audioSessionSource.includes('AudioSessionFailureListener') ||
  audioSessionSource.includes('addFailureListener(')) {
  ERRORS.push('audio-session health must not expose a component-failure propagation path');
}
const pcmCaptureConstructorStart = pcmCaptureSource.indexOf('constructor()');
const pcmCaptureConstructorEnd = pcmCaptureSource.indexOf('async requestPermission(', pcmCaptureConstructorStart);
if (pcmCaptureConstructorStart >= 0 && pcmCaptureConstructorEnd > pcmCaptureConstructorStart &&
  pcmCaptureSource.slice(pcmCaptureConstructorStart, pcmCaptureConstructorEnd)
    .includes('session.setFailureListener')) {
  ERRORS.push('audio-session failure must not tear down a healthy Capturer');
}
const pcmPlayerConstructorStart = pcmPlayerSource.indexOf('constructor(');
const pcmPlayerConstructorEnd = pcmPlayerSource.indexOf('setFailureListener(', pcmPlayerConstructorStart);
if (pcmPlayerConstructorStart >= 0 && pcmPlayerConstructorEnd > pcmPlayerConstructorStart &&
  pcmPlayerSource.slice(pcmPlayerConstructorStart, pcmPlayerConstructorEnd)
    .includes('session.setFailureListener')) {
  ERRORS.push('audio-session failure must not terminate a healthy renderer');
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
const outputPreferenceStart = audioSessionSource.indexOf('private async applyOutputPreference(): Promise<void>');
const outputPreferenceEnd = audioSessionSource.indexOf('private communicationRendererInfo()', outputPreferenceStart);
if (outputPreferenceStart >= 0 && outputPreferenceEnd > outputPreferenceStart) {
  const outputPreferenceSource = audioSessionSource.slice(outputPreferenceStart, outputPreferenceEnd);
  const manualSpeakerOverride = outputPreferenceSource.indexOf('const speakerActive = this.speakerphoneEnabled');
  const nativeRoute = outputPreferenceSource.indexOf('setCommunicationDevice(');
  if (manualSpeakerOverride < 0 || nativeRoute < 0 || manualSpeakerOverride > nativeRoute) {
    ERRORS.push('manual speaker override must be resolved before applying the native communication route');
  }
  if (outputPreferenceSource.includes('setDefaultOutputDevice(')) {
    ERRORS.push('communication routing must not stack a global default-output override');
  }
}
if (indexSource.includes('.enabled(!this.snapshot.headsetOutputAvailable)')) {
  ERRORS.push('audio output selection must remain enabled when a headset is connected');
}
const toggleSpeakerStart = controllerSource.indexOf('toggleSpeakerphone(): void');
const toggleSpeakerEnd = controllerSource.indexOf('private applySpeakerphonePreference()', toggleSpeakerStart);
if (toggleSpeakerStart >= 0 && toggleSpeakerEnd > toggleSpeakerStart) {
  const toggleSpeakerSource = controllerSource.slice(toggleSpeakerStart, toggleSpeakerEnd);
  if (toggleSpeakerSource.includes('headsetOutputAvailable')) {
    ERRORS.push('manual audio output selection must not be blocked by headset availability');
  }
}
const outputRouteCallbackStart = controllerSource.indexOf('private onOutputRouteChanged(');
const outputRouteCallbackEnd = controllerSource.indexOf('toggleMute()', outputRouteCallbackStart);
if (outputRouteCallbackStart >= 0 && outputRouteCallbackEnd > outputRouteCallbackStart) {
  const outputRouteCallback = controllerSource.slice(outputRouteCallbackStart, outputRouteCallbackEnd);
  if (outputRouteCallback.includes('this.config.speakerphoneEnabled') ||
    outputRouteCallback.includes('persistConfig()')) {
    ERRORS.push('device route callbacks must not overwrite the persisted output preference');
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
const openSettingsStart = indexSource.indexOf('private openSettings(): void');
const openSettingsEnd = indexSource.indexOf('private closeSettings(): void', openSettingsStart);
if (openSettingsStart >= 0 && openSettingsEnd > openSettingsStart &&
  indexSource.slice(openSettingsStart, openSettingsEnd).includes('loadModelOptions')) {
  ERRORS.push('settings view must display shared runtime identity and must not trigger identity refresh');
}
const systemSpeechStateStart = controllerSource.indexOf('onSystemSpeechState(');
const systemSpeechStateEnd = controllerSource.indexOf('onSystemSpeechError(', systemSpeechStateStart);
if (systemSpeechStateStart >= 0 && systemSpeechStateEnd > systemSpeechStateStart &&
  controllerSource.slice(systemSpeechStateStart, systemSpeechStateEnd).includes('startSystemRecognition()')) {
  ERRORS.push('system TTS chunk completion must not restart an already persistent ASR lifecycle');
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
  if (!reconnectRestoreSource.includes('this.runtime.resumeSession(storedId, 100)')) {
    ERRORS.push('gateway reconnect must resume the existing Session');
  }
  for (const destructiveRestoreAction of ['this.stopVoice()', 'this.snapshot.messages = []']) {
    if (reconnectRestoreSource.includes(destructiveRestoreAction)) {
      ERRORS.push(`gateway reconnect must preserve voice and messages (${destructiveRestoreAction})`);
    }
  }
}
if (!voiceInputSource.includes('private hasSemanticContent(text: string): boolean')) {
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

try {
  const appProfile = JSON.parse(fs.readFileSync(path.join(root, 'AppScope/app.json5'), 'utf8'));
  if (appProfile.app.versionName !== '1.2.10' || appProfile.app.versionCode !== 1020010) {
    ERRORS.push('HarmonyOS release version must be 1.2.10 (1020010)');
  }
} catch (error) {
  // The JSON parse error is reported by the validation loop above.
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
