import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const BACKGROUND_AUDIO_LOG_DOMAIN = 0xD005;
const BACKGROUND_AUDIO_LOG_TAG = 'BackgroundAudio';

export type BackgroundAudioIntent = 'none' | 'recording' | 'playback';

export class BackgroundAudioTaskOwner {
  private context?: common.UIAbilityContext;
  private desiredIntent: BackgroundAudioIntent = 'none';
  private runningIntent: BackgroundAudioIntent = 'none';
  private failedIntent: BackgroundAudioIntent = 'none';
  private starting: boolean = false;
  private stopping: boolean = false;
  private onError?: (message: string) => void;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  sync(intent: BackgroundAudioIntent, onError: (message: string) => void): void {
    if (this.desiredIntent !== intent) {
      hilog.info(
        BACKGROUND_AUDIO_LOG_DOMAIN,
        BACKGROUND_AUDIO_LOG_TAG,
        'background intent desired=%{public}s running=%{public}s',
        intent,
        this.runningIntent
      );
      this.failedIntent = 'none';
    }
    this.desiredIntent = intent;
    this.onError = onError;
    if (intent === 'none') {
      this.failedIntent = 'none';
    }
    this.advance();
  }

  private advance(): void {
    if (this.starting || this.stopping) {
      return;
    }
    if (this.runningIntent !== 'none') {
      if (this.runningIntent === this.desiredIntent) {
        return;
      }
      this.stop();
      return;
    }
    if (this.desiredIntent === 'none' || this.desiredIntent === this.failedIntent) {
      return;
    }
    this.start(this.desiredIntent);
  }

  private async start(intent: BackgroundAudioIntent): Promise<void> {
    const context = this.context;
    if (!context || intent === 'none') {
      return;
    }
    this.starting = true;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'cc.daiworld.voice.singleagent',
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      if (this.desiredIntent !== intent) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(context, this.mode(intent), agent);
      this.runningIntent = intent;
      this.failedIntent = 'none';
      hilog.info(
        BACKGROUND_AUDIO_LOG_DOMAIN,
        BACKGROUND_AUDIO_LOG_TAG,
        'background intent started=%{public}s',
        intent
      );
    } catch (error) {
      this.runningIntent = 'none';
      this.failedIntent = intent;
      if (this.desiredIntent === intent && this.onError) {
        this.onError(this.errorMessage(error as BusinessError, '后台音频保持启动失败'));
      }
    } finally {
      this.starting = false;
      this.advance();
    }
  }

  private stop(): void {
    const context = this.context;
    if (!context || this.runningIntent === 'none') {
      this.runningIntent = 'none';
      this.advance();
      return;
    }
    this.stopping = true;
    let stopFailed = false;
    backgroundTaskManager.stopBackgroundRunning(context).then((): void => {
      hilog.info(
        BACKGROUND_AUDIO_LOG_DOMAIN,
        BACKGROUND_AUDIO_LOG_TAG,
        'background intent stopped=%{public}s next=%{public}s',
        this.runningIntent,
        this.desiredIntent
      );
      this.runningIntent = 'none';
    }).catch((error: BusinessError): void => {
      stopFailed = true;
      if (this.desiredIntent !== 'none' && this.onError) {
        this.onError(this.errorMessage(error, '后台音频保持切换失败'));
      }
    }).finally((): void => {
      this.stopping = false;
      if (!stopFailed) {
        this.advance();
      }
    });
  }

  private mode(intent: BackgroundAudioIntent): backgroundTaskManager.BackgroundMode {
    return intent === 'recording'
      ? backgroundTaskManager.BackgroundMode.AUDIO_RECORDING
      : backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK;
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }
}
