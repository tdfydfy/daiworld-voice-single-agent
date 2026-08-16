# HarmonyOS 语音运行时架构收敛与执行方案

更新时间：2026-08-16

状态：待实施

当前执行入口：[当前计划](PLAN.md)

业务权威：[HarmonyOS 音频用户旅程与业务逻辑](HARMONYOS_AUDIO_USER_JOURNEY.md)

## 1. 文档目的

本文把以下真机问题归并为一次语音运行时架构收敛，而不是继续逐项打补丁：

- 频繁出现恢复、连接或音频资源错误；
- 恢复旧会话后麦克风不能可靠重新工作；
- 息屏后录音或播报中断；
- 收到、思考、停止和错误提示音时有时无；
- 文件已经拆分，但状态所有权、异步代际和资源释放仍未闭环。

目标不是增加更多 Coordinator，而是让现有输入、输出、后台保护和 Session 生命周期各自只有一个事实来源，并由一个串行语音运行时协调跨域动作。

## 2. 最终交付结果

完成后必须同时满足：

1. 恢复同一 Profile 下的历史 Session 不停止健康的 Capturer、ASR 或后台音频保护。
2. Session、Profile、语音后端切换和应用释放均有统一 `epoch`；旧回调不能推进新状态。
3. 本地和远端 ASR 共用唯一 `CaptureSupervisor` 与唯一 `PcmCapture`。
4. 新回复、历史重读、协议播报和四类提示音都进入唯一 `SpeechPlaybackQueue`。
5. 系统 TTS、远端 PCM 和提示音虽然使用不同执行后端，但任一时刻只有一个有效播放作业。
6. 后台保护由录音需求和播放需求两个独立事实驱动，不再由 UI 通知顺序临时猜测。
7. 音频 Session、Capturer、Renderer、ASR、TTS 和后台任务恢复都有明确的成功、恢复中和终止失败状态。
8. 应用释放是幂等、可等待的事务；退出后不残留 socket、timer、后台任务或自动重连。
9. 自动化测试执行真实异步序列，不再用源码正则表达式代替行为验证。

## 3. 非目标

- 不重写 Hermes 会话协议和 Agent 业务逻辑。
- 不在本轮调整 UI 视觉、ASR 停顿阈值或模型选择体验。
- 不把亮屏、息屏、前台和后台实现为不同业务状态机。
- 不为每个故障新增独立 Manager、Supervisor 或重试定时器。
- 不在没有目标真机证据时宣称某一种 HarmonyOS 后台模式可以同时保证录音和系统 TTS。

## 4. 已确认的结构性问题

### 4.1 Session 切换与音频停止并发

当前 `resumeSession()` 调用 `stopVoice()` 后立即恢复 `wanted`，但输入停止过程仍在异步释放 Capturer 和识别 Session。远端路径的 `startCapture()` 会在旧 `capturing=true` 时直接返回，旧停止完成后也不会补发启动。

结论：Session 切换必须成为可等待事务；同一 Profile 的 Session 切换不应重启与 Session 无关的健康音频资源。

### 4.2 本地和远端输入各自持有 Capturer

`VoiceInputCoordinator` 和 `SystemSpeechService` 各自构造 `CaptureSupervisor`。这形成两套 wanted、starting、running、recovery 和 stop/start 时序。

结论：Capturer 属于设备输入，不属于 ASR 后端。ASR 后端只消费 PCM。

### 4.3 后台模式以单一枚举表达两个并存需求

当前 `recording | playback` 互斥枚举导致每次录播切换都先停止旧后台任务。提示音活跃但麦克风开启时，控制器仍选择 `recording`，提示音不会等待播放保护 ready。

结论：业务状态必须保存 `{ recordingDemand, playbackDemand }`；具体映射到哪个平台模式由可替换策略决定。

### 4.4 可听输出只有名义上的统一

提示音直接创建独立 `PcmPlayer(false)`；系统 TTS、远端 PCM 和提示音没有公共作业 ID、优先级、取消确认和完成边界。远端 TTS 只有连接 generation，没有播放 job generation。

结论：所有声音先成为 `PlaybackJob`，再由单一队列选择执行后端。

### 4.5 恢复失败没有统一终态

AudioSession 恢复耗尽只写日志，Renderer 恢复可无限重试，部分错误又通过一个共享 `snapshot.error` 互相覆盖。

结论：所有平台资源必须向上发出类型化健康事件；有限恢复耗尽后进入明确失败态并停止自动重试。

