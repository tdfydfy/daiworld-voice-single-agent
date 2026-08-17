const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionState() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/StopTaskState.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(/:\s*(?:number|string|boolean|void)(?=\s*[,)=;{])/g, '');
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('stop task status distinguishes local cleanup from remote confirmation', async () => {
  const { StopTaskState } = await loadProductionState();

  assert.equal(
    StopTaskState.localStoppedPendingConfirmation(),
    '本地已停止，任务/队列状态待确认',
  );
  assert.equal(
    StopTaskState.requestConfirmedPendingConfirmation(),
    '停止请求已确认，任务/队列状态待确认',
  );
  assert.equal(
    StopTaskState.requestFailedPendingConfirmation(),
    '本地已停止，停止请求失败，任务/队列状态待确认',
  );
});

test('only the newest stop request may update its confirmation state', async () => {
  const { StopTaskState } = await loadProductionState();
  const state = new StopTaskState();

  const firstRequest = state.beginRequest();
  const secondRequest = state.beginRequest();
  assert.equal(state.isCurrentRequest(firstRequest), false);
  assert.equal(state.isCurrentRequest(secondRequest), true);

  state.invalidatePendingRequest();
  assert.equal(state.isCurrentRequest(secondRequest), false);
});
