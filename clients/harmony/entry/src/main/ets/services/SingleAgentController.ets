// Single-Agent controller state machine for HarmonyOS.
// Deliberately excludes Host orchestration (activeAgentKey, hostAck,
// pendingSupplementCount, agentStage, HOST intents).

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  ChatMessage,
  ConnectionState,
  HistorySession,
  MessageRole,
  PlaybackState,
  ProfileInfo,
  ProfileKey,
  SingleAgentSnapshot
} from '../models/SingleAgentState';
import { AuthSessionClient } from './AuthSessionClient';
import { HermesGatewayClient } from './HermesGatewayClient';
import { PcmCapture, PcmPlayer } from './PcmAudio';
import { StreamingAsrClient } from './StreamingAsrClient';
import { StreamingTtsClient } from './StreamingTtsClient';

const STOP_PHRASES: string[] = ['停止', 'stop'];

export interface SnapshotListener {
  (snapshot: SingleAgentSnapshot): void;
}

export interface ClientConfig {
  gatewayUrl: string;
  accessToken: string;
  profile: ProfileKey;
  muted: boolean;
}

export class SingleAgentController {
  private gateway: HermesGatewayClient = new HermesGatewayClient();
  private asr: StreamingAsrClient = new StreamingAsrClient();
  private tts: StreamingTtsClient = new StreamingTtsClient();
  private auth: AuthSessionClient = new AuthSessionClient();
  private capture: PcmCapture = new PcmCapture();
  private player: PcmPlayer = new PcmPlayer();
  private listener?: SnapshotListener;
  private snapshot: SingleAgentSnapshot = new SingleAgentSnapshot();
  private config: ClientConfig = { gatewayUrl: '', accessToken: '', profile: 'default', muted: false };
  private cookie: string = '';
  private voiceWanted: boolean = false;
  private capturing: boolean = false;
  private messageCounter: number = 0;

  setListener(listener: SnapshotListener): void {
    this.listener = listener;
    this.notify();
  }

  getSnapshot(): SingleAgentSnapshot {
    return this.snapshot;
  }

  setConfig(config: ClientConfig): void {
    this.config = config;
    this.snapshot.selectedProfile = config.profile;
    this.notify();
  }

  // Text input path. Also used after ASR final.
  submitText(text: string): void {
    const value = text.trim();
    if (value.length === 0) {
      return;
    }
    this.appendMessage('user', '你', value);
    if (this.isStopPhrase(value)) {
      this.interrupt();
      return;
    }
    if (this.snapshot.connection !== 'online' || this.snapshot.runtimeSessionId.length === 0) {
      this.snapshot.error = '尚未连接，请稍后再试';
      this.notify();
      return;
    }
    this.snapshot.agentBusy = true;
    this.notify();
    this.gateway.submitPrompt(value, false).then((result: Object) => {
      // Prompt accepted; agent events drive the UI from here.
    }).catch((error: BusinessError) => {
      this.snapshot.agentBusy = false;
      this.snapshot.error = error.message;
      this.notify();
    });
  }

  toggleVoice(): void {
    if (this.voiceWanted) {
      this.stopVoice();
      return;
    }
    this.voiceWanted = true;
    this.snapshot.voiceEnabled = true;
    this.ensureConnections();
  }

  toggleMute(): void {
    this.config.muted = !this.config.muted;
    if (this.config.muted) {
      this.player.stop().catch(() => undefined);
      this.snapshot.playback = 'none';
    }
    this.notify();
  }

  newConversation(): void {
    this.player.stop().catch(() => undefined);
    this.snapshot.messages = [];
    this.snapshot.storedSessionId = '';
    this.snapshot.runtimeSessionId = '';
    if (this.snapshot.connection === 'online') {
      this.gateway.createSession(100).then((result: Object) => {
        this.onSessionCreated(result);
      }).catch(() => undefined);
    }
    this.notify();
  }

