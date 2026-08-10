// Streaming ASR client for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 6.
// PCM: signed 16-bit little-endian, 16 kHz, mono, 6400-byte chunks.

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ASR_CHUNK_BYTES, AsrFrame, VoiceCommands } from '../models/VoiceProtocol';

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
  private ready: boolean = false;
  private preReadyBuffer: ArrayBuffer[] = [];

  setListener(listener: AsrListener): void {
    this.listener = listener;
  }

  isConnected(): boolean {
    return this.connected;
  }

  isReady(): boolean {
    return this.ready;
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
      }
    });
    socket.on('close', (err: BusinessError, value: Object) => {
      this.connected = false;
      this.ready = false;
      this.preReadyBuffer = [];
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

  // PCM is accepted before 'ready' and flushed once the upstream is ready.
  sendPcm(chunk: ArrayBuffer): void {
    if (!this.socket || !this.connected) {
      return;
    }
    if (!this.ready) {
      if (this.preReadyBuffer.length * ASR_CHUNK_BYTES < 4 * ASR_CHUNK_BYTES) {
        this.preReadyBuffer.push(chunk.slice(0));
      }
      return;
    }
    this.flushPreReady();
    this.socket.send(chunk).catch((error: BusinessError) => {
      if (this.listener) {
        this.listener.onError(error.message);
      }
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
    this.ready = false;
    this.preReadyBuffer = [];
  }

  private flushPreReady(): void {
    if (this.preReadyBuffer.length === 0 || !this.socket || !this.connected) {
      return;
    }
    const frames = this.preReadyBuffer;
    this.preReadyBuffer = [];
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
    const frame = parsed as AsrFrame;
    if (frame.type === 'ready') {
      this.ready = true;
      this.flushPreReady();
      if (this.listener) {
        this.listener.onReady();
      }
      return;
    }
    if (frame.type === 'transcript') {
      if (this.listener) {
        this.listener.onTranscript(frame.text, frame.interim, frame.final);
      }
      return;
    }
    if (frame.type === 'error') {
      if (this.listener) {
        this.listener.onError(frame.message);
      }
    }
  }
}
