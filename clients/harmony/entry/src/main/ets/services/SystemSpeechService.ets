import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PcmCapture } from './PcmAudio';

const SPEECH_FRAME_BYTES = 640;
const SPEECH_PRE_ROLL_BYTES = 6400;
const SPEECH_SESSION_MAX_AUDIO_BYTES = 16000 * 2 * 18;
const SPEECH_LOG_DOMAIN = 0xD003;
const SPEECH_LOG_TAG = 'SingleAgentSpeech';

export type SpeechActiveCallback = (active: boolean) => void;
export type RecognitionAudioStartCallback = () => void;
export type RecognitionStartupPhaseCallback = (phase: string) => void;
export type RecognitionResultCallback = (text: string, isFinal: boolean, isLast: boolean) => void;
export type SpeechErrorCallback = (channel: string, message: string) => void;
export type InputRouteCallback = (label: string) => void;

export class SystemSpeechCallbacks {
  private recognitionStateCallback: SpeechActiveCallback;
  private recognitionResultCallback: RecognitionResultCallback;
  private recognitionAudioStartCallback: RecognitionAudioStartCallback;
  private recognitionStartupPhaseCallback: RecognitionStartupPhaseCallback;
  private inputRouteCallback: InputRouteCallback;
  private speechStateCallback: SpeechActiveCallback;
  private errorCallback: SpeechErrorCallback;

  constructor(
    recognitionStateCallback: SpeechActiveCallback,
    recognitionResultCallback: RecognitionResultCallback,
    recognitionAudioStartCallback: RecognitionAudioStartCallback,
    recognitionStartupPhaseCallback: RecognitionStartupPhaseCallback,
    inputRouteCallback: InputRouteCallback,
    speechStateCallback: SpeechActiveCallback,
    errorCallback: SpeechErrorCallback
  ) {
    this.recognitionStateCallback = recognitionStateCallback;
    this.recognitionResultCallback = recognitionResultCallback;
    this.recognitionAudioStartCallback = recognitionAudioStartCallback;
    this.recognitionStartupPhaseCallback = recognitionStartupPhaseCallback;
    this.inputRouteCallback = inputRouteCallback;
    this.speechStateCallback = speechStateCallback;
    this.errorCallback = errorCallback;
  }

  onRecognitionState(active: boolean): void {
    this.recognitionStateCallback(active);
  }

  onRecognitionResult(text: string, isFinal: boolean, isLast: boolean): void {
    this.recognitionResultCallback(text, isFinal, isLast);
  }

  onRecognitionAudioStart(): void {
    this.recognitionAudioStartCallback();
  }

  onRecognitionStartupPhase(phase: string): void {
    this.recognitionStartupPhaseCallback(phase);
  }

  onInputRouteChanged(label: string): void {
    this.inputRouteCallback(label);
  }

  onSpeechState(active: boolean): void {
    this.speechStateCallback(active);
  }

  onError(channel: string, message: string): void {
    this.errorCallback(channel, message);
  }
}

export interface SystemSpeechCapabilities {
  stt: boolean;
  tts: boolean;
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

export class SystemSpeechService {
  private context: common.UIAbilityContext;
  private callbacks: SystemSpeechCallbacks;
  private capture: PcmCapture = new PcmCapture();
  private recognizer?: speechRecognizer.SpeechRecognitionEngine;
  private tts?: textToSpeech.TextToSpeechEngine;
  private recognitionSessionId: string = '';
  private recognitionSessionReady: boolean = false;
  private recognitionSessionAudioBytes: number = 0;
  private pendingAudio: Uint8Array = new Uint8Array(0);
  private recognitionWanted: boolean = false;
  private microphonePermissionGranted: boolean = false;
  private captureRunning: boolean = false;
  private captureStarting?: Promise<void>;
  private captureStopping?: Promise<void>;
  private ttsPerson: number = -1;
  constructor(context: common.UIAbilityContext, callbacks: SystemSpeechCallbacks) {
    this.context = context;
    this.callbacks = callbacks;
  }

  getCapabilities(): SystemSpeechCapabilities {
    return {
      stt: canIUse('SystemCapability.AI.SpeechRecognizer'),
      tts: canIUse('SystemCapability.AI.TextToSpeech')
    };
  }

  getInputRouteLabel(): string {
    return this.capture.getInputRouteLabel();
  }

