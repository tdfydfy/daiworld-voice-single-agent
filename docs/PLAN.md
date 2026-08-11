# 当前计划

## Current follow-up - replay lifecycle

- [x] Serialize replay cleanup before starting a replacement TTS job; protect the active replay from stale renderer and TTS callbacks.
- [x] Cancel pending system TTS initialization after `stopSpeaking()` so an old replay cannot start after a new replay has been queued.
- [x] Run Harmony static verification, ArkTS type checking, signed HAP assembly, Node tests, and cover-install the HAP to the connected device.
- [ ] User true-device acceptance: start the app and confirm replay produces audible output, can be stopped, and can be replayed again without waiting for another message.

更新时间：2026-08-11

## 产品落点与范围（2026-08-11）

- Web Native 仅作为同源技术预览和自动化验证面；本轮动态 Agent 功能稳定后，暂停 Web 客户端新增功能。
- HarmonyOS 移动应用是最终交付面，后续语音、交互和真机验收优先投入 HarmonyOS；Web 只保留必要的协议回归和稳定性修复。

## 当前里程碑：1.1.0 安全与连接韧性

- 来源：`docs/plans/2026-08-11-non-device-development-milestone.md`
- 目标：先连续完成可在本地验证的安全与连接韧性能力，再统一部署并进行真机验收。
- 范围边界：里程碑完成前不部署 Adapter，不安装或启动 HAP，不操作真机；允许自动化测试、ArkTS 类型检查和签名构建。
- 完成标准：
  - [x] 已保存访问令牌由 Preferences 明文迁移为 HUKS 管理密钥加密存储，迁移成功后删除旧明文字段。
  - [x] Gateway 鉴权失效和意外断开可恢复，Session 重建/恢复不重复提交用户消息。
  - [x] Python、Node、Harmony 静态校验和 ArkTS 类型检查覆盖新增安全与重连约束。
  - [x] 版本提升至 `1.1.0`，签名 HAP 构建和包内版本核验通过。
- 当前动作：Adapter 与 `1.1.0` HAP 已完成统一部署/安装；等待用户启动应用并完成真机验收。
- 风险：HUKS 密钥生命周期、旧明文令牌一次性迁移、Gateway 真实断网恢复和 Session 连续性仍需在统一真机测试中确认。

## 正在做

- [ ] [Harmony/远端语音恢复] ASR / TTS WebSocket 意外断开后自动重连
  - [x] ASR 未连接或未 ready 时保留最近 4 个 PCM 块，重连不清空预备音频
  - [x] TTS 重连保留断线后产生的待发送文本 / done 帧并按顺序串行发送，显式关闭仍彻底清理
  - [x] 控制器使用有上限退避恢复远端 ASR / TTS，ready 后重置退避；单次连接 10 秒超时
  - [x] ASR 短暂断线不立即拆分当前转写；重连失败期间仍按收句窗口提交已有有效文本
  - [x] TTS 断线后排空已收到的 PCM，连接恢复后继续接受后续语音任务
  - [x] 增加静态回归检查并完成 Python 25 项、Node 19 项、ArkTS 和签名 HAP 构建
  - [x] 真机网络切换验收按用户要求暂缓，不阻塞后续开发
  - [ ] 用户真机验收短暂断网、长连接悬挂、耳机播放续接和连续收音

- [ ] [Harmony/真机语音稳定性] 修复播放中断、跳字与 ASR 中途拆句
  - [x] 耳机存在时不强制回退听筒，避免系统输出路由抖动
  - [x] PCM renderer 创建失败和音频会话恢复后自动有界重试，不依赖下一条消息唤醒
  - [x] ASR 误触发后若只有空文本 / 纯标点，自动恢复被暂停的播报
  - [x] 普通 ASR final 延迟约 1.1 秒提交并合并连续分段
  - [x] “停止 / 暂停收音”和审批、澄清回复继续即时处理
  - [x] Python 25 项、Node 19 项、Harmony 静态检查、ArkTS 类型检查和签名 HAP 构建通过
  - [ ] 用户真机验收耳机长播报、焦点恢复、自然停顿和连续分段
  - 来源：`docs/plans/2026-08-11-voice-interruption-and-asr-segmentation.md`

- [ ] [消息播报/真机] 验收 HarmonyOS 单条 Agent 消息重读
  - [x] 在 Agent 回复气泡内提供固定尺寸的重读图标，播放中可再次点击停止
  - [x] 重读不创建 Hermes 对话、不重复执行 Agent，并在 Agent 忙碌或用户说话时禁用
  - [x] 重用 `SpeechTextFilter` 清理 Markdown、代码块、链接、文件路径和 `MEDIA:`
  - [x] 遵守语音输出 / 静音状态，远端与系统 TTS 都在真实播放结束后清理消息状态
  - [x] Python 25 项、Node 19 项、Harmony 静态校验、ArkTS 类型检查和签名 HAP 构建通过
  - [ ] 用户安装本轮 HAP，验证短回复、长回复、代码 / 附件回复、再次点击停止和说话暂停 / 恢复

