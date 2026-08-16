import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  VoiceFailure,
  VoiceInputIntent,
  VoiceRuntimePhase,
  VoiceRuntimeReducer,
  VoiceRuntimeState
} from './VoiceRuntimeState';

const VOICE_RUNTIME_LOG_DOMAIN = 0xD004;
const VOICE_RUNTIME_LOG_TAG = 'VoiceRuntime';

export class VoiceRuntime {
  private reducer: VoiceRuntimeReducer = new VoiceRuntimeReducer();
  private transactionSerial: number = 0;

  state(): VoiceRuntimeState {
    return this.reducer.state;
  }

  currentEpoch(): number {
    return this.reducer.state.epoch;
  }

  isCurrent(epoch: number): boolean {
    return this.reducer.isCurrent(epoch);
  }

  begin(phase: VoiceRuntimePhase, reason: string): number {
    const epoch = this.reducer.begin(phase);
    this.transactionSerial += 1;
    hilog.info(
      VOICE_RUNTIME_LOG_DOMAIN,
      VOICE_RUNTIME_LOG_TAG,
      'transition begin epoch=%{public}d transaction=%{public}d phase=%{public}s reason=%{public}s',
      epoch,
      this.transactionSerial,
      phase,
      reason
    );
    return epoch;
  }

  complete(epoch: number, reason: string): boolean {
    const committed = this.reducer.complete(epoch);
    hilog.info(
      VOICE_RUNTIME_LOG_DOMAIN,
      VOICE_RUNTIME_LOG_TAG,
      'transition complete epoch=%{public}d current=%{public}d committed=%{public}s reason=%{public}s',
      epoch,
      this.reducer.state.epoch,
      String(committed),
      reason
    );
    return committed;
  }

  completeDispose(epoch: number): boolean {
    return this.reducer.completeDispose(epoch);
  }

  setInputIntent(intent: VoiceInputIntent): void {
    this.reducer.setInputIntent(intent);
  }

  setPlaybackDemand(demand: boolean): void {
    this.reducer.setPlaybackDemand(demand);
  }

  commitSession(epoch: number, storedSessionId: string, runtimeSessionId: string): boolean {
    return this.reducer.commitSession(epoch, storedSessionId, runtimeSessionId);
  }

  fail(epoch: number, failure: VoiceFailure): boolean {
    const committed = this.reducer.fail(epoch, failure);
    if (committed) {
      hilog.error(
        VOICE_RUNTIME_LOG_DOMAIN,
        VOICE_RUNTIME_LOG_TAG,
        'transition failed epoch=%{public}d domain=%{public}s code=%{public}s message=%{public}s',
        epoch,
        failure.domain,
        failure.code,
        failure.message
      );
    }
    return committed;
  }
}
