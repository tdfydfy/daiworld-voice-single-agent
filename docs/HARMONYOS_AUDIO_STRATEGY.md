# HarmonyOS 录音、播放与前后台统一策略

更新时间：2026-08-12

> 业务分类与用户可见语义以[音频用户旅程与业务逻辑](HARMONYOS_AUDIO_USER_JOURNEY.md)为权威入口。本文是其下游的音频可靠性技术参考，用于定义平台资源、健康证据和恢复约束；它不再用亮屏、息屏或测试组合定义业务场景。具体故障序列、组件接口和现有代码迁移见[组件拆解参考](HARMONYOS_AUDIO_COMPONENT_DESIGN.md)，当前实现按[当前计划](PLAN.md)逐步收敛。

## 1. 从最终目的开始

HarmonyOS 语音客户端的目的不是“让录音 API 和播放 API 能调用”，而是：

> 用户一次开启语音后，可以在手机亮屏、息屏、前台、后台和音频设备变化期间持续与 Agent 对话；已经说出的内容不会被静默丢失，已经接受的播报不会无故跳过，暂停、停止和恢复的结果符合用户意图。

由此得到四项按优先级排序的产品承诺：

1. **不伪装正常**：界面显示“监听中”或“播放中”时，必须有平台真实状态和数据流证据。
2. **不静默丢失**：不确定播放位置时，宁可有限重复当前短分段，也不能猜测进度后吞字。
3. **不隐式改变意图**：息屏、切到后台、Gateway 重连、Agent 完成和 TTS 完成都不能自行关闭麦克风或丢弃待播内容。
4. **不能恢复时明确失败**：平台资源被永久撤销或有限恢复耗尽后，停止虚假状态、保留可保留的数据并向用户报告。

## 2. 第一性原理

### 2.1 屏幕状态不是语音意图

亮屏、息屏、前台和后台只改变系统调度环境，不改变用户是否要继续收音或播放。因此：

- `screenOn`、`screenOff`、`onForeground`、`onBackground` 不进入 ASR/TTS 业务决策；
- 音频资源在亮屏时就按持续使用要求建立，不能等息屏后临时换一套策略；
- 生命周期事件只用于记录诊断、核对资源健康和刷新 UI，不主动重建正常工作的录音或播放。

### 2.2 用户意图、资源状态和健康证据是三件事

```text
用户意图：我希望继续收音 / 我允许继续播报
资源状态：后台任务、AudioSession、Capturer、TTS、Renderer 是否已启动
健康证据：是否持续收到 PCM、是否真实开始播放、是否完成设备排空
```

一个布尔值不能同时代表三者。比如 `captureChainStarted=true` 只表示本次运行已由用户开启完整输入链路，不能证明 AudioCapturer 正在产出 PCM 或 ASR 正常返回结果。

### 2.3 后台长时任务是能力租约，不是录音机或播放器

后台任务只向系统声明“这段时间应用需要持续使用音频能力”。它不能证明采集或播放健康，也不应跟随每个 TTS 分段反复切换。

统一策略是：每次应用运行中，只要用户已经手动启动完整话筒链路，或存在播放需求，就持有一个同时声明 `audioRecording` 和 `audioPlayback` 的组合租约；切换到仅系统指令模式不释放物理采集、ASR 或租约。用户退出软件且播放需求消失后才释放。

### 2.4 控制面不能代替数据面

- `start()` 成功不代表后续一直有 PCM；真实收音证据是 Capturer 为 RUNNING 且 `readData` 持续到达。
- `speak()` 返回不代表已经出声；`onStart` 只证明系统开始处理请求。
- 系统 TTS 的 `onComplete` 是 API 终止事件，不是用户已经完整听到的强证据。
- 应用自管 PCM 只有 Renderer 写入推进且最后一帧 drain 后，才能确认真实播放完成。

### 2.5 暂停和停止必须分开

