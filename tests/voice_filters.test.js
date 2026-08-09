const test = require('node:test');
const assert = require('node:assert/strict');
const { echoScore, isLikelyEcho } = require('../web_native/voice_filters.js');

const spoken = '好的，这个功能已经实现了，现在正在为你播放完整结果，当前任务完成以后会处理下一条补充内容。';

test('normal supplement sharing common Chinese characters is not echo', () => {
  const supplement = '这个内容还要补充一下，等你说完以后再处理。';
  assert.ok(echoScore(supplement, spoken) < 0.78);
  assert.equal(isLikelyEcho(supplement, spoken), false);
});

test('ordered phrase copied from spoken output is echo', () => {
  assert.equal(isLikelyEcho('当前任务完成以后会处理下一条补充内容', spoken), true);
});

test('short ordinary acknowledgement is preserved', () => {
  assert.equal(isLikelyEcho('好的', spoken), false);
});

test('real interim speech pauses active playback but echo does not', () => {
  const { shouldPauseForTranscript } = require('../web_native/voice_filters.js');
  assert.equal(shouldPauseForTranscript('这个内容还要补充一下', spoken, true), true);
  assert.equal(shouldPauseForTranscript('当前任务完成以后会处理下一条补充内容', spoken, true), false);
  assert.equal(shouldPauseForTranscript('这个内容还要补充一下', spoken, false), false);
});
