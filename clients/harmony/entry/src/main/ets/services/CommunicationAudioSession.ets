// Shared HarmonyOS voice-communication audio session and output routing.

import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AudioOutputRoute } from '../models/SingleAgentState';

const AUDIO_LOG_DOMAIN = 0xD002;
const AUDIO_LOG_TAG = 'SingleAgentAudio';
const AUDIO_SESSION_RECOVERY_DELAYS_MS: number[] = [100, 500, 1500];

export type OutputRouteListener = (route: AudioOutputRoute, headsetAvailable: boolean) => void;
export type AudioSessionRecoveryListener = () => void;

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
  private lastHeadsetAvailable?: boolean;
  private recoveryListeners: AudioSessionRecoveryListener[] = [];
  private preferredOutputListener = (devices: audio.AudioDeviceDescriptors): void => {
    this.speakerphoneEnabled = this.outputRoute(devices) === 'speaker';
    this.publishOutputRoute(devices);
  };
  private availableOutputListener = (_action: audio.DeviceChangeAction): void => {
    this.applyOutputPreference().catch((error: BusinessError): void => {
      hilog.warn(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication output refresh failed: %{public}s',
        error.message
      );
    });
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

  async showOutputPicker(context: common.UIAbilityContext): Promise<void> {
    const picker = new avSession.AVCastPickerHelper(context);
    await picker.select({
      sessionType: 'voice_call'
    });
    hilog.info(AUDIO_LOG_DOMAIN, AUDIO_LOG_TAG, 'native communication output picker opened');
  }

  setOutputRouteListener(listener: OutputRouteListener): void {
    this.outputRouteListener = listener;
    this.installRoutingListeners();
    this.publishOutputRoute();
  }

  addRecoveryListener(listener: AudioSessionRecoveryListener): void {
    this.recoveryListeners.push(listener);
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
    if (this.users <= 0) {
      this.publishOutputRoute();
      return;
    }
    let available: audio.AudioDeviceDescriptors = [];
    try {
      available = routingManager.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
    } catch (error) {
    }
    const headsetAvailable = this.hasHeadsetOutput(available);
    if (this.lastHeadsetAvailable === undefined || this.lastHeadsetAvailable !== headsetAvailable) {
      this.speakerphoneEnabled = false;
      this.lastHeadsetAvailable = headsetAvailable;
    }
    const speakerActive = this.speakerphoneEnabled;
    try {
      await routingManager.setCommunicationDevice(
        audio.CommunicationDeviceType.SPEAKER,
        speakerActive
      );
      hilog.info(
        AUDIO_LOG_DOMAIN,
        AUDIO_LOG_TAG,
        'communication route preference headset=%{public}s phone=%{public}s',
        String(headsetAvailable),
        speakerActive ? 'speaker' : 'system-preferred'
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
        for (const listener of this.recoveryListeners) {
          listener();
        }
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

export function showCommunicationOutputPicker(context: common.UIAbilityContext): Promise<void> {
  return COMMUNICATION_AUDIO_SESSION.showOutputPicker(context);
}

export function setCommunicationOutputRouteListener(listener: OutputRouteListener): void {
  COMMUNICATION_AUDIO_SESSION.setOutputRouteListener(listener);
}

export class CommunicationAudioSessionLease {
  private acquired: boolean = false;

  addRecoveryListener(listener: AudioSessionRecoveryListener): void {
    COMMUNICATION_AUDIO_SESSION.addRecoveryListener(listener);
  }

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