- 用户开口：暂停当前播报，保留当前分段和后续队列，提交语音后恢复。
- 关闭话筒：采集和 ASR 继续，只把识别结果路由切到本地系统指令门；普通内容不生成消息或 Prompt，不影响 Agent 和已经接受的播报。
- 打开话筒：完整链路已由用户手动启动时，只把识别结果恢复到普通对话路由，不重建 Capturer 或 ASR。
- 静音：停止并清空语音输出，不关闭麦克风或中断 Agent。
- 精确“停止任务”或停止按钮：执行 Hermes `/stop` 语义，中断当前 Agent turn、取消全部排队 Prompt 并清空正文、重读和提醒输出，但不改变完整话筒链路、ASR 或消息路由模式。
- 退出软件：停止并释放全部本地音频、后台任务和网络连接，然后终止应用；默认不隐式中断已经提交给 Hermes 的远端任务。
- 切换会话或 Agent：终止旧会话的语音资源，陈旧回调不得污染新会话。

### 2.6 所有异步结果必须有代际

后台租约、采集器、识别 Session、TTS request、播放分段和会话切换都可能产生迟到回调。每条链路必须用 generation/request ID 隔离，旧回调只能被记录，不能推进当前状态。

## 3. 自上而下的结构

```text
L0 产品承诺
   持续对话、不静默丢失、控制可预测、失败可见
        |
L1 用户意图
   captureChainStarted / inputRouting / outputEnabled / muted / stopRequested / exitRequested
        |
L2 逻辑工作
   captureDemand / recognitionDemand / ordinaryPromptEnabled / playbackDemand / pausedForUser / queuedSpeech
        |
L3 系统保护
   combinedBackgroundLease(audioRecording + audioPlayback)
        |
L4 平台资源
   CommunicationAudioSession / AudioCapturer / CoreSpeech / PcmPlayer
        |
L5 真实健康
   stateChange / audioInterrupt / PCM heartbeat / renderer progress / drain
        |
L6 恢复与证据
   generation / bounded retry / terminal error / correlated logs / tests
```

上层只表达“要什么”，下层负责“如何做到”。屏幕状态只作为 L6 的诊断维度，不穿透到 L1-L4 改变策略。

## 4. 最小状态模型

### 4.1 权威状态

| 状态 | 含义 | 权威所有者 |
| --- | --- | --- |
| `recordingActual` | Capturer 是否真实 RUNNING 且持续有 PCM | `PcmCapture` / `SystemSpeechService` |
| `captureChainStarted` | 本次应用运行是否已由用户手动启动完整话筒链路 | `VoiceInputCoordinator` / Controller |
| `inputRouting` | `conversation` 普通对话或 `system_commands_only` 仅系统指令 | `VoiceInputCoordinator` |
| `recognitionState` | ASR 是连接、监听、收尾还是停止 | `VoiceInputCoordinator` |
| `outputEnabled` / `muted` | 用户是否允许语音输出 | `VoiceOutputCoordinator` / 设置 |
| `speechQueue` | 已接受但尚未确认完成的播报 | `VoiceOutputCoordinator` / `SystemSpeechQueue` |
| `playbackActual` | TTS/Renderer 是否真实启动和推进 | 对应播放后端 |
| `pausedForUser` | 因真人说话而临时暂停 | `VoiceOutputCoordinator` |
| `leaseState` | 组合后台任务的 desired/starting/ready/stopping/failed | `BackgroundAudioTaskOwner` |
| `screenState` | 可见性、锁屏等诊断信息 | Ability 生命周期，仅观测 |

### 4.2 派生规则

```text
captureDemand = captureChainStarted

recognitionDemand = captureChainStarted

ordinaryPromptEnabled = recognitionDemand && inputRouting == conversation

playbackDemand = outputEnabled
  && !muted
  && (speechQueue 非空 || 正在合成 || 正在播放 || 正在排空 || 必要提示音活跃)

voiceLeaseDemand = captureDemand || playbackDemand

leaseModes = voiceLeaseDemand
  ? { audioRecording, audioPlayback }
  : { }
```

