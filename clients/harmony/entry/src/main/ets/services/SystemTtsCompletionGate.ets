export type SystemTtsPlaybackEvent = 'started' | 'completed' | 'interrupted';

export class SystemTtsCompletionGate {
  private startedAt: number = 0;
  private minimumPlaybackMs: number = 0;

  begin(text: string, speechRate: number): void {
    const rate = Math.max(0.5, Math.min(2, speechRate));
    let weightedMs = 0;
    for (let index = 0; index < text.length; index += 1) {
      const code = text.charCodeAt(index);
      const cjk = (code >= 0x3400 && code <= 0x4DBF) ||
        (code >= 0x4E00 && code <= 0x9FFF);
      weightedMs += cjk ? 160 : 35;
    }
    this.startedAt = 0;
    this.minimumPlaybackMs = Math.max(120, Math.ceil(weightedMs / rate));
  }

  markStarted(now: number): void {
    this.startedAt = now;
  }

  classifyCompletion(now: number): SystemTtsPlaybackEvent {
    if (this.startedAt <= 0 || now - this.startedAt < this.minimumPlaybackMs) {
      return 'interrupted';
    }
    return 'completed';
  }

  elapsed(now: number): number {
    return this.startedAt > 0 ? Math.max(0, now - this.startedAt) : 0;
  }

  minimum(): number {
    return this.minimumPlaybackMs;
  }

  reset(): void {
    this.startedAt = 0;
    this.minimumPlaybackMs = 0;
  }
}
