// Keeps the full assistant text on screen while producing a short TTS-safe view.

export class SpeechTextFilter {
  private codeBlock: boolean = false;
  private pending: string = '';

  push(value: string): string {
    this.pending += value;
    let output = '';
    let boundary = this.findBoundary(this.pending);
    while (boundary >= 0) {
      const segment = this.pending.substring(0, boundary + 1);
      this.pending = this.pending.substring(boundary + 1);
      output += this.consume(segment);
      boundary = this.findBoundary(this.pending);
    }
    return output;
  }

  flush(): string {
    const output = this.consume(this.pending);
    this.pending = '';
    this.codeBlock = false;
    return output;
  }

  static clean(value: string): string {
    let text = String(value || '').replace(/```[\s\S]*?```/g, ' ');
    text = text.replace(/^\s*MEDIA:\s*.*$/gim, ' ');
    text = text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
    text = text.replace(/https?:\/\/[^\s]+/gi, ' ');
    text = text.replace(/[\\/~][^\s]+\.[A-Za-z0-9]{1,8}/g, ' ');
    text = text.replace(/[*_#>`~]/g, '');
    return text.replace(/\s+/g, ' ').trim();
  }

  private findBoundary(value: string): number {
    for (let index = 0; index < value.length; index += 1) {
      if ('。！？!?；;\n'.includes(value[index])) {
        return index;
      }
    }
    return value.length >= 160 ? 159 : -1;
  }

  private consume(segment: string): string {
    let output = '';
    let cursor = 0;
    while (cursor < segment.length) {
      const fence = segment.indexOf('```', cursor);
      if (fence < 0) {
        if (!this.codeBlock) {
          output += segment.substring(cursor);
        }
        break;
      }
      if (!this.codeBlock) {
        output += segment.substring(cursor, fence);
      }
      this.codeBlock = !this.codeBlock;
      cursor = fence + 3;
    }
    return SpeechTextFilter.clean(output);
  }
}
