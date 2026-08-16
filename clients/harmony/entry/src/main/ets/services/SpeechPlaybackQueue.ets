export type PlaybackKind = 'assistant' | 'replay' | 'protocol' | 'cue';
export type PlaybackPriority = 10 | 20 | 30 | 40;

export class PlaybackJob {
  id: string = '';
  epoch: number = 0;
  kind: PlaybackKind = 'assistant';
  priority: PlaybackPriority = 20;
  text: string = '';
  cue: string = '';
  segmentIndex: number = 0;
  skippable: boolean = false;
}

export class SpeechPlaybackQueue {
  private epoch: number = 0;
  private serial: number = 0;
  private active?: PlaybackJob;

  bindEpoch(epoch: number): void {
    this.epoch = epoch;
    this.active = undefined;
  }

  enqueue(
    epoch: number,
    kind: PlaybackKind,
    priority: PlaybackPriority,
    text: string = '',
    cue: string = '',
    skippable: boolean = false
  ): string {
    if (epoch !== this.epoch) {
      return '';
    }
    const job = new PlaybackJob();
    this.serial += 1;
    job.id = `playback-${epoch}-${this.serial}`;
    job.epoch = epoch;
    job.kind = kind;
    job.priority = priority;
    job.text = text;
    job.cue = cue;
    job.skippable = skippable;
    const active = this.active;
    if (!active) {
      this.active = job;
      return job.id;
    }
    if (skippable || (kind === 'cue' && priority <= active.priority)) {
      return '';
    }
    if (priority > active.priority) {
      this.active = job;
      return job.id;
    }
    return '';
  }

  activeJob(): PlaybackJob | undefined {
    return this.active;
  }

  isActive(epoch: number, jobId: string): boolean {
    return epoch === this.epoch && this.active?.id === jobId;
  }

  complete(epoch: number, jobId: string): PlaybackJob | undefined {
    if (!this.isActive(epoch, jobId)) {
      return this.active;
    }
    this.active = undefined;
    return this.active;
  }

  cancelAll(epoch: number): boolean {
    if (epoch !== this.epoch) {
      return false;
    }
    this.active = undefined;
    return true;
  }

  hasOutput(): boolean {
    return this.active !== undefined;
  }
}