`pausedForUser` 期间队列仍非空，因此继续持有组合租约。这样用户说完后可以直接恢复，不发生后台模式切换空窗。

### 4.3 UI 状态的证据要求

| UI 文案 | 最低证据 |
| --- | --- |
| 正在连接 | 用户意图仍在，资源启动或恢复尚未完成 |
| 监听中 | `captureChainStarted`、`inputRouting=conversation`、Capturer RUNNING、近期有 PCM、ASR 可接收音频 |
| 仅响应系统指令 | `captureChainStarted`、`inputRouting=system_commands_only`、Capturer RUNNING、ASR持续工作；普通结果不出本地指令门 |
| 等待播报 | 队列非空，但后台租约或播放后端尚未 ready |
| 播放中 | 系统 TTS `onStart`，或 PCM Renderer 已开始写入 |
| 已暂停 | 当前内容仍保留，且存在明确暂停原因 |
| 已停止/错误 | 用户显式停止，或有限恢复耗尽；不得继续显示正常状态 |

## 5. 组件所有权

| 组件 | 唯一职责 | 不应负责 |
| --- | --- | --- |
| `VoiceInputCoordinator` | 完整链路启动意图、消息路由模式、收句、系统指令门和 UI 输入状态 | 猜测 Capturer 是否健康、把仅指令模式的普通文本发送到远端、管理播放 |
| `PcmCapture` | 创建/释放唯一 Capturer、持续 PCM、报告状态/中断/心跳、执行单次重建 | 因消息路由变化而停止、修改用户意图、无限重试 |
| `SystemSpeechService` | CoreSpeech 识别/TTS request、采集编排、恢复上限 | 根据屏幕状态选择算法 |
| `VoiceOutputCoordinator` | 正文/重读/提示音的唯一输出仲裁、分段队列、暂停/恢复/停止语义、request/chunk 代际 | 切换录音资源、允许多个播放器并发抢占 |
| `SystemSpeechQueue` | 文本分段及分段状态 | 用估算进度宣称精确播放位置 |
| `PcmPlayer` | PCM 排队、Renderer 健康、暂停位置、设备排空 | 决定 Agent 或麦克风意图 |
| `CommunicationAudioSession` | 通信场景、并发策略、输出路由与 Session 恢复 | 代替后台长时任务 |
| `BackgroundAudioTaskOwner` | 组合租约、ready 门、串行启动/停止和有限重试 | 判断 TTS 完成或 Capturer 健康 |
| `SingleAgentController` | 汇总需求并协调跨域动作 | 持有第二份音频状态机 |

## 6. 四种基础组合

亮屏和息屏使用完全相同的四种策略，区别只体现在系统是否更依赖后台租约。

| 物理采集需求 | 播放需求 | 组合租约 | 平台行为 |
| --- | --- | --- | --- |
| 无 | 无 | 释放 | 本次运行尚未手动启动或已明确退出完整链路；不持有 Capturer、TTS 或 Renderer |
| 有 | 无 | 保持并等待 ready | Capturer 和 ASR 持续运行；消息路由可为普通对话或仅系统指令；不创建播放器 |
| 无 | 有 | 首段前启动并等待 ready | 不启动 Capturer；按后端播放，队列 drain 后释放租约 |
| 有 | 有 | 保持同一个 ready 租约 | Capturer 不停；TTS/PCM 并行播放；用户开口时只暂停输出 |

关键点：第四种状态不是在 `AUDIO_RECORDING` 和 `AUDIO_PLAYBACK` 之间切换，而是从开始到结束一直持有同一个组合租约。

## 7. 场景策略矩阵

