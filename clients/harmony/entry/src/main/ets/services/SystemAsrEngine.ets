import { BusinessError } from '@kit.BasicServicesKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const SPEECH_FRAME_BYTES = 640;
const SPEECH_PRE_ROLL_BYTES = 6400;
const SPEECH_SESSION_MAX_AUDIO_BYTES = 16000 * 2 * 18;
const SYSTEM_ASR_LOG_DOMAIN = 0xD003;
const SYSTEM_ASR_LOG_TAG = 'SystemAsrEngine';

export type SystemAsrStateCallback = (epoch: number, active: boolean) => void;
export type SystemAsrResultCallback = (
  epoch: number,
  text: string,
  isFinal: boolean,
  isLast: boolean
) => void;
export type SystemAsrAudioStartCallback = (epoch: number) => void;
export type SystemAsrStartupCallback = (epoch: number, phase: string) => void;
export type SystemAsrErrorCallback = (epoch: number, message: string) => void;

export class SystemAsrCallbacks {
  private stateCallback: SystemAsrStateCallback;
  private resultCallback: SystemAsrResultCallback;
  private audioStartCallback: SystemAsrAudioStartCallback;
  private startupCallback: SystemAsrStartupCallback;
  private errorCallback: SystemAsrErrorCallback;

  constructor(
    stateCallback: SystemAsrStateCallback,
    resultCallback: SystemAsrResultCallback,
    audioStartCallback: SystemAsrAudioStartCallback,
    startupCallback: SystemAsrStartupCallback,
    errorCallback: SystemAsrErrorCallback
  ) {
    this.stateCallback = stateCallback;
    this.resultCallback = resultCallback;
    this.audioStartCallback = audioStartCallback;
    this.startupCallback = startupCallback;
    this.errorCallback = errorCallback;
  }

  onState(epoch: number, active: boolean): void {
    this.stateCallback(epoch, active);
  }

  onResult(epoch: number, text: string, isFinal: boolean, isLast: boolean): void {
    this.resultCallback(epoch, text, isFinal, isLast);
  }

  onAudioStart(epoch: number): void {
    this.audioStartCallback(epoch);
  }

  onStartup(epoch: number, phase: string): void {
    this.startupCallback(epoch, phase);
  }

  onError(epoch: number, message: string): void {
    this.errorCallback(epoch, message);
  }
}

export class SystemAsrEngine {
  private callbacks: SystemAsrCallbacks;
  private recognizer?: speechRecognizer.SpeechRecognitionEngine;
  private activeEpoch: number = 0;
  private sessionEpoch: number = 0;
  private sessionId: string = '';
  private sessionReady: boolean = false;
  private rotatingSession: boolean = false;
  private sessionAudioBytes: number = 0;
  private pendingAudio: Uint8Array = new Uint8Array(0);
  private wanted: boolean = false;
  private requestSerial: number = 0;
  private disposed: boolean = false;

  constructor(callbacks: SystemAsrCallbacks) {
    this.callbacks = callbacks;
  }

  isSupported(): boolean {
    return canIUse('SystemCapability.AI.SpeechRecognizer');
  }

  async start(epoch: number): Promise<void> {
    if (this.disposed || !this.isSupported()) {
      throw new Error('设备不支持鸿蒙系统语音识别');
    }
    this.wanted = true;
    this.activeEpoch = epoch;
    this.reportStartup(epoch, '创建本地识别引擎');
    const engine = await this.ensureRecognizer();
    if (!this.wanted || epoch !== this.activeEpoch) {
      return;
    }
    this.startSession(engine, epoch);
  }

