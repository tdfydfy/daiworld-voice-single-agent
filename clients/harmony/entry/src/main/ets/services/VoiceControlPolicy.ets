export type VoiceControlAction =
  'none' | 'stop_task' | 'close_microphone' | 'open_microphone' | 'exit_application';

const STOP_PHRASES: string[] = ['停止任务', '停止', 'stop'];
const CLOSE_MIC_PHRASES: string[] = ['关闭话筒', '关闭麦克风', '关闭microphone', '暂停收音'];
const OPEN_MIC_PHRASES: string[] = ['打开话筒', '打开麦克风', '打开microphone', '恢复收音'];
const EXIT_PHRASES: string[] = ['退出软件'];

export class VoiceControlPolicy {
  static resolve(text: string): VoiceControlAction {
    const normalized = VoiceControlPolicy.normalize(text);
    if (VoiceControlPolicy.matches(EXIT_PHRASES, normalized)) {
      return 'exit_application';
    }
    if (VoiceControlPolicy.matches(STOP_PHRASES, normalized)) {
      return 'stop_task';
    }
    if (VoiceControlPolicy.matches(CLOSE_MIC_PHRASES, normalized)) {
      return 'close_microphone';
    }
    if (VoiceControlPolicy.matches(OPEN_MIC_PHRASES, normalized)) {
      return 'open_microphone';
    }
    return 'none';
  }

  private static matches(phrases: string[], normalized: string): boolean {
    for (const phrase of phrases) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  private static normalize(text: string): string {
    return text.trim().toLowerCase().replace(/[\s\p{P}\p{S}]/gu, '');
  }
}
