# Native Adapter 运行速查

Native Adapter 是同源 FastAPI 边界层。它不运行 Agent，也不保存第二套会话；正式部署复用 Hermes 官方 Dashboard/API 的 Profile、Session 和历史。

## 链路

```text
HarmonyOS / Web Native
  -> Native Adapter :8844
     -> /api/hermes/ws
     -> /api/audio/transcribe-stream
     -> /api/audio/speak-stream
     -> /api/hermes/sessions/{id}
     -> /api/artifacts/{token}
  -> Hermes Dashboard/API :9119
```

## 启动

Hermes：

```bash
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN \
hermes dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open
```

Adapter：

```bash
VOICE_ACCESS_TOKEN=CHANGE_ME_GATEWAY_TOKEN \
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN \
HERMES_GATEWAY_URL=http://127.0.0.1:9119 \
HERMES_PROFILE_CATALOG_ENABLED=true \
VOICE_ARTIFACT_ALLOW_ALL_READABLE=true \
python -m uvicorn app.native_main:app --host 127.0.0.1 --port 8844
```

首次通过鉴权的 `/api/agents` 请求读取 Hermes `/api/status.profiles` 并缓存。只有显式 `?refresh=1` 或 Adapter 重启后的首次请求会重新发现目录。`HERMES_AGENTS_JSON` 和三个固定 Profile URL 仅用于旧 Hermes 或应急回滚。

## 鉴权

客户端先用 `X-Voice-Token` 调用 `POST /api/auth/session`，换取短期 HttpOnly `voice_session` Cookie。WebSocket 只携带该 Cookie；`HERMES_DASHBOARD_SESSION_TOKEN` 只用于 Adapter 到 Hermes，禁止下发客户端。

生产环境可用 `HERMES_DASHBOARD_SESSION_TOKEN_FILE` 从权限为 `0600` 的 root 文件读取内部令牌。完整说明见 [docs/CREDENTIALS.md](docs/CREDENTIALS.md)。

## 附件

推荐的同权限部署设置 `VOICE_ARTIFACT_ALLOW_ALL_READABLE=true`。此时本地文件边界是 Adapter/Hermes 进程的 OS 读取权限，文件仍必须存在、为普通文件、可读且不超过 `VOICE_ARTIFACT_MAX_BYTES`。如需目录隔离，关闭该开关并配置 `VOICE_ARTIFACT_ROOTS`。

客户端不会收到服务器绝对路径。Adapter 把本地文件或合格的 HTTPS 文件地址转换为 15 分钟有效的随机令牌；远程地址通过令牌端点重定向，不由 Adapter 抓取。

## 生产部署

当前生产服务名为：

```text
daiworld-voice-single-agent.service
```

反向代理必须支持 WebSocket Upgrade、长读写超时、关闭代理缓冲，并保持 `/voice-native/` 尾斜杠语义。静态资源发布后应验证入口实际返回当前资源版本。

## 验证

```bash
python -m pytest -q
node --test tests/*.test.js
node clients/harmony/scripts/verify.mjs
```

部署后再检查服务状态、鉴权、Agent 目录、WebSocket 心跳和真机附件。验收标准见 [docs/NATIVE_TEST_MATRIX.md](docs/NATIVE_TEST_MATRIX.md)。
