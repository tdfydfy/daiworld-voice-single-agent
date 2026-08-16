import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, SingleAgentSnapshot } from '../models/SingleAgentState';
import { ClientConfig } from './AppSettingsStore';
import { AudioCuePlayer } from './AudioCuePlayer';
import { PcmPlayer } from './PcmPlayer';
import { SpeechTextFilter } from './SpeechTextFilter';
import { StreamingTtsClient, TtsJobListener } from './StreamingTtsClient';
import { SystemSpeechQueue } from './SystemSpeechQueue';
import { SystemTtsPlayer } from './SystemTtsPlayer';
import { SystemTtsPlaybackEvent } from './SystemTtsCompletionGate';
import { PlaybackKind, PlaybackPriority, SpeechPlaybackQueue } from './SpeechPlaybackQueue';

const OUTPUT_LOG_DOMAIN = 0xD004;
const OUTPUT_LOG_TAG = 'VoiceOutput';
const SYSTEM_TTS_INTERRUPTION_RETRY_DELAYS_MS: number[] = [300, 1200];

export class VoiceOutputCallbacks {
  private configCallback: () => ClientConfig;
  private notifyCallback: () => void;
  private backgroundStateCallback: () => void;
  private playbackReadyCallback: () => Promise<void>;
  private cancelRemoteReconnectCallback: () => void;
  private remoteReadyCallback: () => void;
  private remoteDisconnectCallback: (message: string) => void;
  private remoteUrlCallback: () => string;
  private cookieCallback: () => string;

