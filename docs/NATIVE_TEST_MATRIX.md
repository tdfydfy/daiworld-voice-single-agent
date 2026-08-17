# Native 测试矩阵

测试分为纯逻辑、Adapter 集成、HarmonyOS 静态契约、构建和真机五层。低层通过不能替代高层证据；安装成功或 Ability 拉起也不能记为功能验收。

## 自动化

在仓库根目录执行：

```bash
python -m pytest -q
node --test tests/*.test.js
node clients/harmony/scripts/verify.mjs
```

这些检查覆盖：

- Adapter 鉴权、Profile 目录、JSON-RPC、历史和附件转换；
- Web Native 语音过滤、播放连续性、恢复和移动布局逻辑；
- HarmonyOS 单 Agent 路由、权限、语音状态和附件渲染静态契约。

完整 HarmonyOS 构建：

```powershell
cd clients/harmony
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

构建依赖 DevEco Studio、匹配的 HarmonyOS SDK、Hvigor、Node 和 JBR。

## Adapter 集成

| 用例 | 期望 |
|---|---|
| 无口令或错误口令 | HTTP/WS 拒绝，内部 Hermes 令牌不泄漏 |
| 首次 Agent 目录 | 从 Hermes profiles 建立缓存，只返回公开字段 |
| `?refresh=1` | 显式刷新目录，不启动后台轮询 |
| 创建/恢复 Session | 运行时 ID 与持久 ID 分离，Profile 不串线 |
| 网关心跳 | 约 25 秒下发，只由客户端连接层消费 |
| 历史详情 | 保留真实时间、模型和可重签附件 |
| 失效附件令牌 | 返回不存在/过期，不泄漏原路径 |

## 附件专项

至少验证下列输入：

| 输入 | 期望 |
|---|---|
| `MEDIA:/.../image.png` | 图片附件，正文不显示路径 |
| `sandbox:/.../report.docx` | 文件附件，正文不显示 sandbox 地址 |
| `file:///.../report.pdf` | 文件附件 |
| 裸绝对路径 `.../sheet.xlsx` | 文件附件 |
| Markdown 包装的本地引用 | 保留可读标签，生成附件 |
| HTTPS `.../slides.pptx` | 令牌端点重定向，不由 Adapter 抓取 |
| 普通网页 URL | 保持链接，不误判附件 |
| HTTP、未知协议或未知后缀 | 保持文字，不放行 |
| 不存在、不可读、目录或超限文件 | 不签发附件 |
| 历史中的同一引用 | 恢复时生成新令牌 |

## HarmonyOS 真机

| 领域 | 必测行为 |
|---|---|
| 登录与目录 | 正确口令在线，错误口令明确失败，Agent 可刷新切换 |
| 文字 | 新对话、繁忙补充、历史恢复、模型切换 |
| 连续语音 | 手动启用、partial/final、长时间监听、暂停恢复 |
| 系统命令 | `关闭话筒`、`打开话筒`、`停止任务`、`退出软件` 精确语义 |
| 审批/澄清 | `同意`、`取消` 和未识别输入均符合协议 |
| 播放 | 自动播报、单条重读、停止、耳机/听筒/扬声器切换 |
| 生命周期 | 前后台、息屏、网络断开恢复、进程退出后无残留重连 |
| 附件 | 图片内联；Word/PDF 等文件显示文件项并可打开或下载 |
| 安全显示 | UI、日志和系统打开器参数不出现 `/root/...` 等原始路径 |

## 证据边界

- 自动化通过：证明代码契约和可模拟路径，不证明设备音频体验。
- HAP 构建通过：证明工程可编译，不证明安装、权限和网络可用。
- 安装并拉起：证明签名和 Ability 可运行，不证明产品流程正确。
- 真机功能验收：需要实际执行操作并记录结果；语音听感和视觉判断由用户确认。

长期允许的 AI 真机冒烟范围见 [永久真机授权](./plans/2026-08-12-permanent-device-smoke-authorization.md)。

## 发布门槛

1. 三组自动化命令通过。
2. DevEco/Hvigor 构建通过。
3. 生产 Adapter 健康、目录、鉴权和心跳正常。
4. 真机完成本次变更相关用例及基础回归。
5. 附件改动必须同时验证一张图片和一个非图片文件。
6. 文档、应用版本和生产服务名与实际部署一致。
