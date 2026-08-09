// Single-Agent UI state model for HarmonyOS.
// Deliberately excludes Host product states (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

export type ConnectionState = 'offline' | 'connecting' | 'online';

export type ProfileKey = 'default' | 'hexiaoma' | 'hexiaoxin';

export type AsrState = 'stopped' | 'connecting' | 'listening' | 'finalizing';

export type PlaybackState = 'none' | 'queued' | 'playing' | 'paused_for_user';

export type MessageRole = 'user' | 'assistant' | 'system';

export class ChatMessage {
  id: string = '';
  role: MessageRole = 'assistant';
  label: string = '';
  text: string = '';
  tools: string[] = [];
  duration_s?: number;
  timestamp: number = 0;
  pending: boolean = false;
}

export class HistorySession {
  id: string = '';
  title: string = '';
  model?: string;
  updated_at?: number;
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
  agentBusy: boolean = false;
  approvalPending: boolean = false;
  clarifyPending: boolean = false;
  playback: PlaybackState = 'none';
  messages: ChatMessage[] = [];
  history: HistorySession[] = [];
  historyLimit: number = 20;
  statusTitle: string = '';
  statusDetail: string = '';
  error: string = '';
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