- [ ] [Harmony/对话协议] 将审批与澄清选项改为对话内容，并统一实际 Provider 身份
  - [x] `approval.request` 和 `clarify.request` 进入消息流，不再显示独立卡片
  - [x] 下一条文字或语音直接走 `approval.respond` / `clarify.respond`，不触发新的 Agent Prompt
  - [x] 审批只接受精确同意 / 取消词，未知内容保持等待且默认安全失败
  - [x] Adapter 识别 Hermes 的顶层 `provider` / `is_current` 字段，返回当前具体 Provider（服务器实测为 `open1`，可选 `wawapi`），不再按模型名误匹配 `openai-api`
  - [x] HarmonyOS 设置页从 HAP 清单读取并显示版本名和版本码，当前本地待部署版本为 `1.1.0 (1010000)`
  - [x] Python 25 项、Node 19 项、Harmony 静态校验、ArkTS 编译和签名 HAP 构建通过
  - [x] 新版 Adapter 和可回滚部署脚本已放入 `foxi:/home/admin/daiworld-voice-agent-update-20260811/`，上传哈希一致且暂存源码编译通过
  - [x] 用户执行交互式 `sudo` 完成 Adapter 更新，并确认运行文件哈希与暂存版本一致
  - [x] 新版签名 HAP 已覆盖安装到真机 `6HQ0226409028766`
  - [ ] 用户真机验收对话式审批/澄清、Provider 显示和实际 Session 切换结果
  - 来源：`docs/plans/2026-08-11-conversational-prompts-and-provider-identity.md`

- [ ] [Harmony/语音基础] 完成当前音频闭环的真机验收与回归
  - [ ] 验证已连接耳机时的麦克风路由与图标状态
  - [ ] 验证听筒 / 扬声器切换，以及无耳机、仅输出耳机、耳机热插拔场景
  - [ ] 验证 `audioSessionDeactivated` 后的有界恢复
  - [ ] 麦克风开启和关闭两种状态下验证自动 TTS 可听、确认 `6800301` 不再出现
  - [ ] 在真实手机上确认 ASR、TTS、Agent 过程状态和终止状态一致

- [ ] [Agent与语音] 落实动态 Agent 目录、顶部身份展示和语音回复策略
  - [x] 定义并测试 Agent Catalog 接口及后端配置结构，客户端不写死 Profile
  - [x] HarmonyOS 改为动态 Agent 状态，处理加载、空列表、删除回退和切换
  - [x] 重构顶部 Agent 区域，加入头像占位及当前模型 / Provider
  - [x] 接入后端语音回复策略，不污染用户消息和历史记录
  - [x] 增加 `speech_text` 兼容与 TTS Markdown / 代码块过滤
  - [x] 完成静态检查、自动化测试、ArkTS 编译、签名 HAP 构建和覆盖安装
  - [x] 将包含 `/api/agents` 的新版 Adapter 部署到 `foxi`；已确认 root 提权、服务 `active`，未携带凭据访问返回预期 `401`
  - [x] 保持客户端只使用正式 Agent Catalog 契约，不增加旧 Adapter 降级逻辑
  - [x] 真机重新启动后动态目录正常加载，界面显示“赫小码”和“在线”，不再出现 HTTP 404，已有 Session 可恢复
  - [ ] 完成 Agent 切换、新建 Session、删除/空列表回退和 TTS 清理的真机交互验收
  - [x] 详细计划：`docs/plans/2026-08-10-dynamic-agents-and-voice-response.md`
  - [x] 服务端契约来源：`docs/plans/2026-08-11-server-agent-catalog-contract.md`

- [ ] [消息展示] 将 HarmonyOS 的 `thinking.delta` / `reasoning.delta` 按自然行展示
  - [x] 保留服务端换行和阶段顺序，连续增量只更新当前未完成行
  - [x] 没有换行时按完整句末标点分行，避免每个 token 产生一行
  - [x] 过程区保持可折叠、可滚动和完成状态
  - [ ] 验收：长思考过程可逐行阅读，正文、工具过程和思考过程不混排

