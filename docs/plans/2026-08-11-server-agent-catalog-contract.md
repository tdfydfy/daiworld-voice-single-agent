---
id: TASK-20260811-02
created: 2026-08-11
source: user
source_type: text
supersedes: null
related:
  - 2026-08-10-dynamic-agents-and-voice-response.md
---

# 完善 foxi 服务端 Agent Catalog 契约

## 用户原文

> 你这几个服务都不对啊，我的服务器安装在别名为foxi的服务器上，可以ssh链接，但是需要提升sudo -i才能访问到root目录

> 不，不用保留这个降级处理能力，直接完善服务器端的服务

## 入档时理解

- 核心目标：在 `foxi` 的正式 Adapter 服务中提供 `/api/agents`，消除真机 Agent 目录 HTTP 404。
- 关键约束：访问 root 目录前通过 `sudo -i` 提权；不增加客户端降级逻辑。
- 计划去向：[当前计划](../plan.md)与[关键决策](../decisions.md)。
- 待确认：无。
