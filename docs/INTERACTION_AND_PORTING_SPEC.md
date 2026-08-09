# 单 Agent 跨端交互与协议规范

> 版本：Single Agent v21  
> Web 参考实现：`web_native/app.js`  
> 服务边界：`app/native_main.py`  
> 迁移目标：单 Agent HarmonyOS 形态  
> 不适用：主持人多 Agent 版

## 1. 规范目标

Web 和 HarmonyOS 可以使用不同 UI、录音和播放 API，但必须保持相同语义：

- 一个客户端当前只面对一个 Hermes Profile；
- Hermes 官方 Session 是唯一上下文；
- ASR final 自动成为当前 Session 的用户消息；
- 忙碌时普通补充使用 `queued:true`；
- 只有精确整句“停止 / stop”是破坏性中断；
- 播放、收音、Agent任务互不隐式关闭；
- 审批、文件和历史都来自 Hermes 官方能力。

## 2. 产品操作

### 2.1 选择 Agent

客户端显示：

| Profile | 显示名称 | 说明 |
|---|---|---|
| `default` | 赫准行 | 独立 Hermes Profile |
| `hexiaoma` | 赫小码 | 独立 Hermes Profile |
| `hexiaoxin` | 赫小新 | 独立 Hermes Profile |

切换 Profile：

1. 关闭当前 JSON-RPC / ASR / TTS 连接；
2. 清空当前运行时播放；
3. 连接对应 Profile 的 Adapter 路由；
4. 创建新的 Hermes Session；
5. 加载该 Profile 自己的历史。

这不是主持人调度，也不桥接不同 Profile 的上下文。

### 2.2 新对话

- 创建新的 Hermes Session；
- 页面消息清空；
- 不删除旧持久会话；
- 历史栏仍可恢复旧会话。

### 2.3 恢复历史

- 列表首次显示最新 20 个持久会话；
- 到底后再显示 20；
- 点击条目执行 `session.resume`；
- 使用返回的运行时 ID 继续；
- 显示用 REST timestamp/model，不伪造旧耗时；
- 恢复后直接发送或开麦即继续原上下文。

## 3. JSON-RPC Gateway

### 3.1 连接

```text
POST /api/auth/session
  Header: X-Voice-Token=<long-term-access>
  → Set-Cookie: voice_session=<http-only>

WSS /api/hermes/ws?profile=<profile>
```

服务端连接成功后发送 `gateway.ready` 事件。客户端再调用 `session.create` 或 `session.resume`。

### 3.2 请求格式

```json
{
  "jsonrpc": "2.0",
  "id": "42",
  "method": "session.create",
  "params": {"cols": 100}
}
```

响应：

```json
{
  "jsonrpc": "2.0",
  "id": "42",
  "result": {}
}
```

事件：

```json
{
  "jsonrpc": "2.0",
  "method": "event",
  "params": {
    "type": "message.delta",
    "session_id": "runtime-id",
    "payload": {"text": "..."}
  }
}
```

客户端必须用 `session_id` 隔离旧连接和旧 Session 的迟到事件。

## 4. 客户端调用的 Hermes 方法

| 方法 | 关键参数 | 客户端用途 |
|---|---|---|
| `session.create` | `cols` | 新对话 |
| `session.list` | `limit` | 历史列表；20条递增 |
| `session.resume` | `session_id=storedId, cols` | 恢复上下文 |
| `session.delete` | `session_id=storedId` | 删除非活动历史 |
| `prompt.submit` | `session_id, text, queued?` | 文字或ASR final |
| `session.interrupt` | `session_id` | 精确停止 / 停止按钮 |
| `approval.respond` | `session_id, choice` | `session` 或 `deny` |
| `clarify.respond` | `session_id, request_id, answer` | 回答澄清 |

## 5. 客户端处理的 Hermes 事件

| 事件 | 关键字段 | 行为 |
|---|---|---|
| `gateway.ready` | — | create/resume Session |
| `session.info` | `model, provider, profile_name` | 更新运行时身份 |
| `message.start` | — | 创建 Agent 气泡和 SpeechJob |
| `message.delta` | `text/rendered` | 追加正文和TTS文本 |
| `message.complete` | `text/rendered, artifacts?` | 完成正文、耗时和播放队列 |
| `thinking.delta` / `reasoning.delta` | `text` | 更新思考区，不作为正式回答 |
| `tool.start` | `tool_id, name, args_text/context` | 创建工具步骤 |
| `tool.progress` | `name, preview` | 更新工具详情 |
| `tool.complete` | `tool_id, name, duration_s, summary, error` | 完成工具步骤，耗时同行 |
| `approval.request` | `description, command` | 进入审批模态 |
| `clarify.request` | `request_id, question, choices` | 进入澄清模态 |
| `status.update` | `text/kind` | 更新运行状态 |
| `error` | `message` | 结束相关忙碌并显示错误 |

