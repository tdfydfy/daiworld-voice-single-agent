# Daiworld Voice Single-Agent HarmonyOS 客户端

这是单 Agent Hermes 协议的原生 HarmonyOS 客户端，和仓库中的主持人多 Agent 客户端分开维护。客户端只连接一个 Profile，使用同一套 Adapter 的 JSON-RPC、连续 ASR 和流式 TTS 接口。

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

在应用设置中填写 Adapter 的基地址，例如 `https://example.com/voice-native`，再填写对应的访问口令和 Profile。长期访问口令只用于前置 HTTP 会话换取，WebSocket 只发送短期 `voice_session` Cookie。

设置页还可以选择鸿蒙离线语音或远端语音。鸿蒙离线模式支持选择系统返回的音色，并将音色和 `0.5x` 到 `2.0x` 的朗读语速长期保存在设备 Preferences 中；远端模式的音色由服务器 TTS 配置决定。关闭设置页不会写入草稿或重连，只有网关地址、访问口令或 Profile 发生变化时才会重建网关连接。

## 鸿蒙离线 ASR 边界

CoreSpeechKit 当前使用离线短句识别。真机上单个识别 session 最长约 20 秒，持续静音约 10 秒也会结束。客户端会复用同一个 `SpeechRecognitionEngine`，只轮换 session ID，并在约 150 ms 后继续监听，因此长时间开启语音不会在每轮重建引擎时留下数秒空档。不过，一次连续发言超过单 session 上限时仍会被拆成多段提交，而不是合并成一个无限长的听写结果。

录音链路会根据当前输出设备选择采集源：耳机、蓝牙耳机和听筒使用面向语音识别的采集源，与已验证的 CoreSpeechKit 真机示例一致；扬声器外放使用面向语音通信的采集源。STT 和 TTS 保持并行；用户开口后只停止旧播报，不停止或重建识别 session。客户端不叠加 RMS 声音阈值，以免截断轻声发言。外放回声消除和双讲识别的实际效果仍取决于设备系统实现。

## 发布前检查

1. 通过 `node scripts/verify.mjs`，确认单 Agent 路由和权限没有回退到主持人协议。
2. 在真机上验证前台文字、连续 ASR、TTS 排空、审批拒绝/允许、网络断开恢复和麦克风权限拒绝。
3. 确认公网 Adapter 的 HTTPS 证书、WSS 反代、`VOICE_ACCESS_TOKEN` 和三个 Hermes Profile 均可用。
4. 在 DevEco Studio 中使用发行签名构建 HAP，再通过 AppGallery Connect 创建版本、上传 HAP、填写隐私与权限说明并提交审核。

真机和 AppGallery Connect 的签名、上传、审核需要开发者账号授权，不能由本地源码或 CI 自动替代。
