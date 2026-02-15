package bridge

import (
	"fmt"
	"strings"
)

type textCommand int

const (
	commandNone textCommand = iota
	commandHelp
	commandPing
	commandCWD
	commandSession
	commandNewSession
	commandMemory
	commandForget
	commandScreenshot
)

type runMediaFunc func(cfg bridgeConfig, chatID int64, msg telegramMessage, media mediaInput) (mediaProcessResult, error)
type runImageFunc func(cfg bridgeConfig, chatID int64, image imageInput) (mediaProcessResult, error)

type mediaProcessEnvelope struct {
	Handled bool
	Resp    string
	Tag     string
	Opts    chatLogOptions
}

func normalizeMessageText(msg telegramMessage) string {
	text := strings.TrimSpace(msg.Text)
	caption := strings.TrimSpace(msg.Caption)
	if text == "" && caption != "" {
		return caption
	}
	return text
}

func classifyTextCommand(text string) textCommand {
	switch strings.TrimSpace(text) {
	case "/start", "/help":
		return commandHelp
	case "/ping":
		return commandPing
	case "/cwd":
		return commandCWD
	case "/session":
		return commandSession
	case "/newsession", "/reset":
		return commandNewSession
	case "/memory":
		return commandMemory
	case "/forget":
		return commandForget
	case "/screenshot", "截图":
		return commandScreenshot
	default:
		return commandNone
	}
}

func handleExactCommand(cfg bridgeConfig, msg telegramMessage, cmd textCommand) bool {
	switch cmd {
	case commandHelp:
		help := "Commands:\n" +
			"/ping - health check\n" +
			"/cwd - show CODEX_WORKDIR\n" +
			"/newsession - reset Agent session for this chat\n" +
			"/session - show bound Agent session id\n" +
			"/screenshot - take a local screenshot and send back\n" +
			"/memory - show persistent memory\n" +
			"/remember <text> - append memory item\n" +
			"/forget - clear user memory items\n" +
			"You can also send: 记住<内容>\n" +
			"Image is supported now.\n" +
			"Voice/Audio/Video is supported now.\n" +
			"Any other text will be sent to current agent provider"
		_ = sendMessage(cfg, msg.Chat.ID, help)
		appendChatLog(cfg, msg, help, "help")
		return true
	case commandPing:
		reply := "pong"
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "ping")
		return true
	case commandCWD:
		reply := "workdir: " + cfg.CodexWorkdir
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "cwd")
		return true
	case commandSession:
		sid := getChatSessionID(cfg.AgentProvider, msg.Chat.ID)
		reply := "session: (none)"
		if sid != "" {
			reply = "provider=" + cfg.AgentProvider + " session: " + sid
		}
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "session")
		return true
	case commandNewSession:
		clearChatSessionID(cfg, cfg.AgentProvider, msg.Chat.ID)
		reply := "session reset. next message will start a new " + cfg.AgentProvider + " session."
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "new_session")
		return true
	case commandMemory:
		mem, err := readMemory(cfg)
		if err != nil {
			reply := "failed to read memory: " + err.Error()
			_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
			appendChatLog(cfg, msg, reply, "memory_error")
			return true
		}
		reply := "MEMORY.md:\n" + mem
		_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
		appendChatLog(cfg, msg, reply, "memory_view")
		return true
	case commandForget:
		if err := resetMemory(cfg); err != nil {
			reply := "failed to reset memory: " + err.Error()
			_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
			appendChatLog(cfg, msg, reply, "memory_error")
			return true
		}
		reply := "memory reset done."
		_ = sendMessage(cfg, msg.Chat.ID, reply)
		appendChatLog(cfg, msg, reply, "memory_reset")
		return true
	case commandScreenshot:
		if err := handleScreenshotRequest(cfg, msg); err != nil {
			reply := "screenshot failed: " + err.Error()
			_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
			appendChatLog(cfg, msg, reply, "screenshot_error")
		}
		return true
	default:
		return false
	}
}

