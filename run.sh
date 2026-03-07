#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Usage:
#   ./run.sh [/path/to/repo] [extra claude args...]
#   ./run.sh plan [/path/to/repo]
#   ./run.sh dispatch <manifest.yml>
#   ./run.sh status <manifest.yml>
#   ./run.sh build
#   ./run.sh gws-setup
#   ./run.sh gws-auth
#
# Examples:
#   ./run.sh                                        # interactive, current dir
#   ./run.sh ~/code/myproject                       # mount a specific repo
#   ./run.sh ~/code/myproject -p "fix the tests"    # with a prompt
#   ./run.sh plan ~/code/myproject                  # plan features interactively
#   ./run.sh dispatch cc-manifest.yml               # fan out agents from manifest
#   ./run.sh status cc-manifest.yml                 # check agent progress
#   ./run.sh build                                  # rebuild the image
#   ./run.sh gws-setup                              # configure GCP project + OAuth
#   ./run.sh gws-auth                               # log in to Google Workspace

# Common mounts for Claude auth, config, MCP, and Google Workspace
CLAUDE_MOUNTS=(
    -v "$HOME/.claude.json:/home/claude/.claude.json"
    -v "$HOME/.claude:/home/claude/.claude"
    -v "$HOME/.config/gh:/home/claude/.config/gh"
    -v "$HOME/.config/gws:/home/claude/.config/gws"
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
)

if [ "${1:-}" = "build" ]; then
    echo "Building cctainer image..."
    exec docker build -t cctainer:latest "$SCRIPT_DIR"
fi

if [ "${1:-}" = "dispatch" ]; then
    shift
    exec "$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/dispatch.py" dispatch "$@"
fi

if [ "${1:-}" = "status" ]; then
    shift
    exec "$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/dispatch.py" status "$@"
fi

if [ "${1:-}" = "plan" ]; then
    shift
    REPO_PATH="${1:-.}"
    REPO_PATH="$(cd "$REPO_PATH" && pwd)"
    REPO_NAME="$(basename "$REPO_PATH")"
    PARENT_DIR="$(dirname "$REPO_PATH")"

    if ! docker image inspect cctainer:latest &>/dev/null; then
        echo "Error: cctainer image not found. Run 'cc build' first." >&2
        exit 1
    fi

    # Mount the parent so manifest + worktrees are siblings of the repo
    # Tell Claude where the repo is within /src
    echo "Planning: $REPO_NAME"
    echo "  Repo:     $REPO_PATH → /src/$REPO_NAME"
    echo "  Manifest: $PARENT_DIR/cc-manifest.yml"
    echo ""
    PLAN_PROMPT=$(cat "$SCRIPT_DIR/plan-prompt.md")
    PLAN_PROMPT="$PLAN_PROMPT

## This session

The repo to plan for is at \`/src/${REPO_NAME}\`.
Write the manifest to \`/src/cc-manifest.yml\` (above the repo, at the mount root).
Set \`repo: /src/${REPO_NAME}\` in the manifest."

    exec docker run --rm -it \
        -v "$PARENT_DIR":/src \
        "${CLAUDE_MOUNTS[@]}" \
        cctainer:latest \
        --system-prompt "$PLAN_PROMPT"
fi

if [ "${1:-}" = "gws-setup" ]; then
    echo "Setting up Google Workspace GCP project and OAuth client..."
    mkdir -p "$HOME/.config/gws"
    exec docker run --rm -it \
        -v "$HOME/.config/gws":/home/claude/.config/gws \
        --entrypoint gws \
        cctainer:latest \
        auth setup
fi

if [ "${1:-}" = "gws-auth" ]; then
    echo "Logging in to Google Workspace..."
    mkdir -p "$HOME/.config/gws"
    exec docker run --rm -it \
        -v "$HOME/.config/gws":/home/claude/.config/gws \
        --entrypoint gws \
        cctainer:latest \
        auth login
fi

if ! docker image inspect cctainer:latest &>/dev/null; then
    echo "Error: cctainer image not found. Run 'cc build' first." >&2
    exit 1
fi

SRC_DIR="${1:-.}"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
shift 2>/dev/null || true

exec docker run --rm -it \
    -v "$SRC_DIR":/src \
    "${CLAUDE_MOUNTS[@]}" \
    cctainer:latest \
    "$@"
