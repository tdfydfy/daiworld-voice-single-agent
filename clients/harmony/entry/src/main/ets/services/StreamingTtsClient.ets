// Streaming TTS client for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 7.
// PCM: signed 16-bit little-endian, 24 kHz, mono, binary frames.

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TTS_SAMPLE_RATE_DEFAULT, VoiceCommands } from '../models/VoiceProtocol';

export abstract class TtsJobListener {
  abstract onReady(): void;
  abstract onJobStarted(sampleRate: number): void;
  abstract onJobPcm(pcm: ArrayBuffer): void;
  abstract onJobEnded(): void;
  abstract onJobFallback(): void;
  abstract onError(message: string): void;
  abstract onClosed(): void;
}

export class StreamingTtsClient {
  private socket: webSocket.WebSocket | undefined = undefined;
  private listener: TtsJobListener | undefined = undefined;
  private connected: boolean = false;
  private sampleRate: number = TTS_SAMPLE_RATE_DEFAULT;
  private pendingFrames: string[] = [];

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
        this.flushPendingFrames();
        if (this.listener) {
          this.listener.onReady();
        }
      } else if (this.listener) {
        this.listener.onError(err.message);
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
    const headers: Record<string, string> = {};
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
    }
    const options: webSocket.WebSocketRequestOptions = { header: headers };
    socket.connect(url, options).catch((error: BusinessError) => {
      if (this.listener) {
        this.listener.onError(error.message);
      }
    });
  }

  sendText(text: string): void {
    const frame: Record<string, Object> = {};
    frame['text'] = text;
    this.sendFrame(JSON.stringify(frame));
  }

  sendDone(): void {
    const frame: Record<string, Object> = {};
    frame[VoiceCommands.TTS_DONE] = true;
    this.sendFrame(JSON.stringify(frame));
  }

  sendStop(): void {
    this.pendingFrames = [];
    const frame: Record<string, Object> = {};
    frame[VoiceCommands.TTS_STOP] = true;
    this.sendFrame(JSON.stringify(frame));
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
    this.pendingFrames = [];
  }

  private sendFrame(frame: string): void {
    if (!this.socket || !this.connected) {
      this.pendingFrames.push(frame);
      return;
    }
    this.socket.send(frame).catch(() => undefined);
  }

  private flushPendingFrames(): void {
    if (!this.socket || !this.connected || this.pendingFrames.length === 0) {
      return;
    }
    const frames = this.pendingFrames;
    this.pendingFrames = [];
    for (const frame of frames) {
      this.socket.send(frame).catch(() => undefined);
    }
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
