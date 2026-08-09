# 单 Agent HarmonyOS 迁移实施计划

> **For Hermes:** 实施时加载 `subagent-driven-development` 和 `realtime-voice-agent-integration`，按任务逐项执行与复审。

**目标：** 在不修改主持人 HarmonyOS `main` 的前提下，创建可独立运行的单 Agent HarmonyOS 原生客户端，对齐 Web v21 的 Hermes Session、连续ASR、流式TTS、审批、附件和历史能力。

**架构：** 从 Harmony `main` 新建 `single-agent-hermes-native` 分支，复用原生音频、后台和配置基础模块，替换主持人 Gateway/Controller。客户端分别连接 Hermes JSON-RPC、Streaming ASR、Streaming TTS 三条WSS，Adapter保持当前协议。

**技术栈：** ArkTS、ArkUI、HarmonyOS API 12、AudioCapturer、AudioRenderer、NetworkKit WebSocket、Preferences/HUKS、Hermes TUI Gateway JSON-RPC、pytest、Node静态契约。

---

## Task 0：建立独立产品分支

**目标：** 单Agent开发不覆盖主持人HarmonyOS main。

**仓库：** 单Agent产品仓库的HarmonyOS客户端目录

**步骤：**

1. 验证 `main` 工作树干净：

```bash
git status --short --branch
node scripts/verify.mjs
```

期望：`main...origin/main`，静态验证通过。

2. 创建分支：

```bash
git switch main
git pull --ff-only
git switch -c single-agent-hermes-native
```

3. 新建 `docs/SINGLE_AGENT_PRODUCT.md`，链接单Agentv21规范。
4. 提交：

```bash
git add docs/SINGLE_AGENT_PRODUCT.md
git commit -m "docs: establish single-agent HarmonyOS product branch"
```

## Task 1：建立协议模型和失败契约

**目标：** 先让旧主持人协议在单Agent验证器中失败。

**文件：**

- Create: `scripts/verify-single-agent.mjs`
- Create: `entry/src/test/SingleAgentProtocol.test.ets`
- Create: `entry/src/main/ets/models/HermesProtocol.ets`
- Create: `entry/src/main/ets/models/VoiceProtocol.ets`
- Create: `entry/src/main/ets/models/SingleAgentState.ets`

**失败检查至少包含：**

- 三条目标WSS路径；
- `session.create/list/resume/delete`；
- `prompt.submit` 的 `queued`；
- `session.interrupt`；
- `approval.respond / clarify.respond`；
- `message/thinking/tool/approval`事件；
- 历史PAGE_SIZE=20；
- runtime/stored Session ID不同字段；
- 禁止 `host_route / host_message / supplement_queued / agent_result` 出现在 SingleAgentController。

**运行：**

```bash
node scripts/verify-single-agent.mjs
```

期望：因实现不存在而FAIL。

## Task 2：实现 Hermes JSON-RPC 客户端

**目标：** 跑通文字、Session和事件流。

**文件：**

- Create: `entry/src/main/ets/services/HermesGatewayClient.ets`
- Modify: `entry/src/main/ets/models/HermesProtocol.ets`
- Test: `entry/src/test/HermesGatewayClient.test.ets`

**实现：**

- request ID单调递增；
- pending Promise表；
- WSS连接：`POST /api/auth/session`换取Cookie后连接`/api/hermes/ws?profile=`；
- JSON-RPC response和`method=event`分离；
- runtime Session ID过滤；
- close时reject全部pending；
- `session.create`和`prompt.submit`封装。

**验收：**

- 真实服务`gateway.ready`；
- 两轮文字连续；
- 第二轮保留第一轮上下文；
- 旧Socket迟到事件不显示。

## Task 3：实现历史与Profile

**目标：** 对齐Web v21历史和元数据。

**文件：**

- Replace/Retire: `entry/src/main/ets/services/ConversationApi.ets`
- Create: `entry/src/main/ets/services/HermesHistoryClient.ets`
- Create: `entry/src/main/ets/pages/HistoryDrawer.ets`
- Modify: `ConfigStore.ets`
- Modify: `SingleAgentState.ets`

**实现：**

- Profile：`default / hexiaoma / hexiaoxin`；
- `session.list(limit=20)`；
- 滚底40/60；
- `session.resume` + REST详情并行；
- `session.delete`确认；
- 当前会话禁删；
- 历史模型、timestamp和总耗时；
- runtime/stored ID分离。

**验收：**

```text
初始20 → 滚底40 → 再滚60
恢复旧会话 → 继续追问正确
Profile切换 → 历史隔离
```

## Task 4：实现消息、工具和审批UI

**目标：** 无语音时已经是完整Hermes客户端。

**文件：**

- Create: `ConversationStore.ets`
- Create: `ActivityTrail.ets`
- Create: `ApprovalCard.ets`
- Create: `ArtifactCard.ets`
- Modify: `Index.ets`
- Create: `SingleAgentController.ets`

**事件：**

