// Opt-in Hermes stop-contract probe. It is inert unless HERMES_C0_RUN=1.
// The probe uses the Adapter's existing /api/hermes/ws JSON-RPC bridge and
// never prints access tokens or message content.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const RUN_FLAG = '1';
const DEFAULT_RUNNING_TIMEOUT_MS = 15000;
const DEFAULT_SETTLE_MS = 5000;
const RPC_TIMEOUT_MS = 30000;

const METHODS = {
  create: 'session.create',
  submit: 'prompt.submit',
  interrupt: 'session.interrupt',
  detail: 'session.detail',
  delete: 'session.delete',
};

const RUNNING_EVENTS = new Set([
  'message.start',
  'message.delta',
  'thinking.delta',
  'reasoning.delta',
  'tool.start',
]);
const COMPLETION_EVENT_TYPES = new Set(['message.complete']);
const CONTRACT_MARKERS = Object.freeze({
  running: 'C0_RUNNING_DONE',
  queueA: 'C0_QUEUE_A_DONE',
  queueB: 'C0_QUEUE_B_DONE',
});

export function readProbeConfig(env = process.env) {
  if (env.HERMES_C0_RUN !== RUN_FLAG) {
    return { enabled: false };
  }
  const required = [
    'HERMES_C0_GATEWAY_WS_URL',
    'HERMES_C0_GATEWAY_HTTP_URL',
    'HERMES_C0_ACCESS_TOKEN',
    'HERMES_C0_PROFILE',
  ];
  const missing = required.filter((name) => !String(env[name] || '').trim());
  if (missing.length > 0) {
    throw new Error(`missing required C0 environment: ${missing.join(', ')}`);
  }
  const runningTimeoutMs = boundedMilliseconds(
    env.HERMES_C0_RUNNING_TIMEOUT_MS,
    DEFAULT_RUNNING_TIMEOUT_MS,
  );
  const settleMs = boundedMilliseconds(env.HERMES_C0_SETTLE_MS, DEFAULT_SETTLE_MS);
  return {
    enabled: true,
    wsUrl: validateUrl(env.HERMES_C0_GATEWAY_WS_URL, ['ws:', 'wss:']),
    httpUrl: validateUrl(env.HERMES_C0_GATEWAY_HTTP_URL, ['http:', 'https:']),
    accessToken: String(env.HERMES_C0_ACCESS_TOKEN),
    profile: String(env.HERMES_C0_PROFILE).trim(),
    runningTimeoutMs,
    settleMs,
    keepSession: env.HERMES_C0_KEEP_SESSION === RUN_FLAG,
    outputPath: String(env.HERMES_C0_OUTPUT || '').trim(),
  };
}

export function buildGatewayWsUrl(wsUrl, profile, accessToken) {
  const url = new URL(wsUrl);
  url.searchParams.set('profile', profile);
  url.searchParams.set('token', accessToken);
  return url.toString();
}

export function buildHistoryUrl(httpUrl, profile, sessionId) {
  const base = httpUrl.endsWith('/') ? httpUrl : `${httpUrl}/`;
  const url = new URL(`api/hermes/sessions/${encodeURIComponent(sessionId)}`, base);
  url.searchParams.set('profile', profile);
  return url.toString();
}

// Keep the conclusion conservative: absence of a completion marker is not
// proof that Hermes cancelled the queued work, while a post-interrupt marker
// is direct evidence that queued work continued.
export function buildContractEvidence(events, history, interruptEventIndex) {
  const startIndex = Number.isInteger(interruptEventIndex) && interruptEventIndex >= 0
    ? interruptEventIndex : 0;
  const postInterruptEvents = Array.isArray(events)
    ? events.slice(startIndex).filter((event) => COMPLETION_EVENT_TYPES.has(event?.type))
    : [];
  const postInterruptMarkers = markerFlags(postInterruptEvents.map((event) => event?.payload));
  const historyMarkers = markerFlags(historyMessages(history)
    .filter((message) => message?.role === 'assistant' || message?.role === 'tool')
    .flatMap((message) => messageTextValues(message)));
  const queueWorkObserved = postInterruptMarkers.queueA || postInterruptMarkers.queueB;
  return {
    post_interrupt_completion_markers: postInterruptMarkers,
    history_completion_markers: historyMarkers,
    interpretation: queueWorkObserved
      ? 'queue_work_observed_after_interrupt'
      : 'inconclusive_no_post_interrupt_queue_completion',
  };
}

function markerFlags(values) {
  return {
    running: values.some((value) => containsMarker(value, CONTRACT_MARKERS.running)),
    queueA: values.some((value) => containsMarker(value, CONTRACT_MARKERS.queueA)),
    queueB: values.some((value) => containsMarker(value, CONTRACT_MARKERS.queueB)),
  };
}