## 5. 目标结构

```text
Index / SingleAgentController
              |
              | user command / Hermes event
              v
        VoiceRuntime
  serialized mailbox + epoch + reducer
       /          |             \
      v           v              v
VoiceInput   VoiceOutput   BackgroundAudioTaskOwner
Coordinator Coordinator        + policy
      |           |
      |           +--> SpeechPlaybackQueue
      |                   |       |       |
      |                   v       v       v
      |              SystemTts RemoteTts CueRenderer
      |
      +--> one CaptureSupervisor --> one PcmCapture
                     |
                     +--> SystemAsrEngine
                     +--> RemoteAsrEngine
```

### 5.1 依赖方向

- `SingleAgentController` 只把 UI 命令和 Hermes 事件交给 `VoiceRuntime`，不再判断 Capturer、TTS 或后台任务内部状态。
- `VoiceRuntime` 是唯一跨输入、输出、Session 和后台保护的协调点。
- `VoiceInputCoordinator` 只拥有输入意图、收句和当前 ASR 后端。
- `VoiceOutputCoordinator` 只拥有播放作业、优先级和用户暂停语义。
- 平台适配器只能发事件，不能直接修改 `SingleAgentSnapshot`。
- 不引入全局事件总线；所有依赖通过构造参数中的窄接口注入。

Runtime 的串行边界只负责同步状态转换，不在 mailbox 内等待平台 Promise：

```text
command/event
  -> mailbox reducer: validate epoch, update state, emit Effect
  -> effect runner: await platform/Hermes operation outside mailbox
  -> completion event(epoch, result)
  -> mailbox reducer: commit only when epoch is still current
```

这样 `stop`、`switchSession` 和 `dispose` 可以立即使旧 effect 失效，不会被一个卡住的 Capturer、CoreSpeech 或网络 Promise 阻塞。命令返回的 Promise 由 transaction ID 对应的终态事件 resolve/reject，不代表 mailbox 自身一直被占用。

### 5.2 应删除或收窄的结构

- 删除只有转发作用的 `AudioContinuityCoordinator`；由 `VoiceRuntime` 直接依赖 `BackgroundAudioTaskOwner` 接口。
- 从 `SystemSpeechService` 拆出 `SystemAsrEngine` 和 `SystemTtsPlayer`，完成后删除 `SystemSpeechService`。
- `AudioCuePlayer` 不再持有 `PcmPlayer`；保留波形数据和 Cue 执行适配，生命周期归 `SpeechPlaybackQueue`。
- `VoiceInputCoordinator`、`VoiceOutputCoordinator` 不再接收可写 `SingleAgentSnapshot`。

## 6. 唯一状态模型

### 6.1 运行时状态

```ts
export type VoiceRuntimePhase =
  'idle' | 'ready' | 'switching_session' | 'reconfiguring' | 'disposing' | 'failed';

export type InputIntent = 'off' | 'conversation' | 'commands_only';
export type ResourceHealth =
  'stopped' | 'starting' | 'healthy' | 'recovering' | 'failed';

export class VoiceRuntimeState {
  epoch: number = 0;
  phase: VoiceRuntimePhase = 'idle';
  inputIntent: InputIntent = 'off';
  captureHealth: ResourceHealth = 'stopped';
  asrHealth: ResourceHealth = 'stopped';
  playbackHealth: ResourceHealth = 'stopped';
  recordingDemand: boolean = false;
  playbackDemand: boolean = false;
  storedSessionId: string = '';
  runtimeSessionId: string = '';
  activePlaybackJobId: string = '';
  failure?: VoiceFailure;
}
```

### 6.2 状态写权限

| 事实 | 唯一写入者 | 其他组件如何取得 |
| --- | --- | --- |
| `epoch/phase` | `VoiceRuntime` | 只读快照 |
| 完整话筒链路和消息路由 | `VoiceInputCoordinator` 事件，经 Runtime reducer 落地 | `VoiceRuntimeState.inputIntent` |
| Capturer 真实健康 | `CaptureSupervisor` 事件，经 Runtime reducer 落地 | `captureHealth` |
| ASR 后端健康 | 当前 `AsrEngine` 事件 | `asrHealth` |
| 播放队列和活动 job | `SpeechPlaybackQueue` | `activePlaybackJobId/playbackDemand` |
| 后台任务状态 | `BackgroundAudioTaskOwner` | 类型化 continuity 事件 |
| Session 身份 | `HermesRuntime` 成功结果，经 `VoiceRuntime` 提交 | `storedSessionId/runtimeSessionId` |
| 用户可见错误 | `VoiceRuntime` 错误归并器 | 派生到 UI 快照 |