| 场景 | 应保持的事实 | 允许的动作 | 禁止的动作 |
| --- | --- | --- | --- |
| 亮屏开启麦克风 | 组合租约 ready、Capturer 有 PCM、ASR 可接收 | 正常采集和识别 | 只凭 `captureRunning` 显示监听中 |
| 收音中息屏/进入后台 | 与亮屏时相同 | 记录生命周期并检查健康 | 停录、重建、切换后台模式 |
| 息屏后解锁/回前台 | 用户意图和现有资源不变 | 刷新 UI、核对 PCM/路由 | 无条件重连 Gateway、重启 Capturer 或清队列 |
| 仅系统指令模式开始播报 | 组合租约保持 ready | 启动系统 TTS 或 PCM 播放，采集/ASR继续 | 后台租约仍 starting 时直接 `speak`，或切换输入路径 |
| 收音同时开始播报 | 组合租约不变，Capturer 继续 | 播放与识别并行 | 为播放停掉 Capturer，或录播模式 stop/start |
| 播放中息屏 | 队列、当前 request 和租约不变 | 继续播放并观察真实进度 | 重新分段、跳到下一段、因屏幕事件调用 stop |
| 播放中检测到真人语音 | Capturer 和 ASR 继续，待播内容保留 | 暂停输出；final 提交后恢复 | 清空播报、关闭麦克风、重建识别 Session |
| 播放中关闭话筒 | 当前播报、队列、Capturer、ASR和租约继续 | 识别结果只过本地系统指令门，普通内容丢弃 | 停止 Capturer/ASR、Agent 或 TTS，切换后台任务类型 |
| 播放中静音 | 麦克风意图不变 | 停止并清空输出；若仍收音则保留组合租约 | 关闭麦克风或中断 Agent |
| 播放中精确“停止任务” | 完整话筒链路、ASR和消息路由不变 | `/stop` 当前任务和全部排队任务；清空正文、重读、待播和呼吸音；确认后播放停止提示 | 把输入一并关闭，或保留排队 Prompt |
| 精确“退出软件” | 已确认记录和远端任务身份保留 | 依次释放本地输出、输入、后台租约和网络连接，然后终止应用 | 自动重连、遗留采集/播放；默认把退出扩大成 `/stop` |
| 新消息/历史重读/提醒 | 使用同一输出仲裁、分段、队列和播放入口 | 按优先级让路并用 generation 隔离旧请求 | 多套播放器、两套分段或两套息屏逻辑 |
| 来电/其他音频焦点抢占 | 用户意图和队列保留 | 按中断提示暂停或有限恢复 | 把临时中断当成用户停止 |
| 耳机插拔/路由变化 | 用户意图、Capturer 和队列不变 | 让系统选择设备，更新标签；资源失活时才恢复 | 正常插拔就手工选输入或重建采集器 |
| Gateway 瞬态断线 | 本地音频状态独立保留 | 恢复 Session；远端 ASR/TTS 各自有界重连 | 清消息、重放 Prompt、强制归零本地播放 |
| 应用被系统杀死或强制停止 | 运行态不可继续 | 下次启动报告中断并恢复持久设置/会话 | 宣称后台任务能对抗强制停止或所有电源策略 |

## 8. 录音策略

### 8.1 启动顺序

```text
用户开启麦克风
  -> captureChainStarted=true（每次冷启动首次由用户手动触发）
  -> inputRouting=conversation
  -> 请求组合后台租约并等待 ready
  -> 获取 CommunicationAudioSession
  -> 创建并启动 AudioCapturer
  -> 观察 RUNNING + 首批 PCM
  -> 启动/接通识别 Session
  -> UI 显示“监听中”
```

任何一步失败都必须携带同一 generation 收尾。用户尚未手动启动完整链路或已经执行退出软件时，迟到的启动成功必须立即释放。切换消息路由时不得释放 Capturer 或 ASR。

### 8.2 健康判定

以下任一条件表示采集失活：

