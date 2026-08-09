// PCM capture/playback infrastructure for the Single-Agent HarmonyOS client.
// Reused from the Host project's platform audio layer; extended with
// pause/resume/clear/drain semantics required by the Single-Agent TTS spec
// (docs/INTERACTION_AND_PORTING_SPEC.md section 7).

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const AUDIO_LOG_DOMAIN = 0xD002;
const AUDIO_LOG_TAG = 'SingleAgentAudio';

export type AudioChunkListener = (buffer: ArrayBuffer) => void;
export type DrainedListener = () => void;

export class PcmCapture {
  private capturer?: audio.AudioCapturer;
  private listener?: AudioChunkListener;
  private lastReadAt: number = 0;
  private readCount: number = 0;

  async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    const result = await manager.requestPermissionsFromUser(context, permissions);
    return result.authResults.length > 0 && result.authResults[0] === 0;
  }

  async start(listener: AudioChunkListener): Promise<void> {
    if (this.capturer) {
      return;
    }
    this.listener = listener;
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION,
        capturerFlags: 0
      }
    };
    const capturer = await audio.createAudioCapturer(options);
    capturer.on('readData', (buffer: ArrayBuffer) => {
      const now = Date.now();
      const gap = this.lastReadAt > 0 ? now - this.lastReadAt : 0;
      this.lastReadAt = now;
      this.readCount += 1;
      if (this.readCount <= 5 || gap > 150) {
        hilog.info(
          AUDIO_LOG_DOMAIN,
          AUDIO_LOG_TAG,
          'capture bytes=%{public}d gapMs=%{public}d',
          buffer.byteLength,
          gap
        );
      }
      this.listener?.(buffer);
    });
    await capturer.start();
    this.capturer = capturer;
  }

  async stop(): Promise<void> {
    const capturer = this.capturer;
    this.capturer = undefined;
    this.lastReadAt = 0;
    this.readCount = 0;
    if (!capturer) {
      return;
    }
    capturer.off('readData');
    await capturer.stop();
    await capturer.release();
  }
}

export class PcmPlayer {
  private renderer?: audio.AudioRenderer;
  private rendererCreating?: Promise<audio.AudioRenderer>;
  private queue: Uint8Array[] = [];
  private queueOffset: number = 0;
  private generation: number = 0;
  private paused: boolean = false;
  private pendingDrain: DrainedListener | undefined = undefined;
  private sampleRate: number = 24000;

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
        content: audio.ContentType.CONTENT_TYPE_SPEECH,
        usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT,
        rendererFlags: 0
      }
    };
    const renderer = await audio.createAudioRenderer(options);
    renderer.on('writeData', (buffer: ArrayBuffer) => {
      this.fillPlaybackBuffer(buffer);
    });
    await renderer.start();
    if (generation !== this.generation) {
      renderer.off('writeData');
      await renderer.stop();
      await renderer.release();
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
      this.ensureRenderer().catch(() => undefined);
    }
  }

  clearQueue(): void {
    this.queue = [];
    this.queueOffset = 0;
  }

  hasQueued(): boolean {
    return this.queue.length > 0;
  }

  async pause(): Promise<void> {
    this.paused = true;
    const renderer = this.renderer;
    if (renderer) {
      await renderer.pause().catch(() => undefined);
    }
  }

  async resume(): Promise<void> {
    this.paused = false;
    const renderer = this.renderer;
    if (renderer) {
      await renderer.start().catch(() => undefined);
    } else if (this.queue.length > 0) {
      this.ensureRenderer().catch(() => undefined);
    }
  }

  // Fires when the queue has been fully consumed by the renderer.
  waitForDrain(listener: DrainedListener): void {
    if (this.queue.length === 0) {
      listener();
      return;
    }
    this.pendingDrain = listener;
  }

  async stop(): Promise<void> {
    this.generation += 1;
    this.queue = [];
    this.queueOffset = 0;
    this.paused = false;
    this.pendingDrain = undefined;
    const renderer = this.renderer;
    this.renderer = undefined;
    const creating = this.rendererCreating;
    if (creating) {
      await creating.catch(() => undefined);
    }
    if (!renderer) {
      return;
    }
    renderer.off('writeData');
    await renderer.stop();
    await renderer.release();
  }

  private fillPlaybackBuffer(buffer: ArrayBuffer): void {
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
    if (this.queue.length === 0 && this.pendingDrain) {
      const listener = this.pendingDrain;
      this.pendingDrain = undefined;
      listener();
    }
  }
}