HarmonyOS 不应继续监听旧主持人版的 `host_route / host_message / supplement_queued / agent_result / runtime_refresh` 作为单 Agent 主协议。

## 6. 连续 ASR 协议

### 6.1 连接

```text
WSS /api/audio/transcribe-stream?profile=<profile>
```

鉴权使用前置HTTP会话Cookie，不把长期访问口令放入WebSocket URL。
客户端连接后应**并行**启动麦克风采集，不要先等待 `ready` 再录音。

### 6.2 上行

- 二进制 PCM signed 16-bit little-endian；
- 16 kHz；
- 单声道；
- Web 当前每次发送 6400 bytes；
- `ready` 前允许本地短缓冲；
- 结束时发送：

```json
{"stop": true}
```

### 6.3 下行

Ready：

```json
{"type":"ready"}
```

转写：

```json
{
  "type": "transcript",
  "text": "用户正在说的内容",
  "interim": true,
  "final": false
}
```

Final：

```json
{
  "type": "transcript",
  "text": "完整用户输入",
  "interim": false,
  "final": true
}
```

错误：

```json
{"type":"error","message":"..."}
```

### 6.4 ASR 客户端规则

1. `ready` 前不处理 transcript；
2. partial 更新同一个临时用户气泡；
3. final 不删除重建，直接把同一气泡升级为正式消息；
4. `idle timeout` 是继续等待，不是重连理由；
5. 断线且用户仍开启语音时自动重连；
6. exact STOP 先中断，不提交普通 Prompt；
7. approval pending 时只接受固定同意/拒绝词。

## 7. TTS 协议

### 7.1 流式连接

```text
WSS /api/audio/speak-stream?profile=<profile>
```

鉴权使用前置HTTP会话Cookie。
客户端发送：

```json
{"text":"一段增量文本"}
{"done":true}
{"stop":true}
```

服务端发送：

- JSON 生命周期事件；
- 二进制 PCM signed 16-bit little-endian；
- 24 kHz；
- 单声道。

Web 当前识别的 JSON：

```json
{"type":"start"}
{"type":"end"}
{"type":"fallback"}
{"type":"error","message":"..."}
```

### 7.2 播放排空

收到 `end` 后：

```text
remaining = speechNext - AudioClock.currentTime
```

客户端必须等待 remaining 排空，再释放当前 SpeechJob。HarmonyOS 应用 `AudioRenderer` 的真实队列/回调实现等价语义。

### 7.3 TTS 队列

```text
activeSpeechJob
speechQueue[]
```

- 一次只播放一个 Job；
- 后续 Agent 回答按顺序排队；
- `message.complete` 不等于前一条播完；
- STOP 才清空队列。

### 7.4 MEDIA 文本过滤

Hermes 可能把附件路径拆成：

```text
"MEDIA" → ":/" → "tmp" → "/file.pdf"
```

客户端必须使用**行首有限前缀状态机**过滤 TTS，不能只做 `delta.includes("MEDIA:")`。

## 8. 繁忙输入与补充

```text
append = agentBusy || activeSpeechJob || speechQueue.length > 0
```

普通 final：

```json
{
  "method": "prompt.submit",
  "params": {
    "session_id": "runtime-id",
    "text": "补充内容",
    "queued": true
  }
}
```

UI 必须显示：

```text
豆包流式ASR · 提交中
→ 已排队
```

禁止：

- 用关键词猜 APPEND / REPLACE / SWITCH；
- 每次说话都中断 Agent；
- 把转写气泡删掉却不提交；
- 用模型自述代替 RPC 回执。

## 9. 精确停止

只匹配标准化后的整句：

```text
停止
stop
```

其他内容，例如“不要停止”“停止当前任务后解释一下”“先停一下这个观点”，默认是普通输入，不做破坏性操作。

STOP 行为：

1. `session.interrupt`；
2. 清理本地 SpeechJob 和播放队列；
3. 清理 pending approval；
4. 显示“已停止当前任务”；
5. 不自动发起下一轮模型回答。

## 10. 播放中用户说话

### 10.1 判定

```text
getUserMedia echoCancellation
+ RMS 门槛
+ 播放阶段门槛
+ 连续帧多数
+ 有序文本回音判断
```

### 10.2 行为

真人 partial：

```text
AudioContext.suspend / AudioRenderer.pause
```

final 提交后：

```text
AudioContext.resume / AudioRenderer.resume
```

ASR 误判为回音时才删除预览；普通补充必须保留。