- `stateChange` 进入 STOPPED、RELEASED 或 INVALID；
- `audioInterrupt` 表示暂停/停止且未在合理时间恢复；
- Capturer 已声明 RUNNING，但约 2 秒没有任何 `readData`；
- Communication AudioSession 恢复后，Capturer 仍无 PCM。

静音环境仍会产生 PCM，所以“无 PCM”是采集链失活证据，不是“用户没有说话”。

### 8.3 恢复边界

- 每次失活只允许一个串行恢复任务；同一事件的状态回调、无 PCM 看门和 Session 恢复通知必须合并。
- 建议使用 `100 / 500 / 1500 ms` 三次有界退避；新 PCM 到达后清零本次恢复计数。
- 重建 Capturer 时保留 `captureChainStarted`、`inputRouting` 和可用的有限 pre-roll；不得并发创建两个 Capturer。
- 关闭/打开话筒只切换消息路由，不取消 Capturer/ASR 看门和恢复；只有退出软件、权限撤销或应用释放才取消输入恢复。
- 恢复耗尽后将实际状态置为 stopped、清除虚假“监听中”并报告错误；不无限重试。

### 8.4 本地和远端 ASR

- 选定的本地或远端 ASR 共用同一个 Capturer 健康模型；普通对话和仅系统指令模式共用同一个识别 Session 与收句缓冲，不因消息路由变化重连或轮换。
- CoreSpeech 的约 18 秒识别 Session 轮换只更换识别 Session，不停止 PCM 采集或后台租约。
- 远端 ASR 断线时保留有限 pre-roll，并按既有有界退避恢复 WebSocket；网络恢复和采集恢复是两个独立状态机。
- ASR final 的 1.8 秒收句窗口不参与底层音频资源切换。
- 识别 Session 轮换、短暂断线和前后台变化共用同一上层话语缓冲；只有真正收句完成或精确控制词才提交，不能把一次讲话因内部断点拆成多条 Prompt。
- 每个 final 先经过本地精确系统指令门。在 `system_commands_only` 模式，只有“停止任务”“打开话筒”“退出软件”可以产生动作，其他结果不创建气泡、不响收到提示、不访问 Agent 链路。

## 9. 播放策略

### 9.1 通用队列规则

每个播报分段至少经过：

```text
queued -> waiting_for_lease -> issued -> started -> terminal
```

- 首段必须等待组合后台租约 ready；后续分段复用同一租约。
- request ID、generation、chunk 序号共同标识一次播放；陈旧回调不能完成当前分段。
- 只有队列为空、当前分段 terminal、播放器完成 drain 且没有采集需求时，才释放组合租约。
- 新消息自动播报和历史重读使用完全相同的分段和队列入口。

### 9.2 系统 TTS

- CoreSpeech TTS 不主动获取应用的 Communication AudioSession，避免与系统 `VOICE_ASSISTANT` 播放器形成 `6800301` 焦点冲突。
- 完整话筒链路已启动时，由 Capturer 持有的通信 Session 使用允许混音策略；消息路由模式不改变播放会话。
- `onStart` 表示请求实际开始；`onStop/onError` 是明确中断；`onComplete` 暂作为分段终止回调，但不能证明用户完整听到。
- 系统 TTS 没有可靠播放位置。用户开口暂停或平台中断后，短期策略应从当前短分段开头重播，最多产生一个分段的重复，禁止按“时长 × 每秒字数”估算后跳过文本。
- 若稳定后台租约后仍出现 `onComplete` 但漏播，系统 TTS 不再满足“不静默丢失”的产品承诺，进入 PCM 自管播放升级。

### 9.3 远端或合成 PCM 播放

