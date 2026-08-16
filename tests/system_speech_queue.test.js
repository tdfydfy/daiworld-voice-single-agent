const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadProductionQueue() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/SystemSpeechQueue.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(/:\s*string\[\](?=\s*[,)=;{])/g, '');
  source = source.replace(/:\s*(?:void|boolean|number|string)(?=\s*[,)=;{])/g, '');
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('pause resumes from the complete active system TTS segment', async () => {
  const { SystemSpeechQueue } = await loadProductionQueue();
  const queue = new SystemSpeechQueue();
  const activeSegment = 'This complete short segment must be replayed after interruption.';

  queue.activate(activeSegment);
  queue.enqueue('The following segment remains queued.');
  queue.pause(2.0);

  assert.equal(queue.takeResumeText(), activeSegment);
  assert.equal(queue.takeNext(), 'The following segment remains queued.');
});

test('pause does not estimate a character offset from speech rate', async () => {
  const { SystemSpeechQueue } = await loadProductionQueue();
  const segment = '0123456789abcdefghijklmnopqrstuvwxyz';

  for (const speechRate of [0.5, 1.0, 2.0]) {
    const queue = new SystemSpeechQueue();
    queue.activate(segment);
    queue.pause(speechRate);
    assert.equal(queue.takeResumeText(), segment);
  }
});
