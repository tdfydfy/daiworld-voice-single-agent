---
id: TASK-20260812-SCREEN-OFF-AUDIO-REGRESSION
created: 2026-08-12
source: user
source_type: text
supersedes: null
related:
  - docs/plans/2026-08-12-core-file-decomposition-and-screen-off-tts.md
  - docs/plans/2026-08-12-core-voice-architecture-convergence.md
  - docs/plans/2026-08-11-voice-interruption-and-asr-segmentation.md
---

# 息屏录播可靠性回退与恢复

## 用户原文

> 鸿蒙版终端的开发已经走上了新的阶段，但是前面实现的功能现在缺失了，一些修复的问题又复现了，你再看看怎么回事。前期反馈过息屏时，播放会终端、卡顿、吞字，录音会中断，后来升级了亮屏息屏统一的播放和录音逻辑，本来已经修复了，但是刚刚我测试，又重现了。

> 好，梳理具体改进方案。本地的签名还是老版的，没有跟着github的仓库更新，是正常现象。

## 入档时理解

- 核心目标：恢复并固化 HarmonyOS 亮屏/息屏统一的连续录音与播放可靠性，防止结构拆解后旧问题再次出现。
- 关键约束：保留当前薄客户端和模块边界；本地旧签名 HAP 是正常的未跟随 Git 更新产物，不作为异常或回退依据；复杂语音听感仍由用户真机验收。
- 计划去向：[当前计划](../PLAN.md)与[项目路线图](../roadmap.md)。
- 待确认：多后台模式在目标设备上的实际持续任务状态；系统 TTS 在稳定后台所有权下是否仍会报告完成但漏播；复现时录音意图与系统 AudioCapturer 状态是否发生漂移。
