package bridge

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type agentRunResult struct {
	Output    string
	SessionID string
}

type agentRunner interface {
	Name() string
	SupportsImages() bool
	Run(cfg bridgeConfig, chatID int64, prompt string, imagePaths []string) (agentRunResult, error)
}

func runAgent(cfg bridgeConfig, chatID int64, prompt string, imagePaths []string) (string, string, error) {
	runner := selectRunner(cfg)
	existingSessionID := strings.TrimSpace(getChatSessionID(runner.Name(), chatID))
	finalPrompt := buildPromptWithMemory(cfg, prompt, existingSessionID == "")
	processedPrompt, processedImages, err := preprocessForRunner(cfg, runner, finalPrompt, imagePaths)
	if err != nil {
		log.Printf("[agent] preprocess failed provider=%s chat_id=%d err=%v", runner.Name(), chatID, err)
		return "", "", err
	}

	log.Printf("[agent] request provider=%s chat_id=%d images=%d session=%q inject_context=%t", runner.Name(), chatID, len(processedImages), existingSessionID, existingSessionID == "")
	if len(processedImages) > 0 {
		log.Printf("[agent] image_paths provider=%s chat_id=%d paths=%q", runner.Name(), chatID, processedImages)
	}
	log.Printf("[agent] prompt begin provider=%s chat_id=%d\n%s\n[agent] prompt end provider=%s chat_id=%d", runner.Name(), chatID, processedPrompt, runner.Name(), chatID)
	res, err := runner.Run(cfg, chatID, processedPrompt, processedImages)
	if err != nil {
		log.Printf("[agent] response error provider=%s chat_id=%d err=%v", runner.Name(), chatID, err)
		return "", "", err
	}

	log.Printf("[agent] response provider=%s chat_id=%d session=%q output begin\n%s\n[agent] response provider=%s chat_id=%d output end", runner.Name(), chatID, strings.TrimSpace(res.SessionID), strings.TrimSpace(res.Output), runner.Name(), chatID)
	if strings.TrimSpace(res.SessionID) != "" {
		setChatSessionID(cfg, runner.Name(), chatID, strings.TrimSpace(res.SessionID))
	}
	return strings.TrimSpace(res.Output), strings.TrimSpace(res.SessionID), nil
}

func runCodexWithImages(cfg bridgeConfig, chatID int64, prompt string, imagePaths []string) (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.TimeoutSec)*time.Second)
	defer cancel()
	finalPrompt := prompt

	existingSessionID := getChatSessionID("codex", chatID)
	useOutputLastMessage := existingSessionID == ""

	lastMsgPath := ""
	if useOutputLastMessage {
		lastMsgFile, err := os.CreateTemp(os.TempDir(), "codex-last-message-*.txt")
		if err != nil {
			return "", "", fmt.Errorf("failed to create temp file for codex output: %w", err)
		}
		lastMsgPath = lastMsgFile.Name()
		_ = lastMsgFile.Close()
		defer os.Remove(lastMsgPath)
	}

	args := []string{"exec"}
	if cfg.CodexSandbox != "" {
		args = append(args, "--sandbox", cfg.CodexSandbox)
	}
	if cfg.CodexModel != "" {
		args = append(args, "--model", cfg.CodexModel)
	}
	if useOutputLastMessage {
		for _, p := range imagePaths {
			if strings.TrimSpace(p) != "" {
				args = append(args, "--image", p)
			}
		}
		args = append(args, "--skip-git-repo-check", "--output-last-message", lastMsgPath, finalPrompt)
	} else {
		args = append(args, "resume", "--skip-git-repo-check")
		for _, p := range imagePaths {
			if strings.TrimSpace(p) != "" {
				args = append(args, "--image", p)
			}
		}
		args = append(args, existingSessionID, finalPrompt)
	}

	cmd := exec.CommandContext(ctx, cfg.CodexBin, args...)
	cmd.Dir = cfg.CodexWorkdir

	var combined bytes.Buffer
	cmd.Stdout = &combined
	cmd.Stderr = &combined

	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		log.Printf("[codex] timeout chat_id=%d session=%q args=%q", chatID, existingSessionID, args)
		return "", existingSessionID, fmt.Errorf("timeout after %d seconds", cfg.TimeoutSec)
	}
	if err != nil {
		log.Printf("[codex] exec failed chat_id=%d session=%q args=%q output=%q err=%v", chatID, existingSessionID, args, combined.String(), err)
		return "", existingSessionID, fmt.Errorf("%v\n%s", err, combined.String())
	}
	log.Printf("[codex] exec ok chat_id=%d session_before=%q session_after=%q args=%q raw_output begin\n%s\n[codex] exec ok chat_id=%d raw_output end", chatID, existingSessionID, parseSessionID(combined.String()), args, combined.String(), chatID)

	actualSessionID := parseSessionID(combined.String())
	if actualSessionID == "" {
		actualSessionID = existingSessionID
	}

	if useOutputLastMessage {
		lastMsg, err := os.ReadFile(lastMsgPath)
		if err == nil {
			final := strings.TrimSpace(string(lastMsg))
			if final != "" {
				log.Printf("[codex] output-last-message chat_id=%d session=%q value begin\n%s\n[codex] output-last-message chat_id=%d value end", chatID, actualSessionID, final, chatID)
				return final, actualSessionID, nil
			}
		}
	}

	if resumed := extractAssistantReply(combined.String()); resumed != "" {
		log.Printf("[codex] extracted assistant reply chat_id=%d session=%q value begin\n%s\n[codex] extracted assistant reply chat_id=%d value end", chatID, actualSessionID, resumed, chatID)
		return resumed, actualSessionID, nil
	}

	clean := cleanCodexOutput(combined.String())
	log.Printf("[codex] clean output chat_id=%d session=%q value begin\n%s\n[codex] clean output chat_id=%d value end", chatID, actualSessionID, clean, chatID)
	return clean, actualSessionID, nil
}

