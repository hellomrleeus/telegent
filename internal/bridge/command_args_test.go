package bridge

import (
	"reflect"
	"testing"
)

func TestParseCommandArgs(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		input   string
		want    []string
		wantErr bool
	}{
		{
			name:  "empty",
			input: "   ",
			want:  nil,
		},
		{
			name:  "simple",
			input: "--mode fast --flag",
			want:  []string{"--mode", "fast", "--flag"},
		},
		{
			name:  "double quoted value",
			input: `--message "hello world" --x 1`,
			want:  []string{"--message", "hello world", "--x", "1"},
		},
		{
			name:  "single quoted value",
			input: "--message 'hello world' --x 1",
			want:  []string{"--message", "hello world", "--x", "1"},
		},
		{
			name:  "escaped spaces and quote",
			input: `--path /tmp/a\ b --raw \"x\"`,
			want:  []string{"--path", "/tmp/a b", "--raw", `"x"`},
		},
		{
			name:    "unclosed quote",
			input:   `--message "hello`,
			wantErr: true,
		},
		{
			name:    "trailing escape",
			input:   `--path /tmp/a\`,
			wantErr: true,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, err := parseCommandArgs(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil and args=%v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("parseCommandArgs(%q)=%v, want=%v", tc.input, got, tc.want)
			}
		})
	}
}
