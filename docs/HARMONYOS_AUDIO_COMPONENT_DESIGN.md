# HarmonyOS 音频场景与组件拆解蓝图

更新时间：2026-08-12

> 本文是后续实现阶段的技术参考，不是当前业务设计入口。业务分类与组件责任域先以[音频用户旅程与业务逻辑](HARMONYOS_AUDIO_USER_JOURNEY.md)为准；文中的 `S00-S21` 仅表示测试与故障序列，不能视为 22 个用户场景，也不能据此按亮屏/息屏拆出多套业务逻辑。本文把[音频可靠性技术策略](HARMONYOS_AUDIO_STRATEGY.md)转换为可编码结构。

> **历史方案提示：** 本文的组合租约和本地 CoreSpeech PCM 组件方案已由 `1.2.5` 的专用 `AUDIO_PLAYBACK`/`AUDIO_RECORDING` 切换及系统播放器取代。当前实现与后续变更以[关键决策](decisions.md)和[当前计划](PLAN.md)为准。

## 1. 拆解目标

代码拆解不是按“录音文件、播放文件、息屏文件”分类，而是按独立生命周期和状态所有权分类：

```text
用户命令与对话语义
  -> 输入/输出协调
  -> 连续运行保护
  -> ASR/TTS 后端
  -> Capturer/Renderer 平台资源
  -> UI 只读快照
```

拆解完成后应满足：

1. 一个状态只有一个组件可以写。
2. 输入、输出和后台保护可以分别测试。
3. 亮屏/息屏不产生不同业务调用链。
4. 本地/远端后端共享同一用户语义，但各自拥有连接和恢复状态。
5. `SingleAgentController` 不再判断 Capturer、TTS 或后台任务的内部状态。
6. 不使用事件总线；组件通过构造参数中的窄接口和类型化回调通信。

## 2. 场景坐标系

所有场景由五个正交维度组合，不为每个组合写一套分支：

| 维度 | 状态 |
| --- | --- |
| 采集/识别需求 `R` | `0` 完整链路未启动或已退出、`1` 持续采集和ASR；消息路由另分 `conversation/system_commands_only` |
| 播放需求 `P` | `0` 无、`1` 有、`paused` 因用户说话暂停 |
| 应用环境 `V` | `foreground`、`background`；屏幕亮灭只作诊断标签 |
| 语音后端 `B` | `system`、`remote` |
| 资源健康 `H` | `starting`、`healthy`、`interrupted`、`recovering`、`failed` |

基础运行态只有四种：

| 编号 | `R` | `P` | 组合租约 | 说明 |
| --- | --- | --- | --- | --- |
| `B00` | 0 | 0 | 无 | 完全空闲 |
| `B10` | 1 | 0 | ready | 只收音 |
| `B01` | 0 | 1 | ready | 只播放 |
| `B11` | 1 | 1/paused | ready | 全双工或播报暂歇 |

`V`、`B` 和 `H` 是覆盖在这四种状态上的变化。例如“息屏时系统 TTS 播放并持续收音”是 `B11 + background + system + healthy`，不是第五套业务模式。

## 3. 目标组件图

```text
Index / EntryAbility
        |
        v
SingleAgentController -------------------------- HermesRuntime
        |                                              |
        | user commands / conversation events          | Agent events
        v                                              v
VoiceInputCoordinator ----> SingleAgentController <---- VoiceOutputCoordinator
        |                  high-level events           |
        | recording demand                             | playback demand
        +------------------+   +-----------------------+
                           v   v
                 AudioContinuityCoordinator       SpeechPlaybackQueue
                           |                         /             \
                           v                        v               v
                 BackgroundAudioTaskOwner   SystemTtsPlayer   RemoteTtsPlayer
                           ^                                      |
                           | ensureReady                          v
VoiceInputCoordinator ---> CaptureSupervisor                  PcmPlayer
                              |                                   |
                              v                                   |
                          PcmCapture                              |
                              |                                   |
                              +----------+  +---------------------+
                                         v  v
                              CommunicationAudioSession

VoiceInputCoordinator -> SystemAsrEngine | RemoteAsrEngine
VoiceOutputCoordinator -> SpeechSegmenter / AudioCuePlayer
```

依赖只允许向下。平台组件通过事件回调向上报告，不得直接修改 UI 快照或用户意图。

## 4. 公共事件与状态契约

这些类型应放入新的 `VoiceAudioContracts.ets`，避免继续使用多个无语义的 `boolean` 回调。

```ts
export type AudioDemandKind = 'recording' | 'playback';
export type LeaseState = 'idle' | 'starting' | 'ready' | 'stopping' | 'failed';
export type ResourceHealth = 'idle' | 'starting' | 'healthy' | 'interrupted' | 'recovering' | 'failed';
export type SpeechTerminal = 'completed' | 'stopped' | 'error';

export class AudioGeneration {
  voice: number = 0;
  session: number = 0;
}

export class CaptureHealthEvent {
  generation: number = 0;
  health: ResourceHealth = 'idle';
  platformState: number = 0;
  lastPcmAt: number = 0;
  reason: string = '';
}

export class SpeechPlaybackEvent {
  generation: number = 0;
  jobId: string = '';
  requestId: string = '';
  chunkIndex: number = 0;
  phase: 'issued' | 'started' | 'terminal' = 'issued';
  terminal?: SpeechTerminal;
  reason: string = '';
}
```

