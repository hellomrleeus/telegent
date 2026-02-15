package bridge

import (
	"reflect"
	"testing"
)

func TestBuildGenericRunnerArgs(t *testing.T) {
	t.Parallel()

	cfg := bridgeConfig{
		AgentArgs:          `--session "{{session_id}}" --prompt "{{prompt}}" --images "{{image_paths}}"`,
		AgentSupportsImage: true,
	}

	got, err := buildGenericRunnerArgs(cfg, "hello world", "sid-1", []string{"/tmp/1.png", "/tmp/2.png"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{
		"--session", "sid-1",
		"--prompt", "hello world",
		"--images", "/tmp/1.png,/tmp/2.png",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("buildGenericRunnerArgs mismatch\ngot : %v\nwant: %v", got, want)
	}
}

func TestBuildGenericRunnerArgs_AutoAppendPromptAndImage(t *testing.T) {
	t.Parallel()

	cfg := bridgeConfig{
		AgentArgs:          `--mode fast`,
		AgentSupportsImage: true,
	}
	got, err := buildGenericRunnerArgs(cfg, "hello", "sid-2", []string{"/tmp/img.png"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{"--mode", "fast", "--image", "/tmp/img.png", "hello"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("buildGenericRunnerArgs mismatch\ngot : %v\nwant: %v", got, want)
	}
}

func TestBuildGenericRunnerArgs_InvalidArgs(t *testing.T) {
	t.Parallel()

	cfg := bridgeConfig{
		AgentArgs: `--message "broken`,
	}
	_, err := buildGenericRunnerArgs(cfg, "hello", "sid", nil)
	if err == nil {
		t.Fatal("expected error for invalid AGENT_ARGS, got nil")
	}
}
