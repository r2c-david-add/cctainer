#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Usage: ./run.sh [/path/to/repo] [extra claude args...]
# Examples:
#   ./run.sh                          # interactive claude in current dir
#   ./run.sh ~/code/myproject         # mount a specific repo
#   ./run.sh ~/code/myproject -p "fix the tests"  # with a prompt

SRC_DIR="${1:-.}"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
shift 2>/dev/null || true

# Build if image doesn't exist
if ! docker image inspect cctainer:latest &>/dev/null; then
    echo "Building cctainer image..."
    docker build -t cctainer:latest "$SCRIPT_DIR"
fi

exec docker run --rm -it \
    -v "$SRC_DIR":/src \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    cctainer:latest \
    "$@"
