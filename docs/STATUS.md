# 项目当前状态

## 当前快照（2026-08-12）

- 总体状态：`1.2.1 (1020001)` 息屏录播可靠性重新打开为 P0；用户再次复现播放中断、卡顿、吞字和录音中断，旧的“核心语音已通过”结论不再作为当前发布依据。
- 当前阶段：先修后台持续任务和真实采集健康，再复验系统 TTS；连续 ASR 1.8 秒停顿判定验收顺延。
- 当前任务：[息屏录播可靠性回退与恢复](plans/2026-08-12-screen-off-audio-regression-recovery.md)。
- 已确认事实：设备安装包是 `1.2.1 (1020001)`，更新时间为 2026-08-12 18:43，位于语音拆解提交 `cc0f64e` 之后；因此不是本地旧 HAP 或旧安装版本导致的复现。工作区现成签名 HAP 仍为旧版属于正常构建产物状态，Git 拉取不会更新被忽略的 HAP。
- 代码证据：后台 owner 在录音/播放意图变化时异步 stop/start，系统 TTS 首段没有等待播放后台任务 ready；`PcmCapture` 没有 `stateChange`、`audioInterrupt`、无 PCM 看门或 AudioSession 恢复处理；`SystemSpeechService` 主要依赖 `captureRunning` 布尔值。
- SDK 证据：目标 API 24 支持一个 UIAbility 同时申请 `audioPlayback` 与 `audioRecording` 多后台模式；AudioCapturer 支持状态/中断回调；CoreSpeech TTS 支持 `SpeakListener.onData` 返回带序号的合成音频，可作为条件升级路径。
- 诊断边界：只读查询时应用进程在后台，但系统无 AudioSession 和 AudioCapturer；由于没有同时取得 UI 收音意图，该结果只作为状态漂移线索，不能单独证明客户端仍误报“监听中”。
- 当前方案：优先使用单一录播组合持续任务并让首段等待 ready；补采集健康检测和有限重建；若真机仍出现 `onComplete` 但漏播，再验证并启用 PCM 自管播放。
- 业务基线：已按用户视角形成[HarmonyOS 音频用户旅程与业务逻辑](HARMONYOS_AUDIO_USER_JOURNEY.md)，将业务收敛为“发起/补充 -> 等待 Agent -> 聆听播报 -> 停止/补充”的单一循环；话筒、播报、亮屏/息屏和应用前后台是正交状态，不再枚举组合场景。
- 最新控制语义：`停止任务`等价于 Hermes `/stop`，取消当前和全部排队任务并清空本地输出；`关闭话筒`保持 Capturer 和ASR，只禁止普通识别结果进入 Agent，并继续识别“停止任务/打开话筒/退出软件”；`打开话筒`恢复普通消息路由；`退出软件`释放全部本地资源和网络连接，默认不停止远端任务。每次冷启动首次完整链路仍需手动开启。
- 提醒音现状：代码已存在 accepted/running/stop/error 四类入口，以及正文等待短提示排空和思考呼吸音让路逻辑；目标设计要求它们与新消息、历史重读、协议播报进一步收敛为唯一可听输出仲裁，防止并发播放器和破音。
- 实现差距：当前代码仍以“停止/stop”触发 `session.interrupt`，未证明清空全部排队任务；“关闭话筒”当前会停止 Capturer/ASR；“打开话筒”和“退出软件”语音指令不存在。以上业务设计尚未实现，本轮只整理并同步文档。
- 技术参考：[录音播放统一策略](HARMONYOS_AUDIO_STRATEGY.md)继续约束组合后台租约、真实健康证据和恢复边界；[组件拆解蓝图](HARMONYOS_AUDIO_COMPONENT_DESIGN.md)降为实现期参考，其中 `S00-S21` 是测试/故障序列，不是用户场景。
- 验证缺口：现有 `node scripts/verify.mjs` 仍通过，但主要验证源码结构存在性，不执行后台切换、采集失活或 TTS 陈旧回调等行为序列。
- 下一恢复点：先实现本地系统指令门、`/stop`等价队列清理、统一退出释放和唯一可听输出仲裁；再实现组合后台任务、AudioCapturer健康恢复和统一收句缓冲。构建新HAP后按同一用户循环覆盖亮屏、息屏、两种输入路由和退出后的资源核验。

## 2026-08-12 - `1.1.2` 真机验收反馈

