# 单 Agent HarmonyOS 迁移准备与实施计划

> 目标：把已稳定的单 Agent Web v21 迁移为独立 HarmonyOS 原生形态。  
> 约束：不修改主持人多 Agent Web；不在 HarmonyOS `main` 上覆盖主持人版。  
> 源规范：[`INTERACTION_AND_PORTING_SPEC.md`](./INTERACTION_AND_PORTING_SPEC.md)。

## 1. 迁移结论

当前 `daiworld-voice-harmony/main` 是**主持人多 Agent 版**：

- 连接旧 `/voice/ws`；
- 使用 `conversation_id`；
- 处理 `host_route / host_message / supplement_queued / agent_result`；
- 历史来自 `/api/conversations`；
- Controller 保存主持人、主脑、补充和多 Agent 播放状态。

单 Agent v21 使用的是另一套边界：

- Hermes 官方 JSON-RPC；
- `session.create / resume / list / delete`；
- `prompt.submit(queued=true)`；
- 独立 Streaming ASR / TTS WebSocket；
- Hermes审批、工具、附件和历史。

因此这不是“增加几个事件”，而是**新建单 Agent 客户端控制层**。

## 2. 分支策略

### 2.1 当前阶段

在 Harmony 仓库新建独立分支：

```bash
git switch main
git pull --ff-only
git switch -c single-agent-hermes-native
```

规则：

- `main` 继续代表主持人多 Agent 版；
- `single-agent-hermes-native` 代表单 Agent 形态；
- 不把单 Agent 协议直接合并覆盖 `main` 的 Controller；
- 发布名称、包名、图标或页面标题必须可区分。

### 2.2 稳定后再决定

当单 Agent HarmonyOS 经过真机验证后，再评估：

1. 保持双分支/双应用；
2. 拆成两个 entry module；
3. 抽取共享 `audio/network/ui` library。

当前不要提前做双产品统一框架。先让单 Agent 竖向链路可运行。

## 3. 当前可复用资产

只复用平台基础设施，不复用主持人业务状态机。

| 当前文件 | 复用判断 | 说明 |
|---|---|---|
| `entry/src/main/ets/services/PcmAudio.ets` | 高 | `AudioCapturer / AudioRenderer`、16k/24k、队列和late PCM屏障可复用 |
| `BackgroundSession.ets` | 高 | 后台录音连续任务、生命周期可复用，需重新验证单Agent连接 |
| `ConfigStore.ets` | 中 | URL和访问口令可复用；需新增Profile，安全存储后续增强 |
| `Index.ets` | 中 | 页面布局和设置入口可参考；消息、历史、审批、附件需重做 |
| `EntryAbility.ets` | 中高 | Ability启动与Context注入可复用 |
| `VoiceModels.ets` | 低 | 当前是主持人事件模型，应替换为Hermes RPC/ASR/TTS模型 |
| `VoiceGateway.ets` | 低 | 当前单WS旧协议，应拆成三个客户端 |
| `ConversationApi.ets` | 低 | 当前 `/api/conversations`，需改Hermes Session历史 |
| `VoiceController.ets` | 低 | 当前主持人/补充/主脑状态机，不应补丁式兼容 |
| `scripts/verify.mjs` | 中 | 平台/安全检查可保留；事件和状态断言需单Agent化 |

## 4. 目标模块

```text
entry/src/main/ets/
├── models/
│   ├── HermesProtocol.ets
│   ├── VoiceProtocol.ets
│   ├── ArtifactModels.ets
│   └── SingleAgentState.ets
├── services/
│   ├── HermesGatewayClient.ets
│   ├── StreamingAsrClient.ets
│   ├── StreamingTtsClient.ets
│   ├── HermesHistoryClient.ets
│   ├── ArtifactClient.ets
│   ├── SingleAgentController.ets
│   ├── PcmAudio.ets                # 复用并按需修正
│   ├── BackgroundSession.ets       # 复用并实机验证
│   └── ConfigStore.ets             # 增加Profile
├── stores/
│   └── ConversationStore.ets
└── pages/
    ├── Index.ets
    ├── HistoryDrawer.ets
    ├── ApprovalCard.ets
    ├── ActivityTrail.ets
    └── ArtifactCard.ets
```

首个可运行版本可以减少文件数，但职责边界不能合并回一个巨型 Controller。

## 5. 目标状态模型