约束：

- 所有异步入口必须携带 generation；
- request ID 只标识一个后端请求，不能代替 job generation；
- 组件收到旧 generation 时只记录日志并返回；
- UI 状态由协调器根据事件投影，不直接暴露平台枚举；
- 屏幕/前后台标签仅进入日志，不进入状态迁移条件。

## 5. 组件职责与逻辑

### 5.1 `SingleAgentController`

保留职责：

- 接收 UI 命令：首次启动完整话筒链路、切换普通对话/仅系统指令模式、静音、停止任务、退出软件、重读、切换会话/Agent；
- 接收 Hermes 消息事件并转发给输入/输出协调器；
- 协调跨域语义：用户开始说话时暂停输出，输入提交或丢弃后决定是否恢复；
- 汇总输入、输出和运行时的只读 UI 快照。

目标公开逻辑：

```text
startVoiceChain()      -> input.startCaptureAndRecognition(...)
setInputRouting(mode)  -> input.setRouting(mode)
toggleMute()           -> output.setMuted(...)
stopCurrentTask()      -> output.stopAll() + runtime.stopCurrentAndQueued()
exitApplication()      -> output.release() + input.release() + continuity.releaseAll() + runtime.disconnect()
replayMessage(message) -> output.replay(message)
switchProfile/session  -> bump sessionGeneration + input/output.reset(...)
```

必须迁出：

- `backgroundAudioTask` 字段；
- `syncBackgroundVoiceTask()`；
- `prefersBackgroundPlayback()` 优先级判断；
- CoreSpeech listener 的逐个接线细节；
- Capturer、TTS request 或 Renderer 的健康判断。

### 5.2 `AudioContinuityCoordinator`（新增）

唯一职责：把录音/播放需求合并为一个组合后台租约，并提供可等待的 ready 门。

内部状态：

```text
  captureDemand: boolean
playbackDemand: boolean
demandGeneration: number
leaseState: LeaseState
```

目标接口：

```ts
setDemand(kind: AudioDemandKind, active: boolean, generation: number): void;
ensureReady(kind: AudioDemandKind, generation: number): Promise<void>;
clearGeneration(generation: number): Promise<void>;
releaseAll(): Promise<void>;
snapshot(): AudioContinuitySnapshot;
```

逻辑：

1. 完整话筒链路启动或 playback demand 变为 `true`，调用 `BackgroundAudioTaskOwner.ensureReady()`；消息路由变化不清除 capture demand。
2. 两个 demand 共享同一个启动 Promise。
3. 任一 demand 仍为 `true` 时不停止租约。
4. 两个 demand 都为 `false` 时串行停止。
5. `pausedForUser` 不清除 playback demand，因为队列仍需恢复。
6. 启动失败只对当前 generation 生效；有限重试耗尽后拒绝对应 `ensureReady()`。

禁止：不创建 Capturer、不调用 TTS、不读 UI playback 字符串、不判断屏幕状态。

### 5.3 `BackgroundAudioTaskOwner`

唯一职责：封装 HarmonyOS 后台任务 API。

目标接口：

```ts
setContext(context: UIAbilityContext): void;
ensureReady(generation: number): Promise<void>;
stop(generation: number): Promise<void>;
release(): Promise<void>;
```

逻辑：

- `startBackgroundRunning(context, [audioPlayback, audioRecording], agent)` 只在 idle 时调用；
- 状态机为 `idle -> starting -> ready -> stopping -> idle`；
- 多次 `ensureReady()` 返回同一 Promise；
- stop 在 starting 期间到达时记录 desired=false，启动完成后立即串行停止；
- 迟到完成不能把新 generation 改成 ready；
- 目标设备拒绝组合模式时进入显式 failed，不在组件内部静默改回旧切换策略。

禁止：不知道 recording/playback 哪个活跃，不处理 AudioSession 和播放完成。

### 5.4 `CaptureSupervisor`（新增）

唯一职责：把“用户需要录音”落实为一个健康的物理 Capturer，并负责去重、看门和有界恢复。

内部状态：

```text
wanted: boolean
generation: number
health: ResourceHealth
lastPcmAt: number
recoveryAttempt: number
startOrRecovery?: Promise<void>
watchdog?: timer
```

目标接口：

```ts
start(generation: number, pcmSink: AudioChunkListener): Promise<void>;
stop(generation: number): Promise<void>;
onHealth(listener: CaptureHealthListener): void;
getRouteLabel(): string;
```

启动逻辑：

```text
continuity.ensureReady('recording')
  -> PcmCapture.start()
  -> 等待 state=RUNNING 和首块 PCM
  -> health=healthy
  -> 启动 2 秒 PCM 看门
```

恢复逻辑：

