// PCM microphone capture for the HarmonyOS single-Agent client.

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CommunicationAudioSessionLease } from './CommunicationAudioSession';

const AUDIO_LOG_DOMAIN = 0xD002;
const AUDIO_LOG_TAG = 'SingleAgentAudio';

export type AudioChunkListener = (buffer: ArrayBuffer) => void;
export type InputRouteListener = (label: string) => void;

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
