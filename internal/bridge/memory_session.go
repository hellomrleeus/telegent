package bridge

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

var (
	sessionMu      sync.Mutex
	chatSessions   = map[string]string{}
	sessionIDRegex = regexp.MustCompile(`session id:\s*([0-9a-fA-F-]{36})`)
)

func parseRememberCommand(text string) (string, bool) {
	if strings.HasPrefix(text, "/remember") {
		rest := strings.TrimSpace(strings.TrimPrefix(text, "/remember"))
		if rest != "" {
			return rest, true
		}
		return "", false
	}

	if strings.HasPrefix(text, "记住") {
		rest := strings.TrimSpace(strings.TrimPrefix(text, "记住"))
		rest = strings.TrimLeft(rest, "：:，, ")
		if rest != "" {
			return rest, true
		}
	}

	return "", false
}

func isScreenshotRequest(text string) bool {
	t := strings.ToLower(strings.TrimSpace(text))
	if t == "" {
		return false
	}
	if t == "/screenshot" || t == "截图" {
		return true
	}
	if strings.Contains(t, "screenshot") {
		return true
	}
	if strings.Contains(text, "截图") || strings.Contains(text, "截个图") || strings.Contains(text, "截屏") {
		return true
	}
	return false
}

func buildPromptWithMemory(cfg bridgeConfig, userPrompt string, inject bool) string {
	if !inject {
		return userPrompt
	}

	parts := make([]string, 0, 2)
	if agentText := readAgentInstructions(cfg); agentText != "" {
		parts = append(parts, "Agent instructions:\n"+agentText)
	}
	if memoryText := readMemoryForPrompt(cfg); memoryText != "" {
		parts = append(parts, "Persistent memory:\n"+memoryText)
	}
	if len(parts) == 0 {
		return userPrompt
	}

	return "Use the following context as background constraints/preferences.\n" +
		"Prioritize the user's latest explicit request.\n\n" +
		strings.Join(parts, "\n\n") +
		"\n\nUser request:\n" +
		userPrompt
}

func readMemoryForPrompt(cfg bridgeConfig) string {
	raw, err := os.ReadFile(resolveMemoryPath(cfg))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func readAgentInstructions(cfg bridgeConfig) string {
	candidates := []string{
		filepath.Join(filepath.Dir(resolveMemoryPath(cfg)), "AGENTS.md"),
		filepath.Join(cfg.CodexWorkdir, "AGENTS.md"),
		filepath.Join(cfg.CodexWorkdir, "AGENT.md"),
	}
	for _, p := range candidates {
		raw, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		text := strings.TrimSpace(string(raw))
		if text != "" {
			return text
		}
	}
	return ""
}

func parseSessionID(output string) string {
	m := sessionIDRegex.FindStringSubmatch(output)
	if len(m) == 2 {
		return strings.TrimSpace(m[1])
	}
	return ""
}

func sessionKey(provider string, chatID int64) string {
	p := strings.ToLower(strings.TrimSpace(provider))
	if p == "" {
		p = "codex"
	}
	return p + ":" + strconv.FormatInt(chatID, 10)
}

func getChatSessionID(provider string, chatID int64) string {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	return chatSessions[sessionKey(provider, chatID)]
}

func setChatSessionID(cfg bridgeConfig, provider string, chatID int64, sid string) {
	sessionMu.Lock()
	chatSessions[sessionKey(provider, chatID)] = sid
	err := saveSessionsLocked(cfg.SessionStoreFile)
	sessionMu.Unlock()
	if err != nil {
		log.Printf("failed to save session store: %v", err)
	}
}

func clearChatSessionID(cfg bridgeConfig, provider string, chatID int64) {
	sessionMu.Lock()
	delete(chatSessions, sessionKey(provider, chatID))
	err := saveSessionsLocked(cfg.SessionStoreFile)
	sessionMu.Unlock()
	if err != nil {
		log.Printf("failed to save session store: %v", err)
	}
}

func loadSessions(path string) error {
	sessionMu.Lock()
	defer sessionMu.Unlock()

	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			chatSessions = map[string]string{}
			return saveSessionsLocked(path)
		}
		return err
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		chatSessions = map[string]string{}
		return nil
	}

	var parsed map[string]string
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return err
	}
	if parsed == nil {
		parsed = map[string]string{}
	}
	chatSessions = parsed
	return nil
}

func saveSessionsLocked(path string) error {
	data, err := json.MarshalIndent(chatSessions, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func resolveMemoryPath(cfg bridgeConfig) string {
	if filepath.IsAbs(cfg.MemoryFile) {
		return cfg.MemoryFile
	}
	return filepath.Join(cfg.CodexWorkdir, cfg.MemoryFile)
}

func ensureMemoryFile(cfg bridgeConfig) error {
	memoryPath := resolveMemoryPath(cfg)
	legacyPath := filepath.Join(cfg.CodexWorkdir, "memory.md")

	if _, err := os.Stat(memoryPath); err == nil {
		return nil
	}
	if _, err := os.Stat(legacyPath); err == nil && memoryPath != legacyPath {
		if err := os.Rename(legacyPath, memoryPath); err == nil {
			return nil
		}
	}
	return os.WriteFile(memoryPath, []byte(defaultMemoryTemplate()), 0o644)
}

func defaultMemoryTemplate() string {
	return "# MEMORY\n\n" +
		"## Profile\n" +
		"- name: 老板\n" +
		"- language: Chinese\n\n" +
		"## Interaction Preferences\n" +
		"- Prefer concise, actionable answers.\n" +
		"- For ops/tasks, return what changed and next step.\n\n" +
		"## User Memory Items\n" +
		"- (use `记住...` or `/remember ...` to append)\n"
}

func readMemory(cfg bridgeConfig) (string, error) {
	raw, err := os.ReadFile(resolveMemoryPath(cfg))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(raw)), nil
}

func appendMemoryItem(cfg bridgeConfig, item string) error {
	item = strings.TrimSpace(item)
	if item == "" {
		return errors.New("empty memory item")
	}
	path := resolveMemoryPath(cfg)
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	text := strings.TrimRight(string(content), "\n")
	if !strings.Contains(text, "## User Memory Items") {
		text += "\n\n## User Memory Items"
	}
	text += "\n- " + item + "\n"
	return os.WriteFile(path, []byte(text), 0o644)
}

func resetMemory(cfg bridgeConfig) error {
	return os.WriteFile(resolveMemoryPath(cfg), []byte(defaultMemoryTemplate()), 0o644)
}
