const test = require('node:test');
const assert = require('node:assert/strict');
const {
  echoScore,
  isLikelyEcho,
  hasSemanticContent,
  isCloseMicCommand,
  splitThinkingLines,
} = require('../web_native/voice_filters.js');

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

test('punctuation-only transcripts are rejected before submission', () => {
  assert.equal(hasSemanticContent('。'), false);
  assert.equal(hasSemanticContent(' ，……！？ '), false);
  assert.equal(hasSemanticContent('---'), false);
  assert.equal(hasSemanticContent('好的。'), true);
  assert.equal(hasSemanticContent('版本 2.0'), true);
});

test('close microphone command is exact and does not swallow normal speech', () => {
  assert.equal(isCloseMicCommand('闭麦'), true);
  assert.equal(isCloseMicCommand('闭麦。'), true);
  assert.equal(isCloseMicCommand('关闭麦克风'), true);
  assert.equal(isCloseMicCommand('不要闭麦'), false);
  assert.equal(isCloseMicCommand('闭麦以后继续说'), false);
});

test('thinking text is split by explicit lines and complete sentences', () => {
  assert.deepEqual(
    splitThinkingLines('先检查配置。再确认服务\n最后执行验证'),
    ['先检查配置。', '再确认服务', '最后执行验证'],
  );
  assert.deepEqual(splitThinkingLines('正在分析一个尚未结束的增量'), ['正在分析一个尚未结束的增量']);
  assert.deepEqual(splitThinkingLines('第一步！第二步？第三步'), ['第一步！', '第二步？', '第三步']);
});
