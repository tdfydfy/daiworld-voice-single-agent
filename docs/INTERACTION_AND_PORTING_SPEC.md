# 跨端交互与协议规范

本文定义 HarmonyOS 和 Web Native 必须保持一致的用户语义。平台可以使用不同的录音、播放和 UI API，但不得改变 Hermes 协议含义。

## Agent 与 Session

- Agent 目录来自 Adapter `/api/agents`，其权威来源是 Hermes `/api/status.profiles`；客户端把 `id` 视为不透明值。
- 一次只连接一个 Profile；切换 Agent 时关闭旧连接并创建该 Profile 的新 Session。
- 新对话创建 Hermes Session，但不删除旧历史。
- 历史列表按 20 条增量加载；恢复使用持久 ID，继续工作使用恢复后返回的运行时 ID。
- 当前 Session 的模型切换通过 Hermes `config.set(... --session)` 完成，只有匹配的 `session.info` 才能确认 UI 状态。

## 文本和语音提交

- 空白或仅标点的 ASR final 不创建 Prompt。
- Agent 空闲时发送普通 `prompt.submit`；Agent 繁忙时的补充使用 `queued=true`。
- 用户开口可以暂停当前播报；普通补充提交后继续已接受的播报队列。
- `message.complete` 只完成当前回答，不得无条件抢断前一条尚未播完的回答。
- TTS 必须过滤代码、链接、文件路径和附件指令，附件本身不得被朗读。

## HarmonyOS 控制命令

控制命令按规范化后的精确整句匹配，不做模糊意图推断：

| 命令 | 行为 |
|---|---|
| `关闭话筒` | 保持采集和 ASR，切换到仅系统命令路由；普通 final 本地丢弃 |
| `打开话筒` | 恢复普通对话路由 |
| `停止任务` | 立即清理本地正文、重读、待播和提醒，再发送 `session.interrupt` |
| `退出软件` | 释放本地音频、后台任务和网络连接后退出；不隐式停止远端任务 |

冷启动后必须由用户手动开启一次完整收音链路。麦克风按钮在链路启动后切换与 `关闭话筒` / `打开话筒` 相同的路由状态。

`停止任务`的本地效果是立即且可确认的；Hermes 当前任务和排队工作的最终状态以后续服务端事件为准，客户端不得用本地清理推断服务端已完全收敛。

## 审批与澄清

收到 `approval.request` 后：

- 在 Agent 对话流中显示完整风险命令；
- 只接受去除两端空白和有限句末标点后的精确 `同意` 或 `取消`；
- 直接调用 `approval.respond`，不创建新的 Prompt；
- 未识别输入保持审批等待，不自动批准。

`clarify.request` 同样进入对话流。客户端显示服务端原始问题和选项，用户完整回复通过 `clarify.respond` 提交；客户端不把序号自行解释成语义选项。

## 连接与恢复

1. 用 `X-Voice-Token` 调用 `POST /api/auth/session`。
2. 保存服务端下发的 HttpOnly `voice_session` Cookie。
3. 建立带 Profile 的 JSON-RPC、ASR 或 TTS WebSocket。
4. 收到 `gateway.ready` 后创建或恢复 Session。
5. 收到首个 `gateway.heartbeat` 后启用 70 秒看门狗。

瞬态断线使用有限退避重新鉴权，并恢复当前 `storedSessionId`。恢复路径不得清空消息、重放 Prompt 或把当前本地音频状态伪造成新的 Agent 事件。401/403 不自动重试。

## 附件契约

Agent 可以显式使用 `MEDIA:`，也可以在普通回复中给出受支持后缀的文件引用。Adapter 支持：

```text
MEDIA:/absolute/path/report.docx
sandbox:/absolute/path/report.docx
file:///absolute/path/report.docx
/absolute/path/report.docx
[下载报告](sandbox:/absolute/path/report.docx)
https://example.test/report.docx
```

支持的常见后缀包括：

```text
图片: apng avif bmp gif heic heif ico jpeg jpg png svg tif tiff webp
文档: csv doc docx epub json md odf ods odt pdf ppt pptx rtf txt xls xlsx xml
压缩: 7z gz rar tar zip
```

处理规则：

- 显式 `MEDIA:` 可投递可验证的本地文件或合格 HTTPS 文件地址；
- 非 `MEDIA:` 引用只有后缀在支持列表中才提升为附件；
- 本地路径必须存在、可读、为普通文件并满足大小限制；
- HTTPS 必须无用户名密码、具有文件名，并移除 fragment；
- HTTP、`artifact:` 等未知协议和普通网页链接不提升；
- 消息正文移除已成功转换的原始路径或地址；失败引用保留为文字并记录服务端诊断；
- 客户端只使用 `/api/artifacts/{token}`，不得显示或持久化服务器路径；
- 图片内联显示，其他文件显示名称、类型、大小和打开/下载操作。

## 历史

- `session.list` 提供持久会话列表；
- `session.resume` 恢复上下文并返回新的运行时 ID；
- Adapter REST 聚合真实时间、模型和附件；
- 恢复历史中的附件时重新签发令牌；
- 当前已绑定的会话不得在客户端直接删除；
- 缺失的旧思考或耗时数据保持缺失，不由客户端伪造。

## 客户端不得实现

- Profile 名称、数量或内部 URL 的硬编码；
- 第二套 Agent 上下文、工具路由或审批权限；
- 对普通语音做破坏性命令的模糊匹配；
- 将服务器绝对路径直接交给浏览器或系统文件打开器；
- 因 ASR/TTS 某一路失败而擅自切换用户未选择的语音后端。
