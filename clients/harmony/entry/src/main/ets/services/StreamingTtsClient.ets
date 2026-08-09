// Streaming TTS client for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 7.
// PCM: signed 16-bit little-endian, 24 kHz, mono, binary frames.

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TTS_SAMPLE_RATE_DEFAULT, VoiceCommands } from '../models/VoiceProtocol';

export interface TtsJobListener {
  onJobStarted(sampleRate: number): void;
  onJobPcm(pcm: ArrayBuffer): void;
  onJobEnded(): void;
  onJobFallback(): void;
  onError(message: string): void;
  onClosed(): void;
}

export class StreamingTtsClient {
  private socket: webSocket.WebSocket | undefined = undefined;
  private listener: TtsJobListener | undefined = undefined;
  private connected: boolean = false;
  private sampleRate: number = TTS_SAMPLE_RATE_DEFAULT;

  setListener(listener: TtsJobListener): void {
    this.listener = listener;
  }

  isConnected(): boolean {
    return this.connected;
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  connect(url: string, cookie: string): void {
    this.close();
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('open', (err: BusinessError, value: Object) => {
      if (!err) {
        this.connected = true;
      }
    });
    socket.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        return;
      }
      if (typeof data === 'string') {
        this.handleText(data);
      } else {
        this.handlePcm(data);
      }
    });
    socket.on('close', (err: BusinessError, value: Object) => {
      this.connected = false;
      if (this.listener) {
        this.listener.onClosed();
      }
    });
    socket.on('error', (err: BusinessError) => {
      this.connected = false;
      if (this.listener) {
        this.listener.onError(err.message);
      }
    });
    const options: webSocket.WebSocketRequestOptions = { header: {} };
    if (cookie.length > 0) {
      options.header['Cookie'] = cookie;
    }
    socket.connect(url, options).catch((error: BusinessError) => {
      if (this.listener) {
        this.listener.onError(error.message);
      }
    });
  }

  sendText(text: string): void {
    if (!this.socket || !this.connected) {
      return;
    }
    const frame: Record<string, Object> = {};
    frame['text'] = text;
    this.socket.send(JSON.stringify(frame)).catch(() => undefined);
  }

  sendDone(): void {
    if (!this.socket || !this.connected) {
      return;
    }
    const frame: Record<string, Object> = {};
    frame[VoiceCommands.TTS_DONE] = true;
    this.socket.send(JSON.stringify(frame)).catch(() => undefined);
  }

  sendStop(): void {
    if (!this.socket || !this.connected) {
      return;
    }
    const frame: Record<string, Object> = {};
    frame[VoiceCommands.TTS_STOP] = true;
    this.socket.send(JSON.stringify(frame)).catch(() => undefined);
  }

  close(): void {
    const socket = this.socket;
    if (socket) {
      socket.off('open');
      socket.off('message');
      socket.off('close');
      socket.off('error');
      socket.close().catch(() => undefined);
      this.socket = undefined;
    }
    this.connected = false;
  }

  private handleText(data: string): void {
    let parsed: Object;
    try {
      parsed = JSON.parse(data) as Object;
    } catch (error) {
      return;
    }
    const frame = parsed as Record<string, Object>;
    const type = frame['type'];
    if (type === 'start') {
      const rate = frame['sample_rate'];
      if (typeof rate === 'number' && rate > 0) {
        this.sampleRate = rate;
      }
      if (this.listener) {
        this.listener.onJobStarted(this.sampleRate);
      }
      return;
    }
    if (type === 'end') {
      if (this.listener) {
        this.listener.onJobEnded();
      }
      return;
    }
    if (type === 'fallback') {
      if (this.listener) {
        this.listener.onJobFallback();
      }
      return;
    }
    if (type === 'error') {
      const message = String(frame['message'] !== undefined ? frame['message'] : 'tts error');
      if (this.listener) {
        this.listener.onError(message);
      }
    }
  }

  private handlePcm(data: ArrayBuffer): void {
    if (this.listener) {
      // Forward raw PCM to the player queue; AudioRenderer consumes it.
      this.listener.onJobPcm !== undefined && this.listener.onJobPcm(data);
    }
  }
}