- 结果：用户确认真机验收总体成功；亮屏状态下长文播报正常。
- 问题：息屏长文播报仍出现断连、缺字漏字和破音；这表明问题与息屏生命周期、后台音频所有权、系统 TTS 分段或播放链路有关，尚未定位到具体模块。
- 重读：语音说“重读一次”后曾偶发再次发声，但只读检查确认当前客户端没有本地重读控制词，更可能走普通 Agent Prompt；消息气泡按钮没有效果，仍需单独定位点击条件和统一输出入口。
- 决定：按用户要求先不开发业务修复，优先进行核心文件功能拆解，拆解完成后再做定向定位。

## 2026-08-11 - 1.1.1 基本可用确认与后续问题

- 进展：Adapter 已增加 25 秒下行应用层心跳并部署到 `foxi`；HarmonyOS 在收到首个心跳后使用 70 秒看门狗关闭悬挂连接。自动重连使用独立的无损 Session 恢复，不再调用会关闭语音输出的手动历史恢复路径；系统 TTS 重读也不再等待无关的远端 PCM 清理。`1.1.1` HAP 已保留数据覆盖安装到设备 `6HQ0226409028766`，未启动应用。
- 验证：Python 27 项、Node 19 项、Harmony 18 个 ETS 文件静态校验、ArkTS 类型检查、签名 HAP 构建和 `git diff --check` 通过。远端运行源码 SHA-256 与本地一致，systemd 为 `active/running`，本机与公开根入口返回 `200`，未鉴权 `/api/agents` 返回预期 `401`；设备包信息为 `1.1.1 (1010001)`。
- 产物：`clients/harmony/entry/build/default/outputs/default/entry-default-signed.hap`，版本 `1.1.1 (1010001)`，SHA-256 `CA8142F0BA161D1C9DEE9C958E25D90ADE9203F1D3CF1D99CD0505F3D468EE68`。
- 用户结论：`1.1.1` 当前基本可用。
- 活跃问题：左上 Agent 选择框过长且供应商/模型不显式；设置页供应商默认 `custom` 并依赖打开页面才刷新；重读按钮撑大气泡且重读仍无声；思考呼吸音偶发缺失；设置项缺少双列紧凑布局和清晰分区。
- 下一恢复点：从[后续问题原文](plans/2026-08-11-v111-acceptance-and-follow-up-issues.md)恢复，先复现并记录供应商刷新、重读 TTS 和呼吸音的完整事件路径，再设计紧凑布局；本轮不改代码。

## 当前快照（2026-08-11）

- 总体状态：`1.1.1` 已确认基本可用，进入问题记录和下一阶段规划。
- 当前阶段：HarmonyOS 界面密度、运行身份同步与声音可靠性。
- 当前任务：已记录四组后续问题；按用户要求本轮不再修改功能或 UI 代码。
- 已完成到：网关下行心跳、客户端心跳看门狗、无损 Session 恢复、播放状态隔离、系统/远端后端专属重读清理、Adapter 部署，以及 `1.1.1 (1010001)` 安装。
- 活跃问题：Agent/供应商/模型展示与主动刷新、重读布局和无声、思考呼吸音偶发缺失、设置双列布局及分区。
- 最近验证：Python 27 项、Node 19 项、Harmony 18 个 ETS 文件静态校验、ArkTS 类型检查、签名构建和 `git diff --check` 通过；最新 HAP SHA-256 为 `CA8142F0BA161D1C9DEE9C958E25D90ADE9203F1D3CF1D99CD0505F3D468EE68`。
- 下一恢复点：读取 `docs/plans/2026-08-11-v111-acceptance-and-follow-up-issues.md`，按 `docs/plan.md` 的四项顺序进行只读路径分析和后续实现。

## 2026-08-11

- Progress: 已通过 SSH 将当前 `app/native_main.py` 部署到 `foxi`，远端生产文件与本地 SHA-256 一致；服务 `daiworld-voice-single-agent.service` 为 `active`，未鉴权访问 `/api/agents` 和模型选项接口均返回 `401`。
- Impact: 服务器已运行包含当前 Agent Catalog、Provider/模型契约和 ASR 语义边界的 Adapter，不需要客户端降级到旧接口。
- Blockers: 签名 HAP 已通过 HDC 保留数据安装到设备 `6HQ0226409028766`，包名为 `cc.daiworld.voice.singleagent`、版本为 `1.1.0 (1010000)`；本轮未启动应用，语音、听感和视觉结论仍待用户操作。
- Next: 用户启动应用后完成部署后真机验收；发现问题时记录复现步骤和设备日志，再做定向修复。