type codexRunner struct{}

func (c codexRunner) Name() string         { return "codex" }
func (c codexRunner) SupportsImages() bool { return true }
func (c codexRunner) Run(cfg bridgeConfig, chatID int64, prompt string, imagePaths []string) (agentRunResult, error) {
	out, sid, err := runCodexWithImages(cfg, chatID, prompt, imagePaths)
	if err != nil {
		return agentRunResult{}, err
	}
	return agentRunResult{Output: out, SessionID: sid}, nil
}

type genericRunner struct {
	name          string
	supportsImage bool
}

func (g genericRunner) Name() string {
	if strings.TrimSpace(g.name) == "" {
		return "generic"
	}
	return g.name
}
func (g genericRunner) SupportsImages() bool { return g.supportsImage }

func buildGenericRunnerArgs(cfg bridgeConfig, prompt string, sessionID string, imagePaths []string) ([]string, error) {
	imageJoined := strings.Join(imagePaths, ",")
	rawArgs, err := parseCommandArgs(cfg.AgentArgs)
	if err != nil {
		return nil, fmt.Errorf("invalid AGENT_ARGS: %w", err)
	}
	args := make([]string, 0, len(rawArgs)+4)
	promptAttached := false
	imageAttached := false
	for _, a := range rawArgs {
		if strings.Contains(a, "{{prompt}}") {
			a = strings.ReplaceAll(a, "{{prompt}}", prompt)
			promptAttached = true
		}
		if strings.Contains(a, "{{session_id}}") {
			a = strings.ReplaceAll(a, "{{session_id}}", sessionID)
		}
		if strings.Contains(a, "{{image_paths}}") {
			a = strings.ReplaceAll(a, "{{image_paths}}", imageJoined)
			imageAttached = true
		}
		args = append(args, a)
	}
	if len(imagePaths) > 0 && cfg.AgentSupportsImage && !imageAttached {
		for _, p := range imagePaths {
			if strings.TrimSpace(p) != "" {
				args = append(args, "--image", p)
			}
		}
	}
	if !promptAttached {
		args = append(args, prompt)
	}
	return args, nil
}

func (g genericRunner) Run(cfg bridgeConfig, chatID int64, prompt string, imagePaths []string) (agentRunResult, error) {
	sessionID := getChatSessionID(g.Name(), chatID)
	if sessionID == "" {
		sessionID = strconv.FormatInt(time.Now().UnixNano(), 10)
	}

	args, err := buildGenericRunnerArgs(cfg, prompt, sessionID, imagePaths)
	if err != nil {
		return agentRunResult{}, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.TimeoutSec)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.AgentBin, args...)
	cmd.Dir = cfg.CodexWorkdir
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			log.Printf("[agent-generic] timeout provider=%s chat_id=%d args=%q", g.Name(), chatID, args)
			return agentRunResult{}, fmt.Errorf("timeout after %d seconds", cfg.TimeoutSec)
		}
		log.Printf("[agent-generic] exec failed provider=%s chat_id=%d args=%q output=%q err=%v", g.Name(), chatID, args, out.String(), err)
		return agentRunResult{}, fmt.Errorf("%v\n%s", err, out.String())
	}
	log.Printf("[agent-generic] exec ok provider=%s chat_id=%d session=%q args=%q output begin\n%s\n[agent-generic] exec ok provider=%s chat_id=%d output end", g.Name(), chatID, sessionID, args, strings.TrimSpace(out.String()), g.Name(), chatID)
	return agentRunResult{Output: strings.TrimSpace(out.String()), SessionID: sessionID}, nil
}

