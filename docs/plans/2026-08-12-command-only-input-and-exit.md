---
id: TASK-20260812-COMMAND-ONLY-INPUT-AND-EXIT
created: 2026-08-12
source: user
source_type: text
supersedes: docs/plans/2026-08-12-audio-cues-controls-and-stream-unification.md
related:
  - docs/plans/2026-08-12-audio-user-journey-simplification.md
  - docs/plans/2026-08-12-screen-off-audio-regression-recovery.md
---

# 关闭话筒改为系统指令模式并新增退出软件

## 用户原文

> 再补充一点：我刚刚表述有误，关闭话筒，实际上应该也没有终止ASR，只是终止了ASR后，把用户消息向agent传递消息的链路。此时，依然能识别停止任务、打开话筒、退出软件，这种“系统指令”。是的，我又增加了一个“退出软件”的指令，此时直接关闭软件，避免持续占用系统资源和网络连接。

## 入档时理解

- 核心目标：把“关闭话筒”从暂停 ASR 再次修订为“ASR 持续工作，但普通用户消息不再传给 Agent”的系统指令模式，并新增完整释放本地客户端的“退出软件”指令。
- 关键约束：关闭话筒后物理采集和 ASR 都持续；仅允许识别并执行“停止任务”“打开话筒”“退出软件”，普通语音不得进入 Agent；退出软件释放采集、ASR、播放、后台任务和网络连接。
- 计划去向：[HarmonyOS 音频用户旅程与业务逻辑](../HARMONYOS_AUDIO_USER_JOURNEY.md)、[当前计划](../PLAN.md)。
- 待确认：实现阶段需确认 HarmonyOS 主动终止 UIAbility 的稳定方式，以及 Hermes `session.interrupt` 对排队任务的 `/stop` 等价性。
