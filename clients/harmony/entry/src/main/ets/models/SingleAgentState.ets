// Single-Agent UI state model for HarmonyOS.
// Deliberately excludes Host product states (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

export type ConnectionState = 'offline' | 'connecting' | 'online';

export type ProfileKey = 'default' | 'hexiaoma' | 'hexiaoxin';

export type AsrState = 'stopped' | 'connecting' | 'listening' | 'finalizing';

export type TtsState = 'stopped' | 'connecting' | 'ready' | 'speaking' | 'fallback' | 'error';

export type PlaybackState = 'none' | 'queued' | 'playing' | 'paused_for_user';

export type SpeechBackend = 'harmony_offline' | 'remote';

export type AudioOutputRoute = 'earpiece' | 'speaker' | 'headset';

export type MessageRole = 'user' | 'assistant' | 'system';

export type ActivityState = 'running' | 'completed' | 'error';

export class MessageActivity {
  id: string = '';
  title: string = '';
  detail: string = '';
  state: ActivityState = 'running';
  duration_s?: number;
}

export class MessageArtifact {
  token: string = '';
  name: string = '附件';
  mimeType: string = 'application/octet-stream';
  size: number = 0;
  isImage: boolean = false;
}

export class ChatMessage {
  id: string = '';
  revision: number = 0;
  role: MessageRole = 'assistant';
  label: string = '';
  text: string = '';
  model: string = '';
  provider: string = '';
  status: string = '';
  transient: boolean = false;
  thinking: string = '';
  activities: MessageActivity[] = [];
  artifacts: MessageArtifact[] = [];
  thinking_s?: number;
  generation_s?: number;
  duration_s?: number;
  timestamp: number = 0;
  firstTokenAt: number = 0;
  completedAt: number = 0;
  pending: boolean = false;
  processExpanded: boolean = false;
}

export class HistorySession {
  id: string = '';
  title: string = '';
  preview: string = '';
  source: string = 'Hermes';
  model?: string;
  started_at?: number;
  updated_at?: number;
  message_count: number = 0;
}

export class ApprovalView {
  description: string = '';
  command: string = '';
}

export class ClarifyView {
  requestId: string = '';
  question: string = '';
  choices: string[] = [];
}

export class SingleAgentSnapshot {
  connection: ConnectionState = 'offline';
  selectedProfile: ProfileKey = 'default';
  runtimeSessionId: string = '';
  storedSessionId: string = '';
  voiceEnabled: boolean = false;
  asrState: AsrState = 'stopped';
  asrTranscript: string = '';
  asrUtteranceActive: boolean = false;
  microphoneRoute: string = '';
  speakerphoneEnabled: boolean = false;
  audioOutputRoute: AudioOutputRoute = 'earpiece';
  headsetOutputAvailable: boolean = false;
  ttsState: TtsState = 'stopped';
  ttsSampleRate: number = 24000;
  asrBackend: SpeechBackend = 'harmony_offline';
  ttsBackend: SpeechBackend = 'harmony_offline';
  agentBusy: boolean = false;
  approvalPending: boolean = false;
  clarifyPending: boolean = false;
  playback: PlaybackState = 'none';
  messages: ChatMessage[] = [];
  history: HistorySession[] = [];
  historyLimit: number = 20;
  historyLoading: boolean = false;
  historyHasMore: boolean = true;
  conversationLoading: boolean = false;
  debugMode: boolean = false;
  statusTitle: string = '';
  statusDetail: string = '';
  runtimeModel: string = '';
  runtimeProvider: string = '';
  error: string = '';
  approvalDescription: string = '';
  approvalCommand: string = '';
  clarifyRequestId: string = '';
  clarifyQuestion: string = '';
  clarifyChoices: string[] = [];
}

export class ProfileInfo {
  static readonly PROFILES: ProfileKey[] = ['default', 'hexiaoma', 'hexiaoxin'];

  static displayName(key: ProfileKey): string {
    if (key === 'default') {
      return '赫准行';
    }
    if (key === 'hexiaoma') {
      return '赫小码';
    }
    return '赫小新';
  }
}
