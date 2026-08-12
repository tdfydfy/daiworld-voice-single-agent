import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, SingleAgentSnapshot } from '../models/SingleAgentState';
import { ClientConfig } from './AppSettingsStore';
import { AudioCuePlayer } from './AudioCuePlayer';
import { PcmPlayer } from './PcmPlayer';
import { SpeechTextFilter } from './SpeechTextFilter';
import { StreamingTtsClient, TtsJobListener } from './StreamingTtsClient';
import { SystemSpeechQueue } from './SystemSpeechQueue';
import { SystemSpeechService } from './SystemSpeechService';

const OUTPUT_LOG_DOMAIN = 0xD004;
const OUTPUT_LOG_TAG = 'VoiceOutput';

export class VoiceOutputCallbacks {
  private configCallback: () => ClientConfig;
  private notifyCallback: () => void;
  private backgroundStateCallback: () => void;
  private cancelRemoteReconnectCallback: () => void;
  private remoteDisconnectCallback: (message: string) => void;
  private remoteUrlCallback: () => string;
  private cookieCallback: () => string;

  constructor(
    configCallback: () => ClientConfig,
    notifyCallback: () => void,
    backgroundStateCallback: () => void,
    cancelRemoteReconnectCallback: () => void,
    remoteDisconnectCallback: (message: string) => void,
    remoteUrlCallback: () => string,
    cookieCallback: () => string
  ) {
    this.configCallback = configCallback;
    this.notifyCallback = notifyCallback;
    this.backgroundStateCallback = backgroundStateCallback;
    this.cancelRemoteReconnectCallback = cancelRemoteReconnectCallback;
    this.remoteDisconnectCallback = remoteDisconnectCallback;
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

  cancelRemoteReconnect(): void {
    this.cancelRemoteReconnectCallback();
  }

  onRemoteDisconnect(message: string): void {
    this.remoteDisconnectCallback(message);
  }

  remoteUrl(): string {
    return this.remoteUrlCallback();
  }

  cookie(): string {
    return this.cookieCallback();
  }
}

class CoordinatorTtsListener extends TtsJobListener {
  private coordinator: VoiceOutputCoordinator;

  constructor(coordinator: VoiceOutputCoordinator) {
    super();
    this.coordinator = coordinator;
  }

  onReady(): void {
    this.coordinator.onRemoteReady();
  }

  onJobStarted(sampleRate: number): void {
    this.coordinator.onRemoteJobStarted(sampleRate);
  }

  onJobPcm(pcm: ArrayBuffer): void {
    this.coordinator.onRemoteJobPcm(pcm);
  }

  onJobEnded(): void {
    this.coordinator.onRemoteJobEnded();
  }

  onJobFallback(): void {
    this.coordinator.onRemoteJobFallback();
  }

  onError(message: string): void {
    this.coordinator.onRemoteError(message);
  }

  onClosed(): void {
    this.coordinator.onRemoteClosed();
  }
}

// Owns all voice-output state. The UI controller remains the thin facade and
// only supplies current configuration, connection details, and snapshot delivery.
export class VoiceOutputCoordinator {
  private snapshot: SingleAgentSnapshot;
  private callbacks: VoiceOutputCallbacks;
  private tts: StreamingTtsClient = new StreamingTtsClient();
  private player: PcmPlayer = new PcmPlayer();
  private audioCues: AudioCuePlayer = new AudioCuePlayer();
  private systemSpeechQueue: SystemSpeechQueue = new SystemSpeechQueue();
  private systemSpeech?: SystemSpeechService;
  private enabled: boolean = true;
  private pausedForUser: boolean = false;
  private ttsTextSent: string = '';
  private activeReplayMessageId: string = '';
  private replayAwaitingSystemStart: boolean = false;
  private replayGeneration: number = 0;
  private replayCleanup: Promise<void> = Promise.resolve();
  private replayCleanupActive: boolean = false;
  private useSystemSpeech: boolean = false;
  private systemSpeechStartGeneration: number = 0;
  private speechTextFilter: SpeechTextFilter = new SpeechTextFilter();
  private lastCueError: string = '';
  // Explicit Agent-turn boundary for the thinking pulse.  Do not infer the
  // pulse solely from a broad UI snapshot: queued prompts and late TTS state
  // callbacks can otherwise make a valid thinking window disappear.
  private agentTurnActive: boolean = false;
  private lastThinkingCueActive: boolean = false;
  private remoteTtsDrainPending: boolean = false;

