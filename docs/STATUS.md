# 项目当前状态

更新时间：2026-08-13

- 总体状态：用户确认 `1.2.4` 真机报“本地 TTS 未返回 PCM 音频流”；目标设备即使显式请求 `audioType: pcm`，CoreSpeech 也不回调可用的 `SpeakListener.onData`。已按用户要求检查老代码，确认 `1.1.2/1.2.1` 曾通过真机息屏长文验收的路径是系统 `engine.speak()` 加播放优先的专用 `AUDIO_PLAYBACK` 后台模式。
- 当前阶段：P0 持续运行底座与本地播放连续性真机门。`1.2.5` 已撤销本地 CoreSpeech PCM 接管和录播组合租约，恢复系统播放器及专用 `AUDIO_PLAYBACK`/`AUDIO_RECORDING` 串行切换；代码、自动化和签名构建已完成，待覆盖安装后的用户听感验收。
- 当前任务：[用户旅程驱动的当前计划](PLAN.md)，本轮来源为[恢复旧版已验证的息屏播放路径](plans/2026-08-13-restore-proven-screen-off-playback.md)。
- 已完成到：系统 TTS 排队或播放时，控制器优先请求播放意图；`BackgroundAudioTaskOwner` 停止旧模式并等待 `AUDIO_PLAYBACK` ready 后才允许 `engine.speak()`。平台 `onComplete(type=1)` 推进短段队列，结束或用户开口后恢复 `AUDIO_RECORDING`。停止旧任务遇到 `9800005` 按已经停止处理；request generation 和完成后清空 request ID 保留重复点击幂等。
- 保留能力：输出按钮任何时候都可打开 HarmonyOS `voice_call` 原生设备面板；耳机插拔恢复系统首选，用户仍可自由覆盖。采集状态、中断和无 PCM 看门仍按 `100 / 500 / 1500 ms` 三次有界恢复；远端 TTS 继续使用应用 `PcmPlayer` 和 drain。
- 当前实现基线：`1.2.5 (1020005)`。已具备动态 Agent、Session 恢复、连续 ASR、系统/远端 TTS、消息重读和四类提醒入口；目标控制语义仍未落地。
- 活跃问题：`1.2.5` 需在目标真机复验新消息和历史气泡长文播放中息屏是否连续，并确认播放完成后持续 ASR 恢复；输出设备自由选择只需做回归，不再改路由实现。
- 优先级边界：不再继续尝试本地 CoreSpeech PCM 参数；除非目标设备后续稳定返回真实 PCM 数据，否则本地 TTS 固定使用系统播放器。审批、视觉细节和连续 ASR 体感验收在息屏播放通过后处理。
- 最近验证：Node 28/28、Python 27/27、HarmonyOS 32 个 ETS 静态校验、ArkTS 类型检查、编译和签名 HAP 构建通过，`git diff --check` 无错误。最终 HAP 为 `clients/harmony/entry/build/default/outputs/default/entry-default-signed.hap`，SHA-256 `5C8F07369CF7CC0ACB32B7B7AD48EA7FACA4AE7CFE1C91361B2EF6A6DC937A59`；已保留数据覆盖安装到设备 `6HQ0226409028766`，设备端确认 `1.2.5 (1020005)`、`backgroundModes=6`，`EntryAbility` 拉起成功并处于前台。复杂语音听感仍未宣称通过。
- 下一恢复点：覆盖安装 `1.2.5` 并拉起后，由用户先播放一条长回复，播放中息屏 10 秒以上；确认无“本地 TTS 未返回 PCM 音频流”、不断音、不跳字后，再测试同一气泡重复点击和播放结束后的语音输入恢复。