- [ ] [Hermes 设置] 增加当前会话的模型 / Provider 快速切换
  - [x] 决定仅切换当前 Session，不写回当前 Profile 默认配置
  - [x] 从 Adapter 受控接口读取可用 Provider / 模型列表，不在客户端硬编码密钥
  - [x] 切换过程中保留当前对话和语音连接状态，失败时显示原因并保持原配置
  - [x] 成功后以 `session.info` 确认并更新顶部实际生效的模型 / Provider
  - [x] HarmonyOS 提供正式入口和状态反馈；Web 技术预览只保留现有协议回归
  - [ ] 验收：选择后能确认实际生效的模型、Provider，重连或恢复 Session 后状态不漂移

## 下一步

### 1. 延长语音输入停顿判定（已并入当前任务）

- [ ] [连续 ASR] 延长气口 / 短暂停顿的收句判定时间，避免用户思考时被系统抢话
  - [x] 梳理 HarmonyOS、豆包流式 ASR 的结束判定和缓冲参数，以 Web 现有行为作参考
  - [x] 使用 1.1 秒收句窗口合并 interim / final，并在异常结束时保留有效文本
  - [x] 保留用户主动提交、停止和暂停收音的优先级，不让延长窗口阻塞明确指令
  - [ ] 使用真实手机外放 / 耳机分别验证连续表达、思考停顿和真正结束
  - [ ] 验收：短暂停顿不会过早提交；真正结束仍能在可接受延迟内提交

### 2. 语音输入纯符号前置过滤

- [x] [ASR 输入] 在 ASR final 进入 Hermes 前增加纯标点 / 符号过滤
  - [x] trim 后以 Unicode 字母 / 数字判断是否含实际语义
  - [x] 纯符号结果不创建正式用户消息、不进入队列、不触发 Agent 回复
  - [x] 保留包含汉字、字母、数字或实际语义内容的正常短句
  - [x] Adapter 将纯符号 final 归一为空 final；HarmonyOS 保留同一 Unicode `L/N` 规则作为防御边界，Web 只保留协议回归
  - [x] 验收：纯 `。`、`,`、`…`、emoji、下划线和重复标点被拦截；正常短句、Unicode 数字和带标点短句正常提交

### 3. “暂停收音”指令与停止任务分离

- [ ] [语音控制] 增加“暂停收音”控制指令，关闭麦克风输入但不影响 Agent 思考和 TTS 播报
  - [x] “停止 / stop”继续只负责中断当前 Agent 任务并清理 TTS 队列
  - [x] “暂停收音”只停止 `AudioCapturer` / ASR 输入，保持 Hermes Gateway、当前任务和播报连接
  - [x] 暂停收音指令本身作为控制词消费，不进入对话历史、不触发新的 Agent 回复
  - [x] 控制词仅允许“关闭话筒”“关闭麦克风”“关闭microphone”“暂停收音”，其他中英文转写不匹配
  - [x] 提供明确的重新开麦方式，并显示输入关闭、输出仍可用的状态
  - [x] 处理闭麦期间到达的 Agent 结果：仍可播报；不因输入关闭而丢弃
  - [ ] 验收：真实手机上说“暂停收音”后麦克风确实停止，当前思考和播报不中断；说“停止”仍能中断任务

### 4. 审批请求语音播报与快速应答

- [ ] [审批交互] 审批请求同时提供弹窗、语音提示和明确的语音快速应答
  - [x] 收到 `approval.request` 后在对话流显示并自动播报风险操作摘要及“同意 / 取消”提示，不显示独立卡片
  - [x] 支持“同意”“取消”等精确控制词，控制词消费后不进入普通 Agent Prompt
  - [x] 文字、语音应答和 Hermes `approval.respond` 使用同一状态，重复应答安全失败
  - [x] 播报过程中保留麦克风快速应答，审批 pending 下未知词默认安全失败
  - [ ] Web 仅做协议回归；HarmonyOS 完成外放和耳机真机验收
  - [ ] 原计划：`docs/plans/2026-08-11-approval-voice-response.md`
  - [ ] 展现方式修订：`docs/plans/2026-08-11-conversational-prompts-and-provider-identity.md`

## 待决策

- 思考过程的“一行”按服务端换行、语义阶段，还是客户端自然分段；需要避免 token 级碎片化。
- 气口延长的具体阈值、最大等待时间和 Web / HarmonyOS 是否共用同一组参数。
- “暂停收音”识别的精确词表和误触发处理。

## 关联现有文档

- 当前产品与架构：`docs/ARCHITECTURE.md`、`docs/PRODUCT_FORMS.md`
- 当前交互协议：`docs/INTERACTION_AND_PORTING_SPEC.md`
- 语音输入输出边界：`docs/plans/2026-08-10-voice-input-output.md`
- 当前 HarmonyOS 状态与真机阻塞：`docs/status.md`
- 动态 Agent 与语音回复：`docs/plans/2026-08-10-dynamic-agents-and-voice-response.md`
