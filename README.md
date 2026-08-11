# Daiworld Voice — Single Agent Edition

> 当前分支：`main`
> 当前基线：Web v21 + HarmonyOS 1.0
> 当前入口：<https://your-gateway.example/voice-native/>

Daiworld Voice 有两种并存的产品形态，单 Agent 版不是主持人多 Agent 版的替代品。

## 产品矩阵

| 产品形态 | 网页版 | HarmonyOS 版 | 定位 |
|---|---|---|---|
| 主持人多 Agent 版 | 已有，保持现状 | 已有，保持现状 | 最终高级形态。主持人负责理解意图、调度多个 Agent、组织互动、共享上下文和分配任务；各 Agent 按主持人的安排工作 |
| 单 Agent 版 | **技术预览** | **最终移动交付面** | 简化形态。用户直接选择并面对一个 Agent，由该 Agent 自行理解、调用工具、完成任务；Web 用于协议验证，HarmonyOS 承担后续产品化 |

本分支只描述和维护**单 Agent 形态**。主持人版网页和主持人版 HarmonyOS 当前不调整，它们拥有独立的交互协议和产品职责。

---

## 一、单 Agent 版的核心亮点

### 1. Hermes 原生，而不是再造 Agent

Web 技术预览和 HarmonyOS 客户端直接复用 Hermes 官方能力：

- `session.create / session.list / session.resume / session.delete`；
- `prompt.submit(queued=true)`；
- `session.interrupt`；
- 工具事件、思考事件、审批和澄清；
- 动态 Agent Catalog、模型、历史、上下文和工具权限。

Native Adapter 的 `/api/agents` 是 Agent 目录权威来源。客户端只保存不透明 Agent ID 和公开身份字段；Web 在本轮稳定后暂停新增功能，后续以 HarmonyOS 真机体验为主。

客户端不维护第二套 Agent 会话，不复制工具调度，不伪造“已调用某个 Agent”。

### 2. 一次开启、持续对话

用户只需开启一次实时语音：

- 麦克风持续采集 PCM16/16k；
- 豆包 SeedASR-2.0 持续返回 partial / final；
- final 自动提交到当前 Hermes Session；
- Agent 思考和播报期间仍能听见用户补充；
- 不需要每轮点击录音、停止、再发送。

### 3. 播报不阻塞下一轮工作

- Agent 流式文本进入豆包流式 TTS；
- 已接受的播报按队列完整播放；
- 用户补充以 Hermes 官方 `queued:true` 进入下一轮；
- 后续 Agent 可在上一轮仍播报时后台工作；
- 新结果不会无条件抢断旧播报。

### 4. 用户说话时暂停，提交后续播

识别到真实用户语音后：

1. 暂停当前 TTS 播放；
2. 保留已排队 PCM 和播放位置；
3. 完成 ASR final；
4. 把同一个转写气泡升级为“提交中 / 已排队 / 已提交”；
5. 提交后恢复上一轮播报。

这比“听到声音就停止一切”更适合补充式对话。

### 5. 回音过滤不吞用户输入

WebRTC AEC 是第一层；文本过滤只做兜底：

- 不使用中文单字集合重合率；
- 使用连续短语和二元组有序重合；
- 短句和模糊输入优先保留；
- 只有确认是播报回音时才删除预览气泡。

### 6. 思考、工具、发言顺序清晰

页面从上到下展示：

```text
思考过程
→ 工具执行（工具名 / 摘要 / 同行耗时）
→ Agent 正式发言
→ Agent · 模型
→ 思考 / 生成 / 总计 / 时间
```

思考、工具和发言使用不同深浅的深色框体，不把过程和结论混成一团。

### 7. 高风险审批进入对话并支持语音

Hermes 发出 `approval.request` 时：

- HarmonyOS 在 Agent 对话气泡中显示完整命令和高风险提示，不再弹出独立审批卡；
- 下一条文字或语音只接受固定的“同意 / 取消”词表，并直接映射到 `approval.respond`；
- 语音同意只作用于当前 Session，不建立永久白名单；
- 未识别内容保持等待，绝不自动批准，也不会作为新的 Agent Prompt。

### 8. Agent 可以发送图片和文件

Agent 显式返回 `MEDIA:<path>` 后：

- 默认只允许 `VOICE_ARTIFACT_ROOTS` 配置的目录；未配置时仅允许 `/tmp`；
- 令牌有效期 15 分钟，单文件默认上限 50 MiB；
- 禁止 `.env`、凭据、SSH和Git目录等敏感路径；
- 图片可内联预览，其他文件默认下载；
- 浏览器不能直接提交服务器路径；
- 分片出现的 `MEDIA:` 不会显示或被 TTS 朗读。

### 9. 复用 Hermes 官方历史

- 桌面端左侧常驻历史栏；
- 移动端全屏左抽屉；
- 首次加载 20 个会话，滚到底再加载 20；
- 使用 `session.resume` 继续原上下文；
- 历史图片和文件重新签发令牌；
- 历史时间和模型来自 Hermes 官方 REST；
- 当前会话禁止删除。

