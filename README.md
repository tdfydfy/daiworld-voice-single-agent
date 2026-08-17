# Daiworld Voice Single Agent

Daiworld Voice Single Agent 是 Hermes 的远程语音客户端。HarmonyOS 是主要移动端产品，Web Native 用于协议预览和调试；两端都直接使用 Hermes 的 Session、工具、审批、历史和模型状态，不复制 Agent 运行时。

当前稳定基线：

- HarmonyOS `1.2.16 (1020016)`；
- Adapter `main` 分支，基线提交 `09f0ed4`；
- 真机已验证图片内联显示和 Word 等文件附件下载；
- 主持人多 Agent 产品不在本仓库范围内。

## 系统组成

```text
HarmonyOS / Web Native
        | HTTPS / WSS
Native Adapter (FastAPI)
        | Hermes JSON-RPC / REST / Audio WebSocket
Hermes Dashboard/API + Profiles
```

- Hermes：拥有 Session、上下文、工具、思考、审批、历史、模型和文件读取权限。
- Adapter：负责访问鉴权、Profile 目录投影、协议代理、心跳、历史补充和附件令牌。
- 客户端：负责 UI、麦克风、ASR/TTS 交互、播放队列和本地生命周期。

详细边界见 [系统架构](docs/ARCHITECTURE.md) 和 [交互与协议规范](docs/INTERACTION_AND_PORTING_SPEC.md)。

## 主要能力

- 从 Hermes `/api/status.profiles` 动态加载 Agent 目录；
- 创建、恢复、分页和删除 Hermes 历史会话；
- 连续语音输入、流式回复、工具过程、审批和澄清；
- HarmonyOS 离线语音或 Adapter 远端 ASR/TTS；
- 通过短期不透明令牌投递图片和常见文档、表格、演示文稿、文本及压缩包；
- 网关心跳、断线恢复和前后台语音生命周期管理。

## 本地启动

先启动 Hermes 官方 Dashboard/API：

```bash
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN \
hermes dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open
```

再启动 Adapter：

```bash
VOICE_ACCESS_TOKEN=CHANGE_ME_GATEWAY_TOKEN \
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN \
HERMES_GATEWAY_URL=http://127.0.0.1:9119 \
HERMES_PROFILE_CATALOG_ENABLED=true \
python -m uvicorn app.native_main:app --host 127.0.0.1 --port 8844
```

打开 `http://127.0.0.1:8844/`。生产参数和凭据边界见 [Native Adapter 运行速查](README_NATIVE.md) 与 [凭据说明](docs/CREDENTIALS.md)。

## HarmonyOS

使用 DevEco Studio 打开 `clients/harmony`，启用自动签名后构建：

```powershell
cd clients/harmony
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

安装、连接和真机检查见 [HarmonyOS 客户端说明](clients/harmony/README.md)。

## 验证

```bash
python -m pytest -q
node --test tests/*.test.js
node clients/harmony/scripts/verify.mjs
```

完整分层和真机用例见 [测试矩阵](docs/NATIVE_TEST_MATRIX.md)。

## 文档入口

| 文档 | 用途 |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | 当前架构、所有权和安全边界 |
| [INTERACTION_AND_PORTING_SPEC.md](docs/INTERACTION_AND_PORTING_SPEC.md) | 跨端交互与协议契约 |
| [NATIVE_TEST_MATRIX.md](docs/NATIVE_TEST_MATRIX.md) | 自动化、集成和真机验收 |
| [CREDENTIALS.md](docs/CREDENTIALS.md) | 凭据与生产配置 |
| [STATUS.md](docs/STATUS.md) | 当前稳定状态与已知边界 |
| [roadmap.md](docs/roadmap.md) | 尚未完成的方向 |
| [decisions.md](docs/decisions.md) | 长期有效的关键决策 |
| [changelog.md](docs/changelog.md) | 已交付里程碑 |
