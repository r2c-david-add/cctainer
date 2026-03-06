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

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

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

# Pre-accept the terms so --dangerously-skip-permissions works non-interactively
RUN mkdir -p /home/claude/.claude && \
    echo '{"hasCompletedOnboarding": true, "acceptedTerms": true}' > /home/claude/.claude/settings.json

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
