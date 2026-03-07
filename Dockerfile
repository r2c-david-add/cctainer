FROM node:22-bookworm

# System dependencies useful for Claude Code workflows
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    ripgrep \
    gh \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    pipx \
    && rm -rf /var/lib/apt/lists/*

# Python dev tooling (installed globally via pipx for the claude user later)
# Also make python3 the default `python`
RUN ln -sf /usr/bin/python3 /usr/bin/python

# Install Claude Code and Google Workspace CLI globally
RUN npm install -g @anthropic-ai/claude-code @googleworkspace/cli

# Create workspace directory for mounted repos
RUN mkdir -p /src

# Set up a non-root user (claude code works fine as non-root)
RUN useradd -m -s /bin/bash claude
RUN chown -R claude:claude /src

USER claude
WORKDIR /src

# Python dev tools via pipx (isolated from system python)
RUN pipx install semgrep && \
    pipx install ruff && \
    pipx install mypy && \
    pipx install pytest

# Make pipx binaries available
ENV PATH="/home/claude/.local/bin:${PATH}"

# ~/.claude is mounted from the host at runtime to provide
# user profile, MCP config, and settings.
# ~/.config/gws is mounted for Google Workspace OAuth tokens.
RUN mkdir -p /home/claude/.claude /home/claude/.config/gws

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
