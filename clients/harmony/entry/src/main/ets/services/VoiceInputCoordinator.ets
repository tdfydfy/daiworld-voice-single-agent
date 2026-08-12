import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, SingleAgentSnapshot } from '../models/SingleAgentState';
import { ClientConfig } from './AppSettingsStore';
import { PcmCapture } from './PcmCapture';
import { AsrListener, StreamingAsrClient } from './StreamingAsrClient';
import { SystemSpeechService } from './SystemSpeechService';
import { VoiceOutputCoordinator } from './VoiceOutputCoordinator';

const STOP_PHRASES: string[] = ['停止', 'stop'];
const CLOSE_MIC_PHRASES: string[] = ['关闭话筒', '关闭麦克风', '关闭microphone', '暂停收音'];
const SYSTEM_ASR_STARTUP_TIMEOUT_MS = 15000;
const ASR_FINALIZATION_GRACE_MS = 1800;
const REMOTE_ASR_RECONNECT_DELAYS_MS: number[] = [250, 750, 1500, 3000];
const INPUT_LOG_DOMAIN = 0xD004;
const INPUT_LOG_TAG = 'VoiceInput';

export class VoiceInputCallbacks {
  private configCallback: () => ClientConfig;
  private notifyCallback: () => void;
  private backgroundStateCallback: () => void;
  private ensurePreviewCallback: () => ChatMessage;
  private currentPreviewCallback: () => ChatMessage | undefined;
  private discardPreviewCallback: () => void;
  private protocolReplyCallback: (value: string, preview?: ChatMessage) => boolean;
  private interruptCallback: (value: string, preview?: ChatMessage) => void;
  private submitCallback: (value: string, preview?: ChatMessage) => boolean;
  private approvalReplyCallback: (value: string) => boolean;
  private remoteUrlCallback: () => string;
  private cookieCallback: () => string;

  constructor(
    configCallback: () => ClientConfig,
    notifyCallback: () => void,
    backgroundStateCallback: () => void,
    ensurePreviewCallback: () => ChatMessage,
    currentPreviewCallback: () => ChatMessage | undefined,
    discardPreviewCallback: () => void,
    protocolReplyCallback: (value: string, preview?: ChatMessage) => boolean,
    interruptCallback: (value: string, preview?: ChatMessage) => void,
    submitCallback: (value: string, preview?: ChatMessage) => boolean,
    approvalReplyCallback: (value: string) => boolean,
    remoteUrlCallback: () => string,
    cookieCallback: () => string
  ) {
    this.configCallback = configCallback;
    this.notifyCallback = notifyCallback;
    this.backgroundStateCallback = backgroundStateCallback;
    this.ensurePreviewCallback = ensurePreviewCallback;
    this.currentPreviewCallback = currentPreviewCallback;
    this.discardPreviewCallback = discardPreviewCallback;
    this.protocolReplyCallback = protocolReplyCallback;
    this.interruptCallback = interruptCallback;
    this.submitCallback = submitCallback;
    this.approvalReplyCallback = approvalReplyCallback;
    this.remoteUrlCallback = remoteUrlCallback;
    this.cookieCallback = cookieCallback;
  }

  config(): ClientConfig {
    return this.configCallback();
  }

  notify(): void {
    this.notifyCallback();
  }

  syncBackgroundState(): void {
    this.backgroundStateCallback();
  }

  ensurePreview(): ChatMessage {
    return this.ensurePreviewCallback();
  }

  currentPreview(): ChatMessage | undefined {
    return this.currentPreviewCallback();
  }

  discardPreview(): void {
    this.discardPreviewCallback();
  }

  consumeProtocolReply(value: string, preview?: ChatMessage): boolean {
    return this.protocolReplyCallback(value, preview);
  }

  interrupt(value: string, preview?: ChatMessage): void {
    this.interruptCallback(value, preview);
  }

