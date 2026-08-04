#!/usr/bin/env python3
"""Safely fast-forward the canonical Olympus skill checkout from GitHub."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


EXPECTED_REMOTE_PARTS = ("github.com", "link2427/homelab")


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def skip(reason: str) -> int:
    print(f"SKIPPED: {reason}")
    return 0


def main() -> int:
    skill_dir = Path(__file__).resolve().parent.parent

    probe = git(skill_dir, "rev-parse", "--show-toplevel", check=False)
    if probe.returncode != 0:
        return skip("standalone skill copy is not inside a Git checkout")

    repo = Path(probe.stdout.strip()).resolve()
    canonical_dir = (repo / "skills" / "olympus-deploy").resolve()
    if skill_dir != canonical_dir:
        return skip("standalone project copy; refusing to update its repository")

    remote = git(repo, "remote", "get-url", "origin", check=False)
    if remote.returncode != 0:
        return skip("canonical checkout has no origin remote")
    normalized_remote = remote.stdout.strip().lower().removesuffix(".git")
    if not all(part in normalized_remote for part in EXPECTED_REMOTE_PARTS):
        return skip("origin is not the expected link2427/homelab repository")

    branch = git(repo, "branch", "--show-current").stdout.strip()
    if branch != "main":
        return skip(f"checkout is on {branch or 'detached HEAD'}, not main")

    dirty = git(repo, "status", "--porcelain", "--untracked-files=normal").stdout
    if dirty.strip():
        return skip("checkout has local changes")

    before = git(repo, "rev-parse", "HEAD").stdout.strip()
    pull = git(repo, "pull", "--ff-only", "origin", "main", check=False)
    if pull.returncode != 0:
        message = (pull.stderr or pull.stdout).strip().splitlines()
        detail = message[-1] if message else "git pull failed"
        print(f"ERROR: {detail}", file=sys.stderr)
        return 1

    after = git(repo, "rev-parse", "HEAD").stdout.strip()
    if before == after:
        print(f"CURRENT: {after[:12]}")
    else:
        print(f"UPDATED: {before[:12]} -> {after[:12]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
