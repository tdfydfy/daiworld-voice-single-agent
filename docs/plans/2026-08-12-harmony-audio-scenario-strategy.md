---
id: TASK-20260812-HARMONY-AUDIO-SCENARIO-STRATEGY
created: 2026-08-12
source: user
source_type: text
supersedes: null
related:
  - docs/plans/2026-08-12-screen-off-audio-regression-recovery.md
---

# HarmonyOS 录播与屏幕场景策略汇总

## 用户原文

> 把录音、播放、亮屏、息屏等不同场景下的各种策略做一个汇总，根据第一性原理，从高层目的往下梳理结构。

## 入档时理解

- 核心目标：从持续语音对话的产品目的出发，统一定义录音、播放、亮屏、息屏、打断、路由变化和故障恢复策略，避免继续按场景堆叠局部补丁。
- 关键约束：屏幕状态不得成为 ASR/TTS 业务分支；用户意图、平台真实状态和 UI 展示必须分离；策略需要直接指导当前息屏录播 P0 的实现和验收。
- 计划去向：[HarmonyOS 音频策略](../HARMONYOS_AUDIO_STRATEGY.md)、[当前计划](../PLAN.md)。
- 待确认：组合后台任务在目标真机上的实际行为，以及稳定后台所有权后系统 TTS 是否仍会报告完成但实际漏播。
