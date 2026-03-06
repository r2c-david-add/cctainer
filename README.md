# cctainer

A Docker container for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a sandboxed environment. Mount any repo, get an isolated filesystem where Claude can operate with `--dangerously-skip-permissions` without risk to your host system.

## What's inside

- **Node.js 22** (Debian Bookworm)
- **Claude Code** installed globally, pre-configured to skip onboarding
- **Python 3** with venv support, pip, and build tooling
- **Pre-installed CLI tools** via pipx: `semgrep`, `ruff`, `mypy`, `pytest`
- **Utilities**: `git`, `gh`, `curl`, `jq`, `ripgrep`

## Quick start

### Prerequisites

- Docker
- An `ANTHROPIC_API_KEY` environment variable (or pass it inline)

### Using the run script

```bash
# Run Claude Code against a repo
./run.sh ~/code/my-project

# Pass additional Claude args
./run.sh ~/code/my-project -p "find and fix all type errors"

# Interactive mode in the current directory
./run.sh
```

### Using docker directly

```bash
# Build the image
docker build -t cctainer:latest .

# Run with a mounted repo
docker run --rm -it \
  -v ~/code/my-project:/src \
  -e ANTHROPIC_API_KEY \
  cctainer:latest
```

### Using docker compose

```bash
# Set the repo path and run
SRC_DIR=~/code/my-project docker compose run --rm claude
```

## How it works

Your repo is mounted at `/src` inside the container. Claude Code runs as a non-root `claude` user with `--dangerously-skip-permissions` enabled by default. Any changes Claude makes are written directly to the mounted volume (your repo on disk), but system-level side effects (installed packages, modified configs, etc.) are isolated to the container and discarded when it exits.

## Customization

To add more tools or languages, edit the `Dockerfile` and rebuild:

```bash
docker build -t cctainer:latest .
```