禁止输入、输出、平台适配器直接写 `snapshot.voiceEnabled`、`snapshot.asrState`、`snapshot.playback`、`snapshot.ttsState` 或 `snapshot.error`。这些字段在迁移期由 Runtime 从新状态派生。

### 6.3 三种代际

| 标识 | 变化时机 | 隔离范围 |
| --- | --- | --- |
| `epoch` | Session/Profile/后端切换、完整停止、dispose | 整个语音运行时 |
| `captureGeneration` | Capturer 物理启动或恢复 | 单个 Capturer 实例 |
| `playbackJobId` | 每个正文、重读、协议播报或提示音作业 | 单次可听输出 |

Runtime effect、ASR 结果和 continuity 回调必须携带发起时的 `epoch`；播放回调再携带 `playbackJobId`。Capturer 是可跨 Session 保留的物理资源，其底层回调携带 `captureGeneration`，由 `VoiceInputCoordinator` 在同步 PCM 路由边界附加当前 `epoch`。不匹配时只记录日志，不修改状态。

同一 Profile 切换 Session 时不重建健康的 Capturer 和 ASR engine，但必须调用 `AsrEngine.bindEpoch(newEpoch)` 清空未完成话语并重绑结果路由。切换前已经开始的话语保留旧 epoch，即使 final 迟到也会被丢弃；切换完成后的新话语才使用新 epoch。若某个后端无法安全重绑，则只轮换该后端的逻辑识别 session/connection，不释放 Capturer 或重建 engine。

## 7. 核心接口

### 7.1 `VoiceRuntime`

```ts
export interface VoiceRuntimeCommands {
  enableConversationInput(): Promise<void>;
  setInputMode(mode: InputIntent): Promise<void>;
  switchSession(storedSessionId: string): Promise<void>;
  switchProfile(profile: string): Promise<void>;
  switchSpeechBackend(backend: SpeechBackend): Promise<void>;
  enqueueSpeech(request: SpeechRequest): Promise<string>;
  stopAllTasks(): Promise<void>;
  dispose(): Promise<void>;
}
```

实现要求：

- 所有命令和适配器事件进入同一个 mailbox/reducer 顺序处理；reducer 只做同步状态转换并产出 effect。
- 会破坏旧生命周期的命令进入 reducer 时先递增 `epoch`，再启动任何 effect；effect 等待期间不得占用 mailbox。
- 每个 effect 的完成、失败和超时都作为携带 `epoch + transactionId` 的事件回投，只有当前 epoch 可以提交结果。
- 每个硬件或网络等待都有超时；`dispose()` 不得被一个永不返回的 start 阻塞。
- 生命周期方法全部返回 `Promise<void>`；禁止 Controller 对 stop/start 使用 fire-and-forget。

### 7.2 `CaptureSupervisor`

```ts
export interface CapturePort {
  start(epoch: number): Promise<CaptureReady>;
  stop(epoch: number): Promise<void>;
  onPcm(listener: (event: CapturePcmEvent) => void): void;
  onHealth(listener: (event: CaptureHealthEvent) => void): void;
}
```

规则：

- 只允许一个 `PcmCapture`。
- `start()` 在 AudioCapturer 为 RUNNING 且收到首块 PCM 后才 resolve；“已安排恢复”不能冒充 ready。
- STOPPED、RELEASED、INVALID、需要恢复的 interrupt 和连续 2 秒无 PCM 汇入同一个恢复入口。
- 恢复预算为 60 秒窗口内最多 3 次；连续稳定 PCM 10 秒后才清零，不能由单块 PCM 立即重置全部预算。
- 耗尽后发出 `failed`，不自行修改用户意图，也不无限重试。

### 7.3 ASR 后端

```ts
export interface AsrEngine {
  start(epoch: number): Promise<void>;
  bindEpoch(epoch: number): void;
  acceptPcm(event: CapturePcmEvent): void;
  finishUtterance(epoch: number): Promise<void>;
  stop(epoch: number): Promise<void>;
  onEvent(listener: (event: AsrEvent) => void): void;
}
```

