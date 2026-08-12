const FIRST_MIN = 20;
const FIRST_TARGET = 32;
const FIRST_MAX = 48;
const NEXT_MIN = 40;
const NEXT_TARGET = 64;
const NEXT_PREFERRED_MAX = 80;
const HARD_MAX = 96;
const HARD_BOUNDARIES = '。！？；.!?;\n';
const SOFT_BOUNDARIES = '，、：,: ';

export class SystemSpeechQueue {
  private activeText: string = '';
  private pausedText: string = '';
  private queue: string[] = [];
  private startedAt: number = 0;
  private pendingText: string = '';
  private receivedText: string = '';
  private firstChunkQueued: boolean = false;

  beginStream(): void {
    this.pendingText = '';
    this.receivedText = '';
    this.firstChunkQueued = false;
  }

  appendStream(text: string): string[] {
    if (text.length === 0) {
      return [];
    }
    this.pendingText += text;
    this.receivedText += text;
    return this.flush(false);
  }

  finishStream(finalText: string): string[] {
    if (this.receivedText.length === 0) {
      this.pendingText += finalText;
    } else if (finalText.startsWith(this.receivedText) && finalText.length > this.receivedText.length) {
      this.pendingText += finalText.substring(this.receivedText.length);
    }
    return this.flush(true);
  }

  pendingLength(): number {
    return this.pendingText.length;
  }

  receivedLength(): number {
    return this.receivedText.length;
  }

  activate(text: string): void {
    this.activeText = text;
    this.startedAt = 0;
  }

  markStarted(): void {
    this.startedAt = Date.now();
  }

  active(): string {
    return this.activeText;
  }

  hasActive(): boolean {
    return this.activeText.length > 0;
  }

  enqueue(text: string): void {
    this.queue.push(text);
  }

  queuedCount(): number {
    return this.queue.length;
  }

  takeNext(): string {
    const next = this.queue.shift();
    return next === undefined ? '' : next;
  }

  completeActive(): string {
    this.activeText = '';
    this.startedAt = 0;
    return this.takeNext();
  }

  pause(speechRate: number): void {
    this.pausedText = this.remainingText(speechRate);
  }

  takeResumeText(): string {
    const remaining = this.pausedText;
    this.pausedText = '';
    this.activeText = '';
    this.startedAt = 0;
    return remaining.length > 0 ? remaining : this.takeNext();
  }

  hasPendingOutput(): boolean {
    return this.activeText.length > 0 || this.queue.length > 0;
  }

  clear(): void {
    this.activeText = '';
    this.pausedText = '';
    this.queue = [];
    this.startedAt = 0;
    this.beginStream();
  }

  private flush(final: boolean): string[] {
    const chunks: string[] = [];
    while (this.pendingText.trim().length > 0) {
      const end = this.chunkEnd(this.pendingText, final);
      if (end <= 0) {
        break;
      }
      const chunk = this.pendingText.substring(0, end).trim();
      this.pendingText = this.trimLeading(this.pendingText.substring(end));
      if (chunk.length > 0) {
        this.firstChunkQueued = true;
        chunks.push(chunk);
      }
    }
    return chunks;
  }

  private remainingText(speechRate: number): string {
    const text = this.activeText;
    if (text.length === 0 || this.startedAt <= 0) {
      return text;
    }
    const elapsedSeconds = Math.max(0, Date.now() - this.startedAt) / 1000;
    const estimatedIndex = Math.min(text.length, Math.floor(elapsedSeconds * 4.5 * speechRate));
    if (estimatedIndex <= 1) {
      return text;
    }
    const punctuation = '。！？；，,.!?;\n';
    for (let index = estimatedIndex - 1; index >= 0; index -= 1) {
      if (punctuation.includes(text[index])) {
        return text.substring(index + 1).trim();
      }
    }
    return text;
  }

  private trimLeading(text: string): string {
    const whitespace = ' \t\r\n';
    let index = 0;
    while (index < text.length && whitespace.includes(text[index])) {
      index += 1;
    }
    return text.substring(index);
  }

  private chunkEnd(text: string, final: boolean): number {
    const length = text.length;
    if (length === 0) {
      return 0;
    }
    const finalLimit = this.firstChunkQueued ? NEXT_PREFERRED_MAX : FIRST_MAX;
    if (final && length <= finalLimit) {
      return length;
    }
    if (!this.firstChunkQueued) {
      if (length < FIRST_MIN) {
        return final ? length : 0;
      }
      const hardEnd = this.firstBoundaryEnd(text, HARD_BOUNDARIES, FIRST_MIN - 1, Math.min(length, FIRST_MAX));
      if (hardEnd > 0) {
        return hardEnd;
      }
      if (length >= FIRST_TARGET) {
        const softEnd = this.lastBoundaryEnd(text, SOFT_BOUNDARIES, FIRST_MIN - 1, Math.min(length, FIRST_TARGET));
        if (softEnd > 0) {
          return softEnd;
        }
      }
      return length >= FIRST_MAX ? FIRST_MAX : 0;
    }
    if (length < NEXT_MIN) {
      return final ? length : 0;
    }
    const preferredHardEnd = this.firstBoundaryEnd(
      text,
      HARD_BOUNDARIES,
      NEXT_MIN - 1,
      Math.min(length, NEXT_PREFERRED_MAX)
    );
    if (preferredHardEnd > 0) {
      return preferredHardEnd;
    }
    if (length >= NEXT_TARGET) {
      const targetEnd = this.lastBoundaryEnd(
        text,
        HARD_BOUNDARIES + SOFT_BOUNDARIES,
        NEXT_MIN - 1,
        Math.min(length, NEXT_TARGET)
      );
      if (targetEnd > 0) {
        return targetEnd;
      }
    }
    if (length > NEXT_PREFERRED_MAX) {
      const laterEnd = this.firstBoundaryEnd(
        text,
        HARD_BOUNDARIES + SOFT_BOUNDARIES,
        NEXT_PREFERRED_MAX - 1,
        Math.min(length, HARD_MAX)
      );
      if (laterEnd > 0) {
        return laterEnd;
      }
    }
    if (length >= HARD_MAX) {
      const safeEnd = this.lastBoundaryEnd(
        text,
        HARD_BOUNDARIES + SOFT_BOUNDARIES,
        NEXT_MIN - 1,
        HARD_MAX
      );
      return safeEnd > 0 ? safeEnd : HARD_MAX;
    }
    if (final) {
      return NEXT_PREFERRED_MAX;
    }
    return 0;
  }

  private firstBoundaryEnd(text: string, boundaries: string, start: number, end: number): number {
    for (let index = Math.max(0, start); index < Math.min(text.length, end); index += 1) {
      if (boundaries.includes(text[index])) {
        return index + 1;
      }
    }
    return 0;
  }

  private lastBoundaryEnd(text: string, boundaries: string, start: number, end: number): number {
    for (let index = Math.min(text.length, end) - 1; index >= Math.max(0, start); index -= 1) {
      if (boundaries.includes(text[index])) {
        return index + 1;
      }
    }
    return 0;
  }
}
