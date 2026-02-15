package bridge

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func loadConfig() (bridgeConfig, error) {
	cfg := bridgeConfig{}
	cfg.BotToken = strings.TrimSpace(os.Getenv("TELEGRAM_BOT_TOKEN"))
	if cfg.BotToken == "" {
		return cfg, errors.New("TELEGRAM_BOT_TOKEN is required")
	}

	allowed := strings.TrimSpace(os.Getenv("TELEGRAM_ALLOWED_USER_ID"))
	if allowed == "" {
		return cfg, errors.New("TELEGRAM_ALLOWED_USER_ID is required")
	}
	uid, err := strconv.ParseInt(allowed, 10, 64)
	if err != nil {
		return cfg, fmt.Errorf("invalid TELEGRAM_ALLOWED_USER_ID: %w", err)
	}
	cfg.AllowedUserID = uid

	parentPID := strings.TrimSpace(os.Getenv("BRIDGE_PARENT_PID"))
	if parentPID != "" {
		pid, err := strconv.Atoi(parentPID)
		if err != nil || pid <= 1 {
			return cfg, errors.New("BRIDGE_PARENT_PID must be a positive integer")
		}
		cfg.ParentPID = pid
	}

	cfg.CodexBin = strings.TrimSpace(os.Getenv("CODEX_BIN"))
	if cfg.CodexBin == "" {
		cfg.CodexBin = "codex"
	}
	cfg.AgentProvider = strings.ToLower(strings.TrimSpace(os.Getenv("AGENT_PROVIDER")))
	if cfg.AgentProvider == "" {
		cfg.AgentProvider = "codex"
	}
	cfg.AgentBin = strings.TrimSpace(os.Getenv("AGENT_BIN"))
	if cfg.AgentBin == "" {
		cfg.AgentBin = cfg.CodexBin
	}
	cfg.AgentArgs = strings.TrimSpace(os.Getenv("AGENT_ARGS"))
	cfg.AgentModel = strings.TrimSpace(os.Getenv("AGENT_MODEL"))
	supportsImg := strings.ToLower(strings.TrimSpace(os.Getenv("AGENT_SUPPORTS_IMAGE")))
	switch supportsImg {
	case "1", "true", "yes", "on":
		cfg.AgentSupportsImage = true
	case "0", "false", "no", "off":
		cfg.AgentSupportsImage = false
	default:
		cfg.AgentSupportsImage = (cfg.AgentProvider == "codex")
	}

	cfg.CodexWorkdir = strings.TrimSpace(os.Getenv("CODEX_WORKDIR"))
	if cfg.CodexWorkdir == "" {
		wd, err := os.Getwd()
		if err != nil {
			return cfg, fmt.Errorf("failed to get current directory: %w", err)
		}
		cfg.CodexWorkdir = wd
	}

	cfg.CodexModel = strings.TrimSpace(os.Getenv("CODEX_MODEL"))
	if cfg.CodexModel == "" {
		cfg.CodexModel = cfg.AgentModel
	}
	cfg.TmpDir = strings.TrimSpace(os.Getenv("TMPDIR"))
	if cfg.TmpDir == "" {
		cfg.TmpDir = filepath.Join(cfg.CodexWorkdir, "tmp")
	}
	if err := os.MkdirAll(cfg.TmpDir, 0o755); err != nil {
		return cfg, fmt.Errorf("failed to create TMPDIR: %w", err)
	}
	cfg.ImageDir = strings.TrimSpace(os.Getenv("IMAGE_DIR"))
	if cfg.ImageDir == "" {
		cfg.ImageDir = filepath.Join(cfg.TmpDir, "images")
	}
	if err := os.MkdirAll(cfg.ImageDir, 0o755); err != nil {
		return cfg, fmt.Errorf("failed to create IMAGE_DIR: %w", err)
	}
	cfg.CodexSandbox = strings.TrimSpace(os.Getenv("CODEX_SANDBOX"))
	if cfg.CodexSandbox == "" {
		cfg.CodexSandbox = "workspace-write"
	}
	cfg.WhisperPythonBin = strings.TrimSpace(os.Getenv("WHISPER_PYTHON_BIN"))
	if cfg.WhisperPythonBin == "" {
		cfg.WhisperPythonBin = "python3"
	}
	cfg.WhisperScript = strings.TrimSpace(os.Getenv("WHISPER_SCRIPT"))
	if cfg.WhisperScript == "" {
		if exe, err := os.Executable(); err == nil {
			bundled := filepath.Join(filepath.Dir(exe), "transcribe_faster_whisper.py")
			if info, statErr := os.Stat(bundled); statErr == nil && !info.IsDir() {
				cfg.WhisperScript = bundled
			}
		}
	}
	if cfg.WhisperScript == "" {
		cfg.WhisperScript = filepath.Join(cfg.CodexWorkdir, "scripts", "transcribe_faster_whisper.py")
	}
	cfg.WhisperModel = strings.TrimSpace(os.Getenv("FASTER_WHISPER_MODEL"))
	if cfg.WhisperModel == "" {
		cfg.WhisperModel = "small"
	}
	cfg.WhisperLanguage = strings.TrimSpace(os.Getenv("FASTER_WHISPER_LANGUAGE"))
	if cfg.WhisperLanguage == "" {
		cfg.WhisperLanguage = "zh"
	}
	cfg.WhisperCompute = strings.TrimSpace(os.Getenv("FASTER_WHISPER_COMPUTE_TYPE"))
	if cfg.WhisperCompute == "" {
		cfg.WhisperCompute = "int8"
	}
	cfg.MemoryFile = strings.TrimSpace(os.Getenv("MEMORY_FILE"))
	if cfg.MemoryFile == "" {
		cfg.MemoryFile = "MEMORY.md"
	}

	cfg.TimeoutSec = 120
	if timeoutStr := strings.TrimSpace(os.Getenv("CODEX_TIMEOUT_SEC")); timeoutStr != "" {
		t, err := strconv.Atoi(timeoutStr)
		if err != nil || t <= 0 {
			return cfg, errors.New("CODEX_TIMEOUT_SEC must be a positive integer")
		}
		cfg.TimeoutSec = t
	}

	cfg.MaxReplyChars = 3500
	if maxStr := strings.TrimSpace(os.Getenv("MAX_REPLY_CHARS")); maxStr != "" {
		m, err := strconv.Atoi(maxStr)
		if err != nil || m < 500 {
			return cfg, errors.New("MAX_REPLY_CHARS must be an integer >= 500")
		}
		cfg.MaxReplyChars = m
	}

	cfg.ChatLogFile = strings.TrimSpace(os.Getenv("CHAT_LOG_FILE"))
	if cfg.ChatLogFile == "" {
		cfg.ChatLogFile = "tmp/chat-history.jsonl"
	}
	if err := os.MkdirAll(filepath.Dir(cfg.ChatLogFile), 0o755); err != nil {
		return cfg, fmt.Errorf("failed to create chat log dir: %w", err)
	}
	f, err := os.OpenFile(cfg.ChatLogFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return cfg, fmt.Errorf("failed to initialize chat log file: %w", err)
	}
	_ = f.Close()

	cfg.SessionStoreFile = strings.TrimSpace(os.Getenv("SESSION_STORE_FILE"))
	if cfg.SessionStoreFile == "" {
		cfg.SessionStoreFile = "tmp/codex-sessions.json"
	}
	if err := os.MkdirAll(filepath.Dir(cfg.SessionStoreFile), 0o755); err != nil {
		return cfg, fmt.Errorf("failed to create session store dir: %w", err)
	}
	if err := loadSessions(cfg.SessionStoreFile); err != nil {
		return cfg, fmt.Errorf("failed to load session store: %w", err)
	}
	if err := ensureMemoryFile(cfg); err != nil {
		return cfg, fmt.Errorf("failed to initialize memory file: %w", err)
	}

	return cfg, nil
}
