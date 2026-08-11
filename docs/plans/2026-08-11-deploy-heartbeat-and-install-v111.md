---
id: TASK-20260811-DEPLOY-V111
created: 2026-08-11
source: user
source_type: text
supersedes: null
related:
  - TASK-20260811-GATEWAY-REPLAY
---

# 部署网关心跳并安装 1.1.1

## 用户原文

> 可以部署服务器（ssh foxi ,sudo密码[敏感信息已脱敏]）并安装hap

## 入档时理解

- 核心目标：将网关心跳 Adapter 部署到 `foxi`，并把 `1.1.1` 签名 HAP 安装到已连接真机。
- 关键约束：使用用户明确授权的 SSH 与 sudo 权限；不记录任何凭据；不启动应用，真机声音交互仍由用户操作。
- 计划去向：[当前计划](../plan.md)
- 待确认：真机保持连接超过 5 分钟及断线前后有声重读的验收结果。
