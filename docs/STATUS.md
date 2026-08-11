# Development Status

## 2026-08-11 - Replay lifecycle fix

- Progress: Fixed HarmonyOS single-message replay startup ordering. Replay now advances a generation, serializes `PcmPlayer.stop()` cleanup, ignores late TTS callbacks while old playback is being released, and starts remote/system TTS only after cleanup completes. System TTS also cancels requests that are still waiting for engine initialization after `stopSpeaking()`.
- Verification: Harmony static verification passed (18 ETS files), ArkTS type check and signed HAP assembly passed, Node tests passed (19), and `git diff --check` passed. The signed HAP was cover-installed successfully on device `6HQ0226409028766`.
- Artifact: `clients/harmony/entry/build/default/outputs/default/entry-default-signed.hap`, SHA-256 `06558583C0A89E9F5455824463E0AAA803976C7C054F1AC36B5174948DF36BAC`.
- Blockers: The app was installed but not started by AI. Audible replay, repeated stop, system/remote TTS output, and headset listening remain user-operated true-device checks.
- Next: Start the installed app and test a short reply, a long reply, replay after prior playback, replay stop/replay again, and replay while using the microphone. Capture the first TTS state/PCM or system `onStart` if silence remains.

## 当前快照（2026-08-11）

- 总体状态：正常推进。
- 当前阶段：`1.1.0 安全与连接韧性` 已完成部署，进入真机验收。
- 当前任务：由用户启动已安装的 `1.1.0` HAP，集中进行安全迁移、连接恢复、Session 连续性和语音交互验收。
- 已完成到：HUKS AES-256-GCM 令牌存储、旧明文一次性迁移、页面异步初始化、Gateway 鉴权分类/有界重连、Session 恢复且不重放 Prompt，以及 `1.1.0 (1010000)` 签名构建。
- 活跃问题：HUKS 真实密钥生命周期、旧令牌迁移、断网重连、Session 连续性和语音听感尚未真机验证；当前没有服务器部署阻塞。
- 最近验证：Python 26 项、Node 19 项、Harmony 18 个 ETS 文件静态校验、ArkTS 类型检查、签名构建和 `git diff --check` 通过；包内版本为 `1.1.0 (1010000)`，最新 HAP SHA-256 为 `419dfabdbce307f2b7740404a9b42c73a505ab481e057f6c106b9d7d59857efb`。
- 下一恢复点：用户启动应用后，按真机清单验证耳机长播报、ASR 连续收音、停止/暂停收音、审批/澄清、Agent/Provider/模型切换和重连恢复。

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