### 10. HarmonyOS 原生语音客户端

`clients/harmony` 已实现可独立安装的 Stage 模型客户端：

- 支持 HarmonyOS 6.1 / API 24，使用 ArkTS 和系统 `CoreSpeechKit`；
- ASR/TTS 可分别选择鸿蒙离线能力或 Adapter 远端能力；
- 本地 TTS 按短首段、长续段增量朗读，降低长回复的首句等待；
- Agent 回复支持单条重读和再次点击停止；重读不创建新会话或重复执行 Agent，并过滤代码、链接、文件路径和 `MEDIA:`；
- 麦克风持续监听，用户开口暂停当前播报，非停止指令完成后恢复播报并排队提交；
- 精确整句“停止/stop”会中断任务与播放，并保留在对话上下文中；
- 远端 ASR/TTS 意外断线后有界退避重连；ASR 保留短 PCM 并合并 1.1 秒内连续 final，TTS 保持待发帧顺序并先排空已收到的 PCM；
- 纯符号 ASR final 在 Adapter 统一归一为空 final，HarmonyOS 使用相同的 Unicode 字母/数字规则防御性拦截，不创建 Hermes Prompt；
- 使用 `AUDIO_RECORDING` 长时任务支持后台和息屏监听，实际持续时间仍受设备电源策略约束；
- 网关、Profile、语音后端、音色、语速和登录状态均持久化保存；
- 历史按 20 条增量加载，恢复真实日期、模型、耗时、思考和工具过程；工具原始 JSON 不进入回复气泡或 TTS。

---

## 二、当前功能清单

| 领域 | 已实现 |
|---|---|
| Agent | Adapter 动态 Agent Catalog；兼容三个既有 Profile 环境变量，每次只直接面对一个 Agent |
| 文字 | 流式回答、工具过程、思考过程、模型与耗时元数据 |
| 语音输入 | Web：SeedASR-2.0 连续 PCM16/16k；HarmonyOS：CoreSpeechKit 离线识别或远端流式 ASR |
| 语音输出 | Web：豆包流式 TTS + Edge fallback；HarmonyOS：系统离线 TTS 增量分段或远端 PCM24k |
| 全双工 | Agent 思考/播报期间持续监听、真人语音暂停/恢复、补充排队 |
| 控制 | 精确整句“停止/stop”才中断；其他语音默认作为下一轮输入 |
| 审批 | HarmonyOS 对话气泡、文字/语音同意或取消、安全失败；Web 技术预览保留既有协议回归 |
| 澄清 | HarmonyOS 将问题和编号选项放入对话，下一条回复直达 `clarify.respond` |
| 文件 | MEDIA 图片预览、附件下载、短期令牌、历史附件恢复 |
| 历史 | 官方 list/resume/delete、20 条增量、完整日期、模型、耗时、思考与工具过程 |
| 后台 | HarmonyOS `AUDIO_RECORDING` 长时任务、息屏监听、连接与语音状态恢复 |
| UI | Web 深色 Linear 桌面/移动端适配；HarmonyOS 原生语音优先界面与持久化设置 |
| 部署 | 一个或多个 Hermes Agent 后端 + 一个同源 FastAPI Adapter + HTTPS/WSS 反代 |

---

## 三、对 Hermes 系统的补充

单 Agent 项目补的是**实时语音和远程客户端能力**，不替代 Hermes 核心。

### Hermes 内部扩展

- 豆包 SeedASR-2.0 `StreamingTranscriptionProvider.open_stream()`；
- `/api/audio/transcribe-stream` 持续 PCM 路由；
- 豆包流式 TTS Provider 与 `/api/audio/speak-stream`；
- Profile 隔离的语音 Provider 配置。

### 同源 Adapter 补充

`app/native_main.py` 只负责：

- 访问口令校验；
- Profile 到 Hermes `serve --isolated` 的映射；
- JSON-RPC、ASR、TTS WebSocket 透明转发；
- Hermes 历史详情聚合；
- MEDIA 文件短期令牌。

### 浏览器补充

`web_native/app.js` 负责：

- 麦克风、PCM、AudioContext；
- continuous ASR 和播放队列；
- 语音暂停/恢复、回音兜底；
- Hermes 事件渲染；
- 历史和附件 UI。

### HarmonyOS 客户端补充

`clients/harmony` 负责：

- ArkTS 原生消息、历史、审批、澄清、附件和 Profile 界面；
- Hermes JSON-RPC 与 ASR/TTS WebSocket 连接；
- CoreSpeechKit 离线识别与朗读、PCM 采集和播放；
- 播报队列、语音暂停/恢复、硬停止和声音状态提示；
- Preferences 长期设置、后台录音任务和生命周期恢复。

### 明确不包含

单 Agent 版不包含：

- 主持人角色；
- 多 Agent 任务编排、共享上下文和 Agent 间互动；
- `HOST:` 意图协议；
- StageMic 全场麦克风调度；
- 自建 Agent 运行数据库；
- 飞书或其他渠道的隐式结果投递。

