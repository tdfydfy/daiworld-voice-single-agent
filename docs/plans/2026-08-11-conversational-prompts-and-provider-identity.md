---
id: TASK-20260811-CONVERSATIONAL-PROMPTS
created: 2026-08-11
source: user
source_type: text
supersedes: 2026-08-11-approval-voice-response.md
related:
  - 2026-08-10-dynamic-agents-and-voice-response.md
  - 2026-08-11-server-agent-catalog-contract.md
---

# 对话式协议提示与 Provider 身份一致性

## 用户原文

> 出了审批卡，有时候还会出现一些选项卡，这种情况尽量还是不要出现，转为对话内容即可吧。真机一直链接中，前面已经调试过可以打开。记住，真机调试尽量让我来操作，更快更直观。还有一点，现在设置页面中，agent的provider显示为custom，但是选项中又默认是OPENAIAPI，而不是具体的open1或者waw，有点不对。

## 入档时理解

- 核心目标：将审批和澄清选项从独立卡片改成对话流，并让 Agent 顶部身份、设置选项和当前 Session 显示同一个实际 Provider 名称。
- 关键约束：Hermes 的 `approval.respond` / `clarify.respond` 协议仍需正确响应；真机上的交互、听感和视觉验收由用户操作。
- 计划去向：[当前计划](../plan.md)
- 待确认：服务端 Provider 原始配置中 `open1` / `waw` 的字段位置由代码和真实接口契约确认，不凭客户端猜测。