  constructor(
    configCallback: () => ClientConfig,
    notifyCallback: () => void,
    backgroundStateCallback: () => void,
    playbackReadyCallback: () => Promise<void>,
    cancelRemoteReconnectCallback: () => void,
    remoteReadyCallback: () => void,
    remoteDisconnectCallback: (message: string) => void,
    remoteUrlCallback: () => string,
    cookieCallback: () => string
  ) {
    this.configCallback = configCallback;
    this.notifyCallback = notifyCallback;
    this.backgroundStateCallback = backgroundStateCallback;
    this.playbackReadyCallback = playbackReadyCallback;
    this.cancelRemoteReconnectCallback = cancelRemoteReconnectCallback;
    this.remoteReadyCallback = remoteReadyCallback;
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

  ensurePlaybackReady(): Promise<void> {
    return this.playbackReadyCallback();
  }

  cancelRemoteReconnect(): void {
    this.cancelRemoteReconnectCallback();
  }

  onRemoteReady(): void {
    this.remoteReadyCallback();
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
  private epoch: number;
  private jobId: string;

  constructor(coordinator: VoiceOutputCoordinator, epoch: number, jobId: string) {
    super();
    this.coordinator = coordinator;
    this.epoch = epoch;
    this.jobId = jobId;
  }

  onReady(): void {
    this.coordinator.onRemoteReady(this.epoch, this.jobId);
  }

  onJobStarted(sampleRate: number): void {
    this.coordinator.onRemoteJobStarted(this.epoch, this.jobId, sampleRate);
  }

  onJobPcm(pcm: ArrayBuffer): void {
    this.coordinator.onRemoteJobPcm(this.epoch, this.jobId, pcm);
  }

  onJobEnded(): void {
    this.coordinator.onRemoteJobEnded(this.epoch, this.jobId);
  }

  onJobFallback(): void {
    this.coordinator.onRemoteJobFallback(this.epoch, this.jobId);
  }

  onError(message: string): void {
    this.coordinator.onRemoteError(this.epoch, this.jobId, message);
  }

  onClosed(): void {
    this.coordinator.onRemoteClosed(this.epoch, this.jobId);
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
  private systemTts?: SystemTtsPlayer;
  private playbackQueue: SpeechPlaybackQueue = new SpeechPlaybackQueue();
  private playbackEpoch: number = 0;
  private activePlaybackJobId: string = '';
  private activeCueJobId: string = '';
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
  private systemSpeechToken: string = '';
  private systemSpeechRetryCount: number = 0;
  private systemSpeechRetryTimer?: number;
  private systemSpeechSuspended: boolean = false;
  private speechTextFilter: SpeechTextFilter = new SpeechTextFilter();
  private lastCueError: string = '';
  // Explicit Agent-turn boundary for the thinking pulse.  Do not infer the
  // pulse solely from a broad UI snapshot: queued prompts and late TTS state
  // callbacks can otherwise make a valid thinking window disappear.
  private agentTurnActive: boolean = false;
  private lastThinkingCueActive: boolean = false;
  private remoteTtsDrainPending: boolean = false;
  private pendingErrorCue: boolean = false;

  constructor(snapshot: SingleAgentSnapshot, callbacks: VoiceOutputCallbacks) {
    this.snapshot = snapshot;
    this.callbacks = callbacks;
    this.playbackQueue.bindEpoch(this.playbackEpoch);
    this.tts.setListener(new CoordinatorTtsListener(this, this.playbackEpoch, ''));
    this.audioCues.setStateListener((): void => {
      if (this.activeCueJobId.length > 0 && !this.audioCues.isRunning()) {
        this.completePlaybackJob(this.activeCueJobId);
        this.activeCueJobId = '';
      }
      this.callbacks.syncBackgroundState();
    });
    this.audioCues.setPlaybackReadyListener((): Promise<void> => {
      return this.callbacks.ensurePlaybackReady();
    });
    this.player.setFailureListener((message: string): void => {
      this.onPcmPlaybackFailure(message);
    });
  }

  setSystemTts(systemTts: SystemTtsPlayer): void {
    this.systemTts = systemTts;
  }

  bindEpoch(epoch: number): void {
    this.playbackEpoch = epoch;
    this.playbackQueue.bindEpoch(epoch);
    this.activePlaybackJobId = '';
    this.activeCueJobId = '';
    this.systemSpeechStartGeneration += 1;
    this.systemSpeechToken = '';
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
    this.tts.setListener(new CoordinatorTtsListener(this, this.playbackEpoch, this.activePlaybackJobId));
    this.tts.connect(url, cookie);
  }

  reconnectRemote(url: string, cookie: string): void {
    this.tts.setListener(new CoordinatorTtsListener(this, this.playbackEpoch, this.activePlaybackJobId));
    this.tts.connect(url, cookie);
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
    if (speechDelta.length === 0 || !this.enabled || this.callbacks.config().muted) {
      return;
    }
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'assistant TTS speech delta length=%{public}d system=%{public}s',
      speechDelta.length,
      String(this.useSystemSpeech)
    );
    if (this.useSystemSpeech) {
      this.appendSystemSpeechStream(speechDelta);
    } else {
      if (!this.ensureAssistantPlaybackJob()) {
        return;
      }
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
      if (!this.ensureAssistantPlaybackJob()) {
        this.callbacks.notify();
        return;
      }
      this.tts.sendText(speechText);
    }
    if (this.activePlaybackJobId.length > 0) {
      this.tts.sendDone();
    } else {
      this.callbacks.notify();
    }
  }

  speakProtocolPrompt(text: string): void {
    const value = SpeechTextFilter.clean(text).trim();
    if (value.length === 0 || !this.enabled || this.callbacks.config().muted) {
      return;
    }
    this.activePlaybackJobId = this.beginPlaybackJob('protocol', 20, value);
    if (this.activePlaybackJobId.length === 0) {
      return;
    }
    if (this.useSystemSpeech) {
      this.speakWithSystem(value);
      return;
    }
    this.openRemoteForActiveJob();
    this.tts.sendText(value);
    this.tts.sendDone();
  }

  stopProtocolPromptPlayback(): void {
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.tts.sendStop();
    this.systemTts?.stop();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
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
      this.systemTts?.stop();
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
    this.systemTts?.stop();
    this.player.stop().catch(() => undefined);
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
    this.audioCues.silence();
    this.snapshot.playback = 'none';
  }

  async stopForConversationChange(): Promise<void> {
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.callbacks.cancelRemoteReconnect();
    this.tts.close();
    const systemStop = this.systemTts?.stop() ?? Promise.resolve();
    const cueStop = this.audioCues.dispose();
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
    await Promise.all([
      cueStop.catch(() => undefined),
      systemStop.catch(() => undefined),
      this.player.stop().catch(() => undefined)
    ]);
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
  }

  async stopForInterrupt(): Promise<void> {
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.callbacks.cancelRemoteReconnect();
    this.tts.close();
    const systemStop = this.systemTts?.stop() ?? Promise.resolve();
    const cueStop = this.audioCues.dispose();
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
    this.snapshot.playback = 'none';
    await Promise.all([
      cueStop.catch(() => undefined),
      systemStop.catch(() => undefined),
      this.player.stop().catch(() => undefined)
    ]);
    if (!this.useSystemSpeech && this.enabled && !this.callbacks.config().muted) {
      this.tts.setListener(new CoordinatorTtsListener(this, this.playbackEpoch, ''));
      this.tts.connect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    }
  }

  stopForVoiceClientRestart(): void {
    this.agentTurnActive = false;
    this.tts.sendStop();
    this.systemTts?.stop();
    this.player.stop().catch(() => undefined);
    this.audioCues.silence();
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
  }

  disable(): void {
    this.enabled = false;
    this.agentTurnActive = false;
    this.callbacks.cancelRemoteReconnect();
    this.audioCues.silence();
    this.pausedForUser = false;
    this.snapshot.ttsState = 'stopped';
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
    this.tts.sendStop();
    this.systemTts?.stop();
    this.player.stop().catch(() => undefined);
  }

  async dispose(): Promise<void> {
    this.enabled = false;
    this.agentTurnActive = false;
    this.pausedForUser = false;
    this.pendingErrorCue = false;
    this.callbacks.cancelRemoteReconnect();
    this.tts.close();
    this.clearSystemSpeechQueue();
    this.cancelPlaybackJobs();
    const systemStop = this.systemTts?.stop() ?? Promise.resolve();
    await Promise.all([
      this.audioCues.dispose().catch(() => undefined),
      systemStop.catch(() => undefined),
      this.player.dispose().catch(() => undefined)
    ]);
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = 'stopped';
    this.callbacks.syncBackgroundState();
  }

  prepareInterruptCue(): boolean {
    const shouldPlayCue = this.enabled && !this.callbacks.config().muted;
    this.audioCues.setRunning(false);
    return shouldPlayCue;
  }

  playAcceptedCue(): void {
    const jobId = this.beginPlaybackJob('cue', 10, '', 'accepted', true);
    if (jobId.length === 0) {
      return;
    }
    if (this.hasSpeechPlayback()) {
      this.completePlaybackJob(jobId);
      return;
    }
    this.activeCueJobId = jobId;
    this.audioCues.playAccepted();
  }

  playStopCue(): void {
    const jobId = this.beginPlaybackJob('cue', 40, '', 'stop');
    if (jobId.length === 0) {
      return;
    }
    this.activeCueJobId = jobId;
    this.audioCues.playStop();
  }

  syncAudioCues(): void {
    const error = this.snapshot.error.trim();
    const cueEnabled = this.enabled && !this.callbacks.config().muted;
    const newError = error.length > 0 && error !== this.lastCueError;
    this.lastCueError = error;
    if (cueEnabled && newError) {
      this.pendingErrorCue = true;
    }
    const activeJob = this.playbackQueue.activeJob();
    const thinkingOwnsQueue = activeJob?.kind === 'cue' && activeJob.cue === 'thinking';
    const running = cueEnabled && error.length === 0 && this.agentTurnActive && this.snapshot.agentBusy &&
      !this.snapshot.asrUtteranceActive && this.snapshot.playback === 'none' &&
      this.snapshot.ttsState !== 'speaking' && !this.snapshot.approvalPending &&
      !this.snapshot.clarifyPending && (!this.playbackQueue.hasOutput() || thinkingOwnsQueue);
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
      if (running) {
        const thinkingJobId = this.beginPlaybackJob('cue', 10, '', 'thinking', true);
        if (thinkingJobId.length > 0) {
          this.activeCueJobId = thinkingJobId;
        }
      }
    }
    this.audioCues.setRunning(running);
    if (cueEnabled && this.pendingErrorCue && !this.hasSpeechPlayback()) {
      this.pendingErrorCue = false;
      const errorJobId = this.beginPlaybackJob('cue', 40, '', 'error');
      if (errorJobId.length > 0) {
        this.activeCueJobId = errorJobId;
        this.audioCues.playError();
      }
    }
  }

  hasBackgroundOutput(): boolean {
    return this.audioCues.isRunning() || this.snapshot.playback !== 'none' ||
      this.snapshot.ttsState === 'speaking' || this.systemSpeechQueue.hasPendingOutput() ||
      this.playbackQueue.hasOutput();
  }

  prefersBackgroundPlayback(): boolean {
    if (this.pausedForUser || this.snapshot.playback === 'paused_for_user') {
      return false;
    }
    return this.snapshot.playback === 'queued' || this.snapshot.playback === 'playing' ||
      this.snapshot.ttsState === 'speaking';
  }

  hasActivePlaybackJob(): boolean {
    return this.activePlaybackJobId.length > 0;
  }

  private hasSpeechPlayback(): boolean {
    return this.snapshot.playback !== 'none' || this.snapshot.ttsState === 'speaking' ||
      this.systemSpeechQueue.hasPendingOutput();
  }

  onSystemSpeechState(token: string, event: SystemTtsPlaybackEvent): void {
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS state event=%{public}s output=%{public}s paused=%{public}s queue=%{public}d',
      event,
      String(this.enabled),
      String(this.pausedForUser),
      this.systemSpeechQueue.queuedCount()
    );
    if (!this.useSystemSpeech || this.replayCleanupActive || token.length === 0 ||
      token !== this.systemSpeechToken) {
      return;
    }
    if (!this.enabled) {
      this.snapshot.ttsState = 'stopped';
      this.snapshot.playback = 'none';
      this.clearActiveReplayState();
      return;
    }
    if (event === 'started' && this.pausedForUser) {
      this.systemTts?.stop();
      this.snapshot.ttsState = 'ready';
      this.snapshot.playback = 'paused_for_user';
      this.callbacks.notify();
      return;
    }
    if (event === 'started') {
      this.replayAwaitingSystemStart = false;
      this.snapshot.ttsState = 'speaking';
      this.snapshot.playback = 'playing';
      this.callbacks.notify();
      return;
    }
    if (event === 'interrupted') {
      if (this.pausedForUser) {
        this.snapshot.ttsState = 'ready';
        this.snapshot.playback = 'paused_for_user';
        this.callbacks.notify();
        return;
      }
      this.scheduleSystemSpeechRetry(token);
      return;
    }
    this.cancelSystemSpeechRetry();
    this.systemSpeechRetryCount = 0;
    this.systemSpeechSuspended = false;
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
      const completedJobId = this.activePlaybackJobId;
      this.systemSpeechToken = '';
      this.snapshot.playback = 'none';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
        this.snapshot.statusDetail = '';
      }
      this.completePlaybackJob(completedJobId);
      this.callbacks.notify();
    }
  }

  onSystemSpeechError(token: string, message: string): void {
    if (!this.useSystemSpeech || this.replayCleanupActive || token.length === 0 ||
      token !== this.systemSpeechToken) {
      return;
    }
    this.clearSystemSpeechQueue();
    this.completePlaybackJob(this.activePlaybackJobId);
    this.systemSpeechToken = '';
    this.snapshot.ttsState = 'error';
    this.snapshot.playback = 'none';
    this.snapshot.statusDetail = '本地 TTS 已停止';
    this.snapshot.error = 'TTS：' + message;
    this.callbacks.notify();
  }

  resumeSuspendedSystemSpeech(): void {
    if (!this.systemSpeechSuspended || !this.useSystemSpeech || !this.enabled ||
      this.pausedForUser || this.callbacks.config().muted) {
      return;
    }
    const text = this.systemSpeechQueue.active();
    if (text.length === 0) {
      this.systemSpeechSuspended = false;
      return;
    }
    hilog.info(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS resuming suspended segment length=%{public}d',
      text.length
    );
    this.systemSpeechSuspended = false;
    this.systemSpeechRetryCount = 0;
    this.snapshot.statusDetail = '';
    this.startSystemSpeech(text);
  }

  onRemoteReady(epoch: number, jobId: string): void {
    if (!this.isRemoteEventCurrent(epoch, jobId) || this.replayCleanupActive) {
      return;
    }
    this.callbacks.onRemoteReady();
    this.snapshot.ttsState = 'ready';
    this.snapshot.error = '';
    this.callbacks.notify();
  }

  onRemoteJobStarted(epoch: number, jobId: string, sampleRate: number): void {
    if (!this.isRemoteEventCurrent(epoch, jobId) || this.replayCleanupActive) {
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

  onRemoteJobPcm(epoch: number, jobId: string, pcm: ArrayBuffer): void {
    if (this.isRemoteEventCurrent(epoch, jobId) && !this.replayCleanupActive) {
      this.player.enqueue(pcm);
    }
  }

  onRemoteJobEnded(epoch: number, jobId: string): void {
    if (!this.isRemoteEventCurrent(epoch, jobId) || this.replayCleanupActive) {
      return;
    }
    this.player.waitForDrain((): void => {
      this.snapshot.playback = 'none';
      this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
      if (this.activeReplayMessageId.length > 0) {
        this.clearActiveReplayState();
        this.snapshot.statusDetail = '';
      }
      this.completePlaybackJob(jobId);
      this.callbacks.notify();
    });
  }

  onRemoteJobFallback(epoch: number, jobId: string): void {
    if (!this.isRemoteEventCurrent(epoch, jobId)) {
      return;
    }
    this.snapshot.ttsState = 'fallback';
    this.snapshot.statusDetail = 'TTS已降级';
    this.callbacks.notify();
  }

  onRemoteError(epoch: number, jobId: string, message: string): void {
    if (this.isRemoteEventCurrent(epoch, jobId) && !this.replayCleanupActive) {
      this.callbacks.onRemoteDisconnect(message.length > 0 ? message : 'TTS 连接失败');
    }
  }

  onRemoteClosed(epoch: number, jobId: string): void {
    if (this.isRemoteEventCurrent(epoch, jobId) && !this.replayCleanupActive) {
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
      this.completePlaybackJob(this.activePlaybackJobId);
      this.callbacks.notify();
    });
  }

  private stopPlaybackForReplay(): Promise<void> {
    this.pausedForUser = false;
    this.replayCleanupActive = true;
    this.callbacks.cancelRemoteReconnect();
    this.cancelPlaybackJobs();
    this.clearSystemSpeechQueue(false);
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
    if (this.useSystemSpeech) {
      const cleanup = this.systemTts?.stop() ?? Promise.resolve();
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
    this.activePlaybackJobId = this.beginPlaybackJob('replay', 20, text);
    if (this.activePlaybackJobId.length === 0) {
      this.replayCleanupActive = false;
      this.clearActiveReplayState();
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
    this.tts.setListener(new CoordinatorTtsListener(
      this,
      this.playbackEpoch,
      this.activePlaybackJobId
    ));
    this.tts.connect(this.callbacks.remoteUrl(), this.callbacks.cookie());
    this.tts.sendText(text);
    this.tts.sendDone();
  }

  private clearSystemSpeechQueue(clearReplayState: boolean = true): void {
    this.cancelSystemSpeechRetry();
    this.systemSpeechRetryCount = 0;
    this.systemSpeechSuspended = false;
    this.systemSpeechStartGeneration += 1;
    this.systemSpeechToken = '';
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
    const chunks = this.systemSpeechQueue.finishStream(finalText);
    this.speakSystemChunks(chunks);
    if (chunks.length === 0 && !this.systemSpeechQueue.hasPendingOutput()) {
      this.completePlaybackJob(this.activePlaybackJobId);
      this.snapshot.playback = 'none';
      this.snapshot.ttsState = this.enabled ? 'ready' : 'stopped';
      this.callbacks.notify();
    }
  }

  private startSystemReplay(text: string): void {
    const chunks = this.systemSpeechQueue.finishStream(text);
    if (chunks.length === 0) {
      this.completePlaybackJob(this.activePlaybackJobId);
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
    if (value.length === 0 || !this.systemTts) {
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
    const speech = this.systemTts;
    if (!speech || text.length === 0) {
      return;
    }
    if (!this.ensureAssistantPlaybackJob()) {
      return;
    }
    const generation = ++this.systemSpeechStartGeneration;
    const jobId = this.activePlaybackJobId;
    const token = `${this.playbackEpoch}:${jobId}:${generation}`;
    this.systemSpeechToken = token;
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
    this.audioCues.yieldForSpeech().then((): Promise<void> => {
      if (!this.isSystemSpeechStartCurrent(generation, text)) {
        return Promise.resolve();
      }
      return this.callbacks.ensurePlaybackReady();
    }).then((): void => {
      if (!this.isSystemSpeechStartCurrent(generation, text)) {
        this.callbacks.syncBackgroundState();
        return;
      }
      const latestConfig = this.callbacks.config();
      speech.speak(text, latestConfig.voicePerson, latestConfig.speechRate, token).catch((error: BusinessError) => {
        if (generation !== this.systemSpeechStartGeneration) {
          this.callbacks.syncBackgroundState();
          return;
        }
        this.clearSystemSpeechQueue();
        this.completePlaybackJob(jobId);
        this.systemSpeechToken = '';
        this.snapshot.ttsState = 'error';
        this.snapshot.playback = 'none';
        this.snapshot.statusDetail = '本地 TTS 启动失败';
        this.snapshot.error = this.errorMessage(error, '离线 TTS 启动失败');
        this.callbacks.notify();
      });
    }).catch((error: BusinessError): void => {
      if (!this.isSystemSpeechStartCurrent(generation, text)) {
        this.callbacks.syncBackgroundState();
        return;
      }
      this.clearSystemSpeechQueue();
      this.completePlaybackJob(jobId);
      this.systemSpeechToken = '';
      this.snapshot.ttsState = 'error';
      this.snapshot.playback = 'none';
      this.snapshot.statusDetail = '本地 TTS 输出准备失败';
      this.snapshot.error = this.errorMessage(error, '后台音频保持或提示音交接失败');
      this.callbacks.notify();
    });
  }

  private isSystemSpeechStartCurrent(generation: number, text: string): boolean {
    const config = this.callbacks.config();
    return generation === this.systemSpeechStartGeneration && this.useSystemSpeech &&
      this.enabled && !config.muted && !this.pausedForUser &&
      this.systemSpeechQueue.active() === text;
  }

  private scheduleSystemSpeechRetry(token: string): void {
    if (token !== this.systemSpeechToken || this.systemSpeechRetryTimer !== undefined) {
      return;
    }
    const text = this.systemSpeechQueue.active();
    if (text.length === 0) {
      return;
    }
    if (this.systemSpeechRetryCount >= SYSTEM_TTS_INTERRUPTION_RETRY_DELAYS_MS.length) {
      this.systemSpeechSuspended = true;
      this.snapshot.ttsState = 'ready';
      this.snapshot.playback = 'queued';
      this.snapshot.statusDetail = '系统暂停了本地播报，回到应用后继续';
      this.callbacks.syncBackgroundState();
      this.callbacks.notify();
      hilog.warn(
        OUTPUT_LOG_DOMAIN,
        OUTPUT_LOG_TAG,
        'system TTS segment suspended after interruptions length=%{public}d attempts=%{public}d',
        text.length,
        this.systemSpeechRetryCount
      );
      return;
    }
    const delay = SYSTEM_TTS_INTERRUPTION_RETRY_DELAYS_MS[this.systemSpeechRetryCount];
    this.systemSpeechRetryCount += 1;
    this.snapshot.ttsState = 'connecting';
    this.snapshot.playback = 'queued';
    this.callbacks.notify();
    hilog.warn(
      OUTPUT_LOG_DOMAIN,
      OUTPUT_LOG_TAG,
      'system TTS interrupted; retaining segment length=%{public}d retry=%{public}d delayMs=%{public}d',
      text.length,
      this.systemSpeechRetryCount,
      delay
    );
    this.systemSpeechRetryTimer = setTimeout((): void => {
      this.systemSpeechRetryTimer = undefined;
      if (token !== this.systemSpeechToken || this.pausedForUser || !this.enabled ||
        !this.useSystemSpeech || this.systemSpeechQueue.active() !== text) {
        return;
      }
      this.startSystemSpeech(text);
    }, delay);
  }

  private cancelSystemSpeechRetry(): void {
    if (this.systemSpeechRetryTimer !== undefined) {
      clearTimeout(this.systemSpeechRetryTimer);
      this.systemSpeechRetryTimer = undefined;
    }
  }

  private beginPlaybackJob(
    kind: PlaybackKind,
    priority: PlaybackPriority,
    text: string = '',
    cue: string = '',
    skippable: boolean = false
  ): string {
    const jobId = this.playbackQueue.enqueue(
      this.playbackEpoch,
      kind,
      priority,
      text,
      cue,
      skippable
    );
    const active = this.playbackQueue.activeJob();
    return active !== undefined && active.id === jobId ? jobId : '';
  }

  private ensureAssistantPlaybackJob(): boolean {
    if (this.activePlaybackJobId.length > 0 &&
      this.playbackQueue.isActive(this.playbackEpoch, this.activePlaybackJobId)) {
      return true;
    }
    this.audioCues.silence();
    const jobId = this.beginPlaybackJob('assistant', 20);
    if (jobId.length === 0) {
      return false;
    }
    this.activePlaybackJobId = jobId;
    if (!this.useSystemSpeech) {
      this.openRemoteForActiveJob();
    }
    return true;
  }

  private completePlaybackJob(jobId: string): void {
    if (jobId.length === 0) {
      return;
    }
    this.playbackQueue.complete(this.playbackEpoch, jobId);
    if (this.activePlaybackJobId === jobId) {
      this.activePlaybackJobId = '';
    }
  }

  private cancelPlaybackJobs(): void {
    this.playbackQueue.cancelAll(this.playbackEpoch);
    this.activePlaybackJobId = '';
    this.activeCueJobId = '';
  }

  private openRemoteForActiveJob(): void {
    if (this.activePlaybackJobId.length === 0) {
      return;
    }
    this.callbacks.cancelRemoteReconnect();
    this.tts.close();
    this.tts.setListener(new CoordinatorTtsListener(
      this,
      this.playbackEpoch,
      this.activePlaybackJobId
    ));
    this.tts.connect(this.callbacks.remoteUrl(), this.callbacks.cookie());
  }

  private isRemoteEventCurrent(epoch: number, jobId: string): boolean {
    if (epoch !== this.playbackEpoch) {
      return false;
    }
    if (jobId.length === 0) {
      return this.activePlaybackJobId.length === 0;
    }
    return this.playbackQueue.isActive(epoch, jobId);
  }

  private onPcmPlaybackFailure(message: string): void {
    if (this.activePlaybackJobId.length === 0) {
      return;
    }
    this.cancelPlaybackJobs();
    this.tts.close();
    this.player.stop().catch(() => undefined);
    this.snapshot.playback = 'none';
    this.snapshot.ttsState = 'error';
    this.snapshot.statusDetail = '远端 TTS 播放器已停止';
    this.snapshot.error = message;
    this.callbacks.syncBackgroundState();
    this.callbacks.notify();
  }

  failSystemSpeech(message: string): void {
    this.onSystemSpeechError(this.systemSpeechToken, message);
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }
}
