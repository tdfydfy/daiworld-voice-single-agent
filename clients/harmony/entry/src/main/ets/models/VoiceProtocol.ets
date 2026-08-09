// Voice streaming protocol (ASR/TTS) for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md sections 6-7.

export const ASR_SAMPLE_RATE: number = 16000;
export const ASR_CHUNK_BYTES: number = 6400;

export const TTS_SAMPLE_RATE_DEFAULT: number = 24000;

export class AsrFrame {
  type: string = 'transcript';
  text: string = '';
  interim: boolean = false;
  final: boolean = false;
}

export class TtsLifecycleFrame {
  type: string = '';
  sample_rate?: number;
  message?: string;
}

export class VoiceCommands {
  static readonly ASR_STOP: string = 'stop';
  static readonly TTS_DONE: string = 'done';
  static readonly TTS_STOP: string = 'stop';
}
