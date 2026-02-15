# telegent

[中文文档](./README.zh-CN.md) | English

A local-first Telegram multi-agent bridge for macOS.

`telegent` runs on your Mac, receives Telegram messages, routes them to a CLI agent provider (Codex or generic CLI), and sends results back to Telegram.

## Features

- Multi-agent provider routing (`codex`, `generic`)
- Per-provider session isolation
- Text, image, voice/audio/video handling
- Screenshot capture and inline chat-history rendering
- Persistent memory (`MEMORY.md`) and agent policy (`AGENTS.md`)
- Menu bar macOS app with Control Center UI
- Local storage under `~/Library/Application Support/telegent`

## Architecture

1. Telegram long polling (`getUpdates`)
2. Media pre-processing (speech/image fallback)
3. Agent runner dispatch
4. Response delivery + chat/session logging

## Prerequisites

- macOS 12+
- Go 1.22+
- Python 3.9+
- Telegram bot token from `@BotFather`
- Optional speech transcription dependency:
  - `python3 -m pip install faster-whisper`

## Quick Start (CLI)

```bash
cd /path/to/telegent

export TELEGRAM_BOT_TOKEN="<YOUR_BOT_TOKEN>"
export TELEGRAM_ALLOWED_USER_ID="<YOUR_TELEGRAM_USER_ID>"

# Default provider: codex
export AGENT_PROVIDER="codex"
export AGENT_BIN="/Applications/Codex.app/Contents/Resources/codex"

# Optional
export CODEX_WORKDIR="$(pwd)"
export CODEX_TIMEOUT_SEC="180"
export MAX_REPLY_CHARS="3500"
export CODEX_SANDBOX="workspace-write"

# Optional media/transcription
export WHISPER_PYTHON_BIN="python3"
export FASTER_WHISPER_MODEL="small"
export FASTER_WHISPER_LANGUAGE="zh"
export FASTER_WHISPER_COMPUTE_TYPE="int8"

go run ./cmd/telegent
```

## Build & Run macOS App

```bash
./scripts/build_macos_app.sh
open ./dist/telegent.app
```

Menu bar app capabilities:

- Start / Stop / Restart runtime
- Open runtime log
- Open Control Center

Control Center tabs:

- Config
- Permissions
- Logs
- Chat
- Dependency Check
- Memory & Agent

## Agent Providers

### Codex Provider

Use:

- `AGENT_PROVIDER=codex`
- `AGENT_BIN=/Applications/Codex.app/Contents/Resources/codex`

### Generic CLI Provider

Use:

- `AGENT_PROVIDER=generic`
- `AGENT_BIN=<your-cli-path>`
- `AGENT_ARGS=<fixed args>`
- `AGENT_SUPPORTS_IMAGE=true|false`

Supported placeholders in `AGENT_ARGS`:

- `{{prompt}}`
- `{{session_id}}`
- `{{image_paths}}` (comma-separated)

If `{{prompt}}` is not present, prompt is appended automatically.

## Telegram Commands

- `/ping` health check
- `/cwd` show working directory
- `/session` show current provider session
- `/newsession` or `/reset` reset session for current provider
- `/screenshot` capture local screen and send image
- `/memory` show `MEMORY.md`
- `/remember <text>` append memory item
- `/forget` reset memory items
- `记住<内容>` Chinese shortcut for memory append

## Storage Paths

Runtime files are stored under:

- `~/Library/Application Support/telegent/logs/app-bridge.log`
- `~/Library/Application Support/telegent/chat-history.jsonl`
- `~/Library/Application Support/telegent/codex-sessions.json`
- `~/Library/Application Support/telegent/images`
- `~/Library/Application Support/telegent/tmp`

## Security Notes

- Only `TELEGRAM_ALLOWED_USER_ID` is allowed to interact.
- Keep bot token private.
- Avoid running destructive shell tools in generic provider mode.

## Troubleshooting

1. App opens but no response
- Check runtime log in Control Center -> Logs.
- Verify token/user id and network access.

2. Voice transcription fails
- Ensure Python and `faster-whisper` are installed.

3. Screenshot fails (`could not create image from display`)
- Grant Screen Recording permission in macOS settings.

## Development

```bash
go fmt ./...
go test ./...
```

## Secret Safety

Use local env files and pre-commit scanning to avoid secret leaks:

```bash
cp .env.example .env
./scripts/install_git_hooks.sh
```

Manual scan:

```bash
./scripts/secret_scan.sh --all
```

## License

See [`COPYRIGHT`](./COPYRIGHT).