这些属于主持人多 Agent 版的产品能力，不应被误删或错误移植到单 Agent 版。

---

## 四、架构与移植文档

- [`docs/PRODUCT_FORMS.md`](docs/PRODUCT_FORMS.md)：两种产品形态及四端矩阵。
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：单 Agent v21 当前架构、状态所有权、数据流和安全边界。
- [`docs/INTERACTION_AND_PORTING_SPEC.md`](docs/INTERACTION_AND_PORTING_SPEC.md)：跨端交互、JSON-RPC、ASR/TTS、审批、附件和历史契约。
- [`docs/HARMONYOS_SINGLE_AGENT_MIGRATION.md`](docs/HARMONYOS_SINGLE_AGENT_MIGRATION.md)：只针对单 Agent 鸿蒙形态的迁移分层、文件落点、阶段与验收。
- [`docs/NATIVE_TEST_MATRIX.md`](docs/NATIVE_TEST_MATRIX.md)：单 Agent 专属自动化、真实服务证据、缺口及 HarmonyOS L1-L6 验证阶梯。
- [`README_NATIVE.md`](README_NATIVE.md)：本地启动和运行速查。
- [`clients/harmony/README.md`](clients/harmony/README.md)：HarmonyOS 工程、签名、构建、语音边界和真机检查说明。

旧主持人版架构仍保留在它自己的项目和历史分支中，不以本仓库 `main` 的单 Agent 文档为准。

---

## 五、本地启动

先启动三个 Hermes Profile：

```bash
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN hermes -p default serve --isolated --host 127.0.0.1 --port 9120 --skip-build
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN hermes -p hexiaoma serve --isolated --host 127.0.0.1 --port 9121 --skip-build
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN hermes -p hexiaoxin serve --isolated --host 127.0.0.1 --port 9122 --skip-build
```

再启动 Adapter：

```bash
VOICE_ACCESS_TOKEN=CHANGE_ME_GATEWAY_TOKEN \
HERMES_DASHBOARD_SESSION_TOKEN=CHANGE_ME_INTERNAL_TOKEN \
python -m uvicorn app.native_main:app \
  --host 127.0.0.1 --port 8844
```

打开 `http://127.0.0.1:8844/`。

### HarmonyOS 客户端

使用 DevEco Studio 打开 `clients/harmony`，安装 HarmonyOS 6.1 / API 24 SDK，并在 Signing 页面启用自动签名。依赖安装和命令行构建：

```powershell
cd clients/harmony
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

首次启动时填写 Adapter 的 HTTPS 基地址和 `VOICE_ACCESS_TOKEN`。详细环境变量、产物路径与离线语音边界见 [`clients/harmony/README.md`](clients/harmony/README.md)。

---

## 六、验证

```bash
python -m pytest -q -o 'addopts='
node --check web_native/app.js
node --test tests/voice_filters.test.js tests/media_speech_filter.test.js tests/mobile_ui.test.js
node clients/harmony/scripts/verify.mjs
```

安装 DevEco Studio、HarmonyOS SDK 和 Hvigor 后，再执行 HarmonyOS 完整构建：

```powershell
cd clients/harmony
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

稳定基线验证记录：

```text
Python：26 passed
Node：19 passed
HarmonyOS：17 个 ETS 文件静态校验通过，ArkTS/Hvigor 构建通过
真机：网关登录、持续离线 ASR、增量离线 TTS、暂停/恢复、硬停止、后台任务、历史恢复已验证
Native/HarmonyOS 专属代码：`app/native_main.py`、`app/artifacts.py`、`web_native/`、`clients/harmony/`
桌面/移动端真实服务证据：见 `docs/NATIVE_TEST_MATRIX.md`
```

> 当前开源分支只保留单 Agent Native 运行链路；Hermes Profile 本身需要单独安装和配置。

## 七、生产凭据

Native版的配置示例见 [`.env.example`](./.env.example)，凭据说明见 [`docs/CREDENTIALS.md`](./docs/CREDENTIALS.md)。

- `VOICE_ACCESS_TOKEN`：客户端访问Adapter的口令；
- `HERMES_DASHBOARD_SESSION_TOKEN`：Adapter访问Hermes Profile服务的内部口令；
- `HERMES_AGENTS_JSON`：可选的动态 Agent Catalog；设置后替代下面三个既有 Profile 地址，内部 URL、Provider 和语音指令不会暴露给客户端；
- `HERMES_DEFAULT_URL` / `HERMES_HEXIAOMA_URL` / `HERMES_HEXIAOXIN_URL`：Profile服务地址；
- `HERMES_*_PROVIDER_LABEL`：可选的具体 Provider 显示名，例如 `open1`、`wawapi`；
- 模型供应商凭据由Hermes自身管理，不进入本项目。

## 八、项目记忆

- [项目路线图](docs/roadmap.md)
- [当前计划](docs/plan.md)
- [当前状态](docs/status.md)
- [变更记录](docs/changelog.md)
- [关键决策](docs/decisions.md)