- STOPPED/RELEASED/INVALID、需要暂停的 audioInterrupt、无 PCM、AudioSession 恢复后仍无数据均调用同一个 `requestRecovery(reason)`；
- 已有恢复 Promise 时只合并原因，不再创建第二个 Capturer；
- 使用 `100 / 500 / 1500 ms` 三次退避；
- 每次恢复执行 `PcmCapture.stop -> start`，新 PCM 到达后清零；
- wanted=false 或 generation 变化立即取消看门和后续重试；
- 耗尽后发出 `failed`，不自行修改用户意图。

### 5.5 `PcmCapture`

唯一职责：封装一个 AudioCapturer 实例的创建、事件注册、启动、停止和释放。

目标事件：

```text
onPcm(buffer)
onStateChange(state)
onAudioInterrupt(event)
onRouteChange(label)
onError(error)
```

保留：权限申请、16 kHz mono PCM 配置、通信源、输入路由查询。

迁出：看门计时、恢复次数、用户 wanted、ASR 状态和 UI 文案。`PcmCapture` 不重试，只完成一次物理操作。

### 5.6 `VoiceInputCoordinator`

唯一职责：完整话筒链路意图、识别后端、连续话语收句、本地系统指令门和普通消息路由。

内部状态保留：

```text
captureChainStarted
inputRouting: conversation | system_commands_only
selectedBackend
utterance interim/final buffer
1.8 秒 finalization timer
control phrase recognition
```

目标调用链：

```text
startCaptureAndRecognition()
  -> continuity.setDemand(capture=true)
  -> selectedAsr.start(generation) 与 captureSupervisor.start(...) 并行准备
  -> CaptureSupervisor 内部等待 recording lease ready 后才启动 PcmCapture
  -> capture healthy && backend ready => UI listening
```

识别结果逻辑仍保留：

- partial/final 合并；
- 每个 final 先匹配“停止任务”“关闭话筒”“打开话筒”“退出软件”等精确系统指令；
- `system_commands_only` 只执行停止任务、打开话筒、退出软件，普通结果不建消息、不响收到提示、不提交；
- 普通 final 经过 1.8 秒窗口提交；
- 产生 `userSpeechStarted`、`utteranceAccepted`、`utteranceDiscarded` 高层回调，由 Controller 协调输出暂停/恢复。
- 识别 Session 轮换、短暂断线和亮屏/息屏共用同一个上层话语缓冲，内部断点不能把一句话拆成多条 Prompt。

必须迁出：`PcmCapture` 字段、`capturing`、`startCapture()`、远端 reconnect timer、本地识别 restart timer。

### 5.7 `SystemAsrEngine`（从 `SystemSpeechService` 拆出）

唯一职责：CoreSpeech 识别引擎和识别 Session。

目标接口：

```ts
start(generation: number): Promise<void>;
acceptPcm(generation: number, pcm: ArrayBuffer): void;
finish(generation: number): void;
stop(generation: number): Promise<void>;
onEvent(listener: RecognitionEventListener): void;
```

内部逻辑：

- 创建/复用 SpeechRecognitionEngine；
- ready 前保留有限 pre-roll；
- 每 18 秒音频预算轮换识别 Session，但不触碰 Capturer；
- sessionId + generation 隔离旧回调；
- 引擎 Session 意外终止时有限重建，耗尽后发 terminal error；
- 不申请麦克风权限，不持有 `captureRunning`。

### 5.8 `RemoteAsrEngine`（包装现有 `StreamingAsrClient`）

唯一职责：远端 ASR WebSocket、ready、PCM pre-roll 和有界重连。

内部逻辑：

- `250 / 750 / 1500 / 3000 ms` 封顶退避；
- ready 前和断线时保留约 0.8 秒 PCM；
- reconnect 只由 `started && gateway online && cookie available` 决定；
- generation 变化、退出软件、切换后端或鉴权终止错误取消重连；关闭/打开话筒不重连；
- 不负责 1.8 秒自然语言收句，不修改 UI 消息。

### 5.9 `VoiceOutputCoordinator`

唯一职责：正文、历史重读、协议播报和提示音的唯一输出仲裁，SpeechJob 语义、暂停/恢复/停止和后端选择。

保留：

- Agent 流式正文转播报文本；
- 新消息、重读、审批/澄清播报和 accepted/running/stop/error 提醒的 job 来源；
- muted/outputEnabled；
- 用户开口暂停、final 后恢复；
- thinking/accepted/stop cue 的业务时机。
- 统一优先级：停止/错误警示 > 用户讲话静默 > 正文/重读 > 收到提示 > 思考呼吸；任一时刻只有一个可听输出所有者。

目标调用链：

```text
enqueue(job)
  -> segmenter 产生 chunks
  -> queue.enqueue(job)
  -> continuity.setDemand(playback=true)
  -> continuity.ensureReady('playback')
  -> selectedPlayer.play(activeChunk)
```

结束逻辑：

- 只接受匹配 generation/jobId/requestId/chunkIndex 的 terminal；
- 还有 chunk 时启动下一段；
- 队列清空且 cue 不活跃时 `playbackDemand=false`；
- captureDemand 是否仍在由 continuity 自己判断，不由输出组件切模式。

必须迁出：系统 TTS API、远端 TTS WebSocket 回调、PCM Renderer 回调和后台意图优先级。

### 5.10 `SpeechSegmenter` 与 `SpeechPlaybackQueue`

