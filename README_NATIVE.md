# Daiworld Voice 单 Agent Web — 运行速查

> 当前分支：`native-open-source`
> 开源基线：当前分支首个清理提交

完整能力见 [`README.md`](./README.md)，系统架构见 [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)。

## 1. 产品边界

这是用户直接面对一个 Hermes Agent 的简化形态：

- 用户从 Hermes Profile 目录中手动选择一个 Agent；
- 每次只有一个当前 Profile；
- 不包含主持人、多 Agent 编排、HOST协议或共享上下文；
- 非精确停止的语音默认是下一轮输入；
- 主持人多 Agent Web/HarmonyOS 是并存的另一种产品形态。

## 2. 链路

```text
Web麦克风/播放器
  ↕ HTTPS/WSS
Native Adapter :8844
  ├─ /api/hermes/ws
  ├─ /api/audio/transcribe-stream
  ├─ /api/audio/speak-stream
  ├─ /api/hermes/sessions/{id}
  └─ /api/artifacts/{token}
  ↕
Hermes 官方 Dashboard/API :9119
  └─ default / 全部命名 Profile（请求级隔离）
```

## 3. 本地启动

```bash
export HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN

hermes dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open
```

另开终端：

```bash
VOICE_ACCESS_TOKEN=CHANGE_ME_GATEWAY_TOKEN \
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN \
HERMES_GATEWAY_URL=http://127.0.0.1:9119 \
HERMES_PROFILE_CATALOG_ENABLED=true \
python -m uvicorn app.native_main:app \
  --host 127.0.0.1 --port 8844
```

首次鉴权后读取 `/api/agents` 时，Adapter 从 Hermes 公开的 `/api/status.profiles` 读取一次 Profile ID 并缓存结果。普通请求只读内存；用户点击“刷新列表”时客户端发送 `?refresh=1`，Adapter 才重新读取。Adapter 重启后在下一次目录请求重新建立缓存，不运行分钟级刷新任务。

`HERMES_AGENTS_JSON` 和三个 `HERMES_*_URL` 仅用于旧 Hermes 或回滚，不再作为日常 Profile 注册方式。正式部署只复用 Hermes 已有的单个 Dashboard；旧的 `hermes-native-profile@.service` 和三个 socket 单元不得同时启用。

打开：

```text
http://127.0.0.1:8844/
```

输入你在本地配置的`VOICE_ACCESS_TOKEN`。

## 4. 交互语义

### 普通文字

```text
prompt.submit(sessionId, text)
```

### Agent忙碌或正在播报时的补充

```text
prompt.submit(sessionId, text, queued=true)
```

### 精确停止

只有标准化整句等于：

```text
停止
stop
```

才调用：

```text
session.interrupt
```

### 语音审批

- 同意 → `approval.respond(choice=session)`；
- 拒绝 → `approval.respond(choice=deny)`。

## 5. 文件

Agent显式输出：

```text
MEDIA:/absolute/path/report.pdf
```

Adapter验证Agent默认权限下可读文件并签发15分钟令牌。浏览器不接收服务器路径。

## 6. 历史

```text
session.list(limit=20)
session.resume(storedId)
session.delete(storedId)
GET /api/hermes/sessions/{storedId}?profile=...
```

运行时ID和持久ID必须分开。

## 7. 验证

```bash
python -m pytest -q -o 'addopts='
node --check web_native/app.js
node --test tests/voice_filters.test.js tests/media_speech_filter.test.js
```

最近稳定记录：

```text
Python 10 passed
Node 7 passed
桌面 1280px
移动 390px
```

## 8. 生产入口

```text
https://your-gateway.example/voice-native/
```

生产服务：

```text
daiworld-voice-native.service
```

发布静态资源时必须提升 `index.html` 中的 `app.js?v=N` / `styles.css?v=N`，并验证公网返回的新版本号。
