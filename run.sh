#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Usage:
#   ./run.sh <path> [path...] [-- extra claude args...]
#   ./run.sh plan <project> <repo> [path...]
#   ./run.sh dispatch <project>  [-j N]
#   ./run.sh status <project>
#   ./run.sh build
#   ./run.sh gws-setup
#   ./run.sh gws-auth
#
# The first path is the working directory (/src). Additional paths are
# mounted read-only at /shared/<basename>. Name conflicts get a suffix.
#
# Plan creates a project workspace in the current directory:
#   cc plan my-feature ./repo ./reference
#   → ./my-feature/           (project dir)
#   → ./my-feature/repo/      (worktree from ./repo)
#   → ./my-feature/manifest.yml
#   Dispatch creates worktrees as siblings inside the project dir.
#
# Examples:
#   ./run.sh ~/code/myproject                                    # interactive session
#   ./run.sh ~/code/myproject ~/code/reference                   # with extra context
#   ./run.sh plan my-feature ./myproject ./reference              # plan a project
#   ./run.sh dispatch my-feature                                 # fan out agents
#   ./run.sh status my-feature                                   # check progress
#   ./run.sh build                                               # rebuild image

# Common mounts shared by all modes.
COMMON_MOUNTS=(
    -v "$HOME/.config/gh:/home/claude/.config/gh:ro"
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
    -e "SEMGREP_APP_TOKEN=${SEMGREP_APP_TOKEN:-}"
    -e "CLAUDECODE="
    --tmpfs /tmp:size=2g
)

# Create a per-container copy of Claude config files.
# Each container gets its own writable copy to avoid contention when
# running multiple containers concurrently (OAuth token refreshes, etc.).
# Sets CLAUDE_HOME_COPY to the temp directory path.
copy_claude_home() {
    CLAUDE_HOME_COPY=$(mktemp -d "${TMPDIR:-/tmp}/cctainer-claude-XXXXXX")
    trap "rm -rf '$CLAUDE_HOME_COPY'" EXIT

    # ~/.claude.json — top-level auth/subscription
    if [ -f "$HOME/.claude.json" ]; then
        cp "$HOME/.claude.json" "$CLAUDE_HOME_COPY/.claude.json"
    fi

    # ~/.claude/ internals — settings, MCP plugins, OAuth credentials
    mkdir -p "$CLAUDE_HOME_COPY/.claude"
    echo '{"hasCompletedOnboarding": true, "acceptedTerms": true}' \
        > "$CLAUDE_HOME_COPY/.claude/settings.json"
    if [ -f "$HOME/.claude/.credentials.json" ]; then
        cp "$HOME/.claude/.credentials.json" "$CLAUDE_HOME_COPY/.claude/.credentials.json"
    fi
    if [ -f "$HOME/.claude/mcp-needs-auth-cache.json" ]; then
        cp "$HOME/.claude/mcp-needs-auth-cache.json" "$CLAUDE_HOME_COPY/.claude/mcp-needs-auth-cache.json"
    fi
    if [ -d "$HOME/.claude/plugins" ]; then
        cp -r "$HOME/.claude/plugins" "$CLAUDE_HOME_COPY/.claude/plugins"
    fi
}