  async bindEpoch(epoch: number): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.activeEpoch = epoch;
    this.cancelSession(false, true);
    if (!this.wanted) {
      return;
    }
    const engine = await this.ensureRecognizer();
    if (!this.wanted || epoch !== this.activeEpoch) {
      return;
    }
    this.startSession(engine, epoch);
  }

  acceptPcm(epoch: number, buffer: ArrayBuffer): void {
    if (!this.wanted || epoch !== this.activeEpoch) {
      return;
    }
    const incoming = new Uint8Array(buffer);
    const merged = new Uint8Array(this.pendingAudio.length + incoming.length);
    merged.set(this.pendingAudio, 0);
    merged.set(incoming, this.pendingAudio.length);
    this.pendingAudio = merged;
    const sessionId = this.sessionId;
    if (sessionId.length === 0 || !this.sessionReady) {
      if (this.pendingAudio.length > SPEECH_PRE_ROLL_BYTES) {
        this.pendingAudio = this.pendingAudio.slice(this.pendingAudio.length - SPEECH_PRE_ROLL_BYTES);
      }
      return;
    }
    this.flushAudio(sessionId);
  }

  stop(epoch: number, finish: boolean = false): Promise<void> {
    this.activeEpoch = epoch;
    this.wanted = false;
    this.cancelSession(finish, true);
    this.callbacks.onState(epoch, false);
    return Promise.resolve();
  }

  async release(epoch: number): Promise<void> {
    this.disposed = true;
    await this.stop(epoch, false);
    if (this.recognizer) {
      this.recognizer.shutdown();
      this.recognizer = undefined;
    }
  }

  private startSession(
    engine: speechRecognizer.SpeechRecognitionEngine,
    epoch: number,
    clearAudio: boolean = true
  ): void {
    this.cancelSession(false, clearAudio);
    const sessionId = this.makeId('stt');
    this.sessionId = sessionId;
    this.sessionEpoch = epoch;
    this.sessionReady = false;
    this.sessionAudioBytes = 0;
    try {
      this.reportStartup(epoch, '启动识别会话');
      engine.startListening({
        sessionId: sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      this.reportStartup(epoch, '等待识别引擎 ready');
    } catch (error) {
      this.sessionId = '';
      this.sessionReady = false;
      throw new Error(this.errorText(error as BusinessError));
    }
  }

  private installListener(engine: speechRecognizer.SpeechRecognitionEngine): void {
    engine.setListener({
      onStart: (sessionId: string, _eventMessage: string): void => {
        if (this.sessionId !== sessionId) {
          return;
        }
        const epoch = this.sessionEpoch;
        this.sessionReady = true;
        this.sessionAudioBytes = 0;
        this.flushAudio(sessionId);
        this.callbacks.onState(epoch, true);
      },
      onEvent: (sessionId: string, eventCode: number, _eventMessage: string): void => {
        if (this.sessionId === sessionId && eventCode === 1) {
          this.callbacks.onAudioStart(this.sessionEpoch);
        }
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (this.sessionId !== sessionId) {
          return;
        }
        this.callbacks.onResult(this.sessionEpoch, result.result, result.isFinal, result.isLast);
      },
      onComplete: (sessionId: string, _eventMessage: string): void => {
        if (this.sessionId !== sessionId) {
          return;
        }
        const epoch = this.sessionEpoch;
        const rotating = this.rotatingSession;
        this.sessionId = '';
        this.sessionReady = false;
        this.sessionAudioBytes = 0;
        this.rotatingSession = false;
        if (rotating && this.wanted && epoch === this.activeEpoch && this.recognizer) {
          try {
            this.startSession(this.recognizer, epoch, false);
          } catch (error) {
            this.callbacks.onState(epoch, false);
            this.callbacks.onError(epoch, this.errorText(error as BusinessError));
          }
          return;
        }
        this.callbacks.onState(epoch, false);
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
        if (this.sessionId !== sessionId) {
          return;
        }
        const epoch = this.sessionEpoch;
        this.sessionId = '';
        this.sessionReady = false;
        this.sessionAudioBytes = 0;
        this.rotatingSession = false;
        this.callbacks.onState(epoch, false);
        this.callbacks.onError(epoch, `code=${errorCode} message=${errorMessage}`);
      }
    });
  }

  private flushAudio(sessionId: string): void {
    const audioBytes = this.pendingAudio;
    let offset = 0;
    while (offset + SPEECH_FRAME_BYTES <= audioBytes.length) {
      if (!this.recognizer || this.sessionId !== sessionId || !this.sessionReady) {
        return;
      }
      if (this.sessionAudioBytes + SPEECH_FRAME_BYTES > SPEECH_SESSION_MAX_AUDIO_BYTES) {
        this.pendingAudio = audioBytes.slice(offset);
        this.finishForRotation(sessionId);
        return;
      }
      try {
        this.recognizer.writeAudio(sessionId, audioBytes.slice(offset, offset + SPEECH_FRAME_BYTES));
      } catch (error) {
        this.sessionReady = false;
        this.callbacks.onError(this.sessionEpoch, this.errorText(error as BusinessError));
        return;
      }
      this.sessionAudioBytes += SPEECH_FRAME_BYTES;
      offset += SPEECH_FRAME_BYTES;
    }
    this.pendingAudio = audioBytes.slice(offset);
  }

  private finishForRotation(sessionId: string): void {
    const engine = this.recognizer;
    if (!engine || this.sessionId !== sessionId || !this.sessionReady) {
      return;
    }
    this.sessionReady = false;
    this.rotatingSession = true;
    hilog.info(
      SYSTEM_ASR_LOG_DOMAIN,
      SYSTEM_ASR_LOG_TAG,
      'ASR rotating session epoch=%{public}d bytes=%{public}d',
      this.sessionEpoch,
      this.sessionAudioBytes
    );
    try {
      engine.finish(sessionId);
    } catch (error) {
      this.rotatingSession = false;
      this.callbacks.onError(this.sessionEpoch, this.errorText(error as BusinessError));
    }
  }

  private cancelSession(finish: boolean, clearAudio: boolean): void {
    const sessionId = this.sessionId;
    const engine = this.recognizer;
    this.sessionId = '';
    this.sessionReady = false;
    this.sessionAudioBytes = 0;
    this.rotatingSession = false;
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
        this.callbacks.onError(this.sessionEpoch, this.errorText(error as BusinessError));
      }
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
    if (this.disposed) {
      engine.shutdown();
      throw new Error('System ASR engine was disposed');
    }
    this.recognizer = engine;
    this.installListener(engine);
    return engine;
  }

  private reportStartup(epoch: number, phase: string): void {
    hilog.info(
      SYSTEM_ASR_LOG_DOMAIN,
      SYSTEM_ASR_LOG_TAG,
      'ASR startup epoch=%{public}d phase=%{public}s',
      epoch,
      phase
    );
    this.callbacks.onStartup(epoch, phase);
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
