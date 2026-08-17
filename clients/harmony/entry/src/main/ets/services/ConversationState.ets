import { util } from '@kit.ArkTS';
import {
  ChatMessage,
  HistorySession,
  MessageArtifact,
  MessageActivity,
  MessageRole,
  SingleAgentSnapshot
} from '../models/SingleAgentState';
import { ActivityTimelineReducer } from './ActivityTimelineReducer';

const THINKING_ACTIVITY_MAX_CHARS = 180;

export class ConversationStateCallbacks {
  private notifyCallback: () => void;
  private agentNameCallback: () => string;
  private providerDisplayCallback: (data: Record<string, Object> | undefined) => string;

  constructor(
    notifyCallback: () => void,
    agentNameCallback: () => string,
    providerDisplayCallback: (data: Record<string, Object> | undefined) => string
  ) {
    this.notifyCallback = notifyCallback;
    this.agentNameCallback = agentNameCallback;
    this.providerDisplayCallback = providerDisplayCallback;
  }

  notify(): void {
    this.notifyCallback();
  }

  agentName(): string {
    return this.agentNameCallback();
  }

  providerDisplay(data: Record<string, Object> | undefined): string {
    return this.providerDisplayCallback(data);
  }
}

class HistoryToolResult {
  success: boolean = true;
  message: string = '';
  duration_s?: number;
}

// Owns the mutable conversation graph shown by the UI. Networking and voice
// coordinators may request mutations, but do not keep parallel message state.
export class ConversationState {
  private snapshot: SingleAgentSnapshot;
  private callbacks: ConversationStateCallbacks;
  private messageCounter: number = 0;
  private activeAssistantMessageId: string = '';
  private activeAsrMessageId: string = '';
  private approvalResponseInFlight: boolean = false;
  private clarifyResponseInFlight: boolean = false;

  constructor(snapshot: SingleAgentSnapshot, callbacks: ConversationStateCallbacks) {
    this.snapshot = snapshot;
    this.callbacks = callbacks;
  }

  clearMessages(): void {
    this.snapshot.messages = [];
    this.activeAssistantMessageId = '';
    this.activeAsrMessageId = '';
  }

  toggleMessageProcess(messageId: string): void {
    for (const message of this.snapshot.messages) {
      if (message.id === messageId) {
        message.processExpanded = !message.processExpanded;
        message.revision += 1;
        this.callbacks.notify();
        return;
      }
    }
  }

  toggleMessageActivity(messageId: string, activityId: string): void {
    for (const message of this.snapshot.messages) {
      if (message.id !== messageId) {
        continue;
      }
      const activity = ActivityTimelineReducer.find(message.activities, activityId);
      if (activity !== undefined && activity.detail.length > 0) {
        activity.expanded = !activity.expanded;
        message.revision += 1;
        this.callbacks.notify();
      }
      return;
    }
  }

  appendMessage(role: MessageRole, label: string, text: string): ChatMessage {
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = role;
    message.label = label;
    message.text = text;
    message.timestamp = Date.now();
    this.snapshot.messages.push(message);
    this.callbacks.notify();
    return message;
  }

  beginAssistantMessage(): void {
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = 'assistant';
    message.label = this.callbacks.agentName();
    message.model = this.snapshot.runtimeModel;
    message.provider = this.snapshot.runtimeProvider;
    message.text = '';
    message.timestamp = Date.now();
    message.pending = true;
    message.processExpanded = true;
    this.snapshot.messages.push(message);
    this.activeAssistantMessageId = message.id;
    this.snapshot.agentBusy = true;
    this.callbacks.notify();
  }

  appendAssistantDelta(text: string): void {
    let message = this.currentAssistantMessage();
    if (!message || !message.pending) {
      this.beginAssistantMessage();
      message = this.currentAssistantMessage();
    }
    if (message && message.pending) {
      if (text.length > 0 && message.firstTokenAt === 0) {
        message.firstTokenAt = Date.now();
      }
      if (text.length > 0) {
        this.completeTrailingProcessActivity(message);
      }
      message.text += text;
      message.revision += 1;
      this.callbacks.notify();
    }
  }

