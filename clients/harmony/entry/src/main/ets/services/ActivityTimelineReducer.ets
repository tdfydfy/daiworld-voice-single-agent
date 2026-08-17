import { MessageActivity } from '../models/SingleAgentState';

export class ActivityTimelineReducer {
  static appendThinking(
    activities: MessageActivity[],
    id: string,
    text: string,
    now: number,
    completed: boolean = false
  ): MessageActivity | undefined {
    const value = text.trim();
    if (value.length === 0) {
      return undefined;
    }
    let activity = ActivityTimelineReducer.trailingRunning(activities, 'thinking');
    if (activity === undefined) {
      activity = ActivityTimelineReducer.create(id, 'thinking', '思考', now);
      activities.push(activity);
    }
    activity.detail += activity.detail.length > 0 ? text : value;
    activity.summary = ActivityTimelineReducer.summary(activity.detail, '正在思考');
    if (completed) {
      ActivityTimelineReducer.complete(activity, now);
    }
    return activity;
  }

  static appendStatus(
    activities: MessageActivity[],
    id: string,
    text: string,
    now: number
  ): MessageActivity | undefined {
    const value = text.trim();
    if (value.length === 0) {
      return undefined;
    }
    let activity = ActivityTimelineReducer.trailingRunning(activities, 'status');
    if (activity !== undefined && activity.detail === value) {
      return activity;
    }
    ActivityTimelineReducer.finishTrailing(activities, now);
    activity = ActivityTimelineReducer.create(id, 'status', '状态', now);
    activity.summary = ActivityTimelineReducer.summary(value, '状态更新');
    activity.detail = value;
    activities.push(activity);
    return activity;
  }

  static startTool(
    activities: MessageActivity[],
    id: string,
    title: string,
    input: string,
    now: number
  ): MessageActivity {
    let activity = ActivityTimelineReducer.find(activities, id);
    if (activity !== undefined) {
      activity.title = title;
      if (input.length > 0 && !activity.detail.startsWith('输入：')) {
        activity.detail = '输入：' + input + (activity.detail.length > 0 ? '\n' + activity.detail : '');
      }
      return activity;
    }
    ActivityTimelineReducer.finishTrailing(activities, now);
    activity = ActivityTimelineReducer.create(id, 'tool', title, now);
    activities.push(activity);
    activity.title = title;
    activity.summary = '执行中';
    activity.detail = input.length > 0 ? '输入：' + input : '';
    activity.state = 'running';
    if (activity.startedAt <= 0) {
      activity.startedAt = now;
    }
    activity.endedAt = 0;
    activity.duration_s = undefined;
    return activity;
  }

  static progressTool(
    activities: MessageActivity[],
    id: string,
    title: string,
    preview: string,
    now: number
  ): MessageActivity {
    let activity = ActivityTimelineReducer.find(activities, id);
    if (activity === undefined) {
      activity = ActivityTimelineReducer.startTool(activities, id, title, '', now);
    }
    if (activity.state !== 'running') {
      return activity;
    }
    activity.summary = '执行中';
    activity.detail = ActivityTimelineReducer.replaceDetail(activity.detail, '进展：', preview);
    activity.state = 'running';
    return activity;
  }

  static completeTool(
    activities: MessageActivity[],
    id: string,
    title: string,
    result: string,
    failed: boolean,
    now: number,
    duration_s?: number
  ): MessageActivity {
    let activity = ActivityTimelineReducer.find(activities, id);
    if (activity !== undefined && activity.state !== 'running') {
      return activity;
    }
    if (activity === undefined) {
      activity = ActivityTimelineReducer.create(id, 'tool', title, 0);
      activities.push(activity);
    }
    activity.title = title;
    activity.summary = failed ? '失败' : '已完成';
    const prefix = failed ? '失败：' : '结果：';
    activity.detail = ActivityTimelineReducer.replaceDetail(activity.detail, prefix, result);
    activity.state = failed ? 'error' : 'completed';
    ActivityTimelineReducer.complete(activity, now, duration_s);
    return activity;
  }

  static appendError(
    activities: MessageActivity[],
    id: string,
    title: string,
    detail: string,
    now: number
  ): MessageActivity {
    ActivityTimelineReducer.finishTrailing(activities, now);
    const activity = ActivityTimelineReducer.create(id, 'error', title, now);
    activity.summary = '失败';
    activity.detail = detail;
    activity.state = 'error';
    ActivityTimelineReducer.complete(activity, now);
    activities.push(activity);
    return activity;
  }

  static finishTrailing(activities: MessageActivity[], now: number): void {
    if (activities.length === 0) {
      return;
    }
    const activity = activities[activities.length - 1];
    if ((activity.kind === 'thinking' || activity.kind === 'status') &&
      activity.state === 'running') {
      activity.state = 'completed';
      ActivityTimelineReducer.complete(activity, now);
    }
  }

  static finishAll(activities: MessageActivity[], now: number): void {
    for (const activity of activities) {
      if (activity.state === 'running') {
        activity.state = 'completed';
        if (activity.summary.length === 0 || activity.summary === '执行中') {
          activity.summary = '已完成';
        }
        ActivityTimelineReducer.complete(activity, now);
      }
    }
  }

  static find(activities: MessageActivity[], id: string): MessageActivity | undefined {
    for (const activity of activities) {
      if (activity.id === id) {
        return activity;
      }
    }
    return undefined;
  }

  private static create(
    id: string,
    kind: 'thinking' | 'tool' | 'status' | 'error',
    title: string,
    now: number
  ): MessageActivity {
    const activity = new MessageActivity();
    activity.id = id;
    activity.kind = kind;
    activity.title = title;
    activity.startedAt = now;
    return activity;
  }

  private static trailingRunning(
    activities: MessageActivity[],
    kind: 'thinking' | 'status'
  ): MessageActivity | undefined {
    if (activities.length === 0) {
      return undefined;
    }
    const activity = activities[activities.length - 1];
    return activity.kind === kind && activity.state === 'running' ? activity : undefined;
  }

  private static complete(activity: MessageActivity, now: number, suppliedDuration?: number): void {
    if (now > 0) {
      activity.endedAt = now;
    }
    if (suppliedDuration !== undefined && suppliedDuration >= 0) {
      activity.duration_s = suppliedDuration;
      return;
    }
    if (activity.startedAt > 0 && activity.endedAt >= activity.startedAt) {
      activity.duration_s = (activity.endedAt - activity.startedAt) / 1000;
    }
  }

  private static replaceDetail(existing: string, prefix: string, value: string): string {
    const normalized = value.trim();
    if (normalized.length === 0) {
      return existing;
    }
    const lines = existing.length > 0 ? existing.split('\n') : [];
    const output: string[] = [];
    for (const line of lines) {
      if (!line.startsWith(prefix)) {
        output.push(line);
      }
    }
    output.push(prefix + normalized);
    return output.join('\n');
  }

  private static summary(value: string, fallback: string): string {
    const normalized = value.replace(/\s+/g, ' ').trim();
    if (normalized.length === 0) {
      return fallback;
    }
    const boundaries = '。！？!?；;';
    for (let index = 0; index < normalized.length && index < 60; index += 1) {
      if (boundaries.includes(normalized[index])) {
        return normalized.substring(0, index + 1);
      }
    }
    return normalized.length <= 60 ? normalized : normalized.substring(0, 57) + '...';
  }
}
