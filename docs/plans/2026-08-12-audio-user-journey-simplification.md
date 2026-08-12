---
id: TASK-20260812-AUDIO-USER-JOURNEY-SIMPLIFICATION
created: 2026-08-12
source: user
source_type: text
supersedes: docs/plans/2026-08-12-audio-scenario-component-decomposition.md
related:
  - docs/plans/2026-08-12-harmony-audio-scenario-strategy.md
  - docs/plans/2026-08-12-screen-off-audio-regression-recovery.md
---

# 以用户旅程简化音频业务分类

## 用户原文

> 太复杂了，我们先不用非常具体的代码接口实现，只考虑逻辑过程，以用户视角看，有哪些场景，然后再去归类，梳理，汇总业务逻辑。比如：1、用户发起对话，2、等待agent反应，3、聆听播报，4、停止/补充任务，所有场景都是上述的循环，当然还有播报/收音/等待时亮屏/息屏，还有特殊指令：停止任务、关闭话筒。（建议将“停止”升级为“停止任务”，否则识别精度不够，容易误触发或难以触发）。你需要按照这个逻辑，去梳理每个环节、每个变化，前后台需要什么设置、如何切换、错误如何应对。你要明白，当一个分类方式分出太多类的时候，说明分类的维度不够聪明。

## 入档时理解

- 核心目标：以用户对话循环作为唯一业务分类主轴，说明各环节、转换、客户端/服务端职责、运行环境变化和错误处理。
- 关键约束：暂不下钻具体代码接口；亮屏/息屏、应用前台/后台、收音/播报是覆盖主流程的正交状态，不得扩展成大量业务场景；控制语义收敛为“停止任务”和“关闭话筒”。
- 计划去向：[HarmonyOS 音频用户旅程与业务逻辑](../HARMONYOS_AUDIO_USER_JOURNEY.md)、[当前计划](../PLAN.md)。
- 待确认：“停止任务”目标语义形成后，具体控制词兼容期和代码迁移在后续实现轮次确定。
