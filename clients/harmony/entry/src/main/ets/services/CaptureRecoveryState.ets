export class CaptureRecoveryState {
  phase: string = 'idle';
  generation: number = 0;
  recoveryAttempt: number = 0;
  readonly maxAttempts: number;
  readonly windowMs: number;
  readonly stableResetMs: number;
  windowStartedAt: number = 0;
  stableSince: number = 0;

  constructor(maxAttempts: number = 3, windowMs: number = 60000, stableResetMs: number = 10000) {
    this.maxAttempts = maxAttempts;
    this.windowMs = windowMs;
    this.stableResetMs = stableResetMs;
  }

  beginStart(now: number = Date.now()): number {
    this.generation += 1;
    this.phase = 'starting';
    this.recoveryAttempt = 0;
    this.windowStartedAt = now;
    this.stableSince = 0;
    return this.generation;
  }

  markRunning(generation: number, now: number = Date.now()): boolean {
    if (generation !== this.generation ||
      (this.phase !== 'starting' && this.phase !== 'recovering')) {
      return false;
    }
    this.phase = 'running';
    this.stableSince = now;
    return true;
  }

  observePcm(generation: number, now: number = Date.now()): boolean {
    if (generation !== this.generation || this.phase !== 'running') {
      return false;
    }
    if (this.stableSince === 0) {
      this.stableSince = now;
    }
    if (this.recoveryAttempt > 0 && now - this.stableSince >= this.stableResetMs) {
      this.recoveryAttempt = 0;
      this.windowStartedAt = now;
    }
    return true;
  }

  beginRecovery(now: number = Date.now()): number {
    if (this.phase === 'recovering') {
      return 0;
    }
    if (this.phase === 'idle') {
      return -1;
    }
    if (this.windowStartedAt === 0 || now - this.windowStartedAt >= this.windowMs) {
      this.windowStartedAt = now;
      this.recoveryAttempt = 0;
    }
    if (this.phase === 'failed' || this.recoveryAttempt >= this.maxAttempts) {
      this.phase = 'failed';
      return -1;
    }
    this.recoveryAttempt += 1;
    this.generation += 1;
    this.phase = 'recovering';
    this.stableSince = 0;
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
    this.windowStartedAt = 0;
    this.stableSince = 0;
    return this.generation;
  }
}
