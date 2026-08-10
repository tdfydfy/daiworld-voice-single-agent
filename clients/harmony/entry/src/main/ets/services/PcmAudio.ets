// PCM capture/playback infrastructure for the Single-Agent HarmonyOS client.
// Reused from the Host project's platform audio layer; extended with
// pause/resume/clear/drain semantics required by the Single-Agent TTS spec
// (docs/INTERACTION_AND_PORTING_SPEC.md section 7).

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AudioOutputRoute } from '../models/SingleAgentState';

const AUDIO_LOG_DOMAIN = 0xD002;
const AUDIO_LOG_TAG = 'SingleAgentAudio';
const AUDIO_SESSION_RECOVERY_DELAYS_MS: number[] = [100, 500, 1500];

export type AudioChunkListener = (buffer: ArrayBuffer) => void;
export type DrainedListener = () => void;
export type InputRouteListener = (label: string) => void;
export type OutputRouteListener = (route: AudioOutputRoute, headsetAvailable: boolean) => void;

class CommunicationAudioSession {
  private users: number = 0;
  private activation?: Promise<void>;
  private deactivation?: Promise<void>;
  private speakerphoneEnabled: boolean = false;
  private recoveryAttempt: number = 0;
  private recoveryTimer?: number;
  private listenerInstalled: boolean = false;
  private routingListenersInstalled: boolean = false;
  private outputRouteListener?: OutputRouteListener;
  private preferredOutputListener = (devices: audio.AudioDeviceDescriptors): void => {
    this.publishOutputRoute(devices);
  };
  private availableOutputListener = (_action: audio.DeviceChangeAction): void => {
    this.publishOutputRoute();
  };
  private sessionDeactivatedListener = (event: audio.AudioSessionDeactivatedEvent): void => {
    hilog.warn(
      AUDIO_LOG_DOMAIN,
      AUDIO_LOG_TAG,
      'communication audio session deactivated reason=%{public}d users=%{public}d',
      event.reason,
      this.users
    );
    if (this.users > 0) {
      this.scheduleRecovery();
    }
  };