  async startRecognition(): Promise<void> {
    if (!this.getCapabilities().stt) {
      throw new Error('设备不支持鸿蒙系统语音识别');
    }
    this.recognitionWanted = true;
    this.reportRecognitionStartupPhase('申请麦克风权限');
    if (!this.microphonePermissionGranted) {
      const granted = await this.capture.requestPermission(this.context);
      if (!granted) {
        this.recognitionWanted = false;
        throw new Error('麦克风权限未授权');
      }
      this.microphonePermissionGranted = true;
    }

    this.reportRecognitionStartupPhase('创建本地识别引擎');
    const engine = await this.ensureRecognizer();
    if (!this.recognitionWanted) {
      return;
    }
    this.reportRecognitionStartupPhase('启动音频采集');
    await this.ensureRecognitionCapture();
    if (!this.recognitionWanted) {
      await this.stopRecognitionCapture();
      return;
    }
    this.cancelRecognitionSession(false, false);
    const sessionId = this.makeId('stt');
    this.recognitionSessionId = sessionId;
    this.recognitionSessionReady = false;
    this.recognitionSessionAudioBytes = 0;
    try {
      this.reportRecognitionStartupPhase('启动识别会话');
      engine.startListening({
        sessionId: sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      this.reportRecognitionStartupPhase('等待识别引擎 ready');
    } catch (error) {
      this.recognitionSessionId = '';
      throw new Error(this.errorText(error as BusinessError));
    }
  }

  async stopRecognition(finish: boolean = true): Promise<void> {
    this.recognitionWanted = false;
    this.cancelRecognitionSession(finish);
    this.callbacks.onRecognitionState(false);
    await this.stopRecognitionCapture();
  }

  async resetRecognition(): Promise<void> {
    this.recognitionWanted = false;
    this.cancelRecognitionSession(false);
    await this.stopRecognitionCapture();
    this.releaseRecognizer();
  }

  async listVoices(): Promise<VoiceOption[]> {
    if (!this.getCapabilities().tts) {
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

  async speak(text: string, person: number = 0, speechRate: number = 1): Promise<void> {
    const normalized = text.trim();
    if (normalized.length === 0) {
      return;
    }
    if (!this.getCapabilities().tts) {
      throw new Error('设备不支持鸿蒙系统语音合成');
    }
    const normalizedRate = Math.max(0.5, Math.min(2, speechRate));
    const requestId = this.makeId('tts');
    hilog.info(
      SPEECH_LOG_DOMAIN,
      SPEECH_LOG_TAG,
      'TTS request id=%{public}s length=%{public}d person=%{public}d rate=%{public}s',
      requestId,
      normalized.length,
      person,
      String(normalizedRate)
    );
    try {
      const engine = await this.ensureTts(person);
      const extraParams: Record<string, Object> = {
        'speed': normalizedRate
      };
      engine.speak(normalized, {
        requestId: requestId,
        extraParams: extraParams
      });
    } catch (error) {
      hilog.error(
        SPEECH_LOG_DOMAIN,
        SPEECH_LOG_TAG,
        'TTS request failed id=%{public}s error=%{public}s',
        requestId,
        this.errorText(error as BusinessError)
      );
      throw new Error(this.errorText(error as BusinessError));
    }
  }

  stopSpeaking(): void {
    if (!this.tts) {
      return;
    }
    try {
      hilog.info(SPEECH_LOG_DOMAIN, SPEECH_LOG_TAG, 'TTS stop requested');
      this.tts.stop();
    } catch (error) {
      this.callbacks.onError('TTS', this.errorText(error as BusinessError));
    }
  }

  async release(): Promise<void> {
    await this.stopRecognition(false);
    this.releaseRecognizer();
    if (this.tts) {
      this.tts.shutdown();
      this.tts = undefined;
      this.ttsPerson = -1;
    }
    this.callbacks.onSpeechState(false);
  }

  private installRecognitionListener(engine: speechRecognizer.SpeechRecognitionEngine): void {
    engine.setListener({
      onStart: (sessionId: string, _eventMessage: string): void => {
        if (this.recognitionSessionId !== sessionId) {
          return;
        }
        this.recognitionSessionReady = true;
        this.recognitionSessionAudioBytes = 0;
        this.flushRecognitionAudio(sessionId);
        this.callbacks.onRecognitionState(true);
      },
      onEvent: (sessionId: string, eventCode: number, _eventMessage: string): void => {
        if (this.recognitionSessionId === sessionId && eventCode === 1) {
          this.callbacks.onRecognitionAudioStart();
        }
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (this.recognitionSessionId !== sessionId) {
          return;
        }
        this.callbacks.onRecognitionResult(result.result, result.isFinal, result.isLast);
      },
      onComplete: (sessionId: string, _eventMessage: string): void => {
        if (this.recognitionSessionId !== sessionId) {
          return;
        }
        this.recognitionSessionId = '';
        this.recognitionSessionReady = false;
        this.recognitionSessionAudioBytes = 0;
        this.callbacks.onRecognitionState(false);
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
        if (this.recognitionSessionId !== sessionId) {
          return;
        }
        this.recognitionSessionId = '';
        this.recognitionSessionReady = false;
        this.recognitionSessionAudioBytes = 0;
        this.callbacks.onRecognitionState(false);
        this.callbacks.onError('STT', `code=${errorCode} message=${errorMessage}`);
      }
    });
  }

  private writeRecognitionAudio(buffer: ArrayBuffer): void {
    const incoming = new Uint8Array(buffer);
    const merged = new Uint8Array(this.pendingAudio.length + incoming.length);
    merged.set(this.pendingAudio, 0);
    merged.set(incoming, this.pendingAudio.length);
    this.pendingAudio = merged;
    const sessionId = this.recognitionSessionId;
    if (sessionId.length === 0 || !this.recognitionSessionReady) {
      if (this.pendingAudio.length > SPEECH_PRE_ROLL_BYTES) {
        this.pendingAudio = this.pendingAudio.slice(this.pendingAudio.length - SPEECH_PRE_ROLL_BYTES);
      }
      return;
    }
    this.flushRecognitionAudio(sessionId);
  }

  private flushRecognitionAudio(sessionId: string): void {
    const audioBytes = this.pendingAudio;
    let offset = 0;
    while (offset + SPEECH_FRAME_BYTES <= audioBytes.length) {
      if (!this.recognizer || this.recognitionSessionId !== sessionId || !this.recognitionSessionReady) {
        return;
      }
      if (this.recognitionSessionAudioBytes + SPEECH_FRAME_BYTES > SPEECH_SESSION_MAX_AUDIO_BYTES) {
        this.pendingAudio = audioBytes.slice(offset);
        this.finishRecognitionSessionForRotation(sessionId);
        return;
      }
      try {
        this.recognizer.writeAudio(sessionId, audioBytes.slice(offset, offset + SPEECH_FRAME_BYTES));
      } catch (error) {
        this.recognitionSessionReady = false;
        this.callbacks.onError('STT', this.errorText(error as BusinessError));
        return;
      }
      this.recognitionSessionAudioBytes += SPEECH_FRAME_BYTES;
      offset += SPEECH_FRAME_BYTES;
    }
    this.pendingAudio = audioBytes.slice(offset);
  }

  private async ensureRecognitionCapture(): Promise<void> {
    const stopping = this.captureStopping;
    if (stopping) {
      await stopping.catch(() => undefined);
    }
    if (this.captureRunning) {
      return;
    }
    const existingStart = this.captureStarting;
    if (existingStart) {
      await existingStart;
      return;
    }
    const startTask = this.capture.start((buffer: ArrayBuffer): void => {
      this.writeRecognitionAudio(buffer);
    }, (label: string): void => {
      this.callbacks.onInputRouteChanged(label);
    });
    this.captureStarting = startTask;
    try {
      await startTask;
      this.captureRunning = true;
    } finally {
      if (this.captureStarting === startTask) {
        this.captureStarting = undefined;
      }
    }
  }

  private async stopRecognitionCapture(): Promise<void> {
    const existingStop = this.captureStopping;
    if (existingStop) {
      await existingStop.catch(() => undefined);
      return;
    }
    const stopTask = this.capture.stop();
    this.captureStopping = stopTask;
    try {
      await stopTask.catch(() => undefined);
    } finally {
      this.captureRunning = false;
      if (this.captureStopping === stopTask) {
        this.captureStopping = undefined;
      }
    }
  }

  private cancelRecognitionSession(finish: boolean, clearAudio: boolean = true): void {
    const sessionId = this.recognitionSessionId;
    const engine = this.recognizer;
    this.recognitionSessionId = '';
    this.recognitionSessionReady = false;
    this.recognitionSessionAudioBytes = 0;
    if (clearAudio) {
      this.pendingAudio = new Uint8Array(0);
    }
    if (!engine || sessionId.length === 0) {
      return;
    }
    try {
      if (finish) {
        engine.finish(sessionId);
      } else {
        engine.cancel(sessionId);
      }
    } catch (error) {
      if (finish) {
        this.callbacks.onError('STT', this.errorText(error as BusinessError));
      }
    }
  }

  private finishRecognitionSessionForRotation(sessionId: string): void {
    const engine = this.recognizer;
    if (!engine || this.recognitionSessionId !== sessionId || !this.recognitionSessionReady) {
      return;
    }
    this.recognitionSessionReady = false;
    hilog.info(
      SPEECH_LOG_DOMAIN,
      SPEECH_LOG_TAG,
      'ASR rotating session bytes=%{public}d',
      this.recognitionSessionAudioBytes
    );
    try {
      engine.finish(sessionId);
    } catch (error) {
      this.callbacks.onError('STT', this.errorText(error as BusinessError));
    }
  }

  private async ensureRecognizer(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    if (this.recognizer) {
      return this.recognizer;
    }
    let engine: speechRecognizer.SpeechRecognitionEngine;
    try {
      engine = await speechRecognizer.createEngine({
        language: 'zh-CN',
        online: 1
      });
    } catch (error) {
      throw new Error(this.errorText(error as BusinessError));
    }
    this.recognizer = engine;
    this.installRecognitionListener(engine);
    return engine;
  }

  private async ensureTts(person: number): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.tts && this.ttsPerson === person) {
      hilog.info(SPEECH_LOG_DOMAIN, SPEECH_LOG_TAG, 'TTS engine reused person=%{public}d', person);
      return this.tts;
    }
    if (this.tts) {
      this.tts.shutdown();
      this.tts = undefined;
    }
    let engine: textToSpeech.TextToSpeechEngine;
    hilog.info(SPEECH_LOG_DOMAIN, SPEECH_LOG_TAG, 'TTS engine creating person=%{public}d', person);
    try {
      engine = await textToSpeech.createEngine({
        language: 'zh-CN',
        person: person,
        online: 1
      });
    } catch (error) {
      throw new Error(this.errorText(error as BusinessError));
    }
    this.tts = engine;
    this.ttsPerson = person;
    hilog.info(SPEECH_LOG_DOMAIN, SPEECH_LOG_TAG, 'TTS engine created person=%{public}d', person);
    engine.setListener({
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
        hilog.info(
          SPEECH_LOG_DOMAIN,
          SPEECH_LOG_TAG,
          'TTS onStart id=%{public}s type=%{public}s rate=%{public}d',
          requestId,
          response.audioType,
          response.sampleRate
        );
        this.callbacks.onSpeechState(true);
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        hilog.info(
          SPEECH_LOG_DOMAIN,
          SPEECH_LOG_TAG,
          'TTS onComplete id=%{public}s type=%{public}d',
          requestId,
          response.type
        );
        if (response.type === 1) {
          this.callbacks.onSpeechState(false);
        }
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
        hilog.info(
          SPEECH_LOG_DOMAIN,
          SPEECH_LOG_TAG,
          'TTS onStop id=%{public}s type=%{public}d',
          requestId,
          response.type
        );
        this.callbacks.onSpeechState(false);
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        hilog.error(
          SPEECH_LOG_DOMAIN,
          SPEECH_LOG_TAG,
          'TTS onError id=%{public}s code=%{public}d message=%{public}s',
          requestId,
          errorCode,
          errorMessage
        );
        this.callbacks.onSpeechState(false);
        this.callbacks.onError('TTS', `code=${errorCode} message=${errorMessage}`);
      }
    });
    return engine;
  }

  private releaseRecognizer(): void {
    if (this.recognizer) {
      this.recognizer.shutdown();
      this.recognizer = undefined;
    }
    this.recognitionSessionId = '';
    this.recognitionSessionReady = false;
    this.recognitionSessionAudioBytes = 0;
    this.pendingAudio = new Uint8Array(0);
    this.recognitionWanted = false;
  }

  private reportRecognitionStartupPhase(phase: string): void {
    hilog.info(SPEECH_LOG_DOMAIN, SPEECH_LOG_TAG, 'ASR startup phase: %{public}s', phase);
    this.callbacks.onRecognitionStartupPhase(phase);
  }

  private makeId(prefix: string): string {
    return `${prefix}-${Date.now()}`;
  }

  private errorText(error: Error): string {
    const businessError = error as BusinessError;
    if (businessError.code !== undefined) {
      return `code=${businessError.code} message=${businessError.message}`;
    }
    return error.message;
  }
}
