# Voice Input and Output Separation

Date: 2026-08-10
Scope: `clients/harmony` only.

## Decision

The microphone control owns the input path only: `AudioCapturer`, PCM delivery, and ASR sessions. Turning it off must not interrupt an existing Agent turn or stop TTS playback. The `停止` control owns the current-turn interrupt: it cancels the Agent task and clears active TTS playback/queues while leaving microphone state unchanged.

Speech backend selection is explicit. When `harmony_offline` is selected, CoreSpeech startup or runtime failure must remain local, stop the affected voice path, and expose the failing phase/error. It must never silently switch ASR or TTS to the remote backend. Remote ASR/TTS starts only when the user explicitly selects `remote`.

The client keeps these concerns as separate state:

- `inputEnabled`: microphone and ASR are accepting new speech.
- `voiceOutputEnabled`: Agent responses may be sent to TTS, subject to mute settings.
- `agentBusy`: the remote Agent is still thinking or executing.
- `playback` / `ttsState`: local and remote speech output lifecycle.

## Acceptance

- Turning the microphone off stops capture and ASR without closing the Agent gateway or stopping an active TTS job.
- A response that arrives after microphone input is disabled can still be spoken when output is not muted.
- `停止` interrupts the current Agent task and stops TTS, but does not change microphone input state.
- Re-enabling the microphone resumes ASR without needlessly reconnecting an already active TTS stream.
- Harmony static verification, type checking, signed build, and true-device checks pass.

## Message Bubble Follow-up

- [ ] 修复 Harmony 消息气泡的流式更新和滚动跟随
  - Goal: 保持消息节点稳定，ASR 预览升级为正式用户消息，并让回复增长时仅在用户接近底部时自动跟随。
  - Acceptance: 流式 delta 不再重建整条消息；ASR partial/final 在同一条用户消息中更新；用户上翻时不被强制拉回底部。
  - Status: done
- [ ] 对齐过程信息、元数据和附件的气泡归属
  - Goal: 过程信息独立于助手正文，模型/Provider 元数据和附件与对应消息保持一致。
  - Acceptance: 助手正文、过程折叠块、附件在视觉和数据上属于同一条消息，但互不嵌套错位。
  - Status: done

Verification: `node clients/harmony/scripts/verify.mjs` passed; signed `assembleHap --mode module -p product=default --no-daemon` passed. True-device verification remains pending until HDC sees the phone.

## Reactive Message and Microphone Route Follow-up

- [ ] 修复稳定消息 key 后嵌套字段不刷新的问题
  - Goal: 保持气泡节点不重建，同时让 ASR partial、助手正文和 pending/process 状态逐次刷新。
  - Acceptance: 用户气泡显示完整 final；助手正文可见；完成后过程指示停止转动并可折叠。
  - Status: done
- [ ] 显示实际麦克风输入类型
  - Goal: 从当前 AudioCapturer 输入设备判断手机或耳机麦克风。
  - Acceptance: 麦克风开启后，按钮显示实际的“手机麦克风”或“耳机麦克风”。
  - Status: done

Verification: message rendering now uses `Repeat` with stable IDs and fresh UI snapshots; static verification, ArkTS type checking, signing, and HAP assembly pass.

- [ ] 诊断并收敛 CoreSpeech 长时间不返回 ready
  - Goal: 覆盖完整启动调用的超时，并显示权限、引擎创建、音频采集、识别会话、等待 ready 中的实际停留阶段。
  - Acceptance: 不再无限显示“ASR 启动中”；失败后关闭麦克风输入并保留 `harmony_offline` 后端，不自动连接远端 ASR/TTS；用户可再次手动开启重试。
  - Status: active

Implementation: optional Bluetooth/NearLink route setup is time-bounded, in-flight capture startup is cancellable, and a failed CoreSpeech attempt releases the recognizer before a user retry. Static verification, ArkTS type checking, signed assembly, and cover installation pass; user-operated true-device ASR verification remains pending.

## True-device Stability Follow-up

- [ ] Wait for the selected headset microphone route to settle after capture starts.
  - Goal: Use the headset microphone whenever an input-capable wired, Bluetooth, USB, hearing-aid, or NearLink device is explicitly selected.
  - Acceptance: A connected headset is not rejected by an immediate stale route read; capture fails only after the route-settling window confirms that the phone microphone remained active.
  - Status: active
- [ ] Rotate local CoreSpeech recognition sessions before the platform audio-length limit.
  - Goal: Keep one persistent PCM capture while using bounded recognition sessions.
  - Acceptance: Continuous microphone input no longer reaches `1002200003`; final results are preserved across session boundaries and the next local session starts automatically while input remains enabled.
  - Status: active
- [ ] Finalize the Agent process bubble on verified terminal paths.
  - Goal: Keep `agentBusy`, pending activities, and process animation consistent with gateway completion, failure, close, and explicit interrupt events.
  - Acceptance: “处理中 / 正在分析请求” stops accumulating after the Agent turn has actually ended, without using a speculative elapsed-time timeout.
  - Status: active