  async acquire(): Promise<void> {
    this.users += 1;
    try {
      this.installListener();
      const deactivation = this.deactivation;
      if (deactivation) {
        await deactivation.catch(() => undefined);
      }
      await this.ensureActivated();
    } catch (error) {
      this.users = Math.max(0, this.users - 1);
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
  }

  async release(): Promise<void> {
    this.users = Math.max(0, this.users - 1);
    if (this.users > 0) {
      return;
    }
    this.cancelRecovery();
    const activation = this.activation;
    if (activation) {
      await activation.catch(() => undefined);
    }
    if (this.users > 0) {
      return;
    }
    const sessionManager = audio.getAudioManager().getSessionManager();
    if (!sessionManager.isAudioSessionActivated()) {
      return;
    }
    const existing = this.deactivation;
    if (existing) {
      await existing.catch(() => undefined);
      return;
    }
    let deactivation: Promise<void>;
    try {
      deactivation = sessionManager.deactivateAudioSession();
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication audio session deactivation failed: %{public}s',
        businessError.message
      );
      return;
    }
    this.deactivation = deactivation;
    try {
      await deactivation;
      hilog.info(AUDIO_LOG_DOMAIN, AUDIO_LOG_TAG, 'communication audio session deactivated');
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication audio session deactivation failed: %{public}s',
        businessError.message
      );
    } finally {
      if (this.deactivation === deactivation) {
        this.deactivation = undefined;
      }
    }
  }

  async setSpeakerphoneEnabled(enabled: boolean): Promise<void> {
    this.speakerphoneEnabled = enabled;
    if (this.users > 0) {
      await this.ensureActivated();
    }
    await this.applyOutputPreference();
  }

  setOutputRouteListener(listener: OutputRouteListener): void {
    this.outputRouteListener = listener;
    this.installRoutingListeners();
    this.publishOutputRoute();
  }

  private installListener(): void {
    if (this.listenerInstalled) {
      return;
    }
    try {
      audio.getAudioManager().getSessionManager().on(
        'audioSessionDeactivated',
        this.sessionDeactivatedListener
      );
      this.listenerInstalled = true;
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication audio session listener setup failed: %{public}s',
        businessError.message
      );
    }
  }

  private installRoutingListeners(): void {
    if (this.routingListenersInstalled) {
      return;
    }
    const routingManager = audio.getAudioManager().getRoutingManager();
    try {
      routingManager.on(
        'preferOutputDeviceChangeForRendererInfo',
        this.communicationRendererInfo(),
        this.preferredOutputListener
      );
      routingManager.on(
        'availableDeviceChange',
        audio.DeviceUsage.CALL_OUTPUT_DEVICES,
        this.availableOutputListener
      );
      this.routingListenersInstalled = true;
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication output listener setup failed: %{public}s',
        businessError.message
      );
    }
  }

  private async ensureActivated(): Promise<void> {
    const sessionManager = audio.getAudioManager().getSessionManager();
    if (sessionManager.isAudioSessionActivated()) {
      return;
    }
    const existing = this.activation;
    if (existing) {
      await existing;
      return;
    }
    const activation = this.activate();
    this.activation = activation;
    try {
      await activation;
    } finally {
      if (this.activation === activation) {
        this.activation = undefined;
      }
    }
  }

  private async activate(): Promise<void> {
    const sessionManager = audio.getAudioManager().getSessionManager();
    try {
      sessionManager.setAudioSessionScene(audio.AudioSessionScene.AUDIO_SESSION_SCENE_VOICE_COMMUNICATION);
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
      };
      await sessionManager.activateAudioSession(strategy);
      hilog.info(AUDIO_LOG_DOMAIN, AUDIO_LOG_TAG, 'communication audio session activated');
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
    await this.applyOutputPreference();
  }

  private async applyOutputPreference(): Promise<void> {
    const routingManager = audio.getAudioManager().getRoutingManager();
    try {
      await routingManager.setCommunicationDevice(
        audio.CommunicationDeviceType.SPEAKER,
        this.speakerphoneEnabled
      );
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication speaker selection failed: %{public}s',
        businessError.message
      );
    }
    if (this.users <= 0) {
      this.publishOutputRoute();
      return;
    }
    const sessionManager = audio.getAudioManager().getSessionManager();
    const device = this.speakerphoneEnabled ? audio.DeviceType.SPEAKER : audio.DeviceType.EARPIECE;
    try {
      await sessionManager.setDefaultOutputDevice(device);
      hilog.info(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication fallback output=%{public}s',
        this.speakerphoneEnabled ? 'speaker' : 'earpiece'
      );
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication fallback output setup failed: %{public}s',
        businessError.message
      );
    }
    this.publishOutputRoute();
  }

  private communicationRendererInfo(): audio.AudioRendererInfo {
    return {
      usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION,
      rendererFlags: 0
    };
  }

  private publishOutputRoute(devices?: audio.AudioDeviceDescriptors): void {
    const listener = this.outputRouteListener;
    if (!listener) {
      return;
    }
    const routingManager = audio.getAudioManager().getRoutingManager();
    let preferred = devices;
    if (!preferred) {
      try {
        preferred = routingManager.getPreferredOutputDeviceForRendererInfoSync(
          this.communicationRendererInfo()
        );
      } catch (error) {
        preferred = [];
      }
    }
    let available: audio.AudioDeviceDescriptors = [];
    try {
      available = routingManager.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
    } catch (error) {
    }
    listener(this.outputRoute(preferred), this.hasHeadsetOutput(available));
  }

  private outputRoute(devices: audio.AudioDeviceDescriptors): AudioOutputRoute {
    for (const device of devices) {
      if (this.isHeadsetOutput(device.deviceType)) {
        return 'headset';
      }
      if (device.deviceType === audio.DeviceType.SPEAKER) {
        return 'speaker';
      }
    }
    return this.speakerphoneEnabled ? 'speaker' : 'earpiece';
  }

  private hasHeadsetOutput(devices: audio.AudioDeviceDescriptors): boolean {
    for (const device of devices) {
      if (this.isHeadsetOutput(device.deviceType)) {
        return true;
      }
    }
    return false;
  }

  private isHeadsetOutput(deviceType: audio.DeviceType): boolean {
    return deviceType === audio.DeviceType.WIRED_HEADSET ||
      deviceType === audio.DeviceType.WIRED_HEADPHONES ||
      deviceType === audio.DeviceType.BLUETOOTH_SCO ||
      deviceType === audio.DeviceType.BLUETOOTH_A2DP ||
      deviceType === audio.DeviceType.USB_HEADSET ||
      deviceType === audio.DeviceType.USB_DEVICE ||
      deviceType === audio.DeviceType.HEARING_AID ||
      deviceType === audio.DeviceType.NEARLINK;
  }

  private scheduleRecovery(): void {
    if (this.users <= 0 || this.recoveryTimer !== undefined) {
      return;
    }
    if (this.recoveryAttempt >= AUDIO_SESSION_RECOVERY_DELAYS_MS.length) {
      hilog.error(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication audio session recovery exhausted users=%{public}d',
        this.users
      );
      this.recoveryAttempt = 0;
      return;
    }
    const delay = AUDIO_SESSION_RECOVERY_DELAYS_MS[this.recoveryAttempt];
    this.recoveryAttempt += 1;
    this.recoveryTimer = setTimeout((): void => {
      this.recoveryTimer = undefined;
      if (this.users <= 0) {
        this.recoveryAttempt = 0;
        return;
      }
      this.ensureActivated().then((): void => {
        this.recoveryAttempt = 0;
        hilog.info(
          AUDIO_LOG_DOMAIN,
          AUDIO_LOG_TAG,
          'communication audio session recovered users=%{public}d',
          this.users
        );
      }).catch((error: BusinessError): void => {
        hilog.warn(
          AUDIO_LOG_DOMAIN,
          AUDIO_LOG_TAG,
          'communication audio session recovery failed: %{public}s',
          error.message
        );
        this.scheduleRecovery();
      });
    }, delay);
  }

  private cancelRecovery(): void {
    if (this.recoveryTimer !== undefined) {
      clearTimeout(this.recoveryTimer);
      this.recoveryTimer = undefined;
    }
    this.recoveryAttempt = 0;
  }
}

