import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AudioChunkListener,
  CaptureHealthListener,
  InputRouteListener,
  PcmCapture
} from './PcmCapture';
import { CaptureRecoveryState } from './CaptureRecoveryState';

const CAPTURE_LOG_DOMAIN = 0xD002;
const CAPTURE_LOG_TAG = 'CaptureSupervisor';
const CAPTURE_NO_PCM_TIMEOUT_MS = 2000;
const CAPTURE_WATCHDOG_INTERVAL_MS = 500;
const CAPTURE_RECOVERY_DELAYS_MS: number[] = [100, 500, 1500];

export type CaptureSupervisorStateListener = (state: string, reason: string) => void;
export type CaptureRecoveryExhaustedListener = (message: string) => void;

export class CaptureSupervisorCallbacks {
  private stateCallback: CaptureSupervisorStateListener;
  private exhaustedCallback: CaptureRecoveryExhaustedListener;

  constructor(
    stateCallback: CaptureSupervisorStateListener,
    exhaustedCallback: CaptureRecoveryExhaustedListener
  ) {
    this.stateCallback = stateCallback;
    this.exhaustedCallback = exhaustedCallback;
  }

  onState(state: string, reason: string): void {
    this.stateCallback(state, reason);
  }

  onExhausted(message: string): void {
    this.exhaustedCallback(message);
  }
}

export class CaptureSupervisor {
  private capture: PcmCapture = new PcmCapture();
  private callbacks: CaptureSupervisorCallbacks;
  private recovery: CaptureRecoveryState = new CaptureRecoveryState(
    CAPTURE_RECOVERY_DELAYS_MS.length
  );
  private wanted: boolean = false;
  private listener?: AudioChunkListener;
  private routeListener?: InputRouteListener;
  private watchdog?: number;
  private recoveryTimer?: number;
  private startTask?: Promise<void>;
  private recoveryTask?: Promise<void>;
  private cleanupTask?: Promise<void>;
  private lastPcmAt: number = 0;
  private runningSince: number = 0;
  private lastFailureReason: string = '';
  private requestGeneration: number = 0;

  constructor(callbacks: CaptureSupervisorCallbacks) {
    this.callbacks = callbacks;
  }

  requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    return this.capture.requestPermission(context);
  }

  getInputRouteLabel(): string {
    return this.capture.getInputRouteLabel();
  }

  async start(listener: AudioChunkListener, routeListener?: InputRouteListener): Promise<void> {
    const requestGeneration = ++this.requestGeneration;
    this.wanted = true;
    const cleanup = this.cleanupTask;
    if (cleanup) {
      await cleanup.catch(() => undefined);
    }
    if (!this.wanted || requestGeneration !== this.requestGeneration) {
      return;
    }
    this.listener = listener;
    this.routeListener = routeListener;
    if (this.wanted && this.recovery.phase !== 'idle' && this.recovery.phase !== 'failed') {
      const activeStart = this.startTask;
      if (activeStart) {
        await activeStart;
      }
      return;
    }
    this.cancelRecoveryTimer();
    const generation = this.recovery.beginStart();
    this.callbacks.onState('starting', 'requested');
    const task = this.startInitialCapture(generation);
    this.startTask = task;
    try {
      await task;
    } finally {
      if (this.startTask === task) {
        this.startTask = undefined;
      }
    }
  }

  async stop(): Promise<void> {
    this.wanted = false;
    this.requestGeneration += 1;
    this.recovery.stop();
    this.cancelRecoveryTimer();
    this.cancelWatchdog();
    const activeStart = this.startTask;
    if (activeStart) {
      await activeStart.catch(() => undefined);
    }
    const activeRecovery = this.recoveryTask;
    if (activeRecovery) {
      await activeRecovery.catch(() => undefined);
    }
    await this.stopCapture().catch(() => undefined);
    this.listener = undefined;
    this.routeListener = undefined;
    this.lastPcmAt = 0;
    this.runningSince = 0;
    this.lastFailureReason = '';
    this.callbacks.onState('stopped', 'requested');
  }

  private async startInitialCapture(generation: number): Promise<void> {
    try {
      await this.startCapture(generation);
    } catch (error) {
      if (this.wanted && generation === this.recovery.generation) {
        this.scheduleRecovery(this.errorMessage(error as BusinessError, '音频采集启动失败'));
      }
    }
  }

  private async startCapture(generation: number): Promise<void> {
    const listener = this.listener;
    if (!listener || !this.wanted || generation !== this.recovery.generation) {
      return;
    }
    this.lastPcmAt = 0;
    this.runningSince = Date.now();
    await this.capture.start((buffer: ArrayBuffer): void => {
      if (!this.wanted || generation !== this.recovery.generation) {
        return;
      }
      this.lastPcmAt = Date.now();
      this.recovery.observePcm(generation);
      listener(buffer);
    }, this.routeListener, (reason: string, healthy: boolean): void => {
      this.onCaptureHealth(generation, reason, healthy);
    });
    if (!this.wanted || !this.recovery.markRunning(generation)) {
      await this.capture.stop().catch(() => undefined);
      return;
    }
    this.runningSince = Date.now();
    this.callbacks.onState('running', 'started');
    this.armWatchdog(generation);
  }

  private onCaptureHealth(generation: number, reason: string, healthy: boolean): void {
    if (!this.wanted || generation !== this.recovery.generation) {
      return;
    }
    if (healthy) {
      return;
    }
    this.scheduleRecovery(reason);
  }

  private scheduleRecovery(reason: string): void {
    if (!this.wanted || this.recoveryTimer !== undefined || this.recoveryTask !== undefined) {
      return;
    }
    this.lastFailureReason = reason;
    const generation = this.recovery.beginRecovery();
    if (generation < 0) {
      this.failExhausted(reason);
      return;
    }
    if (generation === 0) {
      return;
    }
    this.cancelWatchdog();
    this.callbacks.onState('recovering', reason);
    const delay = CAPTURE_RECOVERY_DELAYS_MS[this.recovery.recoveryAttempt - 1];
    hilog.warn(
      CAPTURE_LOG_DOMAIN,
      CAPTURE_LOG_TAG,
      'capture recovery scheduled generation=%{public}d attempt=%{public}d delayMs=%{public}d reason=%{public}s',
      generation,
      this.recovery.recoveryAttempt,
      delay,
      reason
    );
    this.recoveryTimer = setTimeout((): void => {
      this.recoveryTimer = undefined;
      this.runRecovery(generation);
    }, delay);
  }

  private runRecovery(generation: number): void {
    if (!this.wanted || generation !== this.recovery.generation || this.recoveryTask !== undefined) {
      return;
    }
    const task = this.recover(generation);
    this.recoveryTask = task;
    task.then((): void => {
      if (this.recoveryTask === task) {
        this.recoveryTask = undefined;
      }
    }, (error: BusinessError): void => {
      if (this.recoveryTask === task) {
        this.recoveryTask = undefined;
      }
      if (!this.wanted || generation !== this.recovery.generation) {
        return;
      }
      this.recovery.failRecovery(generation);
      this.scheduleRecovery(this.errorMessage(error, this.lastFailureReason));
    });
  }

  private async recover(generation: number): Promise<void> {
    await this.capture.stop().catch(() => undefined);
    if (!this.wanted || generation !== this.recovery.generation) {
      return;
    }
    await this.startCapture(generation);
  }

  private armWatchdog(generation: number): void {
    this.cancelWatchdog();
    this.watchdog = setInterval((): void => {
      if (!this.wanted || generation !== this.recovery.generation ||
        this.recovery.phase !== 'running') {
        return;
      }
      const heartbeat = this.lastPcmAt > 0 ? this.lastPcmAt : this.runningSince;
      if (heartbeat > 0 && Date.now() - heartbeat >= CAPTURE_NO_PCM_TIMEOUT_MS) {
        this.scheduleRecovery('连续 2 秒未收到 PCM');
      }
    }, CAPTURE_WATCHDOG_INTERVAL_MS);
  }

  private failExhausted(reason: string): void {
    this.wanted = false;
    this.cancelWatchdog();
    this.cancelRecoveryTimer();
    this.stopCapture().catch(() => undefined);
    const message = `音频采集恢复失败：${reason}`;
    hilog.error(
      CAPTURE_LOG_DOMAIN,
      CAPTURE_LOG_TAG,
      'capture recovery exhausted attempts=%{public}d reason=%{public}s',
      this.recovery.recoveryAttempt,
      reason
    );
    this.callbacks.onState('failed', reason);
    this.callbacks.onExhausted(message);
  }

  private cancelWatchdog(): void {
    if (this.watchdog !== undefined) {
      clearInterval(this.watchdog);
      this.watchdog = undefined;
    }
  }

  private cancelRecoveryTimer(): void {
    if (this.recoveryTimer !== undefined) {
      clearTimeout(this.recoveryTimer);
      this.recoveryTimer = undefined;
    }
  }

  private stopCapture(): Promise<void> {
    const existing = this.cleanupTask;
    if (existing) {
      return existing;
    }
    const task = this.capture.stop();
    this.cleanupTask = task;
    task.then((): void => {
      if (this.cleanupTask === task) {
        this.cleanupTask = undefined;
      }
    }, (): void => {
      if (this.cleanupTask === task) {
        this.cleanupTask = undefined;
      }
    });
    return task;
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }
}
