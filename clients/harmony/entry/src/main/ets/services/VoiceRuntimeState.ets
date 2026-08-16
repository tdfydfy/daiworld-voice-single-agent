export type VoiceRuntimePhase =
  'idle' | 'ready' | 'switching_session' | 'reconfiguring' | 'disposing' | 'failed';

export type VoiceInputIntent = 'off' | 'conversation' | 'commands_only';

export type VoiceResourceHealth = 'stopped' | 'starting' | 'healthy' | 'recovering' | 'failed';

export type VoiceFailureDomain = 'session' | 'capture' | 'asr' | 'playback' | 'continuity';

export class VoiceFailure {
  domain: VoiceFailureDomain = 'session';
  code: string = '';
  epoch: number = 0;
  recoverable: boolean = false;
  userVisible: boolean = true;
  dedupeKey: string = '';
  message: string = '';
}

export class VoiceRuntimeState {
  epoch: number = 0;
  phase: VoiceRuntimePhase = 'idle';
  inputIntent: VoiceInputIntent = 'off';
  captureHealth: VoiceResourceHealth = 'stopped';
  asrHealth: VoiceResourceHealth = 'stopped';
  playbackHealth: VoiceResourceHealth = 'stopped';
  recordingDemand: boolean = false;
  playbackDemand: boolean = false;
  storedSessionId: string = '';
  runtimeSessionId: string = '';
  activePlaybackJobId: string = '';
  failure?: VoiceFailure;
}

export class VoiceRuntimeReducer {
  readonly state: VoiceRuntimeState = new VoiceRuntimeState();

  begin(phase: VoiceRuntimePhase): number {
    this.state.epoch += 1;
    this.state.phase = phase;
    this.state.failure = undefined;
    return this.state.epoch;
  }

  isCurrent(epoch: number): boolean {
    return epoch === this.state.epoch;
  }

  complete(epoch: number): boolean {
    if (!this.isCurrent(epoch) || this.state.phase === 'disposing') {
      return false;
    }
    this.state.phase = 'ready';
    return true;
  }

  completeDispose(epoch: number): boolean {
    if (!this.isCurrent(epoch) || this.state.phase !== 'disposing') {
      return false;
    }
    this.state.phase = 'idle';
    this.state.inputIntent = 'off';
    this.state.captureHealth = 'stopped';
    this.state.asrHealth = 'stopped';
    this.state.playbackHealth = 'stopped';
    this.state.recordingDemand = false;
    this.state.playbackDemand = false;
    this.state.activePlaybackJobId = '';
    return true;
  }

  setInputIntent(intent: VoiceInputIntent): void {
    this.state.inputIntent = intent;
    this.state.recordingDemand = intent !== 'off';
  }

  setPlaybackDemand(demand: boolean): void {
    this.state.playbackDemand = demand;
  }

  setCaptureHealth(epoch: number, health: VoiceResourceHealth): boolean {
    if (!this.isCurrent(epoch)) {
      return false;
    }
    this.state.captureHealth = health;
    return true;
  }

  setAsrHealth(epoch: number, health: VoiceResourceHealth): boolean {
    if (!this.isCurrent(epoch)) {
      return false;
    }
    this.state.asrHealth = health;
    return true;
  }

  setPlaybackHealth(epoch: number, jobId: string, health: VoiceResourceHealth): boolean {
    if (!this.isCurrent(epoch)) {
      return false;
    }
    if (this.state.activePlaybackJobId.length > 0 && jobId !== this.state.activePlaybackJobId) {
      return false;
    }
    this.state.activePlaybackJobId = health === 'stopped' ? '' : jobId;
    this.state.playbackHealth = health;
    this.state.playbackDemand = health !== 'stopped' && health !== 'failed';
    return true;
  }

  commitSession(epoch: number, storedSessionId: string, runtimeSessionId: string): boolean {
    if (!this.isCurrent(epoch)) {
      return false;
    }
    this.state.storedSessionId = storedSessionId;
    this.state.runtimeSessionId = runtimeSessionId;
    return true;
  }

  fail(epoch: number, failure: VoiceFailure): boolean {
    if (!this.isCurrent(epoch)) {
      return false;
    }
    failure.epoch = epoch;
    this.state.failure = failure;
    this.state.phase = 'failed';
    return true;
  }
}
