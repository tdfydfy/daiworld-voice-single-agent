// PCM playback queue for remote TTS and short local cues.

import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommunicationAudioSessionLease } from './CommunicationAudioSession';
import { RecoveryBudget } from './RecoveryBudget';

const AUDIO_LOG_DOMAIN = 0xD002;
const AUDIO_LOG_TAG = 'SingleAgentAudio';
const PCM_RENDERER_RECOVERY_DELAYS_MS: number[] = [100, 500, 1500, 3000];
const PCM_RENDERER_RECOVERY_WINDOW_MS = 60000;
const PCM_RENDERER_STABLE_RESET_MS = 10000;
const PCM_RENDERER_WATCHDOG_MS = 1200;
const PCM_RENDERER_STALL_LIMIT = 2;
const PCM_DRAIN_RETRY_DELAYS_MS: number[] = [100, 500, 1500];

export type DrainedListener = () => void;
export type PlaybackFailureListener = (message: string) => void;

export class PcmPlayer {
  private renderer?: audio.AudioRenderer;
  private rendererCreating?: Promise<audio.AudioRenderer>;
  private queue: Uint8Array[] = [];
  private queueOffset: number = 0;
  private generation: number = 0;
  private paused: boolean = false;
  private pendingDrain: DrainedListener | undefined = undefined;
  private drainTask?: Promise<void>;
  private drainRetryTimer?: number;
  private drainRetryAttempt: number = 0;
  private sampleRate: number = 24000;
  private channelCount: number = 1;
  private rendererSampleRate: number = 0;
  private rendererChannelCount: number = 0;
  private session: CommunicationAudioSessionLease = new CommunicationAudioSessionLease();
  private communication: boolean;
  private rendererRecovery?: Promise<void>;
  private rendererRetryTimer?: number;
  private rendererRecoveryBudget: RecoveryBudget = new RecoveryBudget(
    PCM_RENDERER_RECOVERY_DELAYS_MS.length,
    PCM_RENDERER_RECOVERY_WINDOW_MS,
    PCM_RENDERER_STABLE_RESET_MS
  );
  private rendererFailed: boolean = false;
  private disposed: boolean = false;
  private failureListener?: PlaybackFailureListener;
  private rendererWatchdog?: number;
  private rendererWatchdogFramePos?: number;
  private rendererStallCount: number = 0;
  private rendererReplayTail: Uint8Array = new Uint8Array(0);

  constructor(communication: boolean = true) {
    this.communication = communication;
    if (communication) {
      this.session.setRecoveryListener((): void => {
        this.onCommunicationSessionRecovered();
      });
    }
  }

  setFailureListener(listener: PlaybackFailureListener): void {
    this.failureListener = listener;
  }

  private async ensureRenderer(): Promise<audio.AudioRenderer> {
    if (this.renderer) {
      if (this.rendererSampleRate === this.sampleRate &&
        this.rendererChannelCount === this.channelCount) {
        return this.renderer;
      }
      const staleRenderer = this.renderer;
      this.renderer = undefined;
      this.rendererSampleRate = 0;
      this.rendererChannelCount = 0;
      await this.releaseRenderer(staleRenderer, false);
    }
    if (this.rendererCreating) {
      await this.rendererCreating;
      return this.ensureRenderer();
    }
    const generation = this.generation;
    const sampleRate = this.sampleRate;
    const channelCount = this.channelCount;
    const creation = this.createRenderer(generation, sampleRate, channelCount);
    this.rendererCreating = creation;
    try {
      return await creation;
    } finally {
      if (this.rendererCreating === creation) {
        this.rendererCreating = undefined;
      }
    }
  }

