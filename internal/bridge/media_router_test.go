package bridge

import (
	"errors"
	"strings"
	"testing"
)

func TestProcessIncomingMediaCore_PrioritizesMediaOverImage(t *testing.T) {
	t.Parallel()

	msg := telegramMessage{
		Chat: telegramChat{ID: 1},
		Voice: &telegramFileRef{
			FileID: "voice-file",
		},
		Photo: []telegramPhotoSize{{FileID: "photo-file"}},
	}
	cfg := bridgeConfig{MaxReplyChars: 3500}

	mediaCalled := false
	imageCalled := false
	env := processIncomingMediaCore(
		cfg,
		msg,
		func(cfg bridgeConfig, chatID int64, msg telegramMessage, media mediaInput) (mediaProcessResult, error) {
			mediaCalled = true
			return mediaProcessResult{Output: "ok media"}, nil
		},
		func(cfg bridgeConfig, chatID int64, image imageInput) (mediaProcessResult, error) {
			imageCalled = true
			return mediaProcessResult{Output: "ok image"}, nil
		},
	)

	if !env.Handled {
		t.Fatal("expected handled=true")
	}
	if env.Tag != "media_output" {
		t.Fatalf("unexpected tag: %q", env.Tag)
	}
	if !mediaCalled {
		t.Fatal("expected media handler to be called")
	}
	if imageCalled {
		t.Fatal("expected image handler NOT to be called when media exists")
	}
}

func TestProcessIncomingMediaCore_MediaErrorWrapped(t *testing.T) {
	t.Parallel()

	msg := telegramMessage{
		Chat: telegramChat{ID: 1},
		Voice: &telegramFileRef{
			FileID: "voice-file",
		},
	}
	cfg := bridgeConfig{MaxReplyChars: 3500}

	env := processIncomingMediaCore(
		cfg,
		msg,
		func(cfg bridgeConfig, chatID int64, msg telegramMessage, media mediaInput) (mediaProcessResult, error) {
			return mediaProcessResult{}, errors.New("boom")
		},
		func(cfg bridgeConfig, chatID int64, image imageInput) (mediaProcessResult, error) {
			t.Fatal("image handler should not be called")
			return mediaProcessResult{}, nil
		},
	)

	if !env.Handled {
		t.Fatal("expected handled=true")
	}
	if env.Tag != "media_error" {
		t.Fatalf("unexpected tag: %q", env.Tag)
	}
	if !strings.HasPrefix(env.Resp, "media process error:\n") {
		t.Fatalf("unexpected media error response: %q", env.Resp)
	}
	if !strings.Contains(env.Resp, "boom") {
		t.Fatalf("expected original error in response: %q", env.Resp)
	}
}

func TestProcessIncomingMediaCore_ImageErrorWrapped(t *testing.T) {
	t.Parallel()

	msg := telegramMessage{
		Chat:  telegramChat{ID: 1},
		Photo: []telegramPhotoSize{{FileID: "photo-file"}},
	}
	cfg := bridgeConfig{MaxReplyChars: 3500}

	env := processIncomingMediaCore(
		cfg,
		msg,
		func(cfg bridgeConfig, chatID int64, msg telegramMessage, media mediaInput) (mediaProcessResult, error) {
			t.Fatal("media handler should not be called")
			return mediaProcessResult{}, nil
		},
		func(cfg bridgeConfig, chatID int64, image imageInput) (mediaProcessResult, error) {
			return mediaProcessResult{}, errors.New("bad image")
		},
	)

	if !env.Handled {
		t.Fatal("expected handled=true")
	}
	if env.Tag != "image_error" {
		t.Fatalf("unexpected tag: %q", env.Tag)
	}
	if !strings.HasPrefix(env.Resp, "image process error:\n") {
		t.Fatalf("unexpected image error response: %q", env.Resp)
	}
	if !strings.Contains(env.Resp, "bad image") {
		t.Fatalf("expected original error in response: %q", env.Resp)
	}
}
