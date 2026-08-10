// Hermes JSON-RPC wire protocol for the Single-Agent HarmonyOS client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md sections 3-5.

export interface JsonRpcRequest {
  jsonrpc: string;
  id: string;
  method: string;
  params: Object;
}

export interface JsonRpcError {
  code?: number;
  message: string;
  data?: Object;
}

export interface JsonRpcResponse {
  jsonrpc: string;
  id: string;
  result?: Object;
  error?: JsonRpcError;
}

export interface HermesEventEnvelope {
  jsonrpc: string;
  method: string;
  params: HermesEventParams;
}

export interface HermesEventParams {
  type: string;
  session_id?: string;
  payload?: Object;
}

export interface SessionInfo {
  model?: string;
  provider?: string;
  provider_label?: string;
  provider_name?: string;
  profile_name?: string;
}

export interface ToolStep {
  tool_id?: string;
  name?: string;
  args_text?: string;
  preview?: string;
  duration_s?: number;
  summary?: string;
  error?: string;
}

export interface ApprovalRequest {
  description?: string;
  command?: string;
}

export interface ClarifyRequest {
  request_id?: string;
  question?: string;
  choices?: string[];
}

export interface SessionSummary {
  id: string;
  title: string;
  model?: string;
  updated_at?: number;
  created_at?: number;
}

export class HermesEvents {
  static readonly GATEWAY_READY: string = 'gateway.ready';
  static readonly SESSION_INFO: string = 'session.info';
  static readonly MESSAGE_START: string = 'message.start';
  static readonly MESSAGE_DELTA: string = 'message.delta';
  static readonly MESSAGE_COMPLETE: string = 'message.complete';
  static readonly THINKING_DELTA: string = 'thinking.delta';
  static readonly REASONING_DELTA: string = 'reasoning.delta';
  static readonly TOOL_START: string = 'tool.start';
  static readonly TOOL_PROGRESS: string = 'tool.progress';
  static readonly TOOL_COMPLETE: string = 'tool.complete';
  static readonly APPROVAL_REQUEST: string = 'approval.request';
  static readonly CLARIFY_REQUEST: string = 'clarify.request';
  static readonly STATUS_UPDATE: string = 'status.update';
  static readonly ERROR: string = 'error';
}

export class HermesMethods {
  static readonly SESSION_CREATE: string = 'session.create';
  static readonly SESSION_LIST: string = 'session.list';
  static readonly SESSION_RESUME: string = 'session.resume';
  static readonly SESSION_DELETE: string = 'session.delete';
  static readonly PROMPT_SUBMIT: string = 'prompt.submit';
  static readonly SESSION_INTERRUPT: string = 'session.interrupt';
  static readonly APPROVAL_RESPOND: string = 'approval.respond';
  static readonly CLARIFY_RESPOND: string = 'clarify.respond';
}