- `PcmPlayer` 按实际采样率创建 Renderer，使用通信场景和系统路由。
- Provider `done/onComplete` 只表示不会再产生 PCM；最后一个 buffer drain 后才算听觉播放完成。
- 暂停保存精确 PCM 队列和写入位置，恢复不需要猜测文本进度。
- Renderer STOPPED/INVALID、`audioInterrupt`、写入无推进和 AudioSession 恢复都进入同一个有限重建入口。
- 重建 Renderer 不清空尚未 drain 的 PCM；generation 变化或用户停止才清空。

## 10. 后台租约策略

`BackgroundAudioTaskOwner` 应使用显式状态机：

```text
idle -> starting -> ready -> stopping -> idle
          |          |
          +-> failed <-+
```

规则：

1. 完整话筒链路已手动启动或任一播放需求出现时，请求固定的组合模式，不根据当前谁更活跃进行优先级切换；普通对话/仅系统指令模式不改变租约。
2. `ensureReady(generation)` 返回可等待 Promise；Capturer 或首段 TTS 不得越过这个门。
3. 多个需求共享同一启动 Promise；快速 start/stop 只由最新 generation 决定最终状态。
4. 启动失败有限重试并报告；失败期间不得把受保护音频伪装为已正常启动。
5. 只有退出完整话筒链路，且正文、重读和必要提示音都结束后才停止；消息路由切换或播报暂停时不停止。
6. 亮屏和前台也遵守同样的租约流程，从而保证随后息屏不需要临时迁移资源。

如果目标设备拒绝一次申请两种模式，才进入设备验证后的降级路径：优先验证原地更新能力；确实只能串行 stop/start 时，必须等待新模式 ready，且把空窗作为显式错误状态。不能回到 fire-and-forget。

## 11. 事件优先级

同一时刻发生多个事件时按以下顺序处理：

1. 会话/Agent generation 变化和应用释放；
2. 用户精确“退出软件”“停止任务”、静音、关闭/打开话筒等显式控制；
3. 真人说话引发的临时暂停；
4. 平台中断、资源失活和有界恢复；
5. TTS/ASR/提示音普通完成回调；
6. 屏幕和前后台生命周期通知。

高优先级动作一旦改变 generation，低优先级迟到回调只能忽略。这样可以防止“用户刚停止，旧 ready 回调又开始播放”或“切换会话后旧 TTS 完成推进新队列”。

## 12. 可观测性

每条日志至少包含适用的关联字段：

```text
voiceGeneration
leaseGeneration / leaseState / leaseModes
captureGeneration / capturerState / lastPcmGapMs
recognitionSessionId / asrState
speechGeneration / requestId / chunkIndex / playbackState
screenState / abilityState（仅诊断）
audioRoute / interruptHint / retryAttempt
```

需要能从一次复现日志回答：

1. 当时用户是否要求收音和播放？
2. 组合后台租约是否 ready，是否出现过空窗？
3. Capturer 是否 RUNNING，最后一块 PCM 何时到达？
4. 当前 TTS 分段是否真正 `onStart`，由哪个回调推进到下一段？
5. 是否发生 AudioSession、焦点或设备路由中断？
6. 恢复由什么触发，是否被去重，最终成功还是耗尽？

## 13. 验收结构

### 13.1 状态机自动化

- 组合租约只启动一次，录播并行时不切换模式；
- lease ready 前 Capturer 和首段 TTS 都不得启动；
- 快速开启/关闭、播放/停止不会被陈旧回调反向启动；
- Capturer 状态异常、中断和无 PCM 同时到达时只重建一次；
- 显式关闭会取消看门和重试；
- 系统 TTS 暂停后从当前分段开头恢复，不按估算位置跳字；
- TTS 陈旧 request 回调不能完成新分段；
- PCM Provider 完成与 Renderer drain 分开验证。

### 13.2 真机场景

