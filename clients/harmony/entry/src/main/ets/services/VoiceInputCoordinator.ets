import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, InputRouting, SingleAgentSnapshot } from '../models/SingleAgentState';
import { ClientConfig } from './AppSettingsStore';
import { CaptureSupervisor, CaptureSupervisorCallbacks } from './CaptureSupervisor';
import { RecoveryBudget } from './RecoveryBudget';
import { AsrListener, StreamingAsrClient } from './StreamingAsrClient';
import { SystemAsrEngine } from './SystemAsrEngine';
import { VoiceControlPolicy } from './VoiceControlPolicy';
import { VoiceOutputCoordinator } from './VoiceOutputCoordinator';

const SYSTEM_ASR_STARTUP_TIMEOUT_MS = 15000;
const ASR_FINALIZATION_GRACE_MS = 1800;
const REMOTE_ASR_RECONNECT_DELAYS_MS: number[] = [250, 750, 1500, 3000];
const REMOTE_ASR_STABLE_RESET_MS = 10000;
const INPUT_LOG_DOMAIN = 0xD004;
const INPUT_LOG_TAG = 'VoiceInput';

export class VoiceInputCallbacks {
  private configCallback: () => ClientConfig;
  private notifyCallback: () => void;
  private backgroundStateCallback: () => void;
  private recordingReadyCallback: () => Promise<void>;
  private ensurePreviewCallback: () => ChatMessage;
  private currentPreviewCallback: () => ChatMessage | undefined;
  private discardPreviewCallback: () => void;
  private protocolReplyCallback: (value: string, preview?: ChatMessage) => boolean;
  private interruptCallback: (value: string, preview?: ChatMessage) => void;
  private exitApplicationCallback: () => void;
  private submitCallback: (value: string, preview?: ChatMessage) => boolean;
  private approvalReplyCallback: (value: string) => boolean;
  private remoteUrlCallback: () => string;
  private cookieCallback: () => string;

