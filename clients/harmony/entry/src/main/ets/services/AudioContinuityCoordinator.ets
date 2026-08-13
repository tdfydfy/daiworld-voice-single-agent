import { common } from '@kit.AbilityKit';
import { BackgroundAudioIntent, BackgroundAudioTaskOwner } from './BackgroundAudioTaskOwner';

export class AudioContinuityCoordinator {
  private owner: BackgroundAudioTaskOwner = new BackgroundAudioTaskOwner();
  private desiredIntent: BackgroundAudioIntent = 'none';
  private onError?: (message: string) => void;

  setContext(context: common.UIAbilityContext): void {
    this.owner.setContext(context);
  }

  setErrorListener(onError: (message: string) => void): void {
    this.onError = onError;
  }

  syncIntent(intent: BackgroundAudioIntent): void {
    this.desiredIntent = intent;
    this.owner.sync(intent, (message: string): void => {
      this.onError?.(message);
    });
  }

  ensureRecordingReady(): Promise<void> {
    return this.ensureReady('recording');
  }

  ensurePlaybackReady(): Promise<void> {
    return this.ensureReady('playback');
  }

  release(): Promise<void> {
    this.desiredIntent = 'none';
    return this.owner.release((message: string): void => {
      this.onError?.(message);
    });
  }

  private ensureReady(intent: BackgroundAudioIntent): Promise<void> {
    this.desiredIntent = intent;
    return this.owner.ensureReady(intent, (message: string): void => {
      this.onError?.(message);
    });
  }
}
