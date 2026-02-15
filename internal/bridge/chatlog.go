package bridge

import (
	"encoding/json"
	"log"
	"os"
	"strings"
	"time"
)

func trimForTelegram(s string, maxChars int) string {
	s = strings.TrimSpace(s)
	if len(s) <= maxChars {
		return s
	}
	return s[:maxChars] + "\n...[truncated]"
}

type chatLogRecord struct {
	Timestamp    string `json:"timestamp"`
	Tag          string `json:"tag"`
	SessionID    string `json:"session_id"`
	UserID       int64  `json:"user_id"`
	ChatID       int64  `json:"chat_id"`
	MessageID    int64  `json:"message_id"`
	UserText     string `json:"user_text"`
	BotText      string `json:"bot_text"`
	MediaType    string `json:"media_type,omitempty"`
	MediaPath    string `json:"media_path,omitempty"`
	BotMediaPath string `json:"bot_media_path,omitempty"`
}

type chatLogOptions struct {
	UserText     string
	KeepUserText bool
	MediaPath    string
	BotMediaPath string
}

func appendChatLog(cfg bridgeConfig, msg telegramMessage, botText string, tag string) {
	appendChatLogWithOptions(cfg, msg, botText, tag, chatLogOptions{})
}

func appendChatLogWithOptions(cfg bridgeConfig, msg telegramMessage, botText string, tag string, opts chatLogOptions) {
	userID := int64(0)
	if msg.From != nil {
		userID = msg.From.ID
	}

	userText := strings.TrimSpace(opts.UserText)
	if userText == "" && !opts.KeepUserText {
		userText = firstNonEmpty(strings.TrimSpace(msg.Text), strings.TrimSpace(msg.Caption))
	}
	mediaType := detectMediaType(msg)
	if userText == "" && mediaType != "" {
		userText = "[" + mediaType + "]"
	}
	rec := chatLogRecord{
		Timestamp:    time.Now().Format(time.RFC3339),
		Tag:          tag,
		SessionID:    getChatSessionID(cfg.AgentProvider, msg.Chat.ID),
		UserID:       userID,
		ChatID:       msg.Chat.ID,
		MessageID:    msg.MessageID,
		UserText:     userText,
		BotText:      strings.TrimSpace(botText),
		MediaType:    mediaType,
		MediaPath:    strings.TrimSpace(opts.MediaPath),
		BotMediaPath: strings.TrimSpace(opts.BotMediaPath),
	}

	b, err := json.Marshal(rec)
	if err != nil {
		log.Printf("chat log marshal failed: %v", err)
		return
	}

	f, err := os.OpenFile(cfg.ChatLogFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("chat log open failed: %v", err)
		return
	}
	defer f.Close()

	if _, err := f.Write(append(b, '\n')); err != nil {
		log.Printf("chat log write failed: %v", err)
	}
}

func detectMediaType(msg telegramMessage) string {
	switch {
	case msg.Voice != nil:
		return "语音"
	case msg.Audio != nil:
		return "音频"
	case msg.Video != nil:
		return "视频"
	case msg.VideoNote != nil:
		return "视频短消息"
	case len(msg.Photo) > 0:
		return "图片"
	case msg.Document != nil:
		return "文件"
	default:
		return ""
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
