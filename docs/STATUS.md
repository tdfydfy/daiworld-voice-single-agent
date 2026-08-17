# 当前状态

更新日期：2026-08-17

## 稳定基线

- HarmonyOS：`1.2.16 (1020016)`；
- Adapter：`main`，基线提交 `09f0ed4`；
- 生产服务：`daiworld-voice-single-agent.service`；
- 移动端定位：HarmonyOS 为主要产品，Web Native 为协议预览；
- Agent 目录：Hermes `/api/status.profiles`；
- 附件权限：正式同权限部署允许投递 Hermes/Adapter OS 身份可读的普通文件。

## 已验证

- Python：`53/53`；
- Node：`91/91`；
- HarmonyOS 静态契约检查通过；
- HarmonyOS 真机已验证图片内联发送；
- HarmonyOS 真机已验证 Word 等非图片文件以附件形式发送和打开；
- 客户端不再显示域名替代附件，也不显示 `sandbox:/root/...` 等服务器路径。

测试数量只记录本次稳定点，不作为永久门槛；长期门槛以 [测试矩阵](./NATIVE_TEST_MATRIX.md) 中的测试层和行为为准。

## 当前行为

- Agent 可以通过 `MEDIA:`、`sandbox:`、`file:`、裸绝对路径、Markdown 链接或合格 HTTPS 文件链接返回附件。
- 常见图片、文档、表格、演示文稿、文本和压缩包按后缀识别。
- 图片内联展示，其他文件显示为可打开或下载的文件项。
- Adapter 只向客户端签发短期不透明令牌，不暴露服务器路径。
- `关闭话筒`、`打开话筒`、`停止任务`、`退出软件` 已按统一语义工作。
- `停止任务`确认本地立即停止并发送 `session.interrupt`；不把客户端本地状态当作 Hermes 队列收敛证明。

## 已知边界

- 外放回音消除和双讲效果受具体设备系统实现影响，必须真机判断。
- 本地 CoreSpeech 与远端语音后端不会在故障时自动互相切换。
- 附件令牌默认 15 分钟有效，Adapter 重启后失效；历史恢复会重新签发。
- 同权限附件模式不会绕过 OS 权限，部署身份的文件权限本身就是安全边界。
- 主持人多 Agent、Profile 间共享上下文和任务编排不属于本项目。