- `SystemAsrEngine` 只封装 CoreSpeech engine/session，不创建 Capturer。
- `RemoteAsrEngine` 包装 `StreamingAsrClient`，不拥有 Capturer。
- `bindEpoch()` 同步关闭旧话语接收门并清空未确认缓冲；旧话语事件继续携带旧 epoch，禁止通过读取“当前 epoch”给迟到结果重新盖章。
- 后端切换时保留健康 Capturer，只停止旧 ASR、启动新 ASR 并切换 PCM sink。
- ASR Session 的 18 秒轮换只改变 `SystemAsrEngine` 内部 session，不改变 Runtime epoch。

### 7.4 播放作业

```ts
export type PlaybackKind = 'assistant' | 'replay' | 'protocol' | 'cue';
export type PlaybackPriority = 10 | 20 | 30 | 40;

export class PlaybackJob {
  id: string = '';
  epoch: number = 0;
  kind: PlaybackKind = 'assistant';
  priority: PlaybackPriority = 20;
  text: string = '';
  cue: CueKind | '' = '';
  segmentIndex: number = 0;
}
```

优先级固定为：

```text
stop/error cue: 40
user speech pause: immediate control action
assistant/replay/protocol: 20
accepted cue: 10
thinking pulse: 10 and skippable
```

队列规则：

- 所有作业先进入 `SpeechPlaybackQueue`，禁止直接调用 `PcmPlayer.enqueue()` 或 `SystemSpeechService.speak()`。
- 每次只激活一个 job；后端回调必须同时匹配 `epoch + jobId`。
- 正文活跃时，accepted/thinking cue 延后到安全边界或直接省略。
- cue 开始前也必须等待 `ensurePlaybackReady(epoch)`。
- `CueRenderer` 使用与语音输出一致的通信路由；不再创建 `PcmPlayer(false)` 绕过 AudioSession。
- 系统 TTS 从完整短段检查点恢复；允许重播当前短段，不估算字符位置后吞字。

### 7.5 远端 TTS 取消边界

远端二进制 PCM 帧目前没有 job ID。第一阶段采用以下强边界：

1. 一个 WebSocket connection generation 同时只执行一个 job。
2. 正常 job 结束后收到匹配的 `end` 才启动下一 job。
3. Session 切换、stop、replay 替换和 dispose 时关闭 TTS socket，而不是在同一 socket 上立即复用。
4. 新 job 在新 connection generation 上启动，旧 PCM 自动因 connection generation 不匹配而丢弃。
5. Adapter/Provider 后续在 `start/end/error` 文本帧中回显 `job_id`；二进制帧不加头的前提下仍保持单 job connection 约束。

### 7.6 后台保护

```ts
export class AudioDemand {
  recording: boolean = false;
  playback: boolean = false;
}

export interface AudioContinuityPort {
  setDemand(epoch: number, demand: AudioDemand): Promise<void>;
  ensureRecordingReady(epoch: number): Promise<void>;
  ensurePlaybackReady(epoch: number): Promise<void>;
  release(epoch: number): Promise<void>;
}
```

规则：

- `recordingDemand = inputIntent !== 'off'`，即使 Capturer 正在恢复也保持。
- `playbackDemand = queue 非空 || job 活跃 || 必要 cue 活跃`。
- 只有 Runtime reducer 可以改变 demand；UI `notify()` 不再触发后台模式推导。
- `BackgroundAudioTaskOwner` 保存 demand 向量和平台实际模式，后台策略与业务状态分离。
- 当前专用模式切换先作为一个 `DedicatedModePolicy` 保留，便于小步迁移；是否继续使用由第 12 节真机能力门决定。

### 7.7 类型化错误

```ts
export class VoiceFailure {
  domain: 'session' | 'capture' | 'asr' | 'playback' | 'continuity' = 'session';
  code: string = '';
  epoch: number = 0;
  recoverable: boolean = false;
  userVisible: boolean = true;
  dedupeKey: string = '';
  message: string = '';
}
```

- 组件不得清除其他 domain 的错误。
- 错误提示音只由新的、用户可见的 `dedupeKey` 触发一次。
- 自动恢复中的瞬态故障进入诊断日志和健康状态，不立即轰炸用户。
- 恢复耗尽才进入用户可见失败；文字对话和已确认消息继续可用。

## 8. 关键调用序列

### 8.1 恢复历史 Session

```text
UI.resumeSession(target)
  -> Runtime epoch++ / phase=switching_session
  -> Input.freezeSubmission(epoch)
       clear unfinished utterance
       AsrEngine.bindEpoch(epoch)
       keep healthy Capturer and initialized ASR engine running
  -> Output.cancelAll(epoch) and await completion
  -> Hermes.resumeSession(target)
  -> fetch detail
  -> if epoch current: commit runtime/stored identity and messages
  -> Input.resumeSubmission(epoch)
  -> phase=ready
```