func handleRememberCommand(cfg bridgeConfig, msg telegramMessage, text string) bool {
	remembered, ok := parseRememberCommand(text)
	if !ok {
		return false
	}
	if err := appendMemoryItem(cfg, remembered); err != nil {
		reply := "failed to update memory: " + err.Error()
		_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
		appendChatLog(cfg, msg, reply, "memory_error")
		return true
	}
	reply := "已记住: " + remembered
	_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
	appendChatLog(cfg, msg, reply, "memory_append")
	return true
}

func processIncomingMedia(cfg bridgeConfig, msg telegramMessage) bool {
	envelope := processIncomingMediaCore(cfg, msg, runAgentWithMedia, runAgentWithImage)
	if !envelope.Handled {
		return false
	}
	_ = sendMessage(cfg, msg.Chat.ID, envelope.Resp)
	appendChatLogWithOptions(cfg, msg, envelope.Resp, envelope.Tag, envelope.Opts)
	return true
}

func processIncomingMediaCore(cfg bridgeConfig, msg telegramMessage, runMedia runMediaFunc, runImage runImageFunc) mediaProcessEnvelope {
	if media := extractMediaInput(msg); media != nil {
		mediaRes, err := runMedia(cfg, msg.Chat.ID, msg, *media)
		if err != nil {
			resp := fmt.Sprintf("media process error:\n%s", trimForTelegram(err.Error(), cfg.MaxReplyChars))
			return mediaProcessEnvelope{
				Handled: true,
				Resp:    resp,
				Tag:     "media_error",
			}
		}
		out := mediaRes.Output
		if strings.TrimSpace(out) == "" {
			out = "(no output)"
		}
		resp := trimForTelegram(out, cfg.MaxReplyChars)
		return mediaProcessEnvelope{
			Handled: true,
			Resp:    resp,
			Tag:     "media_output",
			Opts: chatLogOptions{
				UserText:  mediaRes.UserText,
				MediaPath: mediaRes.MediaPath,
			},
		}
	}
	if image := extractImageInput(msg); image != nil {
		imgRes, err := runImage(cfg, msg.Chat.ID, *image)
		if err != nil {
			resp := fmt.Sprintf("image process error:\n%s", trimForTelegram(err.Error(), cfg.MaxReplyChars))
			return mediaProcessEnvelope{
				Handled: true,
				Resp:    resp,
				Tag:     "image_error",
			}
		}
		out := imgRes.Output
		if strings.TrimSpace(out) == "" {
			out = "(no output)"
		}
		resp := trimForTelegram(out, cfg.MaxReplyChars)
		return mediaProcessEnvelope{
			Handled: true,
			Resp:    resp,
			Tag:     "image_output",
			Opts: chatLogOptions{
				UserText:  imgRes.UserText,
				MediaPath: imgRes.MediaPath,
			},
		}
	}

	return mediaProcessEnvelope{}
}

func handleDefaultText(cfg bridgeConfig, msg telegramMessage, text string) {
	if isScreenshotRequest(text) {
		if err := handleScreenshotRequest(cfg, msg); err != nil {
			reply := "screenshot failed: " + err.Error()
			_ = sendMessage(cfg, msg.Chat.ID, trimForTelegram(reply, cfg.MaxReplyChars))
			appendChatLog(cfg, msg, reply, "screenshot_error")
		}
		return
	}

	out, _, err := runAgent(cfg, msg.Chat.ID, text, nil)
	if err != nil {
		resp := fmt.Sprintf("agent error:\n%s", trimForTelegram(err.Error(), cfg.MaxReplyChars))
		_ = sendMessage(cfg, msg.Chat.ID, resp)
		appendChatLog(cfg, msg, resp, "agent_error")
		return
	}

	if strings.TrimSpace(out) == "" {
		out = "(no output)"
	}
	resp := trimForTelegram(out, cfg.MaxReplyChars)
	_ = sendMessage(cfg, msg.Chat.ID, resp)
	appendChatLog(cfg, msg, resp, "agent_output")
}