const COMMUNICATION_AUDIO_SESSION = new CommunicationAudioSession();

export function setCommunicationSpeakerphoneEnabled(enabled: boolean): Promise<void> {
  return COMMUNICATION_AUDIO_SESSION.setSpeakerphoneEnabled(enabled);
}

export function setCommunicationOutputRouteListener(listener: OutputRouteListener): void {
  COMMUNICATION_AUDIO_SESSION.setOutputRouteListener(listener);
}

export class CommunicationAudioSessionLease {
  private acquired: boolean = false;

  async acquire(): Promise<void> {
    if (this.acquired) {
      return;
    }
    await COMMUNICATION_AUDIO_SESSION.acquire();
    this.acquired = true;
  }

  async release(): Promise<void> {
    if (!this.acquired) {
      return;
    }
    this.acquired = false;
    await COMMUNICATION_AUDIO_SESSION.release();
  }
}

export class PcmCapture {
  private capturer?: audio.AudioCapturer;
  private listener?: AudioChunkListener;
  private routeListener?: InputRouteListener;
  private lastReadAt: number = 0;
  private lastHealthLogAt: number = 0;
  private readCount: number = 0;
  private activeInputLabel: string = '';
  private captureGeneration: number = 0;
  private session: CommunicationAudioSessionLease = new CommunicationAudioSessionLease();

  async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const result = await manager.requestPermissionsFromUser(context, permissions);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (error) {
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
  }

