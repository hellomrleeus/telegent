package bridge

import (
	"fmt"
	"strings"
)

func parseCommandArgs(input string) ([]string, error) {
	s := strings.TrimSpace(input)
	if s == "" {
		return nil, nil
	}

	args := make([]string, 0, 8)
	var cur strings.Builder
	inSingle := false
	inDouble := false
	escaped := false

	flush := func() {
		args = append(args, cur.String())
		cur.Reset()
	}

	for i := 0; i < len(s); i++ {
		ch := s[i]

		if escaped {
			cur.WriteByte(ch)
			escaped = false
			continue
		}

		if inSingle {
			if ch == '\'' {
				inSingle = false
				continue
			}
			cur.WriteByte(ch)
			continue
		}

		if inDouble {
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inDouble = false
			default:
				cur.WriteByte(ch)
			}
			continue
		}

		switch ch {
		case ' ', '\t', '\n', '\r':
			if cur.Len() > 0 {
				flush()
			}
		case '\'':
			inSingle = true
		case '"':
			inDouble = true
		case '\\':
			escaped = true
		default:
			cur.WriteByte(ch)
		}
	}

	if escaped {
		return nil, fmt.Errorf("trailing escape in AGENT_ARGS")
	}
	if inSingle || inDouble {
		return nil, fmt.Errorf("unclosed quote in AGENT_ARGS")
	}
	if cur.Len() > 0 {
		flush()
	}
	return args, nil
}
