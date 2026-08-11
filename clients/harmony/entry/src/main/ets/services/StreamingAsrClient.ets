// Streaming ASR client for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 6.
// PCM: signed 16-bit little-endian, 16 kHz, mono, 6400-byte chunks.

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ASR_CHUNK_BYTES, AsrFrame, VoiceCommands } from '../models/VoiceProtocol';

const ASR_CONNECT_TIMEOUT_MS = 10000;

export abstract class AsrListener {
  abstract onReady(): void;
  abstract onTranscript(text: string, interim: boolean, final: boolean): void;
  abstract onError(message: string): void;
  abstract onClosed(): void;
}

export class StreamingAsrClient {
  private socket: webSocket.WebSocket | undefined = undefined;
  private listener: AsrListener | undefined = undefined;
  private connected: boolean = false;
  private connecting: boolean = false;
  private ready: boolean = false;
  private preReadyBuffer: ArrayBuffer[] = [];
  private connectionGeneration: number = 0;
  private connectTimeout?: number;

  setListener(listener: AsrListener): void {
    this.listener = listener;
  }

  isConnected(): boolean {
    return this.connected;
  }

  isConnecting(): boolean {
    return this.connecting;
  }

  isReady(): boolean {
    return this.ready;
  }

  connect(url: string, cookie: string): void {
    this.open(url, cookie, false);
  }

  reconnect(url: string, cookie: string): void {
    this.open(url, cookie, true);
  }

  private open(url: string, cookie: string, preserveBufferedAudio: boolean): void {
    this.connectionGeneration += 1;
    const generation = this.connectionGeneration;
    this.detachSocket(!preserveBufferedAudio);
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    this.connecting = true;
    this.startConnectTimeout(socket, generation);
    socket.on('open', (err: BusinessError, value: Object) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      if (!err) {
        this.connected = true;
        this.connecting = false;
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
      }
    });
    socket.on('close', (err: BusinessError, value: Object) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.socket = undefined;
      this.connected = false;
      this.connecting = false;
      this.ready = false;
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

  // PCM is accepted before 'ready' and flushed once the upstream is ready.
  sendPcm(chunk: ArrayBuffer): void {
    if (!this.socket || !this.connected || !this.ready) {
      this.bufferPreReady(chunk);
      return;
    }
    this.flushPreReady();
    const socket = this.socket;
    const generation = this.connectionGeneration;
    socket.send(chunk).catch((error: BusinessError) => {
      if (generation !== this.connectionGeneration || this.socket !== socket) {
        return;
      }
      this.connected = false;
      this.ready = false;
      this.bufferPreReady(chunk);
      this.failConnection(socket, generation, error.message);
    });
  }

  stop(): void {
    if (!this.socket || !this.connected) {
      return;
    }
    this.flushPreReady();
    const stopFrame: Record<string, Object> = {};
    stopFrame[VoiceCommands.ASR_STOP] = true;
    this.socket.send(JSON.stringify(stopFrame)).catch(() => undefined);
  }

  close(): void {
    this.connectionGeneration += 1;
    this.detachSocket(true);
  }

  private detachSocket(clearBufferedAudio: boolean): void {
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
    this.ready = false;
    if (clearBufferedAudio) {
      this.preReadyBuffer = [];
    }
  }

  private bufferPreReady(chunk: ArrayBuffer): void {
    while (this.preReadyBuffer.length >= 4) {
      this.preReadyBuffer.shift();
    }
    this.preReadyBuffer.push(chunk.slice(0));
  }

  private startConnectTimeout(socket: webSocket.WebSocket, generation: number): void {
    this.clearConnectTimeout();
    this.connectTimeout = setTimeout((): void => {
      this.connectTimeout = undefined;
      this.failConnection(socket, generation, 'ASR 连接超时');
    }, ASR_CONNECT_TIMEOUT_MS);
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
      this.listener.onError(message.length > 0 ? message : 'ASR 连接失败');
    }
  }

  private flushPreReady(): void {
    if (this.preReadyBuffer.length === 0 || !this.socket || !this.connected) {
      return;
    }
    const frames = this.preReadyBuffer;
    this.preReadyBuffer = [];
    const socket = this.socket;
    const generation = this.connectionGeneration;
    for (const frame of frames) {
      socket.send(frame).catch((error: BusinessError) => {
        if (generation !== this.connectionGeneration || this.socket !== socket) {
          return;
        }
        this.connected = false;
        this.ready = false;
        this.bufferPreReady(frame);
        this.failConnection(socket, generation, error.message);
      });
    }
  }

  private handleText(data: string): void {
    let parsed: Object;
    try {
      parsed = JSON.parse(data) as Object;
    } catch (error) {
      return;
    }
    const frame = parsed as AsrFrame;
    if (frame.type === 'ready') {
      this.clearConnectTimeout();
      this.ready = true;
      this.flushPreReady();
      if (this.listener) {
        this.listener.onReady();
      }
      return;
    }
    if (frame.type === 'transcript') {
      if (!this.ready) {
        return;
      }
      if (this.listener) {
        this.listener.onTranscript(frame.text, frame.interim, frame.final);
      }
      return;
    }
    if (frame.type === 'error') {
      const socket = this.socket;
      if (socket) {
        this.failConnection(socket, this.connectionGeneration, frame.message);
      }
    }
  }
}
