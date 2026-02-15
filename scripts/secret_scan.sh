#!/bin/zsh
set -euo pipefail

MODE="staged"
if [[ "${1:-}" == "--all" ]]; then
  MODE="all"
fi

PATTERN='([0-9]{8,12}:[A-Za-z0-9_-]{20,})|(sk-[A-Za-z0-9]{20,})|(TELEGRAM_BOT_TOKEN[[:space:]]*[:=][[:space:]]*["'"'"']?[0-9]{8,12}:[A-Za-z0-9_-]{20,})'

if [[ "$MODE" == "all" ]]; then
  if LC_ALL=C rg -n -I -e "$PATTERN" -g '!.git/**' -g '!dist/**' .; then
    echo "\n[secret-scan] Potential secret detected in repository"
    exit 1
  fi
  echo "[secret-scan] OK"
  exit 0
fi

files=$(git diff --cached --name-only --diff-filter=ACMRTUXB)
if [[ -z "$files" ]]; then
  echo "[secret-scan] no staged files"
  exit 0
fi

failed=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if ! git cat-file -e ":$f" 2>/dev/null; then
    continue
  fi
  if git show ":$f" | LC_ALL=C rg -n -I -e "$PATTERN" >/dev/null; then
    echo "[secret-scan] Potential secret in staged file: $f"
    git show ":$f" | LC_ALL=C rg -n -I -e "$PATTERN" || true
    failed=1
  fi
done <<< "$files"

if [[ "$failed" -ne 0 ]]; then
  echo "\n[secret-scan] Commit blocked. Move secrets to environment variables or .env (ignored)."
  exit 1
fi

echo "[secret-scan] OK"