  submit(value: string, preview?: ChatMessage): boolean {
    return this.submitCallback(value, preview);
  }

  isApprovalReply(value: string): boolean {
    return this.approvalReplyCallback(value);
  }

  remoteUrl(): string {
    return this.remoteUrlCallback();
  }

  cookie(): string {
    return this.cookieCallback();
  }
}

class CoordinatorAsrListener extends AsrListener {
  private coordinator: VoiceInputCoordinator;

  constructor(coordinator: VoiceInputCoordinator) {
    super();
    this.coordinator = coordinator;
  }

  onReady(): void {
    this.coordinator.onRemoteReady();
  }

  onTranscript(text: string, interim: boolean, final: boolean): void {
    this.coordinator.onRemoteTranscript(text, interim, final);
  }

  onError(message: string): void {
    this.coordinator.onRemoteError(message);
  }

  onClosed(): void {
    this.coordinator.onRemoteClosed();
  }
}

// Owns microphone capture, local/remote recognition, utterance collection,
// and exact input control phrases. Hermes submission remains a facade callback.
export class VoiceInputCoordinator {
  private snapshot: SingleAgentSnapshot;
  private output: VoiceOutputCoordinator;
  private callbacks: VoiceInputCallbacks;
  private asr: StreamingAsrClient = new StreamingAsrClient();
  private capture: PcmCapture = new PcmCapture();
  private systemSpeech?: SystemSpeechService;
  private context?: common.UIAbilityContext;
  private wanted: boolean = false;
  private capturing: boolean = false;
  private systemRecognitionStarting: boolean = false;
  private systemRecognitionRestart?: number;
  private systemRecognitionReadyTimeout?: number;
  private systemRecognitionAttempt: number = 0;
  private systemRecognitionStartupPhase: string = '';
  private asrFinalizationTimer?: number;
  private asrPendingFinalText: string = '';
  private asrLatestInterimText: string = '';
  private remoteAsrReconnectTimer?: number;
  private remoteAsrReconnectAttempt: number = 0;