  async start(listener: AudioChunkListener, routeListener?: InputRouteListener): Promise<void> {
    const generation = this.captureGeneration + 1;
    this.captureGeneration = generation;
    this.listener = listener;
    this.routeListener = routeListener;
    if (this.capturer) {
      return;
    }
    this.activeInputLabel = '';
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION,
      capturerFlags: 0
    };
    this.logPreferredInputDevices(capturerInfo);
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: capturerInfo
    };
    await this.session.acquire();
    let capturer: audio.AudioCapturer | undefined = undefined;
    try {
      if (generation !== this.captureGeneration) {
        throw new Error('录音启动已取消');
      }
      capturer = await audio.createAudioCapturer(options);
      if (generation !== this.captureGeneration) {
        throw new Error('录音启动已取消');
      }
      this.capturer = capturer;
      capturer.on('readData', (buffer: ArrayBuffer) => {
        const now = Date.now();
        const gap = this.lastReadAt > 0 ? now - this.lastReadAt : 0;
        this.lastReadAt = now;
        this.readCount += 1;
        if (this.readCount <= 5 || gap > 150 || now - this.lastHealthLogAt >= 15000) {
          this.lastHealthLogAt = now;
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
      capturer.on('inputDeviceChange', (devices: audio.AudioDeviceDescriptors) => {
        if (generation !== this.captureGeneration || this.capturer !== capturer) {
          return;
        }
        this.updateInputRoute('changed', devices);
      });
      await capturer.start();
      if (generation !== this.captureGeneration) {
        throw new Error('录音启动已取消');
      }
      this.updateInputRoute('started', this.getActiveInputDevices(capturer));
      hilog.info(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'capture started source=voice_communication'
      );
    } catch (error) {
      if (capturer && this.capturer === capturer) {
        this.capturer = undefined;
      }
      if (capturer) {
        try {
          capturer.off('readData');
          capturer.off('inputDeviceChange');
        } catch (offError) {
        }
        await capturer.stop().catch(() => undefined);
        await capturer.release().catch(() => undefined);
      }
      await this.session.release();
      this.activeInputLabel = '';
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
  }

  async stop(): Promise<void> {
    this.captureGeneration += 1;
    const capturer = this.capturer;
    this.capturer = undefined;
    this.lastReadAt = 0;
    this.lastHealthLogAt = 0;
    this.readCount = 0;
    this.listener = undefined;
    this.routeListener = undefined;
    this.activeInputLabel = '';
    if (!capturer) {
      return;
    }
    try {
      capturer.off('readData');
      capturer.off('inputDeviceChange');
    } catch (error) {
      // A stopped capturer may already have removed the callback.
    }
    await capturer.stop().catch(() => undefined);
    await capturer.release().catch(() => undefined);
    await this.session.release();
    hilog.info(AUDIO_LOG_DOMAIN, AUDIO_LOG_TAG, 'capture stopped');
  }

  getInputRouteLabel(): string {
    const capturer = this.capturer;
    if (capturer) {
      const devices = this.getActiveInputDevices(capturer);
      const label = this.inputRouteLabel(devices);
      if (label.length > 0) {
        this.activeInputLabel = label;
      }
    }
    return this.activeInputLabel;
  }

  private logPreferredInputDevices(capturerInfo: audio.AudioCapturerInfo): void {
    try {
      const devices = audio.getAudioManager().getRoutingManager()
        .getPreferredInputDeviceForCapturerInfoSync(capturerInfo);
      this.logInputDevices('preferred', devices);
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'capture preferred input query failed: %{public}s',
        businessError.message
      );
    }
  }

  private getActiveInputDevices(
    capturer: audio.AudioCapturer
  ): audio.AudioDeviceDescriptors | undefined {
    try {
      return capturer.getCurrentInputDevices();
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'capture active input query failed: %{public}s',
        businessError.message
      );
      return undefined;
    }
  }

  private updateInputRoute(
    stage: string,
    devices: audio.AudioDeviceDescriptors | undefined
  ): void {
    if (!devices) {
      return;
    }
    this.logInputDevices(stage, devices);
    const label = this.inputRouteLabel(devices);
    if (label.length === 0 || label === this.activeInputLabel) {
      return;
    }
    this.activeInputLabel = label;
    this.routeListener?.(label);
  }

  private logInputDevices(stage: string, devices: audio.AudioDeviceDescriptors): void {
    if (devices.length === 0) {
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'capture input stage=%{public}s devices=none',
        stage
      );
      return;
    }
    for (const device of devices) {
      hilog.info(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'capture input stage=%{public}s deviceType=%{public}d headsetMic=%{public}s',
        stage,
        device.deviceType,
        this.isHeadsetInput(device.deviceType) ? 'true' : 'false'
      );
    }
  }

  private isHeadsetInput(deviceType: audio.DeviceType): boolean {
    return deviceType === audio.DeviceType.WIRED_HEADSET ||
      deviceType === audio.DeviceType.BLUETOOTH_SCO ||
      deviceType === audio.DeviceType.USB_HEADSET ||
      deviceType === audio.DeviceType.USB_DEVICE ||
      deviceType === audio.DeviceType.HEARING_AID ||
      deviceType === audio.DeviceType.NEARLINK;
  }

  private findHeadsetInput(
    devices: audio.AudioDeviceDescriptors
  ): audio.AudioDeviceDescriptor | undefined {
    for (const device of devices) {
      if (this.isHeadsetInput(device.deviceType)) {
        return device;
      }
    }
    return undefined;
  }

  private hasHeadsetInput(devices: audio.AudioDeviceDescriptors): boolean {
    return this.findHeadsetInput(devices) !== undefined;
  }

  private inputRouteLabel(devices: audio.AudioDeviceDescriptors | undefined): string {
    if (!devices || devices.length === 0) {
      return '';
    }
    return this.hasHeadsetInput(devices) ? '耳机麦克风' : '手机麦克风';
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
  private drainTimer: number | undefined = undefined;
  private lastBufferDurationMs: number = 0;
  private sampleRate: number = 24000;
  private session: CommunicationAudioSessionLease = new CommunicationAudioSessionLease();
  private communication: boolean;

  constructor(communication: boolean = true) {
    this.communication = communication;
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
      await renderer.start();
    } catch (error) {
      await renderer.release().catch(() => undefined);
      await this.session.release();
      const businessError = error as BusinessError;
      throw new Error(businessError.message);
    }
    if (generation !== this.generation) {
      try {
        renderer.off('writeData');
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
      this.scheduleDrain(listener);
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
    if (this.drainTimer !== undefined) {
      clearTimeout(this.drainTimer);
      this.drainTimer = undefined;
    }
    const renderer = this.renderer;
    this.renderer = undefined;
    const creating = this.rendererCreating;
    if (creating) {
      await creating.catch(() => undefined);
    }
    if (!renderer) {
      return;
    }
    try {
      renderer.off('writeData');
    } catch (error) {
    }
    await renderer.stop();
    await renderer.release();
    await this.session.release();
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
    this.lastBufferDurationMs = Math.ceil(
      (outputOffset / (Math.max(this.sampleRate, 1) * 2)) * 1000
    );
    if (this.queue.length === 0 && this.pendingDrain) {
      const listener = this.pendingDrain;
      this.pendingDrain = undefined;
      this.scheduleDrain(listener);
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
