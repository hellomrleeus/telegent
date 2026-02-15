# telegent

中文 | [English](./README.md)

一个运行在 macOS 本机的 Telegram 多 Agent 桥接器。

`telegent` 在你的 Mac 上接收 Telegram 消息，按配置路由到对应命令行 Agent（如 Codex 或通用 CLI），再把结果回传到 Telegram。

## 功能特性

- 多 Agent 提供方路由（`codex`、`generic`）
- 按提供方隔离会话上下文
- 支持文本、图片、语音/音频/视频
- 支持截图并在对话记录中展示
- 持久记忆（`MEMORY.md`）与 Agent 规则（`AGENTS.md`）
- macOS 状态栏 App + 控制中心 GUI
- 本地数据目录：`~/Library/Application Support/telegent`

## 架构流程

1. Telegram 长轮询（`getUpdates`）
2. 媒体预处理（语音转写 / 图片回退）
3. Agent Runner 分发执行
4. 结果回传 + 日志/会话落盘

## 运行前准备

- macOS 12+
- Go 1.22+
- Python 3.9+
- `@BotFather` 创建的 Bot Token
- 可选语音转写依赖：
  - `python3 -m pip install faster-whisper`

## 快速开始（CLI）

```bash
cd /path/to/telegent

export TELEGRAM_BOT_TOKEN="<你的 BOT TOKEN>"
export TELEGRAM_ALLOWED_USER_ID="<你的 TELEGRAM 用户 ID>"

# 默认 provider: codex
export AGENT_PROVIDER="codex"
export AGENT_BIN="/Applications/Codex.app/Contents/Resources/codex"

# 可选项
export CODEX_WORKDIR="$(pwd)"
export CODEX_TIMEOUT_SEC="180"
export MAX_REPLY_CHARS="3500"
export CODEX_SANDBOX="workspace-write"

# 可选语音转写
export WHISPER_PYTHON_BIN="python3"
export FASTER_WHISPER_MODEL="small"
export FASTER_WHISPER_LANGUAGE="zh"
export FASTER_WHISPER_COMPUTE_TYPE="int8"

go run ./cmd/telegent
```

## 构建并运行 macOS App

```bash
./scripts/build_macos_app.sh
open ./dist/telegent.app
```

状态栏菜单支持：

- 启动 / 停止 / 重启
- 打开运行日志
- 打开控制中心

控制中心包含：

- 配置
- 授权
- 日志
- 对话
- 依赖检查
- 记忆 & Agent

## Agent 提供方配置

### Codex 提供方

建议配置：

- `AGENT_PROVIDER=codex`
- `AGENT_BIN=/Applications/Codex.app/Contents/Resources/codex`

### 通用 CLI 提供方

建议配置：

- `AGENT_PROVIDER=generic`
- `AGENT_BIN=<你的 CLI 路径>`
- `AGENT_ARGS=<固定参数>`
- `AGENT_SUPPORTS_IMAGE=true|false`

`AGENT_ARGS` 支持占位符：

- `{{prompt}}`
- `{{session_id}}`
- `{{image_paths}}`（逗号分隔）

如果未使用 `{{prompt}}`，系统会自动把 prompt 追加到参数末尾。

## Telegram 命令

- `/ping` 健康检查
- `/cwd` 查看工作目录
- `/session` 查看当前 provider 的会话
- `/newsession` 或 `/reset` 重置当前 provider 会话
- `/screenshot` 本机截图并回传图片
- `/memory` 查看 `MEMORY.md`
- `/remember <text>` 追加记忆项
- `/forget` 重置记忆项
- `记住<内容>` 中文快捷写法

## 本地存储路径

默认落盘目录：

- `~/Library/Application Support/telegent/logs/app-bridge.log`
- `~/Library/Application Support/telegent/chat-history.jsonl`
- `~/Library/Application Support/telegent/codex-sessions.json`
- `~/Library/Application Support/telegent/images`
- `~/Library/Application Support/telegent/tmp`

## 安全建议

- 仅允许 `TELEGRAM_ALLOWED_USER_ID` 访问。
- 妥善保管 Bot Token。
- `generic` 模式执行外部 CLI 时，避免危险命令。

## 常见问题

1. App 打开但无回复
- 在控制中心 -> 日志查看运行日志。
- 检查 token/user id 与网络。

2. 语音转写失败
- 检查 Python 与 `faster-whisper` 是否安装。

3. 截图失败（`could not create image from display`）
- 在 macOS 设置中授予屏幕录制权限。

## 开发

```bash
go fmt ./...
go test ./...
```

## 密钥安全

建议使用本地环境变量文件并启用 pre-commit 扫描，避免密钥泄露：

```bash
cp .env.example .env
./scripts/install_git_hooks.sh
```

手动全仓扫描：

```bash
./scripts/secret_scan.sh --all
```

## 许可证

见 [`COPYRIGHT`](./COPYRIGHT)。
