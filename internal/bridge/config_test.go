package bridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setupBaseConfigEnv(t *testing.T) string {
	t.Helper()
	base := t.TempDir()
	t.Setenv("TELEGRAM_BOT_TOKEN", "token-123")
	t.Setenv("TELEGRAM_ALLOWED_USER_ID", "10001")
	t.Setenv("CODEX_WORKDIR", base)
	t.Setenv("TMPDIR", filepath.Join(base, "tmp"))
	t.Setenv("IMAGE_DIR", filepath.Join(base, "images"))
	t.Setenv("CHAT_LOG_FILE", filepath.Join(base, "logs", "chat.jsonl"))
	t.Setenv("SESSION_STORE_FILE", filepath.Join(base, "state", "sessions.json"))
	t.Setenv("MEMORY_FILE", filepath.Join(base, "state", "MEMORY.md"))
	return base
}

func TestLoadConfigDefaults(t *testing.T) {
	base := setupBaseConfigEnv(t)

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error: %v", err)
	}

	if cfg.AgentProvider != "codex" {
		t.Fatalf("AgentProvider=%q", cfg.AgentProvider)
	}
	if cfg.AgentSupportsImage != true {
		t.Fatalf("AgentSupportsImage=%v", cfg.AgentSupportsImage)
	}
	if cfg.CodexSandbox != "workspace-write" {
		t.Fatalf("CodexSandbox=%q", cfg.CodexSandbox)
	}
	if cfg.TimeoutSec != 120 {
		t.Fatalf("TimeoutSec=%d", cfg.TimeoutSec)
	}
	if cfg.MaxReplyChars != 3500 {
		t.Fatalf("MaxReplyChars=%d", cfg.MaxReplyChars)
	}
	if !strings.HasPrefix(cfg.WhisperScript, base) {
		t.Fatalf("WhisperScript=%q, base=%q", cfg.WhisperScript, base)
	}
	if _, err := os.Stat(cfg.ChatLogFile); err != nil {
		t.Fatalf("chat log not initialized: %v", err)
	}
	if _, err := os.Stat(cfg.SessionStoreFile); err != nil {
		t.Fatalf("session store not initialized: %v", err)
	}
	if _, err := os.Stat(cfg.MemoryFile); err != nil {
		t.Fatalf("memory file not initialized: %v", err)
	}
}

func TestLoadConfigAgentSupportsImageFallback(t *testing.T) {
	setupBaseConfigEnv(t)
	t.Setenv("AGENT_PROVIDER", "generic")
	t.Setenv("AGENT_SUPPORTS_IMAGE", "")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error: %v", err)
	}
	if cfg.AgentSupportsImage {
		t.Fatalf("expected AgentSupportsImage=false for generic fallback")
	}

	t.Setenv("AGENT_SUPPORTS_IMAGE", "true")
	cfg, err = loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error: %v", err)
	}
	if !cfg.AgentSupportsImage {
		t.Fatalf("expected AgentSupportsImage=true when explicitly set")
	}
}

func TestLoadConfigInvalidNumericValues(t *testing.T) {
	setupBaseConfigEnv(t)

	t.Setenv("CODEX_TIMEOUT_SEC", "0")
	if _, err := loadConfig(); err == nil || !strings.Contains(err.Error(), "CODEX_TIMEOUT_SEC") {
		t.Fatalf("expected CODEX_TIMEOUT_SEC validation error, got: %v", err)
	}

	t.Setenv("CODEX_TIMEOUT_SEC", "120")
	t.Setenv("MAX_REPLY_CHARS", "499")
	if _, err := loadConfig(); err == nil || !strings.Contains(err.Error(), "MAX_REPLY_CHARS") {
		t.Fatalf("expected MAX_REPLY_CHARS validation error, got: %v", err)
	}
}