| 组别 | 场景 |
| --- | --- |
| 屏幕 | 亮屏开始后息屏、息屏后开始播报、锁屏/解锁、前后台往返 |
| 录音 | 冷启动首次手动开启、至少 5 分钟持续采集/ASR、关闭/打开话筒只切消息路由、识别 Session 多次轮换、短暂中断后恢复 |
| 播放 | 短句/长文、新消息/历史重读/提醒统一仲裁、段间衔接、播放中息屏 |
| 双工 | 播放时开口、提交后恢复、连续补充、误回音观察 |
| 控制 | 关闭/打开话筒、静音、精确“停止任务”清空当前和排队任务、“退出软件”释放本地资源、切换会话/Agent |
| 路由 | 听筒、扬声器、有线/蓝牙/USB 耳机、播放中插拔 |
| 故障 | Gateway/远端语音断线、AudioSession 撤销、Capturer/Renderer 失活 |

通过标准：无静默采集/ASR中断，一次讲话不会因内部 ASR/生命周期断点被拆成多条提交，仅系统指令模式的普通内容不会出本地；无并发播放器、提示音抢占、播放中断、破音、缺字、漏段或无限重复；有限重复必须局限在被打断的当前短分段；退出后无采集、播放、后台任务或自动重连；UI 与平台真实状态一致；无后台任务空窗、无限恢复或 `6800301`。

## 14. 能力边界和升级条件

以下能力不能靠后台任务或状态机凭空保证：

- 系统强制停止、用户手动终止应用或设备级极端省电后的进程存活；
- 系统 TTS 在没有 PCM/播放进度接口时的精确暂停位置和真实设备 drain；
- 所有硬件上的回声消除、双讲和蓝牙路由质量。

因此采用分层承诺：

1. 先以组合后台租约、真实采集健康和严格 request 代际消除客户端自身竞态。
2. 系统 TTS 暂停采用“当前短分段至少一次”语义，以有限重复换取不吞字。
3. 若系统 TTS 正常回调仍与听感不一致，验证 CoreSpeech `onData`，切换到 `PcmPlayer` 后以 PCM 写入和 drain 提供更强完成语义。
4. 真机无法控制的系统终止明确记录为平台边界，不伪造自动恢复成功。

## 15. 当前实现差距

| 当前实现 | 与策略的差距 | 收敛动作 |
| --- | --- | --- |
| `BackgroundAudioTaskOwner` 只有 `none/recording/playback` | 录播之间会 stop/start，且没有可等待 ready | 改为固定组合租约和 generation-aware `ensureReady()` |
| `SingleAgentController` 以播放优先选择后台模式 | 同时收音和播放时只能表达一个意图 | 汇总为 `voiceLeaseDemand`，不做录播优先级选择 |
| `startSystemSpeech()` 只等待提示音让路 | 首段可能在后台租约 ready 前启动 | 将 lease ready 纳入同一个启动门 |
| `PcmCapture` 只监听 `readData/inputDeviceChange` | 不能发现状态失活、中断或长期无 PCM | 增加状态、中断、看门和串行恢复 |
| `SystemSpeechService.captureRunning` 是主要健康依据 | 布尔值可能与平台实际状态漂移 | 使用 Capturer 健康事件更新实际状态 |
| `SystemSpeechQueue.remainingText()` 按时长估算位置 | 播放速度/标点误差会直接吞字 | 系统 TTS 恢复时重播当前完整短分段 |
| 系统 TTS 以 `onComplete` 推进队列 | 无法证明用户实际听完 | 先严格隔离 request；仍漏播则升级 PCM 自管播放 |

## 16. 实施顺序

1. 组合后台租约和 ready 门；先消除所有屏幕切换前就存在的资源竞态。
2. Capturer 真实健康、无 PCM 看门和有限恢复；消除虚假监听状态。
3. TTS request/chunk 代际及系统 TTS 保守重播；消除陈旧回调和估算吞字。
4. 状态机自动化与真机场景矩阵；用同一组规则验证亮屏和息屏。
5. 只有系统 TTS 的能力边界仍导致漏播时，升级为 CoreSpeech 合成 PCM + `PcmPlayer`。