从当前 `SystemSpeechQueue` 拆为两个纯逻辑组件。

`SpeechSegmenter`：

- 只负责流式文本、首段 20-48 字、续段 40-80 字和 96 字硬上限；
- 不知道播放、暂停、request ID 和屏幕状态；
- 新消息和历史重读使用同一实例规则。

`SpeechPlaybackQueue`：

```ts
enqueue(job: SpeechJob): void;
activateNext(): SpeechChunk | undefined;
markIssued(eventKey): void;
markStarted(eventKey): void;
markTerminal(eventKey, terminal): SpeechChunk | undefined;
pauseForUser(): SpeechChunk | undefined;
resume(): SpeechChunk | undefined;
clear(generation: number): void;
```

- 系统 TTS 暂停时保留完整 active chunk，恢复从该 chunk 开头播放；
- PCM 后端暂停时 active chunk 和 PCM 偏移由播放器精确保留；
- 删除当前 `remainingText()` 的按时间估算逻辑；
- queue 本身不调用任何后端。

### 5.11 `SystemTtsPlayer`（从 `SystemSpeechService` 拆出）

唯一职责：CoreSpeech TTS engine 和单分段 request。

目标接口：

```ts
listVoices(): Promise<VoiceOption[]>;
play(chunk: SpeechChunk, config: SpeechConfig): Promise<void>;
stop(generation: number): void;
release(): Promise<void>;
onEvent(listener: SpeechPlaybackListener): void;
```

逻辑：

- 每个 chunk 创建 requestId，并记录 job generation/chunkIndex；
- `onStart` 上报 started；`onComplete/onStop/onError` 上报 terminal；
- 旧 request 回调不外发当前事件；
- stop 只停止当前 request，不擅自清空业务 queue；
- 不持有 CommunicationAudioSession；
- 不等待后台任务，ready 门由 VoiceOutputCoordinator 统一负责。

### 5.12 `RemoteTtsPlayer`（包装 `StreamingTtsClient` + `PcmPlayer`）

唯一职责：一次远端 TTS job 从文本发送到 PCM drain 的完整后端生命周期。

逻辑：

- 维护 WebSocket ready、待发 text/done 帧和有界重连；
- 收到 job start 后按实际采样率配置 `PcmPlayer`；
- Provider end 只标记 synthesis complete；
- `PcmPlayer.waitForDrain()` 后才发 completed；
- 用户暂停调用 `PcmPlayer.pause()`，恢复调用 `resume()`；
- socket 断线时已收到 PCM 继续 drain，未发送帧按顺序恢复；
- stop 清空本 job 的远端帧和 PCM，并隔离旧 socket/player 回调。

### 5.13 `PcmPlayer`

唯一职责：PCM 队列、Renderer、精确暂停位置、写入看门和 drain。

保留现有 stateChange、audioInterrupt、AudioSession 恢复和 Renderer 重建。需要收紧：

- 所有事件携带 player generation；
- Renderer 重建不得丢弃尚未写入/排空的 PCM；
- `waitForDrain()` 只对调用时对应 job 生效；
- stop/release 必须使旧 drain timer 失效。

### 5.14 `CommunicationAudioSession`

唯一职责：通信场景、引用计数、输出路由和 Session 恢复。

- 由 `PcmCapture` 和 `PcmPlayer` 的 lease 使用；
- 系统 TTS 不 acquire；
- 路由变化只报告，不主动重建 Capturer/Renderer；
- Session 被撤销时按现有有限退避恢复，并通知当前 lease 用户核对资源健康；
- 不拥有后台任务，也不修改录播 demand。

### 5.15 `AudioCuePlayer`

保留提示音播放能力，但需求归入输出侧：

- thinking cue 活跃时计入 playback demand；
- 正文 TTS 开始前 `yieldForSpeech()`；
- accepted/running/stop/error 提示不改变采集、ASR或消息路由；
- accepted 只在有效收句/接受后一次性播放，running 只在无用户讲话和无正文时循环，stop 在本地清理和服务端确认后播放，同一 error 不重复轰炸；
- `AudioCuePlayer` 只能作为 Output 的窄执行器，不得和正文/重读并发持有输出；
- cue 完成后通知 VoiceOutputCoordinator 重新计算 playback demand；
- 不直接调用 `BackgroundAudioTaskOwner`。

### 5.16 `EntryAbility` 与页面生命周期

只负责诊断和资源最终释放：

- `onForeground/onBackground` 记录 ability state；
- 页面 show/hide 不调用录音、播放、Gateway 重连或后台模式切换；
- `onDestroy` 调用 Controller 的统一 `release()`，后者依次停止输入、输出、continuity 和 runtime；
- 屏幕锁定状态若无法通过稳定公开 API 获取，不新增业务状态，真机日志使用系统电源事件对齐。

## 6. 具体场景调用链

以下场景是代码和测试的最小行为单元。

### 6.1 场景责任速查

