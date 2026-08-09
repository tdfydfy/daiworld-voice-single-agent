# 单 Agent v21 验证矩阵

> 目的：区分“有自动化证据”“有真实服务证据”和“尚未验证”，避免把整个仓库测试通过等同于单 Agent 全链路完成。

## 1. 基线

| 项目 | 值 |
|---|---|
| 运行代码基线 | `native-open-source` 清理分支 |
| 文档基线 | `native-open-source` 分支 |
| Python Native专属回归 | 10 passed |
| Node单Agent回归 | 7 passed |
| 公网入口 | 按部署者配置 |
| Adapter服务 | `daiworld-voice-native.service` |

> 当前分支只包含Native单Agent代码；全链路真实服务证据仍需由部署者按环境复测。

## 2. 单 Agent 专属自动化

| 能力 | 测试文件 | 已覆盖 |
|---|---|---|
| MEDIA令牌 | `tests/test_native_artifacts.py` | 路径选择、令牌、MIME、历史重签、禁止未选择路径 |
| 历史详情 | `tests/test_native_history.py` | Session model与消息timestamp聚合 |
| 回音过滤 | `tests/voice_filters.test.js` | 有序短语/二元组、正常补充不误杀、播放暂停判定 |
| MEDIA TTS过滤 | `tests/media_speech_filter.test.js` | 分片MEDIA行过滤、普通文本保留 |

运行：

```bash
python -m pytest tests/test_native_artifacts.py tests/test_native_history.py \
  -q -o 'addopts='

node --test \
  tests/voice_filters.test.js \
  tests/media_speech_filter.test.js
```

## 3. 已有真实服务证据

| 层级 | 证据 | 状态 |
|---|---|---|
| Profile隔离 | default/hexiaoma/hexiaoxin三个 `serve --isolated` 后端 | 已验证 |
| JSON-RPC | `gateway.ready`、create、submit、delta、complete | 已验证 |
| Session连续性 | 真实两轮Session继续 | 已验证 |
| 历史分页 | 浏览器DOM `20 → 40 → 60` | 已验证 |
| 历史恢复 | 原Session继续、模型/时间恢复 | 已验证 |
| 历史删除 | 二次确认、删除后条目消失 | 已验证 |
| 图片/文件 | PNG内联、TXT/PDF类文件下载卡、历史附件重签 | 已验证 |
| 桌面布局 | Chromium 1280px | 已验证 |
| 移动布局 | Chromium 390px | 已验证 |
| 服务发布 | systemd active、公网版本资源可读、无warning | 已验证 |

## 4. 浏览器语音能力证据边界

| 能力 | 当前状态 | 说明 |
|---|---|---|
| Streaming ASR ready/partial/final | 已在真实服务链路实现；需持续保留回归 | Provider和浏览器联合链路 |
| 首句PCM缓冲 | 源码和浏览器探针已验证 | 采集与WS并行启动 |
| Agent流式TTS | 已实现并运行 | Provider end与客户端排空分离 |
| queued补充 | 已验证RPC与UI状态 | `prompt.submit(queued=true)` |
| 播放暂停/恢复 | 浏览器逻辑和Node判定已验证 | 真实不同硬件AEC效果仍需测量 |
| 精确STOP | 已实现 | `停止/stop`整句；仍需保留端到端回归 |
| 审批语音 | 已实现 | 屏幕按钮和固定语音词表；需专项端到端自动化 |

## 5. 尚缺的单 Agent 自动化

按优先级补充：

1. JSON-RPC pending/request ID/Session隔离单测；
2. Streaming ASR WebSocket ready、idle、final、stop集成测试；
3. Streaming TTS队列和设备排空集成测试；
4. 审批卡与语音同意/拒绝端到端测试；
5. `queued=true` 多轮顺序浏览器测试；
6. exact STOP 与非精确“停止”文本矩阵；
7. Profile切换后历史和迟到事件隔离；
8. 移动端软键盘、安全区和抽屉交互回归；
9. token过期后的附件错误UI；
10. 网络断开/重连时不重复提交final。

这些缺项不否定当前v21稳定基线，但在HarmonyOS迁移前应转化为跨端fixture。

## 6. HarmonyOS验证阶梯

单 Agent HarmonyOS 每项必须标注实际完成层级：

```text
L1 源码静态契约
L2 ArkTS类型检查
L3 DevEco/Hvigor构建
L4 模拟器
L5 真机前台
L6 真机后台/锁屏
```

验收矩阵：

| 场景 | L1 | L2 | L3 | L4 | L5 | L6 |
|---|---:|---:|---:|---:|---:|---:|
| JSON-RPC文字两轮 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 不适用 |
| 历史20→40 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 不适用 |
| PCM16k持续ASR | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 |
| PCM24k连续TTS | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 |
| queued补充 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 |
| exact STOP | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 |
| 审批 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 |
| 图片/文件 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 不适用 |
| 网络切换 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 | 待迁移 |
| 蓝牙/来电/音频焦点 | 不适用 | 不适用 | 不适用 | 不充分 | 待迁移 | 待迁移 |

当前服务器没有DevEco Studio、Harmony SDK、OHPM、Hvigor和HDC，因此不得提前填写L2-L6为通过。

## 7. 发布前固定命令

```bash
# 单Agent与全仓回归
python -m pytest -q -o 'addopts='
node --check web_native/app.js
node --test tests/voice_filters.test.js tests/media_speech_filter.test.js

# 语法与差异
node --check web_native/app.js
git diff --check

# 服务
systemctl is-active daiworld-voice-native.service
journalctl -u daiworld-voice-native.service --since '10 minutes ago' -p warning --no-pager
```
