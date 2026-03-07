#!/usr/bin/env python3
"""
Dispatch parallel Claude Code agents across git worktrees.

Reads a YAML manifest, creates sibling worktrees next to the repo,
launches a cctainer for each with the specified prompt, and
streams status to the terminal.
"""

import argparse
import os
import subprocess
import sys
import time
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

    for feat in manifest.get("features", []):
        if "branch" not in feat or "prompt" not in feat:
            print(f"Error: each feature needs 'branch' and 'prompt': {feat}", file=sys.stderr)
            sys.exit(1)

    return manifest


def worktree_path(repo: str, branch: str) -> str:
    """Sibling worktree: ~/code/my-project--feat-add-widget"""
    repo_name = os.path.basename(repo)
    branch_suffix = branch.replace("/", "-")
    return os.path.join(os.path.dirname(repo), f"{repo_name}--{branch_suffix}")


def create_worktree(repo: str, base: str, branch: str) -> str:
    """Create a git worktree as a sibling directory, return the path."""
    wt_dir = worktree_path(repo, branch)

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


def log_dir_for(repo: str) -> str:
    repo_name = os.path.basename(repo)
    return os.path.join(os.path.dirname(repo), f"{repo_name}--_logs")


def launch_container(worktree: str, prompt: str, branch: str, log_path: str) -> subprocess.Popen:
    """Launch a cctainer in the background with the given prompt."""
    log_file = os.path.join(log_path, f"{branch.replace('/', '-')}.log")
    home = os.path.expanduser("~")

    with open(log_file, "w") as log:
        proc = subprocess.Popen(
            [
                "docker", "run", "--rm",
                "-v", f"{worktree}:/src",
                "-v", f"{home}/.claude.json:/home/claude/.claude.json",
                "-v", f"{home}/.claude:/home/claude/.claude",
                "-v", f"{home}/.config/gh:/home/claude/.config/gh",
                "-v", f"{home}/.config/gws:/home/claude/.config/gws",
                "-e", f"ANTHROPIC_API_KEY={os.environ.get('ANTHROPIC_API_KEY', '')}",
                "cctainer:latest",
                "--print", prompt,
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    return proc


def dispatch(manifest_path: str):
    manifest = load_manifest(manifest_path)
    repo = manifest["repo"]
    base = manifest["base"]
    features = manifest["features"]

    logs = log_dir_for(repo)
    os.makedirs(logs, exist_ok=True)

    print(f"Repo:     {repo}")
    print(f"Base:     {base}")
    print(f"Features: {len(features)}")
    print(f"Logs:     {logs}/")
    print()

    # Create all worktrees first
    print("Creating worktrees...")
    worktrees = {}
    for feat in features:
        branch = feat["branch"]
        wt = create_worktree(repo, base, branch)
        worktrees[branch] = wt
        print(f"  {branch} -> {wt}")
    print()

    # Launch all containers
    print("Launching agents...")
    procs = {}
    for feat in features:
        branch = feat["branch"]
        prompt = feat["prompt"]
        print(f"  {branch}")
        procs[branch] = launch_container(worktrees[branch], prompt, branch, logs)
    print()

    print("Waiting for agents to complete...")
    print()

    completed = set()
    while len(completed) < len(procs):
        for branch, proc in procs.items():
            if branch in completed:
                continue
            ret = proc.poll()
            if ret is not None:
                completed.add(branch)
                status = "done" if ret == 0 else f"failed (exit {ret})"
                log_name = branch.replace("/", "-")
                print(f"  [{len(completed)}/{len(procs)}] {branch}: {status}  (log: {log_name}.log)")
        time.sleep(2)

    print()
    print("All agents finished.")
    print(f"Worktrees are sibling directories next to {repo}")
    print(f"Logs at {logs}/")


def status(manifest_path: str):
    """Show status of running containers and worktree branches."""
    manifest = load_manifest(manifest_path)
    repo = manifest["repo"]
    logs = log_dir_for(repo)

    # Check which containers are still running
    result = subprocess.run(
        ["docker", "ps", "--filter", "ancestor=cctainer:latest", "--format", "{{.ID}}\t{{.Status}}"],
        capture_output=True,
        text=True,
    )
    running = result.stdout.strip()

    print(f"Running cctainer instances: {len(running.splitlines()) if running else 0}")
    if running:
        print(running)
    print()

    # Show worktree status
    print("Worktrees:")
    for feat in manifest.get("features", []):
        branch = feat["branch"]
        wt = worktree_path(repo, branch)
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

    p_status = sub.add_parser("status", help="Check status of running agents")
    p_status.add_argument("manifest", help="Path to YAML manifest file")

    args = parser.parse_args()

    if args.command == "dispatch":
        dispatch(args.manifest)
    elif args.command == "status":
        status(args.manifest)


if __name__ == "__main__":
    main()
