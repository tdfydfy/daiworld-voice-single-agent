export class RecoveryBudget {
  attempt: number = 0;
  windowStartedAt: number = 0;
  stableSince: number = 0;
  readonly maxAttempts: number;
  readonly windowMs: number;
  readonly stableResetMs: number;

  constructor(maxAttempts: number, windowMs: number = 60000, stableResetMs: number = 10000) {
    this.maxAttempts = maxAttempts;
    this.windowMs = windowMs;
    this.stableResetMs = stableResetMs;
  }

  beginAttempt(now: number = Date.now()): number {
    if (this.windowStartedAt === 0 || now - this.windowStartedAt >= this.windowMs) {
      this.attempt = 0;
      this.windowStartedAt = now;
      this.stableSince = 0;
    }
    if (this.attempt >= this.maxAttempts) {
      return 0;
    }
    this.attempt += 1;
    this.stableSince = 0;
    return this.attempt;
  }

  observeHealthy(now: number = Date.now()): boolean {
    if (this.attempt === 0) {
      return false;
    }
    if (this.stableSince === 0) {
      this.stableSince = now;
      return false;
    }
    if (now - this.stableSince < this.stableResetMs) {
      return false;
    }
    this.attempt = 0;
    this.windowStartedAt = now;
    this.stableSince = now;
    return true;
  }

  reset(): void {
    this.attempt = 0;
    this.windowStartedAt = 0;
    this.stableSince = 0;
  }
}
