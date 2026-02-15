#!/bin/zsh
set -euo pipefail

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit scripts/secret_scan.sh

echo "Installed git hooks path: $(git config core.hooksPath)"
