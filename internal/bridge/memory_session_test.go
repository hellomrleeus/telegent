package bridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRememberCommand(t *testing.T) {
	t.Parallel()

	v, ok := parseRememberCommand("/remember  buy milk")
	if !ok || v != "buy milk" {
		t.Fatalf("unexpected parse result: ok=%v v=%q", ok, v)
	}

	v, ok = parseRememberCommand("记住： 明天开会")
	if !ok || v != "明天开会" {
		t.Fatalf("unexpected chinese parse result: ok=%v v=%q", ok, v)
	}
}

func TestSessionStoreRoundTrip(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "sessions.json")

	chatSessions = map[string]string{}
	if err := loadSessions(path); err != nil {
		t.Fatalf("loadSessions create failed: %v", err)
	}

	cfg := bridgeConfig{SessionStoreFile: path}
	setChatSessionID(cfg, "codex", 42, "sid-42")
	if got := getChatSessionID("codex", 42); got != "sid-42" {
		t.Fatalf("session mismatch: %q", got)
	}

	chatSessions = map[string]string{}
	if err := loadSessions(path); err != nil {
		t.Fatalf("loadSessions reload failed: %v", err)
	}
	if got := getChatSessionID("codex", 42); got != "sid-42" {
		t.Fatalf("session persisted mismatch: %q", got)
	}
}

func TestMemoryAppendAndReset(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	cfg := bridgeConfig{CodexWorkdir: dir, MemoryFile: "MEMORY.md"}

	if err := ensureMemoryFile(cfg); err != nil {
		t.Fatalf("ensureMemoryFile failed: %v", err)
	}
	if err := appendMemoryItem(cfg, "喜欢简洁回复"); err != nil {
		t.Fatalf("appendMemoryItem failed: %v", err)
	}

	mem, err := readMemory(cfg)
	if err != nil {
		t.Fatalf("readMemory failed: %v", err)
	}
	if !strings.Contains(mem, "喜欢简洁回复") {
		t.Fatalf("memory does not contain appended item: %q", mem)
	}

	if err := resetMemory(cfg); err != nil {
		t.Fatalf("resetMemory failed: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "MEMORY.md"))
	if err != nil {
		t.Fatalf("read reset file failed: %v", err)
	}
	if !strings.Contains(string(raw), "## User Memory Items") {
		t.Fatalf("reset template invalid: %q", string(raw))
	}
}