```ts
connection: 'offline' | 'connecting' | 'online'
selectedProfile: 'default' | 'hexiaoma' | 'hexiaoxin'
runtimeSessionId: string
storedSessionId: string
voiceEnabled: boolean
asrState: 'stopped' | 'connecting' | 'listening' | 'finalizing'
agentBusy: boolean
approvalPending: boolean
playback: 'none' | 'queued' | 'playing' | 'paused_for_user'
messages: ChatMessage[]
history: SessionSummary[]
historyLimit: number
```

不要沿用单 Agent 不需要的状态：

```text
activeAgentKey
pendingSupplementCount
hostAck
agentStage / agentLatest
HOST intent
```

Profile选择是用户直接选择，不是主持人主脑状态。

## 6. 网络客户端拆分

### 6.1 `HermesGatewayClient`

连接：

```text
/voice-native/api/hermes/ws?profile=hexiaoma&token=...
```

职责：

- JSON-RPC request ID；
- pending Promise 表；
- `event` 分发；
- Session ID 过滤；
- reconnect 和迟到事件隔离；
- `session.create/list/resume/delete`；
- `prompt.submit`、`session.interrupt`；
- approval/clarify response。

### 6.2 `StreamingAsrClient`

连接：

```text
/voice-native/api/audio/transcribe-stream?profile=...&token=...
```

职责：

- ready 前 PCM 缓冲；
- 6400-byte chunk；
- partial/final；
- stop frame；
- idle 不自断；
- 断线重连。

### 6.3 `StreamingTtsClient`

连接：

```text
/voice-native/api/audio/speak-stream?profile=...&token=...
```

职责：

- 文本 delta；
- done/stop；
- JSON生命周期与二进制PCM区分；
- Provider end 与设备播放排空分离；
- fallback。

三个 Socket 不能再由一个 `VoiceGateway` 的 `GatewayEvent.type` 开关统一处理。

## 7. Controller 行为

### 7.1 启动

1. 读取 URL、访问口令和 Profile；
2. 连接 Hermes JSON-RPC；
3. 收到 `gateway.ready`；
4. `session.create`；
5. 加载前20个历史会话；
6. 用户主动开启语音后，再启动 ASR 和 AudioCapturer。

### 7.2 ASR final

```text
partial → 同一个用户气泡
final → 判断 approval / exact stop / echo / ordinary
ordinary → prompt.submit(queued=agentBusy||playing||speechQueueNotEmpty)
```

### 7.3 Agent事件

```text
message.start
→ thinking/tool events
→ message.delta
→ message.complete
→ SpeechJob完成
```

### 7.4 用户补充

真人语音期间：

1. 暂停 `AudioRenderer`；
2. ASR final；
3. 提交 `queued:true`；
4. 气泡显示已排队；
5. 恢复 `AudioRenderer`。

### 7.5 STOP

仅精确整句：

```text
停止 / stop
```

执行：

- `session.interrupt`；
- 清空 TTS jobs；
- 停止 renderer；
- 清理 approval；
- 不创建模型回答。

## 8. UI 目标

保持当前 Web 的信息结构，不逐像素复制：

### 桌面/平板

- 左侧常驻历史；
- 主区显示消息、活动、审批和附件；
- 底部文字、语音和停止。

### 手机

- 历史全屏抽屉；
- 主区单列；
- 触控目标至少 44vp；
- 软键盘和安全区不遮挡消息；
- Profile 选择始终可见。

### 消息顺序

```text
思考
工具
正文
附件
Agent · 模型
耗时 · 时间
```

## 9. 历史迁移

### 列表

```text
session.list(limit=20)
→ scroll bottom
→ limit=40
→ 只新增后20
```

### 详情

并行调用：

```text
session.resume(storedId)
GET /api/hermes/sessions/{storedId}?profile=...
```

- resume负责Agent上下文；
- REST负责时间、模型、附件；
- runtime ID与stored ID必须分开。

### 删除

- `session.delete(storedId)`；
- 当前会话删除按钮禁用；
- 其他会话二次确认。

## 10. 附件迁移

- 图片：ArkUI `Image` 预览；
- 文件：文件卡 + 保存/分享；
- 只使用 Adapter token URL；
- 不解析或显示 `MEDIA:/server/path`；
- 过期返回404时显示“附件已过期，请让Agent重新发送”；
- 不在设备端扩大 Agent 文件权限。

## 11. 音频与HarmonyOS平台重点

### 11.1 采集

- 目标 16kHz / mono / PCM s16le；
- 如果设备原生采样率不同，明确重采样；
- ready 前本地缓冲；
- 不因 AgentBusy 关闭 AudioCapturer。

