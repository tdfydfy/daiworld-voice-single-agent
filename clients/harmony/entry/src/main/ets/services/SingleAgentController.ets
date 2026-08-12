// Single-Agent controller state machine for HarmonyOS.
// Deliberately excludes Host orchestration (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AudioOutputRoute,
  ChatMessage,
  MessageArtifact,
  MessageActivity,
  AgentInfo,
  ModelOptionInfo,
  ModelProviderInfo,
  ProfileKey,
  SingleAgentSnapshot,
  SpeechBackend
} from '../models/SingleAgentState';
import {
  AppSettingsLoadResult,
  AppSettingsStore,
  ClientConfig
} from './AppSettingsStore';
import { ConversationState, ConversationStateCallbacks } from './ConversationState';
import { HermesRuntime, HermesRuntimeCallbacks } from './HermesRuntime';
import { SpeechTextFilter } from './SpeechTextFilter';
import { BackgroundAudioIntent, BackgroundAudioTaskOwner } from './BackgroundAudioTaskOwner';
import {
  setCommunicationOutputRouteListener,
  setCommunicationSpeakerphoneEnabled
} from './CommunicationAudioSession';
import {
  SystemSpeechCallbacks,
  SystemSpeechCapabilities,
  SystemSpeechService,
  VoiceOption
} from './SystemSpeechService';
import { VoiceInputCallbacks, VoiceInputCoordinator } from './VoiceInputCoordinator';
import { VoiceOutputCallbacks, VoiceOutputCoordinator } from './VoiceOutputCoordinator';

const APPROVAL_ALLOW_PHRASES: string[] = ['同意', '允许', '可以', '执行', '允许执行', '同意执行'];
const APPROVAL_DENY_PHRASES: string[] = ['取消', '拒绝', '阻止', '不要', '拒绝执行', '阻止执行'];
const REMOTE_VOICE_RECONNECT_DELAYS_MS: number[] = [250, 750, 1500, 3000];
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

export class SingleAgentController {
  private runtime: HermesRuntime;
  private backgroundAudioTask: BackgroundAudioTaskOwner = new BackgroundAudioTaskOwner();
  private systemSpeech?: SystemSpeechService;
  private listener?: SnapshotListener;
  private context?: common.UIAbilityContext;
  private appSettings: AppSettingsStore = new AppSettingsStore();
  private snapshot: SingleAgentSnapshot = new SingleAgentSnapshot();
  private conversation: ConversationState;
  private output: VoiceOutputCoordinator;
  private input: VoiceInputCoordinator;
  private config: ClientConfig = AppSettingsStore.defaultConfig();
  private discardInterruptedTurnEvents: boolean = false;
  private replacementPromptSubmitted: boolean = false;
  private outputRouteInitialized: boolean = false;
  private remoteTtsReconnectTimer?: number;
  private remoteTtsReconnectAttempt: number = 0;

