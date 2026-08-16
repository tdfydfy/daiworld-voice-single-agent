// Single-Agent UI state model for HarmonyOS.
// Deliberately excludes Host product states (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

export type ConnectionState = 'offline' | 'connecting' | 'online';

export type CredentialState = 'unconfigured' | 'ready' | 'storage_error' | 'unauthorized';

// Agent IDs are opaque values supplied by the Adapter catalog.
export type ProfileKey = string;

export type AsrState = 'stopped' | 'connecting' | 'listening' | 'finalizing';

export type TtsState = 'stopped' | 'connecting' | 'ready' | 'speaking' | 'fallback' | 'error';

export type PlaybackState = 'none' | 'queued' | 'playing' | 'paused_for_user';

export type SpeechBackend = 'harmony_offline' | 'remote';

export type AudioOutputRoute = 'earpiece' | 'speaker' | 'headset';

export type MessageRole = 'user' | 'assistant' | 'system';

export type ActivityState = 'running' | 'completed' | 'error';

export type ActivityKind = 'thinking' | 'tool' | 'status' | 'error';

export class MessageActivity {
  id: string = '';
  kind: ActivityKind = 'status';
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
  replaying: boolean = false;
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
  credentialState: CredentialState = 'unconfigured';
  credentialError: string = '';
  selectedProfile: ProfileKey = 'default';
  agents: AgentInfo[] = [];
  agentsLoading: boolean = false;
  agentsError: string = '';
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
  modelProviders: ModelProviderInfo[] = [];
  modelOptionsLoading: boolean = false;
  modelOptionsError: string = '';
  modelSwitching: boolean = false;
  modelSwitchStatus: string = '';
  modelSwitchError: string = '';
  error: string = '';
  approvalDescription: string = '';
  approvalCommand: string = '';
  clarifyRequestId: string = '';
  clarifyQuestion: string = '';
  clarifyChoices: string[] = [];
}

export class AgentInfo {
  id: string = '';
  name: string = '';
  isDefault: boolean = false;
  avatarUrl: string = '';

  static fromObject(value: Object): AgentInfo | undefined {
    const row = value as Record<string, Object>;
    const id = row['id'];
    const name = row['name'];
    if (typeof id !== 'string' || id.length === 0 || typeof name !== 'string' || name.length === 0) {
      return undefined;
    }
    const info = new AgentInfo();
    info.id = id;
    info.name = name;
    info.isDefault = row['is_default'] === true;
    info.avatarUrl = typeof row['avatar_url'] === 'string' ? row['avatar_url'] : '';
    return info;
  }
}

export class AgentCatalog {
  agents: AgentInfo[] = [];

  find(id: string): AgentInfo | undefined {
    return this.agents.find((agent: AgentInfo): boolean => agent.id === id);
  }

  displayName(id: string): string {
    const agent = this.find(id);
    return agent !== undefined ? agent.name : (id.length > 0 ? id : 'Agent');
  }

  fallback(): AgentInfo | undefined {
    return this.agents.find((agent: AgentInfo): boolean => agent.isDefault) || this.agents[0];
  }
}

export class ModelOptionInfo {
  id: string = '';
  label: string = '';

  static fromValue(value: Object): ModelOptionInfo | undefined {
    const option = new ModelOptionInfo();
    if (typeof value === 'string') {
      option.id = value.trim();
      option.label = option.id;
      return option.id.length > 0 ? option : undefined;
    }
    if (value === null || typeof value !== 'object') {
      return undefined;
    }
    const row = value as Record<string, Object>;
    const rawId = row['id'] !== undefined ? row['id'] :
      row['model'] !== undefined ? row['model'] : row['name'];
    if (typeof rawId !== 'string' || rawId.trim().length === 0) {
      return undefined;
    }
    option.id = rawId.trim();
    const rawLabel = row['label'] !== undefined ? row['label'] : row['name'];
    option.label = typeof rawLabel === 'string' && rawLabel.trim().length > 0
      ? rawLabel.trim() : option.id;
    return option;
  }
}

export class ModelProviderInfo {
  id: string = '';
  name: string = '';
  models: ModelOptionInfo[] = [];

  static fromObject(value: Object): ModelProviderInfo | undefined {
    if (value === null || typeof value !== 'object') {
      return undefined;
    }
    const row = value as Record<string, Object>;
    const rawId = row['slug'] !== undefined ? row['slug'] :
      row['id'] !== undefined ? row['id'] : row['name'];
    if (typeof rawId !== 'string' || rawId.trim().length === 0) {
      return undefined;
    }
    const rawModels = Array.isArray(row['models']) ? row['models'] : row['model_ids'];
    if (!Array.isArray(rawModels)) {
      return undefined;
    }
    const provider = new ModelProviderInfo();
    provider.id = rawId.trim();
    const suppliedName = typeof row['name'] === 'string' ? String(row['name']).trim() : '';
    provider.name = ModelProviderInfo.isGenericName(suppliedName) &&
      !ModelProviderInfo.isGenericName(provider.id) ? provider.id : (suppliedName || provider.id);
    for (const rawModel of rawModels as Object[]) {
      const model = ModelOptionInfo.fromValue(rawModel);
      if (model !== undefined && provider.models.find(
        (item: ModelOptionInfo): boolean => item.id === model.id
      ) === undefined) {
        provider.models.push(model);
      }
    }
    return provider.models.length > 0 ? provider : undefined;
  }

  private static isGenericName(value: string): boolean {
    const normalized = value.trim().toLowerCase().replace(/[^a-z0-9]/g, '');
    return normalized === 'custom' || normalized === 'openaiapi' ||
      normalized === 'openaicompatible' || normalized === 'openaicompatibleapi';
  }
}