  constructor(
    configCallback: () => ClientConfig,
    notifyCallback: () => void,
    backgroundStateCallback: () => void,
    recordingReadyCallback: () => Promise<void>,
    ensurePreviewCallback: () => ChatMessage,
    currentPreviewCallback: () => ChatMessage | undefined,
    discardPreviewCallback: () => void,
    protocolReplyCallback: (value: string, preview?: ChatMessage) => boolean,
    interruptCallback: (value: string, preview?: ChatMessage) => void,
    exitApplicationCallback: () => void,
    submitCallback: (value: string, preview?: ChatMessage) => boolean,
    approvalReplyCallback: (value: string) => boolean,
    remoteUrlCallback: () => string,
    cookieCallback: () => string
  ) {
    this.configCallback = configCallback;
    this.notifyCallback = notifyCallback;
    this.backgroundStateCallback = backgroundStateCallback;
    this.recordingReadyCallback = recordingReadyCallback;
    this.ensurePreviewCallback = ensurePreviewCallback;
    this.currentPreviewCallback = currentPreviewCallback;
    this.discardPreviewCallback = discardPreviewCallback;
    this.protocolReplyCallback = protocolReplyCallback;
    this.interruptCallback = interruptCallback;
    this.exitApplicationCallback = exitApplicationCallback;
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

  ensureRecordingReady(): Promise<void> {
    return this.recordingReadyCallback();
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

  exitApplication(): void {
    this.exitApplicationCallback();
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
  private epoch: number;

  constructor(coordinator: VoiceInputCoordinator, epoch: number) {
    super();
    this.coordinator = coordinator;
    this.epoch = epoch;
  }

  onReady(): void {
    this.coordinator.onRemoteReady(this.epoch);
  }

  onTranscript(text: string, interim: boolean, final: boolean): void {
    this.coordinator.onRemoteTranscript(this.epoch, text, interim, final);
  }

  onError(message: string): void {
    this.coordinator.onRemoteError(this.epoch, message);
  }

  onClosed(): void {
    this.coordinator.onRemoteClosed(this.epoch);
  }
}

// Owns microphone capture, local/remote recognition, utterance collection,
// and exact input control phrases. Hermes submission remains a facade callback.
export class VoiceInputCoordinator {
  private snapshot: SingleAgentSnapshot;
  private output: VoiceOutputCoordinator;
  private callbacks: VoiceInputCallbacks;
  private asr: StreamingAsrClient = new StreamingAsrClient();
  private capture: CaptureSupervisor;
  private systemAsr?: SystemAsrEngine;
  private context?: common.UIAbilityContext;
  private epoch: number = 0;
  private submissionFrozen: boolean = false;
  private wanted: boolean = false;
  private capturing: boolean = false;
  private captureReady: boolean = false;
  private systemAsrReady: boolean = false;
  private systemRecognitionStarting: boolean = false;
  private systemRecognitionRestart?: number;
  private systemRecognitionReadyTimeout?: number;
  private systemRecognitionAttempt: number = 0;
  private systemRecognitionStartupPhase: string = '';
  private asrFinalizationTimer?: number;
  private asrPendingFinalText: string = '';
  private asrLatestInterimText: string = '';
  private remoteAsrReconnectTimer?: number;
  private remoteAsrStableTimer?: number;
  private remoteAsrRecoveryBudget: RecoveryBudget = new RecoveryBudget(
    REMOTE_ASR_RECONNECT_DELAYS_MS.length
  );
  private captureStartGeneration: number = 0;

  constructor(
    snapshot: SingleAgentSnapshot,
    output: VoiceOutputCoordinator,
    callbacks: VoiceInputCallbacks
  ) {
    this.snapshot = snapshot;
    this.output = output;
    this.callbacks = callbacks;
    this.capture = new CaptureSupervisor(new CaptureSupervisorCallbacks(
      (state: string, reason: string): void => this.onRemoteCaptureState(state, reason),
      (message: string): void => this.onRemoteCaptureExhausted(message)
    ));
    this.asr.setListener(new CoordinatorAsrListener(this, this.epoch));
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setSystemAsr(systemAsr: SystemAsrEngine): void {
    this.systemAsr = systemAsr;
  }

  bindEpoch(epoch: number): Promise<void> {
    this.epoch = epoch;
    this.submissionFrozen = true;
    this.cancelFinalization();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.callbacks.discardPreview();
    if (!this.wanted) {
      return Promise.resolve();
    }
    if (this.output.isUsingSystemSpeech()) {
      return this.systemAsr?.bindEpoch(epoch) ?? Promise.resolve();
    }
    this.cancelRemoteReconnect();
    this.asr.close();
    this.asr.setListener(new CoordinatorAsrListener(this, epoch));
    this.asr.connect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    return Promise.resolve();
  }

  resumeEpoch(epoch: number): void {
    if (epoch === this.epoch) {
      this.submissionFrozen = false;
    }
  }

  isWanted(): boolean {
    return this.wanted;
  }

  inputRouting(): InputRouting {
    return this.wanted ? this.snapshot.inputRouting : 'off';
  }

  isCommandsOnly(): boolean {
    return this.wanted && this.snapshot.inputRouting === 'commands_only';
  }

  setWanted(wanted: boolean): void {
    if (this.wanted !== wanted && !wanted) {
      this.captureStartGeneration += 1;
    }
    this.wanted = wanted;
    this.snapshot.inputRouting = wanted ? 'conversation' : 'off';
    this.snapshot.voiceEnabled = wanted;
  }

  isStopPhrase(text: string): boolean {
    return VoiceControlPolicy.resolve(text) === 'stop_task';
  }

  isCloseMicPhrase(text: string): boolean {
    return VoiceControlPolicy.resolve(text) === 'close_microphone';
  }

  isOpenMicPhrase(text: string): boolean {
    return VoiceControlPolicy.resolve(text) === 'open_microphone';
  }

  isExitPhrase(text: string): boolean {
    return VoiceControlPolicy.resolve(text) === 'exit_application';
  }

  closeConversationRoute(): boolean {
    if (!this.wanted || this.snapshot.inputRouting === 'commands_only') {
      return false;
    }
    this.snapshot.inputRouting = 'commands_only';
    this.snapshot.voiceEnabled = false;
    this.snapshot.statusDetail = '话筒已关闭，仅响应系统口令';
    this.callbacks.syncBackgroundState();
    this.callbacks.notify();
    return true;
  }

  openConversationRoute(): boolean {
    if (!this.wanted || this.snapshot.inputRouting === 'conversation') {
      return false;
    }
    this.snapshot.inputRouting = 'conversation';
    this.snapshot.voiceEnabled = true;
    this.snapshot.statusDetail = '话筒已打开，可以继续对话';
    this.callbacks.syncBackgroundState();
    this.callbacks.notify();
    return true;
  }

  startRemote(): void {
    if (!this.wanted) {
      this.snapshot.asrState = 'stopped';
      return;
    }
    this.snapshot.asrState = 'connecting';
    this.asr.setListener(new CoordinatorAsrListener(this, this.epoch));
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
    const engine = this.systemAsr;
    if (!engine) {
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
    const epoch = this.epoch;
    this.callbacks.ensureRecordingReady().then((): Promise<void> => {
      if (!this.isSystemRecognitionStartCurrent(attempt)) {
        this.callbacks.syncBackgroundState();
        return Promise.resolve();
      }
      return engine.start(epoch);
    }).then(() => {
      if (!this.isSystemRecognitionStartCurrent(attempt)) {
        this.callbacks.syncBackgroundState();
        return;
      }
      this.systemRecognitionStarting = false;
      this.startCapture();
      this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
      this.callbacks.notify();
    }).catch((error: BusinessError) => {
      if (!this.isSystemRecognitionStartCurrent(attempt)) {
        this.callbacks.syncBackgroundState();
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
    this.systemAsrReady = false;
    this.clearSystemRecognitionReadyTimeout();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.wanted = false;
    this.captureStartGeneration += 1;
    this.capturing = false;
    this.captureReady = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.inputRouting = 'off';
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.microphoneRoute = '';
    this.callbacks.discardPreview();
    this.callbacks.syncBackgroundState();
    this.snapshot.statusDetail = phase.length > 0 ? '本地 ASR 已停止：' + phase : '本地 ASR 已停止';
    this.snapshot.error = reason;
    this.callbacks.notify();
    this.systemAsr?.stop(this.epoch, false).catch(() => undefined);
    this.capture.stop().catch(() => undefined);
  }

  onSystemRecognitionStartupPhase(epoch: number, phase: string): void {
    if (epoch !== this.epoch || !this.output.isUsingSystemSpeech() || !this.wanted) {
      return;
    }
    if (phase === '音频采集正在恢复') {
      this.snapshot.asrState = 'connecting';
      this.snapshot.statusDetail = '本地 ASR：音频采集正在恢复';
      this.callbacks.notify();
      return;
    }
    if (phase === '音频采集已恢复') {
      this.snapshot.statusDetail = '本地 ASR：音频采集已恢复';
      this.callbacks.notify();
      return;
    }
    if (this.snapshot.asrState !== 'connecting') {
      return;
    }
    this.systemRecognitionStartupPhase = phase;
    this.snapshot.statusDetail = '本地 ASR：' + phase;
    if (phase === '启动识别会话' || phase === '等待识别引擎 ready') {
      this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
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

  onSystemRecognitionState(epoch: number, active: boolean): void {
    if (epoch !== this.epoch || !this.output.isUsingSystemSpeech()) {
      return;
    }
    if (active && !this.wanted) {
      this.systemAsr?.stop(epoch, false).catch(() => undefined);
      return;
    }
    this.systemAsrReady = active;
    this.snapshot.asrState = active && this.captureReady ? 'listening' : (this.wanted ? 'connecting' : 'stopped');
    if (active) {
      this.clearSystemRecognitionReadyTimeout();
      this.systemRecognitionStarting = false;
      this.systemRecognitionStartupPhase = '';
      this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
      this.snapshot.statusDetail = this.captureReady ? '本地 ASR 监听中' : '本地 ASR：音频采集正在启动';
      this.callbacks.syncBackgroundState();
    }
    if (!active && this.snapshot.asrUtteranceActive) {
      this.queueFinal(epoch, '', false);
    }
    this.callbacks.notify();
    if (!active && this.wanted && !this.systemRecognitionStarting) {
      this.scheduleSystemRecognitionRestart('');
    }
  }

  onSystemRecognitionResult(epoch: number, text: string, isFinal: boolean, isLast: boolean): void {
    if (epoch !== this.epoch || !this.output.isUsingSystemSpeech()) {
      return;
    }
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected(epoch);
    }
    if (isFinal) {
      this.queueFinal(epoch, value, isLast);
    } else {
      this.updateInterim(epoch, value);
    }
  }

  onRecognitionAudioStart(epoch: number): void {
    this.onUserSpeechDetected(epoch);
  }

  onSystemSpeechError(epoch: number, message: string): void {
    if (epoch === this.epoch && this.output.isUsingSystemSpeech()) {
      this.failSystemRecognition('STT：' + message, this.systemRecognitionStartupPhase);
    }
  }

  onRemoteReady(epoch: number): void {
    if (epoch !== this.epoch) {
      return;
    }
    this.markRemoteReady(epoch);
    this.snapshot.asrState = this.captureReady ? 'listening' : 'connecting';
    if (!this.captureReady) {
      this.snapshot.statusDetail = '远端 ASR：音频采集正在恢复';
    }
    this.snapshot.error = '';
    this.callbacks.notify();
  }

  onRemoteTranscript(epoch: number, text: string, interim: boolean, final: boolean): void {
    if (epoch !== this.epoch) {
      return;
    }
    const value = text.trim();
    if (value.length > 0) {
      this.onUserSpeechDetected(epoch);
    }
    if (final) {
      this.queueFinal(epoch, value, false);
    } else if (interim) {
      this.updateInterim(epoch, value);
    }
  }

  onRemoteError(epoch: number, message: string): void {
    if (epoch !== this.epoch) {
      return;
    }
    this.handleRemoteDisconnect(message.length > 0 ? message : 'ASR 连接失败');
  }

  onRemoteClosed(epoch: number): void {
    if (epoch !== this.epoch) {
      return;
    }
    this.handleRemoteDisconnect('ASR 连接已断开');
  }

  async stop(): Promise<void> {
    this.wanted = false;
    this.submissionFrozen = false;
    this.captureStartGeneration += 1;
    this.cancelRemoteReconnect();
    this.cancelFinalization();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStartupPhase = '';
    this.callbacks.syncBackgroundState();
    this.snapshot.voiceEnabled = false;
    this.snapshot.inputRouting = 'off';
    this.snapshot.asrState = 'stopped';
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.microphoneRoute = '';
    this.captureReady = false;
    this.systemAsrReady = false;
    this.callbacks.discardPreview();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.clearSystemRecognitionReadyTimeout();
    this.systemRecognitionStarting = false;
    const systemStop = this.systemAsr?.stop(this.epoch, false) ?? Promise.resolve();
    this.asr.stop();
    this.asr.close();
    await Promise.all([systemStop.catch(() => undefined), this.capture.stop().catch(() => undefined)]);
    this.capturing = false;
    this.callbacks.notify();
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
    this.captureStartGeneration += 1;
    this.systemRecognitionStartupPhase = '';
    this.systemRecognitionStarting = false;
    this.cancelRemoteReconnect();
    this.cancelFinalization();
    this.callbacks.discardPreview();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    if (this.systemAsr) {
      await this.systemAsr.stop(this.epoch, false).catch(() => undefined);
    }
    this.asr.close();
    await this.capture.stop().catch(() => undefined);
    this.capturing = false;
    this.captureReady = false;
    this.snapshot.asrState = 'stopped';
  }

  async prepareBackendSwitch(epoch: number): Promise<void> {
    this.epoch = epoch;
    this.submissionFrozen = true;
    this.cancelRemoteReconnect();
    this.cancelFinalization();
    this.systemRecognitionAttempt += 1;
    this.systemRecognitionStartupPhase = '';
    this.systemRecognitionStarting = false;
    this.systemAsrReady = false;
    this.clearSystemRecognitionReadyTimeout();
    if (this.systemRecognitionRestart !== undefined) {
      clearTimeout(this.systemRecognitionRestart);
      this.systemRecognitionRestart = undefined;
    }
    this.callbacks.discardPreview();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    this.snapshot.asrState = this.wanted ? 'connecting' : 'stopped';
    this.asr.close();
    await (this.systemAsr?.stop(epoch, false) ?? Promise.resolve()).catch(() => undefined);
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
    this.clearRemoteStableTimer();
    this.remoteAsrRecoveryBudget.reset();
  }

  private startCapture(): void {
    if (this.capturing) {
      return;
    }
    const generation = ++this.captureStartGeneration;
    this.capturing = true;
    const context = this.context;
    if (!context) {
      this.snapshot.asrState = 'stopped';
      this.snapshot.error = '无法获取麦克风权限上下文';
      this.capturing = false;
      this.callbacks.notify();
      return;
    }
    this.capture.requestPermission(context).then((granted: boolean) => {
      if (!this.isCaptureStartCurrent(generation)) {
        this.callbacks.syncBackgroundState();
        return false;
      }
      if (!granted) {
        this.capturing = false;
        this.snapshot.error = '麦克风权限未授权';
        this.snapshot.asrState = 'stopped';
        this.callbacks.notify();
        return false;
      }
      return this.callbacks.ensureRecordingReady().then((): Promise<void> => {
        if (!this.isCaptureStartCurrent(generation)) {
          this.callbacks.syncBackgroundState();
          return Promise.resolve();
        }
        return this.capture.start((chunk: ArrayBuffer) => {
          if (this.output.isUsingSystemSpeech()) {
            this.systemAsr?.acceptPcm(this.epoch, chunk);
          } else {
            this.asr.sendPcm(chunk);
          }
        }, (label: string): void => {
          this.onMicrophoneRouteChanged(label);
        });
      }).then((): boolean => {
        if (!this.isCaptureStartCurrent(generation)) {
          this.capture.stop().catch(() => undefined);
          this.callbacks.syncBackgroundState();
          return false;
        }
        return true;
      });
    }).then((started: boolean) => {
      if (generation !== this.captureStartGeneration) {
        this.callbacks.syncBackgroundState();
        return;
      }
      if (!started) {
        this.capturing = false;
        return;
      }
      if (!this.wanted) {
        this.capture.stop().catch(() => undefined);
        return;
      }
      this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
      this.callbacks.syncBackgroundState();
      this.callbacks.notify();
    }).catch((error: BusinessError) => {
      if (!this.isCaptureStartCurrent(generation)) {
        this.callbacks.syncBackgroundState();
        return;
      }
      this.capturing = false;
      this.captureReady = false;
      this.snapshot.asrState = 'stopped';
      this.snapshot.microphoneRoute = '';
      this.asr.close();
      this.snapshot.error = error.message;
      this.callbacks.notify();
    });
  }

  private onRemoteCaptureState(state: string, reason: string): void {
    if (state === 'running') {
      this.captureReady = true;
      if (this.wanted) {
        this.snapshot.microphoneRoute = this.capture.getInputRouteLabel();
        const backendReady = this.output.isUsingSystemSpeech() ? this.systemAsrReady : this.asr.isConnected();
        this.snapshot.asrState = backendReady ? 'listening' : 'connecting';
        this.snapshot.statusDetail = this.output.isUsingSystemSpeech()
          ? (backendReady ? '本地 ASR 监听中' : '本地 ASR 正在连接')
          : (backendReady ? '远端 ASR 监听中' : '远端 ASR 正在连接');
        this.snapshot.error = '';
      }
      this.callbacks.notify();
      return;
    }
    if (state === 'recovering') {
      this.captureReady = false;
      if (this.wanted) {
        this.snapshot.asrState = 'connecting';
        this.snapshot.statusDetail = this.output.isUsingSystemSpeech()
          ? '本地 ASR：音频采集正在恢复' : '远端 ASR：音频采集正在恢复';
        this.snapshot.error = '';
        hilog.warn(
          INPUT_LOG_DOMAIN,
          INPUT_LOG_TAG,
          'capture recovering epoch=%{public}d reason=%{public}s',
          this.epoch,
          reason
        );
        this.callbacks.notify();
      }
      return;
    }
    if (state === 'stopped' || state === 'failed') {
      this.captureReady = false;
    }
  }

  private onRemoteCaptureExhausted(message: string): void {
    if (!this.wanted) {
      return;
    }
    this.finalizeAfterTermination();
    this.wanted = false;
    this.captureStartGeneration += 1;
    this.capturing = false;
    this.captureReady = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.inputRouting = 'off';
    this.snapshot.asrState = 'stopped';
    this.snapshot.microphoneRoute = '';
    this.snapshot.statusDetail = '远端 ASR 已停止：音频采集恢复失败';
    this.snapshot.error = message;
    if (this.output.isUsingSystemSpeech()) {
      this.systemAsr?.stop(this.epoch, false).catch(() => undefined);
    } else {
      this.asr.stop();
      this.asr.close();
    }
    this.callbacks.syncBackgroundState();
    this.callbacks.notify();
  }

  private handleRemoteDisconnect(message: string): void {
    this.clearRemoteStableTimer();
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
    const attempt = this.remoteAsrRecoveryBudget.beginAttempt();
    if (attempt <= 0) {
      this.failRemoteRecovery('远端 ASR 恢复次数已耗尽');
      return;
    }
    const delay = REMOTE_ASR_RECONNECT_DELAYS_MS[attempt - 1];
    this.remoteAsrReconnectTimer = setTimeout((): void => {
      this.remoteAsrReconnectTimer = undefined;
      if (!this.canRecoverRemote() || this.asr.isConnected() || this.asr.isConnecting()) {
        return;
      }
      this.asr.setListener(new CoordinatorAsrListener(this, this.epoch));
      this.asr.reconnect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    }, delay);
  }

  private markRemoteReady(epoch: number): void {
    if (this.remoteAsrReconnectTimer !== undefined) {
      clearTimeout(this.remoteAsrReconnectTimer);
      this.remoteAsrReconnectTimer = undefined;
    }
    this.clearRemoteStableTimer();
    this.remoteAsrRecoveryBudget.observeHealthy();
    this.remoteAsrStableTimer = setTimeout((): void => {
      this.remoteAsrStableTimer = undefined;
      if (epoch === this.epoch && this.wanted && this.asr.isReady()) {
        this.remoteAsrRecoveryBudget.observeHealthy();
      }
    }, REMOTE_ASR_STABLE_RESET_MS);
  }

  private clearRemoteStableTimer(): void {
    if (this.remoteAsrStableTimer !== undefined) {
      clearTimeout(this.remoteAsrStableTimer);
      this.remoteAsrStableTimer = undefined;
    }
  }

  private failRemoteRecovery(message: string): void {
    this.finalizeAfterTermination();
    this.wanted = false;
    this.captureStartGeneration += 1;
    this.capturing = false;
    this.captureReady = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.inputRouting = 'off';
    this.snapshot.asrState = 'stopped';
    this.snapshot.microphoneRoute = '';
    this.snapshot.statusDetail = '远端 ASR 已停止恢复';
    this.snapshot.error = message;
    this.asr.close();
    this.capture.stop().catch(() => undefined);
    this.callbacks.syncBackgroundState();
    this.callbacks.notify();
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

  private onUserSpeechDetected(epoch: number): void {
    if (epoch !== this.epoch || !this.wanted || this.submissionFrozen) {
      return;
    }
    if (!this.snapshot.asrUtteranceActive) {
      this.snapshot.asrUtteranceActive = true;
      if (!this.isCommandsOnly()) {
        this.callbacks.ensurePreview();
      }
    }
    this.output.onUserSpeechDetected();
  }

  private onFinal(epoch: number, text: string): void {
    if (epoch !== this.epoch || !this.wanted || this.submissionFrozen) {
      return;
    }
    const value = this.mergeSegments(this.combinedText(), text.trim());
    this.cancelFinalization();
    const preview = this.callbacks.currentPreview();
    this.snapshot.asrTranscript = '';
    this.snapshot.asrUtteranceActive = false;
    if (this.snapshot.asrState === 'finalizing') {
      this.snapshot.asrState = this.wanted ? 'listening' : 'stopped';
    }
    if (this.isExitPhrase(value)) {
      this.callbacks.discardPreview();
      this.callbacks.exitApplication();
      return;
    }
    if (this.isOpenMicPhrase(value)) {
      this.callbacks.discardPreview();
      this.openConversationRoute();
      if (this.output.isPausedForUser()) {
        this.output.resumePausedPlayback();
      }
      return;
    }
    if (this.isCloseMicPhrase(value)) {
      this.callbacks.discardPreview();
      this.closeConversationRoute();
      if (this.output.isPausedForUser()) {
        this.output.resumePausedPlayback();
      }
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
    if (this.isCommandsOnly()) {
      this.snapshot.statusDetail = '话筒已关闭，普通语音未发送';
      this.discardAndResumePlayback();
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

  private updateInterim(epoch: number, text: string): void {
    if (epoch !== this.epoch || !this.wanted || this.submissionFrozen) {
      return;
    }
    this.asrLatestInterimText = text.trim();
    const value = this.combinedText();
    if (value.length === 0) {
      return;
    }
    this.snapshot.asrTranscript = value;
    if (this.wanted) {
      this.snapshot.asrState = 'listening';
    }
    if (!this.isCommandsOnly()) {
      const preview = this.callbacks.ensurePreview();
      preview.label = '你 · 正在识别';
      preview.text = value;
      preview.revision += 1;
    }
    this.scheduleFinalization(epoch);
    this.callbacks.notify();
  }

  private queueFinal(epoch: number, text: string, isLast: boolean): void {
    if (epoch !== this.epoch || !this.wanted || this.submissionFrozen) {
      return;
    }
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
      this.onFinal(epoch, combined);
      return;
    }
    this.snapshot.asrTranscript = combined;
    this.snapshot.asrUtteranceActive = true;
    this.snapshot.asrState = 'finalizing';
    if (!this.isCommandsOnly()) {
      const preview = this.callbacks.ensurePreview();
      preview.label = '你 · 等待收句';
      preview.text = combined;
      preview.revision += 1;
    }
    hilog.info(
      INPUT_LOG_DOMAIN,
      INPUT_LOG_TAG,
      'ASR final buffered length=%{public}d isLast=%{public}s graceMs=%{public}d',
      combined.length,
      String(isLast),
      ASR_FINALIZATION_GRACE_MS
    );
    this.scheduleFinalization(epoch);
    this.callbacks.notify();
  }

  private scheduleFinalization(epoch: number): void {
    if (this.asrFinalizationTimer !== undefined) {
      clearTimeout(this.asrFinalizationTimer);
    }
    this.asrFinalizationTimer = setTimeout((): void => {
      this.asrFinalizationTimer = undefined;
      this.onFinal(epoch, this.combinedText());
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
      this.onFinal(this.epoch, value);
      return;
    }
    this.discardAndResumePlayback();
  }

  private shouldFinalizeImmediately(text: string): boolean {
    return this.isExitPhrase(text) || this.isStopPhrase(text) || this.isCloseMicPhrase(text) ||
      this.isOpenMicPhrase(text) ||
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

  private isSystemRecognitionStartCurrent(attempt: number): boolean {
    return attempt === this.systemRecognitionAttempt && this.wanted &&
      this.output.isUsingSystemSpeech();
  }

  private isCaptureStartCurrent(generation: number): boolean {
    return generation === this.captureStartGeneration && this.wanted;
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