  finishAssistantMessage(
    finalText: string,
    rawArtifacts: Object | undefined = undefined,
    model: string = ''
  ): void {
    const last = this.currentAssistantMessage();
    if (last && last.pending) {
      const endedAt = Date.now();
      if (finalText.length > 0) {
        last.text = finalText;
      }
      if (model.length > 0) {
        last.model = model;
      } else if (last.model.length === 0) {
        last.model = this.snapshot.runtimeModel;
      }
      if (last.provider.length === 0) {
        last.provider = this.snapshot.runtimeProvider;
      }
      last.artifacts = this.parseArtifacts(rawArtifacts);
      last.completedAt = endedAt;
      const firstTokenAt = last.firstTokenAt > 0 ? last.firstTokenAt : endedAt;
      last.thinking_s = Math.max(0, firstTokenAt - last.timestamp) / 1000;
      last.generation_s = Math.max(0, endedAt - firstTokenAt) / 1000;
      last.duration_s = Math.max(0, endedAt - last.timestamp) / 1000;
      ActivityTimelineReducer.finishAll(last.activities, endedAt);
      last.pending = false;
      last.processExpanded = last.activities.length > 0;
      last.revision += 1;
    }
    this.activeAssistantMessageId = '';
    this.snapshot.agentBusy = false;
    this.snapshot.statusDetail = '';
    this.callbacks.notify();
  }

  failAssistantMessage(errorText: string): void {
    const message = this.currentAssistantMessage();
    if (!message || !message.pending) {
      return;
    }
    const endedAt = Date.now();
    ActivityTimelineReducer.appendError(
      message.activities,
      'error-' + String(message.activities.length),
      '执行失败',
      errorText,
      endedAt
    );
    message.completedAt = endedAt;
    message.duration_s = Math.max(0, endedAt - message.timestamp) / 1000;
    message.pending = false;
    message.processExpanded = true;
    message.revision += 1;
    this.activeAssistantMessageId = '';
  }

  completeInterruptedAssistantMessage(): void {
    const message = this.currentAssistantMessage();
    if (!message || !message.pending) {
      this.activeAssistantMessageId = '';
      return;
    }
    const endedAt = Date.now();
    const firstTokenAt = message.firstTokenAt > 0 ? message.firstTokenAt : endedAt;
    message.completedAt = endedAt;
    message.thinking_s = Math.max(0, firstTokenAt - message.timestamp) / 1000;
    message.generation_s = Math.max(0, endedAt - firstTokenAt) / 1000;
    message.duration_s = Math.max(0, endedAt - message.timestamp) / 1000;
    ActivityTimelineReducer.finishAll(message.activities, endedAt);
    const activity = ActivityTimelineReducer.appendStatus(
      message.activities,
      'stopped-' + String(message.activities.length),
      '已按用户要求停止当前任务',
      endedAt
    );
    if (activity !== undefined) {
      activity.title = '任务已停止';
    }
    ActivityTimelineReducer.finishAll(message.activities, endedAt);
    message.pending = false;
    message.processExpanded = message.activities.length > 0;
    message.revision += 1;
    this.activeAssistantMessageId = '';
  }

  currentAssistantText(): string {
    const message = this.currentAssistantMessage();
    return message ? message.text : '';
  }

