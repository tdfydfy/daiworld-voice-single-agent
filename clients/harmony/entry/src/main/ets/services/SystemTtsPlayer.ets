import { BusinessError } from '@kit.BasicServicesKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SystemTtsCompletionGate, SystemTtsPlaybackEvent } from './SystemTtsCompletionGate';

const SYSTEM_TTS_LOG_DOMAIN = 0xD003;
const SYSTEM_TTS_LOG_TAG = 'SystemTtsPlayer';

export type SystemTtsStateCallback = (token: string, event: SystemTtsPlaybackEvent) => void;
export type SystemTtsErrorCallback = (token: string, message: string) => void;

export class SystemTtsCallbacks {
  private stateCallback: SystemTtsStateCallback;
  private errorCallback: SystemTtsErrorCallback;

  constructor(stateCallback: SystemTtsStateCallback, errorCallback: SystemTtsErrorCallback) {
    this.stateCallback = stateCallback;
    this.errorCallback = errorCallback;
  }

  onState(token: string, event: SystemTtsPlaybackEvent): void {
    this.stateCallback(token, event);
  }

  onError(token: string, message: string): void {
    this.errorCallback(token, message);
  }
}

export class VoiceOption {
  language: string = '';
  person: number = 0;
  style: string = '';
  gender: string = '';
  description: string = '';
  label: string = '';

  constructor(info: textToSpeech.VoiceInfo) {
    this.language = info.language;
    this.person = info.person;
    this.style = info.style;
    this.gender = info.gender;
    this.description = info.description;
    const name = info.description.length > 0 ? info.description : `发音人 ${info.person}`;
    const traits = [info.gender, info.style]
      .filter((value: string): boolean => value.length > 0)
      .join(' / ');
    this.label = traits.length > 0 ? `${name} · ${traits}` : name;
  }
}

export class SystemTtsPlayer {
  private callbacks: SystemTtsCallbacks;
  private tts?: textToSpeech.TextToSpeechEngine;
  private activeRequestId: string = '';
  private activeToken: string = '';
  private requestGeneration: number = 0;
  private requestSerial: number = 0;
  private ttsPerson: number = -1;
  private disposed: boolean = false;
  private completionGate: SystemTtsCompletionGate = new SystemTtsCompletionGate();

  constructor(callbacks: SystemTtsCallbacks) {
    this.callbacks = callbacks;
  }

  isSupported(): boolean {
    return canIUse('SystemCapability.AI.TextToSpeech');
  }

  async listVoices(): Promise<VoiceOption[]> {
    if (this.disposed || !this.isSupported()) {
      return [];
    }
    try {
      const voiceInfos = await textToSpeech.listVoices({
        requestId: this.makeId('voices'),
        online: 1
      });
      return voiceInfos.map((info: textToSpeech.VoiceInfo): VoiceOption => new VoiceOption(info));
    } catch (error) {
      return [];
    }
  }

  async speak(
    text: string,
    person: number = 0,
    speechRate: number = 1,
    token: string = ''
  ): Promise<void> {
    const normalized = text.trim();
    if (normalized.length === 0) {
      return;
    }
    if (this.disposed || !this.isSupported()) {
      throw new Error('设备不支持鸿蒙系统语音合成');
    }
    const normalizedRate = Math.max(0.5, Math.min(2, speechRate));
    const requestId = this.makeId('tts');
    const generation = this.requestGeneration;
    const engine = await this.ensureEngine(person);
    if (generation !== this.requestGeneration) {
      return;
    }
    const extraParams: Record<string, Object> = {
      'speed': normalizedRate
    };
    this.activeRequestId = requestId;
    this.activeToken = token;
    this.completionGate.begin(normalized, normalizedRate);
    hilog.info(
      SYSTEM_TTS_LOG_DOMAIN,
      SYSTEM_TTS_LOG_TAG,
      'TTS request id=%{public}s length=%{public}d person=%{public}d rate=%{public}s',
      requestId,
      normalized.length,
      person,
      String(normalizedRate)
    );
    try {
      engine.speak(normalized, {
        requestId: requestId,
        extraParams: extraParams
      });
    } catch (error) {
      if (this.activeRequestId === requestId) {
        this.activeRequestId = '';
        this.activeToken = '';
        this.completionGate.reset();
      }
      throw new Error(this.errorText(error as BusinessError));
    }
  }

