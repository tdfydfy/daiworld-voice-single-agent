const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionQueue() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/SpeechPlaybackQueue.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/^export type .*;\r?\n/gm, '');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(/\?:\s*PlaybackJob(?=;)/g, '');
  source = source.replace(
    /:\s*(?:void|boolean|number|string|PlaybackKind|PlaybackPriority|PlaybackJob)(?=\s*[,)=;{])/g,
    '',
  );
  source = source.replace(/:\s*PlaybackJob\[\](?=\s*[,)=;{])/g, '');
  source = source.replace(/:\s*PlaybackJob\s*\|\s*undefined(?=\s*[,)=;{])/g, '');
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('stale playback completion cannot advance a new epoch', async () => {
  const { SpeechPlaybackQueue } = await loadProductionQueue();
  const queue = new SpeechPlaybackQueue();
  queue.bindEpoch(1);
  const oldJob = queue.enqueue(1, 'assistant', 20, 'old');
  queue.bindEpoch(2);
  const newJob = queue.enqueue(2, 'assistant', 20, 'new');

  queue.complete(1, oldJob);
  assert.equal(queue.activeJob().id, newJob);
});

test('accepted and thinking cues cannot overlap active speech', async () => {
  const { SpeechPlaybackQueue } = await loadProductionQueue();
  const queue = new SpeechPlaybackQueue();
  queue.bindEpoch(3);
  const speech = queue.enqueue(3, 'assistant', 20, '正文');

  assert.ok(speech.length > 0);
  assert.equal(queue.enqueue(3, 'cue', 10, '', 'accepted', true), '');
  assert.equal(queue.enqueue(3, 'cue', 10, '', 'thinking', true), '');
  assert.equal(queue.activeJob().id, speech);
});

test('stop cue preempts lower-priority output', async () => {
  const { SpeechPlaybackQueue } = await loadProductionQueue();
  const queue = new SpeechPlaybackQueue();
  queue.bindEpoch(4);
  queue.enqueue(4, 'assistant', 20, '正文');
  const stop = queue.enqueue(4, 'cue', 40, '', 'stop');

  assert.equal(queue.activeJob().id, stop);
  assert.equal(queue.activeJob().cue, 'stop');
});

test('non-preempting output is rejected instead of becoming an orphan job', async () => {
  const { SpeechPlaybackQueue } = await loadProductionQueue();
  const queue = new SpeechPlaybackQueue();
  queue.bindEpoch(5);
  const active = queue.enqueue(5, 'assistant', 20, 'first');

  assert.equal(queue.enqueue(5, 'protocol', 20, 'second'), '');
  assert.equal(queue.activeJob().id, active);
  queue.complete(5, active);
  assert.equal(queue.hasOutput(), false);
});