## 11. 审批

### 11.1 屏幕

展示：

- 高风险；
- 简短说明；
- 完整命令；
- “执行已暂停”；
- “允许执行 / 阻止执行”。

### 11.2 语音

允许词：

```text
同意 / 允许 / 可以 / 执行
```

拒绝词：

```text
拒绝 / 阻止 / 取消 / 不要
```

映射：

- 同意 → `approval.respond(choice="session")`；
- 拒绝 → `approval.respond(choice="deny")`。

普通语音不入 Agent 队列；未知词保持 pending。

## 12. 附件

Live `message.complete` 可能带：

```json
{
  "artifacts": [
    {
      "token": "opaque-random-token",
      "name": "report.pdf",
      "mime_type": "application/pdf",
      "size": 12345,
      "is_image": false
    }
  ]
}
```

客户端：

- `is_image=true`：内联预览；
- 其他：下载卡；
- URL：`/api/artifacts/{token}`；
- 下载：`?download=1`；
- 不显示真实服务器路径。

## 13. 历史

### 13.1 列表

```json
{
  "method":"session.list",
  "params":{"limit":20}
}
```

滚到底依次请求 40、60……；因为官方接口无 offset，客户端只新增新出现的后 20 条。

条目显示：

- title；
- preview；
- started_at；
- message_count；
- source。

### 13.2 恢复

并行：

```text
session.resume(storedId)
GET /api/hermes/sessions/{storedId}?profile=...
```

前者恢复运行时上下文，后者提供：

- 持久 timestamp；
- session model；
- display_metadata；
- 历史附件令牌。

### 13.3 元数据

实时：

```text
赫小码 · gpt-5.6-sol
思考 4.4s · 生成 0.3s · 总计 4.6s · 18:59:09
```

历史：

```text
赫小码 · gpt-5.6-sol
总计 7.2s · 2026/08/07 17:51:01
```

历史没有 thinking/generation 持久字段，不得补假数字。

## 14. UI 结构

桌面：

```text
280px历史左栏 | 对话主区
```

移动：

```text
全屏左抽屉
→ 选择后关闭
→ 对话主区
```

回答垂直顺序：

```text
思考
工具
发言
身份/模型
耗时/时间
附件（位于正文和元数据之间）
```

附件实际顺序以 UI 视觉为准：正文 → 附件 → 元数据。

## 15. HarmonyOS 等价实现要求

| Web | HarmonyOS |
|---|---|
| `getUserMedia` | `AudioCapturer` |
| `AudioContext` | `AudioRenderer` |
| Browser WebSocket | `@kit.NetworkKit.webSocket` |
| `localStorage` 口令 | Preferences / HUKS 安全存储 |
| DOM Store | `ConversationStore` |
| `<img>/<a download>` | ArkUI Image / 文件保存与分享 |
| 页面可见性 | Ability 生命周期 + 后台任务 |

移植语义，不移植 DOM 和 ScriptProcessor 代码。

## 16. 跨端验收矩阵

| 场景 | Web 与 HarmonyOS 必须一致 |
|---|---|
| 新 Session | Profile、模型和运行时 ID 正确 |
| 两轮连续对话 | 第二轮知道第一轮 |
| ASR partial/final | 同一气泡升级，不重复 |
| 首句开口 | ready 前 PCM 不丢 |
| Agent 思考中补充 | `queued:true`，不打断当前工作 |
| 播报中补充 | 暂停 → final入队 → 恢复 |
| 回音 | 不提交 Agent 自己的 TTS |
| 普通短句 | 不被回音过滤吞掉 |
| 精确停止 | Agent + TTS 队列停止 |
| 非精确“停止”文本 | 普通下一轮 |
| 工具调用 | 名称、摘要、耗时可见 |
| 高风险审批 | 屏幕和语音均可处理，未知词不批准 |
| 图片 | 内联可见，路径不泄漏 |
| 文件 | 可下载/保存，token 过期后失败 |
| 历史首屏 | 20条 |
| 历史加载更多 | 每次新增20条 |
| 历史继续 | 同一持久上下文 |
| 历史模型/时间 | 与实时同一视觉结构 |
| Profile切换 | 历史和Session隔离 |
| 网络恢复 | 不显示旧连接迟到事件 |
| 后台/锁屏 | 按平台真实能力显示，不虚假在线 |

## 17. 变更规则

任何协议改动必须同步：

1. Web 参考实现；
2. 本规范；
3. 单 Agent HarmonyOS 协议模型；
4. Python/Node 回归；
5. 桌面和移动端真实探针；
6. HarmonyOS DevEco 编译和真机验收。

主持人多 Agent 版有自己的协议，不要求与本规范合并。
