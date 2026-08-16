import { common } from '@kit.AbilityKit';
import { BackgroundAudioIntent, BackgroundAudioTaskOwner } from './BackgroundAudioTaskOwner';
import { AudioDemand } from './AudioContinuityState';

export class AudioContinuityCoordinator {
  private owner: BackgroundAudioTaskOwner = new BackgroundAudioTaskOwner();
  private demand: AudioDemand = new AudioDemand();
  private onError?: (message: string) => void;

  setContext(context: common.UIAbilityContext): void {
    this.owner.setContext(context);
  }

  setErrorListener(onError: (message: string) => void): void {
    this.onError = onError;
  }

  syncDemand(recording: boolean, playback: boolean): void {
    this.demand.recording = recording;
    this.demand.playback = playback;
    this.owner.syncDemand(this.demand, (message: string): void => {
      this.onError?.(message);
    });
  }

  ensureRecordingReady(): Promise<void> {
    return this.ensureReady('recording');
  }

  ensurePlaybackReady(): Promise<void> {
    return this.ensureReady('playback');
  }

  async release(): Promise<void> {
    this.demand.recording = false;
    this.demand.playback = false;
    await this.owner.release((message: string): void => {
      this.onError?.(message);
    });
  }

  private async ensureReady(intent: BackgroundAudioIntent): Promise<void> {
    if (intent === 'recording') {
      this.demand.recording = true;
    } else if (intent === 'playback') {
      this.demand.playback = true;
    }
    await this.owner.ensureReady(intent, this.demand, (message: string): void => {
      this.onError?.(message);
    });
  }
}