| 场景 | 主责组件 | 协作组件 | 所属切片 |
| --- | --- | --- | --- |
| `S00` 应用空闲 | AudioContinuityCoordinator | Input、Output、Background owner | A |
| `S01` 开启麦克风 | VoiceInputCoordinator | Continuity、CaptureSupervisor、ASR engine | A/B/C |
| `S02` 收音中息屏 | CaptureSupervisor | EntryAbility、Continuity、ASR engine | B/F |
| `S03` 仅系统指令模式开始 TTS | VoiceOutputCoordinator | Continuity、Queue、SystemTtsPlayer | A/C/D |
| `S04` 收音时开始播报 | VoiceOutputCoordinator | Continuity、CaptureSupervisor、player | A/B/D |
| `S05` 播放中息屏 | 当前 TTS player | EntryAbility、Continuity、Queue | C/E/F |
| `S06` 播放中真人开口 | SingleAgentController | Input、Output、Queue、player | D/E |
| `S07` 话语完成后恢复 | SingleAgentController | Input、Output、Queue、player | D/E |
| `S08` 播放中关闭/打开话筒 | VoiceInputCoordinator | ASR engine、system command gate | A/B/C |
| `S09` 播放中静音 | VoiceOutputCoordinator | Queue、player、Continuity | A/D/E |
| `S10` 精确停止任务 | SingleAgentController | HermesRuntime、Output、Continuity | A/D |
| `S11` Capturer 失活 | CaptureSupervisor | PcmCapture、CommunicationAudioSession、Input | B |
| `S12` 本地 ASR 轮换 | SystemAsrEngine | VoiceInputCoordinator | C |
| `S13` 远端 ASR 断线 | RemoteAsrEngine | CaptureSupervisor、Input、Gateway 状态 | B/C |
| `S14` 系统 TTS 完成/旧回调 | SystemTtsPlayer | Queue、Output | C/D |
| `S15` 远端 TTS 与 drain | RemoteTtsPlayer | StreamingTtsClient、PcmPlayer、Output | E |
| `S16` 历史重读 | VoiceOutputCoordinator | Segmenter、Queue、selected player | D/E |
| `S17` 切换会话/Agent | SingleAgentController | Input、Output、Continuity、HermesRuntime | A-F |
| `S18` 路由变化 | CommunicationAudioSession | Controller、PcmCapture、PcmPlayer | B/E/F |
| `S19` AudioSession 撤销 | CommunicationAudioSession | CaptureSupervisor、PcmPlayer | B/E |
| `S20` 组合租约失败 | AudioContinuityCoordinator | Background owner、Input、Output | A |
| `S21` 进程被终止 | EntryAbility/启动恢复 | Controller、HermesRuntime、持久设置 | F |

切片字母对应第 10 节。主责组件决定场景状态迁移，协作组件只执行窄接口或上报事件。

### 6.2 场景详细逻辑

#### `S00` 应用空闲

- 前置：`R=0, P=0`。
- 调用：Input/Output 均将 demand 设为 false；Continuity 调用 Background owner stop。
- 结果：无 Capturer、无 Renderer、无活动 TTS request、后台租约 idle。
- 约束：Gateway 可以保持在线；空闲不等于断开会话。

#### `S01` 用户开启麦克风

- 触发：UI 麦克风按钮。
- 顺序：Controller -> Input wanted=true -> Continuity recording=true -> selected ASR 与 CaptureSupervisor 并行准备 -> CaptureSupervisor 等待 lease ready 后启动 PcmCapture -> ASR ready 且 Capturer RUNNING/首 PCM -> UI listening。
- 失败：权限拒绝直接终止；租约、Capturer 或 ASR 启动失败进入明确 error；用户已执行退出软件时，迟到成功立即释放。
- 结果：`B10`。

#### `S02` 持续收音期间息屏/进入后台

- 触发：系统生命周期变化，无用户命令。
- 顺序：EntryAbility 只记录环境；Continuity、Capturer、ASR 不执行迁移；CaptureSupervisor 持续核对 PCM。
- 异常：只有 state/interrupt/no-PCM 证据才触发 `S11` 恢复。
- 结果：仍为 `B10`，generation 不变。

#### `S03` 仅系统指令模式开始系统 TTS

- 触发：输出队列产生首个 chunk，采集和ASR持续，消息路由为 `system_commands_only`。
- 顺序：Output playback=true -> Continuity 复用 ready 租约 -> Queue activate -> SystemTtsPlayer play -> onStart -> UI playing。
- 完成：terminal 匹配后推进下一 chunk；全部完成后 playback=false，因完整输入链路仍启动而保持租约。
- 禁止：lease starting 时调用 `speak()`。
- 结果：始终为持续输入，播放期间全双工，完成后继续只响应系统指令。

#### `S04` 持续收音时开始播报

- 前置：`B10` 且组合租约已经 ready。
- 顺序：Output playback=true；Continuity 发现租约已 ready；播放器启动；CaptureSupervisor 和 ASR 不停止。
- 结果：`B11`。
- 禁止：切换为 playback-only 后台模式、重建 Capturer、关闭识别 Session。

#### `S05` 播放中息屏

- 触发：系统环境变化。
- 顺序：只记录环境；当前 job、chunk、request、Capturer 和租约不变。
- 完成：仍由 TTS terminal 或 PCM drain 推进，而不是屏幕事件。
- 异常：真实平台中断分别进入 `S11` 或 `S15`。