## 2026-08-11

- Progress: 按真机反馈将收音控制词收敛为四条精确白名单：“关闭话筒”“关闭麦克风”“关闭microphone”“暂停收音”。归一化会去除大小写差异、空格、标点和符号，但不接受“闭麦”或其他英文误识别；Node 19 项、Harmony 静态检查和 Python 26 项通过，更新后的 `1.1.0` HAP 已覆盖安装。
- Impact: “暂停收音”成为主要中文口令；控制边界不会把 `be my`、`in my` 等识别错误升级为关闭麦克风动作，停止任务语义保持独立。
- Blockers: 服务器无需重复部署，当前 Adapter 已是同一版本；重播按钮无声问题尚未修复，仍需下一轮串行化 TTS 停止/启动后再真机复测。
- Next: 用户启动最新 HAP，先验证四条收音口令和反例，再复测重播；记录实际 TTS 状态、首个 PCM / `onStart` 和错误信息。

## 2026-08-11

- Progress: 完成 `1.1.0 安全与连接韧性` 非真机里程碑。HarmonyOS 使用 HUKS 管理 AES-256-GCM 密钥，Preferences 仅保存版本化密文；启动和设置保存改为等待安全存储完成。Gateway 区分终止鉴权失败与瞬态错误，使用有上限退避、10 秒 ready 看门和 socket / 请求代际隔离，重连只恢复已有 Session。
- Impact: 已保存访问口令不再以明文字段长期保存；无效口令不会无限重试，短暂网络或服务端故障可自动恢复，且重连不会重复提交用户消息。发布清单已提升为 `1.1.0 (1010000)`。
- Blockers: 本地自动化、ArkTS 类型检查、打包、签名和包内版本核验全部通过。按当前里程碑边界未部署 Adapter、未安装或启动 HAP、未操作真机，因此 HUKS 迁移和真实网络恢复仍待统一真机验收。
- Next: 在下一个大节点统一部署 Adapter 与 `1.1.0` HAP，再执行安全迁移、鉴权、网络恢复、Session 连续性和语音稳定性验收。

## 2026-08-11

- Progress: 统一 ASR 纯符号输入边界。Adapter 以 Unicode General Category `L/N` 判断 final 文本；纯符号结果改为空 final 后继续下发，HarmonyOS 保留同规则兜底，Web 只保留回归测试。
- Impact: 过滤不再仅依赖某个客户端；纯标点、emoji 和下划线不会形成 Hermes Prompt，同时 final 帧仍能结束临时气泡和说话暂停状态。
- Blockers: Python 26 项、Node 19 项、Harmony 静态校验和格式检查通过。Adapter 尚未部署；本轮无 ArkTS 运行时代码变化，未重建或安装 HAP。
- Next: 部署 Adapter 后做受控协议验证，或继续下一项无需真机的功能开发。

## 2026-08-11

- Progress: 完成 HarmonyOS 远端 ASR / TTS 意外断线恢复。客户端隔离旧 socket 回调，ASR 保留最近约 0.8 秒 PCM 并等待 Provider `ready`，TTS 严格按顺序恢复待发文本 / `done` 帧；控制器增加封顶退避、连接看门和显式取消路径。版本提升为 `1.0.3 (1000003)`。
- Impact: 短暂网络抖动不再把远端语音永久留在 stopped / connecting；ASR 重连不立即切断已有转写，TTS 断线后可先播放已收到的 PCM，并在连接恢复后继续后续任务。
- Blockers: Python 25 项、Node 19 项、Harmony 静态校验、ArkTS 类型检查、签名构建和包内版本核验通过。按用户要求未安装或启动 HAP，真机网络与听感验收仍待后续进行。
- Next: 继续无需真机的功能开发；恢复设备验收后测试短暂断网、10 秒悬挂看门、耳机长播报续接和连续收音。

## 2026-08-11