function containsMarker(value, marker) {
  if (typeof value === 'string') {
    return value.includes(marker);
  }
  if (Array.isArray(value)) {
    return value.some((item) => containsMarker(item, marker));
  }
  if (value && typeof value === 'object') {
    return Object.values(value).some((item) => containsMarker(item, marker));
  }
  return false;
}

function messageTextValues(message, result = []) {
  if (!message || typeof message !== 'object') {
    return result;
  }
  for (const key of ['text', 'content', 'output', 'answer']) {
    if (message[key] !== undefined) {
      result.push(message[key]);
    }
  }
  if (message.message && typeof message.message === 'object') {
    messageTextValues(message.message, result);
  }
  return result;
}

function historyMessages(value, result = []) {
  if (Array.isArray(value)) {
    for (const item of value) {
      historyMessages(item, result);
    }
    return result;
  }
  if (!value || typeof value !== 'object') {
    return result;
  }
  if (typeof value.role === 'string') {
    result.push(value);
  }
  for (const child of Object.values(value)) {
    historyMessages(child, result);
  }
  return result;
}

export class JsonRpcProbe {
  constructor(url, socketFactory = (targetUrl) => new WebSocket(targetUrl)) {
    this.url = url;
    this.socketFactory = socketFactory;
    this.socket = undefined;
    this.nextId = 0;
    this.pending = new Map();
    this.events = [];
  }

  open() {
    return new Promise((resolve, reject) => {
      const socket = this.socketFactory(this.url);
      this.socket = socket;
      socket.onopen = () => resolve();
      socket.onerror = () => reject(new Error('C0 WebSocket connection failed'));
      socket.onclose = () => {
        for (const pending of this.pending.values()) {
          clearTimeout(pending.timer);
          pending.reject(new Error('C0 WebSocket closed'));
        }
        this.pending.clear();
      };
      socket.onmessage = (event) => this.onMessage(event.data);
    });
  }

  request(method, params) {
    if (!this.socket || this.socket.readyState !== 1) {
      return Promise.reject(new Error('C0 WebSocket is not open'));
    }
    const id = String(++this.nextId);
    const frame = { jsonrpc: '2.0', id, method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`C0 RPC timeout: ${method}`));
      }, RPC_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify(frame));
    });
  }

  waitForRunningEvent(sessionId, startIndex, timeoutMs) {
    const existing = this.events.slice(startIndex).find((event) =>
      event.session_id === sessionId && RUNNING_EVENTS.has(event.type));
    if (existing) {
      return Promise.resolve(existing);
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        cleanup();
        resolve(undefined);
      }, timeoutMs);
      const check = () => {
        const event = this.events.slice(startIndex).find((item) =>
          item.session_id === sessionId && RUNNING_EVENTS.has(item.type));
        if (event) {
          cleanup();
          resolve(event);
        }
      };
      const interval = setInterval(check, 100);
      const cleanup = () => {
        clearTimeout(timer);
        clearInterval(interval);
      };
    });
  }

  close() {
    if (this.socket && this.socket.readyState < 2) {
      this.socket.close();
    }
    this.socket = undefined;
  }

  onMessage(data) {
    let frame;
    try {
      frame = JSON.parse(String(data));
    } catch {
      return;
    }
    if (frame?.method === 'event' && frame.params) {
      this.events.push({
        observed_at: new Date().toISOString(),
        type: frame.params.type || '',
        session_id: frame.params.session_id || '',
        payload: frame.params.payload,
      });
      return;
    }
    if (frame?.id === undefined) {
      return;
    }
    const id = String(frame.id);
    const pending = this.pending.get(id);
    if (!pending) {
      return;
    }
    this.pending.delete(id);
    clearTimeout(pending.timer);
    if (frame.error) {
      pending.reject(frame.error);
    } else {
      pending.resolve(frame.result);
    }
  }
}

async function call(client, report, method, params) {
  try {
    const result = await client.request(method, params);
    report.rpc.push({ method, ok: true, result: redact(result) });
    return result;
  } catch (error) {
    report.rpc.push({ method, ok: false, error: redact(errorMessage(error)) });
    throw error;
  }
}

