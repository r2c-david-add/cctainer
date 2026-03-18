FROM ubuntu:24.04

# Node.js 22 via NodeSource
RUN apt-get update && apt-get install -y ca-certificates curl gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list

# GitHub CLI repo
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list

# System dependencies
RUN apt-get update && apt-get install -y \
    nodejs \
    git \
    jq \
    ripgrep \
    gh \
    python3 \
    python3-venv \
    python3-pip \
    pipx \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code and Google Workspace CLI globally
RUN npm install -g @anthropic-ai/claude-code @googleworkspace/cli

# Create workspace directory for mounted repos
RUN mkdir -p /src

# Set up a non-root user (claude code works fine as non-root)
RUN useradd -m -s /bin/bash claude
RUN chown -R claude:claude /src

# Mandoline binary for program slicing (used by wtf-sdk enrichment step)
# Pre-downloaded from: gh release download v0.3.2 -R semgrep/mandoline
# Both architectures included; TARGETARCH selects the right one at build time
ARG TARGETARCH
COPY --chmod=755 mandoline-linux-${TARGETARCH:-arm64} /usr/local/bin/mandoline

USER claude
WORKDIR /src

# Python dev tools via pipx (isolated from system python)
RUN pipx install semgrep && \
    pipx install ruff && \
    pipx install mypy && \
    pipx install pytest

# Create a venv for wtf-sdk and workflow dependencies
RUN python3 -m venv /home/claude/.wtf-venv

# Make pipx binaries and wtf venv available
ENV PATH="/home/claude/.wtf-venv/bin:/home/claude/.local/bin:${PATH}"

# Pre-install wtf-sdk dependencies so installs are fast at runtime.
# The actual wtf-sdk is mounted from host at /wtf and installed via pip install -e /wtf
RUN /home/claude/.wtf-venv/bin/pip install --no-cache-dir \
    claude-agent-sdk>=0.1.37 \
    click>=8.1 \
    deepmerge>=2.0 \
    inflection>=0.5 \
    jinja2>=3.1 \
    kubernetes>=28.0 \
    metaflow>=2.19.19 \
    opentelemetry-api>=1.20 \
    opentelemetry-exporter-otlp-proto-http>=1.20 \
    opentelemetry-sdk>=1.20 \
    pydantic-ai>=1.66.0

# Auth is via ANTHROPIC_API_KEY env var at runtime.
# ~/.claude is created for Claude Code's internal use (not mounted from host
# to avoid write contention when running concurrent containers).
# Mark all directories as safe for git (wtf-sdk clones to /tmp, semgrep ci
# needs git access in the cloned repo and sometimes in /src)
RUN git config --global --add safe.directory '*'

RUN mkdir -p /home/claude/.claude && \
    echo '{"hasCompletedOnboarding": true, "acceptedTerms": true}' > /home/claude/.claude/settings.json

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
