// Hermes JSON-RPC gateway client for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md sections 3-5.
// Official API: webSocket.connect(url, { header }) — verified in
// @ohos.net.webSocket docs (connect(url, options?: WebSocketRequestOptions)).

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HermesEventEnvelope,
  HermesEventParams,
  HermesEvents,
  HermesMethods,
  JsonRpcError,
  JsonRpcRequest,
  JsonRpcResponse
} from '../models/HermesProtocol';

export interface GatewayListener {
  onGatewayReady(): void;
  onEvent(type: string, sessionId: string, payload: Object | undefined): void;
  onError(message: string): void;
  onClosed(): void;
}

interface PendingRequest {
  resolve: (result: Object) => void;
  reject: (error: JsonRpcError) => void;
}

export class HermesGatewayClient {
  private socket: webSocket.WebSocket | undefined = undefined;
  private listener: GatewayListener | undefined = undefined;
  private pending: Map<string, PendingRequest> = new Map<string, PendingRequest>();
  private requestCounter: number = 0;
  private connected: boolean = false;
  private currentSessionId: string = '';

  setListener(listener: GatewayListener): void {
    this.listener = listener;
  }

  isConnected(): boolean {
    return this.connected;
  }

  getRuntimeSessionId(): string {
    return this.currentSessionId;
  }

  connect(url: string, cookie: string): void {
    this.close();
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('open', (err: BusinessError, value: Object) => {
      if (err) {
        this.connected = false;
        return;
      }
      this.connected = true;
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
      this.rejectAll('connection closed');
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
      this.connected = false;
      if (this.listener) {
        this.listener.onError(error.message);
      }
    });
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
    this.rejectAll('client closed');
  }

  createSession(cols: number): Promise<Object> {
    return this.request(HermesMethods.SESSION_CREATE, { cols: cols });
  }

  listSessions(limit: number): Promise<Object> {
    return this.request(HermesMethods.SESSION_LIST, { limit: limit });
  }

  resumeSession(storedId: string, cols: number): Promise<Object> {
    return this.request(HermesMethods.SESSION_RESUME, {
      session_id: storedId,
      cols: cols
    });
  }

  deleteSession(storedId: string): Promise<Object> {
    return this.request(HermesMethods.SESSION_DELETE, { session_id: storedId });
  }

  submitPrompt(text: string, queued: boolean): Promise<Object> {
    return this.request(HermesMethods.PROMPT_SUBMIT, {
      session_id: this.currentSessionId,
      text: text,
      queued: queued
    });
  }

  interrupt(): Promise<Object> {
    return this.request(HermesMethods.SESSION_INTERRUPT, {
      session_id: this.currentSessionId
    });
  }

  respondApproval(choice: string): Promise<Object> {
    return this.request(HermesMethods.APPROVAL_RESPOND, {
      session_id: this.currentSessionId,
      choice: choice
    });
  }

  respondClarify(requestId: string, answer: string): Promise<Object> {
    return this.request(HermesMethods.CLARIFY_RESPOND, {
      session_id: this.currentSessionId,
      request_id: requestId,
      answer: answer
    });
  }

  private request(method: string, params: Record<string, Object>): Promise<Object> {
    return new Promise<Object>((resolve, reject) => {
      if (!this.connected || !this.socket) {
        reject({ message: 'gateway not connected' } as JsonRpcError);
        return;
      }
      const id = String(++this.requestCounter);
      const request: JsonRpcRequest = {
        jsonrpc: '2.0',
        id: id,
        method: method,
        params: params
      };
      this.pending.set(id, { resolve: resolve, reject: reject });
      this.socket.send(JSON.stringify(request)).catch((error: BusinessError) => {
        this.pending.delete(id);
        reject({ message: error.message } as JsonRpcError);
      });
    });
  }

  private handleText(data: string): void {
    let parsed: Object;
    try {
      parsed = JSON.parse(data) as Object;
    } catch (error) {
      return;
    }
    const envelope = parsed as HermesEventEnvelope;
    if (envelope.jsonrpc === '2.0' && envelope.id !== undefined) {
      this.handleResponse(envelope as unknown as JsonRpcResponse);
      return;
    }
    if (envelope.method === 'event' && envelope.params) {
      this.handleEvent(envelope.params);
    }
  }

  private handleResponse(response: JsonRpcResponse): void {
    const id = String(response.id);
    const pending = this.pending.get(id);
    if (!pending) {
      return;
    }
    this.pending.delete(id);
    if (response.error) {
      pending.reject(response.error);
    } else if (response.result !== undefined) {
      const result = response.result as Record<string, Object>;
      const sessionId = result['session_id'];
      if (typeof sessionId === 'string' && sessionId.length > 0) {
        this.currentSessionId = sessionId;
      }
      pending.resolve(response.result);
    } else {
      pending.reject({ message: 'empty response' } as JsonRpcError);
    }
  }

  private handleEvent(params: HermesEventParams): void {
    const sessionId = params.session_id !== undefined ? params.session_id : '';
    const type = params.type;
    if (type === HermesEvents.GATEWAY_READY) {
      if (this.listener) {
        this.listener.onGatewayReady();
      }
      return;
    }
    if (this.listener) {
      this.listener.onEvent(type, sessionId, params.payload);
    }
  }

  private rejectAll(message: string): void {
    const entries = Array.from(this.pending.entries());
    this.pending.clear();
    for (const entry of entries) {
      entry[1].reject({ message: message } as JsonRpcError);
    }
  }
}