#### `S06` 播放中检测到真人说话

- 触发：ASR 音频开始/有效 partial。
- 顺序：Input 发 `userSpeechStarted` -> Controller -> Output pauseForUser；Capture/ASR 继续。
- 系统 TTS：stop 当前 request，Queue 保留完整当前 chunk。
- PCM：PcmPlayer 精确 pause，保留 PCM 偏移。
- 结果：`B11 + P=paused`，租约保持 ready。
- 禁止：清空队列或按时间估算并删除已“推测播放”的文字。

#### `S07` 用户话语完成并恢复播报

- 触发：Input final 被提交、作为协议回复消费，或判定为空而丢弃。
- 顺序：Input 发 utterance resolved -> Controller -> Output resumeAfterUser。
- 系统 TTS：重新播放当前完整短 chunk；PCM：从暂停位置继续。
- 结果：回到 `B11` 或队列结束后的 `B10`。

#### `S08` 播放中关闭或打开话筒

- 触发：按钮或精确“关闭话筒/打开话筒”。
- 关闭顺序：Input routing=system_commands_only；Capturer、ASR、Output 和组合租约保持。普通 final 本地丢弃，只执行停止任务、打开话筒、退出软件。
- 打开顺序：Input routing=conversation；复用原 Capturer、ASR和收句缓冲，恢复普通消息提交。
- 结果：只有消息路由变化，物理输入和播放状态不变。
- 禁止：停止 Capturer/ASR、Agent或播报；冷启动未手动启动完整链路时不得靠语音自行启动。

#### `S09` 播放中静音

- 触发：用户打开 muted。
- 顺序：Output generation++ -> Queue clear -> Player stop -> playback demand=false。
- 如果麦克风开启：Continuity 仍保持组合租约；否则停止租约。
- 结果：`B11 -> B10` 或 `B01 -> B00`。
- 禁止：修改 captureChainStarted/inputRouting、调用 session.interrupt。

#### `S10` 精确停止任务

- 触发：停止按钮或精确整句“停止任务”。
- 顺序：Output generation++，停止正文、重读、待播和呼吸音 -> Runtime 执行 Hermes `/stop` 等价动作，取消当前及全部排队任务 -> 清本地 busy/queued/protocol 状态 -> 服务端确认后播放一次停止提示。
- 结果：任务链和输出队列为空；完整输入链路和消息路由保持。
- 迟到 Agent/TTS 回调因旧 generation 被忽略。

#### `S11` Capturer 失活或无 PCM

- 触发：stateChange、audioInterrupt、2 秒无 PCM、AudioSession 恢复后仍无数据。
- 顺序：PcmCapture event -> CaptureSupervisor requestRecovery -> health=recovering -> 串行 stop/start -> 首 PCM -> healthy。
- 合并：同一恢复期间的其他触发只追加 reason。
- 失败：三次耗尽 -> health=failed -> Input UI error；captureChainStarted/inputRouting 保持为用户意图，但 UI 不得显示 listening。
- 租约：全过程保持 recording demand=true，不 stop/start 后台任务。

#### `S12` 本地 ASR Session 到达 18 秒预算

- 触发：SystemAsrEngine 写入预算达到上限。
- 顺序：finish 旧 session -> 保留后续 PCM pre-roll -> 创建新 session -> ready -> flush。
- 不变：CaptureSupervisor、PcmCapture、AudioSession、Continuity generation。
- 失败：识别 Session 有界恢复；不得重建健康的 Capturer。

#### `S13` 远端 ASR 断线

- 触发：RemoteAsrEngine socket error/close。
- 顺序：保持 Capturer；缓存有限 PCM；远端引擎有界重连；ready 后 flush。
- 对话：已有有效 partial/final 由 Input 按终止规则收尾，不静默丢弃。
- 取消：退出软件、切系统后端、切会话/Agent或鉴权终止错误；关闭/打开话筒不取消。

#### `S14` 系统 TTS 分段完成和陈旧回调

- 正常：SystemTtsPlayer 发匹配 terminal -> Output/Queue 完成当前 chunk -> 启动下一段。
- 陈旧：requestId、generation、jobId 或 chunkIndex 任一不匹配，记录并忽略。
- 队列空：playback demand=false；Continuity 根据 recording demand 决定保持或停止。
- 能力边界：`onComplete` 仍不能证明完整听感；真机仍漏播则进入 PCM 升级条件。

#### `S15` 远端 TTS 合成结束与 PCM drain

- Provider end：RemoteTtsPlayer 标记 synthesis complete，不发 completed。
- Renderer queue 未空：继续播放。
- Renderer drain：发匹配 terminal completed，Output 才推进下一 chunk/job。
- Renderer 失活：PcmPlayer 原位重建并保留 PCM；恢复耗尽发 error。

#### `S16` 历史重读或新重读替换旧播放

- 触发：消息气泡重读按钮。
- 顺序：Output replay generation++ -> stop/隔离旧 job -> 使用同一 Segmenter/Queue 创建 replay job -> playback demand=true -> ensureReady -> 播放。
- 再次点击当前重读：停止该 job，不影响麦克风和 Agent。
- 禁止：维护 replay 专属分段器或息屏路径。