- Progress: 修复真机播放与收音中断：耳机可用时不再强制听筒路由；PCM renderer 增加看门、自恢复和音频会话恢复联动；空文本 / 纯标点 ASR 误触发后会恢复 TTS；本地与远端 ASR 使用 1.1 秒窗口合并连续 final，并在连接终止前保留有效文本。版本提升为 `1.0.2 (1000002)`。
- Impact: 播放不再依赖下一条消息唤醒搁置队列，ASR 服务的自然分段不会直接拆成多条 Hermes Prompt，短气口期间保持同一个用户气泡。
- Blockers: Python 25 项、Node 19 项、Harmony 静态验证和 ArkTS 构建已通过；签名 HAP SHA-256 为 `b29a234d2dd8c0f48fb5947f5d26274884e4f555b3aeb3b4f805e57b0ede8d0f`。真机安装、说话、耳机听感和视觉验收仍由用户操作。
- Next: 安装签名 HAP 后连续测试耳机长回复、短暂焦点变化、0.5-1 秒思考停顿、多 final 合并，以及“停止 / 闭麦 / 同意 / 取消”的即时响应。

## 2026-08-11

- Progress: 修正了上一版 Provider 归一化遗漏的 Hermes 字段：Adapter 现在识别顶层 `provider` 和 Provider 条目的 `is_current`，服务器三个 profile 实测均返回 `active_provider_label=open1`，选项保留真实别名 `open1` 与 `wawapi`。HarmonyOS 设置页改为读取 HAP 清单版本，并已将版本提升为 `1.0.1 (1000001)`。
- Impact: 当前 Session、顶部身份和设置页默认选项会以 Hermes 实际 Provider 对齐，不再因为同名模型出现在通用 `openai-api` 前面而误选；设置页可以直接确认安装包是否更新。
- Blockers: Adapter 已通过 `ssh foxi` 部署并重启，服务 `active/running`；Python 25 项、Node 19 项、Harmony 静态验证、ArkTS 类型检查和签名 HAP 构建通过。新版 HAP 尚未覆盖安装到真机，后续安装、点击、语音、听感和视觉验收仍由用户操作。
- Next: 使用 `clients/harmony/entry/build/default/outputs/default/entry-default-signed.hap` 安装新版后，确认设置页显示 `1.0.1 (1000001)`、Provider 默认 `open1`，并手动切换 `wawapi` 验证 Session 身份不漂移。

## 2026-08-11

- Progress: HarmonyOS now renders `approval.request` and `clarify.request` as Agent conversation messages instead of standalone cards. Pending text/ASR replies go directly to `approval.respond` or `clarify.respond`, exact approval phrases fail safely, and in-flight locks prevent duplicate responses. Adapter model options now replace generic `OPENAIAPI` names with concrete provider IDs and return `active_provider_label`; HarmonyOS reconciles generic `custom` runtime identity and preserves the selected concrete Provider after switch confirmation.
- Impact: Protocol prompts stay in the main voice conversation without creating a second Agent task. Provider identity now has a controlled path from Adapter options to the settings selector and Session header.
- Blockers: Python (24), Node (19), Harmony static verification, ArkTS type checking and signed HAP assembly pass. The first deployment check reported a transient connection refusal, but `daiworld-voice-single-agent.service` is `active/running`, `8845` is listening, `/api/agents` returns `401`, and the running `native_main.py` hash matches the staged hash `8072dc990cfd78641d939934addacd884f87e39bc36f114a104a7d915ff73e8a`. The signed HAP was then cover-installed successfully on device `6HQ0226409028766` as bundle `cc.daiworld.voice.singleagent`. True-device tapping, speech, audio and visual acceptance remains user-operated.
- Next: Open the installed app and verify conversational approval/clarification plus concrete Provider names in the settings page; report the observed UI and voice result before any further code change.

## 2026-08-11

- Progress: The `foxi` Adapter has been updated with the formal `/api/agents` route. Interactive sudo verification confirmed `root`, `daiworld-voice-single-agent.service` is `active`, and the unauthenticated local route returns the expected `401` instead of `404`. The installed HarmonyOS app then started successfully and displayed dynamic Agent “赫小码” with “在线” status and restored Session content; no HTTP 404 remained.
- Impact: The new HarmonyOS HAP and deployed Adapter now share the same Agent Catalog contract; no client fallback was added. The reported true-device Agent-directory failure is fixed.
- Blockers: No server-side blocker remains. Agent switching, new Session creation, deletion/empty-catalog fallback and TTS-cleaning interaction acceptance remain pending.
- Next: Complete those remaining true-device interactions, then continue the HarmonyOS-first items in `docs/plan.md`.

## 2026-08-11

