FROM node:22-bookworm

# System dependencies useful for Claude Code workflows
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    ripgrep \
    gh \
    build-essential \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
    libsqlite3-dev libncurses5-dev libffi-dev liblzma-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python 3.12 from source (bookworm only ships 3.11, wtf-sdk needs 3.12+)
ARG PYTHON_VERSION=3.12.8
RUN curl -fsSL https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz | tar xz \
    && cd Python-${PYTHON_VERSION} \
    && ./configure --enable-optimizations --prefix=/usr/local \
    && make -j$(nproc) \
    && make altinstall \
    && cd .. && rm -rf Python-${PYTHON_VERSION} \
    && ln -sf /usr/local/bin/python3.12 /usr/bin/python3 \
    && ln -sf /usr/local/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/local/bin/pip3.12 /usr/bin/pip3 \
    && pip3 install --no-cache-dir pipx

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
RUN mkdir -p /home/claude/.claude

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
