package bridge

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func runAgentWithMedia(cfg bridgeConfig, chatID int64, msg telegramMessage, media mediaInput) (mediaProcessResult, error) {
	_ = msg
	localPath, err := downloadTelegramFile(cfg, media.FileID, media.OriginalName)
	if err != nil {
		return mediaProcessResult{}, fmt.Errorf("failed to download telegram file: %w", err)
	}

	task := "请总结文件内容并回答用户需求。"
	if media.Kind == "视频" || media.Kind == "视频短消息" {
		task = "请先分析视频内容（包含语音时尽量转写），再总结要点并回答用户需求。"
	}

	if media.Kind == "语音" || media.Kind == "音频" {
		defer os.Remove(localPath)
		transcript, err := transcribeWithFasterWhisper(cfg, localPath)
		if err != nil {
			return mediaProcessResult{}, fmt.Errorf("语音转写失败: %w", err)
		}
		userInstruction := strings.TrimSpace(media.UserHint)
		prompt := strings.TrimSpace(transcript)
		if userInstruction != "" {
			prompt = fmt.Sprintf("%s\n\n补充说明：%s", prompt, userInstruction)
		}
		userText := fmt.Sprintf("[%s] %s", media.Kind, strings.TrimSpace(transcript))
		if userInstruction != "" {
			userText = fmt.Sprintf("%s\n%s", userText, userInstruction)
		}

		out, _, err := runAgent(cfg, chatID, prompt, nil)
		if err != nil {
			return mediaProcessResult{}, err
		}
		return mediaProcessResult{Output: out, UserText: strings.TrimSpace(userText)}, nil
	}

	userInstruction := strings.TrimSpace(media.UserHint)
	if userInstruction == "" {
		userInstruction = "请处理这个文件并用中文给出结果。"
	}

	prompt := fmt.Sprintf(
		"用户发送了一个%s文件，请使用本地文件进行处理。\n文件路径: %s\n文件名: %s\n任务: %s\n用户补充: %s\n如果无法读取该媒体，请明确说明缺少的工具或权限。",
		media.Kind,
		localPath,
		filepath.Base(localPath),
		task,
		userInstruction,
	)

	out, _, err := runAgent(cfg, chatID, prompt, nil)
	if err != nil {
		return mediaProcessResult{}, err
	}
	return mediaProcessResult{Output: out}, nil
}

func transcribeWithFasterWhisper(cfg bridgeConfig, audioPath string) (string, error) {
	pythonPath, err := resolvePythonBinary(cfg.WhisperPythonBin)
	if err != nil {
		return "", fmt.Errorf("python not available (%s): %w", cfg.WhisperPythonBin, err)
	}

	scriptPath := strings.TrimSpace(cfg.WhisperScript)
	if scriptPath == "" {
		return "", errors.New("WHISPER_SCRIPT is empty")
	}
	if !filepath.IsAbs(scriptPath) {
		scriptPath = filepath.Join(cfg.CodexWorkdir, scriptPath)
	}
	if info, statErr := os.Stat(scriptPath); statErr != nil || info.IsDir() {
		return "", fmt.Errorf("whisper script not found: %s", scriptPath)
	}

	args := []string{
		scriptPath,
		"--input", audioPath,
		"--model", cfg.WhisperModel,
		"--language", cfg.WhisperLanguage,
		"--compute-type", cfg.WhisperCompute,
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.TimeoutSec)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, pythonPath, args...)
	cmd.Dir = cfg.CodexWorkdir
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("faster-whisper timeout after %d seconds", cfg.TimeoutSec)
	}
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		if msg == "" {
			msg = err.Error()
		}
		return "", errors.New(msg)
	}
	text := strings.TrimSpace(stdout.String())
	if text == "" {
		return "", errors.New("empty transcript")
	}
	return text, nil
}

func resolvePythonBinary(configured string) (string, error) {
	name := strings.TrimSpace(configured)
	if name == "" {
		name = "python3"
	}
	if strings.ContainsRune(name, os.PathSeparator) {
		if isExecutableFile(name) {
			return name, nil
		}
		return "", fmt.Errorf("configured path is not executable: %s", name)
	}
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	candidates := []string{
		filepath.Join("/opt/homebrew/bin", name),
		filepath.Join("/usr/local/bin", name),
		filepath.Join("/opt/local/bin", name),
		filepath.Join("/usr/bin", name),
		filepath.Join("/bin", name),
	}
	for _, c := range candidates {
		if isExecutableFile(c) {
			return c, nil
		}
	}
	return "", fmt.Errorf("executable file not found in PATH or common dirs")
}

func isExecutableFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func runAgentWithImage(cfg bridgeConfig, chatID int64, image imageInput) (mediaProcessResult, error) {
	localPath, err := downloadTelegramFileToDir(cfg, image.FileID, "", cfg.ImageDir)
	if err != nil {
		return mediaProcessResult{}, fmt.Errorf("failed to download image: %w", err)
	}
	userInstruction := strings.TrimSpace(image.UserHint)
	if userInstruction == "" {
		userInstruction = "请描述这张图片并提取关键信息。"
	}
	prompt := "用户发送了一张图片，请根据图片内容完成用户需求。\n用户补充: " + userInstruction
	out, _, err := runAgent(cfg, chatID, prompt, []string{localPath})
	if err != nil {
		return mediaProcessResult{}, err
	}
	userText := "[图片]"
	if strings.TrimSpace(image.UserHint) != "" {
		userText = "[图片] " + strings.TrimSpace(image.UserHint)
	}
	return mediaProcessResult{Output: out, UserText: userText, MediaPath: localPath}, nil
}

func extractMediaInput(msg telegramMessage) *mediaInput {
	hint := strings.TrimSpace(msg.Caption)

	if msg.Voice != nil && strings.TrimSpace(msg.Voice.FileID) != "" {
		return &mediaInput{Kind: "语音", FileID: strings.TrimSpace(msg.Voice.FileID), UserHint: hint}
	}
	if msg.Audio != nil && strings.TrimSpace(msg.Audio.FileID) != "" {
		return &mediaInput{Kind: "音频", FileID: strings.TrimSpace(msg.Audio.FileID), UserHint: hint}
	}
	if msg.Video != nil && strings.TrimSpace(msg.Video.FileID) != "" {
		return &mediaInput{Kind: "视频", FileID: strings.TrimSpace(msg.Video.FileID), UserHint: hint}
	}
	if msg.VideoNote != nil && strings.TrimSpace(msg.VideoNote.FileID) != "" {
		return &mediaInput{Kind: "视频短消息", FileID: strings.TrimSpace(msg.VideoNote.FileID), UserHint: hint}
	}
	if msg.Document != nil && strings.TrimSpace(msg.Document.FileID) != "" {
		mime := strings.ToLower(strings.TrimSpace(msg.Document.MimeType))
		if strings.HasPrefix(mime, "audio/") {
			return &mediaInput{Kind: "音频", FileID: strings.TrimSpace(msg.Document.FileID), UserHint: hint, OriginalName: strings.TrimSpace(msg.Document.FileName)}
		}
		if strings.HasPrefix(mime, "video/") {
			return &mediaInput{Kind: "视频", FileID: strings.TrimSpace(msg.Document.FileID), UserHint: hint, OriginalName: strings.TrimSpace(msg.Document.FileName)}
		}
	}
	return nil
}

func extractImageInput(msg telegramMessage) *imageInput {
	if len(msg.Photo) == 0 {
		return nil
	}
	p := msg.Photo[len(msg.Photo)-1]
	if strings.TrimSpace(p.FileID) == "" {
		return nil
	}
	return &imageInput{FileID: strings.TrimSpace(p.FileID), UserHint: strings.TrimSpace(msg.Caption)}
}

func captureScreenshot(cfg bridgeConfig) (string, error) {
	outDir := cfg.ImageDir
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return "", err
	}
	name := "codex-screenshot-" + time.Now().Format("20060102-150405") + ".png"
	outPath := filepath.Join(outDir, name)

	cmd := exec.Command("screencapture", "-x", outPath)
	cmd.Dir = cfg.CodexWorkdir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", errors.New(msg)
	}
	return outPath, nil
}

func handleScreenshotRequest(cfg bridgeConfig, msg telegramMessage) error {
	path, err := captureScreenshot(cfg)
	if err != nil {
		return err
	}
	if err := sendImageWithFallback(cfg, msg.Chat.ID, path, ""); err != nil {
		return err
	}
	appendChatLogWithOptions(cfg, msg, "", "screenshot_ok", chatLogOptions{UserText: "", KeepUserText: true, BotMediaPath: path})
	return nil
}

func sendImageWithFallback(cfg bridgeConfig, chatID int64, filePath string, caption string) error {
	if err := sendPhoto(cfg, chatID, filePath, caption); err != nil {
		if err2 := sendDocument(cfg, chatID, filePath, filepath.Base(filePath)); err2 != nil {
			return fmt.Errorf("image upload failed: photo=%v document=%v", err, err2)
		}
	}
	return nil
}
