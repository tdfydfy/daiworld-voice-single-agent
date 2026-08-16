import { PcmPlayer } from './PcmPlayer';

const CUE_SAMPLE_RATE = 24000;
const RUNNING_INITIAL_DELAY_MS = 1200;
const RUNNING_INTERVAL_MS = 3200;
const PRIORITY_CUE_DELAY_MS = 120;
const CUE_CLEANUP_TIMEOUT_MS = 1200;

type CueKind = 'accepted' | 'running' | 'stop' | 'error';

class ToneSegment {
  durationMs: number;
  startFrequency: number;
  endFrequency: number;
  amplitude: number;

  constructor(durationMs: number, startFrequency: number, endFrequency: number, amplitude: number) {
    this.durationMs = durationMs;
    this.startFrequency = startFrequency;
    this.endFrequency = endFrequency;
    this.amplitude = amplitude;
  }
}

function createCue(segments: ToneSegment[]): ArrayBuffer {
  let totalSamples = 0;
  for (const segment of segments) {
    totalSamples += Math.max(1, Math.round(segment.durationMs * CUE_SAMPLE_RATE / 1000));
  }
  const result = new ArrayBuffer(totalSamples * 2);
  const bytes = new Uint8Array(result);
  let outputIndex = 0;
  let phase = 0;

  for (const segment of segments) {
    const sampleCount = Math.max(1, Math.round(segment.durationMs * CUE_SAMPLE_RATE / 1000));
    const fadeSamples = Math.max(
      1,
      Math.min(Math.round(CUE_SAMPLE_RATE * 0.012), Math.floor(sampleCount / 2))
    );
    for (let index = 0; index < sampleCount; index += 1) {
      const progress = sampleCount > 1 ? index / (sampleCount - 1) : 0;
      const frequency = segment.startFrequency +
        (segment.endFrequency - segment.startFrequency) * progress;
      const attack = Math.min(1, index / fadeSamples);
      const release = Math.min(1, (sampleCount - index - 1) / fadeSamples);
      const envelope = Math.max(0, Math.min(attack, release));
      let sample = 0;
      if (frequency > 0 && segment.amplitude > 0) {
        phase += 2 * Math.PI * frequency / CUE_SAMPLE_RATE;
        sample = Math.round(Math.sin(phase) * 32767 * segment.amplitude * envelope);
      }
      bytes[outputIndex] = sample & 0xFF;
      bytes[outputIndex + 1] = (sample >> 8) & 0xFF;
      outputIndex += 2;
    }
  }
  return result;
}

const ACCEPTED_CUE = createCue([
  new ToneSegment(105, 620, 880, 0.13)
]);

const RUNNING_CUE = createCue([
  new ToneSegment(115, 390, 450, 0.055)
]);

const STOP_CUE = createCue([
  new ToneSegment(190, 520, 260, 0.14)
]);

const ERROR_CUE = createCue([
  new ToneSegment(105, 280, 250, 0.13),
  new ToneSegment(65, 0, 0, 0),
  new ToneSegment(125, 250, 210, 0.13)
]);

export class AudioCuePlayer {
  private player?: PcmPlayer;
  private activeCue: CueKind | '' = '';
  private playbackGeneration: number = 0;
  private cueTimer?: number;
  private cleanupTimer?: number;
  private running: boolean = false;
  private runningTimer?: number;
  private playerCleanup?: Promise<void>;
  private speechYieldWaiters: Array<() => void> = [];
  private stateListener?: () => void;
  private playbackReadyListener?: () => Promise<void>;

  isRunning(): boolean {
    return this.running || this.activeCue.length > 0 || this.cueTimer !== undefined ||
      this.playerCleanup !== undefined;
  }

  setStateListener(listener: () => void): void {
    this.stateListener = listener;
  }

  setPlaybackReadyListener(listener: () => Promise<void>): void {
    this.playbackReadyListener = listener;
  }

  playAccepted(): void {
    this.playCue(ACCEPTED_CUE, 'accepted');
  }

  playStop(): void {
    this.playCue(STOP_CUE, 'stop', PRIORITY_CUE_DELAY_MS);
  }

  playError(): void {
    this.playCue(ERROR_CUE, 'error', PRIORITY_CUE_DELAY_MS);
  }

  setRunning(active: boolean): void {
    if (this.running === active) {
      return;
    }
    this.running = active;
    this.clearRunningTimer();
    this.notifyStateChanged();
    if (!active && this.activeCue === 'running') {
      // The cue already has a short fade-out. Let it drain instead of cutting
      // the waveform mid-cycle before a higher-priority speech output.
      return;
    }
    if (active) {
      this.scheduleRunningPulse(RUNNING_INITIAL_DELAY_MS);
    }
  }

  silence(): void {
    this.running = false;
    this.clearRunningTimer();
    this.clearCueTimer();
    this.stopActiveCue();
    this.notifyStateChanged();
  }

  async dispose(): Promise<void> {
    this.running = false;
    this.clearRunningTimer();
    this.clearCueTimer();
    if (this.cleanupTimer !== undefined) {
      clearTimeout(this.cleanupTimer);
      this.cleanupTimer = undefined;
    }
    const player = this.player;
    this.player = undefined;
    this.activeCue = '';
    this.playbackGeneration += 1;
    if (player) {
      this.enqueuePlayerCleanup(player);
    }
    this.notifyStateChanged();
    const cleanup = this.playerCleanup;
    if (cleanup) {
      await cleanup;
    }
    this.resolveSpeechYieldWaiters();
  }