- Progress: Completed HarmonyOS natural-line thinking rendering and implemented current-Session Provider/model switching. The settings page now loads controlled options from the Adapter, preserves the live conversation and speech connections, blocks switches during an active Agent turn, and waits up to 10 seconds for matching `session.info` confirmation.
- Impact: Provider credentials and Profile defaults remain server-side. Failed, timed-out, or stale requests cannot optimistically overwrite the last confirmed runtime identity; Web remains unchanged as a protocol preview.
- Blockers: Static verification, Python (22), Node (19), ArkTS type checking, signed HAP assembly, and cover installation on device `6HQ0226409028766` pass. Launch is blocked by the phone lock screen (`10106102`), so true-device visual and runtime confirmation remains pending.
- Next: Unlock the phone and launch the installed build; verify option loading, successful switch confirmation, failure preservation, Session resume identity, and line-by-line thinking display.

## 2026-08-11

- Progress: Confirmed the product scope: Web Native remains a technical preview and protocol-validation surface; HarmonyOS is the final mobile delivery target.
- Impact: Dynamic Agent and voice work will be accepted primarily on HarmonyOS. Web parity is limited to the current preview and regression coverage.
- Blockers: None.
- Next: Finish the dynamic Agent catalog contract and HarmonyOS client migration, then stabilize the Web preview and pause new Web feature work.

## 2026-08-11

- Progress: Implemented the dynamic Agent Catalog across the Adapter, Web preview, and HarmonyOS; added opaque-ID fallback, loading/empty states, avatar identity, session voice instructions, `speech_text`, and Markdown/code/media TTS filtering. Added the approval voice-response plan.
- Impact: Agent additions, removals, and renames no longer require a client release. Full screen content is preserved while spoken output can use a shorter safe text. HarmonyOS remains the primary delivery surface after this Web preview stabilizes.
- Blockers: Python (22), Node (19), Harmony static verification, ArkTS type checking, signed HAP assembly, and cover installation pass. App launch is pending because the connected phone is locked.
- Next: Unlock the phone, launch the installed build, and verify Agent loading/switch/fallback plus automatic TTS with Markdown, code, and `speech_text` examples.

## 2026-08-10

- Progress: Defined separate microphone-input and Agent/TTS-output controls for the Harmony client; implementation is in progress.
- Impact: The microphone button will stop only PCM capture and ASR. The `停止` button remains the explicit Agent/TTS interrupt.
- Blockers: None.
- Next: Implement the state split, build the signed HAP, and verify the two controls on the connected phone.

## 2026-08-10

- Progress: Compared Harmony message bubbles with `web_native`; identified unstable revision keys, a detached ASR preview, missing stream-follow scrolling, nested process UI, and inconsistent metadata/artifact layout.
- Impact: These issues can cause flicker, jumpy scrolling, and make partial speech/reply state look like separate messages.
- Blockers: None.
- Next: Apply the focused bubble fixes, run static verification and a signed build, then check the result on the device when HDC reconnects.

## 2026-08-10

- Progress: Stabilized Harmony message keys, added near-bottom stream following, upgraded ASR partial/final text in one persistent user bubble, separated process activity from the assistant answer, grouped artifacts with the answer, and displayed Provider metadata.
- Impact: Streaming replies no longer intentionally recreate each bubble; users who scroll upward are not pulled back down, while live speech and final submissions retain one message identity.
- Blockers: HDC device visibility is still pending for true-device UI verification.
- Next: Reconnect the phone with developer mode enabled and verify streaming reply rendering, ASR preview/final upgrade, scroll behavior, process collapse, and artifact layout.

## 2026-08-10

- Progress: Fixed the ASR capture-failure path so it leaves `connecting`, closes the incomplete ASR socket, and exposes the recording-route error; moved model/Provider beside the assistant nickname and reordered completed-message metadata to show date/time before durations.
- Impact: The UI no longer reports a permanent ASR connection attempt after microphone capture fails, and message metadata uses less vertical space.
- Blockers: None in build; true-device interaction is reserved for manual user testing.
- Next: Install the new signed HAP and manually verify microphone routing, ASR state transitions, and message metadata ordering.

## 2026-08-10

