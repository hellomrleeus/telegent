package bridge

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func Run() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}
	lockFile, err := acquireSingleInstanceLock(cfg)
	if err != nil {
		log.Fatalf("startup blocked: %v", err)
	}
	defer func() {
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
	}()

	log.Printf("starting telegram-codex bridge. workdir=%q provider=%q agent_bin=%q codex=%q", cfg.CodexWorkdir, cfg.AgentProvider, cfg.AgentBin, cfg.CodexBin)
	startParentWatchdog(cfg)

	var offset int64
	for {
		updates, err := getUpdates(cfg, offset)
		if err != nil {
			log.Printf("getUpdates failed: %v", err)
			time.Sleep(3 * time.Second)
			continue
		}

		for _, upd := range updates {
			offset = upd.UpdateID + 1
			if upd.Message == nil {
				continue
			}
			handleMessage(cfg, *upd.Message)
		}
	}
}

func startParentWatchdog(cfg bridgeConfig) {
	if cfg.ParentPID <= 1 {
		return
	}
	expected := cfg.ParentPID
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			ppid := os.Getppid()
			if ppid == expected {
				continue
			}
			log.Printf("parent watchdog: expected ppid=%d, got=%d; exiting bridge core", expected, ppid)
			os.Exit(0)
		}
	}()
}

func acquireSingleInstanceLock(cfg bridgeConfig) (*os.File, error) {
	lockPath := singleInstanceLockPath(cfg)
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("failed to open lock file %q: %w", lockPath, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, fmt.Errorf("another bridge instance is already running (lock=%s)", lockPath)
		}
		return nil, fmt.Errorf("failed to lock %q: %w", lockPath, err)
	}
	if err := f.Truncate(0); err == nil {
		_, _ = f.Seek(0, 0)
		_, _ = fmt.Fprintf(f, "pid=%d started=%s\n", os.Getpid(), time.Now().Format(time.RFC3339))
	}
	return f, nil
}

func singleInstanceLockPath(cfg bridgeConfig) string {
	sum := sha1.Sum([]byte(cfg.BotToken))
	tokenSig := hex.EncodeToString(sum[:6])
	name := fmt.Sprintf("telegent-%d-%s.lock", cfg.AllowedUserID, tokenSig)
	return filepath.Join(os.TempDir(), name)
}

func handleMessage(cfg bridgeConfig, msg telegramMessage) {
	if msg.From == nil {
		return
	}
	if msg.From.ID != cfg.AllowedUserID {
		reply := "Not authorized."
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "unauthorized")
		return
	}

	text := normalizeMessageText(msg)

	if processIncomingMedia(cfg, msg) {
		return
	}

	if text == "" {
		reply := "Send plain text. I will pass it to codex exec."
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "empty_message")
		return
	}

	if handleExactCommand(cfg, msg, classifyTextCommand(text)) {
		return
	}
	if handleRememberCommand(cfg, msg, text) {
		return
	}

	handleDefaultText(cfg, msg, text)
}
