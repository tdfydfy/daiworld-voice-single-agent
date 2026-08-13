# 变更记录

## 2026-08-13

- `1.2.5` 恢复旧版息屏播放路径：目标真机证明 CoreSpeech 不返回可用的本地 TTS PCM，撤销 `1.2.3/1.2.4` 的 `onData` 接管、格式判断和无 PCM 超时报错；本地 TTS 恢复系统 `engine.speak()` 与 `onComplete(type=1)` 短段推进。后台任务恢复 `1.1.2/1.2.1` 已验证的播放优先专用模式，TTS 启动前等待 `AUDIO_PLAYBACK` ready，播完或用户开口后恢复 `AUDIO_RECORDING`。
- `1.2.5` 回归保护：后台状态机新增录音到播放的串行 stop/start、播放结束恢复录音、启动中意图抢占和陈旧 generation 隔离测试；保留 `9800005` 重复停止幂等、系统原生输出设备选择、耳机路由、采集有限恢复及远端 PCM 播放。Node 28 项、Python 27 项、32 个 ETS 静态校验、ArkTS 类型检查和签名构建通过；最终哈希与真机部署结果见后续状态更新。
- `1.2.5` 构建部署：签名 HAP SHA-256 为 `5C8F07369CF7CC0ACB32B7B7AD48EA7FACA4AE7CFE1C91361B2EF6A6DC937A59`，已保留数据覆盖安装到设备 `6HQ0226409028766`；设备端确认 `1.2.5 (1020005)`、录音/播放能力声明和 `EntryAbility` 前台拉起成功。息屏听感待用户操作验收。
- 息屏断音根因修复：真机日志确认 `1.2.3` 整轮本地 TTS 没有收到 `SpeakListener.onData`，声音仍由 CoreSpeech 系统内置播放器输出，并在页面隐藏时因 `TTSStateObserver--OnPageHide` 停止。`1.2.4 (1020004)` 按官方 `SpeakParams` 示例显式请求 `audioType: pcm`，并增加“合成完成但无 PCM”失败门，确保只有应用通信 `AudioRenderer` 真正接管后才推进播报队列。
- `1.2.4` 验证与部署：Node 28 项、Python 27 项、32 个 ETS 静态校验、ArkTS 类型检查和签名构建通过；最终 HAP SHA-256 为 `240D971ECD754A9799EA0881FBF33BFD63D8989F4F17DE7C32ABFC70A7C3E4EA`，已保留数据覆盖安装到设备 `6HQ0226409028766`，设备端确认版本和组合后台声明。设备锁屏阻止自动拉起；应用 PCM 回调和息屏声音仍待用户验收。
- 本地 TTS 格式兼容：修复 CoreSpeech 真机返回 `pcm/16000/16/3` 时被固定单声道校验拒绝的问题；按 Audio Kit `CH_LAYOUT_STEREO=3` 映射为双声道 renderer，同时兼容 `1/4` 单声道与 `2` 双声道，采样率或声道变化时重建匹配的 renderer。版本提升为 `1.2.3 (1020003)`。
- `1.2.3` 验证与部署：Node 28 项、Python 27 项、32 个 ETS 静态校验、ArkTS 类型检查和签名构建通过；最终 HAP SHA-256 为 `61927903D49146D808289860C8C8B98F004E378DEEB54A80A84CC69A77D66992`，已保留数据覆盖安装到设备 `6HQ0226409028766`。设备端确认 `1.2.3 (1020003)` 和组合后台声明，`EntryAbility` 拉起成功；本地 TTS 声音和息屏听感仍待用户验收。
- 息屏播放修复候选：CoreSpeech 本地 TTS 改为只通过 `SpeakListener.onData` 合成 PCM，按连续序号去重后由通信 `PcmPlayer` 播放；`onComplete(type=0)` 只表示合成结束，必须等待系统 `AudioRenderer.drain()` 才推进下一段。renderer 看门狗使用硬件 `framePos` 判断停滞，通信 Session 恢复保留当前 renderer，确需重建时回放最后一个未确认 PCM 缓冲，避免跳过已写入但尚未听到的几个字。
- 后台任务：音频需求消失后将组合租约保留 30 秒，覆盖停止/重播短空隙；停止持续任务遇到 `9800005` 时按任务已失效完成状态收敛，下一次需求重新申请，不再把校验错误显示成气泡播放失败。
- 输出路由：输出按钮移除耳机和会话加载禁用条件，任何时候都优先打开 HarmonyOS `voice_call` 原生设备面板；耳机等附件仍由系统默认优先，用户可随时手动选择当前可用设备。系统面板失败才回退 `setCommunicationDevice(SPEAKER, true/false)`，不叠加 `setDefaultOutputDevice`。
- 验证与部署：Node 28 项、Python 27 项、32 个 ETS 静态校验、ArkTS 类型检查和签名构建通过；最终候选 HAP SHA-256 为 `54D057849149441E1A9F16AD0BEE2F152E01EA1024A59026CD447AF4FABAC107`，已保留数据覆盖安装到设备 `6HQ0226409028766`，设备端确认 `1.2.2 (1020002)` 和组合后台声明。设备锁屏阻止自动拉起；息屏听感和原生设备面板仍待用户复验。
- 音频底座：HarmonyOS 将录音和播放后台模式合并为一个可等待 ready 的持续租约；录音需求、播放需求独立变化时不再相互 stop/start，远端/本地采集及首段系统 TTS 都经过同一连续性门。
- 采集恢复：新增 Capturer 状态/中断/PCM 心跳观测和 `CaptureSupervisor`，以 2 秒无 PCM 看门、`100 / 500 / 1500 ms` 三次有界重建、单任务串行和 generation 隔离服务远端与本地 ASR；恢复中保留识别状态和已确认转写，耗尽后显式停止输入并报错。
- 验证：Node 27 项、Python 27 项、32 个 ETS 静态校验、ArkTS 类型检查和签名构建通过；签名 HAP SHA-256 为 `0E8C650EFE363AE7E645EC51FDBD9B68236A7F813F97378052D554FC6D30CEE1`。构建完成时首次 HDC 检查无连接设备，后续部署结果见下一条；组合后台与息屏音频仍待真机验收。
- 部署：设备 `6HQ0226409028766` 接入后，以上 `1.2.1 (1020001)` 签名 HAP 已保留数据覆盖安装；设备包信息确认录音/播放组合后台声明，`EntryAbility` 拉起成功且应用进程存在。连续 PCM、息屏恢复和播报听感仍由用户操作验收。

