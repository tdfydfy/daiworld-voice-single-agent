# Daiworld Voice Single-Agent HarmonyOS 客户端

这是单 Agent Hermes 协议的原生 HarmonyOS 客户端，和仓库中的主持人多 Agent 客户端分开维护。客户端每次连接一个由 Adapter Catalog 返回的 Agent ID，使用同一套 JSON-RPC、连续 ASR 和流式 TTS 接口。HarmonyOS 是最终移动交付面，Web Native 仅用于技术预览和协议验证。

## 环境

- DevEco Studio，并安装兼容 HarmonyOS 6.1 / API 24 的 SDK；
- Node.js 18+；
- 与 SDK 匹配的 `ohpm` / Hvigor；
- 一台已启用开发者模式的 HarmonyOS 手机，或 API 12 模拟器。

仓库不包含签名证书、Profile、P12 或访问口令。首次打开工程时，在 DevEco Studio 的 Signing 页面启用自动签名，发布包再选择组织自己的发行证书。

## 安装与构建

在本目录执行依赖安装：

```powershell
ohpm install
```

然后用 DevEco Studio 打开 `clients/harmony`，选择 `entry` 模块和 `default` 产品。命令行构建（已配置 Hvigor 的环境）可以使用：

```powershell
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

HAP 产物位于 `entry/build/` 下。命令行构建时，需要让 `NODE_HOME` 指向 DevEco 的 `tools/node`，`JAVA_HOME` 指向 DevEco 的 `jbr`，并让 `DEVECO_SDK_HOME` 指向 DevEco 的 `sdk` 目录。没有 DevEco Studio、HarmonyOS SDK 或 Hvigor 时，仓库只能完成 Node 静态校验，不能在普通 Node 环境中编译 ETS 或生成 HAP。

## 连接 Adapter

启动仓库根目录的 Native Adapter，并确保它使用 HTTPS/WSS 暴露：

```powershell
$env:VOICE_ACCESS_TOKEN = '本地访问口令'
$env:HERMES_DASHBOARD_SESSION_TOKEN = 'Hermes 内部口令'
python -m uvicorn app.native_main:app --host 0.0.0.0 --port 8844
```

在应用设置中填写 Adapter 的基地址，例如 `https://example.com/voice-native`，再填写对应的访问口令；Agent 选择器会从 `/api/agents` 动态加载目录。访问口令当前保存在应用私有 Preferences 中并在写入后立即读回校验；目标 HarmonyOS 6.1 真机上的 HUKS AES-GCM 回读不稳定，因此不再作为连接前置条件。长期访问口令只用于前置 HTTP 请求换取，WebSocket 只发送短期 `voice_session` Cookie。

Hermes JSON-RPC 链路使用 Adapter 每 25 秒发送的 `gateway.heartbeat` 保活。客户端在收到首个心跳后启用 70 秒看门狗，超时会关闭悬挂 socket 并按有界退避重新鉴权、恢复当前 Session。恢复路径保留现有消息、语音输出开关和播放状态，不会重放 Prompt；旧 Adapter 不发送心跳时不会误触发看门狗。

设置页还可以切换当前 Hermes Session 的 Provider / 模型，并选择鸿蒙离线语音或远端语音。模型列表由 Adapter 的 `/api/hermes/model/options` 受控返回，切换使用 `config.set(... --session)`，不会写回 Agent 默认配置、重建对话或重连语音；界面等待 `session.info` 后才显示已确认。鸿蒙离线模式支持选择系统返回的音色，并将音色和 `0.5x` 到 `2.0x` 的朗读语速长期保存在设备 Preferences 中；远端模式的音色由服务器 TTS 配置决定。关闭设置页不会写入草稿或重连，只有网关地址、访问口令或 Agent 发生变化时才会重建网关连接。

Hermes 的审批和澄清请求直接进入消息流，不显示独立卡片。审批气泡保留完整风险命令，只接受整句“同意”或“取消”，仅容忍 ASR 附加在口令两端的空格和标点；澄清气泡列出无编号语义选项，等待完整收句后提交，数字和序号不在客户端映射。两类回复都走 Hermes 专用响应方法，不会再次触发 Agent Prompt。模型设置优先显示 Adapter 返回的具体 Provider 标识，例如 `open1` 或 `waw`，不把通用的 `custom` / `OPENAIAPI` 当成部署名称。

## 鸿蒙离线 ASR 边界

CoreSpeechKit 当前使用离线短句识别。真机上单个识别 session 最长约 20 秒，持续静音约 10 秒也会结束。客户端会复用同一个 `SpeechRecognitionEngine`，只轮换 session ID，并在约 150 ms 后继续监听，因此长时间开启语音不会在每轮重建引擎时留下数秒空档。不过，一次连续发言超过单 session 上限时仍会被拆成多段提交，而不是合并成一个无限长的听写结果。

语音后端选择是显式配置。选择鸿蒙离线语音后，CoreSpeech 启动或运行失败只会停止对应的本地语音路径并报告错误，不会自动连接远端 ASR/TTS；只有用户在设置页明确选择远端语音时才会建立远端语音连接。

## 远端 ASR/TTS 恢复