  yieldForSpeech(): Promise<void> {
    this.running = false;
    this.clearRunningTimer();
    this.clearCueTimer();
    this.notifyStateChanged();
    if (this.activeCue.length > 0 && !this.player) {
      this.activeCue = '';
      this.playbackGeneration += 1;
      this.notifyStateChanged();
    }
    if (!this.player || this.activeCue.length === 0) {
      return this.playerCleanup ?? Promise.resolve();
    }
    return new Promise<void>((resolve: () => void): void => {
      this.speechYieldWaiters.push(resolve);
    });
  }

  private scheduleRunningPulse(delayMs: number): void {
    this.runningTimer = setTimeout((): void => {
      this.runningTimer = undefined;
      if (!this.running) {
        return;
      }
      this.playCue(RUNNING_CUE, 'running');
      this.scheduleRunningPulse(RUNNING_INTERVAL_MS);
    }, delayMs);
  }

  private playCue(buffer: ArrayBuffer, kind: CueKind, delayMs: number = 0): void {
    this.clearCueTimer();
    this.stopActiveCue(false);
    if (delayMs > 0) {
      this.cueTimer = setTimeout((): void => {
        this.cueTimer = undefined;
        this.startCue(buffer, kind);
      }, delayMs);
      this.notifyStateChanged();
      return;
    }
    this.startCue(buffer, kind);
  }

  private startCue(buffer: ArrayBuffer, kind: CueKind): void {
    const generation = this.playbackGeneration + 1;
    this.playbackGeneration = generation;
    this.activeCue = kind;
    this.notifyStateChanged();
    const cleanup = this.playerCleanup ?? Promise.resolve();
    cleanup.then((): Promise<void> => {
      return this.playbackReadyListener?.() ?? Promise.resolve();
    }).then((): void => {
      if (generation !== this.playbackGeneration || this.activeCue !== kind) {
        return;
      }
      const player = new PcmPlayer();
      player.setFailureListener((): void => {
        this.finishCue(player, generation);
      });
      player.setSampleRate(CUE_SAMPLE_RATE);
      this.player = player;
      player.enqueue(buffer);
      player.waitForDrain((): void => {
        this.finishCue(player, generation);
      });
      this.cleanupTimer = setTimeout((): void => {
        this.cleanupTimer = undefined;
        this.finishCue(player, generation);
      }, CUE_CLEANUP_TIMEOUT_MS);
    }).catch((): void => {
      if (generation !== this.playbackGeneration) {
        return;
      }
      this.player = undefined;
      this.activeCue = '';
      this.playbackGeneration += 1;
      this.notifyStateChanged();
      this.resolveSpeechYieldWaiters();
    });
  }

  private finishCue(player: PcmPlayer, generation: number): void {
    if (generation !== this.playbackGeneration) {
      this.enqueuePlayerCleanup(player);
      return;
    }
    if (this.cleanupTimer !== undefined) {
      clearTimeout(this.cleanupTimer);
      this.cleanupTimer = undefined;
    }
    this.player = undefined;
    this.activeCue = '';
    this.playbackGeneration += 1;
    this.enqueuePlayerCleanup(player);
    this.notifyStateChanged();
  }

  private stopActiveCue(notify: boolean = true): void {
    if (this.cleanupTimer !== undefined) {
      clearTimeout(this.cleanupTimer);
      this.cleanupTimer = undefined;
    }
    const player = this.player;
    this.player = undefined;
    this.activeCue = '';
    this.playbackGeneration += 1;
    if (notify) {
      this.notifyStateChanged();
    }
    if (!player) {
      if (!this.playerCleanup) {
        this.resolveSpeechYieldWaiters();
      }
      return;
    }
    this.enqueuePlayerCleanup(player);
  }

  private enqueuePlayerCleanup(player: PcmPlayer): Promise<void> {
    const previous = this.playerCleanup ?? Promise.resolve();
    const cleanup = previous.then((): Promise<void> => {
      return player.dispose().catch(() => undefined);
    });
    this.playerCleanup = cleanup;
    cleanup.finally((): void => {
      if (this.playerCleanup !== cleanup) {
        return;
      }
      this.playerCleanup = undefined;
      this.notifyStateChanged();
      this.resolveSpeechYieldWaiters();
    });
    return cleanup;
  }

  private resolveSpeechYieldWaiters(): void {
    const waiters = this.speechYieldWaiters;
    this.speechYieldWaiters = [];
    for (const resolve of waiters) {
      resolve();
    }
  }

  private clearCueTimer(): void {
    if (this.cueTimer !== undefined) {
      clearTimeout(this.cueTimer);
      this.cueTimer = undefined;
    }
  }

  private clearRunningTimer(): void {
    if (this.runningTimer !== undefined) {
      clearTimeout(this.runningTimer);
      this.runningTimer = undefined;
    }
  }

  private notifyStateChanged(): void {
    if (this.stateListener) {
      this.stateListener();
    }
  }
}
