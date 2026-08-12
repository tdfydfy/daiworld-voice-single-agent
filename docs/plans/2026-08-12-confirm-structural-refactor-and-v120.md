---
id: TASK-20260812-03
created: 2026-08-12
source: user
source_type: text
supersedes: null
related:
  - docs/plans/2026-08-12-core-file-decomposition-and-screen-off-tts.md
  - docs/plans/2026-08-12-thin-client-decomposition-principles.md
---

# 确认结构拆解、问题修复与版本升级

## 用户原文

> 对，先把结构拆开，然后再修复具体问题，对症下药，升级大版本

## 入档时理解

- 核心目标：执行已经讨论确认的薄客户端结构拆解，结构稳定后再定位并修复息屏长文与按钮重读，最后发布新的功能版本。
- 执行顺序：结构拆解和行为回归必须先于问题修复，不把重构与声音行为修改混在同一步。
- 版本解释：在现有 `1.1.2` 基线上按兼容功能版本升级为 `1.2.0`；当前不改变 Hermes 协议和产品形态，因此不按破坏性主版本解释为 `2.0.0`。
- 关键约束：保持薄客户端、有限模块和主流程优先；复杂语音听感仍由用户真机验收。
- 计划去向：[当前计划](../PLAN.md)。