远端语音 WebSocket 意外断开后，客户端按 `250 / 750 / 1500 / 3000 ms` 封顶退避重连，连接成功后重置退避。ASR 在断线和等待 Provider `ready` 期间保留最近 4 个 PCM 块（约 0.8 秒），普通转写在约 1.8 秒停顿窗口内合并连续 interim/final；连接从开始到 `ready` 超过 10 秒会主动进入下一轮恢复。TTS 的文本和 `done` 帧严格按队列顺序发送，失败帧保留到重连后继续；已收到的 PCM 会先排空。暂停收音、静音、切换到鸿蒙离线语音或主动断开会取消对应重连，`停止` 和显式关闭仍会清空待播任务。

全双工音频统一声明为鸿蒙语音通信场景。PCM 采集固定使用 `SOURCE_TYPE_VOICE_COMMUNICATION`，远端 TTS 由应用的 `STREAM_USAGE_VOICE_COMMUNICATION` PCM renderer 播放；本地 CoreSpeech 使用平台内置播放器。输出按钮任何时候都可打开 HarmonyOS `voice_call` 原生设备面板，由用户自由选择当前可用的有线、蓝牙、USB、NearLink 耳机、听筒或扬声器；附件插拔时系统首选仍以耳机优先。系统面板失败时才通过 `setCommunicationDevice(SPEAKER, true/false)` 回退切换，应用不叠加全局 `setDefaultOutputDevice`。界面监听系统首选输出并按实际路由显示设备。麦克风设备和无输入设备时的手机麦克风回退同样由 HarmonyOS 管理。客户端不调用 `selectMediaInputDevice()`，不再根据输出设备推断输入设备，也不因正常插拔重建 `AudioCapturer`。`inputDeviceChange` 仅用于刷新手机或耳机麦克风标签和记录诊断日志。短提示音不持有通信 Session，避免麦克风关闭后反复切换 A2DP/SCO。STT 和 TTS 保持并行；用户开口后只停止旧播报，不停止或重建识别 session。客户端不叠加 RMS 声音阈值，以免截断轻声发言；外放回声消除和双讲识别的实际效果仍取决于设备系统实现。

目标真机的 CoreSpeech 离线 TTS 不提供可用的 `SpeakListener.onData` PCM，即使显式请求 `audioType: pcm` 也只返回合成/播放状态。因此本地 TTS 使用平台 `engine.speak()` 和系统播放器，以 `onComplete(type=1)` 推进短段队列；应用 PCM renderer 只服务远端 TTS。重复停止会先清空当前 request ID，并将平台的重复停止异常按幂等结果处理。

当前 `1.2.5` 恢复已在 `1.1.2/1.2.1` 真机验证过的专用后台模式：系统 TTS 排队、播放或系统回调确认发声时，先停止现有租约并等待 `AUDIO_PLAYBACK` ready，再调用 `engine.speak()`；播完或用户开口暂停后恢复 `AUDIO_RECORDING`。新消息和历史重读继续共用句边界分段器：首段 20–48 字快速起播，后续段优先约 40–80 字且硬上限 96 字。亮屏、息屏不选择不同算法；完整策略和验收矩阵见 [`docs/HARMONYOS_AUDIO_STRATEGY.md`](../../docs/HARMONYOS_AUDIO_STRATEGY.md)。

## 发布前检查

1. 通过 `node scripts/verify.mjs`，确认单 Agent 路由和权限没有回退到主持人协议。
2. 在真机上验证前台文字、连续 ASR、TTS 排空、审批拒绝/允许、网络断开恢复和麦克风权限拒绝。
3. 确认公网 Adapter 的 HTTPS 证书、WSS 反代、`VOICE_ACCESS_TOKEN` 和 Agent Catalog 中的 Hermes 后端均可用。
4. 在 DevEco Studio 中使用发行签名构建 HAP，再通过 AppGallery Connect 创建版本、上传 HAP、填写隐私与权限说明并提交审核。

真机和 AppGallery Connect 的签名、上传、审核需要开发者账号授权，不能由本地源码或 CI 自动替代。

## AI 真机验证边界

本项目已获得持续有效的开发期真机授权：构建后可直接检查设备连接、保留数据安装签名 HAP、拉起 `EntryAbility`，并执行包/进程状态及不提交真实业务数据的简单接口检查，无需每轮重复确认。复杂点击流程、麦克风输入、语音听感、功能正确性、截图验收和视觉美感仍由用户操作并反馈；安装或成功拉起不能记为产品功能验收通过。授权原文和撤销边界见 [`docs/plans/2026-08-12-permanent-device-smoke-authorization.md`](../../docs/plans/2026-08-12-permanent-device-smoke-authorization.md)。

## Voice control semantics

Current `1.2.16` release behavior: every cold app start requires one manual activation of the full capture/ASR chain. After that, `关闭话筒` keeps capture and ASR running but routes finals through a local command-only gate; ordinary speech never reaches the Agent. The exact `打开话筒` command restores normal conversation routing. `停止任务` immediately clears local output and sends Hermes `session.interrupt` without changing the microphone route; server-side queue convergence is not inferred from local cleanup and is no longer a front-end release gate. The exact `退出软件` command first disposes playback, capture, recognition, background ownership, system speech, and network connections, then terminates the UIAbility without stopping the remote Agent task. The microphone button toggles the same conversation/command-only routing after capture has started.

The in-app help page explains when to use `关闭话筒`, `打开话筒`, `停止任务`, and `退出软件`. Settings also exposes a mobile-only system-instructions field. Its default asks for concise, conversational replies during voice interaction; saving it affects newly created HarmonyOS sessions only and does not modify Hermes backend prompt configuration.