- Progress: Replaced the plain stable-key `ForEach` message path with `Repeat` plus fresh UI snapshots, and exposed the active AudioCapturer route as phone/headset microphone text on the microphone button.
- Impact: ASR partial/final text, assistant deltas, and process completion repaint without recreating message identity; the active input route is visible in the main control.
- Blockers: None in static verification or signed build.
- Next: Manually verify complete user text, assistant final text, stopped process animation, and the displayed microphone route on the connected phone.

## 2026-08-10

- Progress: Decoupled microphone-route display from the CoreSpeech ready callback and added a five-second system-ASR startup timeout with ordered release-before-remote fallback.
- Impact: The active phone/headset route is visible as soon as capture starts, and local ASR cannot remain indefinitely in `connecting`.
- Blockers: None in static verification or signed build.
- Next: Manually confirm the route label appears and ASR reaches listening locally or after remote fallback.

## 2026-08-10

- Progress: Reopened the CoreSpeech startup issue after true-device testing showed `startRecognition()` can remain pending before the previous timeout is registered; rejected automatic local-to-remote fallback as a backend policy.
- Impact: The next build will keep explicit `harmony_offline` selection, report the exact startup phase, and stop failed microphone input without interrupting Agent/TTS work or connecting remote speech services.
- Blockers: The buffered device log no longer contains the original CoreSpeech failure, so the exact blocked API call requires one instrumented manual retry.
- Next: Add phase callbacks and a full-operation timeout, remove every implicit remote fallback, then build and install for user-operated verification.

## 2026-08-10

- Progress: Removed every automatic local-to-remote speech transition, time-bounded optional headset-routing calls, made in-flight capture startup cancellable, and reset a failed CoreSpeech recognizer before the next manual retry. Added visible startup phases and full-operation timeout protection.
- Impact: Selecting `harmony_offline` now remains local. Normal startup is no longer blocked indefinitely by optional audio-route configuration, and a failed attempt cannot poison the next microphone-open action with a stale recognizer.
- Blockers: None in static verification, ArkTS type checking, signing, assembly, or cover installation; CoreSpeech `onStart` and the actual microphone route still require user-operated true-device confirmation.
- Next: Manually open the installed app and verify local ASR reaches listening and shows the active phone/headset microphone route.

## 2026-08-10

- Progress: True-device testing found three remaining Harmony failures: a connected headset is rejected before its asynchronous input route settles, one CoreSpeech session eventually exceeds its supported audio length (`1002200003`), and a completed/failed Agent turn can leave the process bubble running.
- Impact: Headset microphone input cannot start reliably, long-running microphone input eventually breaks local ASR, and terminal Agent state is not always reflected by the UI.
- Blockers: None for implementation; final route and lifecycle acceptance requires user-operated true-device testing.
- Next: Wait for the selected headset route before accepting capture, rotate CoreSpeech sessions below the platform length limit without stopping PCM capture, and close pending Agent process state on every verified terminal path.

## 2026-08-10

- Progress: Implemented the three true-device stability fixes in the Harmony client. Audio capture now always uses the media-selectable voice-recognition source and waits up to five seconds for the requested headset route; CoreSpeech rotates at an 18-second PCM budget while preserving capture and pre-roll; gateway errors, closes, direct submit failures, and `message.complete` now finalize or diagnose the pending Agent process.
- Impact: A connected headset is no longer rejected by an immediate stale route read, continuous local ASR stays below error `1002200003`, and verified terminal Agent paths cannot leave the process timer running.
- Blockers: Implementation, static verification, ArkTS type checking, signing, assembly, and cover installation all pass. User-operated true-device acceptance remains.
- Next: Test an already-connected headset, leave local ASR enabled beyond 20 seconds, and complete or fail an Agent turn. If a completion is still missing, use the new gateway event/drop logs to identify whether the terminal event was received or rejected.

## 2026-08-10

- Progress: Reopened headset routing and message rendering after true-device regression testing. Explicit `selectMediaInputDevice()` still left the active descriptor on the phone and blocked capture; using `SOURCE_TYPE_VOICE_RECOGNITION` for speaker capture also removed the original communication-mode echo handling; stable-key `Repeat` rendered only the first ASR character on device.
- Impact: Headset capture cannot start, speaker TTS is fed back into ASR, and the user bubble does not display the transcript already present in controller state.
- Blockers: None for implementation; the affected behaviors have working reference paths in the original Harmony client.
- Next: Restore source selection by private output route, use communication capture for speaker/AEC, remove blocking explicit media-input selection, and restore revision-keyed message rendering.

## 2026-08-10