  constructor(
    snapshot: SingleAgentSnapshot,
    output: VoiceOutputCoordinator,
    callbacks: VoiceInputCallbacks
  ) {
    this.snapshot = snapshot;
    this.output = output;
    this.callbacks = callbacks;
    this.asr.setListener(new CoordinatorAsrListener(this));
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setSystemSpeech(systemSpeech: SystemSpeechService): void {
    this.systemSpeech = systemSpeech;
  }

  isWanted(): boolean {
    return this.wanted;
  }

  setWanted(wanted: boolean): void {
    this.wanted = wanted;
    this.snapshot.voiceEnabled = wanted;
  }

  isStopPhrase(text: string): boolean {
    const normalized = this.normalizeControlPhrase(text);
    for (const phrase of STOP_PHRASES) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  isCloseMicPhrase(text: string): boolean {
    const normalized = this.normalizeControlPhrase(text);
    for (const phrase of CLOSE_MIC_PHRASES) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  startRemote(): void {
    if (!this.wanted) {
      this.snapshot.asrState = 'stopped';
      return;
    }
    this.snapshot.asrState = 'connecting';
    this.asr.setListener(new CoordinatorAsrListener(this));
    if (!this.asr.isConnected() && !this.asr.isConnecting()) {
      this.asr.connect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    }
    this.startCapture();
  }

  startSystem(): void {
    if (!this.wanted || !this.output.isUsingSystemSpeech() || this.systemRecognitionStarting ||
      this.snapshot.asrState === 'listening') {
      return;
    }
    const speech = this.systemSpeech;
    if (!speech) {
      this.snapshot.asrState = 'stopped';
      this.snapshot.error = '本地语音服务尚未初始化';
      this.callbacks.notify();
      return;
    }
    const attempt = this.systemRecognitionAttempt + 1;
    this.systemRecognitionAttempt = attempt;
    this.systemRecognitionStarting = true;
    this.systemRecognitionStartupPhase = '准备本地识别';
    this.snapshot.asrState = 'connecting';
    this.snapshot.statusDetail = '本地 ASR：准备本地识别';
    this.snapshot.error = '';
    this.clearSystemRecognitionReadyTimeout();
    this.systemRecognitionReadyTimeout = setTimeout((): void => {
      this.systemRecognitionReadyTimeout = undefined;
      if (attempt === this.systemRecognitionAttempt && this.wanted && this.output.isUsingSystemSpeech() &&
        this.snapshot.asrState === 'connecting') {
        const phase = this.systemRecognitionStartupPhase.length > 0
          ? this.systemRecognitionStartupPhase : '未知启动阶段';
        this.failSystemRecognition('本地 ASR 启动超时，停在：' + phase, phase);
      }
    }, SYSTEM_ASR_STARTUP_TIMEOUT_MS);
    this.callbacks.notify();
    speech.startRecognition().then(() => {
      if (attempt !== this.systemRecognitionAttempt) {
        return;
      }
      this.systemRecognitionStarting = false;
      if (!this.wanted || !this.output.isUsingSystemSpeech()) {
        return;
      }
      this.snapshot.microphoneRoute = speech.getInputRouteLabel();
      this.callbacks.notify();
    }).catch((error: BusinessError) => {
      if (attempt !== this.systemRecognitionAttempt) {
        return;
      }
      this.systemRecognitionStarting = false;
      this.failSystemRecognition(this.errorMessage(error, '离线 STT 启动失败'), this.systemRecognitionStartupPhase);
    });
  }

  failSystemRecognition(reason: string, phase: string): void {
    this.finalizeAfterTermination();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStarting = false;
    this.clearSystemRecognitionReadyTimeout();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.wanted = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.microphoneRoute = '';
    this.callbacks.discardPreview();
    this.callbacks.syncBackgroundState();
    this.snapshot.statusDetail = phase.length > 0 ? '本地 ASR 已停止：' + phase : '本地 ASR 已停止';
    this.snapshot.error = reason;
    this.callbacks.notify();
    this.systemSpeech?.resetRecognition().catch(() => undefined);
  }

  onSystemRecognitionStartupPhase(phase: string): void {
    if (!this.output.isUsingSystemSpeech() || !this.wanted || this.snapshot.asrState !== 'connecting') {
      return;
    }
    this.systemRecognitionStartupPhase = phase;
    this.snapshot.statusDetail = '本地 ASR：' + phase;
    if (phase === '启动识别会话' || phase === '等待识别引擎 ready') {
      this.snapshot.microphoneRoute = this.systemSpeech?.getInputRouteLabel() ?? '';
    }
    this.callbacks.notify();
  }

  onMicrophoneRouteChanged(label: string): void {
    if (!this.wanted || label.length === 0 || this.snapshot.microphoneRoute === label) {
      return;
    }
    this.snapshot.microphoneRoute = label;
    this.callbacks.notify();
  }

  onSystemRecognitionState(active: boolean): void {
    if (!this.output.isUsingSystemSpeech()) {
      return;
    }
    if (active && !this.wanted) {
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
      this.callbacks.syncBackgroundState();
    }
    if (!active && this.snapshot.asrUtteranceActive) {
      this.queueFinal('', false);
    }
    this.callbacks.notify();
    if (!active && this.wanted && !this.systemRecognitionStarting) {
      this.scheduleSystemRecognitionRestart('');
    }
  }

  onSystemRecognitionResult(text: string, isFinal: boolean, isLast: boolean): void {
    if (!this.output.isUsingSystemSpeech()) {
      return;
    }
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected();
    }
    if (isFinal) {
      this.queueFinal(value, isLast);
    } else {
      this.updateInterim(value);
    }
  }

  onRecognitionAudioStart(): void {
    this.onUserSpeechDetected();
  }

  onSystemSpeechError(message: string): void {
    if (this.output.isUsingSystemSpeech()) {
      this.failSystemRecognition('STT：' + message, this.systemRecognitionStartupPhase);
    }
  }

  onRemoteReady(): void {
    this.cancelRemoteReconnect();
    this.snapshot.asrState = 'listening';
    this.snapshot.error = '';
    this.callbacks.notify();
  }

  onRemoteTranscript(text: string, interim: boolean, final: boolean): void {
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected();
    }
    if (final) {
      this.queueFinal(value, false);
    } else if (interim) {
      this.updateInterim(value);
    }
  }

  onRemoteError(message: string): void {
    this.handleRemoteDisconnect(message.length > 0 ? message : 'ASR 连接失败');
  }

  onRemoteClosed(): void {
    this.handleRemoteDisconnect('ASR 连接已断开');
  }

  stop(): void {
    this.wanted = false;
    this.cancelRemoteReconnect();
    this.cancelFinalization();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStartupPhase = '';
    this.callbacks.syncBackgroundState();
    this.snapshot.voiceEnabled = false;
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.microphoneRoute = '';
    this.callbacks.discardPreview();
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
      this.callbacks.notify();
    }).catch(() => undefined);
    if (this.output.isPausedForUser()) {
      this.output.clearPausedState();
      if (this.output.isEnabled() && !this.callbacks.config().muted) {
        this.output.resumePausedPlayback();
      }
    }
  }

  async prepareRestart(): Promise<void> {
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.clearSystemRecognitionReadyTimeout();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStartupPhase = '';
    this.systemRecognitionStarting = false;
    this.cancelRemoteReconnect();
    this.cancelFinalization();
    this.callbacks.discardPreview();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    if (this.systemSpeech) {
      await this.systemSpeech.stopRecognition(false).catch(() => undefined);
    }
    this.asr.close();
    await this.capture.stop().catch(() => undefined);
    this.capturing = false;
    this.snapshot.asrState = 'stopped';
  }

  closeRemote(): void {
    this.asr.close();
  }

  cancelFinalization(): void {
    if (this.asrFinalizationTimer !== undefined) {
      clearTimeout(this.asrFinalizationTimer);
      this.asrFinalizationTimer = undefined;
    }
    this.asrPendingFinalText = '';
    this.asrLatestInterimText = '';
  }

  cancelRemoteReconnect(): void {
    if (this.remoteAsrReconnectTimer !== undefined) {
      clearTimeout(this.remoteAsrReconnectTimer);
      this.remoteAsrReconnectTimer = undefined;
    }
    this.remoteAsrReconnectAttempt = 0;
  }

  private startCapture(): void {
    if (this.capturing) {
      return;
    }
    const context = this.context;
    if (!context) {
      this.snapshot.asrState = 'stopped';
      this.snapshot.error = '无法获取麦克风权限上下文';
      this.callbacks.notify();
      return;
    }
    this.capture.requestPermission(context).then((granted: boolean) => {
      if (!granted) {
        this.snapshot.error = '麦克风权限未授权';
        this.snapshot.asrState = 'stopped';
        this.callbacks.notify();
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
      if (!this.wanted) {
        this.capture.stop().catch(() => undefined);
        return;
      }
      this.capturing = true;
      this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
      this.snapshot.asrState = 'listening';
      this.callbacks.syncBackgroundState();
      this.callbacks.notify();
    }).catch((error: BusinessError) => {
      this.snapshot.asrState = 'stopped';
      this.snapshot.microphoneRoute = '';
      this.asr.close();
      this.snapshot.error = error.message;
      this.callbacks.notify();
    });
  }

  private handleRemoteDisconnect(message: string): void {
    if (!this.canRecoverRemote()) {
      this.snapshot.asrState = 'stopped';
      this.finalizeAfterTermination();
      if (this.wanted && !this.output.isUsingSystemSpeech()) {
        this.snapshot.error = message;
      }
      this.callbacks.notify();
      return;
    }
    if (this.snapshot.asrUtteranceActive && this.combinedText().length === 0) {
      this.discardAndResumePlayback();
    }
    this.snapshot.asrState = 'connecting';
    this.snapshot.statusDetail = '远端 ASR 正在恢复';
    this.snapshot.error = '';
    this.scheduleRemoteReconnect();
    this.callbacks.notify();
  }

  private canRecoverRemote(): boolean {
    return !this.output.isUsingSystemSpeech() && this.callbacks.config().speechBackend === 'remote' &&
      this.wanted && this.snapshot.connection === 'online' && this.callbacks.cookie().length > 0;
  }

  private scheduleRemoteReconnect(): void {
    if (!this.canRecoverRemote() || this.asr.isConnected() || this.asr.isConnecting() ||
      this.remoteAsrReconnectTimer !== undefined) {
      return;
    }
    const index = Math.min(this.remoteAsrReconnectAttempt, REMOTE_ASR_RECONNECT_DELAYS_MS.length - 1);
    const delay = REMOTE_ASR_RECONNECT_DELAYS_MS[index];
    this.remoteAsrReconnectAttempt = Math.min(
      this.remoteAsrReconnectAttempt + 1,
      REMOTE_ASR_RECONNECT_DELAYS_MS.length
    );
    this.remoteAsrReconnectTimer = setTimeout((): void => {
      this.remoteAsrReconnectTimer = undefined;
      if (!this.canRecoverRemote() || this.asr.isConnected() || this.asr.isConnecting()) {
        return;
      }
      this.asr.setListener(new CoordinatorAsrListener(this));
      this.asr.reconnect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    }, delay);
  }

  private scheduleSystemRecognitionRestart(reason: string): void {
    if (!this.wanted || !this.output.isUsingSystemSpeech()) {
      return;
    }
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
    }
    if (reason.length > 0) {
      this.snapshot.statusDetail = '本地识别正在恢复';
      this.callbacks.notify();
    }
    this.systemRecognitionRestart = setTimeout((): void => {
      this.systemRecognitionRestart = undefined;
      this.startSystem();
    }, 150);
  }

  private onUserSpeechDetected(): void {
    if (!this.wanted) {
      return;
    }
    if (!this.snapshot.asrUtteranceActive) {
      this.snapshot.asrUtteranceActive = true;
      this.callbacks.ensurePreview();
    }
    this.output.onUserSpeechDetected();
  }

  private onFinal(text: string): void {
    const value = this.mergeSegments(this.combinedText(), text.trim());
    this.cancelFinalization();
    const preview = this.callbacks.currentPreview();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    if (this.snapshot.asrState === 'finalizing') {
      this.snapshot.asrState = this.wanted ? 'listening' : 'stopped';
    }
    if (this.isCloseMicPhrase(value)) {
      this.callbacks.discardPreview();
      this.stop();
      this.snapshot.statusDetail = '已关闭麦克风，思考和播报继续';
      this.callbacks.notify();
      return;
    }
    if (!this.hasSemanticContent(value)) {
      this.discardAndResumePlayback();
      return;
    }
    if (this.isStopPhrase(value)) {
      this.callbacks.interrupt(value, preview);
      return;
    }
    if (this.callbacks.consumeProtocolReply(value, preview)) {
      return;
    }
    if (value.length > 0) {
      const accepted = this.callbacks.submit(value, preview);
      if (accepted && this.output.isEnabled() && !this.callbacks.config().muted) {
        this.output.playAcceptedCue();
      }
    }
    if (this.output.isPausedForUser()) {
      this.output.resumePausedPlayback();
      return;
    }
    this.callbacks.discardPreview();
    this.callbacks.notify();
  }

  private updateInterim(text: string): void {
    this.asrLatestInterimText = text.trim();
    const value = this.combinedText();
    if (value.length === 0) {
      return;
    }
    this.snapshot.asrTranscript = value;
    if (this.wanted) {
      this.snapshot.asrState = 'listening';
    }
    const preview = this.callbacks.ensurePreview();
    preview.label = '你 · 正在识别';
    preview.text = value;
    preview.revision += 1;
    this.scheduleFinalization();
    this.callbacks.notify();
  }

  private queueFinal(text: string, isLast: boolean): void {
    const value = text.trim();
    if (value.length > 0) {
      this.asrPendingFinalText = this.mergeSegments(this.asrPendingFinalText, value);
    } else if (this.asrPendingFinalText.length === 0 && this.asrLatestInterimText.length > 0) {
      this.asrPendingFinalText = this.asrLatestInterimText;
    }
    this.asrLatestInterimText = '';
    const combined = this.combinedText();
    if (combined.length === 0) {
      this.discardAndResumePlayback();
      return;
    }
    if (this.shouldFinalizeImmediately(combined)) {
      this.onFinal(combined);
      return;
    }
    this.snapshot.asrTranscript = combined;
    this.snapshot.asrUtteranceActive = true;
    this.snapshot.asrState = 'finalizing';
    const preview = this.callbacks.ensurePreview();
    preview.label = '你 · 等待收句';
    preview.text = combined;
    preview.revision += 1;
    hilog.info(
      INPUT_LOG_DOMAIN,
      INPUT_LOG_TAG,
      'ASR final buffered length=%{public}d isLast=%{public}s graceMs=%{public}d',
      combined.length,
      String(isLast),
      ASR_FINALIZATION_GRACE_MS
    );
    this.scheduleFinalization();
    this.callbacks.notify();
  }

  private scheduleFinalization(): void {
    if (this.asrFinalizationTimer !== undefined) {
      clearTimeout(this.asrFinalizationTimer);
    }
    this.asrFinalizationTimer = setTimeout((): void => {
      this.asrFinalizationTimer = undefined;
      this.onFinal(this.combinedText());
    }, ASR_FINALIZATION_GRACE_MS);
  }

  private finalizeAfterTermination(): void {
    if (!this.snapshot.asrUtteranceActive && this.combinedText().length === 0) {
      return;
    }
    const preview = this.callbacks.currentPreview();
    const previewText = preview !== undefined ? preview.text.trim() : '';
    const value = this.mergeSegments(this.combinedText(), previewText);
    if (this.hasSemanticContent(value)) {
      this.onFinal(value);
      return;
    }
    this.discardAndResumePlayback();
  }

  private shouldFinalizeImmediately(text: string): boolean {
    return this.isStopPhrase(text) || this.isCloseMicPhrase(text) || this.snapshot.clarifyPending ||
      (this.snapshot.approvalPending && this.callbacks.isApprovalReply(text));
  }

  private combinedText(): string {
    return this.mergeSegments(this.asrPendingFinalText, this.asrLatestInterimText);
  }

  private mergeSegments(previous: string, incoming: string): string {
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

  private discardAndResumePlayback(): void {
    this.cancelFinalization();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.callbacks.discardPreview();
    if (this.output.isPausedForUser()) {
      this.output.resumePausedPlayback();
      return;
    }
    this.callbacks.notify();
  }

  private normalizeControlPhrase(text: string): string {
    return text.trim().toLowerCase().replace(/[\s\p{P}\p{S}]/gu, '');
  }

  private hasSemanticContent(text: string): boolean {
    return /[\p{L}\p{N}]/u.test(String(text || ''));
  }

  private clearSystemRecognitionReadyTimeout(): void {
    if (this.systemRecognitionReadyTimeout !== undefined) {
      clearTimeout(this.systemRecognitionReadyTimeout);
      this.systemRecognitionReadyTimeout = undefined;
    }
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }
}