失败处理：

- 在获得新 runtime session 前失败：恢复原 Session UI 身份并解除输入门。
- 服务端绑定状态不确定：尝试一次 `resumeSession(previousStoredId)` 对账。
- 对账仍失败：进入 `session` 失败态，Capturer/ASR 可以保持健康，但普通 Prompt 提交被阻止；用户仍可使用文字查看历史或重试。
- 成功、回滚或失败终态都保留本次新 epoch；不得把 Runtime epoch 回退到旧值。
- 禁止为了切换历史 Session 调用 `stopVoice()`。

### 8.2 首次开启话筒

```text
enableConversationInput
  -> epoch current / inputIntent=conversation
  -> continuity demand recording=true
  -> await recording ready
  -> await selected AsrEngine.start and attach PCM sink
  -> await CaptureSupervisor.start(first PCM)
  -> captureHealth=healthy && asrHealth=healthy
  -> UI listening
```

ASR sink 必须先就绪，避免 Capturer 首块 PCM 无消费者。后端切换时先冻结提交并准备新 sink，再在一个 reducer 事件中切换路由；切换窗口只允许使用有界 pre-roll，不提交跨后端拼接的话语。UI 只有在 Capturer RUNNING、近期收到 PCM 且 ASR ready 后显示“监听中”。

### 8.3 接受话语并播放提示音

```text
ASR final
  -> utterance accepted locally
  -> submit or queue to Hermes
  -> enqueue accepted cue job
  -> PlaybackQueue checks active正文/重读
       busy: delay or skip
       idle: playbackDemand=true -> await playback ready -> play cue
```

提示音失败只结束该低优先级 job，不改变输入、Agent 或正文状态。

### 8.4 Agent 正文播报

```text
Hermes speech delta/final
  -> create or append assistant PlaybackJob
  -> common segmenter
  -> playbackDemand=true
  -> await continuity playback ready
  -> SystemTtsPlayer or RemoteTtsPlayer starts(epoch, jobId, segment)
  -> matching completion advances one segment
  -> drain/complete all segments
  -> playbackDemand=false
```

### 8.5 息屏或进入后台

```text
Ability visibility event
  -> record diagnostics only
  -> do not increment epoch
  -> do not restart Session, Capturer, ASR or playback
  -> continuity keeps current demand and verifies health
```

### 8.6 统一释放

```text
dispose
  -> epoch++ / phase=disposing / block reconnect and new commands
  -> await Output.cancelAll
  -> await Input.stop (ASR then Capturer)
  -> await Continuity.release
  -> await HermesRuntime.disconnect and cancel timers
  -> phase=idle
```

`dispose()` 必须幂等；任一步失败都记录并继续后续清理。页面 `onPageHide`、Ability `onBackground` 和息屏不得调用 dispose。当前单页面结构可在 `aboutToDisappear()` 调用；显式“退出软件”复用同一方法后终止 UIAbility。

## 9. 文件落点

下表中的 `services/`、`pages/` 路径均相对于 `clients/harmony/entry/src/main/ets/`；`tests/` 位于仓库根目录。

### 9.1 新增

| 文件 | 职责 |
| --- | --- |
| `services/VoiceRuntimeState.ets` | 纯状态、事件和 reducer |
| `services/VoiceRuntime.ets` | mailbox、epoch、跨域命令和生命周期 |
| `services/SystemAsrEngine.ets` | CoreSpeech ASR engine/session，消费 PCM |
| `services/RemoteAsrEngine.ets` | `StreamingAsrClient` 的 ASR 适配 |
| `services/SpeechPlaybackQueue.ets` | job、优先级、分段、取消和完成 |
| `services/SystemTtsPlayer.ets` | CoreSpeech 系统播放适配 |
| `services/RemoteTtsPlayer.ets` | Streaming TTS + `PcmPlayer` 适配 |
| `tests/voice_runtime.test.js` | Runtime 异步序列测试 |
| `tests/playback_queue.test.js` | 输出作业和迟到回调测试 |

### 9.2 保留并修改

