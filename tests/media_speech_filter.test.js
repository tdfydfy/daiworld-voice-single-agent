const test = require('node:test');
const assert = require('node:assert/strict');
const { createMediaSpeechFilter } = require('../web_native/media_speech_filter.js');

test('suppresses split MEDIA line but preserves following speech', () => {
  const filter = createMediaSpeechFilter();
  const chunks = ['MEDIA', ':/', 'tmp', '/x.png', '\n', '文件已经生成'];
  const output = chunks.map(chunk => filter.push(chunk)).join('') + filter.flush();
  assert.equal(output, '文件已经生成');
});

test('streams ordinary text after bounded prefix probe', () => {
  const filter = createMediaSpeechFilter();
  const chunks = ['结果', '已经', '完成。'];
  const output = chunks.map(chunk => filter.push(chunk)).join('') + filter.flush();
  assert.equal(output, '结果已经完成。');
});

test('preserves prose beginning with MEDIA when it is not a directive', () => {
  const filter = createMediaSpeechFilter();
  const output = filter.push('MEDIA is a label') + filter.flush();
  assert.equal(output, 'MEDIA is a label');
});