#### `S17` 切换会话或 Agent

- 顺序：Controller sessionGeneration++ -> Input reset/stop -> Output reset/stop -> Continuity clear old generation -> Runtime resume/create。
- 是否恢复麦克风/输出意图由高层设置显式保存并在新 generation 重新申请，不能沿用旧异步 Promise。
- 旧 ASR/TTS/Gateway 回调全部隔离。

#### `S18` 音频路由变化

- 触发：有线、蓝牙、USB、NearLink 插拔或用户切换扬声器。
- 顺序：CommunicationAudioSession 更新路由 -> Controller/UI 更新标签。
- 正常情况下不重建 Capturer/Renderer；只有随后产生真实失活事件才进入 `S11/S15`。
- 禁止：使用输出设备推断输入设备，或调用手工媒体输入选择。

#### `S19` Communication AudioSession 被系统撤销

- 顺序：Session 组件按 `100/500/1500 ms` 恢复 -> 通知当前 lease 用户核对健康。
- CaptureSupervisor：若 PCM 正常则不重建；若无 PCM 进入 `S11`。
- PcmPlayer：若 Renderer 无推进则进入自身重建。
- SystemTtsPlayer：不属于该 Session，不被应用强制重启。

#### `S20` 组合后台租约启动失败

- 录音启动：CaptureSupervisor 不得越过 ready 门；Input 显示无法持续录音。
- 播放启动：首段保留 queued，不能无保护直接 speak；有限重试耗尽后 job error。
- 已在前台也执行同样规则，避免随后息屏才暴露问题。
- 目标真机拒绝双模式时记录平台证据，再走文档定义的降级设计，不在运行时静默切回旧逻辑。

#### `S21` 应用被强制停止或系统杀死

- 当前进程内状态不可恢复，后台租约不能对抗强制终止。
- 下次启动恢复持久设置和 Hermes Session；运行中的 PCM、TTS chunk 和 ASR interim 不宣称已恢复。
- 日志和 UI 应区分“上次会话可恢复”与“上次音频仍在继续”。

主动“退出软件”与本故障序列不同：Controller 先阻断新任务和自动重连，再依次释放 Output、Input、Continuity 和 Runtime，最后终止 UIAbility；局部释放失败不得阻止其余资源继续关闭。退出默认不调用 Hermes `/stop`，远端任务在下次恢复同一会话时对账。

## 7. 状态写权限表

| 状态 | 唯一写入者 | 只读消费者 |
| --- | --- | --- |
| `captureChainStarted/inputRouting` | VoiceInputCoordinator | Controller、Continuity、UI 投影 |
| `recording health` | CaptureSupervisor | Input、诊断 |
| `recognition backend state` | System/RemoteAsrEngine | Input |
| `utterance buffer` | VoiceInputCoordinator | UI 投影 |
| `outputEnabled/muted` | VoiceOutputCoordinator | Controller、UI |
| `SpeechJob/activeChunk` | SpeechPlaybackQueue | Output、诊断 |
| `player state` | System/RemoteTtsPlayer | Output |
| `PCM renderer state` | PcmPlayer | RemoteTtsPlayer |
| `capture/playback demand` | AudioContinuityCoordinator | 诊断 |
| `background lease state` | BackgroundAudioTaskOwner | Continuity、诊断 |
| `AudioSession/route` | CommunicationAudioSession | Capture、Player、Controller |
| UI `SingleAgentSnapshot` 投影 | 对应协调器，经 Controller 汇总 | Index |

禁止用 `SingleAgentSnapshot.playback/asrState` 反向驱动平台资源；Snapshot 是输出，不是状态机输入。

## 8. 现有代码迁移表

| 现有文件/逻辑 | 目标位置 | 处理方式 |
| --- | --- | --- |
| `SingleAgentController.backgroundAudioTask`、`syncBackgroundVoiceTask()` | AudioContinuityCoordinator | 删除优先级选择，改成两个独立 demand |
| `BackgroundAudioIntent = none/recording/playback` | BackgroundAudioTaskOwner | 改为固定组合租约状态，不表达互斥意图 |
| `VoiceInputCoordinator.capture/capturing/startCapture()` | CaptureSupervisor | 迁出物理采集生命周期 |
| `VoiceInputCoordinator.remoteAsrReconnect*` | RemoteAsrEngine | 迁出远端连接恢复 |
| `VoiceInputCoordinator.systemRecognitionRestart*` | SystemAsrEngine | 迁出本地识别 Session 恢复 |
| `SystemSpeechService.capture/captureRunning` | 删除并使用共享 CaptureSupervisor | 消除本地/远端两套 Capturer 所有权 |
| `SystemSpeechService` 识别 listener、PCM 写入、18 秒轮换 | SystemAsrEngine | 完整迁移 |
| `SystemSpeechService` TTS engine、request listener、voices | SystemTtsPlayer | 完整迁移 |
| `SystemSpeechQueue.flush/chunkEnd` | SpeechSegmenter | 保留纯分段算法 |
| `SystemSpeechQueue.active/queue/markStarted` | SpeechPlaybackQueue | 抽出公共播放队列 |
| `SystemSpeechQueue.remainingText()` | 删除 | 系统 TTS 恢复重播完整当前 chunk |
| `VoiceOutputCoordinator.startSystemSpeech/onSystemSpeechState` | SystemTtsPlayer + 公共 queue 回调 | 协调器只推进 job |
| `VoiceOutputCoordinator.onRemoteJob*`、remote drain/reconnect | RemoteTtsPlayer | 封装远端完整后端生命周期 |
| `VoiceOutputCoordinator.prefersBackgroundPlayback/hasBackgroundOutput` | AudioContinuityCoordinator demand | 删除快照反推后台模式 |
| `PcmPlayer` Renderer 看门、恢复、drain | PcmPlayer | 保留并补强 generation |
| `CommunicationAudioSession` | 原文件 | 暂不按行数拆分，先保持平台音频会话聚合 |
| `EntryAbility` 无前后台事件 | EntryAbility | 只补诊断和最终 release，不加业务分支 |

