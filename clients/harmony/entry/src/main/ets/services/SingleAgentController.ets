// Single-Agent controller state machine for HarmonyOS.
// Deliberately excludes Host orchestration (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

import { common, wantAgent } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AudioOutputRoute,
  ChatMessage,
  HistorySession,
  MessageArtifact,
  MessageActivity,
  MessageRole,
  AgentCatalog,
  AgentInfo,
  ModelOptionInfo,
  ModelProviderInfo,
  ProfileKey,
  SingleAgentSnapshot,
  SpeechBackend
} from '../models/SingleAgentState';
import { AuthSessionClient } from './AuthSessionClient';
import { AgentCatalogClient } from './AgentCatalogClient';
import { ModelOptionsCatalog, ModelOptionsClient } from './ModelOptionsClient';
import { GatewayListener, HermesGatewayClient } from './HermesGatewayClient';
import { HermesSessionDetailClient } from './HermesSessionDetailClient';
import { SecureTokenStore } from './SecureTokenStore';
import { SpeechTextFilter } from './SpeechTextFilter';
import { AudioCuePlayer } from './AudioCuePlayer';
import {
  PcmCapture,
  PcmPlayer,
  setCommunicationOutputRouteListener,
  setCommunicationSpeakerphoneEnabled
} from './PcmAudio';
import { AsrListener, StreamingAsrClient } from './StreamingAsrClient';
import { StreamingTtsClient, TtsJobListener } from './StreamingTtsClient';
import {
  SystemSpeechCallbacks,
  SystemSpeechCapabilities,
  SystemSpeechService,
  VoiceOption
} from './SystemSpeechService';

const STOP_PHRASES: string[] = ['停止', 'stop'];
const CLOSE_MIC_PHRASES: string[] = ['关闭话筒', '关闭麦克风', '关闭microphone', '暂停收音'];
const APPROVAL_ALLOW_PHRASES: string[] = ['同意', '允许', '可以', '执行', '允许执行', '同意执行'];
const APPROVAL_DENY_PHRASES: string[] = ['取消', '拒绝', '阻止', '不要', '拒绝执行', '阻止执行'];
export const DEFAULT_GATEWAY_URL = 'https://voice.daiworld.cc.cd/voice-native';
const SETTINGS_FILE = 'single_agent_settings';
const SYSTEM_TTS_FIRST_MIN = 20;
const SYSTEM_TTS_FIRST_TARGET = 32;
const SYSTEM_TTS_FIRST_MAX = 48;
const SYSTEM_TTS_NEXT_MIN = 100;
const SYSTEM_TTS_NEXT_TARGET = 140;
const SYSTEM_TTS_NEXT_PREFERRED_MAX = 180;
const SYSTEM_TTS_HARD_MAX = 300;
const SYSTEM_TTS_HARD_BOUNDARIES = '。！？；.!?;\n';
const SYSTEM_TTS_SOFT_BOUNDARIES = '，、：,: ';
const SYSTEM_ASR_STARTUP_TIMEOUT_MS = 15000;
const ASR_FINALIZATION_GRACE_MS = 1100;
const REMOTE_VOICE_RECONNECT_DELAYS_MS: number[] = [250, 750, 1500, 3000];
const GATEWAY_RECONNECT_DELAYS_MS: number[] = [500, 1500, 3000, 5000];
const GATEWAY_RECONNECT_MAX_ATTEMPTS = 6;
const GATEWAY_READY_TIMEOUT_MS = 10000;
const MODEL_SWITCH_CONFIRM_TIMEOUT_MS = 10000;
const CONTROLLER_LOG_DOMAIN = 0xD004;
const CONTROLLER_LOG_TAG = 'SingleAgentControl';

export class SnapshotListener {
  private callback: (snapshot: SingleAgentSnapshot) => void;

  constructor(callback: (snapshot: SingleAgentSnapshot) => void) {
    this.callback = callback;
  }

  onSnapshot(snapshot: SingleAgentSnapshot): void {
    this.callback(snapshot);
  }
}

export interface ClientConfig {
  gatewayUrl: string;
  accessToken: string;
  profile: ProfileKey;
  muted: boolean;
  speakerphoneEnabled: boolean;
  debugMode: boolean;
  speechBackend: SpeechBackend;
  voicePerson: number;
  speechRate: number;
}

class HistoryToolResult {
  success: boolean = true;
  message: string = '';
}

class ControllerGatewayListener extends GatewayListener {
  private controller: SingleAgentController;

  constructor(controller: SingleAgentController) {
    super();
    this.controller = controller;
  }

  onGatewayReady(): void {
    this.controller.onGatewayReady();
  }

  onEvent(type: string, sessionId: string, payload: Object | undefined): void {
    this.controller.onGatewayEvent(type, sessionId, payload);
  }

  onError(message: string): void {
    this.controller.onGatewayError(message);
  }

  onClosed(): void {
    this.controller.onGatewayClosed();
  }
}

class ControllerAsrListener extends AsrListener {
  private controller: SingleAgentController;

  constructor(controller: SingleAgentController) {
    super();
    this.controller = controller;
  }

  onReady(): void {
    this.controller.onAsrReady();
  }

  onTranscript(text: string, interim: boolean, final: boolean): void {
    this.controller.onAsrTranscript(text, interim, final);
  }

  onError(message: string): void {
    this.controller.onAsrError(message);
  }

  onClosed(): void {
    this.controller.onAsrClosed();
  }
}

class ControllerTtsListener extends TtsJobListener {
  private controller: SingleAgentController;

  constructor(controller: SingleAgentController) {
    super();
    this.controller = controller;
  }

  onReady(): void {
    this.controller.onTtsReady();
  }

  onJobStarted(sampleRate: number): void {
    this.controller.onTtsJobStarted(sampleRate);
  }

  onJobPcm(pcm: ArrayBuffer): void {
    this.controller.onTtsJobPcm(pcm);
  }

  onJobEnded(): void {
    this.controller.onTtsJobEnded();
  }

  onJobFallback(): void {
    this.controller.onTtsJobFallback();
  }

  onError(message: string): void {
    this.controller.onTtsError(message);
  }

  onClosed(): void {
    this.controller.onTtsClosed();
  }
}

export class SingleAgentController {
  private gateway: HermesGatewayClient = new HermesGatewayClient();
  private asr: StreamingAsrClient = new StreamingAsrClient();
  private tts: StreamingTtsClient = new StreamingTtsClient();
  private auth: AuthSessionClient = new AuthSessionClient();
  private agentCatalogClient: AgentCatalogClient = new AgentCatalogClient();
  private agentCatalog: AgentCatalog = new AgentCatalog();
  private modelOptionsClient: ModelOptionsClient = new ModelOptionsClient();
  private sessionDetail: HermesSessionDetailClient = new HermesSessionDetailClient();
  private capture: PcmCapture = new PcmCapture();
  private player: PcmPlayer = new PcmPlayer();
  private audioCues: AudioCuePlayer = new AudioCuePlayer();
  private systemSpeech?: SystemSpeechService;
  private listener?: SnapshotListener;
  private context?: common.UIAbilityContext;
  private settings?: preferences.Preferences;
  private secureTokenStore: SecureTokenStore = new SecureTokenStore();
  private configPersistence: Promise<void> = Promise.resolve();
  private persistedAccessToken: string = '';
  private queuedAccessToken: string = '';
  private snapshot: SingleAgentSnapshot = new SingleAgentSnapshot();
  private config: ClientConfig = {
    gatewayUrl: DEFAULT_GATEWAY_URL,
    accessToken: '',
    profile: 'default',
    muted: false,
    speakerphoneEnabled: false,
    debugMode: false,
    speechBackend: 'harmony_offline',
    voicePerson: 0,
    speechRate: 1
  };
  private cookie: string = '';
  // Microphone/ASR input lifecycle. TTS output has its own lifecycle below.
  private voiceWanted: boolean = false;
  private voiceOutputEnabled: boolean = true;
  private capturing: boolean = false;
  private pausedForUser: boolean = false;
  private ttsTextSent: string = '';
  private messageCounter: number = 0;
  private activeAssistantMessageId: string = '';
  private activeAsrMessageId: string = '';
  private activeReplayMessageId: string = '';
  private replayAwaitingSystemStart: boolean = false;
  private replayGeneration: number = 0;
  private replayCleanup: Promise<void> = Promise.resolve();
  private replayCleanupActive: boolean = false;
  private discardInterruptedTurnEvents: boolean = false;
  private replacementPromptSubmitted: boolean = false;
  private useSystemSpeech: boolean = false;
  private systemRecognitionStarting: boolean = false;
  private systemRecognitionRestart?: number;
  private systemRecognitionReadyTimeout?: number;
  private systemRecognitionAttempt: number = 0;
  private systemRecognitionStartupPhase: string = '';
  private activeSystemSpeechText: string = '';
  private pausedSystemSpeechText: string = '';
  private systemSpeechQueue: string[] = [];
  private systemSpeechStartedAt: number = 0;
  private systemSpeechPendingText: string = '';
  private systemSpeechReceivedText: string = '';
  private systemSpeechFirstChunkQueued: boolean = false;
  private speechTextFilter: SpeechTextFilter = new SpeechTextFilter();
  private backgroundTaskRunning: boolean = false;
  private backgroundTaskStarting: boolean = false;
  private backgroundTaskStopping: boolean = false;
  private stopBackgroundTaskAfterStart: boolean = false;
  private lastCueError: string = '';
  private outputRouteInitialized: boolean = false;
  private modelSwitchTimeout?: number;
  private modelSwitchSequence: number = 0;
  private modelOptionsSequence: number = 0;
  private requestedModelProvider: string = '';
  private requestedModel: string = '';
  private modelBeforeSwitch: string = '';
  private approvalResponseInFlight: boolean = false;
  private clarifyResponseInFlight: boolean = false;
  private asrFinalizationTimer?: number;
  private asrPendingFinalText: string = '';
  private asrLatestInterimText: string = '';
  private remoteAsrReconnectTimer?: number;
  private remoteAsrReconnectAttempt: number = 0;
  private remoteTtsReconnectTimer?: number;
  private remoteTtsReconnectAttempt: number = 0;
  private remoteTtsDrainPending: boolean = false;
  private gatewayReconnectTimer?: number;
  private gatewayReconnectAttempt: number = 0;
  private gatewayReconnectInFlight: boolean = false;
  private gatewayReconnectBlocked: boolean = false;
  private gatewayConnectGeneration: number = 0;
  private gatewayReadyTimeout?: number;

  setListener(listener: SnapshotListener): void {
    this.listener = listener;
    this.notify();
  }

  async setContext(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.systemSpeech = new SystemSpeechService(context, new SystemSpeechCallbacks(
      (active: boolean): void => {
        this.onSystemRecognitionState(active);
      },
      (text: string, isFinal: boolean, isLast: boolean): void => {
        this.onSystemRecognitionResult(text, isFinal, isLast);
      },
      (): void => {
        this.onUserSpeechDetected();
      },
      (phase: string): void => {
        this.onSystemRecognitionStartupPhase(phase);
      },
      (label: string): void => {
        this.onMicrophoneRouteChanged(label);
      },
      (active: boolean): void => {
        this.onSystemSpeechState(active);
      },
      (channel: string, message: string): void => {
        this.onSystemSpeechError(channel, message);
      }
    ));
    const capabilities = this.systemSpeech.getCapabilities();
    let token = '';
    try {
      this.settings = preferences.getPreferencesSync(context, { name: SETTINGS_FILE });
      const gateway = this.settings.getSync('gatewayUrl', DEFAULT_GATEWAY_URL);
      const profile = this.settings.getSync('profile', 'default');
      const muted = this.settings.getSync('muted', false);
      const speakerphoneEnabled = this.settings.getSync('speakerphoneEnabled', false);
      const debugMode = this.settings.getSync('debugMode', false);
      const speechBackend = this.settings.getSync('speechBackend', 'harmony_offline');
      const voicePerson = this.settings.getSync('voicePerson', 0);
      const speechRate = this.settings.getSync('speechRate', 1);
      try {
        token = await this.secureTokenStore.load(this.settings);
      } catch (error) {
        this.snapshot.error = '已保存的访问口令无法从安全存储读取，请重新输入';
      }
      this.config = {
        gatewayUrl: typeof gateway === 'string' ? this.normalizeGatewayUrl(gateway) : DEFAULT_GATEWAY_URL,
        accessToken: token,
        profile: this.profileFromValue(profile),
        muted: muted === true,
        speakerphoneEnabled: speakerphoneEnabled === true,
        debugMode: debugMode === true,
        speechBackend: this.speechBackendFromValue(speechBackend),
        voicePerson: typeof voicePerson === 'number' ? voicePerson : 0,
        speechRate: this.normalizeSpeechRate(typeof speechRate === 'number' ? speechRate : 1)
      };
      this.persistedAccessToken = token;
      this.queuedAccessToken = token;
      this.snapshot.selectedProfile = this.config.profile;
    } catch (error) {
      this.settings = undefined;
    }
    this.snapshot.asrBackend = this.config.speechBackend;
    this.snapshot.ttsBackend = this.config.speechBackend;
    this.snapshot.speakerphoneEnabled = this.config.speakerphoneEnabled;
    this.snapshot.debugMode = this.config.debugMode;
    setCommunicationOutputRouteListener((route: AudioOutputRoute, headsetAvailable: boolean): void => {
      this.onOutputRouteChanged(route, headsetAvailable);
    });
    setCommunicationSpeakerphoneEnabled(this.config.speakerphoneEnabled).catch(() => undefined);
    this.notify();
  }

  getConfig(): ClientConfig {
    return {
      gatewayUrl: this.config.gatewayUrl,
      accessToken: this.config.accessToken,
      profile: this.config.profile,
      muted: this.config.muted,
      speakerphoneEnabled: this.config.speakerphoneEnabled,
      debugMode: this.config.debugMode,
      speechBackend: this.config.speechBackend,
      voicePerson: this.config.voicePerson,
      speechRate: this.config.speechRate
    };
  }

  getSnapshot(): SingleAgentSnapshot {
    return this.snapshotForUi();
  }

  artifactUrl(token: string, download: boolean = false): string {
    const base = this.config.gatewayUrl.endsWith('/')
      ? this.config.gatewayUrl.substring(0, this.config.gatewayUrl.length - 1)
      : this.config.gatewayUrl;
    return base + '/api/artifacts/' + encodeURIComponent(token) + (download ? '?download=1' : '');
  }

