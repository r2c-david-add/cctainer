#!/usr/bin/env python3
"""
Dispatch parallel Claude Code agents across git worktrees.

Reads a YAML manifest, creates sibling worktrees next to the repo,
launches a cctainer for each with the specified prompt, and
streams status to the terminal.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import deque
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def load_manifest(path: str, repo_override: str = None) -> dict:
    with open(path) as f:
        manifest = yaml.safe_load(f)

    # Resolve container paths (/src/...) to host paths.
    # The manifest sits next to the repo, so /src maps to the manifest's directory.
    repo = manifest["repo"]
    manifest_dir = str(Path(path).resolve().parent)

    if repo_override:
        manifest["repo"] = str(Path(repo_override).resolve())
    elif repo.startswith("/src"):
        # Written inside container — /src is the manifest's parent dir on host
        relative = repo[len("/src"):].lstrip("/")
        if relative:
            manifest["repo"] = os.path.join(manifest_dir, relative)
        else:
            manifest["repo"] = manifest_dir
    else:
        manifest["repo"] = str(Path(os.path.expanduser(repo)).resolve())
    manifest.setdefault("base", "main")

    # Resolve extra mounts — container paths like /ref map from /src-relative host paths
    resolved_mounts = []
    for mount in manifest.get("mounts", []):
        host_path = mount["src"]
        container_path = mount["dst"]
        if host_path.startswith("/src"):
            relative = host_path[len("/src"):].lstrip("/")
            host_path = os.path.join(manifest_dir, relative) if relative else manifest_dir
        else:
            host_path = str(Path(os.path.expanduser(host_path)).resolve())
        resolved_mounts.append({"src": host_path, "dst": container_path})
    manifest["mounts"] = resolved_mounts

    for feat in manifest.get("features", []):
        if "branch" not in feat or "prompt" not in feat:
            print(f"Error: each feature needs 'branch' and 'prompt': {feat}", file=sys.stderr)
            sys.exit(1)

    return manifest


def worktree_path(project_dir: str, repo: str, branch: str) -> str:
    """Worktree inside project dir: project/repo--feat-add-widget"""
    repo_name = os.path.basename(repo)
    branch_suffix = branch.replace("/", "-")
    return os.path.join(project_dir, f"{repo_name}--{branch_suffix}")


def create_worktree(project_dir: str, repo: str, base: str, branch: str) -> str:
    """Create a git worktree inside the project directory, return the path."""
    wt_dir = worktree_path(project_dir, repo, branch)

    if os.path.isdir(wt_dir):
        print(f"  Worktree already exists: {wt_dir}")
        return wt_dir

    # Create branch from base if it doesn't exist
    result = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--verify", branch],
        capture_output=True,
    )
    if result.returncode != 0:
        subprocess.run(
            ["git", "-C", repo, "worktree", "add", "-b", branch, wt_dir, base],
            check=True,
        )
    else:
        subprocess.run(
            ["git", "-C", repo, "worktree", "add", wt_dir, branch],
            check=True,
        )

    return wt_dir


def log_dir_for(project_dir: str) -> str:
    return os.path.join(project_dir, "_logs")


def copy_claude_home(tmp_dir: str, branch: str) -> str:
    """Create a per-container copy of Claude config files.

    Copies ~/.claude.json and relevant ~/.claude/ files (settings, MCP plugins,
    OAuth credentials) into a temp directory. Returns the path to the copy.
    Each container gets its own writable copy to avoid contention.
    """
    home = os.path.expanduser("~")
    suffix = branch.replace("/", "-")
    copy_dir = os.path.join(tmp_dir, f"claude-home-{suffix}")
    os.makedirs(copy_dir, exist_ok=True)

    # ~/.claude.json — top-level auth/subscription
    claude_json = os.path.join(home, ".claude.json")
    if os.path.isfile(claude_json):
        shutil.copy2(claude_json, os.path.join(copy_dir, ".claude.json"))

    # ~/.claude/ internals
    claude_dir = os.path.join(copy_dir, ".claude")
    os.makedirs(claude_dir, exist_ok=True)

    # Settings (always create — needed for onboarding bypass)
    with open(os.path.join(claude_dir, "settings.json"), "w") as f:
        f.write('{"hasCompletedOnboarding": true, "acceptedTerms": true}')

    # MCP OAuth credentials
    creds = os.path.join(home, ".claude", ".credentials.json")
    if os.path.isfile(creds):
        shutil.copy2(creds, os.path.join(claude_dir, ".credentials.json"))

    # MCP auth cache
    auth_cache = os.path.join(home, ".claude", "mcp-needs-auth-cache.json")
    if os.path.isfile(auth_cache):
        shutil.copy2(auth_cache, os.path.join(claude_dir, "mcp-needs-auth-cache.json"))

    # MCP plugin configs
    plugins = os.path.join(home, ".claude", "plugins")
    if os.path.isdir(plugins):
        shutil.copytree(plugins, os.path.join(claude_dir, "plugins"))

    return copy_dir


def launch_container(worktree: str, prompt: str, branch: str, log_path: str,
                     extra_mounts: list, claude_home_copy: str) -> subprocess.Popen:
    """Launch a cctainer in the background with the given prompt."""
    log_file = os.path.join(log_path, f"{branch.replace('/', '-')}.log")
    home = os.path.expanduser("~")

    mount_args = []
    for m in extra_mounts:
        mount_args.extend(["-v", f"{m['src']}:{m['dst']}:ro"])

    claude_mounts = []
    if claude_home_copy:
        claude_json = os.path.join(claude_home_copy, ".claude.json")
        claude_dir = os.path.join(claude_home_copy, ".claude")
        if os.path.isfile(claude_json):
            claude_mounts.extend(["-v", f"{claude_json}:/home/claude/.claude.json"])
        if os.path.isdir(claude_dir):
            claude_mounts.extend(["-v", f"{claude_dir}:/home/claude/.claude"])

    with open(log_file, "w") as log:
        proc = subprocess.Popen(
            [
                "docker", "run", "--rm",
                "--tmpfs", "/tmp:size=2g",
                "-v", f"{worktree}:/src",
                *claude_mounts,
                "-v", f"{home}/.config/gh:/home/claude/.config/gh:ro",
                "-e", f"ANTHROPIC_API_KEY={os.environ.get('ANTHROPIC_API_KEY', '')}",
                "-e", f"SEMGREP_APP_TOKEN={os.environ.get('SEMGREP_APP_TOKEN', '')}",
                "-e", "CLAUDECODE=",
                *mount_args,
                "cctainer:latest",
                "--print", prompt,
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    return proc


def dispatch(manifest_path: str, parallel: int = 4):
    manifest = load_manifest(manifest_path)
    repo = manifest["repo"]
    base = manifest["base"]
    features = manifest["features"]
    mounts = manifest.get("mounts", [])

    # Project dir is the directory containing the manifest
    project_dir = str(Path(manifest_path).resolve().parent)

    logs = log_dir_for(project_dir)
    os.makedirs(logs, exist_ok=True)

    print(f"Project:  {project_dir}")
    print(f"Repo:     {repo}")
    print(f"Base:     {base}")
    print(f"Features: {len(features)}")
    if mounts:
        print(f"Mounts:   {len(mounts)}")
        for m in mounts:
            print(f"  {m['src']} → {m['dst']} (ro)")
    print(f"Logs:     {logs}/")
    print()

    # Create all worktrees first
    print("Creating worktrees...")
    worktrees = {}
    for feat in features:
        branch = feat["branch"]
        wt = create_worktree(project_dir, repo, base, branch)
        worktrees[branch] = wt
        print(f"  {branch} -> {wt}")
    print()

    # Each container gets its own copy of Claude config to avoid write contention
    tmp_dir = tempfile.mkdtemp(prefix="cctainer-")

    # Launch containers with bounded concurrency
    print(f"Launching agents ({parallel} at a time)...")
    print()

    pending = deque(features)
    procs = {}  # branch -> Popen
    completed = set()
    total = len(features)

    while pending or len(completed) < total:
        # Fill up to `parallel` active slots
        while pending and (len(procs) - len(completed)) < parallel:
            feat = pending.popleft()
            branch = feat["branch"]
            prompt = feat["prompt"]
            ch_copy = copy_claude_home(tmp_dir, branch)
            print(f"  Starting: {branch}")
            procs[branch] = launch_container(worktrees[branch], prompt, branch, logs, mounts, ch_copy)

        # Poll running processes
        for branch, proc in procs.items():
            if branch in completed:
                continue
            ret = proc.poll()
            if ret is not None:
                completed.add(branch)
                status = "done" if ret == 0 else f"failed (exit {ret})"
                log_name = branch.replace("/", "-")
                print(f"  [{len(completed)}/{total}] {branch}: {status}  (log: {log_name}.log)")

        if len(completed) < total:
            time.sleep(2)

    # Clean up temp copies of Claude config
    shutil.rmtree(tmp_dir, ignore_errors=True)

    print()
    print("All agents finished.")
    print(f"Worktrees in {project_dir}/")
    print(f"Logs at {logs}/")


def status(manifest_path: str):
    """Show status of running containers and worktree branches."""
    manifest = load_manifest(manifest_path)
    repo = manifest["repo"]
    project_dir = str(Path(manifest_path).resolve().parent)
    logs = log_dir_for(project_dir)

    # Check which containers are still running
    result = subprocess.run(
        ["docker", "ps", "--filter", "ancestor=cctainer:latest", "--format", "{{.ID}}\t{{.Status}}"],
        capture_output=True,
        text=True,
    )
    running = result.stdout.strip()

    print(f"Project: {project_dir}")
    print(f"Running cctainer instances: {len(running.splitlines()) if running else 0}")
    if running:
        print(running)
    print()

    # Show worktree status
    print("Worktrees:")
    for feat in manifest.get("features", []):
        branch = feat["branch"]
        wt = worktree_path(project_dir, repo, branch)
        exists = "exists" if os.path.isdir(wt) else "missing"
        print(f"  {branch}: {exists} ({wt})")
    print()

    # Show log tails
    if os.path.isdir(logs):
        print("Logs:")
        for log_file in sorted(Path(logs).glob("*.log")):
            branch = log_file.stem
            size = log_file.stat().st_size
            last_line = ""
            if size > 0:
                with open(log_file) as f:
                    lines = f.readlines()
                    last_line = lines[-1].strip() if lines else ""
            print(f"  {branch}: {size} bytes")
            if last_line:
                print(f"    {last_line[:120]}")
        print()


def main():
    parser = argparse.ArgumentParser(description="Dispatch parallel Claude Code agents")
    sub = parser.add_subparsers(dest="command", required=True)

    p_dispatch = sub.add_parser("dispatch", help="Launch agents from a manifest")
    p_dispatch.add_argument("manifest", help="Path to YAML manifest file")
    p_dispatch.add_argument("--parallel", "-j", type=int, default=4,
                            help="Max concurrent containers (default: 4)")

    p_status = sub.add_parser("status", help="Check status of running agents")
    p_status.add_argument("manifest", help="Path to YAML manifest file")

    args = parser.parse_args()

    if args.command == "dispatch":
        dispatch(args.manifest, parallel=args.parallel)
    elif args.command == "status":
        status(args.manifest)


if __name__ == "__main__":
    main()
