---
id: TASK-20260812-AUDIO-SCENARIO-COMPONENT-DECOMPOSITION
created: 2026-08-12
source: user
source_type: text
supersedes: null
related:
  - docs/plans/2026-08-12-harmony-audio-scenario-strategy.md
  - docs/plans/2026-08-12-screen-off-audio-regression-recovery.md
---

# 音频场景与组件逻辑拆解

## 用户原文

> 我要看到具体的场景划分以及相应的各个组件的逻辑，这样就可以很好地拆解代码

## 入档时理解

- 核心目标：把音频策略下钻为可直接编码的场景目录、组件职责、调用顺序和现有代码迁移表，让后续重构可以按独立场景和独立组件逐步验收。
- 关键约束：场景需要覆盖录音、播放、双工、亮屏/息屏、控制、路由和故障；组件必须有单一状态所有者和明确禁止依赖；不引入通用事件总线或大规模框架。
- 计划去向：[场景与组件拆解蓝图](../HARMONYOS_AUDIO_COMPONENT_DESIGN.md)、[当前计划](../PLAN.md)。
- 待确认：目标真机对组合后台模式的实际支持，以及系统 TTS 在组合租约稳定后是否仍需升级为 PCM 自管播放。