### 11.2 播放

- 24kHz / mono / PCM s16le；
- AudioRenderer 连续队列；
- pause/resume 保留待播数据；
- Provider end 后等 renderer 实际排空；
- STOP 才丢弃队列。

### 11.3 音频焦点

实机覆盖：

- 扬声器；
- 有线耳机；
- 蓝牙耳机；
- 车载蓝牙；
- 来电；
- 其他播放器抢占；
- 录播并行。

### 11.4 后台和锁屏

主持人Harmony已有后台能力只能作为参考，单Agent仍需重新验证：

- ASR WS + Hermes WS + TTS WS 三连接保活；
- 锁屏后 AudioCapturer；
- 后台 TTS；
- 系统回收后的 Session resume；
- 权限被撤销时 `voiceEnabled` 与真实 capture 分离。

## 12. 实施阶段

## Phase 0：隔离形态与契约

**目标：** 不动主持人main，建立单Agent分支和测试契约。

- 新分支 `single-agent-hermes-native`；
- 保存现有主持人静态验证结果；
- 新增单Agent协议fixture；
- `scripts/verify-single-agent.mjs` 检查目标路由和禁止旧HOST事件。

验收：主持人 `main` SHA不变；单Agent分支可独立开发。

## Phase 1：文字 + Session + 历史

- HermesGatewayClient；
- Profile选择；
- create/list/resume/delete；
- message.start/delta/complete；
- 历史20条增量；
- 模型和时间元数据。

验收：两轮连续文字；恢复后继续；三个Profile隔离。

## Phase 2：工具、审批、附件

- thinking/tool/activity；
- approval/clarify；
- image/file token；
- 当前会话禁删。

验收：真实工具、真实审批、PNG/TXT下载。

## Phase 3：流式TTS

- StreamingTtsClient；
- SpeechJob队列；
- PCM24k；
- 排空回调；
- MEDIA过滤。

验收：长回答完整播完；两个快速回答不互相抢断。

## Phase 4：流式ASR

- AudioCapturer；
- ready并行启动与PCM缓冲；
- partial/final气泡；
- idle重连；
- exact STOP。

验收：首句不丢字；连续10轮无需点录音。

## Phase 5：全双工补充和回音

- 回音有序判断；
- 真人语音暂停Renderer；
- final queued:true；
- 恢复上一轮播放；
- 提交状态可见。

验收：补充不被吞；Agent TTS不自触发。

## Phase 6：生命周期和真机

- 后台任务；
- 锁屏；
- 网络切换；
- 蓝牙；
- 音频焦点；
- 进程恢复；
- 安全存储。

验收：目标设备实测报告，不以静态脚本代替。

## 13. 测试策略

### 静态契约

- 必需文件和权限；
- 禁止 Provider Key；
- 禁止旧主持人事件进入 SingleAgentController；
- 三个WS路径；
- runtime/stored Session ID分离；
- queued:true；
- exact STOP；
- history page size 20。

### 可执行Controller测试

- Gateway事件顺序；
- late event隔离；
- ASR partial/final；
- TTS queue；
- pause/resume；
- approval fail-closed；
- history metadata；
- artifact expiry。

### 真实服务探针

- 公网WSS；
- 两轮Session；
- 真实SeedASR final；
- 非空PCM和排空；
- 工具与审批；
- 图片和文件；
- 历史20→40。

### 真机

- 前台连续10分钟；
- 锁屏30分钟；
- Wi-Fi/蜂窝切换；
- 蓝牙；
- 来电；
- 权限撤销；
- 冷启动恢复。

## 14. 当前验证边界

当前服务器：

- `node scripts/verify.mjs`：通过；
- 未安装 DevEco Studio；
- 未安装 HarmonyOS SDK、OHPM、Hvigor、HDC；
- 因此现有主持人客户端和未来单Agent客户端的编译、签名、HAP和真机结论均不能在本机宣称完成。

单 Agent 迁移开始后，每个Phase都应区分：

```text
源码静态通过
DevEco编译通过
模拟器通过
真机前台通过
真机后台/锁屏通过
```

## 15. 不做事项

本轮迁移不做：

- 修改主持人Web；
- 修改主持人HarmonyOS `main`；
- 把HOST协议兼容进SingleAgentController；
- 多Agent共享上下文；
- 主持人音色和StageMic；
- 统一两种产品的业务Controller；
- 未经真机验证就承诺锁屏持续录音。
