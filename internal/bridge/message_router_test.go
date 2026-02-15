package bridge

import "testing"

func TestNormalizeMessageText(t *testing.T) {
	t.Parallel()

	msg := telegramMessage{
		Text:    "   ",
		Caption: "  hello from caption ",
	}
	if got := normalizeMessageText(msg); got != "hello from caption" {
		t.Fatalf("normalizeMessageText()=%q", got)
	}

	msg = telegramMessage{
		Text:    " use text ",
		Caption: "caption",
	}
	if got := normalizeMessageText(msg); got != "use text" {
		t.Fatalf("normalizeMessageText()=%q", got)
	}
}

func TestClassifyTextCommand(t *testing.T) {
	t.Parallel()

	tests := []struct {
		input string
		want  textCommand
	}{
		{"/start", commandHelp},
		{"/help", commandHelp},
		{"/ping", commandPing},
		{"/cwd", commandCWD},
		{"/session", commandSession},
		{"/newsession", commandNewSession},
		{"/reset", commandNewSession},
		{"/memory", commandMemory},
		{"/forget", commandForget},
		{"截图", commandScreenshot},
		{"/screenshot", commandScreenshot},
		{"random text", commandNone},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.input, func(t *testing.T) {
			t.Parallel()
			if got := classifyTextCommand(tc.input); got != tc.want {
				t.Fatalf("classifyTextCommand(%q)=%v, want=%v", tc.input, got, tc.want)
			}
		})
	}
}
