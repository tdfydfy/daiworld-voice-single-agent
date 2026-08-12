---
id: TASK-20260812-02
created: 2026-08-12
source: user
source_type: text
supersedes: null
related:
  - docs/plans/2026-08-12-core-file-decomposition-and-screen-off-tts.md
---

# 薄客户端拆解原则

## 用户原文

> 我理解中，这个应用就是一个很薄的壳，核心功能就是调用后端hermes agent，前端分别有鉴权、设置、输入、输出等功能，应该是结构简单，思路清晰，不应该混成一堆。具体拆分方法你来定，但是我认为不要做得太复杂臃肿，不要过分纠结小的corner case，你认为呢？

## 入档时理解

- 核心目标：把 HarmonyOS 应用恢复为围绕 Hermes Agent 的薄客户端，模块职责直观，避免核心功能继续堆积在单一控制器。
- 设计授权：具体拆分方法由 AI 根据现有状态所有权决定。
- 关键约束：有限模块、简单依赖、小步拆分；不引入事件总线、通用依赖注入框架、重复仓储/用例层或为少量 corner case 建立额外抽象。
- 范围优先级：只优先处理影响主流程、正确性、安全、会话连续性、音频完整性和明确验收的问题。
- 执行边界：本条确认设计原则和方案裁量，不改变此前“方案讨论确认后再执行代码拆分”的约束。
- 计划去向：[当前计划](../PLAN.md)；关联[核心文件拆解任务](2026-08-12-core-file-decomposition-and-screen-off-tts.md)。
