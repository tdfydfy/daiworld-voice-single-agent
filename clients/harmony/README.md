# Daiworld Voice HarmonyOS 客户端

这是 Single Agent Hermes 协议的原生 HarmonyOS 客户端，也是本仓库的主要移动端产品。当前稳定版本为 `1.2.16 (1020016)`，支持 HarmonyOS 6.1 / API 24。

## 环境

- DevEco Studio 及 HarmonyOS 6.1 / API 24 SDK；
- 与 SDK 匹配的 Node.js、`ohpm` 和 Hvigor；
- 已启用开发者模式的真机；
- 可访问的 HTTPS/WSS Native Adapter。

仓库不包含签名证书、Profile、P12 或真实访问口令。首次打开工程时在 DevEco Studio 的 Signing 页面启用自动签名。

## 安装与构建

```powershell
cd clients/harmony
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

命令行环境需让 `NODE_HOME` 指向 DevEco 的 `tools/node`、`JAVA_HOME` 指向 `jbr`、`DEVECO_SDK_HOME` 指向 SDK。HAP 产物位于 `entry/build/`。

## 连接

首次启动时在设置中填写 Adapter HTTPS 基地址和 `VOICE_ACCESS_TOKEN`。客户端通过 `/api/agents` 加载 Hermes Profile，不保存内部 URL 或 Provider 凭据。长效访问口令只用于换取短期 HttpOnly Cookie，后续 WebSocket 不传长效口令。

设置页可以选择：

- 当前 Hermes Agent；
- 当前 Session 的 Provider / 模型；
- 鸿蒙离线语音或 Adapter 远端 ASR/TTS；
- 离线 TTS 音色和语速；
- 仅作用于新建移动端 Session 的系统指令偏好。

## 交互基线

- 每次冷启动需要用户手动开启一次完整收音链路；
- `关闭话筒`：保持采集和 ASR，仅允许本地系统命令，普通语音不提交 Agent；
- `打开话筒`：恢复普通对话提交；
- `停止任务`：立即清理本地输出并发送 Hermes `session.interrupt`，不改变话筒路由；
- `退出软件`：释放本地音频、后台任务和网络连接后退出，不隐式停止远端任务；
- 审批只接受规范化后的精确整句 `同意` 或 `取消`；
- 瞬态断线重新鉴权并恢复当前持久 Session，不重放 Prompt。

完整规则以 [交互与协议规范](../../docs/INTERACTION_AND_PORTING_SPEC.md) 为准。

## 图片和文件

Adapter 会把 Agent 回复中的受支持引用转换成短期附件令牌。图片在消息中内联展示，Word、PDF、表格、演示文稿、文本和压缩包显示为文件项并交给系统打开或下载。客户端从不接收或展示 `/root/...`、`sandbox:/...` 等服务器路径。

## 验证与发布

静态契约检查：

```powershell
node scripts/verify.mjs
```

发布前必须在真机验证登录、Agent 目录、文本、语音、审批、断线恢复、前后台切换、图片内联和至少一种非图片文件下载。安装成功或 Ability 成功拉起不等于功能验收通过。

AI 可在长期授权范围内完成连接检查、保留数据安装、启动和非业务冒烟；涉及真实语音听感、账号数据或交互判断的测试仍由用户确认。授权边界见 [长期真机冒烟授权](../../docs/plans/2026-08-12-permanent-device-smoke-authorization.md)。
