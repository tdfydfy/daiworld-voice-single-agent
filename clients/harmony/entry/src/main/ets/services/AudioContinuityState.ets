export type BackgroundAudioIntent = 'none' | 'recording' | 'playback';
export type AudioContinuityAction = 'none' | 'start' | 'stop';

export class AudioDemand {
  recording: boolean = false;
  playback: boolean = false;

  constructor(recording: boolean = false, playback: boolean = false) {
    this.recording = recording;
    this.playback = playback;
  }
}

export class DedicatedModePolicy {
  select(demand: AudioDemand): BackgroundAudioIntent {
    if (demand.recording) {
      return 'recording';
    }
    return demand.playback ? 'playback' : 'none';
  }
}

export class AudioContinuityState {
  demand: AudioDemand = new AudioDemand();
  desiredIntent: BackgroundAudioIntent = 'none';
  runningIntent: BackgroundAudioIntent = 'none';
  transitionIntent: BackgroundAudioIntent = 'none';
  phase: string = 'idle';
  generation: number = 0;

  setDemand(recording: boolean, playback: boolean): boolean {
    this.demand.recording = recording;
    this.demand.playback = playback;
    const intent = new DedicatedModePolicy().select(this.demand);
    const changed = this.desiredIntent !== intent;
    this.desiredIntent = intent;
    return changed;
  }

  isReady(intent: BackgroundAudioIntent): boolean {
    return this.phase === 'ready' && this.runningIntent === intent;
  }

  isDemandReady(): boolean {
    return this.desiredIntent === 'none' ? this.isIdle() : this.isReady(this.desiredIntent);
  }

  isIdle(): boolean {
    return this.phase === 'idle' && this.runningIntent === 'none';
  }

  nextAction(): AudioContinuityAction {
    if (this.phase === 'idle' && this.desiredIntent !== 'none') {
      return 'start';
    }
    if (this.phase === 'ready' && this.runningIntent !== this.desiredIntent) {
      return 'stop';
    }
    return 'none';
  }

  begin(action: AudioContinuityAction): number {
    if (action === 'none') {
      return this.generation;
    }
    this.generation += 1;
    if (action === 'start') {
      this.transitionIntent = this.desiredIntent;
      this.phase = 'starting';
    } else {
      this.transitionIntent = this.runningIntent;
      this.phase = 'stopping';
    }
    return this.generation;
  }

  complete(action: AudioContinuityAction, generation: number): boolean {
    if (generation !== this.generation) {
      return false;
    }
    if (action === 'start' && this.phase === 'starting') {
      this.runningIntent = this.transitionIntent;
      this.transitionIntent = 'none';
      this.phase = 'ready';
      return true;
    }
    if (action === 'stop' && this.phase === 'stopping') {
      this.runningIntent = 'none';
      this.transitionIntent = 'none';
      this.phase = 'idle';
      return true;
    }
    return false;
  }

  fail(action: AudioContinuityAction, generation: number): boolean {
    if (generation !== this.generation) {
      return false;
    }
    this.transitionIntent = 'none';
    if (action === 'start' && this.phase === 'starting') {
      this.runningIntent = 'none';
      this.phase = 'idle';
      return true;
    }
    if (action === 'stop' && this.phase === 'stopping') {
      this.phase = 'ready';
      return true;
    }
    return false;
  }
}