| 文件 | 修改方向 |
| --- | --- |
| `SingleAgentController.ets` | 收窄为 UI/Hermes 门面，移除音频内部判断 |
| `VoiceInputCoordinator.ets` | 唯一 CaptureSupervisor、输入意图和收句 |
| `VoiceOutputCoordinator.ets` | 只协调公共 PlaybackQueue 和用户暂停 |
| `CaptureSupervisor.ets` | 首 PCM ready、时间窗恢复预算、类型化事件 |
| `PcmCapture.ets` | 单次物理 start/stop 和平台事件，无恢复策略 |
| `BackgroundAudioTaskOwner.ets` | demand 向量、策略接口、平台实际状态 |
| `CommunicationAudioSession.ets` | 恢复耗尽向 Runtime 报告终态 |
| `PcmPlayer.ets` | 有界恢复、失败回调、jobId 校验 |
| `StreamingTtsClient.ets` | 单 job connection 和可确认取消 |
| `pages/Index.ets` | 调用异步命令，组件销毁时统一 dispose |

### 9.3 最终删除

- `AudioContinuityCoordinator.ets`
- `SystemSpeechService.ets`
- `SystemSpeechQueue.ets`，其分段逻辑迁入 `SpeechPlaybackQueue`
- `AudioContinuityState.ets`，其平台状态迁入 `BackgroundAudioTaskOwner` 的纯 reducer

删除只在所有调用和测试迁移完成后执行，不在早期切片制造大范围编译中断。

## 10. 分阶段实施

每个切片必须独立构建、可回滚，并在完成门通过后才进入下一切片。

### S0：建立会失败的行为测试和关联日志

改动：

- 新建 `VoiceRuntimeState` 的最小纯 reducer 和受控 Promise 测试夹具。
- 为 Session、epoch、capture generation、playback job、continuity transition 增加统一关联字段。
- 增加当前代码必然失败的测试，不修改生产行为来伪造通过。
- 从 `verify.mjs` 移除“存在 stop/start”“提示音必须 `PcmPlayer(false)`”等实现形状检查；保留权限、路由、禁止旧 Host 协议和 manifest 校验。

完成门：

- 历史切换期间旧 capture stop 完成不会关闭新输入。
- cue 在麦克风开启时也必须经过 playback ready。
- 旧 epoch 的 TTS/ASR/continuity 回调不能改变当前状态。
- AudioSession/Renderer 恢复耗尽进入 failed，不无限重试。

### S1：引入 Runtime epoch 和原子 Session 切换

改动：

- 新建 `VoiceRuntime` mailbox。
- 引入 reducer/effect runner/transaction completion，禁止 mailbox 等待平台 Promise。
- 将 `resumeSession/newConversation/switchProfile/restartVoiceClients/disconnect` 纳入 Runtime 命令。
- `resumeSession` 保留健康输入，仅重绑 ASR epoch、冻结普通提交并取消旧输出。
- `VoiceInputCoordinator.stop()`、`VoiceOutputCoordinator.cancelAll()` 全部改为可等待 Promise。
- 增加 Session 切换失败回滚和状态不确定对账。

完成门：

- 连续执行“开麦 -> 历史 Session -> 新会话 -> 历史 Session”不会出现 `voiceEnabled=true` 但 Capturer 停止。
- 同一 Profile 切 Session 不重建 Capturer。
- 切换前开始、切换后迟到的 ASR final 保持旧 epoch，不能提交到新 Session。
- 旧 Session 事件、旧 TTS、旧 ready 回调全部被 epoch 丢弃。

### S2：统一输入管线

改动：

- 拆出 `SystemAsrEngine` 和 `RemoteAsrEngine`。
- `VoiceInputCoordinator` 成为唯一 `CaptureSupervisor` owner。
- 系统/远端后端只消费同一 PCM 事件。
- 调整 CaptureSupervisor ready 和恢复预算。
- 删除 `SystemSpeechService` 中的 capture、recognitionWanted 和 captureStarting/stopping 状态。

完成门：

- 全仓库只有一个业务 owner 构造 `CaptureSupervisor`。
- 后端切换不重建健康 Capturer。
- 任意时刻系统报告最多一个 AudioCapturer。
- 息屏、短暂中断、AudioSession 恢复后首 PCM 证据重新出现；恢复耗尽明确失败。

### S3：统一可听输出

改动：

- 新建 `SpeechPlaybackQueue`、`SystemTtsPlayer`、`RemoteTtsPlayer`。
- 正文、重读、协议播报和 cue 全部迁为 job。
- CueRenderer 使用通信路由并等待 playback ready。
- 远端取消采用关闭 socket/new connection generation。
- 系统 TTS request、segment、job 全部校验 epoch/jobId。

