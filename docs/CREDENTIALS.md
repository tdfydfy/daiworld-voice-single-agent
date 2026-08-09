# Native Web 凭据与配置

本项目有两个不同层级的口令：

- `VOICE_ACCESS_TOKEN`：浏览器/客户端访问 Native Adapter 的口令；
- `HERMES_DASHBOARD_SESSION_TOKEN`：Adapter 访问本机 Hermes Profile 服务的内部口令。

二者不要复用。模型供应商 API Key 不由本项目读取，应配置在各 Hermes Profile 自己的凭据系统中。

## 本地开发

复制配置模板：

```bash
cp .env.example .env.native
chmod 600 .env.native
```

然后分别启动三个 Hermes Profile 和 Native Adapter。环境文件只应存在于本机，不要提交到 Git。

## 生产部署

建议：

1. 创建专用非 root 系统用户；
2. 使用受限权限的 EnvironmentFile 或 systemd Credential；
3. Adapter 与三个 Hermes Profile 使用不同的内部口令；
4. 只把 Adapter 绑定到反向代理内网接口；
5. 公网入口使用 HTTPS/WSS，并配置访问失败限速；
6. 定期轮换 `VOICE_ACCESS_TOKEN` 和 `HERMES_DASHBOARD_SESSION_TOKEN`。

当前模板中的服务地址和路径是示例，不代表任何固定服务器布局。部署时应修改：

- `WorkingDirectory`；
- Python/uvicorn路径；
- Hermes CLI路径；
- `HERMES_*_URL`；
- 运行用户和凭据文件权限。

## 不应提交的内容

```text
.env*
credentials*.json
/run/secrets/*
数据库、日志、录音和临时附件
```

`.gitignore`已覆盖常见凭据和运行时文件，但发布前仍必须检查 Git 历史和打包目录。