func selectRunner(cfg bridgeConfig) agentRunner {
	switch cfg.AgentProvider {
	case "", "codex":
		return codexRunner{}
	case "generic", "command", "cli":
		return genericRunner{name: cfg.AgentProvider, supportsImage: cfg.AgentSupportsImage}
	default:
		// Unknown provider falls back to generic execution.
		return genericRunner{name: cfg.AgentProvider, supportsImage: cfg.AgentSupportsImage}
	}
}

func preprocessForRunner(cfg bridgeConfig, runner agentRunner, prompt string, imagePaths []string) (string, []string, error) {
	_ = cfg
	if len(imagePaths) == 0 {
		return prompt, nil, nil
	}
	if runner.SupportsImages() {
		return prompt, imagePaths, nil
	}

	descs := make([]string, 0, len(imagePaths))
	for _, p := range imagePaths {
		d, err := describeImageLocal(p)
		if err != nil {
			descs = append(descs, fmt.Sprintf("- %s (读取失败: %v)", p, err))
			continue
		}
		descs = append(descs, d)
	}
	fallback := "图片已转为文本描述（当前 Agent 不支持直接图片输入）：\n" + strings.Join(descs, "\n") + "\n\n用户请求：\n" + prompt
	return fallback, nil, nil
}

func describeImageLocal(path string) (string, error) {
	clean := strings.TrimSpace(path)
	if clean == "" {
		return "", fmt.Errorf("empty image path")
	}
	info, err := os.Stat(clean)
	if err != nil {
		return "", err
	}
	if info.IsDir() {
		return "", fmt.Errorf("path is directory")
	}
	width := "unknown"
	height := "unknown"
	cmd := exec.Command("sips", "-g", "pixelWidth", "-g", "pixelHeight", clean)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err == nil {
		for _, line := range strings.Split(out.String(), "\n") {
			l := strings.TrimSpace(line)
			if strings.HasPrefix(l, "pixelWidth:") {
				width = strings.TrimSpace(strings.TrimPrefix(l, "pixelWidth:"))
			}
			if strings.HasPrefix(l, "pixelHeight:") {
				height = strings.TrimSpace(strings.TrimPrefix(l, "pixelHeight:"))
			}
		}
	}
	return fmt.Sprintf("- 文件: %s, 尺寸: %sx%s, 大小: %d bytes", filepath.Base(clean), width, height, info.Size()), nil
}

func cleanCodexOutput(s string) string {
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "OpenAI Codex v") {
			continue
		}
		if strings.HasPrefix(trimmed, "workdir:") ||
			strings.HasPrefix(trimmed, "model:") ||
			strings.HasPrefix(trimmed, "provider:") ||
			strings.HasPrefix(trimmed, "approval:") ||
			strings.HasPrefix(trimmed, "sandbox:") ||
			strings.HasPrefix(trimmed, "reasoning effort:") ||
			strings.HasPrefix(trimmed, "reasoning summaries:") ||
			strings.HasPrefix(trimmed, "session id:") {
			continue
		}
		if strings.Contains(trimmed, "codex_core::") ||
			strings.Contains(trimmed, "mcp startup:") ||
			strings.HasPrefix(trimmed, "tokens used") {
			continue
		}
		if strings.EqualFold(trimmed, "user") ||
			strings.EqualFold(trimmed, "codex") ||
			strings.HasPrefix(trimmed, "--------") {
			continue
		}
		out = append(out, line)
	}

	return strings.TrimSpace(strings.Join(out, "\n"))
}

func extractAssistantReply(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	start := -1

	for i, line := range lines {
		if strings.EqualFold(strings.TrimSpace(line), "codex") {
			start = i + 1
		}
	}
	if start < 0 || start >= len(lines) {
		return ""
	}

	end := len(lines)
	for i := start; i < len(lines); i++ {
		t := strings.TrimSpace(lines[i])
		if strings.EqualFold(t, "tokens used") {
			end = i
			break
		}
	}

	reply := strings.TrimSpace(strings.Join(lines[start:end], "\n"))
	if reply == "" {
		return ""
	}
	return reply
}
