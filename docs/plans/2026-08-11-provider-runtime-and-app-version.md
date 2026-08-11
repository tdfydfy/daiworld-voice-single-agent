---
id: TASK-20260811-PROVIDER-VERSION
created: 2026-08-11
source: user
source_type: text
related:
  - 2026-08-11-conversational-prompts-and-provider-identity.md
---

# Provider 运行身份与应用版本

## 用户原文

> 供应商还是不对，还是custom和openai-api，而不是具体的provider。另外，建议设置页面要显示软件版本号，否则不清楚是否更新了。

> 服务器方面的需求，你直接开发部署到服务器即可。通过ssh foxi即可链接，需要sudo的时候，直接输入密码[敏感信息已脱敏]即可。你自己开发，调试，不要等我。真机调试仍由我操作。

## 入档时理解

- 真机反馈推翻了“Provider 已修复”的旧结论；必须以 Hermes 真实接口字段确定当前 Provider，不能按模型名猜测。
- HarmonyOS 设置页显示安装包清单中的版本名和版本码，作为更新确认依据。
- AI 可直接通过 `ssh foxi` 开发、部署并验证服务器改动；sudo 凭据不得进入仓库或项目文档。
- 真机点击、语音、听感和视觉验收继续由用户操作。
- 计划去向：[当前计划](../plan.md)