完成门：

- 全仓库只有 PlaybackQueue 可以启动可听输出。
- accepted cue 不切断正文；thinking cue 可跳过；停止/错误只响一次。
- Session 切换后旧 PCM、旧系统 TTS 完成和旧 cue drain 均不能推进新队列。
- 新消息和历史重读共用相同分段、暂停和完成逻辑。

### S4：后台保护 demand 化和真机策略门

改动：

- `recording/playback` 单枚举改为 demand 向量。
- 当前切换逻辑封装进 `DedicatedModePolicy`，不再散落在 Controller、输入和输出中。
- 只有 Input/PlaybackQueue 状态事件改变 demand。
- 增加策略实验配置，仅用于目标真机对照，不暴露为普通用户设置。

完成门：

- cue、正文和重读对 continuity 的需求一致。
- UI notify、屏幕事件和状态文案变化不触发后台模式切换。
- 根据第 12 节数据选择正式策略；未通过前不得宣称息屏连续性完成。

### S5：统一健康、错误和释放

改动：

- AudioSession、Capturer、Renderer、ASR、TTS、continuity 统一发 `ResourceHealth` 事件。
- 移除各组件对 `snapshot.error` 的直接写入和清空。
- 实现 Runtime 错误去重、错误 cue 和终态。
- 实现幂等 `dispose()`，接入组件销毁和“退出软件”。
- 取消所有 reconnect/recovery/finalization/clock timer。

完成门：

- 局部资源失败只影响对应域，不关闭健康的输入、输出或 Hermes 任务。
- 退出后无 Capturer、Renderer、AudioSession、后台任务、WebSocket 或计时器。
- 失败恢复不会无限循环，也不会把瞬态日志全部升级为用户错误提示。

### S6：删除兼容层并完成全矩阵

改动：

- 删除旧 Coordinator、Service、Queue 和重复 flags。
- 收紧 `SingleAgentController` 与 UI 快照派生。
- 执行全部自动化、ArkTS 构建和真机矩阵。
- 只有真机通过后更新架构决策和 changelog。

完成门见第 13 节。

## 11. 自动化测试设计

### 11.1 测试夹具

提供可手动 resolve/reject 的 fake：

- `FakeCapturePort`
- `FakeAsrEngine`
- `FakePlaybackBackend`
- `FakeContinuityPort`
- `FakeHermesSessionPort`

测试必须能控制“旧 stop 尚未完成、新 start 已请求、旧 callback 迟到”等顺序，并证明 effect 等待期间 mailbox 仍可接受 `stop/dispose`。Node 测试沿用现有“加载生产 ArkTS 纯逻辑”的方式，只加载 reducer 和不依赖 HarmonyOS API 的 effect 调度核心；平台适配器由 fake 代替。

### 11.2 必测序列

1. 远端 ASR 正在 stop 时切历史 Session，输入最终仍 healthy。
2. 本地 ASR 正在启动时连续切两个 Session，只有最新 Session 生效。
3. Session resume 失败后恢复上一身份；对账失败时阻止提交但保留采集。
4. cue 在 `recordingDemand=true` 时仍建立 `playbackDemand=true` 并等待 ready。
5. 正文播放时 accepted/thinking cue 不创建并发播放器。
6. 关闭旧远端 TTS socket 后到达的 PCM 被 connection generation 丢弃。
7. 旧系统 TTS `onComplete` 不推进新 job。
8. AudioSession 恢复三次失败后进入 failed 并停止重试。
9. Capturer 一块短暂 PCM 后再次失活不会无限重置恢复预算。
10. `dispose()` 在 start、recover、reconnect 和 playback drain 未完成时仍能最终释放。
11. screen/background 事件不改变 epoch，不调用 stop/start。
12. 同一输入跨 ASR Session 轮换最多提交一次。
13. 一个永不 resolve 的旧 start effect 不阻止新 epoch 的 dispose 进入 reducer 并完成其余释放。
14. Session 切换前开始的话语在切换后返回 final 时仍携带旧 epoch；切换后的新话语可正常提交。

### 11.3 验证命令

```powershell
node --test tests/audio_continuity.test.js tests/capture_recovery.test.js tests/voice_runtime.test.js tests/playback_queue.test.js tests/voice_filters.test.js tests/media_speech_filter.test.js tests/mobile_ui.test.js
python -m pytest -q -o 'addopts='
node clients/harmony/scripts/verify.mjs
```

HarmonyOS 工程内：