## 2026-08-12

- UI：HarmonyOS 设置页按“连接 / Agent 运行配置 / 语音引擎 / 应用”分组并增加面板边界；远端地址与口令、Provider 与模型、音色与语速改为成组双列布局。保留原有保存、模型切换和语音控件行为；静态校验、ArkTS 类型检查、签名 HAP 构建与 Node 回归通过。最新 HAP SHA-256 为 `6A2ADE800AECDD081A2486085F724F4D0D0F7BD04B439693C7E54310A3285F88`，真机视觉验收待后续完成。
- 部署：设备 `6HQ0226409028766` 已连接；`1.2.1 (1020001)` 签名 HAP 保留数据覆盖安装成功，`EntryAbility` 拉起成功，应用进程处于前台。仅完成客观包/进程冒烟，设置页面视觉和交互仍由用户验收。
- 验收：用户确认设置页分组和双列布局通过；设置布局项完成，后续优先进行连续 ASR、音频路由与审批/Agent 交互的真机验收。
- 修复：连续 ASR 普通本地/远端转写的收句窗口从 1.1 秒延长到 1.8 秒；每个有效 interim/final 到达都会重新计时，连续分段继续合并为同一条用户消息，停止、暂停收音、审批和澄清回复不受延迟影响。签名 HAP SHA-256 为 `3743D0DF1DF2ED857FF8CEF4458BCD25D97266F14E82D482E90C4B3C0D54F728`，已保留数据覆盖安装，待用户真机验证自然停顿和真正结束的体感。
- 修复：思考呼吸音改由 `VoiceOutputCoordinator` 的显式 Agent-turn 生命周期驱动；提交/`message.start` 开始，正文播报、正常完成、错误、中断、审批/澄清和会话变化结束，避免仅依赖 `agentBusy` 快照与通知时机导致偶发缺失或残留。新增提示音状态变化日志；签名 HAP SHA-256 为 `FE4A294F0DEDEB1FB5FB84A3EA2CC56EE6E8D824DC1E2E8F8CE08DE067038BB6`，待真机听感验收。
- 验收：用户确认 Session 创建、恢复、重连和 Agent/模型切换后的 Provider/模型身份同步通过；模型目录由 Hermes Provider 配置提供，客户端不写死列表。
- 配置：确认 Hermes `providers.<provider>.models` 可作为 Provider 的手工模型目录；已为备用 Provider 补充模型并在 HarmonyOS 真机验证可选择和切换。`default_model` 仅表示默认模型，`model.aliases` / `model_aliases` 仅用于快捷别名；客户端无需改动或写死模型列表。
- 修复：切换 Agent 或 Agent Catalog 回退时同步清除 `RuntimeIdentitySync` 缓存的旧模型目录和未确认运行身份，防止新 Session 暂时返回通用 `custom` Provider 时误显示上一 Agent 的具体 Provider；Session 创建、历史恢复、Gateway 重连和模型切换继续共用同一身份同步入口。
- 发布：HarmonyOS `1.2.1 (1020001)` 统一新消息自动播报与历史消息重读的系统 TTS 分段入口，不按消息来源或屏幕状态维护两套算法；首段 20–48 字，后续优先 40–80 字且硬上限 96 字，最终余段同样受限。签名 HAP SHA-256 为 `4799478EA34BB22B454F78A9D0686A5699A1A7DEF566AD2AE3F8B0CEF1CB764B`；用户真机确认新消息与历史重读在播放中途息屏均连续无异常，核心语音衔接通过验收。
- 修复：历史会话恢复在停止旧会话音频后会恢复原有麦克风与语音输出意图，历史 Agent 消息不再因输出总开关被永久关闭而禁用重读；签名 HAP SHA-256 为 `E951C2E41672CDBAED7439E392141214686EF145FD542A2A9619831AF1BDB288`，已覆盖安装，待用户验收历史重读。
- 架构：第二轮有限拆分将历史恢复解析归入 `ConversationState`，将模型目录/切换和 Gateway 鉴权、Agent 目录、超时及重连状态归入 `HermesRuntime`；`SingleAgentController` 进一步降至 1339 行，继续保留 UI 命令入口与跨域事件协调。
- 修复：消息按钮系统重读现在直接启动第一段 TTS，仅将剩余分段排队，解除所有分段都排队却没有活动任务的无声死锁；最新签名 HAP SHA-256 为 `D5F88A0DFCAB0C5C463AA254FA1C316F0117E34948CE5EBAB6543F3FD4B5EF18`，待真机听感验收。
- 阶段构建：HarmonyOS `1.2.0 (1020000)` 第一轮拆分曾产出 SHA-256 `E7DB1AB4BEDFB96225212DB9EA1AB6D43E7AB84711E99C4A73DEB04A99E4BDFC` 的签名 HAP，已由本日顶部的第二轮拆分产物取代。
- 架构：第一轮按薄客户端原则形成设置/鉴权、Hermes 运行、语音输入、语音输出、对话状态五个责任域，并将音频平台类物理拆开；`SingleAgentController` 从约 3636 行降至约 1920 行，不引入事件总线或多余业务分层。
- 修复：系统 TTS `queued/playing` 期间以 `AUDIO_PLAYBACK` 作为后台任务意图，播完或用户开口暂停后恢复 `AUDIO_RECORDING`，持续麦克风采集保持不变。
- 修复：消息重读按钮不再因持续 ASR 的瞬时活动状态被禁用；保留任务忙碌、pending、静音和输出关闭约束，并增加重读及后台任务切换日志。
- 发布：HarmonyOS 提升为 `1.1.2 (1010002)`，完成签名构建、保留数据覆盖安装、启动和包内版本核验；最终 HAP SHA-256 为 `FCCE719CBFD3378925A97A95EC0A30D90C44A9F11A871751ACF5AC01A9D8AFD6`。
- 修复：目标真机 HUKS AES-GCM 无法稳定回读后，按用户决定改用应用私有 Preferences 保存访问口令，并执行同步读回验证；旧 HUKS 记录自动清理。真机强制停止重开已读取到持久化口令。
- 架构：抽出 `GatewayTokenStore`、`SystemSpeechQueue`、`BackgroundAudioTaskOwner` 和 `RuntimeIdentitySync`，将超大控制器从约 3929 行降至约 3636 行；系统语音仍为主路径，远端语音为手动辅助。
- 声音：系统 TTS 分段队列、循环呼吸音让位、陈旧异步启动隔离和后台录音/播放任务所有权已收敛；用户随后确认息屏长文不再中断或漏字，消息重读由本日顶部修复继续处理。
- 身份：Session 创建、恢复和 `session.info` 主动同步运行 Provider/模型，设置页只展示共享状态；真实显示结果仍需用户确认。
- 验证：Python 27 项、Node 19 项、Harmony 21 个 ETS 文件静态校验、ArkTS 类型检查、签名打包、`git diff --check`、公网 `200/401` 及真机包/进程/Ability 检查通过。

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
