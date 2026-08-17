# 凭据与生产配置

本仓库不提交真实令牌、Provider Key、签名证书、P12、Profile 或生产 `.env`。`.env.example` 只描述变量名和非敏感默认值。

## 凭据分层

| 凭据 | 使用方 | 禁止暴露给 |
|---|---|---|
| `VOICE_ACCESS_TOKEN` | 用户设备换取 Adapter 会话 Cookie | 仓库、日志、公共页面 |
| `HERMES_DASHBOARD_SESSION_TOKEN` | Adapter 访问 Hermes | HarmonyOS、浏览器、附件元数据 |
| ASR/TTS/模型 Provider Key | Hermes Provider | Adapter 静态资源和所有客户端 |
| HarmonyOS 签名材料 | DevEco/AppGallery 构建发布 | Git 和普通 CI 日志 |

`VOICE_ACCESS_TOKEN` 与 Hermes 内部令牌必须不同。生产环境优先通过 systemd credential、权限为 `0600` 的环境文件或 `HERMES_DASHBOARD_SESSION_TOKEN_FILE` 注入内部令牌。

## 非凭据配置

```dotenv
HERMES_GATEWAY_URL=http://127.0.0.1:9119
HERMES_PROFILE_CATALOG_ENABLED=true
VOICE_ARTIFACT_ALLOW_ALL_READABLE=true
VOICE_ARTIFACT_MAX_BYTES=52428800
VOICE_HOST=127.0.0.1
VOICE_PORT=8844
```

`HERMES_AGENTS_JSON`、`HERMES_DEFAULT_URL`、`HERMES_HEXIAOMA_URL` 和 `HERMES_HEXIAOXIN_URL` 是旧 Hermes 或应急回滚入口，不是当前日常 Profile 注册方式。

## 附件权限

`VOICE_ARTIFACT_ALLOW_ALL_READABLE=true` 表示 Adapter 可以为其 OS 身份可读取的任意普通文件签发短期令牌。它不会绕过 Unix 权限，也不会把路径发送给客户端，但会扩大可投递范围；因此 Adapter 应与 Hermes 使用预期的同权限身份运行，且该身份本身不应拥有无关敏感目录的读取权。

如部署需要目录隔离，设置为 `false` 并配置：

```dotenv
VOICE_ARTIFACT_ROOTS=/srv/hermes/artifacts
```

多个目录使用系统路径分隔符。目录模式会额外拒绝常见 `.env`、凭据、SSH、Git 和 Hermes 私有路径；同权限模式以 OS 权限为明确边界。

## 生产检查

1. systemd 和反向代理配置中没有把真实令牌写入可读日志。
2. Hermes 只监听回环地址，公网只暴露 Adapter 反向代理。
3. Cookie 为 HttpOnly，并由 HTTPS/WSS 传输。
4. `/api/agents` 和模型选项不返回内部 URL、路径、指令或 Provider Key。
5. `/api/artifacts/{token}` 使用随机短期令牌，响应不暴露原始路径。
6. 发布包、截图和诊断日志不包含真实口令或签名材料。

如果凭据曾进入 Git、终端共享记录或客户端日志，应立即轮换；从最新提交删除字符串不等于从 Git 历史删除。
