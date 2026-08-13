export class CaptureRecoveryState {
  phase: string = 'idle';
  generation: number = 0;
  recoveryAttempt: number = 0;
  readonly maxAttempts: number;

  constructor(maxAttempts: number = 3) {
    this.maxAttempts = maxAttempts;
  }

  beginStart(): number {
    this.generation += 1;
    this.phase = 'starting';
    this.recoveryAttempt = 0;
    return this.generation;
  }

  markRunning(generation: number): boolean {
    if (generation !== this.generation ||
      (this.phase !== 'starting' && this.phase !== 'recovering')) {
      return false;
    }
    this.phase = 'running';
    return true;
  }

  observePcm(generation: number): boolean {
    if (generation !== this.generation || this.phase !== 'running') {
      return false;
    }
    this.recoveryAttempt = 0;
    return true;
  }

  beginRecovery(): number {
    if (this.phase === 'recovering') {
      return 0;
    }
    if (this.phase === 'idle') {
      return -1;
    }
    if (this.phase === 'failed' || this.recoveryAttempt >= this.maxAttempts) {
      this.phase = 'failed';
      return -1;
    }
    this.recoveryAttempt += 1;
    this.generation += 1;
    this.phase = 'recovering';
    return this.generation;
  }

  failRecovery(generation: number): boolean {
    if (generation !== this.generation || this.phase !== 'recovering') {
      return false;
    }
    if (this.recoveryAttempt >= this.maxAttempts) {
      this.phase = 'failed';
    } else {
      this.phase = 'starting';
    }
    return true;
  }

  stop(): number {
    this.generation += 1;
    this.phase = 'idle';
    this.recoveryAttempt = 0;
    return this.generation;
  }
}