  private async createRenderer(
    generation: number,
    sampleRate: number,
    channelCount: number
  ): Promise<audio.AudioRenderer> {
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: this.samplingRateForRenderer(sampleRate),
        channels: this.channelForRenderer(channelCount),
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      rendererInfo: {
        usage: this.communication
          ? audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION
          : audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT,
        rendererFlags: 0
      }
    };
    if (this.communication) {
      await this.session.acquire();
    }
    let renderer: audio.AudioRenderer;
    try {
      renderer = await audio.createAudioRenderer(options);
    } catch (error) {
      await this.session.release();
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
    try {
      renderer.on('writeData', (buffer: ArrayBuffer) => {
        this.fillPlaybackBuffer(buffer);
      });
      renderer.on('stateChange', (state: audio.AudioState): void => {
        this.onRendererStateChange(renderer, generation, state);
      });
      renderer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        this.onRendererInterrupt(renderer, generation, event);
      });
      await renderer.start();
    } catch (error) {
      try {
        renderer.off('writeData');
        renderer.off('stateChange');
        renderer.off('audioInterrupt');
      } catch (offError) {
      }
      await renderer.release().catch(() => undefined);
      await this.session.release();
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
    if (generation !== this.generation || sampleRate !== this.sampleRate ||
      channelCount !== this.channelCount) {
      try {
        renderer.off('writeData');
        renderer.off('stateChange');
        renderer.off('audioInterrupt');
      } catch (error) {
      }
      await renderer.stop();
      await renderer.release();
      await this.session.release();
      throw new Error('Playback was interrupted');
    }
    this.renderer = renderer;
    this.rendererSampleRate = sampleRate;
    this.rendererChannelCount = channelCount;
    return renderer;
  }

  private samplingRateForRenderer(sampleRate: number): audio.AudioSamplingRate {
    switch (sampleRate) {
      case 8000:
        return audio.AudioSamplingRate.SAMPLE_RATE_8000;
      case 11025:
        return audio.AudioSamplingRate.SAMPLE_RATE_11025;
      case 12000:
        return audio.AudioSamplingRate.SAMPLE_RATE_12000;
      case 16000:
        return audio.AudioSamplingRate.SAMPLE_RATE_16000;
      case 22050:
        return audio.AudioSamplingRate.SAMPLE_RATE_22050;
      case 32000:
        return audio.AudioSamplingRate.SAMPLE_RATE_32000;
      case 44100:
        return audio.AudioSamplingRate.SAMPLE_RATE_44100;
      case 48000:
        return audio.AudioSamplingRate.SAMPLE_RATE_48000;
      case 64000:
        return audio.AudioSamplingRate.SAMPLE_RATE_64000;
      case 88200:
        return audio.AudioSamplingRate.SAMPLE_RATE_88200;
      case 96000:
        return audio.AudioSamplingRate.SAMPLE_RATE_96000;
      default:
        return audio.AudioSamplingRate.SAMPLE_RATE_24000;
    }
  }

  private channelForRenderer(channelCount: number): audio.AudioChannel {
    return channelCount === 2
      ? audio.AudioChannel.CHANNEL_2
      : audio.AudioChannel.CHANNEL_1;
  }

  setAudioFormat(sampleRate: number, channelCount: number): void {
    if (sampleRate > 0 && (channelCount === 1 || channelCount === 2)) {
      this.sampleRate = sampleRate;
      this.channelCount = channelCount;
    }
  }

  setSampleRate(rate: number): void {
    this.setAudioFormat(rate, this.channelCount);
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  enqueue(buffer: ArrayBuffer): void {
    if (this.disposed || this.rendererFailed) {
      return;
    }
    this.queue.push(new Uint8Array(buffer));
    this.rendererStallCount = 0;
    this.drainRetryAttempt = 0;
    if (!this.paused) {
      this.requestPlayback();
    }
  }

  clearQueue(): void {
    this.queue = [];
    this.queueOffset = 0;
    this.cancelRendererRecovery(true);
    this.rendererFailed = false;
  }

  hasQueued(): boolean {
    return this.queue.length > 0;
  }

  async pause(): Promise<void> {
    this.paused = true;
    this.cancelRendererRecovery();
    const renderer = this.renderer;
    if (renderer) {
      await renderer.pause().catch(() => undefined);
    }
  }

  async resume(): Promise<void> {
    this.paused = false;
    if (this.queue.length > 0) {
      this.requestPlayback();
    }
  }

  // Fires when the queue has been fully consumed by the renderer.
  waitForDrain(listener: DrainedListener): void {
    this.pendingDrain = listener;
    if (this.queue.length === 0) {
      this.deferRendererDrain();
    }
  }

  async stop(): Promise<void> {
    this.generation += 1;
    this.cancelRendererRecovery(true);
    this.rendererFailed = false;
    this.queue = [];
    this.queueOffset = 0;
    this.paused = false;
    this.pendingDrain = undefined;
    this.drainTask = undefined;
    this.rendererReplayTail = new Uint8Array(0);
    this.drainRetryAttempt = 0;
    if (this.drainRetryTimer !== undefined) {
      clearTimeout(this.drainRetryTimer);
      this.drainRetryTimer = undefined;
    }
    const creating = this.rendererCreating;
    if (creating) {
      await creating.catch(() => undefined);
    }
    const recovering = this.rendererRecovery;
    if (recovering) {
      await recovering.catch(() => undefined);
    }
    const renderer = this.renderer;
    this.renderer = undefined;
    this.rendererSampleRate = 0;
    this.rendererChannelCount = 0;
    if (!renderer) {
      return;
    }
    try {
      renderer.off('writeData');
      renderer.off('stateChange');
      renderer.off('audioInterrupt');
    } catch (error) {
    }
    await renderer.stop().catch(() => undefined);
    await renderer.release().catch(() => undefined);
    await this.session.release();
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.generation += 1;
    this.cancelRendererRecovery(true);
    this.queue = [];
    this.queueOffset = 0;
    this.paused = false;
    this.pendingDrain = undefined;
    this.rendererReplayTail = new Uint8Array(0);
    if (this.drainRetryTimer !== undefined) {
      clearTimeout(this.drainRetryTimer);
      this.drainRetryTimer = undefined;
    }
    const renderer = this.renderer;
    this.renderer = undefined;
    this.rendererSampleRate = 0;
    this.rendererChannelCount = 0;
    if (renderer) {
      await this.releaseRenderer(renderer, true).catch(() => undefined);
    } else {
      await this.session.release().catch(() => undefined);
    }
  }

  private fillPlaybackBuffer(buffer: ArrayBuffer): void {
    this.rendererStallCount = 0;
    const output = new Uint8Array(buffer);
    let outputOffset = 0;
    while (outputOffset < output.length && this.queue.length > 0) {
      const source = this.queue[0];
      const available = source.length - this.queueOffset;
      const requested = output.length - outputOffset;
      const count = Math.min(available, requested);
      output.set(
        source.subarray(this.queueOffset, this.queueOffset + count),
        outputOffset
      );
      outputOffset += count;
      this.queueOffset += count;
      if (this.queueOffset >= source.length) {
        this.queue.shift();
        this.queueOffset = 0;
      }
    }
    if (outputOffset < output.length) {
      output.fill(0, outputOffset);
    }
    if (outputOffset > 0) {
      this.rendererReplayTail = output.slice(0, outputOffset);
      this.observeRendererHealth();
    }
    if (this.queue.length === 0 && this.pendingDrain) {
      this.cancelRendererWatchdog();
      this.deferRendererDrain();
    } else if (this.queue.length > 0) {
      this.armRendererWatchdog();
    }
  }

  private requestPlayback(recreateRenderer: boolean = false): void {
    if (this.disposed || this.rendererFailed || this.paused ||
      (this.queue.length === 0 && !this.pendingDrain) ||
      this.rendererRecovery !== undefined) {
      return;
    }
    if (this.rendererRetryTimer !== undefined) {
      clearTimeout(this.rendererRetryTimer);
      this.rendererRetryTimer = undefined;
    }
    const generation = this.generation;
    const recovery = this.ensurePlaybackRunning(generation, recreateRenderer);
    this.rendererRecovery = recovery;
    recovery.then((): void => {
      if (generation !== this.generation || this.paused ||
        (this.queue.length === 0 && !this.pendingDrain)) {
        return;
      }
      if (this.queue.length > 0) {
        this.armRendererWatchdog();
      } else {
        this.deferRendererDrain();
      }
    }).catch((error: BusinessError): void => {
      if (generation !== this.generation || this.paused ||
        (this.queue.length === 0 && !this.pendingDrain)) {
        return;
      }
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'PCM renderer recovery failed: %{public}s',
        error.message
      );
      this.scheduleRendererRecovery(error.message);
    }).finally((): void => {
      if (this.rendererRecovery === recovery) {
        this.rendererRecovery = undefined;
      }
    });
  }

  private async ensurePlaybackRunning(
    generation: number,
    recreateRenderer: boolean
  ): Promise<void> {
    if (recreateRenderer && this.renderer) {
      const staleRenderer = this.renderer;
      this.renderer = undefined;
      this.restoreUnconfirmedRendererTail();
      await this.releaseRenderer(staleRenderer, false);
    }
    let renderer = await this.ensureRenderer();
    if (generation !== this.generation) {
      throw new Error('Playback was interrupted');
    }
    if (renderer.state === audio.AudioState.STATE_INVALID ||
      renderer.state === audio.AudioState.STATE_RELEASED) {
      this.renderer = undefined;
      this.restoreUnconfirmedRendererTail();
      await this.releaseRenderer(renderer, false);
      renderer = await this.ensureRenderer();
    }
    if (generation !== this.generation) {
      throw new Error('Playback was interrupted');
    }
    if (renderer.state !== audio.AudioState.STATE_RUNNING) {
      await renderer.start();
    }
  }

  private async releaseRenderer(
    renderer: audio.AudioRenderer,
    releaseSession: boolean
  ): Promise<void> {
    try {
      renderer.off('writeData');
      renderer.off('stateChange');
      renderer.off('audioInterrupt');
    } catch (error) {
    }
    if (renderer.state !== audio.AudioState.STATE_RELEASED) {
      await renderer.stop().catch(() => undefined);
      await renderer.release().catch(() => undefined);
    }
    if (releaseSession) {
      await this.session.release();
    }
  }

  private scheduleRendererRecovery(reason: string): void {
    if (this.rendererFailed || this.paused || (this.queue.length === 0 && !this.pendingDrain) ||
      this.rendererRetryTimer !== undefined) {
      return;
    }
    const attempt = this.rendererRecoveryBudget.beginAttempt();
    if (attempt <= 0) {
      this.failPlayback(`PCM renderer recovery exhausted: ${reason}`);
      return;
    }
    const delay = PCM_RENDERER_RECOVERY_DELAYS_MS[attempt - 1];
    this.rendererRetryTimer = setTimeout((): void => {
      this.rendererRetryTimer = undefined;
      this.requestPlayback(true);
    }, delay);
  }

  private armRendererWatchdog(): void {
    this.cancelRendererWatchdog();
    if (this.paused || this.queue.length === 0) {
      return;
    }
    const renderer = this.renderer;
    const generation = this.generation;
    if (!renderer) {
      this.scheduleRendererRecovery('renderer unavailable');
      return;
    }
    this.rendererWatchdog = setTimeout((): void => {
      this.rendererWatchdog = undefined;
      if (this.paused || this.queue.length === 0 || generation !== this.generation ||
        renderer !== this.renderer) {
        return;
      }
      if (renderer.state !== audio.AudioState.STATE_RUNNING) {
        this.scheduleRendererRecovery(`renderer state ${renderer.state}`);
        return;
      }
      let framePos: number;
      try {
        framePos = renderer.getAudioTimestampInfoSync().framePos;
      } catch (error) {
        this.armRendererWatchdog();
        return;
      }
      if (this.rendererWatchdogFramePos === undefined || framePos > this.rendererWatchdogFramePos) {
        this.rendererWatchdogFramePos = framePos;
        this.rendererStallCount = 0;
        this.observeRendererHealth();
        this.armRendererWatchdog();
        return;
      }
      this.rendererStallCount += 1;
      if (this.rendererStallCount < PCM_RENDERER_STALL_LIMIT) {
        this.armRendererWatchdog();
        return;
      }
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'PCM renderer frame position stalled with queued audio; recreating renderer'
      );
      this.rendererStallCount = 0;
      this.scheduleRendererRecovery('renderer frame position stalled');
    }, PCM_RENDERER_WATCHDOG_MS);
  }

  private cancelRendererWatchdog(): void {
    if (this.rendererWatchdog !== undefined) {
      clearTimeout(this.rendererWatchdog);
      this.rendererWatchdog = undefined;
    }
  }

  private cancelRendererRecovery(resetBudget: boolean = false): void {
    if (this.rendererRetryTimer !== undefined) {
      clearTimeout(this.rendererRetryTimer);
      this.rendererRetryTimer = undefined;
    }
    this.cancelRendererWatchdog();
    this.rendererWatchdogFramePos = undefined;
    this.rendererStallCount = 0;
    if (resetBudget) {
      this.rendererRecoveryBudget.reset();
    }
  }

  private onCommunicationSessionRecovered(): void {
    if (!this.communication || this.paused ||
      (this.queue.length === 0 && !this.pendingDrain)) {
      return;
    }
    this.requestPlayback();
  }

  private onRendererStateChange(
    renderer: audio.AudioRenderer,
    generation: number,
    state: audio.AudioState
  ): void {
    if (generation !== this.generation || this.renderer !== renderer || this.paused ||
      (this.queue.length === 0 && !this.pendingDrain)) {
      return;
    }
    if (state === audio.AudioState.STATE_STOPPED || state === audio.AudioState.STATE_RELEASED ||
      state === audio.AudioState.STATE_INVALID) {
      this.scheduleRendererRecovery(`renderer terminal state ${state}`);
    }
  }

  private onRendererInterrupt(
    renderer: audio.AudioRenderer,
    generation: number,
    event: audio.InterruptEvent
  ): void {
    if (generation !== this.generation || this.renderer !== renderer || this.paused ||
      (this.queue.length === 0 && !this.pendingDrain)) {
      return;
    }
    if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_END &&
      event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      this.requestPlayback();
    }
  }

  private drainRenderer(): void {
    if (!this.pendingDrain || this.queue.length > 0 || this.drainTask) {
      return;
    }
    const renderer = this.renderer;
    if (!renderer) {
      if (this.rendererCreating || this.rendererRecovery) {
        this.requestPlayback();
        return;
      }
      const listener = this.pendingDrain;
      this.pendingDrain = undefined;
      this.rendererReplayTail = new Uint8Array(0);
      this.drainRetryAttempt = 0;
      listener();
      return;
    }
    const generation = this.generation;
    const drain = renderer.drain();
    let drainFailed = false;
    this.drainTask = drain;
    drain.then((): void => {
      if (generation !== this.generation || renderer !== this.renderer || !this.pendingDrain) {
        return;
      }
      if (this.queue.length > 0) {
        this.requestPlayback();
        return;
      }
      const listener = this.pendingDrain;
      this.pendingDrain = undefined;
      this.rendererReplayTail = new Uint8Array(0);
      this.drainRetryAttempt = 0;
      listener();
    }).catch((error: BusinessError): void => {
      if (generation !== this.generation || !this.pendingDrain) {
        return;
      }
      drainFailed = true;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'PCM renderer drain failed: %{public}s',
        error.message
      );
      if (renderer.state !== audio.AudioState.STATE_INVALID &&
        renderer.state !== audio.AudioState.STATE_RELEASED &&
        this.drainRetryAttempt < PCM_DRAIN_RETRY_DELAYS_MS.length) {
        const delay = PCM_DRAIN_RETRY_DELAYS_MS[this.drainRetryAttempt];
        this.drainRetryAttempt += 1;
        this.drainRetryTimer = setTimeout((): void => {
          this.drainRetryTimer = undefined;
          if (generation === this.generation) {
            this.drainRenderer();
          }
        }, delay);
      } else {
        this.scheduleRendererRecovery('renderer drain failed');
      }
    }).finally((): void => {
      if (this.drainTask === drain) {
        this.drainTask = undefined;
      }
      if ((!drainFailed || generation !== this.generation) &&
        this.pendingDrain && this.queue.length === 0) {
        this.drainRenderer();
      }
    });
  }

  private deferRendererDrain(): void {
    setTimeout((): void => {
      this.drainRenderer();
    }, 0);
  }

  private restoreUnconfirmedRendererTail(): void {
    if (this.rendererReplayTail.length === 0) {
      return;
    }
    this.queue.unshift(this.rendererReplayTail);
    this.queueOffset = 0;
    this.rendererReplayTail = new Uint8Array(0);
  }

  private observeRendererHealth(): void {
    this.rendererRecoveryBudget.observeHealthy();
  }

  private failPlayback(message: string): void {
    if (this.rendererFailed) {
      return;
    }
    this.rendererFailed = true;
    this.generation += 1;
    this.cancelRendererRecovery(false);
    this.queue = [];
    this.queueOffset = 0;
    this.pendingDrain = undefined;
    this.rendererReplayTail = new Uint8Array(0);
    const renderer = this.renderer;
    this.renderer = undefined;
    this.rendererSampleRate = 0;
    this.rendererChannelCount = 0;
    if (renderer) {
      this.releaseRenderer(renderer, true).catch(() => undefined);
    } else {
      this.session.release().catch(() => undefined);
    }
    hilog.error(AUDIO_LOG_DOMAIN, AUDIO_LOG_TAG, '%{public}s', message);
    this.failureListener?.(message);
  }
}