```powershell
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

## 12. HarmonyOS 后台策略真机能力门

后台策略不能仅凭 API 声明选型。S4 必须在目标设备上对以下策略做同一组日志和听感对照：

| 候选 | 行为 | 通过条件 |
| --- | --- | --- |
| A：会话级固定 `AUDIO_PLAYBACK` | 完整语音运行期不切模式 | 息屏系统 TTS 连续，Capturer/PCM/ASR 也连续 |
| B：会话级固定 `AUDIO_RECORDING` | 完整语音运行期不切模式 | 息屏采集连续，CoreSpeech 系统播放也连续 |
| C：专用模式事务切换 | 播放 job 边界切 playback，排空后切 recording | 切换空窗可观测，录音和播放都无中断且可恢复 |

每个候选执行：

1. 开麦后亮屏 2 分钟、息屏 5 分钟，记录最大 PCM gap、ASR Session 和恢复次数。
2. 开麦状态播放至少 3 分钟长文，中途息屏 60 秒，记录每段 request、onStart/onComplete 和用户听感。
3. 播放期间说话，验证输入真实可用、播报暂停和提交后恢复。
4. 等待 Agent 时验证 accepted/thinking/error/stop cue。
5. 锁屏/解锁、前后台往返和耳机插拔各执行一次。
6. 播放完成后继续说话 2 分钟，确认录音没有停在伪健康状态。

正式选择规则：

- A 或 B 任一满足全部指标，采用固定策略，删除不必要的模式切换。
- 只有 C 满足时，保留 C，但每次切换必须是 Runtime 可等待事务，禁止 fire-and-forget。
- 三者都不满足时，认定目标平台无法同时保证“CoreSpeech 系统 TTS + 持续后台录音”。不得继续用重试掩盖能力边界；需要在“后台半双工”或“后台改用远端 PCM 播放”之间形成新的产品决策。

通过指标：

- 持续收音期间无超过 2 秒的未解释 PCM gap；无无限恢复。
- 长文无断音、爆破音、明显卡顿、漏段或跳段。
- cue 不与正文并发，不因麦克风开启而静默丢失。
- 无 `6800301`；后台任务切换和 ready 顺序可从同一 epoch/job 日志还原。

## 13. 总完成标准

### 13.1 结构

- 一个 Runtime epoch；一个 CaptureSupervisor；一个 PcmCapture；一个 PlaybackQueue。
- 本地/远端 ASR 不拥有 Capturer。
- cue 不拥有独立业务队列，不绕过 continuity 和通信路由。
- 音频组件不直接写 UI 快照或全局错误字符串。
- 生命周期 stop/dispose 全部可等待且幂等。

### 13.2 行为

- 历史 Session、新会话、Profile 和语音后端切换后麦克风意图与实际健康一致。
- 息屏、锁屏和后台不改变业务路径；音频继续或进入明确失败，不伪装正常。
- 所有迟到回调被 epoch/jobId 隔离。
- 提示音、正文、重读和协议播报严格串行。
- 恢复有上限，耗尽后停止重试并保留已确认数据。
- 退出后资源归零且不自动重连。

### 13.3 验证

- Node 行为测试、Python 协议测试、ETS 静态边界、ArkTS 类型检查和 HAP 构建通过。
- 第 12 节目标真机矩阵通过。
- 用户确认历史会话开麦、息屏长文、播放后继续说话和四类提示音通过。

## 14. 实施纪律

- S0-S6 顺序执行，不在中途并行开发新的语音功能。
- 每个切片单独提交，提交信息标明 `voice-runtime Sx`。
- 旧行为兼容层只能保留到下一切片，不长期双写新旧状态。
- 新状态先成为唯一事实来源，再删除旧 flag；禁止永久镜像两套状态机。
- 真机失败先保存 epoch/job/health 证据，再调整策略；禁止按屏幕事件增加特殊分支。
- 任一切片导致无法解释的录音、播报或 Session 回归时，回滚该切片，不在失败切片上继续叠修复。

## 15. 待决策项

以下内容必须用实现或真机证据决定，本文不提前假定：

1. A/B/C 哪个后台策略能在目标设备上同时满足输入和系统 TTS。
2. Hermes `session.interrupt` 是否原子等价于 `/stop` 并清除全部排队任务。
3. HarmonyOS API 24 主动终止 UIAbility 的稳定入口和失败回退。
4. 远端 TTS Provider 是否可以正式回显 `job_id`；不能时继续采用单 job connection generation 强边界。
