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

在应用设置中填写 Adapter 的基地址，例如 `https://example.com/voice-native`，再填写对应的访问口令；Agent 选择器会从 `/api/agents` 动态加载目录。长期访问口令只用于前置 HTTP 请求换取，WebSocket 只发送短期 `voice_session` Cookie。

设置页还可以切换当前 Hermes Session 的 Provider / 模型，并选择鸿蒙离线语音或远端语音。模型列表由 Adapter 的 `/api/hermes/model/options` 受控返回，切换使用 `config.set(... --session)`，不会写回 Agent 默认配置、重建对话或重连语音；界面等待 `session.info` 后才显示已确认。鸿蒙离线模式支持选择系统返回的音色，并将音色和 `0.5x` 到 `2.0x` 的朗读语速长期保存在设备 Preferences 中；远端模式的音色由服务器 TTS 配置决定。关闭设置页不会写入草稿或重连，只有网关地址、访问口令或 Agent 发生变化时才会重建网关连接。

Hermes 的审批和澄清请求直接进入消息流，不显示独立卡片。审批气泡保留完整风险命令，只接受精确的“同意 / 取消”等固定回复；澄清气泡列出编号选项并接受下一条实际回答。两类回复都走 Hermes 专用响应方法，不会再次触发 Agent Prompt。模型设置优先显示 Adapter 返回的具体 Provider 标识，例如 `open1` 或 `waw`，不把通用的 `custom` / `OPENAIAPI` 当成部署名称。

## 鸿蒙离线 ASR 边界

CoreSpeechKit 当前使用离线短句识别。真机上单个识别 session 最长约 20 秒，持续静音约 10 秒也会结束。客户端会复用同一个 `SpeechRecognitionEngine`，只轮换 session ID，并在约 150 ms 后继续监听，因此长时间开启语音不会在每轮重建引擎时留下数秒空档。不过，一次连续发言超过单 session 上限时仍会被拆成多段提交，而不是合并成一个无限长的听写结果。

语音后端选择是显式配置。选择鸿蒙离线语音后，CoreSpeech 启动或运行失败只会停止对应的本地语音路径并报告错误，不会自动连接远端 ASR/TTS；只有用户在设置页明确选择远端语音时才会建立远端语音连接。

## 远端 ASR/TTS 恢复

远端语音 WebSocket 意外断开后，客户端按 `250 / 750 / 1500 / 3000 ms` 封顶退避重连，连接成功后重置退避。ASR 在断线和等待 Provider `ready` 期间保留最近 4 个 PCM 块（约 0.8 秒），普通 final 在约 1.1 秒窗口内合并；连接从开始到 `ready` 超过 10 秒会主动进入下一轮恢复。TTS 的文本和 `done` 帧严格按队列顺序发送，失败帧保留到重连后继续；已收到的 PCM 会先排空。暂停收音、静音、切换到鸿蒙离线语音或主动断开会取消对应重连，`停止` 和显式关闭仍会清空待播任务。

全双工音频统一声明为鸿蒙语音通信场景。PCM 采集固定使用 `SOURCE_TYPE_VOICE_COMMUNICATION`，应用自管的 PCM 播放使用 `STREAM_USAGE_VOICE_COMMUNICATION`，并共享 `AUDIO_SESSION_SCENE_VOICE_COMMUNICATION`。客户端无配件时默认 `EARPIECE`，耳机接入时回到系统默认的耳机路由；输出按钮可以显式切到 `SPEAKER`，再次点击则回到当前系统私密路由。界面监听系统首选输出，按实际路由显示听筒、扬声器或耳机。蓝牙 SCO、NearLink、有线和 USB 设备的实际选择及无输入设备时的手机麦克风回退仍由 HarmonyOS 管理。客户端不调用 `selectMediaInputDevice()`，不再根据输出设备推断输入设备，也不因正常插拔重建 `AudioCapturer`。`inputDeviceChange` 仅用于刷新手机或耳机麦克风标签和记录诊断日志。短提示音不持有通信 Session，避免麦克风关闭后反复切换 A2DP/SCO。STT 和 TTS 保持并行；用户开口后只停止旧播报，不停止或重建识别 session。客户端不叠加 RMS 声音阈值，以免截断轻声发言。外放回声消除和双讲识别的实际效果仍取决于设备系统实现。

系统 TTS 的音频焦点冲突已做最小修正：CoreSpeech TTS 不再额外持有客户端通信 AudioSession，麦克风仍在使用的通信会话改为允许与系统 `VOICE_ASSISTANT` 播放器并发。静态校验、ArkTS 类型检查和 HAP 构建已通过；仍需真机确认自动播报恢复，并确认日志中不再出现 `ActivateAudioInterrupt Failed` / `6800301`。

## 发布前检查

1. 通过 `node scripts/verify.mjs`，确认单 Agent 路由和权限没有回退到主持人协议。
2. 在真机上验证前台文字、连续 ASR、TTS 排空、审批拒绝/允许、网络断开恢复和麦克风权限拒绝。
3. 确认公网 Adapter 的 HTTPS 证书、WSS 反代、`VOICE_ACCESS_TOKEN` 和 Agent Catalog 中的 Hermes 后端均可用。
4. 在 DevEco Studio 中使用发行签名构建 HAP，再通过 AppGallery Connect 创建版本、上传 HAP、填写隐私与权限说明并提交审核。

真机和 AppGallery Connect 的签名、上传、审核需要开发者账号授权，不能由本地源码或 CI 自动替代。

## Voice control semantics

The microphone button controls input only: it stops `AudioCapturer`, PCM delivery, and ASR sessions. It does not interrupt an Agent turn or stop an active TTS job. The `停止` button is the explicit current-turn interrupt: it cancels the Agent task and clears TTS playback while leaving microphone state unchanged. Re-enabling the microphone resumes ASR without needlessly reconnecting an active TTS stream.