  async connect(): Promise<void> {
    if (this.snapshot.connection === 'connecting' || this.snapshot.connection === 'online') {
      return;
    }
    this.snapshot.connection = 'connecting';
    this.snapshot.statusTitle = '正在连接';
    this.notify();
    try {
      const cookie = await this.auth.acquireSessionCookie(this.config.gatewayUrl, this.config.accessToken);
      if (cookie.length === 0) {
        this.snapshot.connection = 'offline';
        this.snapshot.error = '鉴权失败，请检查网关地址和访问口令';
        this.notify();
        return;
      }
      this.cookie = cookie;
      this.openGateway();
    } catch (error) {
      this.snapshot.connection = 'offline';
      this.snapshot.error = '连接失败';
      this.notify();
    }
  }

  disconnect(): void {
    this.stopVoice();
    this.gateway.close();
    this.snapshot.connection = 'offline';
    this.snapshot.runtimeSessionId = '';
    this.notify();
  }

  // Exact-stop phrase: only these interrupt the current agent turn.
  private isStopPhrase(text: string): boolean {
    const normalized = text.trim().toLowerCase();
    for (const phrase of STOP_PHRASES) {
      if (normalized === phrase) {
        return true;
      }
    }
    return false;
  }

  private interrupt(): void {
    this.gateway.interrupt().then(() => {
      this.snapshot.agentBusy = false;
      this.snapshot.playback = 'none';
      this.player.stop().catch(() => undefined);
      this.notify();
    }).catch(() => undefined);
  }

  private ensureConnections(): void {
    if (this.snapshot.connection === 'online') {
      this.startCapture();
      return;
    }
    this.connect();
  }

  private startCapture(): void {
    if (this.capturing) {
      return;
    }
    this.capture.start((chunk: ArrayBuffer) => {
      this.asr.sendPcm(chunk);
    }).then(() => {
      this.capturing = true;
      this.snapshot.asrState = 'listening';
      this.notify();
    }).catch(() => undefined);
  }

  private stopVoice(): void {
    this.voiceWanted = false;
    this.snapshot.voiceEnabled = false;
    this.snapshot.asrState = 'stopped';
    this.asr.stop();
    this.capture.stop().then(() => {
      this.capturing = false;
      this.notify();
    }).catch(() => undefined);
  }

  private openGateway(): void {
    const url = this.wsUrl('/api/hermes/ws', this.snapshot.selectedProfile);
    this.gateway.setListener({
      onGatewayReady: (): void => {
        this.snapshot.connection = 'online';
        this.gateway.createSession(100).then((result: Object) => {
          this.onSessionCreated(result);
        }).catch(() => undefined);
      },
      onEvent: (type: string, sessionId: string, payload: Object | undefined): void => {
        this.handleEvent(type, sessionId, payload);
      },
      onError: (message: string): void => {
        this.snapshot.error = message;
        this.notify();
      },
      onClosed: (): void => {
        this.snapshot.connection = 'offline';
        this.notify();
      }
    });
    this.gateway.connect(url, this.cookie);
  }

  private onSessionCreated(result: Object): void {
    const record = result as Record<string, Object>;
    const runtime = record['session_id'];
    const stored = record['stored_session_id'];
    if (typeof runtime === 'string' && runtime.length > 0) {
      this.snapshot.runtimeSessionId = runtime;
    }
    if (typeof stored === 'string' && stored.length > 0) {
      this.snapshot.storedSessionId = stored;
    }
    this.snapshot.statusTitle = '已连接';
    this.snapshot.statusDetail = this.snapshot.selectedProfile;
    this.notify();
    if (this.voiceWanted && !this.capturing) {
      this.startVoiceClients();
    }
  }