- `message.start/delta/complete`；
- `thinking.delta / reasoning.delta`；
- `tool.start/progress/complete`；
- `approval.request`；
- `clarify.request`；
- `session.info / status.update / error`。

**视觉顺序：**

```text
思考 → 工具 → 发言 → 附件 → Agent/模型 → 耗时/时间
```

**验收：**

- 真实工具名称和耗时；
- 高风险命令完整可见；
- 未确认不执行；
- 澄清选择正确回传。

## Task 5：拆出流式TTS客户端

**目标：** 完整播放Agent回答，不被后续结果抢断。

**文件：**

- Create: `StreamingTtsClient.ets`
- Modify: `PcmAudio.ets`
- Modify: `SingleAgentController.ets`
- Test: `StreamingTtsQueue.test.ets`

**实现：**

- WSS `/api/audio/speak-stream`；
- text/done/stop；
- JSON和binary分离；
- SpeechJob队列；
- Provider end后等待Renderer排空；
- MEDIA行首分片过滤；
- fallback。

**验收：**

- 长回答完整；
- 两个快速结果顺序播放；
- MEDIA路径不朗读；
- STOP立即清空。

## Task 6：拆出Streaming ASR客户端

**目标：** 一次开麦持续partial/final。

**文件：**

- Create: `StreamingAsrClient.ets`
- Modify: `PcmAudio.ets`
- Modify: `SingleAgentController.ets`
- Test: `StreamingAsrState.test.ets`

**实现：**

- WSS `/api/audio/transcribe-stream`；
- AudioCapturer与WS ready并行；
- ready前PCM缓冲；
- 6400-byte chunk；
- partial/final同一气泡；
- stop frame；
- idle不销毁Session；
- 用户意愿和真实采集状态分离。

**验收：**

- 开口头两个字不丢；
- 10轮无需重复点麦；
- 30秒静音不反复重连。

## Task 7：全双工补充、回音和暂停恢复

**目标：** 对齐Web v21最关键实验成果。

**文件：**

- Create: `EchoFilter.ets`
- Modify: `SingleAgentController.ets`
- Modify: `PcmAudio.ets`
- Test: `FullDuplexSupplement.test.ets`

**失败fixture：**

```text
Agent播报：好的，这个功能已经实现了……
用户补充：这个内容还要补充一下，等你说完以后再处理。
```

旧单字重合算法会误杀；新有序二元组不得误杀。

**实现：**

- partial确认真人后pause Renderer；
- final普通输入queued=true；
- 同一气泡显示提交中/已排队；
- submit后resume Renderer；
- echo才删除预览；
- 短句优先保留。

**验收：**

- pause/resume真实发生；
- 气泡保留；
- 后续Agent轮启动；
- TTS不被ASR当作用户输入。

## Task 8：精确STOP与语音审批

**目标：** 破坏性控制fail-closed。

**文件：**

- Modify: `SingleAgentController.ets`
- Test: `VoiceControl.test.ets`

**STOP矩阵：**

| 输入 | 结果 |
|---|---|
| `停止` | interrupt + 清TTS队列 |
| `stop` | interrupt + 清TTS队列 |
| `不要停止` | 普通prompt |
| `停止当前任务后解释一下` | 普通prompt |

**审批：**

- 固定同意/拒绝词；
- `session` / `deny`；
- 未知词保持pending；
- exact STOP优先。

## Task 9：附件保存和分享

**目标：** HarmonyOS可查看Agent文件。

**文件：**

- Create: `ArtifactClient.ets`
- Create: `ArtifactCard.ets`
- Test: `ArtifactClient.test.ets`

**实现：**

- image inline；
- 文件下载到应用沙箱；
- 调用系统保存/分享；
- token 404提示重新发送；
- 不接受服务器路径参数。

**验收：**

- PNG预览；
- TXT/PDF下载内容正确；
- 路径不显示；
- 过期失败明确。

## Task 10：后台、锁屏与设备音频

**目标：** 完成原生形态真正价值。

**文件：**

- Modify: `BackgroundSession.ets`
- Modify: `EntryAbility.ets`
- Modify: `PcmAudio.ets`
- Modify: `SingleAgentController.ets`

**真机矩阵：**

- 前台10分钟；
- 锁屏30分钟；
- Wi-Fi/蜂窝切换；
- 有线/蓝牙/车载；
- 来电和音频焦点；
- 权限撤销；
- 进程回收后Session恢复。

每项分别记录：静态/编译/模拟器/真机前台/真机后台。

## Task 11：发布与双产品隔离复核

**目标：** 单Agent发布不破坏主持人版。

**步骤：**

1. `node scripts/verify-single-agent.mjs`；
2. DevEco ArkTS检查；
3. HAP构建和签名；
4. 真机验收；
5. 公网服务探针；
6. 对比 `main`，确认主持人Controller/协议未被回写；
7. 更新单Agent README和版本；
8. 创建独立稳定标签。

**最终证据：**

```text
分支/提交
HAP版本
DevEco构建输出
设备/系统版本
真实Session ID
ASR/TTS探针
历史/附件/审批结果
后台/锁屏报告
主持人main未修改证明
```