## 9. 文件落点

沿用当前扁平 `services/` 结构，P0 不同时做目录迁移：

```text
models/
  SingleAgentState.ets              # UI 快照，保持
  VoiceAudioContracts.ets           # 新增：类型化音频事件/状态

services/
  AudioContinuityCoordinator.ets    # 新增：录播需求与 ready 门
  BackgroundAudioTaskOwner.ets      # 重写：组合后台租约
  CaptureSupervisor.ets             # 新增：采集健康与恢复
  PcmCapture.ets                    # 收敛：一次物理 Capturer
  SystemAsrEngine.ets               # 新增：从 SystemSpeechService 拆出
  RemoteAsrEngine.ets               # 新增：包装 StreamingAsrClient
  VoiceInputCoordinator.ets         # 收敛：意图、收句、控制词
  SpeechSegmenter.ets               # 从 SystemSpeechQueue 拆出
  SpeechPlaybackQueue.ets           # 新增：公共 job/chunk 状态
  SystemTtsPlayer.ets               # 新增：从 SystemSpeechService 拆出
  RemoteTtsPlayer.ets               # 新增：TTS WS + PcmPlayer
  VoiceOutputCoordinator.ets        # 收敛：job 语义、控制和后端选择
  PcmPlayer.ets                     # 保留：PCM Renderer
  CommunicationAudioSession.ets     # 保留：Session/路由
  AudioCuePlayer.ets                # 保留：提示音
  SingleAgentController.ets         # 收敛：命令门面和跨域协调
```

迁移完成后删除 `SystemSpeechService.ets` 和 `SystemSpeechQueue.ets`；在完成前允许它们作为兼容壳，但不得再新增业务逻辑。

## 10. 分阶段拆解与验收

### 切片 A：组合租约

- 新增 contracts 和 AudioContinuityCoordinator；
- 重写 Background owner；
- Input/Output 分别上报 demand；
- 删除 Controller 的录播优先级。

验收：`S00-S05`、`S08-S10`、`S20`；行为测试必须证明租约只启动一次且首段/采集等待 ready。

### 切片 B：统一采集

- 新增 CaptureSupervisor；
- PcmCapture 增加平台事件；
- 本地/远端 ASR 共用一个 Capturer；
- 增加无 PCM 看门和有限恢复。

验收：`S01-S02`、`S11-S13`、`S18-S19`；真机连续收音至少 5 分钟。

### 切片 C：系统 ASR/TTS 分离

- 从 SystemSpeechService 拆出 SystemAsrEngine 和 SystemTtsPlayer；
- request/session generation 全覆盖；
- 保留原行为，不同时升级 PCM TTS。

验收：`S12`、`S14`；旧回调不能推进新 Session/job。

### 切片 D：公共播放 job

- 拆 SpeechSegmenter 和 SpeechPlaybackQueue；
- 新消息、重读、协议播报和四类提醒共用唯一输出仲裁；
- 删除按时长估算剩余文本。

验收：`S03-S10`、`S14`、`S16-S17`；系统 TTS 最多重复当前短段，不吞字。

### 切片 E：远端播放后端

- 新增 RemoteTtsPlayer；
- 从 Output 移出 TTS socket、PCM 回调和 drain；
- 收紧 PcmPlayer generation。

验收：`S06-S07`、`S15-S19`；Provider end 不等于播放完成。

### 切片 F：生命周期、日志和全矩阵

- EntryAbility 只补环境日志和 release；
- 统一关联字段；
- 跑全部行为测试和真机场景矩阵。

验收：亮屏/息屏调用链一致；日志可以还原 demand、lease、Capturer、request、Renderer 和恢复顺序。

## 11. 拆解红线

- 不新增全局事件总线、Service Locator 或通用状态框架。
- 不按一个方法一个文件拆分。
- 不让 UI Snapshot 成为平台资源的决策输入。
- 不让输入协调器直接持有输出协调器；跨域暂停/恢复通过 Controller 的高层回调协调。
- 不让 ASR 后端创建自己的 Capturer。
- 不让 TTS 后端决定后台租约需求。
- 不在拆组件时改变 Hermes 协议、1.8 秒收句语义或系统/远端后端选择策略。
- 每个切片必须先有故障序列测试，再删除旧路径；不允许新旧两个状态所有者长期并存。