  private startVoiceClients(): void {
    this.asr.setListener({
      onReady: (): void => {
        this.snapshot.asrState = 'listening';
        this.notify();
      },
      onTranscript: (text: string, interim: boolean, final: boolean): void => {
        if (final) {
          this.onAsrFinal(text);
        }
      },
      onError: (message: string): void => {
        this.snapshot.asrState = 'stopped';
        this.snapshot.error = message;
        this.notify();
      },
      onClosed: (): void => {
        this.snapshot.asrState = 'stopped';
        this.notify();
      }
    });
    this.asr.connect(this.wsUrl('/api/audio/transcribe-stream', this.snapshot.selectedProfile), this.cookie);
    this.tts.setListener({
      onJobStarted: (sampleRate: number): void => {
        this.player.setSampleRate(sampleRate);
        this.snapshot.playback = 'playing';
        this.notify();
      },
      onJobPcm: (pcm: ArrayBuffer): void => {
        this.player.enqueue(pcm);
      },
      onJobEnded: (): void => {
        this.snapshot.playback = 'none';
        this.notify();
      },
      onJobFallback: (): void => {
        this.snapshot.statusDetail = 'TTS已降级';
        this.notify();
      },
      onError: (message: string): void => {
        this.snapshot.error = message;
        this.notify();
      },
      onClosed: (): void => undefined
    });
    this.tts.connect(this.wsUrl('/api/audio/speak-stream', this.snapshot.selectedProfile), this.cookie);
  }

  private onAsrFinal(text: string): void {
    const value = text.trim();
    if (value.length === 0) {
      return;
    }
    this.submitText(value);
  }

  private handleEvent(type: string, sessionId: string, payload: Object | undefined): void {
    if (sessionId.length > 0 && sessionId !== this.snapshot.runtimeSessionId) {
      // Late event from an older session: drop it.
      return;
    }
    const data = payload as Record<string, Object> | undefined;
    if (type === 'message.start') {
      this.beginAssistantMessage();
      return;
    }
    if (type === 'message.delta') {
      const text = data !== undefined && data['text'] !== undefined ? String(data['text']) : '';
      this.appendAssistantDelta(text);
      return;
    }
    if (type === 'message.complete') {
      this.finishAssistantMessage();
      return;
    }
    if (type === 'status.update') {
      const text = data !== undefined && data['text'] !== undefined ? String(data['text']) : '';
      this.snapshot.statusDetail = text;
      this.notify();
      return;
    }
    if (type === 'error') {
      const message = data !== undefined && data['message'] !== undefined ? String(data['message']) : 'Agent错误';
      this.snapshot.agentBusy = false;
      this.snapshot.error = message;
      this.notify();
    }
  }

  private beginAssistantMessage(): void {
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = 'assistant';
    message.label = ProfileInfo.displayName(this.snapshot.selectedProfile);
    message.text = '';
    message.pending = true;
    this.snapshot.messages.push(message);
    this.snapshot.agentBusy = true;
    this.notify();
  }

  private appendAssistantDelta(text: string): void {
    const messages = this.snapshot.messages;
    if (messages.length === 0) {
      return;
    }
    const last = messages[messages.length - 1];
    if (last.role === 'assistant' && last.pending) {
      last.text += text;
      this.notify();
    }
  }

  private finishAssistantMessage(): void {
    const messages = this.snapshot.messages;
    if (messages.length > 0) {
      const last = messages[messages.length - 1];
      if (last.role === 'assistant' && last.pending) {
        last.pending = false;
      }
    }
    this.snapshot.agentBusy = false;
    this.notify();
  }

  private appendMessage(role: MessageRole, label: string, text: string): void {
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = role;
    message.label = label;
    message.text = text;
    message.timestamp = Date.now();
    this.snapshot.messages.push(message);
    this.notify();
  }

  private nextMessageId(): string {
    this.messageCounter += 1;
    return util.generateRandomUUID(true) + '-' + String(this.messageCounter);
  }

  private wsUrl(path: string, profile: ProfileKey): string {
    const base = this.config.gatewayUrl;
    const trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    const scheme = trimmed.startsWith('https:') ? 'wss:' : 'ws:';
    const rest = trimmed.startsWith('http') ? trimmed.substring(trimmed.indexOf('//')) : trimmed;
    return scheme + rest + path + '?profile=' + profile;
  }

  private notify(): void {
    if (this.listener) {
      this.listener(this.snapshot);
    }
  }
}