- Progress: Restored the original route-dependent capture behavior and device-reliable message repainting. Speaker output again uses communication capture, private headset output uses recognition capture with wireless recording preference, explicit media-input selection no longer blocks startup, and each message revision receives a new ArkUI `ForEach` key.
- Impact: System speaker echo handling is restored, HarmonyOS owns Bluetooth/SCO input establishment as in the original client, and ASR/assistant streaming text repaints beyond the first character.
- Blockers: Static verification, ArkTS type checking, signed assembly, and cover installation pass. The three reported regressions require user-operated true-device confirmation.
- Next: Verify headset startup, speaker echo rejection, and multi-character user/assistant streaming updates on the installed build.

## 2026-08-10

- Progress: Replaced output-inferred microphone routing with a shared HarmonyOS voice-communication AudioSession. PCM capture and TTS playback now declare communication semantics, no-accessory communication output defaults to the phone speaker, input-device changes update display/diagnostics without rebuilding capture, and short cues opt out of the communication session.
- Impact: On the connected FreeBuds 5, the system changed from `A2DP + phone MIC` to `PHONE_CHAT + BLUETOOTH_SCO` for both priority routes; the active 16 kHz capturer reported device type `7`, and the UI showed `耳机麦克风`. Closing the microphone released the session without recurring A2DP/SCO switches from status cues.
- Blockers: None for the reported headset-microphone failure. No-headset, output-only-headset, and live hot-plug behavior still need broader hardware acceptance.
- Next: Run the remaining route matrix on a phone without accessories, output-only wired headphones, and a live headset disconnect/reconnect.

## 2026-08-10

- Progress: Added the call-style output preference and true-device diagnostics. With no accessory, the communication fallback now defaults to `EARPIECE` and switches to `SPEAKER` from the UI; connected accessories remain system-prioritized. Agent text now reaches CoreSpeech TTS automatically, and the engine reports successful PCM synthesis at 16 kHz.
- Impact: Input/output routing now follows the intended phone-call model, but generated text is not yet audible in the current development build. Device logs show the system TTS internal `VOICE_ASSISTANT` player is denied audio focus while the app owns a `VOICE_COMMUNICATION` AudioSession (`ActivateAudioInterrupt Failed`, error `6800301`). This is a regression from adding communication-session ownership around capture/TTS, not a synthesis or Agent-text failure.
- Blockers: Automatic system TTS playback is blocked until system-owned TTS playback is isolated from the app's communication session. Communication-session recovery after forced system deactivation is implemented but still needs a true-device recovery event for acceptance.
- Next: Make the smallest audio-session ownership correction, then verify audible TTS with the microphone both enabled and disabled, confirm the interrupt error is gone, and complete the remaining no-accessory/headset hot-plug route matrix.

## 2026-08-10

- Progress: Applied the smallest CoreSpeech TTS focus correction: system TTS no longer acquires the app-owned communication session, while microphone-owned communication sessions allow mixing with the system `VOICE_ASSISTANT` player.
- Impact: The existing ASR/call-routing path remains intact, and TTS no longer creates or strengthens the `VOICE_COMMUNICATION` focus conflict that produced `6800301`.
- Blockers: Static verification, ArkTS type checking, and HAP assembly pass. No HDC target is connected, so audible playback and device logs remain unverified.
- Next: Install the new HAP on the phone, test automatic TTS with the microphone both enabled and disabled, and confirm `ActivateAudioInterrupt Failed` / `6800301` no longer appears.

## 2026-08-10

- Progress: Finished the Harmony interaction polish: persisted debug-only voice status, actual three-state output display, compact microphone text, centered message times and left/right bubbles, compact process metadata, stale-session recreation, conversation loading UI, reversed header groups, and concrete Provider labels supplied by the Adapter.
- Impact: Normal chat no longer exposes ASR/TTS diagnostics or duplicate timing metadata; history transitions visibly load; missing automatic sessions recover silently; audio output reflects HarmonyOS routing; configured Provider names such as `open1` can replace the generic `custom` label without changing provider semantics.
- Blockers: None in static checks, ArkTS compilation, signed HAP assembly, install, launch, or no-headset UI verification. Connected-headset route switching still needs user-operated hardware acceptance.
- Next: Connect a headset, confirm the icon changes to headset, switch once to speaker and back, then configure the deployed Adapter's `HERMES_*_PROVIDER_LABEL` values.