  constructor(snapshot: SingleAgentSnapshot, callbacks: VoiceOutputCallbacks) {
    this.snapshot = snapshot;
    this.callbacks = callbacks;
    this.tts.setListener(new CoordinatorTtsListener(this));
    this.audioCues.setStateListener((): void => {
      this.callbacks.syncBackgroundState();
    });
  }

  setSystemSpeech(systemSpeech: SystemSpeechService): void {
    this.systemSpeech = systemSpeech;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  isPausedForUser(): boolean {
    return this.pausedForUser;
  }

  isUsingSystemSpeech(): boolean {
    return this.useSystemSpeech;
  }

  setUsingSystemSpeech(useSystemSpeech: boolean): void {
    this.useSystemSpeech = useSystemSpeech;
  }

  beginAgentTurn(): void {
    this.agentTurnActive = true;
  }

  endAgentTurn(): void {
    this.agentTurnActive = false;
    this.syncAudioCues();
  }

  isRemoteConnected(): boolean {
    return this.tts.isConnected();
  }

  isRemoteConnecting(): boolean {
    return this.tts.isConnecting();
  }

  connectRemote(url: string, cookie: string): void {
    this.tts.setListener(new CoordinatorTtsListener(this));
    this.tts.connect(url, cookie);
  }

  reconnectRemote(url: string, cookie: string): void {
    this.tts.setListener(new CoordinatorTtsListener(this));
    this.tts.reconnect(url, cookie);
  }

  closeRemote(): void {
    this.tts.close();
  }

  stopRemoteJob(): void {
    this.tts.sendStop();
  }

  canReplayMessage(message: ChatMessage): boolean {
    const source = this.snapshot.messages.find((item: ChatMessage): boolean => item.id === message.id) || message;
    if (source.replaying) {
      return true;
    }
    return source.role === 'assistant' && !source.pending && !this.snapshot.agentBusy &&
      this.enabled && !this.callbacks.config().muted &&
      SpeechTextFilter.clean(source.text).length > 0;
  }

  // Replays local speech only; it never creates or submits a Hermes turn.
  replayMessage(message: ChatMessage): void {
    const source = this.snapshot.messages.find((item: ChatMessage): boolean => item.id === message.id);
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'message replay requested id=%{public}s found=%{public}s active=%{public}s',
      message.id,
      String(source !== undefined),
      this.activeReplayMessageId
    );
    if (source === undefined) {
      return;
    }
    if (source.replaying && this.activeReplayMessageId === source.id) {
      this.stopMessageReplay();
      return;
    }
    if (!this.canReplayMessage(source)) {
      hilog.warn(
        OUTPUT_LOG_DOMAIN,
        OUTPUT_LOG_TAG,
        'message replay rejected id=%{public}s pending=%{public}s busy=%{public}s enabled=%{public}s muted=%{public}s',
        source.id,
        String(source.pending),
        String(this.snapshot.agentBusy),
        String(this.enabled),
        String(this.callbacks.config().muted)
      );
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
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'message replay queued id=%{public}s length=%{public}d system=%{public}s',
      source.id,
      text.length,
      String(this.useSystemSpeech)
    );
    this.callbacks.notify();
    this.startReplayAfterCleanup(text, source.id, replayGeneration, cleanup);
  }

  stopMessageReplay(): void {
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'message replay stop requested id=%{public}s',
      this.activeReplayMessageId
    );
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
    this.callbacks.notify();
  }