  currentAssistantMessage(): ChatMessage | undefined {
    const messages = this.snapshot.messages;
    if (this.activeAssistantMessageId.length > 0) {
      for (let index = messages.length - 1; index >= 0; index -= 1) {
        if (messages[index].id === this.activeAssistantMessageId) {
          return messages[index];
        }
      }
    }
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (messages[index].role === 'assistant' && messages[index].pending) {
        return messages[index];
      }
    }
    if (messages.length > 0 && messages[messages.length - 1].role === 'assistant') {
      return messages[messages.length - 1];
    }
    return undefined;
  }

  appendThinking(text: string): void {
    const message = this.currentAssistantMessage();
    if (message && text.length > 0) {
      message.thinking += text;
      let remaining = text;
      const now = Date.now();
      while (remaining.length > 0) {
        let currentLength = 0;
        if (message.activities.length > 0) {
          const lastActivity = message.activities[message.activities.length - 1];
          if (lastActivity.kind === 'thinking' && lastActivity.state === 'running') {
            currentLength = lastActivity.detail.length;
          }
        }
        const capacity = THINKING_ACTIVITY_MAX_CHARS - currentLength;
        if (capacity <= 0) {
          ActivityTimelineReducer.finishTrailing(message.activities, now);
          continue;
        }
        const chunkLength = this.thinkingChunkLength(remaining, capacity);
        const chunk = remaining.substring(0, chunkLength);
        remaining = remaining.substring(chunkLength);
        ActivityTimelineReducer.appendThinking(
          message.activities,
          'thinking-' + String(message.activities.length),
          chunk,
          now,
          remaining.length > 0
        );
      }
      message.processExpanded = true;
      message.revision += 1;
    }
  }

  updateStatusActivity(text: string): void {
    const message = this.currentAssistantMessage();
    if (!message || text.length === 0) {
      return;
    }
    ActivityTimelineReducer.appendStatus(
      message.activities,
      'status-' + String(message.activities.length),
      text,
      Date.now()
    );
    message.revision += 1;
  }

  updateToolActivity(type: string, data: Record<string, Object> | undefined): string {
    const name = data !== undefined && data['name'] !== undefined ? String(data['name']) : '工具';
    const message = this.currentAssistantMessage();
    if (!message) {
      return name;
    }
    const rawId = data !== undefined && data['tool_id'] !== undefined
      ? String(data['tool_id']) : data !== undefined && data['call_id'] !== undefined
        ? String(data['call_id']) : name;
    const id = 'tool-' + rawId;
    const title = this.historyToolTitle(name);
    const now = Date.now();
    if (type === 'tool.start') {
      const context = data !== undefined && data['context'] !== undefined
        ? String(data['context']) : data !== undefined && data['args_text'] !== undefined
          ? String(data['args_text']) : '';
      ActivityTimelineReducer.startTool(
        message.activities,
        id,
        title,
        this.activityExcerpt(context),
        now
      );
      message.processExpanded = true;
    } else if (type === 'tool.progress') {
      const preview = data !== undefined && data['preview'] !== undefined ? String(data['preview']) : '';
      ActivityTimelineReducer.progressTool(
        message.activities,
        id,
        title,
        this.activityExcerpt(preview),
        now
      );
    } else {
      const summary = data !== undefined && data['summary'] !== undefined ? String(data['summary']) : '';
      const error = data !== undefined && data['error'] !== undefined ? String(data['error']) : '';
      const duration = data !== undefined && typeof data['duration_s'] === 'number'
        ? data['duration_s'] as number : undefined;
      ActivityTimelineReducer.completeTool(
        message.activities,
        id,
        title,
        this.activityExcerpt(error.length > 0 ? error : summary.length > 0 ? summary : '执行完成'),
        error.length > 0,
        now,
        duration
      );
    }
    message.revision += 1;
    return name;
  }

  syncPendingAssistantIdentity(): void {
    const message = this.currentAssistantMessage();
    if (!message || !message.pending ||
      (this.snapshot.runtimeModel.length === 0 && this.snapshot.runtimeProvider.length === 0)) {
      return;
    }
    if (this.snapshot.runtimeModel.length > 0) {
      message.model = this.snapshot.runtimeModel;
    }
    message.provider = this.snapshot.runtimeProvider;
    message.revision += 1;
  }

  ensureAsrPreview(): ChatMessage {
    const existing = this.currentAsrMessage();
    if (existing !== undefined) {
      return existing;
    }
    const message = new ChatMessage();
    message.id = this.nextMessageId();
    message.role = 'user';
    message.label = '你 · 正在识别';
    message.status = 'listening';
    message.transient = true;
    message.timestamp = Date.now();
    this.snapshot.messages.push(message);
    this.activeAsrMessageId = message.id;
    return message;
  }

  currentAsrMessage(): ChatMessage | undefined {
    if (this.activeAsrMessageId.length === 0) {
      return undefined;
    }
    for (let index = this.snapshot.messages.length - 1; index >= 0; index -= 1) {
      const message = this.snapshot.messages[index];
      if (message.id === this.activeAsrMessageId) {
        return message;
      }
    }
    return undefined;
  }

  commitAsrMessage(message: ChatMessage): void {
    if (message.id === this.activeAsrMessageId) {
      this.activeAsrMessageId = '';
    }
  }

  discardAsrPreview(): void {
    if (this.activeAsrMessageId.length === 0) {
      return;
    }
    for (let index = this.snapshot.messages.length - 1; index >= 0; index -= 1) {
      if (this.snapshot.messages[index].id === this.activeAsrMessageId) {
        this.snapshot.messages.splice(index, 1);
        break;
      }
    }
    this.activeAsrMessageId = '';
  }

  isApprovalResponseInFlight(): boolean {
    return this.approvalResponseInFlight;
  }

  isClarifyResponseInFlight(): boolean {
    return this.clarifyResponseInFlight;
  }

  setApprovalResponseInFlight(active: boolean): void {
    this.approvalResponseInFlight = active;
  }

  setClarifyResponseInFlight(active: boolean): void {
    this.clarifyResponseInFlight = active;
  }

  beginApproval(description: string, command: string): boolean {
    const duplicate = this.snapshot.approvalPending &&
      this.snapshot.approvalDescription === description && this.snapshot.approvalCommand === command;
    this.snapshot.approvalPending = true;
    this.snapshot.approvalDescription = description;
    this.snapshot.approvalCommand = command;
    if (!duplicate) {
      this.approvalResponseInFlight = false;
    }
    return !duplicate;
  }

  beginClarify(requestId: string, question: string, choices: string[]): boolean {
    const duplicate = this.snapshot.clarifyPending && this.snapshot.clarifyRequestId === requestId;
    this.snapshot.clarifyPending = true;
    this.snapshot.clarifyRequestId = requestId;
    this.snapshot.clarifyQuestion = question;
    this.snapshot.clarifyChoices = choices;
    if (!duplicate) {
      this.clarifyResponseInFlight = false;
    }
    return !duplicate;
  }

  clearApproval(): void {
    this.approvalResponseInFlight = false;
    this.snapshot.approvalPending = false;
    this.snapshot.approvalDescription = '';
    this.snapshot.approvalCommand = '';
  }

  clearClarify(): void {
    this.clarifyResponseInFlight = false;
    this.snapshot.clarifyPending = false;
    this.snapshot.clarifyRequestId = '';
    this.snapshot.clarifyQuestion = '';
    this.snapshot.clarifyChoices = [];
  }

  clearPendingProtocolRequests(): void {
    this.clearApproval();
    this.clearClarify();
  }

  parseHistorySessions(result: Object): HistorySession[] {
    const record = result as Record<string, Object>;
    const rawSessions = record['sessions'];
    if (!Array.isArray(rawSessions)) {
      return [];
    }
    const sessions: HistorySession[] = [];
    for (const item of rawSessions as Object[]) {
      const row = item as Record<string, Object>;
      const rawId = row['id'] !== undefined ? row['id'] : row['session_id'];
      if (rawId === undefined) {
        continue;
      }
      const session = new HistorySession();
      session.id = String(rawId);
      const title = row['title'] !== undefined ? String(row['title']).trim() : '';
      const preview = row['preview'] !== undefined ? String(row['preview']).trim() : '';
      session.title = title.length > 0 ? title : preview.length > 0 ? preview : '未命名对话';
      session.preview = preview;
      session.source = row['source'] !== undefined ? String(row['source']) : 'Hermes';
      if (row['model'] !== undefined) {
        session.model = String(row['model']);
      }
      const updated = row['updated_at'] !== undefined ? row['updated_at'] : row['started_at'];
      if (typeof updated === 'number') {
        session.updated_at = updated;
      }
      if (typeof row['started_at'] === 'number') {
        session.started_at = row['started_at'] as number;
      }
      if (typeof row['message_count'] === 'number') {
        session.message_count = row['message_count'] as number;
      }
      sessions.push(session);
    }
    return sessions;
  }

  restoreSessionMessages(
    messageItems: Object[],
    initialModel: string,
    processComplete: boolean = true
  ): void {
    this.clearMessages();
    let currentModel = initialModel;
    let pendingActivities: MessageActivity[] = [];
    for (const item of messageItems) {
      const row = item as Record<string, Object>;
      if (String(row['display_kind'] !== undefined ? row['display_kind'] : '') === 'model_switch') {
        currentModel = this.historyModelSwitch(row['display_metadata'], currentModel);
        continue;
      }
      const roleValue = row['role'] !== undefined ? String(row['role']) : '';
      if (roleValue === 'tool') {
        this.restoreHistoryToolResult(row, pendingActivities);
        continue;
      }
      if (roleValue !== 'user' && roleValue !== 'assistant') {
        continue;
      }
      const text = row['text'] !== undefined
        ? String(row['text']) : row['content'] !== undefined ? String(row['content']) : '';
      const artifacts = this.parseArtifacts(row['artifacts']);
      if (roleValue === 'assistant') {
        this.appendHistoryThinkingActivity(pendingActivities, row);
        this.restoreHistoryToolCalls(row, pendingActivities);
      }
      if (text.length === 0 && artifacts.length === 0) {
        continue;
      }
      const message = new ChatMessage();
      message.id = this.nextMessageId();
      message.role = roleValue === 'user' ? 'user' : 'assistant';
      message.label = message.role === 'user' ? '你' : this.callbacks.agentName();
      message.text = text;
      message.artifacts = artifacts;
      message.model = row['model'] !== undefined
        ? String(row['model']) : message.role === 'assistant' ? currentModel : '';
      message.provider = this.callbacks.providerDisplay(row);
      message.timestamp = this.parseTimestamp(row['timestamp']);
      if (message.role === 'user') {
        pendingActivities = [];
      } else {
        message.thinking = this.historyThinkingText(pendingActivities);
        message.activities = pendingActivities;
        message.processWarning = processComplete ? '' : '历史过程未完整载入';
        message.processExpanded = message.activities.length > 0 || message.processWarning.length > 0;
        pendingActivities = [];
      }
      this.snapshot.messages.push(message);
    }
  }

  parseArtifacts(rawArtifacts: Object | undefined): MessageArtifact[] {
    if (!Array.isArray(rawArtifacts)) {
      return [];
    }
    const artifacts: MessageArtifact[] = [];
    const items = rawArtifacts as Object[];
    for (const item of items) {
      const row = item as Record<string, Object>;
      const token = row['token'] !== undefined ? String(row['token']) : '';
      if (token.length === 0) {
        continue;
      }
      const artifact = new MessageArtifact();
      artifact.token = token;
      artifact.name = row['name'] !== undefined ? String(row['name']) : '附件';
      artifact.mimeType = row['mime_type'] !== undefined
        ? String(row['mime_type']) : 'application/octet-stream';
      artifact.size = typeof row['size'] === 'number' ? row['size'] as number : 0;
      artifact.isImage = row['is_image'] === true || artifact.mimeType.startsWith('image/');
      artifacts.push(artifact);
    }
    return artifacts;
  }

  nextMessageId(): string {
    this.messageCounter += 1;
    return util.generateRandomUUID(true) + '-' + String(this.messageCounter);
  }

  private historyModelSwitch(rawMetadata: Object | undefined, fallback: string): string {
    if (rawMetadata === undefined) {
      return fallback;
    }
    let metadata: Record<string, Object>;
    if (typeof rawMetadata === 'string') {
      try {
        metadata = JSON.parse(rawMetadata) as Record<string, Object>;
      } catch (error) {
        return fallback;
      }
    } else {
      metadata = rawMetadata as Record<string, Object>;
    }
    return metadata['model'] !== undefined ? String(metadata['model']) : fallback;
  }

  private appendHistoryThinkingActivity(activities: MessageActivity[], row: Record<string, Object>): void {
    const raw = row['reasoning_content'] !== undefined
      ? String(row['reasoning_content']) : row['reasoning'] !== undefined ? String(row['reasoning']) : '';
    const value = raw.trim();
    if (value.length === 0) {
      return;
    }
    const activity = ActivityTimelineReducer.appendThinking(
      activities,
      'history-thinking-' + String(activities.length),
      value,
      0,
      true
    );
    if (activity === undefined) {
      return;
    }
    const startedAt = this.timelineTimestamp(row['started_at']);
    const endedAt = this.timelineTimestamp(
      row['completed_at'] !== undefined ? row['completed_at'] : row['ended_at']
    );
    if (startedAt > 0 && endedAt >= startedAt) {
      activity.startedAt = startedAt;
      activity.endedAt = endedAt;
      activity.duration_s = (endedAt - startedAt) / 1000;
    }
  }

  private restoreHistoryToolCalls(row: Record<string, Object>, activities: MessageActivity[]): void {
    const rawCalls = row['tool_calls'];
    if (!Array.isArray(rawCalls)) {
      return;
    }
    for (const rawCall of rawCalls as Object[]) {
      const call = rawCall as Record<string, Object>;
      const rawFunction = call['function'];
      const toolFunction = rawFunction !== undefined && typeof rawFunction === 'object'
        ? rawFunction as Record<string, Object> : undefined;
      const name = toolFunction !== undefined && toolFunction['name'] !== undefined
        ? String(toolFunction['name']) : call['name'] !== undefined ? String(call['name']) : 'tool';
      const callId = call['call_id'] !== undefined
        ? String(call['call_id']) : call['tool_call_id'] !== undefined
          ? String(call['tool_call_id']) : call['id'] !== undefined ? String(call['id']) : name;
      const activityId = 'tool-' + callId;
      const rawArguments = toolFunction !== undefined ? toolFunction['arguments'] : undefined;
      ActivityTimelineReducer.startTool(
        activities,
        activityId,
        this.historyToolTitle(name),
        this.activityExcerpt(this.objectText(rawArguments)),
        this.timelineTimestamp(row['timestamp'])
      );
    }
  }

  private restoreHistoryToolResult(row: Record<string, Object>, activities: MessageActivity[]): void {
    const name = row['tool_name'] !== undefined ? String(row['tool_name']) : 'tool';
    const callId = row['tool_call_id'] !== undefined ? String(row['tool_call_id']) : name;
    const activityId = 'tool-' + callId;
    const result = this.historyToolResult(row['content']);
    ActivityTimelineReducer.completeTool(
      activities,
      activityId,
      this.historyToolTitle(name),
      result.success
        ? this.historyToolSuccessText(name, result.message)
        : result.message.length > 0 ? this.activityExcerpt(result.message) : '执行失败',
      !result.success,
      this.timelineTimestamp(row['timestamp']),
      result.duration_s
    );
  }

  private historyToolTitle(name: string): string {
    if (name === 'memory') {
      return '记忆更新';
    }
    if (name === 'web_search' || name === 'search') {
      return '信息检索';
    }
    return name === 'tool' || name.length === 0 ? '工具调用' : name;
  }

  private historyToolResult(rawContent: Object | undefined): HistoryToolResult {
    const result = new HistoryToolResult();
    if (rawContent === undefined) {
      return result;
    }
    try {
      const parsed = typeof rawContent === 'string'
        ? JSON.parse(rawContent) as Record<string, Object>
        : rawContent as Record<string, Object>;
      result.success = parsed['success'] !== false && parsed['error'] === undefined;
      result.message = parsed['message'] !== undefined
        ? String(parsed['message']) : parsed['error'] !== undefined ? String(parsed['error']) : '';
      if (typeof parsed['duration_s'] === 'number') {
        result.duration_s = parsed['duration_s'] as number;
      }
    } catch (error) {
      result.success = true;
    }
    return result;
  }

  private historyToolSuccessText(name: string, message: string): string {
    if (name === 'memory') {
      const normalized = message.toLowerCase();
      return normalized.includes('added') ? '已记录用户偏好' : '已更新用户偏好';
    }
    return '执行完成';
  }

  private historyThinkingText(activities: MessageActivity[]): string {
    const parts: string[] = [];
    for (const activity of activities) {
      if (activity.kind === 'thinking' && activity.detail.length > 0) {
        parts.push(activity.detail);
      }
    }
    return parts.join('\n\n');
  }

  private activityExcerpt(value: string): string {
    const redacted = value
      .replace(/("(?:access_token|api_key|authorization|password|secret|token)"\s*:\s*")[^"]*(")/gi,
        '$1[已隐藏]$2')
      .replace(/((?:access_token|api_key|authorization|password|secret|token)\s*=\s*)[^&\s,}]+/gi,
        '$1[已隐藏]')
      .replace(/(bearer\s+)[a-z0-9._-]+/gi, '$1[已隐藏]');
    const normalized = redacted.replace(/\s+/g, ' ').trim();
    if (normalized.length <= 240) {
      return normalized;
    }
    return normalized.substring(0, 237) + '...';
  }

  private thinkingChunkLength(value: string, maxLength: number): number {
    if (value.length <= maxLength) {
      return value.length;
    }
    const boundaries = '。！？!?；;\n';
    let boundary = -1;
    for (let index = maxLength - 1; index >= 0; index -= 1) {
      if (boundaries.includes(value[index])) {
        boundary = index + 1;
        break;
      }
    }
    if (boundary >= 40) {
      return boundary;
    }
    for (let index = maxLength - 1; index >= 40; index -= 1) {
      if (/\s/.test(value[index])) {
        return index + 1;
      }
    }
    return maxLength;
  }

  private completeTrailingProcessActivity(message: ChatMessage): void {
    ActivityTimelineReducer.finishTrailing(message.activities, Date.now());
  }

  private objectText(value: Object | undefined): string {
    if (value === undefined) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    try {
      return JSON.stringify(value);
    } catch (error) {
      return '';
    }
  }

  private timelineTimestamp(value: Object | undefined): number {
    const parsed = this.parseTimestamp(value);
    return parsed > 0 && parsed < 100000000000 ? parsed * 1000 : parsed;
  }

  private parseTimestamp(value: Object | undefined): number {
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
    if (typeof value === 'string') {
      const numeric = Number(value);
      if (Number.isFinite(numeric) && numeric > 0) {
        return numeric;
      }
      const millis = Date.parse(value);
      if (Number.isFinite(millis) && millis > 0) {
        return millis;
      }
    }
    return 0;
  }

}
