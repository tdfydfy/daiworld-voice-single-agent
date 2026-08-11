// Streaming TTS client for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 7.
// PCM: signed 16-bit little-endian, 24 kHz, mono, binary frames.

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TTS_SAMPLE_RATE_DEFAULT, VoiceCommands } from '../models/VoiceProtocol';

const TTS_CONNECT_TIMEOUT_MS = 10000;

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
  private connecting: boolean = false;
  private sampleRate: number = TTS_SAMPLE_RATE_DEFAULT;
  private pendingFrames: string[] = [];
  private connectionGeneration: number = 0;
  private pendingFramesGeneration: number = 0;
  private pendingFlushActive: boolean = false;
  private connectTimeout?: number;

  setListener(listener: TtsJobListener): void {
    this.listener = listener;
  }

  isConnected(): boolean {
    return this.connected;
  }

  isConnecting(): boolean {
    return this.connecting;
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  connect(url: string, cookie: string): void {
    this.open(url, cookie, false);
  }

  reconnect(url: string, cookie: string): void {
    this.open(url, cookie, true);
  }

  private open(url: string, cookie: string, preservePendingFrames: boolean): void {
    this.connectionGeneration += 1;
    const generation = this.connectionGeneration;
    this.detachSocket(!preservePendingFrames);
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    this.connecting = true;
    this.startConnectTimeout(socket, generation);
    socket.on('open', (err: BusinessError, value: Object) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.clearConnectTimeout();
      if (!err) {
        this.connected = true;
        this.connecting = false;
        this.flushPendingFrames();
        if (this.listener) {
          this.listener.onReady();
        }
      } else {
        this.failConnection(socket, generation, err.message);
      }
    });
    socket.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (generation !== this.connectionGeneration || this.socket !== socket || err) {
        return;
      }
      if (typeof data === 'string') {
        this.handleText(data);
      } else {
        this.handlePcm(data);
      }
    });
    socket.on('close', (err: BusinessError, value: Object) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.socket = undefined;
      this.connected = false;
      this.connecting = false;
      this.pendingFlushActive = false;
      this.clearConnectTimeout();
      if (this.listener) {
        this.listener.onClosed();
      }
    });
    socket.on('error', (err: BusinessError) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.failConnection(socket, generation, err.message);
    });
    const headers: Record<string, string> = {};
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
    }
    const options: webSocket.WebSocketRequestOptions = { header: headers };
    socket.connect(url, options).catch((error: BusinessError) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.failConnection(socket, generation, error.message);
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
    this.pendingFramesGeneration += 1;
    if (!this.socket || !this.connected) {
      return;
    }
    const frame: Record<string, Object> = {};
    frame[VoiceCommands.TTS_STOP] = true;
    const socket = this.socket;
    const generation = this.connectionGeneration;
    socket.send(JSON.stringify(frame)).catch((error: BusinessError) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.failConnection(socket, generation, error.message);
    });
  }

  close(): void {
    this.connectionGeneration += 1;
    this.detachSocket(true);
  }

  private detachSocket(clearPendingFrames: boolean): void {
    this.clearConnectTimeout();
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
    this.connecting = false;
    this.pendingFlushActive = false;
    if (clearPendingFrames) {
      this.pendingFrames = [];
      this.pendingFramesGeneration += 1;
    }
  }

  private sendFrame(frame: string): void {
    this.pendingFrames.push(frame);
    this.flushPendingFrames();
  }

  private flushPendingFrames(): void {
    if (!this.socket || !this.connected || this.pendingFrames.length === 0 || this.pendingFlushActive) {
      return;
    }
    const socket = this.socket;
    const generation = this.connectionGeneration;
    this.pendingFlushActive = true;
    this.sendNextPendingFrame(socket, generation);
  }

  private sendNextPendingFrame(socket: webSocket.WebSocket, generation: number): void {
    if (generation !== this.connectionGeneration || this.socket !== socket || !this.connected) {
      return;
    }
    if (this.pendingFrames.length === 0) {
      this.pendingFlushActive = false;
      return;
    }
    const frame = this.pendingFrames[0];
    const framesGeneration = this.pendingFramesGeneration;
    socket.send(frame).then((): void => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      if (framesGeneration === this.pendingFramesGeneration && this.pendingFrames[0] === frame) {
        this.pendingFrames.shift();
      }
      this.sendNextPendingFrame(socket, generation);
    }).catch((error: BusinessError): void => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.failConnection(socket, generation, error.message);
    });
  }

  private startConnectTimeout(socket: webSocket.WebSocket, generation: number): void {
    this.clearConnectTimeout();
    this.connectTimeout = setTimeout((): void => {
      this.connectTimeout = undefined;
      this.failConnection(socket, generation, 'TTS 连接超时');
    }, TTS_CONNECT_TIMEOUT_MS);
  }

  private clearConnectTimeout(): void {
    if (this.connectTimeout !== undefined) {
      clearTimeout(this.connectTimeout);
      this.connectTimeout = undefined;
    }
  }

  private failConnection(socket: webSocket.WebSocket, generation: number, message: string): void {
    if (generation !== this.connectionGeneration || this.socket !== socket) {
      return;
    }
    this.detachSocket(false);
    if (this.listener) {
      this.listener.onError(message.length > 0 ? message : 'TTS 连接失败');
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
      const socket = this.socket;
      if (socket) {
        this.failConnection(socket, this.connectionGeneration, message);
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
