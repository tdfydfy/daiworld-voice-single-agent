# 系统架构

本文只描述当前 Single Agent 实现。历史迁移过程由 Git 记录，不作为运行依据；主持人多 Agent 产品不在本仓库范围内。

## 目标

在不复制 Hermes Agent 运行时的前提下，为一个真实 Hermes Profile 提供可持续语音、工具过程、审批、历史恢复和附件投递的远程客户端。

## 拓扑

```text
用户
  <-> HarmonyOS / Web Native
  <-> HTTPS/WSS Native Adapter
  <-> Hermes Dashboard/API
       |- Profiles and Sessions
       |- models, tools, approvals and history
       |- ASR/TTS providers
       `- OS-visible files
```

一次客户端连接只选择一个不透明 Agent ID。切换 Agent 等于切换 Hermes Profile，不桥接上下文，也不构成多 Agent 调度。

## 所有权

### Hermes

Hermes 是 Agent 状态的唯一权威，拥有：

- Session 创建、恢复、删除和持久化上下文；
- Prompt 排队、任务中断、模型与 Provider 状态；
- 思考、工具、回答、审批和澄清事件；
- Profile 目录及其历史数据库；
- Agent 进程的文件系统读取权限；
- 语音 Provider 和密钥。

### Native Adapter

`app/native_main.py` 和 `app/artifacts.py` 负责：

- 校验客户端访问口令并签发短期会话 Cookie；
- 从 Hermes `/api/status.profiles` 投影公开 Agent 目录；
- 代理 JSON-RPC、REST、ASR 和 TTS WebSocket；
- 每 25 秒向客户端发送应用层 `gateway.heartbeat`；
- 补充历史时间、模型和附件元数据；
- 把文件引用转换为短期不透明下载令牌；
- 托管同源 Web Native 静态资源。

Adapter 不理解用户意图，不调度工具，不保存第二套会话，也不向客户端暴露 Hermes 内部 URL、路径或密钥。

### 客户端

HarmonyOS 和 Web Native 负责：

- UI、麦克风权限、PCM 采集和播放队列；
- ASR partial/final、TTS 暂停恢复和本地输出清理；
- Agent、历史、审批、澄清和附件展示；
- 当前 Session 的模型选择；
- 设备前后台、音频路由和断线恢复。

HarmonyOS 是主要移动产品；Web Native 是协议预览和诊断入口。

## 主要接口

| 接口 | 用途 |
|---|---|
| `POST /api/auth/session` | 长效访问口令换取短期 HttpOnly Cookie |
| `GET /api/agents[?refresh=1]` | Profile 公开目录和显式刷新 |
| `GET /api/health` | Adapter 与目录状态 |
| `GET /api/hermes/model/options` | 当前 Profile 可选模型公开信息 |
| `WS /api/hermes/ws` | Hermes JSON-RPC 与网关心跳 |
| `WS /api/audio/transcribe-stream` | 远端流式 ASR |
| `WS /api/audio/speak-stream` | 远端流式 TTS |
| `GET /api/hermes/sessions/{id}` | 历史详情、时间和附件重签 |
| `GET /api/artifacts/{token}` | 图片内联、文件下载或 HTTPS 重定向 |

首次鉴权后的 `/api/agents` 请求读取 Hermes 目录并放入进程内缓存。普通请求不轮询；只有 `?refresh=1` 或 Adapter 重启后的首次请求重新读取。

## Session 与恢复

下列身份不可混用：

| 名称 | 含义 |
|---|---|
| `profile` | Agent 身份和隔离环境 |
| `sessionId` | 当前连接的运行时 Session ID |
| `storedSessionId` | Hermes 持久会话 ID，用于历史和恢复 |
| `artifact token` | 单个附件的短期访问凭据 |

瞬态网关断线时，客户端重新鉴权并以 `storedSessionId` 恢复当前上下文。恢复不得清空已有消息、重放 Prompt 或强制关闭独立的本地播放状态。401/403 是鉴权终止错误。

## 语音状态

ASR、Agent 任务和 TTS 是独立生命周期：

```text
voice chain:  not_started | running | exiting
input route:  conversation | system_commands_only
agent:        idle | busy | approval | clarification
playback:     none | queued | playing | paused_for_user
```

每次冷启动由用户手动开启一次完整收音链路。关闭/打开话筒只切换输入路由，不重建采集和识别；用户正常补充可以暂停当前播报并在提交后恢复。`停止任务`先立即清理本地输出，再发送 `session.interrupt`；服务端排队收敛不由客户端伪造确认。

## 附件模型

Adapter 可识别以下 Agent 回复引用：

- `MEDIA:/absolute/path` 或 `MEDIA:https://.../file.ext`；
- `sandbox:/absolute/path`；
- `file:///absolute/path`；
- 裸绝对路径；
- 包装上述引用的 Markdown 链接；
- 文件名后缀属于支持列表的 HTTPS 链接。

常见图片、文档、表格、演示文稿、文本和压缩包按后缀提升为附件。普通网页链接、HTTP、带凭据的 HTTPS、未知协议和无支持后缀的文本保持普通文字。

本地文件必须存在、是普通文件、对 Adapter/Hermes 可读，并且不超过 `VOICE_ARTIFACT_MAX_BYTES`。部署可选择：

- `VOICE_ARTIFACT_ALLOW_ALL_READABLE=true`：以进程的 OS 读取权限为边界；
- 关闭该开关并设置 `VOICE_ARTIFACT_ROOTS`：只允许指定目录，并额外拒绝常见敏感路径。

无论采用哪种模式，客户端只收到随机令牌、文件名、MIME、大小和图片标记，永远不收到服务器绝对路径。令牌默认 15 分钟有效并只存内存；历史恢复时重新签发。本地文件由 Adapter 返回，HTTPS 附件经令牌端点重定向给客户端，Adapter 不代为抓取远端内容。

## 部署边界

推荐拓扑：

```text
Hermes Dashboard/API        127.0.0.1:9119
Native Adapter              127.0.0.1:8844
systemd                     daiworld-voice-single-agent.service
public reverse proxy        /voice-native/
```

反向代理需支持 WebSocket Upgrade、长读写超时、关闭代理缓冲并保持尾斜杠语义。客户端访问口令、Hermes 内部令牌和 Provider 密钥必须分层保存，详见 [CREDENTIALS.md](./CREDENTIALS.md)。

## 明确不包含

- 主持人角色、多 Agent 编排或 Profile 间共享上下文；
- 客户端侧工具调度、权限表或历史数据库；
- 通过 Web UI 上传任意服务器路径；
- 对所有硬件提供同等的外放回音消除保证；
- 用本地 UI 状态宣称 Hermes 服务端任务已经完成或队列已清空。
