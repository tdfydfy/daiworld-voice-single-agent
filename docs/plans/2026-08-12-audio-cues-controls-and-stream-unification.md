---
id: TASK-20260812-AUDIO-CUES-CONTROLS-STREAM-UNIFICATION
created: 2026-08-12
source: user
source_type: text
supersedes: docs/plans/2026-08-12-audio-user-journey-simplification.md
related:
  - docs/plans/2026-08-12-harmony-audio-scenario-strategy.md
  - docs/plans/2026-08-12-audio-scenario-component-decomposition.md
  - docs/plans/2026-08-12-screen-off-audio-regression-recovery.md
---

# 音频提醒、特殊控制与输入输出流统一

## 用户原文

> 一、音频提醒设计：
> 1、用户讲话结束，系统确认收音后，要有收到提示音；
> 2、agent思考且无播报、无用户讲话的情况下，要有思考呼吸音；
> 3、停止任务、错误等场景也有对应警示音；
> 这都是已有功能，不要忘记；
> 二、特殊功能设计：
> 1、停止任务：直接终止当前播报以及正在思考的任务，后续排队任务也一并取消，相当于hermes的/stop命令。你当前2.4的部分理解有误；
> 2、关闭话筒：保持麦克风收音不停，只是暂停asr，因为后面会加一个唤醒功能，麦克风关了就无法实现了。当前的设计是关闭收音，这里也需要调整；
> 3、打开话筒：新增功能，即恢复ASR功能，用于无感启动，减少操作屏幕的次数。当然，首次打开软件是，需要手动启动话筒全链路。
> 三、前期易出问题：
> 1、播放流打架：播放队列打架，语音朗读和音频提醒打架，新消息流式播报和旧消息重播路径不同，分段逻辑导致播报中断破音，亮屏息屏导致播放、收音路径改变；
> 2、输入流打架：收音时断点，导致一句话被拆成几句提交，特别是息屏状态下，应参考播放流，建立统一的录音、ASR策略；

## 入档时理解

- 核心目标：在单一用户旅程下补齐四类音频提醒，纠正停止任务和话筒开关语义，并将所有输入和可听输出分别收敛为一条统一管线。
- 关键约束：`停止任务`等价于 Hermes `/stop`，终止当前播报、当前任务和全部排队任务；“关闭话筒”只暂停会话 ASR，物理采集继续供未来唤醒链路使用；每次冷启动首次开启完整话筒链路必须由用户手动完成。
- 计划去向：[HarmonyOS 音频用户旅程与业务逻辑](../HARMONYOS_AUDIO_USER_JOURNEY.md)、[当前计划](../PLAN.md)。
- 待确认：当前 Hermes `session.interrupt` 是否已经完整实现 `/stop` 的排队任务清理语义；未来本地唤醒引擎、控制词识别和 PCM 分流方式需在实现阶段验证。