  clearActiveReplayState(): void {
    const replayId = this.activeReplayMessageId;
    this.activeReplayMessageId = '';
    this.replayAwaitingSystemStart = false;
    if (this.snapshot.statusDetail === '正在重读这条消息') {
      this.snapshot.statusDetail = '';
    }
    if (replayId.length === 0) {
      return;
    }
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'message replay state cleared id=%{public}s',
      replayId
    );
    const message = this.snapshot.messages.find((item: ChatMessage): boolean => item.id === replayId);
    if (message !== undefined && message.replaying) {
      message.replaying = false;
      message.revision += 1;
    }
  }

  hasActiveReplay(): boolean {
    return this.activeReplayMessageId.length > 0;
  }

  beginAssistantStream(): void {
    this.agentTurnActive = true;
    this.ttsTextSent = '';
    this.systemSpeechQueue.beginStream();
    this.speechTextFilter = new SpeechTextFilter();
  }

  appendAssistantDelta(text: string, suppliedSpeechText: string): void {
    const speechDelta = suppliedSpeechText.length > 0
      ? SpeechTextFilter.clean(suppliedSpeechText)
      : this.speechTextFilter.push(text);
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'assistant TTS delta length=%{public}d output=%{public}s muted=%{public}s system=%{public}s',
      text.length,
      String(this.enabled),
      String(this.callbacks.config().muted),
      String(this.useSystemSpeech)
    );
    if (speechDelta.length === 0 || !this.enabled || this.callbacks.config().muted) {
      return;
    }
    if (this.useSystemSpeech) {
      this.appendSystemSpeechStream(speechDelta);
    } else {
      this.tts.sendText(speechDelta);
      this.ttsTextSent += speechDelta;
    }
  }

  finishAssistantStream(finalText: string, suppliedSpeechText: string, currentText: string): void {
    this.agentTurnActive = false;
    const speechText = SpeechTextFilter.clean(suppliedSpeechText.length > 0
      ? suppliedSpeechText : (finalText.length > 0 ? finalText : currentText));
    const speechTail = this.speechTextFilter.flush();
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'assistant TTS complete final=%{public}d speech=%{public}d output=%{public}s muted=%{public}s system=%{public}s',
      finalText.length,
      speechText.length,
      String(this.enabled),
      String(this.callbacks.config().muted),
      String(this.useSystemSpeech)
    );
    if (!this.enabled || this.callbacks.config().muted) {
      return;
    }
    if (this.useSystemSpeech) {
      if (speechTail.length > 0) {
        this.appendSystemSpeechStream(speechTail);
      }
      this.finishSystemSpeechStream(speechText);
      return;
    }
    if (finalText.length > 0 && this.ttsTextSent.length === 0) {
      this.tts.sendText(speechText);
    }
    this.tts.sendDone();
  }

  speakProtocolPrompt(text: string): void {
    const value = SpeechTextFilter.clean(text).trim();
    if (value.length === 0 || !this.enabled || this.callbacks.config().muted) {
      return;
    }
    if (this.useSystemSpeech) {
      this.speakWithSystem(value);
      return;
    }
    if (!this.tts.isConnected() && !this.tts.isConnecting()) {
      this.tts.reconnect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    }
    this.tts.sendText(value);
    this.tts.sendDone();
  }

  stopProtocolPromptPlayback(): void {
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
  }

  replaceProtocolPromptSpeech(text: string): void {
    this.stopProtocolPromptPlayback();
    this.speakProtocolPrompt(text);
  }

  onUserSpeechDetected(): void {
    if (this.pausedForUser ||
      (this.snapshot.playback !== 'queued' && this.snapshot.playback !== 'playing')) {
      this.callbacks.notify();
      return;
    }
    this.pausedForUser = true;
    this.snapshot.playback = 'paused_for_user';
    this.snapshot.statusDetail = '检测到你说话，已暂停播报';
    if (this.useSystemSpeech) {
      this.systemSpeechQueue.pause(this.callbacks.config().speechRate);
      this.systemSpeechStartGeneration += 1;
      this.systemSpeech?.stopSpeaking();
    } else {
      this.player.pause().catch(() => undefined);
    }
    this.callbacks.notify();
  }

  resumePausedPlayback(): void {
    this.pausedForUser = false;
    this.snapshot.statusDetail = '已恢复播报，新指令在后台处理';
    if (this.useSystemSpeech) {
      const next = this.systemSpeechQueue.takeResumeText();
      if (next.length > 0) {
        this.startSystemSpeech(next);
      } else {
        this.snapshot.playback = 'none';
        this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
        this.callbacks.notify();
      }
      return;
    }
    this.player.resume().catch(() => undefined);
    this.snapshot.playback = this.player.hasQueued() ? 'playing' : 'none';
    this.callbacks.notify();
  }

  clearPausedState(): void {
    this.pausedForUser = false;
  }

  handleMuteChanged(muted: boolean): void {
    if (!muted) {
      return;
    }
    this.callbacks.cancelRemoteReconnect();
    this.agentTurnActive = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.playback = 'none';
  }

  stopForConversationChange(): void {
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
  }

  stopForInterrupt(): void {
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.snapshot.playback = 'none';
  }

  stopForVoiceClientRestart(): void {
    this.agentTurnActive = false;
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
  }

  disable(): void {
    this.enabled = false;
    this.agentTurnActive = false;
    this.callbacks.cancelRemoteReconnect();
    this.audioCues.silence();
    this.pausedForUser = false;
    this.snapshot.ttsState = 'stopped';
    this.clearSystemSpeechQueue();
    this.tts.sendStop();
    this.systemSpeech?.stopSpeaking();
    this.player.stop().catch(() => undefined);
  }

  prepareInterruptCue(): boolean {
    const shouldPlayCue = this.enabled && !this.callbacks.config().muted;
    this.audioCues.setRunning(false);
    return shouldPlayCue;
  }

  playAcceptedCue(): void {
    this.audioCues.playAccepted();
  }

  playStopCue(): void {
    this.audioCues.playStop();
  }

  syncAudioCues(): void {
    const error = this.snapshot.error.trim();
    const cueEnabled = this.enabled && !this.callbacks.config().muted;
    const newError = error.length > 0 && error !== this.lastCueError;
    this.lastCueError = error;
    const running = cueEnabled && error.length === 0 && this.agentTurnActive && this.snapshot.agentBusy &&
      !this.snapshot.asrUtteranceActive && this.snapshot.playback === 'none' &&
      this.snapshot.ttsState !== 'speaking' && !this.snapshot.approvalPending &&
      !this.snapshot.clarifyPending;
    if (running !== this.lastThinkingCueActive) {
      hilog.info(
        OUTPUT_LOG_DOMAIN,
        OUTPUT_LOG_TAG,
        'thinking cue desired=%{public}s turn=%{public}s busy=%{public}s playback=%{public}s tts=%{public}s',
        String(running),
        String(this.agentTurnActive),
        String(this.snapshot.agentBusy),
        this.snapshot.playback,
        this.snapshot.ttsState
      );
      this.lastThinkingCueActive = running;
    }
    this.audioCues.setRunning(running);
    if (cueEnabled && newError) {
      this.audioCues.playError();
    }
  }

  hasBackgroundOutput(): boolean {
    return this.audioCues.isRunning() || this.snapshot.playback !== 'none' ||
      this.snapshot.ttsState === 'speaking' || this.systemSpeechQueue.hasPendingOutput();
  }

  prefersBackgroundPlayback(): boolean {
    if (this.pausedForUser || this.snapshot.playback === 'paused_for_user') {
      return false;
    }
    return this.snapshot.playback === 'queued' || this.snapshot.playback === 'playing' ||
      this.snapshot.ttsState === 'speaking';
  }

  onSystemSpeechState(active: boolean): void {
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS state active=%{public}s output=%{public}s paused=%{public}s queue=%{public}d',
      String(active),
      String(this.enabled),
      String(this.pausedForUser),
      this.systemSpeechQueue.queuedCount()
    );
    if (!this.useSystemSpeech || this.replayCleanupActive) {
      return;
    }
    if (!this.enabled) {
      this.snapshot.ttsState = 'stopped';
      this.snapshot.playback = 'none';
      this.clearActiveReplayState();
      return;
    }
    if (!active && this.activeReplayMessageId.length > 0 && this.replayAwaitingSystemStart) {
      this.snapshot.ttsState = 'connecting';
      this.snapshot.playback = 'queued';
      this.callbacks.notify();
      return;
    }
    if (active && this.pausedForUser) {
      this.systemSpeech?.stopSpeaking();
      this.snapshot.ttsState = 'ready';
      this.snapshot.playback = 'paused_for_user';
      this.callbacks.notify();
      return;
    }
    if (active) {
      this.replayAwaitingSystemStart = false;
      this.systemSpeechQueue.markStarted();
      this.snapshot.ttsState = 'speaking';
      this.snapshot.playback = 'playing';
      this.callbacks.notify();
      return;
    }
    this.snapshot.ttsState = 'ready';
    if (this.pausedForUser) {
      this.snapshot.playback = 'paused_for_user';
      this.callbacks.notify();
      return;
    }
    const next = this.systemSpeechQueue.completeActive();
    if (next.length > 0) {
      this.startSystemSpeech(next);
    } else {
      this.snapshot.playback = 'none';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
        this.snapshot.statusDetail = '';
      }
      this.callbacks.notify();
    }
  }

  onSystemSpeechError(message: string): void {
    if (!this.useSystemSpeech || this.replayCleanupActive) {
      return;
    }
    this.clearSystemSpeechQueue();
    this.snapshot.ttsState = 'error';
    this.snapshot.playback = 'none';
    this.snapshot.statusDetail = '本地 TTS 已停止';
    this.snapshot.error = 'TTS：' + message;
    this.callbacks.notify();
  }

  onRemoteReady(): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.callbacks.cancelRemoteReconnect();
    this.snapshot.ttsState = 'ready';
    this.snapshot.error = '';
    this.callbacks.notify();
  }

  onRemoteJobStarted(sampleRate: number): void {
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
    this.callbacks.notify();
  }

  onRemoteJobPcm(pcm: ArrayBuffer): void {
    if (!this.replayCleanupActive) {
      this.player.enqueue(pcm);
    }
  }

  onRemoteJobEnded(): void {
    if (this.replayCleanupActive) {
      return;
    }
    this.player.waitForDrain((): void => {
      this.snapshot.playback = 'none';
      this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
        this.snapshot.statusDetail = '';
      }
      this.callbacks.notify();
    });
  }

  onRemoteJobFallback(): void {
    this.snapshot.ttsState = 'fallback';
    this.snapshot.statusDetail = 'TTS已降级';
    this.callbacks.notify();
  }

  onRemoteError(message: string): void {
    if (!this.replayCleanupActive) {
      this.callbacks.onRemoteDisconnect(message.length > 0 ? message : 'TTS 连接失败');
    }
  }

  onRemoteClosed(): void {
    if (!this.replayCleanupActive) {
      this.callbacks.onRemoteDisconnect('TTS 连接已断开');
    }
  }

  drainRemotePlaybackAfterDisconnect(): void {
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
      this.callbacks.notify();
    });
  }

  private stopPlaybackForReplay(): Promise<void> {
    this.pausedForUser = false;
    this.replayCleanupActive = true;
    this.callbacks.cancelRemoteReconnect();
    this.clearSystemSpeechQueue(false);
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
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
      this.systemSpeechQueue.beginStream();
      this.speechTextFilter = new SpeechTextFilter();
      this.startSystemReplay(text);
      return;
    }
    this.callbacks.cancelRemoteReconnect();
    this.tts.close();
    this.replayCleanupActive = false;
    this.tts.setListener(new CoordinatorTtsListener(this));
    this.tts.connect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    this.tts.sendText(text);
    this.tts.sendDone();
  }

  private clearSystemSpeechQueue(clearReplayState: boolean = true): void {
    this.systemSpeechStartGeneration += 1;
    this.systemSpeechQueue.clear();
    if (clearReplayState) {
      this.clearActiveReplayState();
    }
  }

  private appendSystemSpeechStream(text: string): void {
    if (text.length === 0) {
      return;
    }
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS delta received length=%{public}d pending=%{public}d',
      text.length,
      this.systemSpeechQueue.pendingLength()
    );
    this.speakSystemChunks(this.systemSpeechQueue.appendStream(text));
  }

  private finishSystemSpeechStream(finalText: string): void {
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS final received length=%{public}d streamed=%{public}d',
      finalText.length,
      this.systemSpeechQueue.receivedLength()
    );
    this.speakSystemChunks(this.systemSpeechQueue.finishStream(finalText));
  }

  private startSystemReplay(text: string): void {
    const chunks = this.systemSpeechQueue.finishStream(text);
    if (chunks.length === 0) {
      this.clearActiveReplayState();
      this.snapshot.playback = 'none';
      this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
      this.callbacks.notify();
      return;
    }
    for (let index = 1; index < chunks.length; index += 1) {
      this.systemSpeechQueue.enqueue(chunks[index]);
    }
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system replay first chunk ready length=%{public}d queued=%{public}d',
      chunks[0].length,
      this.systemSpeechQueue.queuedCount()
    );
    this.startSystemSpeech(chunks[0]);
  }

  private speakSystemChunks(chunks: string[]): void {
    for (const chunk of chunks) {
      this.speakWithSystem(chunk);
    }
  }

  private speakWithSystem(text: string): void {
    const value = text.trim();
    if (value.length === 0 || !this.systemSpeech) {
      return;
    }
    if (this.systemSpeechQueue.hasActive() || this.pausedForUser ||
      this.snapshot.playback === 'queued' || this.snapshot.playback === 'playing') {
      this.systemSpeechQueue.enqueue(value);
      hilog.info(
        OUTPUT_LOG_DOMAIN,
        OUTPUT_LOG_TAG,
        'system TTS chunk queued length=%{public}d queue=%{public}d',
        value.length,
        this.systemSpeechQueue.queuedCount()
      );
      return;
    }
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS chunk ready length=%{public}d',
      value.length
    );
    this.startSystemSpeech(value);
  }

  private startSystemSpeech(text: string): void {
    const speech = this.systemSpeech;
    if (!speech || text.length === 0) {
      return;
    }
    const generation = ++this.systemSpeechStartGeneration;
    this.systemSpeechQueue.activate(text);
    this.snapshot.playback = 'queued';
    this.snapshot.ttsState = 'connecting';
    const config = this.callbacks.config();
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS start length=%{public}d person=%{public}d rate=%{public}s',
      text.length,
      config.voicePerson,
      String(config.speechRate)
    );
    this.callbacks.notify();
    this.audioCues.yieldForSpeech().then((): void => {
      const latestConfig = this.callbacks.config();
      if (generation !== this.systemSpeechStartGeneration || !this.useSystemSpeech ||
        !this.enabled || latestConfig.muted || this.pausedForUser ||
        this.systemSpeechQueue.active() !== text) {
        return;
      }
      speech.speak(text, latestConfig.voicePerson, latestConfig.speechRate).catch((error: BusinessError) => {
        if (generation !== this.systemSpeechStartGeneration) {
          return;
        }
        this.clearSystemSpeechQueue();
        this.snapshot.ttsState = 'error';
        this.snapshot.playback = 'none';
        this.snapshot.statusDetail = '本地 TTS 启动失败';
        this.snapshot.error = this.errorMessage(error, '离线 TTS 启动失败');
        this.callbacks.notify();
      });
    }).catch((error: BusinessError): void => {
      if (generation !== this.systemSpeechStartGeneration) {
        return;
      }
      this.clearSystemSpeechQueue();
      this.snapshot.ttsState = 'error';
      this.snapshot.playback = 'none';
      this.snapshot.statusDetail = '提示音与本地 TTS 交接失败';
      this.snapshot.error = this.errorMessage(error, '本地 TTS 输出准备失败');
      this.callbacks.notify();
    });
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }
}