  stop(): Promise<void> {
    this.requestGeneration += 1;
    const hasActiveRequest = this.activeRequestId.length > 0;
    const token = this.activeToken;
    this.activeRequestId = '';
    this.activeToken = '';
    this.completionGate.reset();
    if (this.tts && hasActiveRequest) {
      try {
        this.tts.stop();
      } catch (error) {
        hilog.warn(
          SYSTEM_TTS_LOG_DOMAIN,
          SYSTEM_TTS_LOG_TAG,
          'TTS stop treated as idempotent: %{public}s',
          this.errorText(error as BusinessError)
        );
      }
    }
    if (token.length > 0) {
      this.callbacks.onState(token, 'interrupted');
    }
    return Promise.resolve();
  }

  async release(): Promise<void> {
    this.disposed = true;
    await this.stop();
    if (this.tts) {
      this.tts.shutdown();
      this.tts = undefined;
      this.ttsPerson = -1;
    }
  }

  private async ensureEngine(person: number): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.tts && this.ttsPerson === person) {
      return this.tts;
    }
    if (this.tts) {
      this.tts.shutdown();
      this.tts = undefined;
    }
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      engine = await textToSpeech.createEngine({
        language: 'zh-CN',
        person: person,
        online: 1
      });
    } catch (error) {
      throw new Error(this.errorText(error as BusinessError));
    }
    if (this.disposed) {
      engine.shutdown();
      throw new Error('System TTS player was disposed');
    }
    this.tts = engine;
    this.ttsPerson = person;
    engine.setListener({
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
        if (this.activeRequestId !== requestId) {
          return;
        }
        hilog.info(
          SYSTEM_TTS_LOG_DOMAIN,
          SYSTEM_TTS_LOG_TAG,
          'TTS onStart id=%{public}s type=%{public}s rate=%{public}d',
          requestId,
          response.audioType,
          response.sampleRate
        );
        this.completionGate.markStarted(Date.now());
        this.callbacks.onState(this.activeToken, 'started');
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        if (this.activeRequestId !== requestId) {
          return;
        }
        if (response.type === 1) {
          const token = this.activeToken;
          const now = Date.now();
          const event = this.completionGate.classifyCompletion(now);
          hilog.info(
            SYSTEM_TTS_LOG_DOMAIN,
            SYSTEM_TTS_LOG_TAG,
            'TTS completion id=%{public}s event=%{public}s elapsedMs=%{public}d minimumMs=%{public}d',
            requestId,
            event,
            this.completionGate.elapsed(now),
            this.completionGate.minimum()
          );
          this.activeRequestId = '';
          this.activeToken = '';
          this.completionGate.reset();
          this.callbacks.onState(token, event);
        }
      },
      onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
        if (this.activeRequestId !== requestId) {
          return;
        }
        const token = this.activeToken;
        this.activeRequestId = '';
        this.activeToken = '';
        this.completionGate.reset();
        this.callbacks.onState(token, 'interrupted');
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        if (this.activeRequestId !== requestId) {
          return;
        }
        const token = this.activeToken;
        this.activeRequestId = '';
        this.activeToken = '';
        this.completionGate.reset();
        this.callbacks.onError(token, `code=${errorCode} message=${errorMessage}`);
      }
    });
    return engine;
  }

  private makeId(prefix: string): string {
    this.requestSerial += 1;
    return `${prefix}-${Date.now()}-${this.requestSerial}`;
  }

  private errorText(error: Error): string {
    const businessError = error as BusinessError;
    if (businessError.code !== undefined) {
      return `code=${businessError.code} message=${businessError.message}`;
    }
    return error.message;
  }
}