Implementation: capture uses `SOURCE_TYPE_VOICE_RECOGNITION` for both phone and headset input, verifies the explicit media-input selection, and polls the authoritative active route for up to five seconds. CoreSpeech counts written PCM bytes and finishes each session at an 18-second budget while retaining pre-roll for the controller's existing restart. Gateway event/session diagnostics were added, and pending assistant messages are finalized on completion, gateway failure/close, explicit interrupt, Agent error, and non-queued submit failure. Static verification, ArkTS type checking, signed assembly with `--no-daemon`, and cover installation pass; the three acceptance checks remain pending user-operated true-device testing.

## Original-behavior Regression Follow-up

- [ ] Restore route-dependent capture source selection.
  - Goal: Use communication capture with speaker output for system echo handling, and recognition capture with private headset output so HarmonyOS establishes the headset recording route.
  - Acceptance: Speaker TTS is not transcribed, and a connected input-capable headset no longer blocks microphone startup on a stale active-device descriptor.
  - Status: active
- [ ] Restore reliable streamed message repainting.
  - Goal: Re-render each changed message revision on ArkUI while retaining the persistent ASR message model.
  - Acceptance: User ASR text and assistant deltas display every update instead of stopping at the first character.
  - Status: active

Implementation: restored the original private-output route test and `ForEach` revision key. Speaker capture now uses `SOURCE_TYPE_VOICE_COMMUNICATION`; private output uses `SOURCE_TYPE_VOICE_RECOGNITION` plus the wireless recording preference. The client clears the previous explicit selection, does not call `selectMediaInputDevice()`, and treats active-device inspection as display/diagnostic state rather than a startup gate. Static verification, ArkTS type checking, signed assembly with `--no-daemon`, and cover installation pass; true-device acceptance remains pending.

## System-managed Communication Routing Follow-up

- [x] Use the HarmonyOS communication scene for the complete duplex audio path.
  - Goal: Let HarmonyOS apply its call-style route policy instead of inferring microphone routing from the media output device.
  - Acceptance: With no headset, communication audio uses the selected earpiece/speaker fallback and the phone microphone; with an input-capable headset, playback and capture use the headset route; output-only headsets fall back to the phone microphone as allowed by the system policy.
  - Status: done
- [x] Observe route changes without rebuilding the capture stream.
  - Goal: Keep device hot-plug under HarmonyOS ownership while exposing the actual active input route in the UI and logs.
  - Acceptance: `inputDeviceChange` updates the route label; the client does not call `selectMediaInputDevice()` or recreate `AudioCapturer` on a normal route change.
  - Status: done

Decision: PCM playback uses `STREAM_USAGE_VOICE_COMMUNICATION`, PCM capture uses `SOURCE_TYPE_VOICE_COMMUNICATION`, and the process activates `AUDIO_SESSION_SCENE_VOICE_COMMUNICATION` while either stream owns the shared communication session. The no-accessory output default is `EARPIECE`; the user can enable speakerphone explicitly, while connected-accessory and all input-device selection remain system-managed.

Verification: static checks, ArkTS type checking, signed HAP assembly, cover installation, and the connected FreeBuds 5 path pass. The device entered `PHONE_CHAT`; active capture and system input/output priority all reported `BLUETOOTH_SCO (7)`; the UI displayed `麦克风已开（耳机麦克风）`. Turning the microphone off released the communication session once, and short audio cues no longer reopened it. No-headset, output-only-headset, and live hot-plug variants remain a manual device matrix rather than implementation blockers.

## Call Output and Automatic TTS Follow-up

- [x] Add a persistent speakerphone preference.
  - Goal: Match normal call controls without taking accessory routing away from HarmonyOS.
  - Acceptance: The default is the earpiece; the speaker button switches the no-accessory fallback between `EARPIECE` and `SPEAKER`; a connected headset remains the preferred system route.
  - Status: done
- [ ] Recover an active communication session after system deactivation.
  - Goal: Keep call-style routing active for as long as capture or playback still owns the shared session.
  - Acceptance: `audioSessionDeactivated` triggers a bounded reactivation while the reference count is non-zero, without rebuilding `AudioCapturer`.
  - Status: active
- [ ] Restore automatic system TTS for generated Agent text.
  - Goal: Queue and play streamed/final assistant text automatically when voice output is enabled.
  - Acceptance: A deterministic text prompt produces audible TTS, and logs identify delta/final reception, chunk queueing, controller start, engine request, and terminal callbacks.
  - Status: blocked

Implementation status: the speakerphone preference is persisted, defaults to `EARPIECE`, and switches the no-accessory fallback to `SPEAKER`; the connected-device path remains system-managed. Bounded AudioSession recovery is implemented but still awaits a true-device `audioSessionDeactivated` recovery event. Automatic TTS dispatch is also implemented and verified through engine synthesis, but audible playback is blocked because CoreSpeech's internal `VOICE_ASSISTANT` renderer cannot acquire audio focus while the client holds `VOICE_COMMUNICATION` (`6800301`). The next change should isolate system TTS from the app-owned communication session before considering a custom PCM playback path.
