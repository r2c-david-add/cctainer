#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Usage:
#   ./run.sh <path> [path...] [-- extra claude args...]
#   ./run.sh plan <path> [path...]
#   ./run.sh dispatch <manifest.yml> [-j N]
#   ./run.sh status <manifest.yml>
#   ./run.sh build
#   ./run.sh gws-setup
#   ./run.sh gws-auth
#
# The first path is the working directory (/src). Additional paths are
# mounted read-only at /shared/<basename>. Name conflicts get a suffix.
#
# Examples:
#   ./run.sh ~/code/myproject                                    # just the repo
#   ./run.sh ~/code/myproject ~/code/reference ~/data/fixtures   # repo + extras
#   ./run.sh ~/code/myproject ~/code/reference -- -p "compare"   # with claude args
#   ./run.sh plan ~/code/myproject ~/code/reference              # plan with ref code
#   ./run.sh dispatch cc-manifest.yml                            # fan out agents
#   ./run.sh build                                               # rebuild image

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
    trap "rm -f '$CLAUDE_JSON_COPY'" EXIT
}

# Parse paths and -- separator from args.
# First path -> SRC_DIR, additional paths -> SHARED_MOUNTS array,
# anything after -- -> CLAUDE_ARGS array.
parse_paths() {
    SRC_DIR=""
    SHARED_MOUNTS=()
    CLAUDE_ARGS=()

    local paths=()
    local seen_separator=false

    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then
            seen_separator=true
            shift
            continue
        fi
        if $seen_separator; then
            CLAUDE_ARGS+=("$1")
        else
            paths+=("$1")
        fi
        shift
    done

    # First path is the workdir
    if [ ${#paths[@]} -eq 0 ]; then
        SRC_DIR="$(pwd)"
    else
        SRC_DIR="$(cd "${paths[0]}" && pwd)"
    fi

    # Remaining paths become /shared/<name> mounts
    if [ ${#paths[@]} -gt 1 ]; then
        local used_names=" "
        local idx=1
        while [ $idx -lt ${#paths[@]} ]; do
            local resolved
            resolved="$(cd "${paths[$idx]}" && pwd)"
            local name
            name="$(basename "$resolved")"

            # Handle name conflicts by prepending parent dir
            if echo "$used_names" | grep -q " ${name} "; then
                local parent
                parent="$(basename "$(dirname "$resolved")")"
                name="${parent}-${name}"
            fi
            # Last resort: numeric suffix
            local orig_name="$name"
            local suffix=2
            while echo "$used_names" | grep -q " ${name} "; do
                name="${orig_name}-${suffix}"
                suffix=$((suffix + 1))
            done

            used_names="${used_names}${name} "
            SHARED_MOUNTS+=(-v "${resolved}:/shared/${name}:ro")
            idx=$((idx + 1))
        done
    fi
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
    parse_paths "$@"

    REPO_NAME="$(basename "$SRC_DIR")"
    PARENT_DIR="$(dirname "$SRC_DIR")"

    if ! docker image inspect cctainer:latest &>/dev/null; then
        echo "Error: cctainer image not found. Run 'cc build' first." >&2
        exit 1
    fi

    echo "Planning: $REPO_NAME"
    echo "  Repo:     $SRC_DIR → /src/$REPO_NAME"
    echo "  Manifest: $PARENT_DIR/cc-manifest.yml"
    if [ ${#SHARED_MOUNTS[@]} -gt 0 ]; then
        echo "  Shared:   ${SHARED_MOUNTS[*]}"
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
        ${SHARED_MOUNTS[@]+"${SHARED_MOUNTS[@]}"} \
        cctainer:latest \
        --system-prompt "$PLAN_PROMPT" \
        ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
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
parse_paths "$@"

if ! docker image inspect cctainer:latest &>/dev/null; then
    echo "Error: cctainer image not found. Run 'cc build' first." >&2
    exit 1
fi

copy_claude_json
exec docker run --rm -it \
    -v "$SRC_DIR":/src \
    -v "$CLAUDE_JSON_COPY:/home/claude/.claude.json" \
    "${COMMON_MOUNTS[@]}" \
    ${SHARED_MOUNTS[@]+"${SHARED_MOUNTS[@]}"} \
    cctainer:latest \
    ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