  constructor() {
    this.runtime = new HermesRuntime(this.snapshot, new HermesRuntimeCallbacks(
      (): void => this.notify(),
      (profile: string): void => {
        this.config.profile = profile;
        this.snapshot.selectedProfile = profile;
        this.persistConfig();
      },
      (): void => this.onRuntimeReady(),
      (type: string, sessionId: string, payload: Object | undefined): void => {
        this.handleEvent(type, sessionId, payload);
      },
      (message: string, shouldFinalizeTurn: boolean): void => {
        this.onRuntimeUnavailable(message, shouldFinalizeTurn);
      }
    ));
    this.conversation = new ConversationState(this.snapshot, new ConversationStateCallbacks(
      (): void => this.notify(),
      (): string => this.agentName(this.snapshot.selectedProfile),
      (data: Record<string, Object> | undefined): string => this.runtime.providerDisplay(data)
    ));
    this.output = new VoiceOutputCoordinator(this.snapshot, new VoiceOutputCallbacks(
      (): ClientConfig => this.config,
      (): void => this.notify(),
      (): void => this.syncBackgroundVoiceTask(),
      (): void => this.cancelRemoteTtsReconnect(),
      (message: string): void => this.handleRemoteTtsDisconnect(message),
      (): string => this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile),
      (): string => this.runtime.getCookie()
    ));
    this.input = new VoiceInputCoordinator(this.snapshot, this.output, new VoiceInputCallbacks(
      (): ClientConfig => this.config,
      (): void => this.notify(),
      (): void => this.syncBackgroundVoiceTask(),
      (): ChatMessage => this.conversation.ensureAsrPreview(),
      (): ChatMessage | undefined => this.conversation.currentAsrMessage(),
      (): void => this.conversation.discardAsrPreview(),
      (value: string, preview?: ChatMessage): boolean => this.consumePendingProtocolReply(value, preview),
      (value: string, preview?: ChatMessage): void => this.interrupt(value, preview),
      (value: string, preview?: ChatMessage): boolean => this.submitText(value, preview),
      (value: string): boolean => this.isApprovalAllowPhrase(value) || this.isApprovalDenyPhrase(value),
      (): string => this.wsUrl('/api/audio/transcribe-stream', this.snapshot.selectedProfile),
      (): string => this.runtime.getCookie()
    ));
  }

  setListener(listener: SnapshotListener): void {
    this.listener = listener;
    this.notify();
  }

  async setContext(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.backgroundAudioTask.setContext(context);
    this.input.setContext(context);
    this.systemSpeech = new SystemSpeechService(context, new SystemSpeechCallbacks(
      (active: boolean): void => {
        this.input.onSystemRecognitionState(active);
      },
      (text: string, isFinal: boolean, isLast: boolean): void => {
        this.input.onSystemRecognitionResult(text, isFinal, isLast);
      },
      (): void => {
        this.input.onRecognitionAudioStart();
      },
      (phase: string): void => {
        this.input.onSystemRecognitionStartupPhase(phase);
      },
      (label: string): void => {
        this.input.onMicrophoneRouteChanged(label);
      },
      (active: boolean): void => {
        this.output.onSystemSpeechState(active);
      },
      (channel: string, message: string): void => {
        this.onSystemSpeechError(channel, message);
      }
    ));
    this.output.setSystemSpeech(this.systemSpeech);
    this.input.setSystemSpeech(this.systemSpeech);
    try {
      const loaded: AppSettingsLoadResult = await this.appSettings.load(context);
      this.config = loaded.config;
      this.snapshot.credentialState = loaded.credentialState;
      this.snapshot.credentialError = loaded.credentialError;
      if (loaded.credentialState === 'storage_error') {
        this.snapshot.error = loaded.credentialError;
      }
      this.snapshot.selectedProfile = this.config.profile;
    } catch (error) {
      this.snapshot.credentialState = 'storage_error';
      this.snapshot.credentialError = '访问口令本地存储初始化失败，请重新输入并保存';
      this.snapshot.error = this.snapshot.credentialError;
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
    this.conversation.toggleMessageProcess(messageId);
  }

  listSystemVoices(): Promise<VoiceOption[]> {
    if (!this.systemSpeech) {
      const voices: VoiceOption[] = [];
      return Promise.resolve(voices);
    }
    return this.systemSpeech.listVoices();
  }

  waitForConfigPersistence(): Promise<void> {
    return this.appSettings.waitForPersistence();
  }

  loadModelOptions(): void {
    this.runtime.loadModelOptions(
      this.config.gatewayUrl,
      this.config.accessToken,
      this.config.profile
    );
  }

  switchRuntimeModel(providerId: string, modelId: string): void {
    this.runtime.switchRuntimeModel(providerId, modelId);
  }

  setConfig(config: ClientConfig): boolean {
    const normalized = this.appSettings.normalize(config);
    const connectionChanged = normalized.gatewayUrl !== this.config.gatewayUrl ||
      normalized.accessToken !== this.config.accessToken ||
      normalized.profile !== this.config.profile;
    const speechChanged = normalized.speechBackend !== this.config.speechBackend ||
      normalized.voicePerson !== this.config.voicePerson ||
      normalized.speechRate !== this.config.speechRate;
    const speakerphoneChanged = normalized.speakerphoneEnabled !== this.config.speakerphoneEnabled;
    this.config = normalized;
    this.snapshot.selectedProfile = this.config.profile;
    this.snapshot.speakerphoneEnabled = this.config.speakerphoneEnabled;
    this.snapshot.debugMode = this.config.debugMode;
    if (connectionChanged) {
      this.runtime.resetModelSelection();
    }
    this.persistConfig();
    this.notify();
    if (speakerphoneChanged) {
      this.applySpeakerphonePreference();
    }
    if (speechChanged && !connectionChanged && (this.input.isWanted() || this.output.isEnabled())) {
      this.restartVoiceClients().catch(() => undefined);
    }
    return connectionChanged;
  }

  switchProfile(profile: ProfileKey): void {
    if (profile === this.config.profile || this.snapshot.agentBusy) {
      return;
    }
    const restoreVoice = this.input.isWanted();
    const restoreVoiceOutput = this.output.isEnabled();
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
    this.conversation.clearMessages();
    this.snapshot.storedSessionId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.runtimeModel = '';
    this.snapshot.runtimeProvider = '';
    this.input.setWanted(restoreVoice);
    this.output.setEnabled(restoreVoiceOutput);
    this.notify();
    this.connect();
  }

  // Text input path. Also used after ASR final.
  submitText(text: string, existingMessage?: ChatMessage): boolean {
    const value = text.trim();
    if (value.length === 0) {
      return false;
    }
    if (this.input.isCloseMicPhrase(value)) {
      this.stopVoiceInput();
      this.snapshot.statusDetail = '已关闭麦克风，思考和播报继续';
      this.notify();
      return true;
    }
    if (this.input.isStopPhrase(value)) {
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
      this.conversation.commitAsrMessage(existingMessage);
    } else {
      this.conversation.appendMessage('user', queued ? '你 · 已排队' : '你', value);
    }
    this.snapshot.agentBusy = true;
    this.output.beginAgentTurn();
    this.snapshot.statusDetail = queued ? '已排队，等待当前任务完成' : 'Agent 正在思考';
    this.notify();
    this.runtime.submitPrompt(value, queued).then((result: Object) => {
      // Prompt accepted; agent events drive the UI from here.
    }).catch((error: BusinessError) => {
      if (this.discardInterruptedTurnEvents) {
        this.replacementPromptSubmitted = false;
      }
      const errorText = this.errorMessage(error, '提交请求失败');
      this.snapshot.agentBusy = false;
      this.output.endAgentTurn();
      this.snapshot.error = errorText;
      if (!queued) {
        this.conversation.failAssistantMessage(errorText);
      }
      this.notify();
    });
    return true;
  }

  toggleVoice(): void {
    if (this.input.isWanted()) {
      this.stopVoiceInput();
      return;
    }
    const outputWasEnabled = this.output.isEnabled();
    this.input.setWanted(true);
    this.output.setEnabled(true);
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
      this.output.handleMuteChanged(true);
    } else if (!this.output.isUsingSystemSpeech() && this.output.isEnabled()) {
      this.startRemoteVoiceClients();
    }
    this.notify();
  }

  newConversation(): void {
    this.input.cancelFinalization();
    this.resetInterruptedTurnGuard();
    this.output.stopForConversationChange();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.conversation.clearMessages();
    this.snapshot.storedSessionId = '';
    this.snapshot.runtimeSessionId = '';
    this.snapshot.conversationLoading = false;
    this.clearPendingProtocolRequests();
    if (this.snapshot.connection === 'online') {
      this.runtime.createSession(100).then((result: Object) => {
        this.onSessionCreated(result);
      }).catch(() => undefined);
    }
    this.notify();
  }

  async connect(): Promise<void> {
    if (this.snapshot.connection === 'connecting' || this.snapshot.connection === 'online') {
      return;
    }
    this.output.setEnabled(true);
    await this.runtime.connect(
      this.config.gatewayUrl,
      this.config.accessToken,
      this.config.profile
    );
  }

  disconnect(): void {
    this.resetInterruptedTurnGuard();
    this.cancelRemoteVoiceReconnects();
    this.stopVoice();
    this.runtime.disconnect();
    this.input.closeRemote();
    this.output.closeRemote();
    this.snapshot.runtimeSessionId = '';
    this.snapshot.conversationLoading = false;
    this.clearPendingProtocolRequests();
    this.notify();
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

  private commitProtocolReply(value: string, label: string, existingMessage?: ChatMessage): void {
    if (existingMessage !== undefined) {
      existingMessage.text = value;
      existingMessage.label = label;
      existingMessage.status = 'submitted';
      existingMessage.transient = false;
      existingMessage.revision += 1;
      this.conversation.commitAsrMessage(existingMessage);
      return;
    }
    const message = this.conversation.appendMessage('user', label, value);
    message.status = 'submitted';
  }

  private consumePendingProtocolReply(value: string, existingMessage?: ChatMessage): boolean {
    if (this.snapshot.approvalPending) {
      if (this.conversation.isApprovalResponseInFlight()) {
        this.conversation.discardAsrPreview();
        this.snapshot.statusDetail = '审批回复正在提交';
        this.notify();
        return true;
      }
      const allow = this.isApprovalAllowPhrase(value);
      const deny = this.isApprovalDenyPhrase(value);
      if (allow || deny) {
        this.commitProtocolReply(value, '你 · 审批回复', existingMessage);
        this.output.stopProtocolPromptPlayback();
        this.respondApproval(allow);
        return true;
      }
      this.commitProtocolReply(value, '你 · 未识别为审批回复', existingMessage);
      const reminder = '审批仍在等待，请只回复“同意”或“取消”。';
      this.conversation.appendMessage('assistant', this.agentName(this.snapshot.selectedProfile), reminder);
      this.output.replaceProtocolPromptSpeech(reminder);
      return true;
    }
    if (this.snapshot.clarifyPending) {
      if (this.conversation.isClarifyResponseInFlight()) {
        this.conversation.discardAsrPreview();
        this.snapshot.statusDetail = '补充回复正在提交';
        this.notify();
        return true;
      }
      this.commitProtocolReply(value, '你 · 补充回复', existingMessage);
      this.output.stopProtocolPromptPlayback();
      this.respondClarify(value);
      return true;
    }
    return false;
  }

  private clearPendingProtocolRequests(): void {
    this.conversation.clearPendingProtocolRequests();
  }

  private interrupt(displayText: string, existingMessage?: ChatMessage): void {
    const shouldPlayCue = this.output.prepareInterruptCue();
    if (existingMessage !== undefined) {
      existingMessage.text = displayText;
      existingMessage.label = '你 · 已停止';
      existingMessage.status = 'stopped';
      existingMessage.transient = false;
      existingMessage.revision += 1;
      this.conversation.commitAsrMessage(existingMessage);
    } else {
      this.conversation.appendMessage('user', '你 · 已停止', displayText);
    }
    this.discardInterruptedTurnEvents = true;
    this.replacementPromptSubmitted = false;
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.asrTranscript = '';
    this.output.stopForInterrupt();
    this.clearPendingProtocolRequests();
      this.conversation.completeInterruptedAssistantMessage();
    this.snapshot.agentBusy = false;
    this.snapshot.playback = 'none';
    if (shouldPlayCue) {
      this.output.playStopCue();
    }
    this.snapshot.statusDetail = '已停止当前任务';
    this.notify();
    if (this.snapshot.connection !== 'online' || this.snapshot.runtimeSessionId.length === 0) {
      return;
    }
    this.runtime.interrupt().catch((error: BusinessError) => {
      this.snapshot.error = this.errorMessage(error, '停止请求失败');
      this.notify();
    });
  }

  stopCurrentTask(): void {
    this.interrupt('停止');
  }

  canReplayMessage(message: ChatMessage): boolean {
    return this.output.canReplayMessage(message);
  }

  // Replay one assistant message without creating a Hermes turn.
  replayMessage(message: ChatMessage): void {
    this.output.replayMessage(message);
  }

  private ensureConnections(): void {
    if (this.snapshot.connection === 'online') {
      this.startVoiceClients();
      return;
    }
    this.connect();
  }

  private stopVoiceInput(): void {
    this.input.stop();
  }

  private stopVoice(): void {
    this.stopVoiceInput();
    this.output.disable();
  }

  private syncBackgroundVoiceTask(): void {
    let intent: BackgroundAudioIntent = 'none';
    if (this.output.prefersBackgroundPlayback()) {
      intent = 'playback';
    } else if (this.input.isWanted()) {
      intent = 'recording';
    } else if (this.output.hasBackgroundOutput()) {
      intent = 'playback';
    }
    this.backgroundAudioTask.sync(intent, (message: string): void => {
      this.snapshot.error = message;
      this.notify();
    });
  }

  private onRuntimeReady(): void {
    if (this.snapshot.storedSessionId.length > 0) {
      this.restoreSessionAfterReconnect(this.snapshot.storedSessionId);
      return;
    }
    this.runtime.createSession(100).then((result: Object) => {
      this.onSessionCreated(result);
    }).catch(() => undefined);
  }

  private onRuntimeUnavailable(message: string, shouldFinalizeTurn: boolean): void {
    hilog.error(CONTROLLER_LOG_DOMAIN, CONTROLLER_LOG_TAG, 'gateway unavailable: %{public}s', message);
    this.snapshot.agentBusy = false;
    this.output.endAgentTurn();
    this.snapshot.conversationLoading = false;
    if (shouldFinalizeTurn) {
      this.conversation.failAssistantMessage(message);
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
      this.syncRuntimeIdentity(info);
    }
    this.snapshot.conversationLoading = false;
    this.snapshot.modelSwitchStatus = '';
    this.snapshot.modelSwitchError = '';
    this.snapshot.statusTitle = '已连接';
    this.snapshot.statusDetail = this.snapshot.selectedProfile;
    this.snapshot.error = '';
    this.notify();
    this.listHistory();
    if (this.output.isEnabled()) {
      this.startVoiceClients();
    }
  }

  private startVoiceClients(): void {
    const capabilities: SystemSpeechCapabilities | undefined = this.systemSpeech?.getCapabilities();
    if (this.config.speechBackend === 'harmony_offline') {
      this.cancelRemoteVoiceReconnects();
      this.output.setUsingSystemSpeech(true);
      this.snapshot.asrBackend = 'harmony_offline';
      this.snapshot.ttsBackend = 'harmony_offline';
      this.input.closeRemote();
      this.output.closeRemote();
      if (!capabilities || !capabilities.tts) {
        this.snapshot.ttsState = 'error';
        this.snapshot.error = '设备不支持鸿蒙本地语音合成';
      } else if (this.snapshot.playback === 'none' && this.snapshot.ttsState !== 'speaking') {
        this.snapshot.ttsState = 'ready';
      }
      if (this.input.isWanted()) {
        if (capabilities && capabilities.stt) {
          this.input.startSystem();
        } else {
          this.input.failSystemRecognition('设备不支持鸿蒙本地语音识别', '检查本地识别能力');
        }
      }
      return;
    }
    this.output.setUsingSystemSpeech(false);
    this.snapshot.asrBackend = 'remote';
    this.snapshot.ttsBackend = 'remote';
    this.startRemoteVoiceClients();
  }

  private async restartVoiceClients(): Promise<void> {
    if (!this.input.isWanted() && !this.output.isEnabled()) {
      return;
    }
    this.cancelRemoteVoiceReconnects();
    this.output.stopForVoiceClientRestart();
    await this.input.prepareRestart();
    this.output.closeRemote();
    this.snapshot.ttsState = 'stopped';
    if (this.output.isEnabled() && this.snapshot.connection === 'online') {
      this.startVoiceClients();
    }
  }

  private startRemoteVoiceClients(): void {
    if (!this.output.isEnabled()) {
      return;
    }
    if (this.input.isWanted()) {
      this.snapshot.asrState = 'connecting';
    } else {
      this.snapshot.asrState = 'stopped';
    }
    if (!this.output.isRemoteConnected()) {
      this.snapshot.ttsState = 'connecting';
    }
    this.snapshot.error = '';
    this.notify();
    if (!this.output.isRemoteConnected() && !this.output.isRemoteConnecting()) {
      this.output.connectRemote(
        this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile),
        this.runtime.getCookie()
      );
    }
    if (!this.input.isWanted()) {
      return;
    }
    this.input.startRemote();
  }

  onSystemSpeechError(channel: string, message: string): void {
    if (!this.output.isUsingSystemSpeech()) {
      return;
    }
    if (channel === 'STT') {
      this.input.onSystemSpeechError(message);
      return;
    }
    this.output.onSystemSpeechError(message);
  }

  private handleRemoteTtsDisconnect(message: string): void {
    if (!this.canRecoverRemoteTts()) {
      this.output.clearActiveReplayState();
      this.snapshot.ttsState = this.output.isEnabled() && !this.config.muted ? 'error' : 'stopped';
      if (this.output.isEnabled() && !this.config.muted && !this.output.isUsingSystemSpeech()) {
        this.snapshot.error = message;
      }
      this.notify();
      return;
    }
    this.snapshot.ttsState = 'connecting';
    this.snapshot.statusDetail = '远端 TTS 正在恢复';
    this.snapshot.error = '';
    this.output.drainRemotePlaybackAfterDisconnect();
    this.scheduleRemoteTtsReconnect();
    this.notify();
  }

  private canRecoverRemoteTts(): boolean {
    return !this.output.isUsingSystemSpeech() && this.config.speechBackend === 'remote' &&
      this.output.isEnabled() && !this.config.muted && this.snapshot.connection === 'online' &&
      this.runtime.getCookie().length > 0;
  }

  private scheduleRemoteTtsReconnect(): void {
    if (!this.canRecoverRemoteTts() || this.output.isRemoteConnected() || this.output.isRemoteConnecting() ||
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
      if (!this.canRecoverRemoteTts() || this.output.isRemoteConnected() || this.output.isRemoteConnecting()) {
        return;
      }
      this.output.reconnectRemote(
        this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile),
        this.runtime.getCookie()
      );
    }, delay);
  }

  private cancelRemoteTtsReconnect(): void {
    if (this.remoteTtsReconnectTimer !== undefined) {
      clearTimeout(this.remoteTtsReconnectTimer);
      this.remoteTtsReconnectTimer = undefined;
    }
    this.remoteTtsReconnectAttempt = 0;
  }

  private cancelRemoteVoiceReconnects(): void {
    this.input.cancelRemoteReconnect();
    this.cancelRemoteTtsReconnect();
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
      this.output.beginAssistantStream();
      this.snapshot.statusDetail = 'Agent 正在思考';
      this.conversation.beginAssistantMessage();
      return;
    }
    if (type === 'message.delta') {
      const text = this.payloadText(data);
      const suppliedSpeechText = this.payloadSpeechText(data);
      this.conversation.appendAssistantDelta(text);
      if (text.length > 0) {
        this.snapshot.statusDetail = 'Agent 正在回复';
      }
      this.output.appendAssistantDelta(text, suppliedSpeechText);
      return;
    }
    if (type === 'message.complete') {
      const finalText = this.payloadText(data);
      const suppliedSpeechText = this.payloadSpeechText(data);
      const currentText = this.conversation.currentAssistantText();
      const rawArtifacts = data !== undefined ? data['artifacts'] : undefined;
      const model = data !== undefined && data['model'] !== undefined ? String(data['model']) : '';
      this.conversation.finishAssistantMessage(finalText, rawArtifacts, model);
      hilog.info(CONTROLLER_LOG_DOMAIN, CONTROLLER_LOG_TAG, 'assistant message finalized');
      this.output.finishAssistantStream(finalText, suppliedSpeechText, currentText);
      return;
    }
    if (type === 'thinking.delta' || type === 'reasoning.delta') {
      const text = data !== undefined && data['text'] !== undefined ? String(data['text']) : '';
      this.conversation.appendThinking(text);
      this.snapshot.statusDetail = text.length > 0 ? text : 'Agent 正在思考';
      this.notify();
      return;
    }
    if (type === 'tool.start' || type === 'tool.progress' || type === 'tool.complete') {
      const name = this.conversation.updateToolActivity(type, data);
      this.snapshot.statusDetail = name;
      this.notify();
      return;
    }
    if (type === 'approval.request') {
      this.output.endAgentTurn();
      const description = data !== undefined && data['description'] !== undefined
        ? String(data['description']).trim() : 'Agent 请求执行高风险操作';
      const command = data !== undefined && data['command'] !== undefined
        ? String(data['command']).trim() : '';
      if (this.conversation.beginApproval(description, command)) {
        const prompt = this.approvalConversationText(description, command);
        this.conversation.appendMessage('assistant', this.agentName(this.snapshot.selectedProfile), prompt);
        this.output.speakProtocolPrompt(this.approvalSpeechText(description, command));
      }
      this.notify();
      return;
    }
    if (type === 'clarify.request') {
      this.output.endAgentTurn();
      const requestId = data !== undefined && data['request_id'] !== undefined
        ? String(data['request_id']) : '';
      const question = data !== undefined && data['question'] !== undefined
        ? String(data['question']).trim() : '请补充信息';
      const choices = data !== undefined ? data['choices'] : undefined;
      const parsedChoices = Array.isArray(choices)
        ? choices.map((choice: Object): string => String(choice).trim())
          .filter((choice: string): boolean => choice.length > 0) : [];
      if (this.conversation.beginClarify(requestId, question, parsedChoices)) {
        const prompt = this.clarifyConversationText(question, parsedChoices);
        this.conversation.appendMessage('assistant', this.agentName(this.snapshot.selectedProfile), prompt);
        this.output.speakProtocolPrompt(prompt);
      }
      this.notify();
      return;
    }
    if (type === 'status.update') {
      const text = data !== undefined && data['text'] !== undefined
        ? String(data['text']) : data !== undefined && data['kind'] !== undefined
          ? String(data['kind']) : '';
      this.snapshot.statusDetail = text;
      this.conversation.updateStatusActivity(text);
      this.notify();
      return;
    }
    if (type === 'session.info') {
      this.syncRuntimeIdentity(data);
      this.conversation.syncPendingAssistantIdentity();
      this.notify();
      return;
    }
    if (type === 'error') {
      const message = data !== undefined && data['message'] !== undefined ? String(data['message']) : 'Agent错误';
      this.snapshot.agentBusy = false;
      this.output.endAgentTurn();
      this.snapshot.statusDetail = '';
      this.snapshot.error = message;
      this.conversation.failAssistantMessage(message);
      this.notify();
    }
  }

  private resetInterruptedTurnGuard(): void {
    this.discardInterruptedTurnEvents = false;
    this.replacementPromptSubmitted = false;
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
    if (!this.snapshot.approvalPending || this.conversation.isApprovalResponseInFlight()) {
      return;
    }
    const sessionId = this.snapshot.runtimeSessionId;
    this.conversation.setApprovalResponseInFlight(true);
    this.snapshot.statusDetail = allow ? '正在提交同意' : '正在提交取消';
    this.notify();
    this.runtime.respondApproval(allow ? 'session' : 'deny').then(() => {
      if (sessionId !== this.snapshot.runtimeSessionId) {
        return;
      }
      this.conversation.clearApproval();
      this.snapshot.statusDetail = allow ? '已同意当前操作' : '已取消当前操作';
      this.notify();
    }).catch((error: BusinessError) => {
      if (sessionId !== this.snapshot.runtimeSessionId) {
        return;
      }
      this.conversation.setApprovalResponseInFlight(false);
      this.snapshot.error = this.errorMessage(error, '审批回复发送失败');
      this.notify();
    });
  }

  respondClarify(answer: string): void {
    const value = answer.trim();
    if (value.length === 0 || !this.snapshot.clarifyPending || this.conversation.isClarifyResponseInFlight()) {
      return;
    }
    const requestId = this.snapshot.clarifyRequestId;
    this.conversation.setClarifyResponseInFlight(true);
    this.snapshot.statusDetail = '正在提交补充回复';
    this.notify();
    this.runtime.respondClarify(requestId, value).then(() => {
      if (requestId !== this.snapshot.clarifyRequestId) {
        return;
      }
      this.conversation.clearClarify();
      this.snapshot.statusDetail = '已提交补充回复';
      this.notify();
    }).catch((error: BusinessError) => {
      if (requestId !== this.snapshot.clarifyRequestId) {
        return;
      }
      this.conversation.setClarifyResponseInFlight(false);
      this.snapshot.error = this.errorMessage(error, '补充回复发送失败');
      this.notify();
    });
  }

  listHistory(limit: number = 20): void {
    if (this.snapshot.connection !== 'online' || this.snapshot.historyLoading) {
      return;
    }
    this.snapshot.historyLoading = true;
    this.notify();
    this.runtime.listSessions(limit).then((result: Object) => {
      this.snapshot.historyLimit = limit;
      const sessions = this.conversation.parseHistorySessions(result);
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
    const restoreVoice = this.input.isWanted();
    const restoreVoiceOutput = this.output.isEnabled();
    this.resetInterruptedTurnGuard();
    this.stopVoice();
    this.input.setWanted(restoreVoice);
    this.output.setEnabled(restoreVoiceOutput);
    this.conversation.clearMessages();
    this.snapshot.runtimeSessionId = '';
    this.snapshot.storedSessionId = storedId;
    this.snapshot.conversationLoading = true;
    this.snapshot.error = '';
    this.notify();
    this.runtime.resumeSession(storedId, 100).then((result: Object) => {
      this.runtime.fetchSessionDetail(
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
    this.runtime.resumeSession(storedId, 100).then((result: Object) => {
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
        this.conversation.clearMessages();
        this.snapshot.error = '';
        this.runtime.createSession(100).then((result: Object) => {
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
    if (Array.isArray(messages)) {
      this.conversation.restoreSessionMessages(messages as Object[], this.snapshot.runtimeModel);
    } else {
      this.conversation.clearMessages();
    }
    this.snapshot.conversationLoading = false;
    this.onSessionCreated(result);
  }

  private syncRuntimeIdentity(data: Record<string, Object> | undefined): void {
    this.runtime.syncRuntimeIdentity(
      data,
      this.config.gatewayUrl,
      this.config.accessToken,
      this.config.profile
    );
  }

  private isSessionNotFound(error: BusinessError): boolean {
    const message = this.errorMessage(error, '').toLowerCase();
    return message.includes('session not found') ||
      message.includes('session does not exist') ||
      message.includes('会话不存在') ||
      message.includes('找不到会话');
  }


  deleteSession(storedId: string): void {
    if (storedId.length === 0 || storedId === this.snapshot.storedSessionId) {
      return;
    }
    this.runtime.deleteSession(storedId).then(() => {
      this.listHistory(this.snapshot.historyLimit);
    }).catch((error: BusinessError) => {
      this.snapshot.error = this.errorMessage(error, '历史会话删除失败');
      this.notify();
    });
  }

  private payloadSpeechText(data: Record<string, Object> | undefined): string {
    if (data !== undefined && typeof data['speech_text'] === 'string') {
      return String(data['speech_text']);
    }
    return '';
  }

  private agentName(profile: string): string {
    return this.runtime.agentDisplayName(profile);
  }

  private persistConfig(): void {
    this.appSettings.persist(this.config, (token: string): void => {
      this.snapshot.credentialState = token.length > 0 ? 'ready' : 'unconfigured';
      this.snapshot.credentialError = '';
    }, (): void => {
      this.snapshot.credentialState = 'storage_error';
      this.snapshot.credentialError = '访问口令未能写入并验证本地存储，请重新保存';
      this.snapshot.error = this.snapshot.credentialError;
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
    copy.credentialState = source.credentialState;
    copy.credentialError = source.credentialError;
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
    this.output.syncAudioCues();
    this.syncBackgroundVoiceTask();
    if (this.listener) {
      this.listener.onSnapshot(this.snapshotForUi());
    }
  }

}
