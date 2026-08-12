// PCM playback queue for remote TTS and short local cues.

import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommunicationAudioSessionLease } from './CommunicationAudioSession';

const AUDIO_LOG_DOMAIN = 0xD002;
const AUDIO_LOG_TAG = 'SingleAgentAudio';
const PCM_RENDERER_RECOVERY_DELAYS_MS: number[] = [100, 500, 1500, 3000];
const PCM_RENDERER_WATCHDOG_MS = 1200;

export type DrainedListener = () => void;

export class PcmPlayer {
  private renderer?: audio.AudioRenderer;
  private rendererCreating?: Promise<audio.AudioRenderer>;
  private queue: Uint8Array[] = [];
  private queueOffset: number = 0;
  private generation: number = 0;
  private paused: boolean = false;
  private pendingDrain: DrainedListener | undefined = undefined;
  private drainTimer: number | undefined = undefined;
  private lastBufferDurationMs: number = 0;
  private sampleRate: number = 24000;
  private session: CommunicationAudioSessionLease = new CommunicationAudioSessionLease();
  private communication: boolean;
  private rendererRecovery?: Promise<void>;
  private rendererRetryTimer?: number;
  private rendererRetryAttempt: number = 0;
  private rendererWatchdog?: number;
  private lastRendererWriteAt: number = 0;

  constructor(communication: boolean = true) {
    this.communication = communication;
    if (communication) {
      this.session.addRecoveryListener((): void => {
        this.onCommunicationSessionRecovered();
      });
    }
  }

  private async ensureRenderer(): Promise<audio.AudioRenderer> {
    if (this.renderer) {
      return this.renderer;
    }
    if (this.rendererCreating) {
      return this.rendererCreating;
    }
    const generation = this.generation;
    const creation = this.createRenderer(generation);
    this.rendererCreating = creation;
    try {
      return await creation;
    } finally {
      if (this.rendererCreating === creation) {
        this.rendererCreating = undefined;
      }
    }
  }

  private async createRenderer(generation: number): Promise<audio.AudioRenderer> {
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
        channels: audio.AudioChannel.CHANNEL_1,
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
    if (generation !== this.generation) {
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
    return renderer;
  }

  setSampleRate(rate: number): void {
    if (rate > 0) {
      this.sampleRate = rate;
    }
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  enqueue(buffer: ArrayBuffer): void {
    this.queue.push(new Uint8Array(buffer));
    if (!this.paused) {
      this.requestPlayback();
    }
  }

  clearQueue(): void {
    this.queue = [];
    this.queueOffset = 0;
    this.cancelRendererRecovery();
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
    if (this.queue.length === 0) {
      this.scheduleDrain(listener);
      return;
    }
    this.pendingDrain = listener;
  }

  async stop(): Promise<void> {
    this.generation += 1;
    this.cancelRendererRecovery();
    this.queue = [];
    this.queueOffset = 0;
    this.paused = false;
    this.pendingDrain = undefined;
    if (this.drainTimer !== undefined) {
      clearTimeout(this.drainTimer);
      this.drainTimer = undefined;
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

  private fillPlaybackBuffer(buffer: ArrayBuffer): void {
    this.lastRendererWriteAt = Date.now();
    this.rendererRetryAttempt = 0;
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
    this.lastBufferDurationMs = Math.ceil(
      (outputOffset / (Math.max(this.sampleRate, 1) * 2)) * 1000
    );
    if (this.queue.length === 0 && this.pendingDrain) {
      this.cancelRendererWatchdog();
      const listener = this.pendingDrain;
      this.pendingDrain = undefined;
      this.scheduleDrain(listener);
    } else if (this.queue.length > 0) {
      this.armRendererWatchdog();
    }
  }

  private requestPlayback(recreateRenderer: boolean = false): void {
    if (this.paused || this.queue.length === 0 || this.rendererRecovery !== undefined) {
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
      if (generation !== this.generation || this.paused || this.queue.length === 0) {
        return;
      }
      this.rendererRetryAttempt = 0;
      this.armRendererWatchdog();
    }).catch((error: BusinessError): void => {
      if (generation !== this.generation || this.paused || this.queue.length === 0) {
        return;
      }
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'PCM renderer recovery failed: %{public}s',
        error.message
      );
      this.scheduleRendererRecovery();
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
      await this.releaseRenderer(staleRenderer, false);
    }
    let renderer = await this.ensureRenderer();
    if (generation !== this.generation) {
      throw new Error('Playback was interrupted');
    }
    if (renderer.state === audio.AudioState.STATE_INVALID ||
      renderer.state === audio.AudioState.STATE_RELEASED) {
      this.renderer = undefined;
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

  private scheduleRendererRecovery(): void {
    if (this.paused || this.queue.length === 0 || this.rendererRetryTimer !== undefined) {
      return;
    }
    const index = Math.min(
      this.rendererRetryAttempt,
      PCM_RENDERER_RECOVERY_DELAYS_MS.length - 1
    );
    const delay = PCM_RENDERER_RECOVERY_DELAYS_MS[index];
    this.rendererRetryAttempt = Math.min(
      this.rendererRetryAttempt + 1,
      PCM_RENDERER_RECOVERY_DELAYS_MS.length
    );
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
    const observedWriteAt = this.lastRendererWriteAt;
    this.rendererWatchdog = setTimeout((): void => {
      this.rendererWatchdog = undefined;
      if (this.paused || this.queue.length === 0 || observedWriteAt !== this.lastRendererWriteAt) {
        return;
      }
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'PCM renderer stalled with queued audio; recreating renderer'
      );
      this.requestPlayback(true);
    }, PCM_RENDERER_WATCHDOG_MS);
  }

  private cancelRendererWatchdog(): void {
    if (this.rendererWatchdog !== undefined) {
      clearTimeout(this.rendererWatchdog);
      this.rendererWatchdog = undefined;
    }
  }

  private cancelRendererRecovery(): void {
    if (this.rendererRetryTimer !== undefined) {
      clearTimeout(this.rendererRetryTimer);
      this.rendererRetryTimer = undefined;
    }
    this.cancelRendererWatchdog();
    this.rendererRetryAttempt = 0;
    this.lastRendererWriteAt = 0;
  }

  private onCommunicationSessionRecovered(): void {
    if (!this.communication || this.paused || this.queue.length === 0) {
      return;
    }
    this.requestPlayback(true);
  }

  private onRendererStateChange(
    renderer: audio.AudioRenderer,
    generation: number,
    state: audio.AudioState
  ): void {
    if (generation !== this.generation || this.renderer !== renderer || this.paused ||
      this.queue.length === 0) {
      return;
    }
    if (state === audio.AudioState.STATE_STOPPED || state === audio.AudioState.STATE_RELEASED ||
      state === audio.AudioState.STATE_INVALID) {
      this.requestPlayback(state !== audio.AudioState.STATE_STOPPED);
    }
  }

  private onRendererInterrupt(
    renderer: audio.AudioRenderer,
    generation: number,
    event: audio.InterruptEvent
  ): void {
    if (generation !== this.generation || this.renderer !== renderer || this.paused ||
      this.queue.length === 0) {
      return;
    }
    if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_END &&
      event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      this.requestPlayback();
    }
  }

  private scheduleDrain(listener: DrainedListener): void {
    if (this.lastBufferDurationMs <= 0) {
      listener();
      return;
    }
    this.drainTimer = setTimeout((): void => {
      this.drainTimer = undefined;
      listener();
    }, this.lastBufferDurationMs);
  }
}