export async function runProbe(config = readProbeConfig(), dependencies = {}) {
  if (!config.enabled) {
    throw new Error('C0 probe is disabled; set HERMES_C0_RUN=1 to enable it');
  }
  const createClient = dependencies.createClient || ((url) => new JsonRpcProbe(url));
  const fetchImpl = dependencies.fetchImpl || fetch;
  const delayFn = dependencies.delayFn || delay;
  const report = {
    status: 'running',
    started_at: new Date().toISOString(),
    profile: config.profile,
    outputPath: config.outputPath,
    rpc: [],
    events: [],
  };
  const client = createClient(buildGatewayWsUrl(
    config.wsUrl,
    config.profile,
    config.accessToken,
  ));
  let sessionId = '';
  try {
    await client.open();
    const created = await call(client, report, METHODS.create, { cols: 100, instructions: '' });
    sessionId = String(created?.session_id || '');
    if (!sessionId) {
      throw new Error('session.create returned no session_id');
    }
    report.session_id = sessionId;

    const firstEventIndex = client.events.length;
    await call(client, report, METHODS.submit, {
      session_id: sessionId,
      text: '[C0_RUNNING] Perform a harmless long-running test and reply C0_RUNNING_DONE after waiting 10 seconds.',
      queued: false,
    });
    const runningEvent = await client.waitForRunningEvent(
      sessionId,
      firstEventIndex,
      config.runningTimeoutMs,
    );
    if (!runningEvent) {
      throw new Error('no running event observed before queue setup');
    }
    report.running_event = { type: runningEvent.type };

    await call(client, report, METHODS.submit, {
      session_id: sessionId,
      text: '[C0_QUEUE_A] Reply C0_QUEUE_A_DONE after the running task is released.',
      queued: true,
    });
    await call(client, report, METHODS.submit, {
      session_id: sessionId,
      text: '[C0_QUEUE_B] Reply C0_QUEUE_B_DONE after C0_QUEUE_A.',
      queued: true,
    });
    const interruptEventIndex = client.events.length;
    report.interrupt_event_index = interruptEventIndex;
    report.interrupt_requested_at = new Date().toISOString();
    await call(client, report, METHODS.interrupt, { session_id: sessionId });
    await delayFn(config.settleMs);

    const history = await fetchHistory(config, sessionId, fetchImpl);
    report.history = redact(history);
    report.contract = buildContractEvidence(
      client.events,
      history,
      interruptEventIndex,
    );
    report.status = 'completed';
  } catch (error) {
    report.status = 'failed';
    report.error = redact(errorMessage(error));
  } finally {
    if (sessionId && !config.keepSession) {
      await call(client, report, METHODS.delete, { session_id: sessionId }).catch((error) => {
        report.cleanup_error = redact(errorMessage(error));
      });
    }
    report.events = client.events.map((event) => redact(event));
    client.close();
    report.finished_at = new Date().toISOString();
  }
  return report;
}

async function fetchHistory(config, sessionId, fetchImpl) {
  const response = await fetchImpl(buildHistoryUrl(config.httpUrl, config.profile, sessionId), {
    headers: { 'X-Voice-Token': config.accessToken },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`history request failed with HTTP ${response.status}`);
  }
  return body;
}

function boundedMilliseconds(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 1000 && parsed <= 120000 ? parsed : fallback;
}

function validateUrl(value, protocols) {
  const url = new URL(String(value));
  if (!protocols.includes(url.protocol)) {
    throw new Error(`invalid C0 URL protocol; expected ${protocols.join(' or ')}`);
  }
  return url.toString();
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function errorMessage(error) {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === 'string') {
    return error;
  }
  return 'C0 request failed';
}

function redact(value, key = '') {
  if (/token|password|cookie|authorization|secret/i.test(key)) {
    return '[REDACTED]';
  }
  if (typeof value === 'string') {
    if (/text|content|rendered|speech|answer|prompt|message/i.test(key)) {
      return { type: 'string', length: value.length };
    }
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => redact(item, key));
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([childKey, childValue]) => [
      childKey,
      redact(childValue, childKey),
    ]));
  }
  return value;
}

function printUsage() {
  console.log([
    'Opt-in C0 probe. No network is used unless HERMES_C0_RUN=1.',
    'Required: HERMES_C0_GATEWAY_WS_URL, HERMES_C0_GATEWAY_HTTP_URL,',
    '          HERMES_C0_ACCESS_TOKEN, HERMES_C0_PROFILE.',
    'Optional: HERMES_C0_OUTPUT, HERMES_C0_KEEP_SESSION=1,',
    '          HERMES_C0_RUNNING_TIMEOUT_MS, HERMES_C0_SETTLE_MS.',
  ].join('\n'));
}

function isMainModule() {
  return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (isMainModule()) {
  if (process.argv.includes('--help')) {
    printUsage();
  } else {
    try {
      const config = readProbeConfig();
      if (!config.enabled) {
        printUsage();
      } else {
        runProbe(config).then(async (report) => {
          const output = JSON.stringify(report, null, 2);
          if (report.outputPath) {
            await fs.mkdir(path.dirname(path.resolve(report.outputPath)), { recursive: true });
            await fs.writeFile(path.resolve(report.outputPath), output + '\n', 'utf8');
          }
          console.log(output);
          if (report.status !== 'completed') {
            process.exitCode = 1;
          }
        }).catch((error) => {
          console.error(JSON.stringify({ status: 'failed', error: redact(errorMessage(error)) }, null, 2));
          process.exitCode = 1;
        });
      }
    } catch (error) {
      console.error(JSON.stringify({ status: 'failed', error: redact(errorMessage(error)) }, null, 2));
      process.exitCode = 1;
    }
  }
}