  openArtifact(artifact: MessageArtifact): void {
    const context = this.context;
    if (!context || artifact.token.length === 0) {
      return;
    }
    context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: this.artifactUrl(artifact.token, !artifact.isImage)
    }).catch((error: BusinessError) => {
      this.snapshot.error = this.errorMessage(error, '无法打开附件');
      this.notify();
    });
  }

  toggleMessageProcess(messageId: string): void {
    for (const message of this.snapshot.messages) {
      if (message.id === messageId) {
        message.processExpanded = !message.processExpanded;
        message.revision += 1;
        this.notify();
        return;
      }
    }
  }

  listSystemVoices(): Promise<VoiceOption[]> {
    if (!this.systemSpeech) {
      const voices: VoiceOption[] = [];
      return Promise.resolve(voices);
    }
    return this.systemSpeech.listVoices();
  }

  waitForConfigPersistence(): Promise<void> {
    return this.configPersistence;
  }

  loadModelOptions(): void {
    if (this.snapshot.modelOptionsLoading) {
      return;
    }
    if (this.config.accessToken.length === 0) {
      this.snapshot.modelProviders = [];
      this.snapshot.modelOptionsError = '请先保存访问口令';
      this.notify();
      return;
    }
    this.snapshot.modelOptionsLoading = true;
    this.snapshot.modelProviders = [];
    this.snapshot.modelOptionsError = '';
    const sequence = ++this.modelOptionsSequence;
    const profile = this.config.profile;
    this.notify();
    this.modelOptionsClient.fetch(
      this.config.gatewayUrl,
      this.config.accessToken,
      profile
    ).then((catalog: ModelOptionsCatalog): void => {
      if (sequence !== this.modelOptionsSequence || profile !== this.config.profile) {
        return;
      }
      const providers = catalog.providers;
      this.snapshot.modelProviders = providers;
      this.snapshot.modelOptionsLoading = false;
      this.snapshot.modelOptionsError = providers.length > 0 ? '' : '服务器暂未返回可用模型';
      this.reconcileRuntimeProvider(catalog);
      this.notify();
    }).catch((error: BusinessError): void => {
      if (sequence !== this.modelOptionsSequence || profile !== this.config.profile) {
        return;
      }
      this.snapshot.modelProviders = [];
      this.snapshot.modelOptionsLoading = false;
      this.snapshot.modelOptionsError = this.errorMessage(error, '模型列表加载失败');
      this.notify();
    });
  }

  switchRuntimeModel(providerId: string, modelId: string): void {
    if (this.snapshot.modelSwitching) {
      return;
    }
    if (this.snapshot.connection !== 'online' || this.snapshot.runtimeSessionId.length === 0) {
      this.snapshot.modelSwitchError = '当前会话尚未连接';
      this.notify();
      return;
    }
    if (this.snapshot.agentBusy) {
      this.snapshot.modelSwitchError = '请等待当前任务结束后再切换模型';
      this.notify();
      return;
    }
    const provider = this.snapshot.modelProviders.find(
      (item: ModelProviderInfo): boolean => item.id === providerId
    );
    const model = provider?.models.find((item: ModelOptionInfo): boolean => item.id === modelId);
    if (provider === undefined || model === undefined ||
      !this.isSafeConfigAtom(provider.id) || !this.isSafeConfigAtom(model.id)) {
      this.snapshot.modelSwitchError = '请选择有效的 Provider 和模型';
      this.notify();
      return;
    }
    this.clearModelSwitchTimeout();
    const sequence = ++this.modelSwitchSequence;
    this.requestedModelProvider = provider.id;
    this.requestedModel = model.id;
    this.modelBeforeSwitch = this.snapshot.runtimeModel;
    this.snapshot.modelSwitching = true;
    this.snapshot.modelSwitchStatus = '正在提交当前会话配置';
    this.snapshot.modelSwitchError = '';
    this.notify();
    this.modelSwitchTimeout = setTimeout((): void => {
      this.modelSwitchTimeout = undefined;
      if (sequence !== this.modelSwitchSequence || !this.snapshot.modelSwitching) {
        return;
      }
      this.snapshot.modelSwitching = false;
      this.snapshot.modelSwitchStatus = '';
      this.snapshot.modelSwitchError = 'Hermes 未返回 session.info，仍显示上次已确认的运行配置';
      this.resetRequestedModel();
      this.notify();
    }, MODEL_SWITCH_CONFIRM_TIMEOUT_MS);
    const value = model.id + ' --provider ' + provider.id + ' --session';
    this.gateway.setConfig('model', value).then((): void => {
      if (sequence !== this.modelSwitchSequence || !this.snapshot.modelSwitching) {
        return;
      }
      this.snapshot.modelSwitchStatus = '切换请求已提交，等待 Hermes 确认';
      this.notify();
    }).catch((error: BusinessError): void => {
      if (sequence !== this.modelSwitchSequence || !this.snapshot.modelSwitching) {
        return;
      }
      this.clearModelSwitchTimeout();
      this.snapshot.modelSwitching = false;
      this.snapshot.modelSwitchStatus = '';
      this.snapshot.modelSwitchError = this.errorMessage(error, '模型切换失败');
      this.resetRequestedModel();
      this.notify();
    });
  }

  setConfig(config: ClientConfig): boolean {
    const gatewayUrl = this.normalizeGatewayUrl(config.gatewayUrl);
    const connectionChanged = gatewayUrl !== this.config.gatewayUrl ||
      config.accessToken !== this.config.accessToken ||
      config.profile !== this.config.profile;
    const speechChanged = config.speechBackend !== this.config.speechBackend ||
      config.voicePerson !== this.config.voicePerson ||
      this.normalizeSpeechRate(config.speechRate) !== this.config.speechRate;
    const speakerphoneChanged = config.speakerphoneEnabled !== this.config.speakerphoneEnabled;
    this.config = {
      gatewayUrl: gatewayUrl,
      accessToken: config.accessToken,
      profile: config.profile,
      muted: config.muted,
      speakerphoneEnabled: config.speakerphoneEnabled,
      debugMode: config.debugMode,
      speechBackend: config.speechBackend,
      voicePerson: config.voicePerson,
      speechRate: this.normalizeSpeechRate(config.speechRate)
    };
    this.snapshot.selectedProfile = this.config.profile;
    this.snapshot.speakerphoneEnabled = this.config.speakerphoneEnabled;
    this.snapshot.debugMode = this.config.debugMode;
    if (connectionChanged) {
      this.clearModelOptions();
      this.cancelModelSwitch('');
      this.snapshot.modelSwitchStatus = '';
      this.snapshot.modelSwitchError = '';
    }
    this.persistConfig();
    this.notify();
    if (speakerphoneChanged) {
      this.applySpeakerphonePreference();
    }
    if (speechChanged && !connectionChanged && (this.voiceWanted || this.voiceOutputEnabled)) {
      this.restartVoiceClients().catch(() => undefined);
    }
    return connectionChanged;
  }

  switchProfile(profile: ProfileKey): void {
    if (profile === this.config.profile || this.snapshot.agentBusy) {
      return;
    }
    const restoreVoice = this.voiceWanted;
    const restoreVoiceOutput = this.voiceOutputEnabled;
    this.setConfig({
      gatewayUrl: this.config.gatewayUrl,
      accessToken: this.config.accessToken,
      profile: profile,
      muted: this.config.muted,
      speakerphoneEnabled: this.config.speakerphoneEnabled,
      debugMode: this.config.debugMode,
      speechBackend: this.config.speechBackend,
      voicePerson: this.config.voicePerson,
      speechRate: this.config.speechRate
    });
    this.disconnect();
    this.snapshot.messages = [];
    this.activeAssistantMessageId = '';
    this.snapshot.storedSessionId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.runtimeModel = '';
    this.snapshot.runtimeProvider = '';
    this.voiceWanted = restoreVoice;
    this.voiceOutputEnabled = restoreVoiceOutput;
    this.snapshot.voiceEnabled = restoreVoice;
    this.notify();
    this.connect();
  }

  // Text input path. Also used after ASR final.
  submitText(text: string, existingMessage?: ChatMessage): boolean {
    const value = text.trim();
    if (value.length === 0) {
      return false;
    }
    if (this.isCloseMicPhrase(value)) {
      this.stopVoiceInput();
      this.snapshot.statusDetail = '已关闭麦克风，思考和播报继续';
      this.notify();
      return true;
    }
    if (this.isStopPhrase(value)) {
      this.interrupt(value);
      return true;
    }
    if (this.consumePendingProtocolReply(value, existingMessage)) {
      return true;
    }
    if (this.snapshot.connection !== 'online' || this.snapshot.runtimeSessionId.length === 0) {
      this.snapshot.error = this.snapshot.connection === 'online'
        ? '会话正在准备，请稍后再发送'
        : '尚未连接，请稍后再试';
      this.notify();
      return false;
    }
    if (this.discardInterruptedTurnEvents) {
      this.replacementPromptSubmitted = true;
    }
    const queued = this.snapshot.agentBusy;
    if (existingMessage !== undefined) {
      existingMessage.text = value;
      existingMessage.label = queued ? '你 · 已排队' : '你';
      existingMessage.status = queued ? 'queued' : 'submitted';
      existingMessage.transient = false;
      existingMessage.revision += 1;
      this.activeAsrMessageId = '';
    } else {
      this.appendMessage('user', queued ? '你 · 已排队' : '你', value);
    }
    this.snapshot.agentBusy = true;
    this.snapshot.statusDetail = queued ? '已排队，等待当前任务完成' : 'Agent 正在思考';
    this.notify();
    this.gateway.submitPrompt(value, queued).then((result: Object) => {
      // Prompt accepted; agent events drive the UI from here.
    }).catch((error: BusinessError) => {
      if (this.discardInterruptedTurnEvents) {
        this.replacementPromptSubmitted = false;
      }
      const errorText = this.errorMessage(error, '提交请求失败');
      this.snapshot.agentBusy = false;
      this.snapshot.error = errorText;
      if (!queued) {
        this.failAssistantMessage(errorText);
      }
      this.notify();
    });
    return true;
  }

  toggleVoice(): void {
    if (this.voiceWanted) {
      this.stopVoiceInput();
      return;
    }
    const outputWasEnabled = this.voiceOutputEnabled;
    this.voiceWanted = true;
    this.snapshot.voiceEnabled = true;
    this.voiceOutputEnabled = true;
    if (!outputWasEnabled) {
      this.config.muted = false;
    }
    this.ensureConnections();
  }

  toggleSpeakerphone(): void {
    this.config.speakerphoneEnabled = this.snapshot.audioOutputRoute !== 'speaker';
    this.snapshot.speakerphoneEnabled = this.config.speakerphoneEnabled;
    this.persistConfig();
    this.notify();
    this.applySpeakerphonePreference();
  }

  private applySpeakerphonePreference(): void {
    setCommunicationSpeakerphoneEnabled(this.config.speakerphoneEnabled).catch((error: BusinessError): void => {
      this.snapshot.error = this.errorMessage(error, '音频输出切换失败');
      this.notify();
    });
  }

  private onOutputRouteChanged(route: AudioOutputRoute, headsetAvailable: boolean): void {
    const headsetConnected = headsetAvailable &&
      (!this.outputRouteInitialized || !this.snapshot.headsetOutputAvailable);
    this.outputRouteInitialized = true;
    this.snapshot.audioOutputRoute = route;
    this.snapshot.headsetOutputAvailable = headsetAvailable;
    if (headsetConnected && this.config.speakerphoneEnabled) {
      this.config.speakerphoneEnabled = false;
      this.snapshot.speakerphoneEnabled = false;
      this.persistConfig();
      this.applySpeakerphonePreference();
    }
    this.notify();
  }

  toggleMute(): void {
    this.config.muted = !this.config.muted;
    if (this.config.muted) {
      this.cancelRemoteTtsReconnect();
      this.tts.sendStop();
      this.systemSpeech?.stopSpeaking();
      this.player.stop().catch(() => undefined);
      this.clearSystemSpeechQueue();
      this.snapshot.playback = 'none';
    } else if (!this.useSystemSpeech && this.voiceOutputEnabled) {
      this.startRemoteVoiceClients();
    }
    this.notify();
  }

  newConversation(): void {
    this.pausedForUser = false;
    this.cancelAsrFinalization();
    this.resetInterruptedTurnGuard();
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.messages = [];
    this.activeAssistantMessageId = '';
    this.activeAsrMessageId = '';
    this.snapshot.storedSessionId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.conversationLoading = false;
    this.clearPendingProtocolRequests();
    if (this.snapshot.connection === 'online') {
      this.gateway.createSession(100).then((result: Object) => {
        this.onSessionCreated(result);
      }).catch(() => undefined);
    }
    this.notify();
  }

  async connect(): Promise<void> {
    if (this.snapshot.connection === 'connecting' || this.snapshot.connection === 'online') {
      return;
    }
    this.cancelGatewayReconnect();
    this.gatewayReconnectBlocked = false;
    const generation = ++this.gatewayConnectGeneration;
    await this.connectGateway(false, generation);
  }

  private async connectGateway(reconnecting: boolean, generation: number): Promise<void> {
    if (this.snapshot.connection === 'online' ||
      (!reconnecting && this.snapshot.connection === 'connecting')) {
      return;
    }
    this.voiceOutputEnabled = true;
    this.snapshot.connection = 'connecting';
    this.snapshot.statusTitle = reconnecting ? '正在恢复连接' : '正在连接';
    this.snapshot.error = '';
    this.snapshot.agentsLoading = true;
    this.snapshot.agentsError = '';
    this.notify();
    try {
      const authResult = await this.auth.acquireSessionCookie(this.config.gatewayUrl, this.config.accessToken);
      if (generation !== this.gatewayConnectGeneration || this.gatewayReconnectBlocked) {
        this.gatewayReconnectInFlight = false;
        return;
      }
      if (authResult.cookie.length === 0) {
        this.gatewayReconnectInFlight = false;
        this.snapshot.connection = 'offline';
        this.snapshot.agentsLoading = false;
        this.snapshot.error = authResult.error.length > 0
          ? authResult.error
          : '鉴权失败，请检查网关地址和访问口令';
        if (authResult.unauthorized) {
          this.gatewayReconnectBlocked = true;
        } else if (authResult.retryable) {
          this.scheduleGatewayReconnect(this.snapshot.error);
        }
        this.notify();
        return;
      }
      this.cookie = authResult.cookie;
      if (!await this.loadAgentCatalog(generation)) {
        this.gatewayReconnectInFlight = false;
        if (this.snapshot.agentsError.length > 0) {
          this.scheduleGatewayReconnect(this.snapshot.error);
          this.notify();
        }
        return;
      }
      if (generation !== this.gatewayConnectGeneration || this.gatewayReconnectBlocked) {
        this.gatewayReconnectInFlight = false;
        return;
      }
      this.openGateway();
      this.gatewayReconnectInFlight = false;
    } catch (error) {
      this.snapshot.connection = 'offline';
      this.snapshot.error = '连接失败';
      this.snapshot.agentsLoading = false;
      this.gatewayReconnectInFlight = false;
      this.scheduleGatewayReconnect(this.snapshot.error);
      this.notify();
    }
  }

  disconnect(): void {
    this.gatewayReconnectBlocked = true;
    this.gatewayConnectGeneration += 1;
    this.cancelGatewayReconnect();
    this.clearGatewayReadyTimeout();
    this.resetInterruptedTurnGuard();
    this.cancelModelSwitch('');
    this.cancelRemoteVoiceReconnects();
    this.stopVoice();
    this.gateway.close();
    this.asr.close();
    this.tts.close();
    this.snapshot.connection = 'offline';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.conversationLoading = false;
    this.clearPendingProtocolRequests();
    this.notify();
  }

  // Exact-stop phrase: only these interrupt the current agent turn.
  private isStopPhrase(text: string): boolean {
    const normalized = this.normalizeControlPhrase(text);
    for (const phrase of STOP_PHRASES) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  // Exact close-microphone phrase: stops input only, never interrupts work.
  private isCloseMicPhrase(text: string): boolean {
    const normalized = this.normalizeControlPhrase(text);
    for (const phrase of CLOSE_MIC_PHRASES) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  private normalizeControlPhrase(text: string): string {
    return text.trim().toLowerCase().replace(/[\s\p{P}\p{S}]/gu, '');
  }

  private isApprovalAllowPhrase(text: string): boolean {
    return APPROVAL_ALLOW_PHRASES.includes(this.normalizeControlPhrase(text));
  }

  private isApprovalDenyPhrase(text: string): boolean {
    return APPROVAL_DENY_PHRASES.includes(this.normalizeControlPhrase(text));
  }

  // Punctuation-only transcripts are dropped before they can reach Hermes.
  private hasSemanticContent(text: string): boolean {
    return /[\p{L}\p{N}]/u.test(String(text || ''));
  }

  private commitProtocolReply(value: string, label: string, existingMessage?: ChatMessage): void {
    if (existingMessage !== undefined) {
      existingMessage.text = value;
      existingMessage.label = label;
      existingMessage.status = 'submitted';
      existingMessage.transient = false;
      existingMessage.revision += 1;
      this.activeAsrMessageId = '';
      return;
    }
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = 'user';
    message.label = label;
    message.text = value;
    message.status = 'submitted';
    message.timestamp = Date.now();
    this.snapshot.messages.push(message);
  }

  private consumePendingProtocolReply(value: string, existingMessage?: ChatMessage): boolean {
    if (this.snapshot.approvalPending) {
      if (this.approvalResponseInFlight) {
        this.discardAsrPreview();
        this.snapshot.statusDetail = '审批回复正在提交';
        this.notify();
        return true;
      }
      const allow = this.isApprovalAllowPhrase(value);
      const deny = this.isApprovalDenyPhrase(value);
      if (allow || deny) {
        this.commitProtocolReply(value, '你 · 审批回复', existingMessage);
        this.stopProtocolPromptPlayback();
        this.respondApproval(allow);
        return true;
      }
      this.commitProtocolReply(value, '你 · 未识别为审批回复', existingMessage);
      const reminder = '审批仍在等待，请只回复“同意”或“取消”。';
      this.appendMessage('assistant', this.agentName(this.snapshot.selectedProfile), reminder);
      this.replaceProtocolPromptSpeech(reminder);
      return true;
    }
    if (this.snapshot.clarifyPending) {
      if (this.clarifyResponseInFlight) {
        this.discardAsrPreview();
        this.snapshot.statusDetail = '补充回复正在提交';
        this.notify();
        return true;
      }
      this.commitProtocolReply(value, '你 · 补充回复', existingMessage);
      this.stopProtocolPromptPlayback();
      this.respondClarify(value);
      return true;
    }
    return false;
  }

  private clearPendingProtocolRequests(): void {
    this.approvalResponseInFlight = false;
    this.clarifyResponseInFlight = false;
    this.snapshot.approvalPending = false;
    this.snapshot.approvalDescription = '';
    this.snapshot.approvalCommand = '';
    this.snapshot.clarifyPending = false;
    this.snapshot.clarifyRequestId = '';
    this.snapshot.clarifyQuestion = '';
    this.snapshot.clarifyChoices = [];
  }

  private interrupt(displayText: string, existingMessage?: ChatMessage): void {
    const shouldPlayCue = this.voiceOutputEnabled && !this.config.muted;
    this.audioCues.setRunning(false);
    if (existingMessage !== undefined) {
      existingMessage.text = displayText;
      existingMessage.label = '你 · 已停止';
      existingMessage.status = 'stopped';
      existingMessage.transient = false;
      existingMessage.revision += 1;
      this.activeAsrMessageId = '';
    } else {
      this.appendMessage('user', '你 · 已停止', displayText);
    }
    this.discardInterruptedTurnEvents = true;
    this.replacementPromptSubmitted = false;
    this.pausedForUser = false;
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.asrTranscript = '';
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.clearPendingProtocolRequests();
    this.completeInterruptedAssistantMessage();
    this.snapshot.agentBusy = false;
    this.snapshot.playback = 'none';
    if (shouldPlayCue) {
      this.audioCues.playStop();
    }
    this.snapshot.statusDetail = '已停止当前任务';
    this.notify();
    if (this.snapshot.connection !== 'online' || this.snapshot.runtimeSessionId.length === 0) {
      return;
    }
    this.gateway.interrupt().catch((error: BusinessError) => {
      this.snapshot.error = this.errorMessage(error, '停止请求失败');
      this.notify();
    });
  }

  stopCurrentTask(): void {
    this.interrupt('停止');
  }

  canReplayMessage(message: ChatMessage): boolean {
    const source = this.snapshot.messages.find((item: ChatMessage): boolean => item.id === message.id) || message;
    if (source.replaying) {
      return true;
    }
    return source.role === 'assistant' && !source.pending && !this.snapshot.agentBusy &&
      !this.snapshot.asrUtteranceActive && this.voiceOutputEnabled && !this.config.muted &&
      SpeechTextFilter.clean(source.text).length > 0;
  }

  // Replay one assistant message without creating a Hermes turn.
  replayMessage(message: ChatMessage): void {
    const source = this.snapshot.messages.find((item: ChatMessage): boolean => item.id === message.id);
    if (source === undefined) {
      return;
    }
    if (source.replaying && this.activeReplayMessageId === source.id) {
      this.stopMessageReplay();
      return;
    }
    if (!this.canReplayMessage(source)) {
      return;
    }
    const text = SpeechTextFilter.clean(source.text);
    if (text.length === 0) {
      return;
    }
    this.replayGeneration += 1;
    const replayGeneration = this.replayGeneration;
    this.clearActiveReplayState();
    const cleanup = this.stopPlaybackForReplay();
    this.activeReplayMessageId = source.id;
    source.replaying = true;
    source.revision += 1;
    this.snapshot.statusDetail = '正在重读这条消息';
    this.snapshot.error = '';
    this.snapshot.playback = 'queued';
    this.notify();
    this.startReplayAfterCleanup(text, source.id, replayGeneration, cleanup);
  }

  private stopMessageReplay(): void {
    this.replayGeneration += 1;
    const replayGeneration = this.replayGeneration;
    this.clearActiveReplayState();
    const cleanup = this.stopPlaybackForReplay();
    cleanup.then((): void => {
      if (replayGeneration === this.replayGeneration) {
        this.replayCleanupActive = false;
      }
    }).catch(() => undefined);
    this.snapshot.statusDetail = '已停止重读';
    this.notify();
  }

  private stopPlaybackForReplay(): Promise<void> {
    this.pausedForUser = false;
    this.replayCleanupActive = true;
    this.cancelRemoteTtsReconnect();
    this.clearSystemSpeechQueue(false);
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = this.voiceOutputEnabled ? 'ready' : 'stopped';
    if (this.useSystemSpeech) {
      this.systemSpeech?.stopSpeaking();
      const cleanup = Promise.resolve();
      this.replayCleanup = cleanup;
      return cleanup;
    }
    this.tts.sendStop();
    const cleanup = this.replayCleanup.then((): Promise<void> => {
      return this.player.stop().catch(() => undefined);
    }).catch((): void => undefined);
    this.replayCleanup = cleanup;
    return cleanup;
  }

  private async startReplayAfterCleanup(
    text: string,
    replayMessageId: string,
    replayGeneration: number,
    cleanup: Promise<void>
  ): Promise<void> {
    await cleanup;
    if (replayGeneration !== this.replayGeneration || this.activeReplayMessageId !== replayMessageId) {
      if (replayGeneration === this.replayGeneration) {
        this.replayCleanupActive = false;
      }
      return;
    }
    if (this.useSystemSpeech) {
      this.replayCleanupActive = false;
      this.replayAwaitingSystemStart = true;
      this.beginSystemSpeechStream();
      this.finishSystemSpeechStream(text);
      return;
    }
    this.cancelRemoteTtsReconnect();
    this.tts.close();
    this.replayCleanupActive = false;
    this.tts.setListener(new ControllerTtsListener(this));
    this.tts.connect(this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile), this.cookie);
    this.tts.sendText(text);
    this.tts.sendDone();
  }

  private clearActiveReplayState(): void {
    const replayId = this.activeReplayMessageId;
    this.activeReplayMessageId = '';
    this.replayAwaitingSystemStart = false;
    if (this.snapshot.statusDetail === '正在重读这条消息') {
      this.snapshot.statusDetail = '';
    }
    if (replayId.length === 0) {
      return;
    }
    const message = this.snapshot.messages.find((item: ChatMessage): boolean => item.id === replayId);
    if (message !== undefined && message.replaying) {
      message.replaying = false;
      message.revision += 1;
    }
  }

  private ensureConnections(): void {
    if (this.snapshot.connection === 'online') {
      this.startVoiceClients();
      return;
    }
    this.connect();
  }

  private startCapture(): void {
    if (this.capturing) {
      return;
    }
    const context = this.context;
    if (!context) {
      this.snapshot.asrState = 'stopped';
      this.snapshot.error = '无法获取麦克风权限上下文';
      this.notify();
      return;
    }
    this.capture.requestPermission(context).then((granted: boolean) => {
      if (!granted) {
        this.snapshot.error = '麦克风权限未授权';
        this.snapshot.asrState = 'stopped';
        this.notify();
        return false;
      }
      return this.capture.start((chunk: ArrayBuffer) => {
        this.asr.sendPcm(chunk);
      }, (label: string): void => {
        this.onMicrophoneRouteChanged(label);
      }).then((): boolean => true);
    }).then((started: boolean) => {
      if (!started) {
        return;
      }
      if (!this.voiceWanted) {
        this.capture.stop().catch(() => undefined);
        return;
      }
      this.capturing = true;
      this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
      this.snapshot.asrState = 'listening';
      this.startBackgroundVoiceTask();
      this.notify();
    }).catch((error: BusinessError) => {
      this.snapshot.asrState = 'stopped';
      this.snapshot.microphoneRoute = '';
      this.asr.close();
      this.snapshot.error = error.message;
      this.notify();
    });
  }

  private stopVoiceInput(): void {
    this.voiceWanted = false;
    this.cancelRemoteAsrReconnect();
    this.cancelAsrFinalization();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStartupPhase = '';
    this.stopBackgroundVoiceTask();
    this.snapshot.voiceEnabled = false;
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.microphoneRoute = '';
    this.discardAsrPreview();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.clearSystemRecognitionReadyTimeout();
    this.systemRecognitionStarting = false;
    this.systemSpeech?.stopRecognition(false).catch(() => undefined);
    this.asr.stop();
    this.asr.close();
    this.capture.stop().then(() => {
      this.capturing = false;
      this.notify();
    }).catch(() => undefined);
    if (this.pausedForUser) {
      this.pausedForUser = false;
      if (this.voiceOutputEnabled && !this.config.muted) {
        this.resumePausedPlayback();
      }
    }
  }

  private stopVoice(): void {
    this.voiceOutputEnabled = false;
    this.cancelRemoteTtsReconnect();
    this.stopVoiceInput();
    this.audioCues.silence();
    this.pausedForUser = false;
    this.snapshot.ttsState = 'stopped';
    this.clearSystemSpeechQueue();
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
  }

  private startBackgroundVoiceTask(): void {
    if (!this.voiceWanted || this.backgroundTaskRunning) {
      return;
    }
    if (this.backgroundTaskStarting) {
      this.stopBackgroundTaskAfterStart = false;
      return;
    }
    if (this.backgroundTaskStopping) {
      return;
    }
    this.backgroundTaskStarting = true;
    this.stopBackgroundTaskAfterStart = false;
    this.beginBackgroundVoiceTask();
  }

  private async beginBackgroundVoiceTask(): Promise<void> {
    const context = this.context;
    if (!context) {
      this.backgroundTaskStarting = false;
      return;
    }
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'cc.daiworld.voice.singleagent',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      if (!this.voiceWanted) {
        this.backgroundTaskStarting = false;
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
        agent
      );
      this.backgroundTaskStarting = false;
      this.backgroundTaskRunning = true;
      if (!this.voiceWanted || this.stopBackgroundTaskAfterStart) {
        this.stopBackgroundVoiceTask();
      }
    } catch (error) {
      this.backgroundTaskStarting = false;
      this.backgroundTaskRunning = false;
      this.stopBackgroundTaskAfterStart = false;
      if (this.voiceWanted) {
        this.snapshot.error = this.errorMessage(error as BusinessError, '后台语音保持启动失败');
        this.notify();
      }
    }
  }

  private stopBackgroundVoiceTask(): void {
    if (this.backgroundTaskStarting) {
      this.stopBackgroundTaskAfterStart = true;
      return;
    }
    if (!this.backgroundTaskRunning || this.backgroundTaskStopping) {
      return;
    }
    const context = this.context;
    this.backgroundTaskRunning = false;
    this.backgroundTaskStopping = true;
    this.stopBackgroundTaskAfterStart = false;
    if (!context) {
      this.backgroundTaskStopping = false;
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(context).then((): void => {
      this.backgroundTaskStopping = false;
      if (this.voiceWanted) {
        this.startBackgroundVoiceTask();
      }
    }).catch((error: BusinessError): void => {
      this.backgroundTaskStopping = false;
      if (this.voiceWanted) {
        this.snapshot.error = this.errorMessage(error, '后台语音保持恢复失败');
        this.notify();
        this.startBackgroundVoiceTask();
      }
    });
  }

  private openGateway(): void {
    const url = this.wsUrl('/api/hermes/ws', this.snapshot.selectedProfile);
    this.gateway.setListener(new ControllerGatewayListener(this));
    this.gateway.connect(url, this.cookie);
    this.clearGatewayReadyTimeout();
    this.gatewayReadyTimeout = setTimeout((): void => {
      this.gatewayReadyTimeout = undefined;
      if (this.snapshot.connection !== 'connecting') {
        return;
      }
      this.gateway.close();
      this.snapshot.connection = 'offline';
      this.scheduleGatewayReconnect('网关连接超时');
      this.notify();
    }, GATEWAY_READY_TIMEOUT_MS);
  }

  private async loadAgentCatalog(generation: number): Promise<boolean> {
    try {
      const agents = await this.agentCatalogClient.fetch(this.config.gatewayUrl, this.config.accessToken);
      if (generation !== this.gatewayConnectGeneration || this.gatewayReconnectBlocked) {
        return false;
      }
      this.agentCatalog.agents = agents;
      this.snapshot.agents = agents.slice();
      this.snapshot.agentsLoading = false;
      this.snapshot.agentsError = '';
      const selected = this.agentCatalog.find(this.config.profile);
      const fallback = this.agentCatalog.fallback();
      if (selected === undefined && fallback !== undefined) {
        this.config.profile = fallback.id;
        this.snapshot.selectedProfile = fallback.id;
        this.persistConfig();
      }
      if (fallback === undefined) {
        this.snapshot.connection = 'offline';
        this.snapshot.error = '服务器暂未配置可用 Agent';
        this.snapshot.statusTitle = '无可用 Agent';
        this.snapshot.statusDetail = '';
        this.notify();
        return false;
      }
      this.snapshot.error = '';
      this.notify();
      return true;
    } catch (error) {
      if (generation !== this.gatewayConnectGeneration || this.gatewayReconnectBlocked) {
        return false;
      }
      this.snapshot.agentsLoading = false;
      this.snapshot.agentsError = 'Agent目录加载失败';
      this.snapshot.connection = 'offline';
      this.snapshot.error = this.errorMessage(error as BusinessError, 'Agent目录加载失败');
      this.notify();
      return false;
    }
  }

  onGatewayReady(): void {
    this.clearGatewayReadyTimeout();
    this.gatewayReconnectInFlight = false;
    this.gatewayReconnectAttempt = 0;
    this.gatewayReconnectBlocked = false;
    this.snapshot.connection = 'online';
    this.snapshot.error = '';
    if (this.snapshot.storedSessionId.length > 0) {
      this.restoreSessionAfterReconnect(this.snapshot.storedSessionId);
      return;
    }
    this.gateway.createSession(100).then((result: Object) => {
      this.onSessionCreated(result);
    }).catch(() => undefined);
  }

  onGatewayEvent(type: string, sessionId: string, payload: Object | undefined): void {
    this.handleEvent(type, sessionId, payload);
  }

  onGatewayError(message: string): void {
    this.clearGatewayReadyTimeout();
    const errorText = typeof message === 'string' && message.length > 0
      ? message
      : '网关连接失败';
    hilog.error(CONTROLLER_LOG_DOMAIN, CONTROLLER_LOG_TAG, 'gateway error: %{public}s', errorText);
    this.snapshot.connection = 'offline';
    this.snapshot.agentBusy = false;
    this.snapshot.conversationLoading = false;
    this.snapshot.error = errorText;
    this.cancelModelSwitch('模型切换未确认：' + errorText);
    this.failAssistantMessage(errorText);
    this.scheduleGatewayReconnect(errorText);
    this.notify();
  }

  onGatewayClosed(): void {
    this.clearGatewayReadyTimeout();
    const wasOnline = this.snapshot.connection === 'online';
    hilog.warn(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'gateway closed wasOnline=%{public}s',
      wasOnline ? 'true' : 'false'
    );
    this.snapshot.connection = 'offline';
    this.snapshot.agentBusy = false;
    this.snapshot.conversationLoading = false;
    if (wasOnline) {
      this.snapshot.error = '网关连接已断开';
      this.cancelModelSwitch('模型切换未确认：网关连接已断开');
      this.failAssistantMessage(this.snapshot.error);
    }
    this.scheduleGatewayReconnect('网关连接已断开');
    this.notify();
  }

  private scheduleGatewayReconnect(reason: string): void {
    if (this.gatewayReconnectBlocked || this.config.accessToken.length === 0 ||
      this.gatewayReconnectTimer !== undefined || this.gatewayReconnectInFlight ||
      this.snapshot.connection === 'online') {
      return;
    }
    if (this.gatewayReconnectAttempt >= GATEWAY_RECONNECT_MAX_ATTEMPTS) {
      this.gatewayReconnectBlocked = true;
      this.snapshot.connection = 'offline';
      this.snapshot.statusTitle = '连接已停止恢复';
      this.snapshot.statusDetail = '请检查网络或重新保存访问口令';
      this.snapshot.error = reason;
      return;
    }
    const index = Math.min(this.gatewayReconnectAttempt, GATEWAY_RECONNECT_DELAYS_MS.length - 1);
    const delay = GATEWAY_RECONNECT_DELAYS_MS[index];
    this.gatewayReconnectAttempt += 1;
    this.snapshot.connection = 'connecting';
    this.snapshot.statusTitle = '正在恢复连接';
    this.snapshot.statusDetail = '将在 ' + String(delay) + ' ms 后重试';
    this.snapshot.error = '';
    this.gatewayReconnectTimer = setTimeout((): void => {
      this.gatewayReconnectTimer = undefined;
      if (this.gatewayReconnectBlocked || this.snapshot.connection === 'online') {
        return;
      }
      this.gatewayReconnectInFlight = true;
      const generation = ++this.gatewayConnectGeneration;
      this.connectGateway(true, generation).then((): void => {
        this.gatewayReconnectInFlight = false;
      }).catch((): void => {
        this.gatewayReconnectInFlight = false;
      });
    }, delay);
  }

  private cancelGatewayReconnect(): void {
    if (this.gatewayReconnectTimer !== undefined) {
      clearTimeout(this.gatewayReconnectTimer);
      this.gatewayReconnectTimer = undefined;
    }
    this.gatewayReconnectAttempt = 0;
    this.gatewayReconnectInFlight = false;
  }

  private clearGatewayReadyTimeout(): void {
    if (this.gatewayReadyTimeout !== undefined) {
      clearTimeout(this.gatewayReadyTimeout);
      this.gatewayReadyTimeout = undefined;
    }
  }

  private onSessionCreated(result: Object): void {
    this.resetInterruptedTurnGuard();
    const record = result as Record<string, Object>;
    const runtime = record['session_id'];
    const stored = record['stored_session_id'] !== undefined
      ? record['stored_session_id'] : record['session_key'];
    const info = record['info'] as Record<string, Object> | undefined;
    if (typeof runtime === 'string' && runtime.length > 0) {
      this.snapshot.runtimeSessionId = runtime;
    }
    if (typeof stored === 'string' && stored.length > 0) {
      this.snapshot.storedSessionId = stored;
    }
    if (info !== undefined) {
      if (info['model'] !== undefined) {
        this.snapshot.runtimeModel = String(info['model']);
      }
      this.snapshot.runtimeProvider = this.providerDisplay(info);
    }
    this.snapshot.conversationLoading = false;
    this.snapshot.modelSwitchStatus = '';
    this.snapshot.modelSwitchError = '';
    this.snapshot.statusTitle = '已连接';
    this.snapshot.statusDetail = this.snapshot.selectedProfile;
    this.snapshot.error = '';
    this.notify();
    this.listHistory();
    if (this.voiceOutputEnabled) {
      this.startVoiceClients();
    }
  }

  private startVoiceClients(): void {
    const capabilities: SystemSpeechCapabilities | undefined = this.systemSpeech?.getCapabilities();
    if (this.config.speechBackend === 'harmony_offline') {
      this.cancelRemoteVoiceReconnects();
      this.useSystemSpeech = true;
      this.snapshot.asrBackend = 'harmony_offline';
      this.snapshot.ttsBackend = 'harmony_offline';
      this.asr.close();
      this.tts.close();
      if (!capabilities || !capabilities.tts) {
        this.snapshot.ttsState = 'error';
        this.snapshot.error = '设备不支持鸿蒙本地语音合成';
      } else if (this.snapshot.playback === 'none' && this.snapshot.ttsState !== 'speaking') {
        this.snapshot.ttsState = 'ready';
      }
      if (this.voiceWanted) {
        if (capabilities && capabilities.stt) {
          this.startSystemRecognition();
        } else {
          this.failSystemRecognition('设备不支持鸿蒙本地语音识别', '检查本地识别能力');
        }
      }
      return;
    }
    this.useSystemSpeech = false;
    this.snapshot.asrBackend = 'remote';
    this.snapshot.ttsBackend = 'remote';
    this.startRemoteVoiceClients();
  }

  private async restartVoiceClients(): Promise<void> {
    if (!this.voiceWanted && !this.voiceOutputEnabled) {
      return;
    }
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.clearSystemRecognitionReadyTimeout();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStartupPhase = '';
    this.systemRecognitionStarting = false;
    this.cancelRemoteVoiceReconnects();
    this.cancelAsrFinalization();
    this.discardAsrPreview();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    if (this.systemSpeech) {
      await this.systemSpeech.stopRecognition(false).catch(() => undefined);
    }
    this.asr.close();
    this.tts.close();
    await this.capture.stop().catch(() => undefined);
    this.capturing = false;
    this.snapshot.asrState = 'stopped';
    this.snapshot.ttsState = 'stopped';
    if (this.voiceOutputEnabled && this.snapshot.connection === 'online') {
      this.startVoiceClients();
    }
  }

  private startRemoteVoiceClients(): void {
    if (!this.voiceOutputEnabled) {
      return;
    }
    if (this.voiceWanted) {
      this.snapshot.asrState = 'connecting';
    } else {
      this.snapshot.asrState = 'stopped';
    }
    if (!this.tts.isConnected()) {
      this.snapshot.ttsState = 'connecting';
    }
    this.snapshot.error = '';
    this.notify();
    this.tts.setListener(new ControllerTtsListener(this));
    if (!this.tts.isConnected() && !this.tts.isConnecting()) {
      this.tts.connect(this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile), this.cookie);
    }
    if (!this.voiceWanted) {
      return;
    }
    this.asr.setListener(new ControllerAsrListener(this));
    if (!this.asr.isConnected() && !this.asr.isConnecting()) {
      this.asr.connect(this.wsUrl('/api/audio/transcribe-stream', this.snapshot.selectedProfile), this.cookie);
    }
    this.startCapture();
  }

  private startSystemRecognition(): void {
    if (!this.voiceWanted || !this.useSystemSpeech || this.systemRecognitionStarting ||
      this.snapshot.asrState === 'listening') {
      return;
    }
    const speech = this.systemSpeech;
    if (!speech) {
      this.failSystemRecognition('系统语音服务未初始化', '初始化系统语音服务');
      return;
    }
    const attempt = this.systemRecognitionAttempt + 1;
    this.systemRecognitionAttempt = attempt;
    this.systemRecognitionStarting = true;
    this.systemRecognitionStartupPhase = '准备本地识别';
    this.snapshot.asrState = 'connecting';
    this.snapshot.microphoneRoute = '';
    this.snapshot.statusDetail = '本地 ASR：准备本地识别';
    this.snapshot.error = '';
    this.clearSystemRecognitionReadyTimeout();
    this.systemRecognitionReadyTimeout = setTimeout((): void => {
      this.systemRecognitionReadyTimeout = undefined;
      if (attempt === this.systemRecognitionAttempt && this.voiceWanted && this.useSystemSpeech &&
        this.snapshot.asrState === 'connecting') {
        const phase = this.systemRecognitionStartupPhase.length > 0
          ? this.systemRecognitionStartupPhase : '未知启动阶段';
        this.failSystemRecognition('本地 ASR 启动超时，停在：' + phase, phase);
      }
    }, SYSTEM_ASR_STARTUP_TIMEOUT_MS);
    this.notify();
    speech.startRecognition().then(() => {
      if (attempt !== this.systemRecognitionAttempt) {
        return;
      }
      this.systemRecognitionStarting = false;
      if (!this.voiceWanted || !this.useSystemSpeech) {
        return;
      }
      this.snapshot.microphoneRoute = speech.getInputRouteLabel();
      this.notify();
    }).catch((error: BusinessError) => {
      if (attempt !== this.systemRecognitionAttempt) {
        return;
      }
      this.systemRecognitionStarting = false;
      this.failSystemRecognition(this.errorMessage(error, '离线 STT 启动失败'), this.systemRecognitionStartupPhase);
    });
  }

  private failSystemRecognition(reason: string, phase: string): void {
    this.finalizeAsrAfterTermination();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStarting = false;
    this.clearSystemRecognitionReadyTimeout();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.voiceWanted = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.microphoneRoute = '';
    this.discardAsrPreview();
    this.stopBackgroundVoiceTask();
    this.snapshot.statusDetail = phase.length > 0 ? '本地 ASR 已停止：' + phase : '本地 ASR 已停止';
    this.snapshot.error = reason;
    this.notify();
    this.systemSpeech?.resetRecognition().catch(() => undefined);
  }

  private onSystemRecognitionStartupPhase(phase: string): void {
    if (!this.useSystemSpeech || !this.voiceWanted || this.snapshot.asrState !== 'connecting') {
      return;
    }
    this.systemRecognitionStartupPhase = phase;
    this.snapshot.statusDetail = '本地 ASR：' + phase;
    if (phase === '启动识别会话' || phase === '等待识别引擎 ready') {
      this.snapshot.microphoneRoute = this.systemSpeech?.getInputRouteLabel() ?? '';
    }
    this.notify();
  }

  private onMicrophoneRouteChanged(label: string): void {
    if (!this.voiceWanted || label.length === 0 || this.snapshot.microphoneRoute === label) {
      return;
    }
    this.snapshot.microphoneRoute = label;
    this.notify();
  }

  onSystemRecognitionState(active: boolean): void {
    if (!this.useSystemSpeech) {
      return;
    }
    if (active && !this.voiceWanted) {
      this.systemSpeech?.stopRecognition(false).catch(() => undefined);
      return;
    }
    this.snapshot.asrState = active ? 'listening' : 'stopped';
    if (active) {
      this.clearSystemRecognitionReadyTimeout();
      this.systemRecognitionStarting = false;
      this.systemRecognitionStartupPhase = '';
      this.snapshot.microphoneRoute = this.systemSpeech?.getInputRouteLabel() ?? '';
      this.snapshot.statusDetail = '本地 ASR 监听中';
      this.startBackgroundVoiceTask();
    }
    if (!active && this.snapshot.asrUtteranceActive) {
      this.queueAsrFinal('', false);
    }
    this.notify();
    if (!active && this.voiceWanted && !this.systemRecognitionStarting) {
      this.scheduleSystemRecognitionRestart('');
    }
  }

  private scheduleSystemRecognitionRestart(reason: string): void {
    if (!this.voiceWanted || !this.useSystemSpeech) {
      return;
    }
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
    }
    if (reason.length > 0) {
      this.snapshot.statusDetail = '本地识别正在恢复';
      this.notify();
    }
    this.systemRecognitionRestart = setTimeout((): void => {
      this.systemRecognitionRestart = undefined;
      this.startSystemRecognition();
    }, 150);
  }

  onSystemRecognitionResult(text: string, isFinal: boolean, isLast: boolean): void {
    if (!this.useSystemSpeech) {
      return;
    }
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected();
    }
    if (isFinal) {
      this.queueAsrFinal(value, isLast);
    } else {
      this.updateAsrInterim(value);
    }
  }

  onSystemSpeechState(active: boolean): void {
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'system TTS state active=%{public}s output=%{public}s paused=%{public}s queue=%{public}d',
      String(active),
      String(this.voiceOutputEnabled),
      String(this.pausedForUser),
      this.systemSpeechQueue.length
    );
    if (!this.useSystemSpeech) {
      return;
    }
    if (this.replayCleanupActive) {
      return;
    }
    if (!this.voiceOutputEnabled) {
      this.snapshot.ttsState = 'stopped';
      this.snapshot.playback = 'none';
      this.clearActiveReplayState();
      return;
    }
    if (!active && this.activeReplayMessageId.length > 0 && this.replayAwaitingSystemStart) {
      this.snapshot.ttsState = 'connecting';
      this.snapshot.playback = 'queued';
      this.notify();
      return;
    }
    if (active && this.pausedForUser) {
      this.systemSpeech?.stopSpeaking();
      this.snapshot.ttsState = 'ready';
      this.snapshot.playback = 'paused_for_user';
      this.notify();
      return;
    }
    if (active) {
      this.replayAwaitingSystemStart = false;
      this.systemSpeechStartedAt = Date.now();
      this.snapshot.ttsState = 'speaking';
      this.snapshot.playback = 'playing';
      this.notify();
      return;
    }
    this.snapshot.ttsState = 'ready';
    if (this.pausedForUser) {
      this.snapshot.playback = 'paused_for_user';
      this.notify();
      return;
    }
    this.activeSystemSpeechText = '';
    this.systemSpeechStartedAt = 0;
    if (this.systemSpeechQueue.length > 0) {
      const next = this.systemSpeechQueue.shift();
      if (next !== undefined) {
        this.startSystemSpeech(next);
      }
    } else {
      this.snapshot.playback = 'none';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
        this.snapshot.statusDetail = '';
      }
      this.notify();
    }
    if (!active && this.voiceWanted) {
      this.startSystemRecognition();
    }
  }

  onSystemSpeechError(channel: string, message: string): void {
    if (!this.useSystemSpeech) {
      return;
    }
    if (this.replayCleanupActive) {
      return;
    }
    if (channel === 'STT') {
      this.failSystemRecognition('STT：' + message, this.systemRecognitionStartupPhase);
      return;
    }
    this.activeSystemSpeechText = '';
    this.clearSystemSpeechQueue();
    this.snapshot.ttsState = 'error';
    this.snapshot.playback = 'none';
    this.snapshot.statusDetail = '本地 TTS 已停止';
    this.snapshot.error = channel + '：' + message;
    this.notify();
  }

  private speakWithSystem(text: string): void {
    const value = text.trim();
    if (value.length === 0 || !this.systemSpeech) {
      return;
    }
    if (this.activeSystemSpeechText.length > 0 || this.pausedForUser ||
      this.snapshot.playback === 'queued' || this.snapshot.playback === 'playing') {
      this.systemSpeechQueue.push(value);
      hilog.info(
        CONTROLLER_LOG_DOMAIN,
        CONTROLLER_LOG_TAG,
        'system TTS chunk queued length=%{public}d queue=%{public}d',
        value.length,
        this.systemSpeechQueue.length
      );
      return;
    }
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'system TTS chunk ready length=%{public}d',
      value.length
    );
    this.startSystemSpeech(value);
  }

  private speakProtocolPrompt(text: string): void {
    const value = SpeechTextFilter.clean(text).trim();
    if (value.length === 0 || !this.voiceOutputEnabled || this.config.muted) {
      return;
    }
    if (this.useSystemSpeech) {
      this.speakWithSystem(value);
      return;
    }
    if (!this.tts.isConnected() && !this.tts.isConnecting()) {
      this.tts.reconnect(this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile), this.cookie);
    }
    this.tts.sendText(value);
    this.tts.sendDone();
  }

  private stopProtocolPromptPlayback(): void {
    this.pausedForUser = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = this.voiceOutputEnabled ? 'ready' : 'stopped';
  }

  private replaceProtocolPromptSpeech(text: string): void {
    this.stopProtocolPromptPlayback();
    this.speakProtocolPrompt(text);
  }

  private beginSystemSpeechStream(): void {
    this.systemSpeechPendingText = '';
    this.systemSpeechReceivedText = '';
    this.systemSpeechFirstChunkQueued = false;
    this.speechTextFilter = new SpeechTextFilter();
  }

  private appendSystemSpeechStream(text: string): void {
    if (text.length === 0) {
      return;
    }
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'system TTS delta received length=%{public}d pending=%{public}d',
      text.length,
      this.systemSpeechPendingText.length
    );
    this.systemSpeechPendingText += text;
    this.systemSpeechReceivedText += text;
    this.flushSystemSpeechStream(false);
  }

  private finishSystemSpeechStream(finalText: string): void {
    const finalValue = finalText;
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'system TTS final received length=%{public}d streamed=%{public}d',
      finalValue.length,
      this.systemSpeechReceivedText.length
    );
    if (this.systemSpeechReceivedText.length === 0) {
      this.systemSpeechPendingText += finalValue;
    } else if (finalValue.startsWith(this.systemSpeechReceivedText) &&
      finalValue.length > this.systemSpeechReceivedText.length) {
      this.systemSpeechPendingText += finalValue.substring(this.systemSpeechReceivedText.length);
    }
    this.flushSystemSpeechStream(true);
  }

  private flushSystemSpeechStream(final: boolean): void {
    while (this.systemSpeechPendingText.trim().length > 0) {
      const end = this.systemSpeechChunkEnd(this.systemSpeechPendingText, final);
      if (end <= 0) {
        return;
      }
      const chunk = this.systemSpeechPendingText.substring(0, end).trim();
      this.systemSpeechPendingText = this.trimSystemSpeechLeading(
        this.systemSpeechPendingText.substring(end)
      );
      if (chunk.length > 0) {
        this.systemSpeechFirstChunkQueued = true;
        this.speakWithSystem(chunk);
      }
    }
  }

  private trimSystemSpeechLeading(text: string): string {
    const whitespace = ' \t\r\n';
    let index = 0;
    while (index < text.length && whitespace.includes(text[index])) {
      index += 1;
    }
    return text.substring(index);
  }

  private systemSpeechChunkEnd(text: string, final: boolean): number {
    const length = text.length;
    if (length === 0) {
      return 0;
    }
    if (final && length <= SYSTEM_TTS_HARD_MAX) {
      return length;
    }
    if (!this.systemSpeechFirstChunkQueued) {
      if (length < SYSTEM_TTS_FIRST_MIN) {
        return final ? length : 0;
      }
      const hardEnd = this.firstBoundaryEnd(
        text,
        SYSTEM_TTS_HARD_BOUNDARIES,
        SYSTEM_TTS_FIRST_MIN - 1,
        Math.min(length, SYSTEM_TTS_FIRST_MAX)
      );
      if (hardEnd > 0) {
        return hardEnd;
      }
      if (length >= SYSTEM_TTS_FIRST_TARGET) {
        const softEnd = this.lastBoundaryEnd(
          text,
          SYSTEM_TTS_SOFT_BOUNDARIES,
          SYSTEM_TTS_FIRST_MIN - 1,
          Math.min(length, SYSTEM_TTS_FIRST_TARGET)
        );
        if (softEnd > 0) {
          return softEnd;
        }
      }
      return length >= SYSTEM_TTS_FIRST_MAX ? SYSTEM_TTS_FIRST_MAX : 0;
    }
    if (length < SYSTEM_TTS_NEXT_MIN) {
      return final ? length : 0;
    }
    const preferredHardEnd = this.firstBoundaryEnd(
      text,
      SYSTEM_TTS_HARD_BOUNDARIES,
      SYSTEM_TTS_NEXT_MIN - 1,
      Math.min(length, SYSTEM_TTS_NEXT_PREFERRED_MAX)
    );
    if (preferredHardEnd > 0) {
      return preferredHardEnd;
    }
    if (length >= SYSTEM_TTS_NEXT_TARGET) {
      const targetEnd = this.lastBoundaryEnd(
        text,
        SYSTEM_TTS_HARD_BOUNDARIES + SYSTEM_TTS_SOFT_BOUNDARIES,
        SYSTEM_TTS_NEXT_MIN - 1,
        Math.min(length, SYSTEM_TTS_NEXT_TARGET)
      );
      if (targetEnd > 0) {
        return targetEnd;
      }
    }
    if (length > SYSTEM_TTS_NEXT_PREFERRED_MAX) {
      const laterEnd = this.firstBoundaryEnd(
        text,
        SYSTEM_TTS_HARD_BOUNDARIES + SYSTEM_TTS_SOFT_BOUNDARIES,
        SYSTEM_TTS_NEXT_PREFERRED_MAX - 1,
        Math.min(length, SYSTEM_TTS_HARD_MAX)
      );
      if (laterEnd > 0) {
        return laterEnd;
      }
    }
    if (length >= SYSTEM_TTS_HARD_MAX) {
      const safeEnd = this.lastBoundaryEnd(
        text,
        SYSTEM_TTS_HARD_BOUNDARIES + SYSTEM_TTS_SOFT_BOUNDARIES,
        SYSTEM_TTS_NEXT_MIN - 1,
        SYSTEM_TTS_HARD_MAX
      );
      return safeEnd > 0 ? safeEnd : SYSTEM_TTS_HARD_MAX;
    }
    return 0;
  }

  private firstBoundaryEnd(text: string, boundaries: string, start: number, end: number): number {
    for (let index = Math.max(0, start); index < Math.min(text.length, end); index += 1) {
      if (boundaries.includes(text[index])) {
        return index + 1;
      }
    }
    return 0;
  }

  private lastBoundaryEnd(text: string, boundaries: string, start: number, end: number): number {
    for (let index = Math.min(text.length, end) - 1; index >= Math.max(0, start); index -= 1) {
      if (boundaries.includes(text[index])) {
        return index + 1;
      }
    }
    return 0;
  }

  private startSystemSpeech(text: string): void {
    const speech = this.systemSpeech;
    if (!speech || text.length === 0) {
      return;
    }
    this.activeSystemSpeechText = text;
    this.systemSpeechStartedAt = 0;
    this.snapshot.playback = 'queued';
    this.snapshot.ttsState = 'connecting';
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'system TTS start length=%{public}d person=%{public}d rate=%{public}s',
      text.length,
      this.config.voicePerson,
      String(this.config.speechRate)
    );
    this.notify();
    speech.speak(text, this.config.voicePerson, this.config.speechRate).catch((error: BusinessError) => {
      this.activeSystemSpeechText = '';
      this.clearSystemSpeechQueue();
      this.snapshot.ttsState = 'error';
      this.snapshot.playback = 'none';
      this.snapshot.statusDetail = '本地 TTS 启动失败';
      this.snapshot.error = this.errorMessage(error, '离线 TTS 启动失败');
      this.notify();
    });
  }

  onAsrReady(): void {
    this.cancelRemoteAsrReconnect();
    this.snapshot.asrState = 'listening';
    this.snapshot.error = '';
    this.notify();
  }

  onAsrTranscript(text: string, interim: boolean, final: boolean): void {
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected();
    }
    if (final) {
      this.queueAsrFinal(value, false);
    } else if (interim) {
      this.updateAsrInterim(value);
    }
  }

  onAsrError(message: string): void {
    this.handleRemoteAsrDisconnect(
      typeof message === 'string' && message.length > 0 ? message : 'ASR 连接失败'
    );
  }

  onAsrClosed(): void {
    this.handleRemoteAsrDisconnect('ASR 连接已断开');
  }

  onTtsJobStarted(sampleRate: number): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.player.setSampleRate(sampleRate);
    this.snapshot.ttsSampleRate = sampleRate;
    this.snapshot.ttsState = 'speaking';
    if (this.pausedForUser) {
      this.player.pause().catch(() => undefined);
      this.snapshot.playback = 'paused_for_user';
    } else {
      this.snapshot.playback = 'playing';
    }
    this.notify();
  }

  onTtsReady(): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.cancelRemoteTtsReconnect();
    this.snapshot.ttsState = 'ready';
    this.snapshot.error = '';
    this.notify();
  }

  onTtsJobPcm(pcm: ArrayBuffer): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.player.enqueue(pcm);
  }

  onTtsJobEnded(): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.player.waitForDrain((): void => {
      this.snapshot.playback = 'none';
      this.snapshot.ttsState = this.voiceOutputEnabled ? 'ready' : 'stopped';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
        this.snapshot.statusDetail = '';
      }
      this.notify();
    });
  }

  onTtsJobFallback(): void {
    this.snapshot.ttsState = 'fallback';
    this.snapshot.statusDetail = 'TTS已降级';
    this.notify();
  }

  onTtsError(message: string): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.handleRemoteTtsDisconnect(
      typeof message === 'string' && message.length > 0 ? message : 'TTS 连接失败'
    );
  }

  onTtsClosed(): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.handleRemoteTtsDisconnect('TTS 连接已断开');
  }

  private handleRemoteAsrDisconnect(message: string): void {
    if (!this.canRecoverRemoteAsr()) {
      this.snapshot.asrState = 'stopped';
      this.finalizeAsrAfterTermination();
      if (this.voiceWanted && !this.useSystemSpeech) {
        this.snapshot.error = message;
      }
      this.notify();
      return;
    }
    if (this.snapshot.asrUtteranceActive && this.combinedAsrText().length === 0) {
      this.discardAsrAndResumePlayback();
    }
    this.snapshot.asrState = 'connecting';
    this.snapshot.statusDetail = '远端 ASR 正在恢复';
    this.snapshot.error = '';
    this.scheduleRemoteAsrReconnect();
    this.notify();
  }

  private handleRemoteTtsDisconnect(message: string): void {
    if (!this.canRecoverRemoteTts()) {
      this.clearActiveReplayState();
      this.snapshot.ttsState = this.voiceOutputEnabled && !this.config.muted ? 'error' : 'stopped';
      if (this.voiceOutputEnabled && !this.config.muted && !this.useSystemSpeech) {
        this.snapshot.error = message;
      }
      this.notify();
      return;
    }
    this.snapshot.ttsState = 'connecting';
    this.snapshot.statusDetail = '远端 TTS 正在恢复';
    this.snapshot.error = '';
    this.drainRemotePlaybackAfterDisconnect();
    this.scheduleRemoteTtsReconnect();
    this.notify();
  }

  private canRecoverRemoteAsr(): boolean {
    return !this.useSystemSpeech && this.config.speechBackend === 'remote' && this.voiceWanted &&
      this.snapshot.connection === 'online' && this.cookie.length > 0;
  }

  private canRecoverRemoteTts(): boolean {
    return !this.useSystemSpeech && this.config.speechBackend === 'remote' &&
      this.voiceOutputEnabled && !this.config.muted && this.snapshot.connection === 'online' &&
      this.cookie.length > 0;
  }

  private scheduleRemoteAsrReconnect(): void {
    if (!this.canRecoverRemoteAsr() || this.asr.isConnected() || this.asr.isConnecting() ||
      this.remoteAsrReconnectTimer !== undefined) {
      return;
    }
    const index = Math.min(
      this.remoteAsrReconnectAttempt,
      REMOTE_VOICE_RECONNECT_DELAYS_MS.length - 1
    );
    const delay = REMOTE_VOICE_RECONNECT_DELAYS_MS[index];
    this.remoteAsrReconnectAttempt = Math.min(
      this.remoteAsrReconnectAttempt + 1,
      REMOTE_VOICE_RECONNECT_DELAYS_MS.length
    );
    this.remoteAsrReconnectTimer = setTimeout((): void => {
      this.remoteAsrReconnectTimer = undefined;
      if (!this.canRecoverRemoteAsr() || this.asr.isConnected() || this.asr.isConnecting()) {
        return;
      }
      this.asr.setListener(new ControllerAsrListener(this));
      this.asr.reconnect(
        this.wsUrl('/api/audio/transcribe-stream', this.snapshot.selectedProfile),
        this.cookie
      );
    }, delay);
  }

  private scheduleRemoteTtsReconnect(): void {
    if (!this.canRecoverRemoteTts() || this.tts.isConnected() || this.tts.isConnecting() ||
      this.remoteTtsReconnectTimer !== undefined) {
      return;
    }
    const index = Math.min(
      this.remoteTtsReconnectAttempt,
      REMOTE_VOICE_RECONNECT_DELAYS_MS.length - 1
    );
    const delay = REMOTE_VOICE_RECONNECT_DELAYS_MS[index];
    this.remoteTtsReconnectAttempt = Math.min(
      this.remoteTtsReconnectAttempt + 1,
      REMOTE_VOICE_RECONNECT_DELAYS_MS.length
    );
    this.remoteTtsReconnectTimer = setTimeout((): void => {
      this.remoteTtsReconnectTimer = undefined;
      if (!this.canRecoverRemoteTts() || this.tts.isConnected() || this.tts.isConnecting()) {
        return;
      }
      this.tts.setListener(new ControllerTtsListener(this));
      this.tts.reconnect(
        this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile),
        this.cookie
      );
    }, delay);
  }

  private cancelRemoteAsrReconnect(): void {
    if (this.remoteAsrReconnectTimer !== undefined) {
      clearTimeout(this.remoteAsrReconnectTimer);
      this.remoteAsrReconnectTimer = undefined;
    }
    this.remoteAsrReconnectAttempt = 0;
  }

  private cancelRemoteTtsReconnect(): void {
    if (this.remoteTtsReconnectTimer !== undefined) {
      clearTimeout(this.remoteTtsReconnectTimer);
      this.remoteTtsReconnectTimer = undefined;
    }
    this.remoteTtsReconnectAttempt = 0;
  }

  private cancelRemoteVoiceReconnects(): void {
    this.cancelRemoteAsrReconnect();
    this.cancelRemoteTtsReconnect();
  }

  private drainRemotePlaybackAfterDisconnect(): void {
    if (this.remoteTtsDrainPending) {
      return;
    }
    this.remoteTtsDrainPending = true;
    this.player.waitForDrain((): void => {
      this.remoteTtsDrainPending = false;
      this.snapshot.playback = 'none';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
      }
      this.notify();
    });
  }

  private onAsrFinal(text: string): void {
    const value = this.mergeAsrSegments(this.combinedAsrText(), text.trim());
    this.cancelAsrFinalization();
    const preview = this.currentAsrMessage();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    if (this.snapshot.asrState === 'finalizing') {
      this.snapshot.asrState = this.voiceWanted ? 'listening' : 'stopped';
    }
    if (this.isCloseMicPhrase(value)) {
      this.discardAsrPreview();
      this.stopVoiceInput();
      this.snapshot.statusDetail = '已关闭麦克风，思考和播报继续';
      this.notify();
      return;
    }
    if (!this.hasSemanticContent(value)) {
      this.discardAsrAndResumePlayback();
      return;
    }
    if (this.isStopPhrase(value)) {
      this.interrupt(value, preview);
      return;
    }
    if (this.consumePendingProtocolReply(value, preview)) {
      return;
    }
    if (value.length > 0) {
      const accepted = this.submitText(value, preview);
      if (accepted && this.voiceOutputEnabled && !this.config.muted) {
        this.audioCues.playAccepted();
      }
    }
    if (this.pausedForUser) {
      this.resumePausedPlayback();
      return;
    }
    this.discardAsrPreview();
    this.notify();
  }

  private updateAsrInterim(text: string): void {
    this.asrLatestInterimText = text.trim();
    const value = this.combinedAsrText();
    if (value.length === 0) {
      return;
    }
    this.snapshot.asrTranscript = value;
    if (this.voiceWanted) {
      this.snapshot.asrState = 'listening';
    }
    const preview = this.ensureAsrPreview();
    preview.label = '你 · 正在识别';
    preview.text = value;
    preview.revision += 1;
    this.scheduleAsrFinalization();
    this.notify();
  }

  private queueAsrFinal(text: string, isLast: boolean): void {
    const value = text.trim();
    if (value.length > 0) {
      this.asrPendingFinalText = this.mergeAsrSegments(this.asrPendingFinalText, value);
    } else if (this.asrPendingFinalText.length === 0 && this.asrLatestInterimText.length > 0) {
      this.asrPendingFinalText = this.asrLatestInterimText;
    }
    this.asrLatestInterimText = '';
    const combined = this.combinedAsrText();
    if (combined.length === 0) {
      this.discardAsrAndResumePlayback();
      return;
    }
    if (this.shouldFinalizeAsrImmediately(combined)) {
      this.onAsrFinal(combined);
      return;
    }
    this.snapshot.asrTranscript = combined;
    this.snapshot.asrUtteranceActive = true;
    this.snapshot.asrState = 'finalizing';
    const preview = this.ensureAsrPreview();
    preview.label = '你 · 等待收句';
    preview.text = combined;
    preview.revision += 1;
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'ASR final buffered length=%{public}d isLast=%{public}s graceMs=%{public}d',
      combined.length,
      String(isLast),
      ASR_FINALIZATION_GRACE_MS
    );
    this.scheduleAsrFinalization();
    this.notify();
  }

  private scheduleAsrFinalization(): void {
    if (this.asrFinalizationTimer !== undefined) {
      clearTimeout(this.asrFinalizationTimer);
    }
    this.asrFinalizationTimer = setTimeout((): void => {
      this.asrFinalizationTimer = undefined;
      const value = this.combinedAsrText();
      this.onAsrFinal(value);
    }, ASR_FINALIZATION_GRACE_MS);
  }

  private finalizeAsrAfterTermination(): void {
    if (!this.snapshot.asrUtteranceActive && this.combinedAsrText().length === 0) {
      return;
    }
    const preview = this.currentAsrMessage();
    const previewText = preview !== undefined ? preview.text.trim() : '';
    const value = this.mergeAsrSegments(this.combinedAsrText(), previewText);
    if (this.hasSemanticContent(value)) {
      this.onAsrFinal(value);
      return;
    }
    this.discardAsrAndResumePlayback();
  }

  private shouldFinalizeAsrImmediately(text: string): boolean {
    if (this.isStopPhrase(text) || this.isCloseMicPhrase(text) || this.snapshot.clarifyPending) {
      return true;
    }
    return this.snapshot.approvalPending &&
      (this.isApprovalAllowPhrase(text) || this.isApprovalDenyPhrase(text));
  }

  private combinedAsrText(): string {
    return this.mergeAsrSegments(this.asrPendingFinalText, this.asrLatestInterimText);
  }

  private mergeAsrSegments(previous: string, incoming: string): string {
    const left = previous.trim();
    const right = incoming.trim();
    if (left.length === 0) {
      return right;
    }
    if (right.length === 0 || left === right) {
      return left;
    }
    if (right.startsWith(left)) {
      return right;
    }
    const separator = /[A-Za-z0-9]$/.test(left) && /^[A-Za-z0-9]/.test(right) ? ' ' : '';
    return left + separator + right;
  }

  private cancelAsrFinalization(): void {
    if (this.asrFinalizationTimer !== undefined) {
      clearTimeout(this.asrFinalizationTimer);
      this.asrFinalizationTimer = undefined;
    }
    this.asrPendingFinalText = '';
    this.asrLatestInterimText = '';
  }

  private discardAsrAndResumePlayback(): void {
    this.cancelAsrFinalization();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.discardAsrPreview();
    if (this.pausedForUser) {
      this.resumePausedPlayback();
      return;
    }
    this.notify();
  }

  private clearSystemRecognitionReadyTimeout(): void {
    if (this.systemRecognitionReadyTimeout !== undefined) {
      clearTimeout(this.systemRecognitionReadyTimeout);
      this.systemRecognitionReadyTimeout = undefined;
    }
  }

  private onUserSpeechDetected(): void {
    if (!this.voiceWanted) {
      return;
    }
    if (!this.snapshot.asrUtteranceActive) {
      this.snapshot.asrUtteranceActive = true;
      this.ensureAsrPreview();
    }
    if (this.pausedForUser ||
      (this.snapshot.playback !== 'queued' && this.snapshot.playback !== 'playing')) {
      this.notify();
      return;
    }
    this.pausedForUser = true;
    this.snapshot.playback = 'paused_for_user';
    this.snapshot.statusDetail = '检测到你说话，已暂停播报';
    if (this.useSystemSpeech) {
      this.pausedSystemSpeechText = this.remainingSystemSpeechText();
      this.systemSpeech?.stopSpeaking();
    } else {
      this.player.pause().catch(() => undefined);
    }
    this.notify();
  }

  private resumePausedPlayback(): void {
    this.pausedForUser = false;
    this.snapshot.statusDetail = '已恢复播报，新指令在后台处理';
    if (this.useSystemSpeech) {
      const remaining = this.pausedSystemSpeechText;
      this.pausedSystemSpeechText = '';
      this.activeSystemSpeechText = '';
      this.systemSpeechStartedAt = 0;
      if (remaining.length > 0) {
        this.startSystemSpeech(remaining);
      } else if (this.systemSpeechQueue.length > 0) {
        const next = this.systemSpeechQueue.shift();
        if (next !== undefined) {
          this.startSystemSpeech(next);
        }
      } else {
        this.snapshot.playback = 'none';
        this.snapshot.ttsState = this.voiceOutputEnabled ? 'ready' : 'stopped';
        this.notify();
      }
      return;
    }
    this.player.resume().catch(() => undefined);
    this.snapshot.playback = this.player.hasQueued() ? 'playing' : 'none';
    this.notify();
  }

  private remainingSystemSpeechText(): string {
    const text = this.activeSystemSpeechText;
    if (text.length === 0 || this.systemSpeechStartedAt <= 0) {
      return text;
    }
    const elapsedSeconds = Math.max(0, Date.now() - this.systemSpeechStartedAt) / 1000;
    const estimatedIndex = Math.min(
      text.length,
      Math.floor(elapsedSeconds * 4.5 * this.config.speechRate)
    );
    if (estimatedIndex <= 1) {
      return text;
    }
    const punctuation = '。！？；，,.!?;\n';
    for (let index = estimatedIndex - 1; index >= 0; index -= 1) {
      if (punctuation.includes(text[index])) {
        return text.substring(index + 1).trim();
      }
    }
    return text;
  }

  private clearSystemSpeechQueue(clearReplayState: boolean = true): void {
    this.activeSystemSpeechText = '';
    this.pausedSystemSpeechText = '';
    this.systemSpeechQueue = [];
    this.systemSpeechStartedAt = 0;
    this.systemSpeechPendingText = '';
    this.systemSpeechReceivedText = '';
    this.systemSpeechFirstChunkQueued = false;
    if (clearReplayState) {
      this.clearActiveReplayState();
    }
  }

  private handleEvent(type: string, sessionId: string, payload: Object | undefined): void {
    hilog.info(
      CONTROLLER_LOG_DOMAIN,
      CONTROLLER_LOG_TAG,
      'gateway event type=%{public}s session=%{public}s runtime=%{public}s',
      type,
      sessionId,
      this.snapshot.runtimeSessionId
    );
    if (sessionId.length > 0 && sessionId !== this.snapshot.runtimeSessionId) {
      // Late event from an older session: drop it.
      hilog.warn(
        CONTROLLER_LOG_DOMAIN,
        CONTROLLER_LOG_TAG,
        'gateway event dropped reason=session-mismatch type=%{public}s',
        type
      );
      return;
    }
    if (this.discardInterruptedTurnEvents && type !== 'session.info') {
      if (type === 'message.start' && this.replacementPromptSubmitted) {
        this.resetInterruptedTurnGuard();
      } else {
        hilog.warn(
          CONTROLLER_LOG_DOMAIN,
          CONTROLLER_LOG_TAG,
          'gateway event dropped reason=interrupted-turn type=%{public}s',
          type
        );
        return;
      }
    }
    const data = payload as Record<string, Object> | undefined;
    if (type === 'message.start') {
      this.ttsTextSent = '';
      this.beginSystemSpeechStream();
      this.snapshot.statusDetail = 'Agent 正在思考';
      this.beginAssistantMessage();
      return;
    }
    if (type === 'message.delta') {
      const text = this.payloadText(data);
      const speechDelta = this.payloadSpeechText(data).length > 0
        ? SpeechTextFilter.clean(this.payloadSpeechText(data))
        : this.speechTextFilter.push(text);
      hilog.info(
        CONTROLLER_LOG_DOMAIN,
        CONTROLLER_LOG_TAG,
        'assistant TTS delta length=%{public}d output=%{public}s muted=%{public}s system=%{public}s',
        text.length,
        String(this.voiceOutputEnabled),
        String(this.config.muted),
        String(this.useSystemSpeech)
      );
      this.appendAssistantDelta(text);
      if (text.length > 0) {
        this.snapshot.statusDetail = 'Agent 正在回复';
      }
      if (speechDelta.length > 0 && this.voiceOutputEnabled && !this.config.muted) {
        if (this.useSystemSpeech) {
          this.appendSystemSpeechStream(speechDelta);
        } else {
          this.tts.sendText(speechDelta);
          this.ttsTextSent += speechDelta;
        }
      }
      return;
    }
    if (type === 'message.complete') {
      const finalText = this.payloadText(data);
      const suppliedSpeechText = this.payloadSpeechText(data);
      const speechText = SpeechTextFilter.clean(suppliedSpeechText.length > 0
        ? suppliedSpeechText : (finalText.length > 0 ? finalText : this.currentAssistantText()));
      const speechTail = this.speechTextFilter.flush();
      hilog.info(
        CONTROLLER_LOG_DOMAIN,
        CONTROLLER_LOG_TAG,
        'assistant TTS complete final=%{public}d speech=%{public}d output=%{public}s muted=%{public}s system=%{public}s',
        finalText.length,
        speechText.length,
        String(this.voiceOutputEnabled),
        String(this.config.muted),
        String(this.useSystemSpeech)
      );
      const rawArtifacts = data !== undefined ? data['artifacts'] : undefined;
      const model = data !== undefined && data['model'] !== undefined ? String(data['model']) : '';
      this.finishAssistantMessage(finalText, rawArtifacts, model);
      hilog.info(CONTROLLER_LOG_DOMAIN, CONTROLLER_LOG_TAG, 'assistant message finalized');
      if (this.voiceOutputEnabled && !this.config.muted) {
        if (this.useSystemSpeech) {
          if (speechTail.length > 0) {
            this.appendSystemSpeechStream(speechTail);
          }
          this.finishSystemSpeechStream(speechText);
        } else {
          if (finalText.length > 0 && this.ttsTextSent.length === 0) {
            this.tts.sendText(speechText);
          }
          this.tts.sendDone();
        }
      }
      return;
    }
    if (type === 'thinking.delta' || type === 'reasoning.delta') {
      const text = data !== undefined && data['text'] !== undefined ? String(data['text']) : '';
      const message = this.currentAssistantMessage();
      if (message && text.length > 0) {
        message.thinking += text;
        message.processExpanded = true;
        message.revision += 1;
      }
      this.snapshot.statusDetail = text.length > 0 ? text : 'Agent 正在思考';
      this.notify();
      return;
    }
    if (type === 'tool.start' || type === 'tool.progress' || type === 'tool.complete') {
      const name = this.updateToolActivity(type, data);
      this.snapshot.statusDetail = name;
      this.notify();
      return;
    }
    if (type === 'approval.request') {
      const description = data !== undefined && data['description'] !== undefined
        ? String(data['description']).trim() : 'Agent 请求执行高风险操作';
      const command = data !== undefined && data['command'] !== undefined
        ? String(data['command']).trim() : '';
      const duplicate = this.snapshot.approvalPending &&
        this.snapshot.approvalDescription === description && this.snapshot.approvalCommand === command;
      this.snapshot.approvalPending = true;
      this.snapshot.approvalDescription = description;
      this.snapshot.approvalCommand = command;
      if (!duplicate) {
        this.approvalResponseInFlight = false;
        const prompt = this.approvalConversationText(description, command);
        this.appendMessage('assistant', this.agentName(this.snapshot.selectedProfile), prompt);
        this.speakProtocolPrompt(this.approvalSpeechText(description, command));
      }
      this.notify();
      return;
    }
    if (type === 'clarify.request') {
      const requestId = data !== undefined && data['request_id'] !== undefined
        ? String(data['request_id']) : '';
      const question = data !== undefined && data['question'] !== undefined
        ? String(data['question']).trim() : '请补充信息';
      const choices = data !== undefined ? data['choices'] : undefined;
      const parsedChoices = Array.isArray(choices)
        ? choices.map((choice: Object): string => String(choice).trim())
          .filter((choice: string): boolean => choice.length > 0) : [];
      const duplicate = this.snapshot.clarifyPending && this.snapshot.clarifyRequestId === requestId;
      this.snapshot.clarifyPending = true;
      this.snapshot.clarifyRequestId = requestId;
      this.snapshot.clarifyQuestion = question;
      this.snapshot.clarifyChoices = parsedChoices;
      if (!duplicate) {
        this.clarifyResponseInFlight = false;
        const prompt = this.clarifyConversationText(question, parsedChoices);
        this.appendMessage('assistant', this.agentName(this.snapshot.selectedProfile), prompt);
        this.speakProtocolPrompt(prompt);
      }
      this.notify();
      return;
    }
    if (type === 'status.update') {
      const text = data !== undefined && data['text'] !== undefined
        ? String(data['text']) : data !== undefined && data['kind'] !== undefined
          ? String(data['kind']) : '';
      this.snapshot.statusDetail = text;
      const message = this.currentAssistantMessage();
      if (message && text.length > 0) {
        let previous: MessageActivity | undefined;
        if (message.activities.length > 0) {
          const lastActivity = message.activities[message.activities.length - 1];
          if (lastActivity.id.startsWith('status-') && lastActivity.state === 'running') {
            previous = lastActivity;
          }
        }
        if (!previous || previous.detail !== text) {
          if (previous) {
            previous.state = 'completed';
          }
          const activity = new MessageActivity();
          activity.id = 'status-' + String(message.activities.length);
          activity.title = '状态';
          activity.detail = text;
          activity.state = 'running';
          message.activities.push(activity);
        }
        message.revision += 1;
      }
      this.notify();
      return;
    }
    if (type === 'session.info') {
      this.snapshot.runtimeModel = data !== undefined && data['model'] !== undefined
        ? String(data['model']) : '';
      this.snapshot.runtimeProvider = this.providerDisplay(data);
      this.confirmModelSwitch(data);
      const message = this.currentAssistantMessage();
      if (message && message.pending &&
        (this.snapshot.runtimeModel.length > 0 || this.snapshot.runtimeProvider.length > 0)) {
        if (this.snapshot.runtimeModel.length > 0) {
          message.model = this.snapshot.runtimeModel;
        }
        message.provider = this.snapshot.runtimeProvider;
        message.revision += 1;
      }
      this.notify();
      return;
    }
    if (type === 'error') {
      const message = data !== undefined && data['message'] !== undefined ? String(data['message']) : 'Agent错误';
      this.snapshot.agentBusy = false;
      this.snapshot.statusDetail = '';
      this.snapshot.error = message;
      this.failAssistantMessage(message);
      this.notify();
    }
  }

  private beginAssistantMessage(): void {
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = 'assistant';
    message.label = this.agentName(this.snapshot.selectedProfile);
    message.model = this.snapshot.runtimeModel;
    message.provider = this.snapshot.runtimeProvider;
    message.text = '';
    message.timestamp = Date.now();
    message.pending = true;
    message.processExpanded = true;
    this.snapshot.messages.push(message);
    this.activeAssistantMessageId = message.id;
    this.snapshot.agentBusy = true;
    this.notify();
  }

  private appendAssistantDelta(text: string): void {
    let message = this.currentAssistantMessage();
    if (!message || !message.pending) {
      this.beginAssistantMessage();
      message = this.currentAssistantMessage();
    }
    if (message && message.pending) {
      if (text.length > 0 && message.firstTokenAt === 0) {
        message.firstTokenAt = Date.now();
      }
      message.text += text;
      message.revision += 1;
      this.notify();
    }
  }

  private finishAssistantMessage(
    finalText: string,
    rawArtifacts: Object | undefined = undefined,
    model: string = ''
  ): void {
    const last = this.currentAssistantMessage();
    if (last && last.pending) {
        const endedAt = Date.now();
        if (finalText.length > 0) {
          last.text = finalText;
        }
        if (model.length > 0) {
          last.model = model;
        } else if (last.model.length === 0) {
          last.model = this.snapshot.runtimeModel;
        }
        if (last.provider.length === 0) {
          last.provider = this.snapshot.runtimeProvider;
        }
        last.artifacts = this.parseArtifacts(rawArtifacts);
        last.completedAt = endedAt;
        const firstTokenAt = last.firstTokenAt > 0 ? last.firstTokenAt : endedAt;
        last.thinking_s = Math.max(0, firstTokenAt - last.timestamp) / 1000;
        last.generation_s = Math.max(0, endedAt - firstTokenAt) / 1000;
        last.duration_s = Math.max(0, endedAt - last.timestamp) / 1000;
        for (const activity of last.activities) {
          if (activity.state === 'running') {
            activity.state = 'completed';
          }
        }
        last.pending = false;
        last.processExpanded = false;
        last.revision += 1;
    }
    this.activeAssistantMessageId = '';
    this.snapshot.agentBusy = false;
    this.snapshot.statusDetail = '';
    this.notify();
  }

  private failAssistantMessage(errorText: string): void {
    const message = this.currentAssistantMessage();
    if (!message || !message.pending) {
      return;
    }
    const endedAt = Date.now();
    const activity = new MessageActivity();
    activity.id = 'error-' + String(message.activities.length);
    activity.title = '执行失败';
    activity.detail = errorText;
    activity.state = 'error';
    message.activities.push(activity);
    message.completedAt = endedAt;
    message.duration_s = Math.max(0, endedAt - message.timestamp) / 1000;
    message.pending = false;
    message.processExpanded = true;
    message.revision += 1;
    this.activeAssistantMessageId = '';
  }

  private completeInterruptedAssistantMessage(): void {
    const message = this.currentAssistantMessage();
    if (!message || !message.pending) {
      this.activeAssistantMessageId = '';
      return;
    }
    const endedAt = Date.now();
    const firstTokenAt = message.firstTokenAt > 0 ? message.firstTokenAt : endedAt;
    message.completedAt = endedAt;
    message.thinking_s = Math.max(0, firstTokenAt - message.timestamp) / 1000;
    message.generation_s = Math.max(0, endedAt - firstTokenAt) / 1000;
    message.duration_s = Math.max(0, endedAt - message.timestamp) / 1000;
    for (const item of message.activities) {
      if (item.state === 'running') {
        item.state = 'completed';
      }
    }
    const activity = new MessageActivity();
    activity.id = 'stopped-' + String(message.activities.length);
    activity.title = '任务已停止';
    activity.detail = '已按用户要求停止当前任务';
    activity.state = 'completed';
    message.activities.push(activity);
    message.pending = false;
    message.processExpanded = false;
    message.revision += 1;
    this.activeAssistantMessageId = '';
  }

  private resetInterruptedTurnGuard(): void {
    this.discardInterruptedTurnEvents = false;
    this.replacementPromptSubmitted = false;
  }

  private currentAssistantText(): string {
    const message = this.currentAssistantMessage();
    return message ? message.text : '';
  }

  private currentAssistantMessage(): ChatMessage | undefined {
    const messages = this.snapshot.messages;
    if (this.activeAssistantMessageId.length > 0) {
      for (let index = messages.length - 1; index >= 0; index -= 1) {
        if (messages[index].id === this.activeAssistantMessageId) {
          return messages[index];
        }
      }
    }
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (messages[index].role === 'assistant' && messages[index].pending) {
        return messages[index];
      }
    }
    if (messages.length > 0 && messages[messages.length - 1].role === 'assistant') {
      return messages[messages.length - 1];
    }
    return undefined;
  }

  private findActivity(message: ChatMessage, id: string): MessageActivity | undefined {
    for (const activity of message.activities) {
      if (activity.id === id) {
        return activity;
      }
    }
    return undefined;
  }

  private updateToolActivity(type: string, data: Record<string, Object> | undefined): string {
    const name = data !== undefined && data['name'] !== undefined ? String(data['name']) : '工具';
    const message = this.currentAssistantMessage();
    if (!message) {
      return name;
    }
    const rawId = data !== undefined && data['tool_id'] !== undefined ? String(data['tool_id']) : name;
    const id = 'tool-' + rawId;
    let activity = this.findActivity(message, id);
    if (!activity) {
      activity = new MessageActivity();
      activity.id = id;
      activity.title = name;
      message.activities.push(activity);
    }
    if (type === 'tool.start') {
      const context = data !== undefined && data['context'] !== undefined
        ? String(data['context']) : data !== undefined && data['args_text'] !== undefined
          ? String(data['args_text']) : '';
      activity.detail = context;
      activity.state = 'running';
      message.processExpanded = true;
    } else if (type === 'tool.progress') {
      const preview = data !== undefined && data['preview'] !== undefined ? String(data['preview']) : '';
      if (preview.length > 0) {
        activity.detail = preview;
      }
      activity.state = 'running';
    } else {
      const summary = data !== undefined && data['summary'] !== undefined ? String(data['summary']) : '';
      const error = data !== undefined && data['error'] !== undefined ? String(data['error']) : '';
      activity.detail = error.length > 0 ? error : summary;
      activity.state = error.length > 0 ? 'error' : 'completed';
      if (data !== undefined && typeof data['duration_s'] === 'number') {
        activity.duration_s = data['duration_s'] as number;
      }
    }
    message.revision += 1;
    return name;
  }

  private parseArtifacts(rawArtifacts: Object | undefined): MessageArtifact[] {
    if (!Array.isArray(rawArtifacts)) {
      return [];
    }
    const artifacts: MessageArtifact[] = [];
    const items = rawArtifacts as Object[];
    for (const item of items) {
      const row = item as Record<string, Object>;
      const token = row['token'] !== undefined ? String(row['token']) : '';
      if (token.length === 0) {
        continue;
      }
      const artifact = new MessageArtifact();
      artifact.token = token;
      artifact.name = row['name'] !== undefined ? String(row['name']) : '附件';
      artifact.mimeType = row['mime_type'] !== undefined
        ? String(row['mime_type']) : 'application/octet-stream';
      artifact.size = typeof row['size'] === 'number' ? row['size'] as number : 0;
      artifact.isImage = row['is_image'] === true || artifact.mimeType.startsWith('image/');
      artifacts.push(artifact);
    }
    return artifacts;
  }

  private payloadText(data: Record<string, Object> | undefined): string {
    if (data === undefined) {
      return '';
    }
    if (data['text'] !== undefined) {
      return String(data['text']);
    }
    if (data['rendered'] !== undefined) {
      return String(data['rendered']);
    }
    return '';
  }

  private approvalConversationText(description: string, command: string): string {
    let prompt = '需要确认：' + description;
    if (command.length > 0) {
      prompt += '\n操作：' + command;
    }
    return prompt + '\n请回复“同意”或“取消”。';
  }

  private approvalSpeechText(description: string, command: string): string {
    const source = (description || command || '执行一项高风险操作').replace(/\s+/g, ' ').trim();
    const summary = source.length > 60 ? source.substring(0, 60) + '。' : source;
    return '需要确认：' + summary + '。请回复同意或取消。';
  }

  private clarifyConversationText(question: string, choices: string[]): string {
    let prompt = question;
    if (choices.length > 0) {
      const lines: string[] = [];
      for (let index = 0; index < choices.length; index += 1) {
        lines.push(String(index + 1) + '. ' + choices[index]);
      }
      prompt += '\n可选：\n' + lines.join('\n');
    }
    return prompt + '\n请直接回复你的选择。';
  }

  respondApproval(allow: boolean): void {
    if (!this.snapshot.approvalPending || this.approvalResponseInFlight) {
      return;
    }
    const sessionId = this.snapshot.runtimeSessionId;
    this.approvalResponseInFlight = true;
    this.snapshot.statusDetail = allow ? '正在提交同意' : '正在提交取消';
    this.notify();
    this.gateway.respondApproval(allow ? 'session' : 'deny').then(() => {
      if (sessionId !== this.snapshot.runtimeSessionId) {
        return;
      }
      this.approvalResponseInFlight = false;
      this.snapshot.approvalPending = false;
      this.snapshot.approvalDescription = '';
      this.snapshot.approvalCommand = '';
      this.snapshot.statusDetail = allow ? '已同意当前操作' : '已取消当前操作';
      this.notify();
    }).catch((error: BusinessError) => {
      if (sessionId !== this.snapshot.runtimeSessionId) {
        return;
      }
      this.approvalResponseInFlight = false;
      this.snapshot.error = this.errorMessage(error, '审批回复发送失败');
      this.notify();
    });
  }

  respondClarify(answer: string): void {
    const value = answer.trim();
    if (value.length === 0 || !this.snapshot.clarifyPending || this.clarifyResponseInFlight) {
      return;
    }
    const requestId = this.snapshot.clarifyRequestId;
    this.clarifyResponseInFlight = true;
    this.snapshot.statusDetail = '正在提交补充回复';
    this.notify();
    this.gateway.respondClarify(requestId, value).then(() => {
      if (requestId !== this.snapshot.clarifyRequestId) {
        return;
      }
      this.clarifyResponseInFlight = false;
      this.snapshot.clarifyPending = false;
      this.snapshot.clarifyRequestId = '';
      this.snapshot.clarifyQuestion = '';
      this.snapshot.clarifyChoices = [];
      this.snapshot.statusDetail = '已提交补充回复';
      this.notify();
    }).catch((error: BusinessError) => {
      if (requestId !== this.snapshot.clarifyRequestId) {
        return;
      }
      this.clarifyResponseInFlight = false;
      this.snapshot.error = this.errorMessage(error, '补充回复发送失败');
      this.notify();
    });
  }

  private appendMessage(role: MessageRole, label: string, text: string): void {
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = role;
    message.label = label;
    message.text = text;
    message.timestamp = Date.now();
    this.snapshot.messages.push(message);
    this.notify();
  }

  private ensureAsrPreview(): ChatMessage {
    const existing = this.currentAsrMessage();
    if (existing !== undefined) {
      return existing;
    }
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = 'user';
    message.label = '你 · 正在识别';
    message.status = 'listening';
    message.transient = true;
    message.timestamp = Date.now();
    this.snapshot.messages.push(message);
    this.activeAsrMessageId = message.id;
    return message;
  }

  private currentAsrMessage(): ChatMessage | undefined {
    if (this.activeAsrMessageId.length === 0) {
      return undefined;
    }
    for (let index = this.snapshot.messages.length - 1; index >= 0; index -= 1) {
      const message = this.snapshot.messages[index];
      if (message.id === this.activeAsrMessageId) {
        return message;
      }
    }
    return undefined;
  }

  private discardAsrPreview(): void {
    if (this.activeAsrMessageId.length === 0) {
      return;
    }
    for (let index = this.snapshot.messages.length - 1; index >= 0; index -= 1) {
      if (this.snapshot.messages[index].id === this.activeAsrMessageId) {
        this.snapshot.messages.splice(index, 1);
        break;
      }
    }
    this.activeAsrMessageId = '';
  }

  private nextMessageId(): string {
    this.messageCounter += 1;
    return util.generateRandomUUID(true) + '-' + String(this.messageCounter);
  }

  listHistory(limit: number = 20): void {
    if (this.snapshot.connection !== 'online' || this.snapshot.historyLoading) {
      return;
    }
    this.snapshot.historyLoading = true;
    this.notify();
    this.gateway.listSessions(limit).then((result: Object) => {
      this.snapshot.historyLimit = limit;
      const record = result as Record<string, Object>;
      const rawSessions = record['sessions'];
      if (!Array.isArray(rawSessions)) {
        this.snapshot.history = [];
        this.snapshot.historyHasMore = false;
        this.snapshot.historyLoading = false;
        this.notify();
        return;
      }
      const sessions: HistorySession[] = [];
      const sessionItems = rawSessions as Object[];
      for (const item of sessionItems) {
        const row = item as Record<string, Object>;
        const rawId = row['id'] !== undefined ? row['id'] : row['session_id'];
        if (rawId === undefined) {
          continue;
        }
        const session = new HistorySession();
        session.id = String(rawId);
        const title = row['title'] !== undefined ? String(row['title']).trim() : '';
        const preview = row['preview'] !== undefined ? String(row['preview']).trim() : '';
        session.title = title.length > 0 ? title : preview.length > 0 ? preview : '未命名对话';
        session.preview = preview;
        session.source = row['source'] !== undefined ? String(row['source']) : 'Hermes';
        if (row['model'] !== undefined) {
          session.model = String(row['model']);
        }
        const updated = row['updated_at'] !== undefined ? row['updated_at'] : row['started_at'];
        if (typeof updated === 'number') {
          session.updated_at = updated;
        }
        if (typeof row['started_at'] === 'number') {
          session.started_at = row['started_at'] as number;
        }
        if (typeof row['message_count'] === 'number') {
          session.message_count = row['message_count'] as number;
        }
        sessions.push(session);
      }
      this.snapshot.history = sessions;
      this.snapshot.historyHasMore = sessions.length >= limit;
      this.snapshot.historyLoading = false;
      this.notify();
    }).catch((error: BusinessError) => {
      this.snapshot.historyLoading = false;
      this.snapshot.error = this.errorMessage(error, '历史会话读取失败');
      this.notify();
    });
  }

  loadMoreHistory(): void {
    if (!this.snapshot.historyHasMore || this.snapshot.historyLoading) {
      return;
    }
    this.listHistory(this.snapshot.historyLimit + 20);
  }

  resumeSession(storedId: string): void {
    if (storedId.length === 0 || this.snapshot.agentBusy || this.snapshot.conversationLoading) {
      return;
    }
    this.resetInterruptedTurnGuard();
    this.stopVoice();
    this.snapshot.messages = [];
    this.activeAssistantMessageId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.storedSessionId = storedId;
    this.snapshot.conversationLoading = true;
    this.snapshot.error = '';
    this.notify();
    this.gateway.resumeSession(storedId, 100).then((result: Object) => {
      this.sessionDetail.fetch(
        this.config.gatewayUrl,
        this.config.accessToken,
        this.snapshot.selectedProfile,
        storedId
      ).then((detail: Object) => {
        if (this.snapshot.storedSessionId === storedId) {
          this.completeSessionResume(result, detail);
        }
      }).catch(() => {
        if (this.snapshot.storedSessionId === storedId) {
          this.completeSessionResume(result);
        }
      });
    }).catch((error: BusinessError) => {
      if (this.snapshot.storedSessionId !== storedId) {
        return;
      }
      this.snapshot.conversationLoading = false;
      this.snapshot.error = this.errorMessage(error, '历史会话恢复失败');
      this.notify();
    });
  }

  private restoreSessionAfterReconnect(storedId: string): void {
    if (storedId.length === 0 || this.snapshot.conversationLoading) {
      return;
    }
    this.snapshot.conversationLoading = true;
    this.snapshot.statusTitle = '正在恢复连接';
    this.snapshot.statusDetail = '正在恢复当前会话';
    this.snapshot.error = '';
    this.notify();
    this.gateway.resumeSession(storedId, 100).then((result: Object) => {
      if (this.snapshot.storedSessionId !== storedId) {
        return;
      }
      this.snapshot.conversationLoading = false;
      this.onSessionCreated(result);
    }).catch((error: BusinessError) => {
      if (this.snapshot.storedSessionId !== storedId) {
        return;
      }
      if (this.isSessionNotFound(error)) {
        this.snapshot.storedSessionId = '';
        this.snapshot.runtimeSessionId = '';
        this.snapshot.messages = [];
        this.snapshot.error = '';
        this.gateway.createSession(100).then((result: Object) => {
          this.onSessionCreated(result);
        }).catch((createError: BusinessError) => {
          this.snapshot.conversationLoading = false;
          this.snapshot.error = this.errorMessage(createError, '新会话创建失败');
          this.notify();
        });
        this.notify();
        return;
      }
      this.snapshot.conversationLoading = false;
      this.snapshot.error = this.errorMessage(error, '当前会话恢复失败');
      this.notify();
    });
  }

  private completeSessionResume(result: Object, detail?: Object): void {
    const record = result as Record<string, Object>;
    const detailRecord = detail as Record<string, Object> | undefined;
    const detailedMessages = detailRecord !== undefined ? detailRecord['messages'] : undefined;
    const fallbackMessages = record['messages'];
    const messages = Array.isArray(detailedMessages) && detailedMessages.length > 0
      ? detailedMessages : fallbackMessages;
    this.snapshot.messages = [];
    if (Array.isArray(messages)) {
      this.restoreSessionMessages(messages as Object[]);
    }
    this.snapshot.conversationLoading = false;
    this.onSessionCreated(result);
  }

  private restoreSessionMessages(messageItems: Object[]): void {
    let currentModel: string = this.snapshot.runtimeModel;
    let pendingThinking: string = '';
    let pendingActivities: MessageActivity[] = [];
    for (const item of messageItems) {
      const row = item as Record<string, Object>;
      if (String(row['display_kind'] !== undefined ? row['display_kind'] : '') === 'model_switch') {
        currentModel = this.historyModelSwitch(row['display_metadata'], currentModel);
        continue;
      }
      const roleValue = row['role'] !== undefined ? String(row['role']) : '';
      if (roleValue === 'tool') {
        this.restoreHistoryToolResult(row, pendingActivities);
        continue;
      }
      if (roleValue !== 'user' && roleValue !== 'assistant') {
        continue;
      }
      const text = row['text'] !== undefined
        ? String(row['text']) : row['content'] !== undefined ? String(row['content']) : '';
      const artifacts = this.parseArtifacts(row['artifacts']);
      if (roleValue === 'assistant') {
        pendingThinking = this.appendHistoryThinking(pendingThinking, row);
        this.restoreHistoryToolCalls(row, pendingActivities);
      }
      if (text.length === 0 && artifacts.length === 0) {
        continue;
      }
      const message = new ChatMessage();
      message.id = this.nextMessageId();
      message.role = roleValue === 'user' ? 'user' : 'assistant';
      message.label = message.role === 'user' ? '你' : this.agentName(this.snapshot.selectedProfile);
      message.text = text;
      message.artifacts = artifacts;
      message.model = row['model'] !== undefined
        ? String(row['model']) : message.role === 'assistant' ? currentModel : '';
      message.provider = this.providerDisplay(row);
      message.timestamp = this.parseTimestamp(row['timestamp']);
      if (message.role === 'user') {
        pendingThinking = '';
        pendingActivities = [];
      } else {
        message.thinking = pendingThinking;
        message.activities = pendingActivities;
        message.processExpanded = false;
        pendingThinking = '';
        pendingActivities = [];
      }
      this.snapshot.messages.push(message);
    }
  }

  private providerDisplay(data: Record<string, Object> | undefined): string {
    if (data === undefined) {
      return '';
    }
    for (const key of ['provider_label', 'provider_name', 'runtime_provider_label', 'runtime_provider']) {
      if (data[key] !== undefined) {
        const value = String(data[key]).trim();
        if (value.length > 0) {
          return value;
        }
      }
    }
    return data['provider'] !== undefined ? String(data['provider']).trim() : '';
  }

  private providerToken(value: string): string {
    return value.trim().toLowerCase().replace(/[^a-z0-9]/g, '');
  }

  private isGenericProvider(value: string): boolean {
    const normalized = this.providerToken(value);
    return normalized.length === 0 || normalized === 'custom' || normalized === 'openaiapi' ||
      normalized === 'openaicompatible' || normalized === 'openaicompatibleapi';
  }

  private reconcileRuntimeProvider(catalog: ModelOptionsCatalog): void {
    if (!this.isGenericProvider(this.snapshot.runtimeProvider)) {
      return;
    }
    let providerLabel = catalog.activeProviderLabel.trim();
    if (providerLabel.length === 0 && this.snapshot.runtimeModel.length > 0) {
      const candidates = catalog.providers.filter((provider: ModelProviderInfo): boolean =>
        provider.models.find((model: ModelOptionInfo): boolean =>
          model.id === this.snapshot.runtimeModel) !== undefined);
      if (candidates.length === 1) {
        providerLabel = candidates[0].name;
      }
    }
    if (providerLabel.length === 0 || this.isGenericProvider(providerLabel)) {
      return;
    }
    this.snapshot.runtimeProvider = providerLabel;
    for (const message of this.snapshot.messages) {
      if (message.role === 'assistant' && this.isGenericProvider(message.provider)) {
        message.provider = providerLabel;
        message.revision += 1;
      }
    }
  }

  private isSessionNotFound(error: BusinessError): boolean {
    const message = this.errorMessage(error, '').toLowerCase();
    return message.includes('session not found') ||
      message.includes('session does not exist') ||
      message.includes('会话不存在') ||
      message.includes('找不到会话');
  }

  private historyModelSwitch(rawMetadata: Object | undefined, fallback: string): string {
    if (rawMetadata === undefined) {
      return fallback;
    }
    let metadata: Record<string, Object>;
    if (typeof rawMetadata === 'string') {
      try {
        metadata = JSON.parse(rawMetadata) as Record<string, Object>;
      } catch (error) {
        return fallback;
      }
    } else {
      metadata = rawMetadata as Record<string, Object>;
    }
    return metadata['model'] !== undefined ? String(metadata['model']) : fallback;
  }

  private appendHistoryThinking(current: string, row: Record<string, Object>): string {
    const raw = row['reasoning_content'] !== undefined
      ? String(row['reasoning_content']) : row['reasoning'] !== undefined ? String(row['reasoning']) : '';
    const value = raw.trim();
    if (value.length === 0 || current.includes(value)) {
      return current;
    }
    return current.length > 0 ? current + '\n\n' + value : value;
  }

  private restoreHistoryToolCalls(
    row: Record<string, Object>,
    activities: MessageActivity[]
  ): void {
    const rawCalls = row['tool_calls'];
    if (!Array.isArray(rawCalls)) {
      return;
    }
    const calls = rawCalls as Object[];
    for (const rawCall of calls) {
      const call = rawCall as Record<string, Object>;
      const rawFunction = call['function'];
      const toolFunction = rawFunction !== undefined
        ? rawFunction as Record<string, Object> : undefined;
      const name = toolFunction !== undefined && toolFunction['name'] !== undefined
        ? String(toolFunction['name']) : 'tool';
      const callId = call['call_id'] !== undefined
        ? String(call['call_id']) : call['id'] !== undefined ? String(call['id']) : name;
      const activityId = 'history-tool-' + callId;
      if (this.findActivityById(activities, activityId)) {
        continue;
      }
      const activity = new MessageActivity();
      activity.id = activityId;
      activity.title = this.historyToolTitle(name);
      activity.detail = '正在执行';
      activity.state = 'running';
      activities.push(activity);
    }
  }

  private restoreHistoryToolResult(
    row: Record<string, Object>,
    activities: MessageActivity[]
  ): void {
    const name = row['tool_name'] !== undefined ? String(row['tool_name']) : 'tool';
    const callId = row['tool_call_id'] !== undefined ? String(row['tool_call_id']) : name;
    const activityId = 'history-tool-' + callId;
    let activity = this.findActivityById(activities, activityId);
    if (!activity) {
      activity = new MessageActivity();
      activity.id = activityId;
      activity.title = this.historyToolTitle(name);
      activities.push(activity);
    }
    const result = this.historyToolResult(row['content']);
    activity.detail = result.success ? this.historyToolSuccessText(name, result.message) : '执行失败';
    activity.state = result.success ? 'completed' : 'error';
  }

  private findActivityById(
    activities: MessageActivity[],
    id: string
  ): MessageActivity | undefined {
    for (const activity of activities) {
      if (activity.id === id) {
        return activity;
      }
    }
    return undefined;
  }

  private historyToolTitle(name: string): string {
    if (name === 'memory') {
      return '记忆更新';
    }
    if (name === 'web_search' || name === 'search') {
      return '信息检索';
    }
    return name === 'tool' || name.length === 0 ? '工具调用' : name;
  }

  private historyToolResult(rawContent: Object | undefined): HistoryToolResult {
    const result = new HistoryToolResult();
    if (rawContent === undefined) {
      return result;
    }
    try {
      const parsed = JSON.parse(String(rawContent)) as Record<string, Object>;
      result.success = parsed['success'] !== false && parsed['error'] === undefined;
      result.message = parsed['message'] !== undefined ? String(parsed['message']) : '';
    } catch (error) {
      result.success = true;
    }
    return result;
  }

  private historyToolSuccessText(name: string, message: string): string {
    if (name === 'memory') {
      const normalized = message.toLowerCase();
      return normalized.includes('added') ? '已记录用户偏好' : '已更新用户偏好';
    }
    return '执行完成';
  }

  private parseTimestamp(value: Object | undefined): number {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    if (typeof value === 'string') {
      const numeric = Number(value);
      if (Number.isFinite(numeric) && numeric > 0) {
        return numeric;
      }
      const millis = Date.parse(value);
      if (Number.isFinite(millis) && millis > 0) {
        return millis;
      }
    }
    return 0;
  }

  deleteSession(storedId: string): void {
    if (storedId.length === 0 || storedId === this.snapshot.storedSessionId) {
      return;
    }
    this.gateway.deleteSession(storedId).then(() => {
      this.listHistory(this.snapshot.historyLimit);
    }).catch((error: BusinessError) => {
      this.snapshot.error = this.errorMessage(error, '历史会话删除失败');
      this.notify();
    });
  }

  private profileFromValue(value: Object): ProfileKey {
    const name = String(value).trim();
    return name.length > 0 ? name : 'default';
  }

  private payloadSpeechText(data: Record<string, Object> | undefined): string {
    if (data !== undefined && typeof data['speech_text'] === 'string') {
      return String(data['speech_text']);
    }
    return '';
  }

  private agentName(profile: string): string {
    return this.agentCatalog.displayName(profile);
  }

  private speechBackendFromValue(value: Object): SpeechBackend {
    return String(value) === 'remote' ? 'remote' : 'harmony_offline';
  }

  private normalizeSpeechRate(value: number): number {
    return Math.round(Math.max(0.5, Math.min(2, value)) * 10) / 10;
  }

  private normalizeGatewayUrl(value: string): string {
    const normalized = value.trim();
    if (normalized.length === 0) {
      return DEFAULT_GATEWAY_URL;
    }
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  private isSafeConfigAtom(value: string): boolean {
    return value.length > 0 && !/\s/.test(value) && !value.startsWith('--');
  }

  private clearModelOptions(): void {
    this.modelOptionsSequence += 1;
    this.snapshot.modelProviders = [];
    this.snapshot.modelOptionsLoading = false;
    this.snapshot.modelOptionsError = '';
  }

  private clearModelSwitchTimeout(): void {
    if (this.modelSwitchTimeout !== undefined) {
      clearTimeout(this.modelSwitchTimeout);
      this.modelSwitchTimeout = undefined;
    }
  }

  private resetRequestedModel(): void {
    this.requestedModelProvider = '';
    this.requestedModel = '';
    this.modelBeforeSwitch = '';
  }

  private cancelModelSwitch(message: string): void {
    if (!this.snapshot.modelSwitching) {
      return;
    }
    this.modelSwitchSequence += 1;
    this.clearModelSwitchTimeout();
    this.snapshot.modelSwitching = false;
    this.snapshot.modelSwitchStatus = '';
    this.snapshot.modelSwitchError = message;
    this.resetRequestedModel();
  }

  private confirmModelSwitch(data: Record<string, Object> | undefined): void {
    if (!this.snapshot.modelSwitching || data === undefined || this.requestedModel.length === 0) {
      return;
    }
    const confirmedModel = data['model'] !== undefined ? String(data['model']).trim() : '';
    if (confirmedModel !== this.requestedModel) {
      return;
    }
    if (this.requestedModel === this.modelBeforeSwitch) {
      const rawProvider = data['provider'] !== undefined ? String(data['provider']).trim() : '';
      const displayProvider = this.providerDisplay(data);
      const option = this.snapshot.modelProviders.find(
        (item: ModelProviderInfo): boolean => item.id === this.requestedModelProvider
      );
      const providerName = option !== undefined ? option.name : '';
      if (rawProvider !== this.requestedModelProvider &&
        displayProvider !== this.requestedModelProvider &&
        (providerName.length === 0 || displayProvider !== providerName)) {
        return;
      }
    }
    const confirmedProvider = this.snapshot.modelProviders.find(
      (item: ModelProviderInfo): boolean => item.id === this.requestedModelProvider
    );
    if (confirmedProvider !== undefined && this.isGenericProvider(this.snapshot.runtimeProvider)) {
      this.snapshot.runtimeProvider = confirmedProvider.name;
    }
    this.clearModelSwitchTimeout();
    this.snapshot.modelSwitching = false;
    this.snapshot.modelSwitchError = '';
    const identity = [this.snapshot.runtimeProvider, this.snapshot.runtimeModel]
      .filter((value: string): boolean => value.length > 0).join(' · ');
    this.snapshot.modelSwitchStatus = identity.length > 0
      ? '当前会话已确认：' + identity : '当前会话模型已确认';
    this.resetRequestedModel();
  }

  private persistConfig(): void {
    const store = this.settings;
    if (!store) {
      return;
    }
    try {
      store.putSync('gatewayUrl', this.config.gatewayUrl);
      store.putSync('profile', this.config.profile);
      store.putSync('muted', this.config.muted);
      store.putSync('speakerphoneEnabled', this.config.speakerphoneEnabled);
      store.putSync('debugMode', this.config.debugMode);
      store.putSync('speechBackend', this.config.speechBackend);
      store.putSync('voicePerson', this.config.voicePerson);
      store.putSync('speechRate', this.config.speechRate);
      store.flushSync();
    } catch (error) {
      // Preferences are a convenience; connection must still work in memory.
    }
    const token = this.config.accessToken;
    if (token === this.queuedAccessToken) {
      return;
    }
    this.queuedAccessToken = token;
    const operation = this.configPersistence.catch((): void => undefined).then((): Promise<void> =>
      this.secureTokenStore.save(store, token)
    ).then((): void => {
      this.persistedAccessToken = token;
    });
    this.configPersistence = operation;
    operation.catch((): void => {
      if (this.queuedAccessToken === token) {
        this.queuedAccessToken = this.persistedAccessToken;
      }
      if (this.configPersistence === operation) {
        this.configPersistence = Promise.resolve();
      }
      this.snapshot.error = '访问口令未能写入安全存储，请重新保存';
      this.notify();
    });
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }

  private wsUrl(path: string, profile: ProfileKey): string {
    const base = this.config.gatewayUrl;
    const trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    const scheme = trimmed.startsWith('https:') ? 'wss:' : 'ws:';
    const rest = trimmed.startsWith('http') ? trimmed.substring(trimmed.indexOf('//')) : trimmed;
    return scheme + rest + path + '?profile=' + encodeURIComponent(profile);
  }

  private snapshotForUi(): SingleAgentSnapshot {
    const source = this.snapshot;
    const copy = new SingleAgentSnapshot();
    copy.connection = source.connection;
    copy.selectedProfile = source.selectedProfile;
    copy.agents = source.agents.map((agent: AgentInfo): AgentInfo => {
      const item = new AgentInfo();
      item.id = agent.id;
      item.name = agent.name;
      item.isDefault = agent.isDefault;
      item.avatarUrl = agent.avatarUrl;
      return item;
    });
    copy.agentsLoading = source.agentsLoading;
    copy.agentsError = source.agentsError;
    copy.runtimeSessionId = source.runtimeSessionId;
    copy.storedSessionId = source.storedSessionId;
    copy.voiceEnabled = source.voiceEnabled;
    copy.asrState = source.asrState;
    copy.asrTranscript = source.asrTranscript;
    copy.asrUtteranceActive = source.asrUtteranceActive;
    copy.microphoneRoute = source.microphoneRoute;
    copy.speakerphoneEnabled = source.speakerphoneEnabled;
    copy.audioOutputRoute = source.audioOutputRoute;
    copy.headsetOutputAvailable = source.headsetOutputAvailable;
    copy.ttsState = source.ttsState;
    copy.ttsSampleRate = source.ttsSampleRate;
    copy.asrBackend = source.asrBackend;
    copy.ttsBackend = source.ttsBackend;
    copy.agentBusy = source.agentBusy;
    copy.approvalPending = source.approvalPending;
    copy.clarifyPending = source.clarifyPending;
    copy.playback = source.playback;
    copy.messages = source.messages.map((message: ChatMessage): ChatMessage => this.messageForUi(message));
    copy.history = source.history.slice();
    copy.historyLimit = source.historyLimit;
    copy.historyLoading = source.historyLoading;
    copy.historyHasMore = source.historyHasMore;
    copy.conversationLoading = source.conversationLoading;
    copy.debugMode = source.debugMode;
    copy.statusTitle = source.statusTitle;
    copy.statusDetail = source.statusDetail;
    copy.runtimeModel = source.runtimeModel;
    copy.runtimeProvider = source.runtimeProvider;
    copy.modelProviders = source.modelProviders.map((provider: ModelProviderInfo): ModelProviderInfo => {
      const providerCopy = new ModelProviderInfo();
      providerCopy.id = provider.id;
      providerCopy.name = provider.name;
      providerCopy.models = provider.models.map((model: ModelOptionInfo): ModelOptionInfo => {
        const modelCopy = new ModelOptionInfo();
        modelCopy.id = model.id;
        modelCopy.label = model.label;
        return modelCopy;
      });
      return providerCopy;
    });
    copy.modelOptionsLoading = source.modelOptionsLoading;
    copy.modelOptionsError = source.modelOptionsError;
    copy.modelSwitching = source.modelSwitching;
    copy.modelSwitchStatus = source.modelSwitchStatus;
    copy.modelSwitchError = source.modelSwitchError;
    copy.error = source.error;
    copy.approvalDescription = source.approvalDescription;
    copy.approvalCommand = source.approvalCommand;
    copy.clarifyRequestId = source.clarifyRequestId;
    copy.clarifyQuestion = source.clarifyQuestion;
    copy.clarifyChoices = source.clarifyChoices.slice();
    return copy;
  }

  private messageForUi(source: ChatMessage): ChatMessage {
    const copy = new ChatMessage();
    copy.id = source.id;
    copy.revision = source.revision;
    copy.role = source.role;
    copy.label = source.label;
    copy.text = source.text;
    copy.model = source.model;
    copy.provider = source.provider;
    copy.status = source.status;
    copy.transient = source.transient;
    copy.thinking = source.thinking;
    copy.thinking_s = source.thinking_s;
    copy.generation_s = source.generation_s;
    copy.duration_s = source.duration_s;
    copy.timestamp = source.timestamp;
    copy.firstTokenAt = source.firstTokenAt;
    copy.completedAt = source.completedAt;
    copy.pending = source.pending;
    copy.processExpanded = source.processExpanded;
    copy.replaying = source.replaying;
    const activities: MessageActivity[] = [];
    for (const sourceActivity of source.activities) {
      const activity = new MessageActivity();
      activity.id = sourceActivity.id;
      activity.title = sourceActivity.title;
      activity.detail = sourceActivity.detail;
      activity.state = sourceActivity.state;
      activity.duration_s = sourceActivity.duration_s;
      activities.push(activity);
    }
    copy.activities = activities;
    const artifacts: MessageArtifact[] = [];
    for (const sourceArtifact of source.artifacts) {
      const artifact = new MessageArtifact();
      artifact.token = sourceArtifact.token;
      artifact.name = sourceArtifact.name;
      artifact.mimeType = sourceArtifact.mimeType;
      artifact.size = sourceArtifact.size;
      artifact.isImage = sourceArtifact.isImage;
      artifacts.push(artifact);
    }
    copy.artifacts = artifacts;
    return copy;
  }

  private notify(): void {
    this.syncAudioCues();
    if (this.listener) {
      this.listener.onSnapshot(this.snapshotForUi());
    }
  }

  private syncAudioCues(): void {
    const error = this.snapshot.error.trim();
    const cueEnabled = this.voiceOutputEnabled && !this.config.muted;
    const newError = error.length > 0 && error !== this.lastCueError;
    this.lastCueError = error;
    const running = cueEnabled && error.length === 0 && this.snapshot.agentBusy &&
      !this.snapshot.asrUtteranceActive && this.snapshot.playback === 'none' &&
      this.snapshot.ttsState !== 'speaking' && !this.snapshot.approvalPending &&
      !this.snapshot.clarifyPending;
    this.audioCues.setRunning(running);
    if (cueEnabled && newError) {
      this.audioCues.playError();
    }
  }
}
