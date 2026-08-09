// Single-Agent controller state machine for HarmonyOS.
// Deliberately excludes Host orchestration (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

import { common, wantAgent } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import {
  ChatMessage,
  HistorySession,
  MessageArtifact,
  MessageActivity,
  MessageRole,
  ProfileInfo,
  ProfileKey,
  SingleAgentSnapshot,
  SpeechBackend
} from '../models/SingleAgentState';
import { AuthSessionClient } from './AuthSessionClient';
import { GatewayListener, HermesGatewayClient } from './HermesGatewayClient';
import { HermesSessionDetailClient } from './HermesSessionDetailClient';
import { AudioCuePlayer } from './AudioCuePlayer';
import { PcmCapture, PcmPlayer } from './PcmAudio';
import { AsrListener, StreamingAsrClient } from './StreamingAsrClient';
import { StreamingTtsClient, TtsJobListener } from './StreamingTtsClient';
import {
  SystemSpeechCallbacks,
  SystemSpeechCapabilities,
  SystemSpeechService,
  VoiceOption
} from './SystemSpeechService';

const STOP_PHRASES: string[] = ['停止', 'stop'];
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
  private sessionDetail: HermesSessionDetailClient = new HermesSessionDetailClient();
  private capture: PcmCapture = new PcmCapture();
  private player: PcmPlayer = new PcmPlayer();
  private audioCues: AudioCuePlayer = new AudioCuePlayer();
  private systemSpeech?: SystemSpeechService;
  private listener?: SnapshotListener;
  private context?: common.UIAbilityContext;
  private settings?: preferences.Preferences;
  private snapshot: SingleAgentSnapshot = new SingleAgentSnapshot();
  private config: ClientConfig = {
    gatewayUrl: DEFAULT_GATEWAY_URL,
    accessToken: '',
    profile: 'default',
    muted: false,
    speechBackend: 'harmony_offline',
    voicePerson: 0,
    speechRate: 1
  };
  private cookie: string = '';
  private voiceWanted: boolean = false;
  private capturing: boolean = false;
  private pausedForUser: boolean = false;
  private ttsTextSent: string = '';
  private messageCounter: number = 0;
  private activeAssistantMessageId: string = '';
  private discardInterruptedTurnEvents: boolean = false;
  private replacementPromptSubmitted: boolean = false;
  private useSystemSpeech: boolean = false;
  private systemRecognitionStarting: boolean = false;
  private systemRecognitionRestart?: number;
  private activeSystemSpeechText: string = '';
  private pausedSystemSpeechText: string = '';
  private systemSpeechQueue: string[] = [];
  private systemSpeechStartedAt: number = 0;
  private systemSpeechPendingText: string = '';
  private systemSpeechReceivedText: string = '';
  private systemSpeechFirstChunkQueued: boolean = false;
  private backgroundTaskRunning: boolean = false;
  private backgroundTaskStarting: boolean = false;
  private backgroundTaskStopping: boolean = false;
  private stopBackgroundTaskAfterStart: boolean = false;
  private lastCueError: string = '';

  setListener(listener: SnapshotListener): void {
    this.listener = listener;
    this.notify();
  }

  setContext(context: common.UIAbilityContext): void {
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
      (active: boolean): void => {
        this.onSystemSpeechState(active);
      },
      (channel: string, message: string): void => {
        this.onSystemSpeechError(channel, message);
      }
    ));
    const capabilities = this.systemSpeech.getCapabilities();
    try {
      this.settings = preferences.getPreferencesSync(context, { name: SETTINGS_FILE });
      const gateway = this.settings.getSync('gatewayUrl', DEFAULT_GATEWAY_URL);
      const token = this.settings.getSync('accessToken', '');
      const profile = this.settings.getSync('profile', 'default');
      const muted = this.settings.getSync('muted', false);
      const speechBackend = this.settings.getSync('speechBackend', 'harmony_offline');
      const voicePerson = this.settings.getSync('voicePerson', 0);
      const speechRate = this.settings.getSync('speechRate', 1);
      this.config = {
        gatewayUrl: typeof gateway === 'string' ? this.normalizeGatewayUrl(gateway) : DEFAULT_GATEWAY_URL,
        accessToken: typeof token === 'string' ? token : '',
        profile: this.profileFromValue(profile),
        muted: muted === true,
        speechBackend: this.speechBackendFromValue(speechBackend),
        voicePerson: typeof voicePerson === 'number' ? voicePerson : 0,
        speechRate: this.normalizeSpeechRate(typeof speechRate === 'number' ? speechRate : 1)
      };
      this.snapshot.selectedProfile = this.config.profile;
    } catch (error) {
      this.settings = undefined;
    }
    const systemAvailable = capabilities.stt && capabilities.tts;
    const backend: SpeechBackend = this.config.speechBackend === 'harmony_offline' && systemAvailable
      ? 'harmony_offline' : 'remote';
    this.snapshot.asrBackend = backend;
    this.snapshot.ttsBackend = backend;
  }

  getConfig(): ClientConfig {
    return {
      gatewayUrl: this.config.gatewayUrl,
      accessToken: this.config.accessToken,
      profile: this.config.profile,
      muted: this.config.muted,
      speechBackend: this.config.speechBackend,
      voicePerson: this.config.voicePerson,
      speechRate: this.config.speechRate
    };
  }

  getSnapshot(): SingleAgentSnapshot {
    return this.snapshot;
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

  setConfig(config: ClientConfig): boolean {
    const gatewayUrl = this.normalizeGatewayUrl(config.gatewayUrl);
    const connectionChanged = gatewayUrl !== this.config.gatewayUrl ||
      config.accessToken !== this.config.accessToken ||
      config.profile !== this.config.profile;
    const speechChanged = config.speechBackend !== this.config.speechBackend ||
      config.voicePerson !== this.config.voicePerson ||
      this.normalizeSpeechRate(config.speechRate) !== this.config.speechRate;
    this.config = {
      gatewayUrl: gatewayUrl,
      accessToken: config.accessToken,
      profile: config.profile,
      muted: config.muted,
      speechBackend: config.speechBackend,
      voicePerson: config.voicePerson,
      speechRate: this.normalizeSpeechRate(config.speechRate)
    };
    this.snapshot.selectedProfile = this.config.profile;
    this.persistConfig();
    this.notify();
    if (speechChanged && !connectionChanged && this.voiceWanted) {
      this.restartVoiceClients().catch(() => undefined);
    }
    return connectionChanged;
  }

  switchProfile(profile: ProfileKey): void {
    if (profile === this.config.profile || this.snapshot.agentBusy) {
      return;
    }
    const restoreVoice = this.voiceWanted;
    this.setConfig({
      gatewayUrl: this.config.gatewayUrl,
      accessToken: this.config.accessToken,
      profile: profile,
      muted: this.config.muted,
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
    this.snapshot.voiceEnabled = restoreVoice;
    this.notify();
    this.connect();
  }

  // Text input path. Also used after ASR final.
  submitText(text: string): boolean {
    const value = text.trim();
    if (value.length === 0) {
      return false;
    }
    if (this.isStopPhrase(value)) {
      this.interrupt(value);
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
    this.appendMessage('user', queued ? '你 · 已排队' : '你', value);
    this.snapshot.agentBusy = true;
    this.snapshot.statusDetail = queued ? '已排队，等待当前任务完成' : 'Agent 正在思考';
    this.notify();
    this.gateway.submitPrompt(value, queued).then((result: Object) => {
      // Prompt accepted; agent events drive the UI from here.
    }).catch((error: BusinessError) => {
      if (this.discardInterruptedTurnEvents) {
        this.replacementPromptSubmitted = false;
      }
      this.snapshot.agentBusy = false;
      this.snapshot.error = error.message;
      this.notify();
    });
    return true;
  }

  toggleVoice(): void {
    if (this.voiceWanted) {
      this.stopVoice();
      return;
    }
    this.voiceWanted = true;
    this.config.muted = false;
    this.snapshot.voiceEnabled = true;
    this.ensureConnections();
  }

  toggleMute(): void {
    this.config.muted = !this.config.muted;
    if (this.config.muted) {
      this.tts.sendStop();
      this.systemSpeech?.stopSpeaking();
      this.player.stop().catch(() => undefined);
      this.clearSystemSpeechQueue();
      this.snapshot.playback = 'none';
    }
    this.notify();
  }

  newConversation(): void {
    this.pausedForUser = false;
    this.resetInterruptedTurnGuard();
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.messages = [];
    this.activeAssistantMessageId = '';
    this.snapshot.storedSessionId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.approvalPending = false;
    this.snapshot.clarifyPending = false;
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
    this.snapshot.connection = 'connecting';
    this.snapshot.statusTitle = '正在连接';
    this.snapshot.error = '';
    this.notify();
    try {
      const authResult = await this.auth.acquireSessionCookie(this.config.gatewayUrl, this.config.accessToken);
      if (authResult.cookie.length === 0) {
        this.snapshot.connection = 'offline';
        this.snapshot.error = authResult.error.length > 0
          ? authResult.error
          : '鉴权失败，请检查网关地址和访问口令';
        this.notify();
        return;
      }
      this.cookie = authResult.cookie;
      this.openGateway();
    } catch (error) {
      this.snapshot.connection = 'offline';
      this.snapshot.error = '连接失败';
      this.notify();
    }
  }

  disconnect(): void {
    this.resetInterruptedTurnGuard();
    this.stopVoice();
    this.gateway.close();
    this.asr.close();
    this.tts.close();
    this.snapshot.connection = 'offline';
    this.snapshot.runtimeSessionId = '';
    this.notify();
  }

  // Exact-stop phrase: only these interrupt the current agent turn.
  private isStopPhrase(text: string): boolean {
    const normalized = text.trim().toLowerCase()
      .replace(/^[\s"'“”‘’.,!?;:，。！？；：、]+|[\s"'“”‘’.,!?;:，。！？；：、]+$/g, '');
    for (const phrase of STOP_PHRASES) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  private interrupt(displayText: string): void {
    const shouldPlayCue = this.voiceWanted && !this.config.muted;
    this.audioCues.setRunning(false);
    this.appendMessage('user', '你 · 已停止', displayText);
    this.discardInterruptedTurnEvents = true;
    this.replacementPromptSubmitted = false;
    this.pausedForUser = false;
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.asrTranscript = '';
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.approvalPending = false;
    this.snapshot.clarifyPending = false;
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
      this.snapshot.asrState = 'listening';
      this.startBackgroundVoiceTask();
      this.notify();
    }).catch((error: BusinessError) => {
      this.snapshot.error = error.message;
      this.notify();
    });
  }

  private stopVoice(): void {
    this.voiceWanted = false;
    this.audioCues.silence();
    this.stopBackgroundVoiceTask();
    this.pausedForUser = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.ttsState = 'stopped';
    this.clearSystemSpeechQueue();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.systemRecognitionStarting = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.systemSpeech?.stopRecognition(false).catch(() => undefined);
    this.asr.stop();
    this.capture.stop().then(() => {
      this.capturing = false;
      this.notify();
    }).catch(() => undefined);
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
  }

  onGatewayReady(): void {
    this.snapshot.connection = 'online';
    this.snapshot.error = '';
    if (this.snapshot.storedSessionId.length > 0) {
      this.resumeSession(this.snapshot.storedSessionId);
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
    this.snapshot.connection = 'offline';
    this.snapshot.agentBusy = false;
    this.snapshot.playback = 'none';
    this.snapshot.error = typeof message === 'string' && message.length > 0
      ? message
      : '网关连接失败';
    this.notify();
  }

  onGatewayClosed(): void {
    const wasOnline = this.snapshot.connection === 'online';
    this.snapshot.connection = 'offline';
    this.snapshot.agentBusy = false;
    this.snapshot.playback = 'none';
    if (wasOnline) {
      this.snapshot.error = '网关连接已断开';
    }
    this.notify();
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
      if (info['provider'] !== undefined) {
        this.snapshot.runtimeProvider = String(info['provider']);
      }
    }
    this.snapshot.statusTitle = '已连接';
    this.snapshot.statusDetail = this.snapshot.selectedProfile;
    this.snapshot.error = '';
    this.notify();
    this.listHistory();
    if (this.voiceWanted && !this.capturing) {
      this.startVoiceClients();
    }
  }

  private startVoiceClients(): void {
    const capabilities: SystemSpeechCapabilities | undefined = this.systemSpeech?.getCapabilities();
    if (this.config.speechBackend === 'harmony_offline' &&
      capabilities && capabilities.stt && capabilities.tts) {
      this.useSystemSpeech = true;
      this.snapshot.asrBackend = 'harmony_offline';
      this.snapshot.ttsBackend = 'harmony_offline';
      this.snapshot.ttsState = 'ready';
      this.asr.close();
      this.tts.close();
      this.startSystemRecognition();
      return;
    }
    this.useSystemSpeech = false;
    this.snapshot.asrBackend = 'remote';
    this.snapshot.ttsBackend = 'remote';
    this.startRemoteVoiceClients();
  }

  private async restartVoiceClients(): Promise<void> {
    if (!this.voiceWanted) {
      return;
    }
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.systemRecognitionStarting = false;
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
    if (this.voiceWanted && this.snapshot.connection === 'online') {
      this.startVoiceClients();
    }
  }

  private startRemoteVoiceClients(): void {
    if (!this.voiceWanted) {
      return;
    }
    this.snapshot.asrState = 'connecting';
    this.snapshot.ttsState = 'connecting';
    this.snapshot.error = '';
    this.notify();
    this.asr.setListener(new ControllerAsrListener(this));
    this.asr.connect(this.wsUrl('/api/audio/transcribe-stream', this.snapshot.selectedProfile), this.cookie);
    this.tts.setListener(new ControllerTtsListener(this));
    this.tts.connect(this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile), this.cookie);
    this.startCapture();
  }

  private startSystemRecognition(): void {
    if (!this.voiceWanted || !this.useSystemSpeech || this.systemRecognitionStarting ||
      this.snapshot.asrState === 'listening') {
      return;
    }
    const speech = this.systemSpeech;
    if (!speech) {
      this.fallbackToRemoteVoice('系统语音服务未初始化');
      return;
    }
    this.systemRecognitionStarting = true;
    this.snapshot.asrState = 'connecting';
    this.snapshot.error = '';
    this.notify();
    speech.startRecognition().then(() => {
      this.systemRecognitionStarting = false;
    }).catch((error: BusinessError) => {
      this.systemRecognitionStarting = false;
      this.scheduleSystemRecognitionRestart(this.errorMessage(error, '离线 STT 启动失败'));
    });
  }

  private fallbackToRemoteVoice(reason: string): void {
    if (!this.voiceWanted || !this.useSystemSpeech) {
      return;
    }
    this.useSystemSpeech = false;
    this.systemRecognitionStarting = false;
    this.snapshot.asrBackend = 'remote';
    this.snapshot.ttsBackend = 'remote';
    this.systemSpeech?.release().catch(() => undefined);
    this.capture.stop().then((): void => {
      this.capturing = false;
      if (this.voiceWanted && !this.useSystemSpeech) {
        this.startRemoteVoiceClients();
      }
    }).catch(() => undefined);
    this.snapshot.statusDetail = '鸿蒙离线语音不可用，已切换远端';
    if (reason.length > 0) {
      this.snapshot.error = reason;
    }
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
      this.startBackgroundVoiceTask();
    }
    if (!active && this.snapshot.asrUtteranceActive) {
      this.onAsrFinal('');
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

  onSystemRecognitionResult(text: string, isFinal: boolean, _isLast: boolean): void {
    if (!this.useSystemSpeech) {
      return;
    }
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected();
    }
    this.snapshot.asrTranscript = value;
    this.notify();
    if (isFinal) {
      this.onAsrFinal(value);
    }
  }

  onSystemSpeechState(active: boolean): void {
    if (!this.useSystemSpeech) {
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
    if (channel === 'STT') {
      this.snapshot.asrState = 'stopped';
      this.scheduleSystemRecognitionRestart('STT：' + message);
      return;
    }
    this.fallbackToRemoteVoice(channel + '：' + message);
  }

  private speakWithSystem(text: string): void {
    const value = text.trim();
    if (value.length === 0 || !this.systemSpeech) {
      return;
    }
    if (this.activeSystemSpeechText.length > 0 || this.pausedForUser ||
      this.snapshot.playback === 'queued' || this.snapshot.playback === 'playing') {
      this.systemSpeechQueue.push(value);
      return;
    }
    this.startSystemSpeech(value);
  }

  private beginSystemSpeechStream(): void {
    this.systemSpeechPendingText = '';
    this.systemSpeechReceivedText = '';
    this.systemSpeechFirstChunkQueued = false;
  }

  private appendSystemSpeechStream(text: string): void {
    if (text.length === 0) {
      return;
    }
    this.systemSpeechPendingText += text;
    this.systemSpeechReceivedText += text;
    this.flushSystemSpeechStream(false);
  }

  private finishSystemSpeechStream(finalText: string): void {
    const finalValue = finalText;
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
    this.notify();
    speech.speak(text, this.config.voicePerson, this.config.speechRate).catch((error: BusinessError) => {
      this.fallbackToRemoteVoice(this.errorMessage(error, '离线 TTS 启动失败'));
    });
  }

  onAsrReady(): void {
    this.snapshot.asrState = 'listening';
    this.snapshot.error = '';
    this.notify();
  }

  onAsrTranscript(text: string, interim: boolean, final: boolean): void {
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected();
    }
    this.snapshot.asrTranscript = value;
    this.notify();
    if (final) {
      this.onAsrFinal(value);
    }
  }

  onAsrError(message: string): void {
    this.snapshot.asrState = 'stopped';
    if (this.snapshot.asrUtteranceActive) {
      this.onAsrFinal('');
    }
    this.snapshot.error = typeof message === 'string' && message.length > 0
      ? message
      : 'ASR 连接失败';
    this.notify();
  }

  onAsrClosed(): void {
    this.snapshot.asrState = 'stopped';
    if (this.snapshot.asrUtteranceActive) {
      this.onAsrFinal('');
    }
    if (this.voiceWanted) {
      this.snapshot.error = 'ASR 连接已断开';
    }
    this.notify();
  }

  onTtsJobStarted(sampleRate: number): void {
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
    this.snapshot.ttsState = 'ready';
    this.snapshot.error = '';
    this.notify();
  }

  onTtsJobPcm(pcm: ArrayBuffer): void {
    this.player.enqueue(pcm);
  }

  onTtsJobEnded(): void {
    this.player.waitForDrain((): void => {
      this.snapshot.playback = 'none';
      this.snapshot.ttsState = this.voiceWanted ? 'ready' : 'stopped';
      this.notify();
    });
  }

  onTtsJobFallback(): void {
    this.snapshot.ttsState = 'fallback';
    this.snapshot.statusDetail = 'TTS已降级';
    this.notify();
  }

  onTtsError(message: string): void {
    this.snapshot.ttsState = 'error';
    this.snapshot.error = typeof message === 'string' && message.length > 0
      ? message
      : 'TTS 连接失败';
    this.notify();
  }

  onTtsClosed(): void {
    this.snapshot.ttsState = this.voiceWanted ? 'connecting' : 'stopped';
    this.notify();
  }

  private onAsrFinal(text: string): void {
    const value = text.trim();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    if (this.isStopPhrase(value)) {
      this.interrupt(value);
      return;
    }
    if (value.length > 0) {
      const accepted = this.submitText(value);
      if (accepted && this.voiceWanted && !this.config.muted) {
        this.audioCues.playAccepted();
      }
    }
    if (this.pausedForUser) {
      this.resumePausedPlayback();
      return;
    }
    this.notify();
  }

  private onUserSpeechDetected(): void {
    if (!this.voiceWanted) {
      return;
    }
    this.snapshot.asrUtteranceActive = true;
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
        this.snapshot.ttsState = this.voiceWanted ? 'ready' : 'stopped';
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

  private clearSystemSpeechQueue(): void {
    this.activeSystemSpeechText = '';
    this.pausedSystemSpeechText = '';
    this.systemSpeechQueue = [];
    this.systemSpeechStartedAt = 0;
    this.systemSpeechPendingText = '';
    this.systemSpeechReceivedText = '';
    this.systemSpeechFirstChunkQueued = false;
  }

  private handleEvent(type: string, sessionId: string, payload: Object | undefined): void {
    if (sessionId.length > 0 && sessionId !== this.snapshot.runtimeSessionId) {
      // Late event from an older session: drop it.
      return;
    }
    if (this.discardInterruptedTurnEvents && type !== 'session.info') {
      if (type === 'message.start' && this.replacementPromptSubmitted) {
        this.resetInterruptedTurnGuard();
      } else {
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
      this.appendAssistantDelta(text);
      if (text.length > 0) {
        this.snapshot.statusDetail = 'Agent 正在回复';
      }
      if (text.length > 0 && this.voiceWanted && !this.config.muted) {
        if (this.useSystemSpeech) {
          this.appendSystemSpeechStream(text);
        } else {
          this.tts.sendText(text);
          this.ttsTextSent += text;
        }
      }
      return;
    }
    if (type === 'message.complete') {
      const finalText = this.payloadText(data);
      const speechText = finalText.length > 0 ? finalText : this.currentAssistantText();
      const rawArtifacts = data !== undefined ? data['artifacts'] : undefined;
      const model = data !== undefined && data['model'] !== undefined ? String(data['model']) : '';
      this.finishAssistantMessage(finalText, rawArtifacts, model);
      if (this.voiceWanted && !this.config.muted) {
        if (this.useSystemSpeech) {
          this.finishSystemSpeechStream(speechText);
        } else {
          if (finalText.length > 0 && this.ttsTextSent.length === 0) {
            this.tts.sendText(finalText);
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
      this.snapshot.approvalPending = true;
      this.snapshot.approvalDescription = data !== undefined && data['description'] !== undefined
        ? String(data['description']) : 'Agent 请求执行高风险操作';
      this.snapshot.approvalCommand = data !== undefined && data['command'] !== undefined
        ? String(data['command']) : '';
      this.notify();
      return;
    }
    if (type === 'clarify.request') {
      this.snapshot.clarifyPending = true;
      this.snapshot.clarifyRequestId = data !== undefined && data['request_id'] !== undefined
        ? String(data['request_id']) : '';
      this.snapshot.clarifyQuestion = data !== undefined && data['question'] !== undefined
        ? String(data['question']) : '请补充信息';
      const choices = data !== undefined ? data['choices'] : undefined;
      this.snapshot.clarifyChoices = Array.isArray(choices)
        ? choices.map((choice: Object): string => String(choice)) : [];
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
      this.snapshot.runtimeProvider = data !== undefined && data['provider'] !== undefined
        ? String(data['provider']) : '';
      const message = this.currentAssistantMessage();
      if (message && message.pending && this.snapshot.runtimeModel.length > 0) {
        message.model = this.snapshot.runtimeModel;
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
    message.label = ProfileInfo.displayName(this.snapshot.selectedProfile);
    message.model = this.snapshot.runtimeModel;
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

  respondApproval(allow: boolean): void {
    this.gateway.respondApproval(allow ? 'session' : 'deny').then(() => {
      this.snapshot.approvalPending = false;
      this.snapshot.approvalDescription = '';
      this.snapshot.approvalCommand = '';
      this.notify();
    }).catch((error: BusinessError) => {
      this.snapshot.error = error.message;
      this.notify();
    });
  }

  respondClarify(answer: string): void {
    const value = answer.trim();
    if (value.length === 0) {
      return;
    }
    this.gateway.respondClarify(this.snapshot.clarifyRequestId, value).then(() => {
      this.snapshot.clarifyPending = false;
      this.snapshot.clarifyRequestId = '';
      this.snapshot.clarifyQuestion = '';
      this.snapshot.clarifyChoices = [];
      this.notify();
    }).catch((error: BusinessError) => {
      this.snapshot.error = error.message;
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
    if (storedId.length === 0 || this.snapshot.agentBusy) {
      return;
    }
    this.resetInterruptedTurnGuard();
    this.stopVoice();
    this.snapshot.messages = [];
    this.activeAssistantMessageId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.storedSessionId = storedId;
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
      this.snapshot.error = this.errorMessage(error, '历史会话恢复失败');
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
    this.onSessionCreated(result);
  }

  private restoreSessionMessages(messageItems: Object[]): void {
    let lastUserAt: number = 0;
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
      message.label = message.role === 'user' ? '你' : ProfileInfo.displayName(this.snapshot.selectedProfile);
      message.text = text;
      message.artifacts = artifacts;
      message.model = row['model'] !== undefined
        ? String(row['model']) : message.role === 'assistant' ? currentModel : '';
      message.timestamp = this.parseTimestamp(row['timestamp']);
      if (message.role === 'user') {
        pendingThinking = '';
        pendingActivities = [];
        lastUserAt = message.timestamp;
      } else {
        if (lastUserAt > 0 && message.timestamp >= lastUserAt) {
          const differenceMs = this.timestampMillis(message.timestamp) - this.timestampMillis(lastUserAt);
          message.duration_s = Math.max(0, differenceMs) / 1000;
        }
        message.thinking = pendingThinking;
        message.activities = pendingActivities;
        message.processExpanded = false;
        pendingThinking = '';
        pendingActivities = [];
      }
      this.snapshot.messages.push(message);
    }
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

  private timestampMillis(value: number): number {
    return value < 100000000000 ? value * 1000 : value;
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
    const name = String(value);
    if (name === 'hexiaoma' || name === 'hexiaoxin') {
      return name as ProfileKey;
    }
    return 'default';
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

  private persistConfig(): void {
    const store = this.settings;
    if (!store) {
      return;
    }
    try {
      store.putSync('gatewayUrl', this.config.gatewayUrl);
      store.putSync('accessToken', this.config.accessToken);
      store.putSync('profile', this.config.profile);
      store.putSync('muted', this.config.muted);
      store.putSync('speechBackend', this.config.speechBackend);
      store.putSync('voicePerson', this.config.voicePerson);
      store.putSync('speechRate', this.config.speechRate);
      store.flushSync();
    } catch (error) {
      // Preferences are a convenience; connection must still work in memory.
    }
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
    return scheme + rest + path + '?profile=' + profile;
  }

  private notify(): void {
    this.syncAudioCues();
    if (this.listener) {
      this.listener.onSnapshot(this.snapshot);
    }
  }

  private syncAudioCues(): void {
    const error = this.snapshot.error.trim();
    const cueEnabled = this.voiceWanted && !this.config.muted;
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