# Build /shared mounts from a list of paths (bash 3.2 compatible).
# Sets SHARED_MOUNTS array.
build_shared_mounts() {
    SHARED_MOUNTS=()
    local used_names=" "
    while [ $# -gt 0 ]; do
        local resolved
        resolved="$(cd "$1" && pwd)"
        local name
        name="$(basename "$resolved")"

        if echo "$used_names" | grep -q " ${name} "; then
            local parent
            parent="$(basename "$(dirname "$resolved")")"
            name="${parent}-${name}"
        fi
        local orig_name="$name"
        local suffix=2
        while echo "$used_names" | grep -q " ${name} "; do
            name="${orig_name}-${suffix}"
            suffix=$((suffix + 1))
        done

        used_names="${used_names}${name} "
        SHARED_MOUNTS+=(-v "${resolved}:/shared/${name}:ro")
        shift
    done
}

# Parse paths and -- separator from positional args.
# Sets SRC_DIR, SHARED_MOUNTS, CLAUDE_ARGS.
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

    if [ ${#paths[@]} -eq 0 ]; then
        SRC_DIR="$(pwd)"
    else
        SRC_DIR="$(cd "${paths[0]}" && pwd)"
    fi

    if [ ${#paths[@]} -gt 1 ]; then
        local extras=()
        local idx=1
        while [ $idx -lt ${#paths[@]} ]; do
            extras+=("${paths[$idx]}")
            idx=$((idx + 1))
        done
        build_shared_mounts "${extras[@]}"
    fi
}

if [ "${1:-}" = "build" ]; then
    echo "Building cctainer image..."
    exec docker build -t cctainer:latest "$SCRIPT_DIR"
fi

if [ "${1:-}" = "dispatch" ]; then
    shift
    PROJECT_NAME="${1:?Usage: cc dispatch <project> [-j N]}"
    shift

    # Find project dir — check current dir, then look for it
    if [ -d "./$PROJECT_NAME" ] && [ -f "./$PROJECT_NAME/manifest.yml" ]; then
        PROJECT_DIR="$(cd "./$PROJECT_NAME" && pwd)"
    else
        echo "Error: project '$PROJECT_NAME' not found (no ./$PROJECT_NAME/manifest.yml)" >&2
        exit 1
    fi

    exec "$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/dispatch.py" dispatch "$PROJECT_DIR/manifest.yml" "$@"
fi

if [ "${1:-}" = "status" ]; then
    shift
    PROJECT_NAME="${1:?Usage: cc status <project>}"

    if [ -d "./$PROJECT_NAME" ] && [ -f "./$PROJECT_NAME/manifest.yml" ]; then
        PROJECT_DIR="$(cd "./$PROJECT_NAME" && pwd)"
    else
        echo "Error: project '$PROJECT_NAME' not found (no ./$PROJECT_NAME/manifest.yml)" >&2
        exit 1
    fi

    exec "$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/dispatch.py" status "$PROJECT_DIR/manifest.yml"
fi

if [ "${1:-}" = "plan" ]; then
    shift

    # Parse: cc plan <project> <repo> [extra-paths...] [-- claude-args...]
    PROJECT_NAME=""
    REPO_PATH=""
    EXTRA_PATHS=()
    CLAUDE_ARGS=()
    local_seen_separator=false

    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then
            local_seen_separator=true
            shift
            continue
        fi
        if $local_seen_separator; then
            CLAUDE_ARGS+=("$1")
        elif [ -z "$PROJECT_NAME" ]; then
            PROJECT_NAME="$1"
        elif [ -z "$REPO_PATH" ]; then
            REPO_PATH="$1"
        else
            EXTRA_PATHS+=("$1")
        fi
        shift
    done

    if [ -z "$PROJECT_NAME" ] || [ -z "$REPO_PATH" ]; then
        echo "Usage: cc plan <project> <repo> [extra-paths...] [-- claude-args...]" >&2
        exit 1
    fi

    REPO_PATH="$(cd "$REPO_PATH" && pwd)"
    REPO_NAME="$(basename "$REPO_PATH")"
    PROJECT_DIR="$(pwd)/$PROJECT_NAME"

    if ! docker image inspect cctainer:latest &>/dev/null; then
        echo "Error: cctainer image not found. Run 'cc build' first." >&2
        exit 1
    fi

    # Scaffold project directory
    if [ -d "$PROJECT_DIR" ]; then
        echo "Project directory already exists: $PROJECT_DIR"
        if [ ! -d "$PROJECT_DIR/$REPO_NAME" ]; then
            echo "Error: expected repo worktree at $PROJECT_DIR/$REPO_NAME" >&2
            exit 1
        fi
    else
        echo "Creating project: $PROJECT_NAME"
        mkdir -p "$PROJECT_DIR"

        # Create a worktree of the repo inside the project dir
        echo "  Worktree: $REPO_PATH → $PROJECT_DIR/$REPO_NAME"
        git -C "$REPO_PATH" worktree add "$PROJECT_DIR/$REPO_NAME" HEAD 2>/dev/null || \
            git -C "$REPO_PATH" worktree add --detach "$PROJECT_DIR/$REPO_NAME" HEAD
    fi

    # Build shared mounts for extra paths
    if [ ${#EXTRA_PATHS[@]} -gt 0 ]; then
        build_shared_mounts "${EXTRA_PATHS[@]}"
    else
        SHARED_MOUNTS=()
    fi

    echo "  Project:  $PROJECT_DIR"
    echo "  Repo:     $PROJECT_DIR/$REPO_NAME → /src/$REPO_NAME"
    echo "  Manifest: $PROJECT_DIR/manifest.yml → /src/manifest.yml"
    if [ ${#SHARED_MOUNTS[@]} -gt 0 ]; then
        echo "  Shared:   ${SHARED_MOUNTS[*]}"
    fi
    echo ""

    PLAN_PROMPT=$(cat "$SCRIPT_DIR/plan-prompt.md")
    PLAN_PROMPT="$PLAN_PROMPT

## This session

The project directory is mounted at \`/src\`.
The repo to plan for is at \`/src/${REPO_NAME}\`.
Write the manifest to \`/src/manifest.yml\`.
Set \`repo: /src/${REPO_NAME}\` in the manifest."

    copy_claude_home
    exec docker run --rm -it \
        -v "$PROJECT_DIR":/src \
        -v "$CLAUDE_HOME_COPY/.claude.json:/home/claude/.claude.json" \
        -v "$CLAUDE_HOME_COPY/.claude:/home/claude/.claude" \
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

copy_claude_home
exec docker run --rm -it \
    -v "$SRC_DIR":/src \
    -v "$CLAUDE_HOME_COPY/.claude.json:/home/claude/.claude.json" \
    -v "$CLAUDE_HOME_COPY/.claude:/home/claude/.claude" \
    "${COMMON_MOUNTS[@]}" \
    ${SHARED_MOUNTS[@]+"${SHARED_MOUNTS[@]}"} \
    cctainer:latest \
    ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}
