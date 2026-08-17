const test = require('node:test');
const assert = require('node:assert/strict');

async function loadProbe() {
  return import('../clients/harmony/scripts/c0_stop_contract_probe.mjs');
}

test('C0 probe remains disabled without the explicit run flag', async () => {
  const { readProbeConfig } = await loadProbe();
  assert.deepEqual(readProbeConfig({}), { enabled: false });
});

test('C0 probe builds the existing Adapter WebSocket and history routes', async () => {
  const { buildGatewayWsUrl, buildHistoryUrl } = await loadProbe();
  const ws = new URL(buildGatewayWsUrl(
    'wss://gateway.example.test/api/hermes/ws',
    'default',
    'temporary-token',
  ));
  assert.equal(ws.pathname, '/api/hermes/ws');
  assert.equal(ws.searchParams.get('profile'), 'default');
  assert.equal(ws.searchParams.get('token'), 'temporary-token');

  const history = new URL(buildHistoryUrl(
    'https://gateway.example.test',
    'default',
    'session-123',
  ));
  assert.equal(history.pathname, '/api/hermes/sessions/session-123');
  assert.equal(history.searchParams.get('profile'), 'default');
});

test('C0 probe validates required environment only after opt-in', async () => {
  const { readProbeConfig } = await loadProbe();
  assert.throws(
    () => readProbeConfig({ HERMES_C0_RUN: '1' }),
    /missing required C0 environment/,
  );
});

function enabledConfig() {
  return {
    enabled: true,
    wsUrl: 'wss://gateway.example.test/api/hermes/ws',
    httpUrl: 'https://gateway.example.test',
    accessToken: 'temporary-token',
    profile: 'default',
    runningTimeoutMs: 1000,
    settleMs: 1000,
    keepSession: false,
    outputPath: '',
  };
}

class FakeProbeClient {
  constructor(runningEvent = true, interruptMarkers = []) {
    this.runningEvent = runningEvent;
    this.interruptMarkers = interruptMarkers;
    this.events = [];
    this.calls = [];
    this.closed = false;
  }

  async open() {}

  async request(method, params) {
    this.calls.push({ method, params });
    if (method === 'session.create') {
      return { session_id: 'c0-session' };
    }
    if (method === 'prompt.submit' && params.queued === false && this.runningEvent) {
      this.events.push({
        type: 'thinking.delta',
        session_id: 'c0-session',
        payload: { text: 'working' },
      });
    }
    if (method === 'session.interrupt') {
      for (const marker of this.interruptMarkers) {
        this.events.push({
          type: 'message.complete',
          session_id: 'c0-session',
          payload: { text: marker },
        });
      }
    }
    return { accepted: true };
  }

  async waitForRunningEvent() {
    return this.events[0];
  }

  close() {
    this.closed = true;
  }
}

test('C0 probe exercises the controlled queue contract and cleans up the session', async () => {
  const { runProbe } = await loadProbe();
  const client = new FakeProbeClient(true, ['C0_QUEUE_B_DONE']);
  const fetchCalls = [];
  const report = await runProbe(enabledConfig(), {
    createClient: () => client,
    delayFn: async () => {},
    fetchImpl: async (url, options) => {
      fetchCalls.push({ url, options });
      return {
        ok: true,
        json: async () => ({ messages: [
          { role: 'user', text: 'C0_QUEUE_B_DONE' },
          { role: 'assistant', text: 'C0_QUEUE_A_DONE' },
        ] }),
      };
    },
  });

  assert.equal(report.status, 'completed');
  assert.deepEqual(client.calls.map((call) => call.method), [
    'session.create',
    'prompt.submit',
    'prompt.submit',
    'prompt.submit',
    'session.interrupt',
    'session.delete',
  ]);
  assert.deepEqual(
    client.calls.filter((call) => call.method === 'prompt.submit').map((call) => call.params.queued),
    [false, true, true],
  );
  assert.equal(fetchCalls.length, 1);
  assert.equal(new URL(fetchCalls[0].url).pathname, '/api/hermes/sessions/c0-session');
  assert.deepEqual(report.events[0].payload.text, { type: 'string', length: 7 });
  assert.equal(report.contract.post_interrupt_completion_markers.queueB, true);
  assert.equal(report.contract.history_completion_markers.queueA, true);
  assert.equal(report.contract.history_completion_markers.queueB, false);
  assert.equal(report.contract.interpretation, 'queue_work_observed_after_interrupt');
  assert.equal(client.closed, true);
});

test('C0 probe preserves the failed sample and cleans up before queue setup', async () => {
  const { runProbe } = await loadProbe();
  const client = new FakeProbeClient(false);
  const report = await runProbe(enabledConfig(), {
    createClient: () => client,
    delayFn: async () => {},
    fetchImpl: async () => {
      throw new Error('history should not be fetched');
    },
  });

  assert.equal(report.status, 'failed');
  assert.match(report.error, /no running event observed/);
  assert.deepEqual(client.calls.map((call) => call.method), [
    'session.create',
    'prompt.submit',
    'session.delete',
  ]);
  assert.equal(client.closed, true);
});

class FakeSocket {
  static OPEN = 1;
  static CLOSING = 2;

  constructor() {
    this.readyState = 0;
    this.frames = [];
    this.onopen = undefined;
    this.onmessage = undefined;
    this.onclose = undefined;
    this.onerror = undefined;
  }

  connect() {
    this.readyState = FakeSocket.OPEN;
    this.onopen?.();
  }

  send(frame) {
    this.frames.push(JSON.parse(frame));
  }

  emit(frame) {
    this.onmessage?.({ data: JSON.stringify(frame) });
  }

  close() {
    this.readyState = 3;
    this.onclose?.();
  }
}

test('JSON-RPC probe parses response, event, error, and close frames', async () => {
  const { JsonRpcProbe } = await loadProbe();
  const socket = new FakeSocket();
  const client = new JsonRpcProbe('wss://gateway.example.test/api/hermes/ws', () => socket);
  const opening = client.open();
  socket.connect();
  await opening;

  const createRequest = client.request('session.create', { cols: 100 });
  assert.deepEqual(socket.frames[0], {
    jsonrpc: '2.0',
    id: '1',
    method: 'session.create',
    params: { cols: 100 },
  });
  socket.emit({ jsonrpc: '2.0', method: 'event', params: {
    type: 'message.start',
    session_id: 'c0-session',
    payload: {},
  } });
  socket.emit({ jsonrpc: '2.0', id: '1', result: { session_id: 'c0-session' } });
  assert.deepEqual(await createRequest, { session_id: 'c0-session' });
  assert.equal(client.events[0].type, 'message.start');

  const rejected = client.request('session.interrupt', { session_id: 'c0-session' });
  socket.emit({ jsonrpc: '2.0', id: '2', error: { code: -32000, message: 'interrupt rejected' } });
  await assert.rejects(rejected, (error) => error.message === 'interrupt rejected');

  const closed = client.request('prompt.submit', { session_id: 'c0-session' });
  socket.close();
  await assert.rejects(closed, /C0 WebSocket closed/);
});
