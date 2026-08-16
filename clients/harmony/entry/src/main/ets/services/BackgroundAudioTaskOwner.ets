import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AudioContinuityAction,
  AudioDemand,
  AudioContinuityState,
  BackgroundAudioIntent
} from './AudioContinuityState';

const BACKGROUND_AUDIO_LOG_DOMAIN = 0xD005;
const BACKGROUND_AUDIO_LOG_TAG = 'BackgroundAudio';

export { BackgroundAudioIntent } from './AudioContinuityState';

export class BackgroundAudioTaskOwner {
  private context?: common.UIAbilityContext;
  private state: AudioContinuityState = new AudioContinuityState();
  private reconcileTask?: Promise<void>;
  private failedIntent: BackgroundAudioIntent = 'none';
  private onError?: (message: string) => void;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  syncDemand(demand: AudioDemand, onError: (message: string) => void): void {
    const changed = this.state.setDemand(demand.recording, demand.playback);
    const intent = this.state.desiredIntent;
    this.onError = onError;
    if (changed) {
      this.failedIntent = 'none';
      this.logState('desired');
    }
    if (intent === 'none') {
      this.failedIntent = 'none';
    }
    if (intent === this.failedIntent) {
      return;
    }
    this.ensureReconcile().catch(() => undefined);
  }

  ensureReady(
    intent: BackgroundAudioIntent,
    demand: AudioDemand,
    onError: (message: string) => void
  ): Promise<void> {
    this.state.setDemand(demand.recording, demand.playback);
    this.failedIntent = 'none';
    this.onError = onError;
    this.logState('ensure');
    return this.ensureReconcile().then((): void => {
      if (!this.state.isDemandReady()) {
        throw new Error(`后台音频${intent === 'playback' ? '播放' : '录音'}模式尚未就绪`);
      }
    });
  }

  release(onError: (message: string) => void): Promise<void> {
    this.state.setDemand(false, false);
    this.failedIntent = 'none';
    this.onError = onError;
    this.logState('release');
    return this.ensureReconcile().then((): void => {
      if (!this.state.isIdle()) {
        throw new Error('后台音频任务尚未释放');
      }
    });
  }

  private ensureReconcile(): Promise<void> {
    const existing = this.reconcileTask;
    if (existing) {
      return existing.then((): Promise<void> => {
        if (this.state.nextAction() !== 'none' && this.state.desiredIntent !== this.failedIntent) {
          return this.ensureReconcile();
        }
        return Promise.resolve();
      });
    }
    const task = this.reconcile();
    this.reconcileTask = task;
    return task.finally((): void => {
      if (this.reconcileTask === task) {
        this.reconcileTask = undefined;
      }
    });
  }

  private async reconcile(): Promise<void> {
    while (true) {
      const action = this.state.nextAction();
      if (action === 'none' || this.state.desiredIntent === this.failedIntent) {
        return;
      }
      const generation = this.state.begin(action);
      const transitionIntent = this.state.transitionIntent;
      this.logTransition(action, transitionIntent, generation, 'begin');
      try {
        if (action === 'start') {
          await this.start(transitionIntent);
        } else {
          await this.stop();
        }
      } catch (error) {
        this.state.fail(action, generation);
        if (action === 'start') {
          this.failedIntent = transitionIntent;
        }
        const message = this.errorMessage(
          error as BusinessError,
          action === 'start' ? '后台音频保持启动失败' : '后台音频保持切换失败'
        );
        this.logTransition(action, transitionIntent, generation, 'failed');
        this.onError?.(message);
        throw new Error(message);
      }
      this.state.complete(action, generation);
      this.failedIntent = 'none';
      this.logTransition(action, transitionIntent, generation, 'complete');
    }
  }

  private async start(intent: BackgroundAudioIntent): Promise<void> {
    const context = this.context;
    if (!context || intent === 'none') {
      throw new Error('后台音频保持缺少 UIAbilityContext');
    }
    const agent = await wantAgent.getWantAgent({
      wants: [{
        bundleName: 'cc.daiworld.voice.singleagent',
        abilityName: 'EntryAbility'
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    await backgroundTaskManager.startBackgroundRunning(context, this.mode(intent), agent);
  }

  private async stop(): Promise<void> {
    const context = this.context;
    if (!context) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      if (!this.isTaskVerificationError(error as BusinessError)) {
        throw new Error(this.errorMessage(error as BusinessError, '后台音频保持停止失败'));
      }
      hilog.warn(
        BACKGROUND_AUDIO_LOG_DOMAIN,
        BACKGROUND_AUDIO_LOG_TAG,
        'background stop reported 9800005; treating the stale task as already stopped'
      );
    }
  }

  private mode(intent: BackgroundAudioIntent): backgroundTaskManager.BackgroundMode {
    return intent === 'recording'
      ? backgroundTaskManager.BackgroundMode.AUDIO_RECORDING
      : backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK;
  }

  private logState(reason: string): void {
    hilog.info(
      BACKGROUND_AUDIO_LOG_DOMAIN,
      BACKGROUND_AUDIO_LOG_TAG,
      'background state reason=%{public}s desired=%{public}s running=%{public}s phase=%{public}s',
      reason,
      this.state.desiredIntent,
      this.state.runningIntent,
      this.state.phase
    );
  }

  private logTransition(
    action: AudioContinuityAction,
    intent: BackgroundAudioIntent,
    generation: number,
    result: string
  ): void {
    hilog.info(
      BACKGROUND_AUDIO_LOG_DOMAIN,
      BACKGROUND_AUDIO_LOG_TAG,
      'background action=%{public}s intent=%{public}s result=%{public}s generation=%{public}d',
      action,
      intent,
      result,
      generation
    );
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }

  private isTaskVerificationError(error: BusinessError): boolean {
    return (error !== undefined && error.code === 9800005) ||
      (error !== undefined && typeof error.message === 'string' && error.message.indexOf('9800005') >= 0);
  }
}
