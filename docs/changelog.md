# 变更记录

## 2026-08-11

- 新增：Adapter 在 Hermes JSON-RPC 下行链路每 25 秒发送 `gateway.heartbeat`；HarmonyOS 在收到首个心跳后启用 70 秒看门狗，并兼容不发送心跳的旧 Adapter。
- 修复：自动网关重连使用无损 `session.resume`，不再调用 `stopVoice()`、清空消息或重放 Prompt；Gateway 错误不再覆盖独立播放状态。
- 修复：系统 TTS 单条重读不再等待无关的远端 PCM renderer 清理，远端重读仍按代际串行清理以隔离迟到回调。
- 发布：本地签名包提升为 `1.1.1 (1010001)`；Python 27 项、Node 19 项、Harmony 静态校验、ArkTS 类型检查和签名构建通过，本条不代表已部署或真机验收。
- 部署：`foxi` Adapter 已更新并保留现网回滚副本；运行源码哈希、systemd `active/running`、本机/公开 `200` 和未鉴权 `401` 检查通过。`1.1.1 (1010001)` HAP 已保留数据覆盖安装，应用未启动，声音验收仍待用户操作。
- 验收：用户确认 `1.1.1` 当前基本可用；Agent/运行身份展示、供应商主动刷新、重读无声、思考呼吸音和设置布局问题已转入下一阶段计划。
- Fixed HarmonyOS replay lifecycle races: old PCM renderer cleanup is serialized before new replay TTS starts, replay generations invalidate stale async work, and late remote/system TTS callbacks cannot clear or overwrite the new replay state.
- Added cancellation protection for system TTS requests that are still initializing when `stopSpeaking()` is called.
- Verification and delivery: Harmony static checks, ArkTS type check, signed HAP assembly, and Node tests passed; the signed HAP was cover-installed to device `6HQ0226409028766` (SHA-256 `06558583C0A89E9F5455824463E0AAA803976C7C054F1AC36B5174948DF36BAC`).
- True-device audio acceptance remains pending user operation.

只记录重要且已经交付的变化。

## 2026-08-11

- 安全：HarmonyOS 访问口令改为 HUKS 管理的 AES-256-GCM 加密存储；旧 Preferences 明文字段只在安全写入成功后删除，读取或迁移失败时不回退明文。
- 修复：Gateway 将 401/403 与网络/5xx 故障分流；瞬态故障按 `500 / 1500 / 3000 / 5000 ms` 有界重连，使用 10 秒 ready 看门和连接代际隔离，并只恢复已有 Session、不重放用户 Prompt。
- 发布：本地签名包提升为 `1.1.0 (1010000)`；自动化、ArkTS、签名和包内版本核验通过，本条不代表已部署或真机验收。
- 部署：当前 Adapter 已更新到 `foxi` 并通过服务状态、源码哈希和未鉴权 `401` 路由检查；`1.1.0 (1010000)` HAP 已安装到设备，尚未由 AI 启动或代替用户进行语音验收。
- 变更：收音控制词收敛为“关闭话筒”“关闭麦克风”“关闭microphone”“暂停收音”四条白名单；归一化后仍只做整句精确匹配，不接受“闭麦”或其他英文误识别。
- 修复：Adapter 统一拦截不含 Unicode 字母/数字的 ASR final，并以下发空 final 而非丢帧的方式结束客户端收句；HarmonyOS 保留同规则兜底，Web 仅保留协议回归。
- 修复：HarmonyOS 远端 ASR/TTS WebSocket 意外断开后自动退避重连，隔离旧连接迟到回调，并用 10 秒看门退出长期 connecting / 等待 ASR ready 的悬挂状态。
- 修复：ASR 重连保留最近约 0.8 秒 PCM，TTS 待发文本和 `done` 帧严格按顺序恢复并先排空已收到的 PCM；发布包版本提升为 `1.0.3 (1000003)`。
- 修复：HarmonyOS 耳机可用时不再强制切回听筒；PCM renderer 增加写入看门、状态 / 中断监听和音频会话恢复联动，避免播放卡顿后必须靠下一条消息唤醒。
- 修复：ASR 空文本 / 纯标点误触发会恢复被暂停的播报；本地与远端普通 `final` 在 1.1 秒窗口内合并，减少气口和 Provider 分段造成的中途提交。修复包版本为 `1.0.2 (1000002)`。
- 新增：HarmonyOS Agent 回复气泡支持单条重读和再次点击停止；重读不创建 Hermes 任务，遵守语音输出状态，过滤代码、链接、文件路径和 `MEDIA:`，并覆盖系统 / 远端 TTS 的实际播放生命周期。
- 修复：Adapter 按 Hermes 实际的顶层 `provider` 和 `is_current` 字段确定当前 Provider；`foxi` 三个 profile 已部署并验证返回 `open1`，设置选项保留 `open1` / `wawapi` 等真实别名。
- 新增：HarmonyOS 设置页从安装包清单读取软件版本；该功能首次随 `1.0.1 (1000001)` 提供，避免无法确认是否安装了更新。
- 新增：Adapter、Web 技术预览和 HarmonyOS 支持动态 Agent Catalog；HarmonyOS 可展示 Agent 身份并使用服务端语音回复策略。
- 新增：HarmonyOS 当前 Session 的模型 / Provider 受控切换，以及思考过程自然行展示。
- 变更：HarmonyOS 审批和澄清请求改为对话气泡；下一条文字或语音直接响应 Hermes pending 状态，不再显示独立卡片或重复触发 Agent。
- 修复：模型选项将通用 `OPENAIAPI` 显示名还原为 `open1` / `waw` 等具体公开标识，并用 `active_provider_label` 对齐顶部 Session 身份。
- 修复：在 `foxi` 部署包含 `/api/agents` 的新版 Adapter，未鉴权请求由错误的 `404` 恢复为预期 `401`；服务状态验证为 `active`，HarmonyOS 真机重新启动后已正常显示动态 Agent 和“在线”状态。
- 变更：Web Native 定位为稳定后暂停新增功能的技术预览，后续产品化与真机验收以 HarmonyOS 为主。
