#!/usr/bin/env python3
import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe audio with faster-whisper")
    parser.add_argument("--input", required=True, help="Input audio file path")
    parser.add_argument("--model", default="small", help="Whisper model name/path")
    parser.add_argument("--language", default="zh", help="Language code, e.g. zh, en")
    parser.add_argument("--compute-type", default="int8", help="faster-whisper compute type")
    args = parser.parse_args()

    try:
        from faster_whisper import WhisperModel
    except Exception as e:
        print(
            "faster-whisper is not installed. Install with: "
            "python3 -m pip install faster-whisper",
            file=sys.stderr,
        )
        print(f"import error: {e}", file=sys.stderr)
        return 2

    try:
        model = WhisperModel(args.model, compute_type=args.compute_type)
    except Exception as e:
        print(f"failed to load model '{args.model}': {e}", file=sys.stderr)
        return 3

    try:
        segments, _info = model.transcribe(args.input, language=args.language)
        text = "".join(segment.text for segment in segments).strip()
    except Exception as e:
        print(f"transcription failed: {e}", file=sys.stderr)
        return 4

    if not text:
        print("empty transcript", file=sys.stderr)
        return 5

    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
