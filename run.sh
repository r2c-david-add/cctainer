#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Usage:
#   ./run.sh [-v /path:/container/path] [/path/to/repo] [extra claude args...]
#   ./run.sh plan [-v /path:/container/path] [/path/to/repo]
#   ./run.sh dispatch <manifest.yml>
#   ./run.sh status <manifest.yml>
#   ./run.sh build
#   ./run.sh gws-setup
#   ./run.sh gws-auth
#
# Examples:
#   ./run.sh ~/code/myproject                                  # mount a specific repo
#   ./run.sh -v ~/code/reference:/ref ~/code/myproject         # with extra read-only mount
#   ./run.sh -v ~/data:/data -v ~/models:/models ~/code/proj   # multiple extra mounts
#   ./run.sh plan -v ~/code/target:/ref ./myproject            # plan with reference code
#   ./run.sh dispatch cc-manifest.yml                          # fan out agents from manifest
#   ./run.sh build                                             # rebuild the image

# Common mounts shared by all modes.
COMMON_MOUNTS=(
    -v "$HOME/.config/gh:/home/claude/.config/gh:ro"
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
    -e "SEMGREP_APP_TOKEN=${SEMGREP_APP_TOKEN:-}"
    -e "CLAUDECODE="
    --tmpfs /tmp:size=2g
)

# Copy ~/.claude.json to a temp file so each container gets its own copy.
# This avoids write contention when running multiple containers concurrently.
copy_claude_json() {
    CLAUDE_JSON_COPY=$(mktemp)
    cp "$HOME/.claude.json" "$CLAUDE_JSON_COPY"
    # Clean up the temp file when this script exits
    trap "rm -f '$CLAUDE_JSON_COPY'" EXIT
}

# Parse -v flags from args, return remaining args in REMAINING_ARGS
# Extra mounts are collected into EXTRA_MOUNTS array
parse_extra_mounts() {
    EXTRA_MOUNTS=()
    REMAINING_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -v)
                shift
                local mount_spec="$1"
                local host_path="${mount_spec%%:*}"
                host_path="$(cd "$host_path" 2>/dev/null && pwd || echo "$host_path")"
                local rest="${mount_spec#*:}"
                EXTRA_MOUNTS+=(-v "${host_path}:${rest}:ro")
                ;;
            *)
                REMAINING_ARGS+=("$1")
                ;;
        esac
        shift
    done
}

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
    parse_extra_mounts "$@"
    set -- "${REMAINING_ARGS[@]}"

    REPO_PATH="${1:-.}"
    REPO_PATH="$(cd "$REPO_PATH" && pwd)"
    REPO_NAME="$(basename "$REPO_PATH")"
    PARENT_DIR="$(dirname "$REPO_PATH")"

    if ! docker image inspect cctainer:latest &>/dev/null; then
        echo "Error: cctainer image not found. Run 'cc build' first." >&2
        exit 1
    fi

    echo "Planning: $REPO_NAME"
    echo "  Repo:     $REPO_PATH → /src/$REPO_NAME"
    echo "  Manifest: $PARENT_DIR/cc-manifest.yml"
    if [ ${#EXTRA_MOUNTS[@]} -gt 0 ]; then
        echo "  Extra:    ${EXTRA_MOUNTS[*]}"
    fi
    echo ""
    PLAN_PROMPT=$(cat "$SCRIPT_DIR/plan-prompt.md")
    PLAN_PROMPT="$PLAN_PROMPT

## This session

The repo to plan for is at \`/src/${REPO_NAME}\`.
Write the manifest to \`/src/cc-manifest.yml\` (above the repo, at the mount root).
Set \`repo: /src/${REPO_NAME}\` in the manifest."

    copy_claude_json
    exec docker run --rm -it \
        -v "$PARENT_DIR":/src \
        -v "$CLAUDE_JSON_COPY:/home/claude/.claude.json" \
        "${COMMON_MOUNTS[@]}" \
        ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
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

# Default: interactive session
parse_extra_mounts "$@"
set -- "${REMAINING_ARGS[@]}"

if ! docker image inspect cctainer:latest &>/dev/null; then
    echo "Error: cctainer image not found. Run 'cc build' first." >&2
    exit 1
fi

SRC_DIR="${1:-.}"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
shift 2>/dev/null || true

copy_claude_json
exec docker run --rm -it \
    -v "$SRC_DIR":/src \
    -v "$CLAUDE_JSON_COPY:/home/claude/.claude.json" \
    "${COMMON_MOUNTS[@]}" \
    ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
    cctainer:latest \
    "$@"
