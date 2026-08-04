terraform {
  required_version = ">= 1.9"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.0"
    }
  }
}

provider "coder" {}
provider "kubernetes" {}

# Container Forge is deliberately separate from the general Linux/agent/GPU
# template. Its only job is authoring, building, and exporting Linux/amd64
# container images for offline Docker hosts.

variable "namespace" {
  type        = string
  description = "Kubernetes namespace used for Coder workspaces."
  default     = "coder-forge"
}

variable "workspace_image" {
  type        = string
  description = "Non-root Coder development image used by the interactive workspace."
  default     = "codercom/example-base:ubuntu"
}

variable "kaniko_image" {
  type        = string
  description = "Pinned Kaniko image used by the disposable builder pod. Keep the Alpine variant because the idle wrapper requires /bin/sh."
  default     = "ghcr.io/osscontainertools/kaniko:v1.28.2-alpine@sha256:44f90ae1ba366aeedbd0f2d56dbe246354553e47904338dd9321a41a44bea9ff"
}

variable "kubectl_version" {
  type        = string
  description = "kubectl client installed into the workspace for narrowly scoped builder-pod access."
  default     = "v1.35.2"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubectl_version))
    error_message = "kubectl_version must be a full version such as v1.35.2."
  }
}

variable "build_node" {
  type        = string
  description = "Exact Kubernetes hostname that holds both the interactive workspace and builder. Pinning is required because the two pods share ReadWriteOnce volumes."
  default     = "precision-7810-01"

  validation {
    condition     = trimspace(var.build_node) != ""
    error_message = "build_node cannot be empty."
  }
}

variable "github_repositories_json" {
  type        = string
  description = "JSON repository catalog generated at publish time. Keep private repository names out of Git."
  default     = "[]"

  validation {
    condition = can(alltrue([
      for repo in jsondecode(var.github_repositories_json) :
      trimspace(repo.name) != "" &&
      can(regex("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\.git$", repo.url)) &&
      contains(["private", "public"], repo.visibility)
    ])) && can(length(jsondecode(var.github_repositories_json)) <= 63)
    error_message = "github_repositories_json must contain at most 63 GitHub repositories with name, .git URL, and private/public visibility fields."
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  github_repositories = jsondecode(var.github_repositories_json)
  storage_classes = {
    fast      = "longhorn-fast"
    resilient = "longhorn-resilient"
    bulk      = "longhorn-bulk"
  }
}

data "coder_parameter" "builder_cpu" {
  name         = "builder_cpu"
  display_name = "Builder CPU"
  description  = "Maximum CPU cores used while a container image is building."
  default      = "8"
  mutable      = true

  option {
    name  = "4 cores"
    value = "4"
  }
  option {
    name  = "8 cores"
    value = "8"
  }
  option {
    name  = "12 cores"
    value = "12"
  }
  option {
    name  = "16 cores"
    value = "16"
  }
}

data "coder_parameter" "builder_memory" {
  name         = "builder_memory"
  display_name = "Builder memory"
  description  = "Maximum RAM used by the disposable image-builder pod."
  default      = "24"
  mutable      = true

  option {
    name  = "8 GiB"
    value = "8"
  }
  option {
    name  = "16 GiB"
    value = "16"
  }
  option {
    name  = "24 GiB"
    value = "24"
  }
  option {
    name  = "32 GiB"
    value = "32"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Projects and exports"
  description  = "Persistent capacity in GiB for build contexts, Docker archives, logs, and AI-agent state. Large PyTorch/CUDA archives can consume tens of GiB each."
  type         = "number"
  default      = "200"
  mutable      = false

  validation {
    min = 80
    max = 500
  }
}

data "coder_parameter" "cache_disk_size" {
  name         = "cache_disk_size"
  display_name = "Builder cache"
  description  = "Disposable Kaniko base-image cache in GiB. This volume is not backed up."
  type         = "number"
  default      = "120"
  mutable      = false

  validation {
    min = 40
    max = 500
  }
}

data "coder_parameter" "storage_tier" {
  name         = "storage_tier"
  display_name = "Storage tier"
  description  = "Bulk is appropriate for large export archives; fast is better for repeated builds."
  default      = "bulk"
  mutable      = false

  option {
    name  = "Bulk HDD · 1 replica + backup"
    value = "bulk"
  }
  option {
    name  = "Fast SSD · 2 replicas"
    value = "fast"
  }
  option {
    name  = "Resilient · 3 replicas"
    value = "resilient"
  }
}

data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "Container project"
  description  = "Clone a Dockerfile repository, or start with an empty project and let an AI agent scaffold it."
  type         = "string"
  form_type    = "dropdown"
  default      = "__empty_project__"
  mutable      = true
  icon         = "/icon/github.svg"

  option {
    name        = "Empty container project"
    value       = "__empty_project__"
    description = "Start without cloning a repository."
    icon        = "/icon/folder.svg"
  }

  dynamic "option" {
    for_each = local.github_repositories

    content {
      name  = option.value.name
      value = option.value.url
      description = join(" · ", compact([
        title(option.value.visibility),
        option.value.archived ? "Archived (read-only)" : "",
        option.value.fork ? "Fork" : "",
        trimspace(option.value.description),
      ]))
      icon = "/icon/github.svg"
    }
  }
}

locals {
  workspace_name = "coder-${data.coder_workspace.me.id}"
  builder_name   = "${local.workspace_name}-builder"
  builder_pod    = "${local.builder_name}-0"
  git_repo_url   = data.coder_parameter.git_repo.value == "__empty_project__" ? "" : trimsuffix(trimspace(data.coder_parameter.git_repo.value), "/")
  git_repo_set   = local.git_repo_url != ""
  git_repo_name  = local.git_repo_set ? trimsuffix(basename(local.git_repo_url), ".git") : ""
  workspace_dir  = local.git_repo_set ? "/home/coder/project/${local.git_repo_name}" : "/home/coder/project"
  node_selector = {
    "kubernetes.io/hostname" = var.build_node
  }
  exports_base_path = format(
    "/@%s/%s.main/apps/exports",
    data.coder_workspace_owner.me.name,
    data.coder_workspace.me.name,
  )
  workspace_environment = {
    "PATH"                  = "/home/coder/.local/bin:/home/coder/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "FORGE_NAMESPACE"       = var.namespace
    "FORGE_BUILDER_POD"     = local.builder_pod
    "FORGE_KANIKO_IMAGE"    = var.kaniko_image
    "FORGE_PLATFORM"        = "linux/amd64"
    "FORGE_WORKSPACE_ID"    = data.coder_workspace.me.id
    "FORGE_WORKSPACE_NAME"  = data.coder_workspace.me.name
    "FORGE_EXPORTS"         = "/home/coder/exports"
  }
}

data "coder_external_auth" "github" {
  count = local.git_repo_set ? 1 : 0
  id    = "github"
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  startup_script = <<-EOT
    set -eu

    mkdir -p /home/coder/project \
      /home/coder/exports \
      /home/coder/.local/bin \
      /home/coder/.local/lib \
      /home/coder/.local/share/filebrowser \
      /home/coder/.docker

    zellij_version="0.44.3"
    zellij_checksum="a675b0106263113b9cb8f028649bad05c5d2283331fa62b2b36dd275aeaaa4d3"
    if ! /home/coder/.local/bin/zellij --version 2>/dev/null | grep -Fqx "zellij $zellij_version"; then
      zellij_dir="$(mktemp -d /tmp/olympus-zellij.XXXXXX)"
      curl --retry 5 --retry-delay 3 --fail --retry-all-errors -L \
        -o "$zellij_dir/zellij.tar.gz" \
        "https://github.com/zellij-org/zellij/releases/download/v$zellij_version/zellij-no-web-x86_64-unknown-linux-musl.tar.gz"
      tar -xzf "$zellij_dir/zellij.tar.gz" -C "$zellij_dir" zellij
      printf '%s  %s\n' "$zellij_checksum" "$zellij_dir/zellij" | sha256sum -c -
      install -m 0755 "$zellij_dir/zellij" /home/coder/.local/bin/zellij
      rm -rf "$zellij_dir"
    fi

    cat > /home/coder/.local/bin/olympus-session <<'SESSION_HELPER'
    #!/bin/bash
    set -euo pipefail
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
      echo "Usage: olympus-session SESSION WORKDIR [COMMAND]" >&2
      exit 2
    fi
    session="$1"
    workdir="$2"
    shift 2
    if zellij list-sessions --no-formatting --short 2>/dev/null | grep -Fqx "$session"; then
      exec zellij attach "$session"
    fi
    if [ "$#" -eq 0 ]; then
      layout="layout { pane cwd=\"$workdir\"; }"
    else
      command="$1"
      layout="layout { pane command=\"$command\" { cwd \"$workdir\"; close_on_exit true; } }"
    fi
    exec zellij --session "$session" --layout-string "$layout"
    SESSION_HELPER
    chmod +x /home/coder/.local/bin/olympus-session

    touch /home/coder/.profile
    grep -Fqx 'export PATH="/home/coder/.local/bin:$PATH"' /home/coder/.profile || \
      printf '%s\n' 'export PATH="/home/coder/.local/bin:$PATH"' >> /home/coder/.profile

    if command -v git >/dev/null 2>&1; then
      git config --global credential.useHttpPath true
      git config --global push.autoSetupRemote true
    fi

    kubectl_version='${var.kubectl_version}'
    kubectl_marker="/home/coder/.local/share/kubectl-version"
    installed_kubectl_version="$(cat "$kubectl_marker" 2>/dev/null || true)"
    if [ ! -x /home/coder/.local/bin/kubectl ] || [ "$installed_kubectl_version" != "$kubectl_version" ]; then
      kubectl_tmp="$(mktemp /tmp/kubectl.XXXXXX)"
      kubectl_checksum_tmp="$(mktemp /tmp/kubectl.sha256.XXXXXX)"
      curl --retry 5 --retry-delay 3 --fail --retry-all-errors -L \
        -o "$kubectl_tmp" \
        "https://dl.k8s.io/release/$kubectl_version/bin/linux/amd64/kubectl"
      curl --retry 5 --retry-delay 3 --fail --retry-all-errors -L \
        -o "$kubectl_checksum_tmp" \
        "https://dl.k8s.io/release/$kubectl_version/bin/linux/amd64/kubectl.sha256"
      printf '%s  %s\n' "$(cat "$kubectl_checksum_tmp")" "$kubectl_tmp" | sha256sum -c -
      install -m 0755 "$kubectl_tmp" /home/coder/.local/bin/kubectl
      printf '%s\n' "$kubectl_version" > "$kubectl_marker"
      rm -f "$kubectl_tmp" "$kubectl_checksum_tmp"
    fi

    cat > /home/coder/.local/bin/container-build <<'PY'
    #!/usr/bin/env python3
    """Build one Docker-compatible linux/amd64 archive in the disposable Kaniko pod."""

    import argparse
    import datetime as dt
    import hashlib
    import json
    import os
    from pathlib import Path
    import re
    import shutil
    import subprocess
    import sys
    import threading
    import time


    HOME = Path("/home/coder").resolve()
    EXPORTS = Path(os.environ.get("FORGE_EXPORTS", "/home/coder/exports")).resolve()
    NAMESPACE = os.environ["FORGE_NAMESPACE"]
    BUILDER_POD = os.environ["FORGE_BUILDER_POD"]
    PLATFORM = os.environ.get("FORGE_PLATFORM", "linux/amd64")


    def fail(message: str) -> "None":
        print(f"container-build: {message}", file=sys.stderr)
        raise SystemExit(2)


    def beneath_home(path: Path, label: str) -> Path:
        resolved = path.expanduser().resolve()
        try:
            resolved.relative_to(HOME)
        except ValueError:
            fail(f"{label} must live under {HOME}; the builder only mounts the workspace volume")
        return resolved


    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(command, text=True, check=True, **kwargs)


    parser = argparse.ArgumentParser(
        description="Build a Docker-loadable archive and place its complete offline handoff bundle in Exports.",
        epilog=(
            "Example: container-build opencode-scif:1.0 . -f Dockerfile "
            "--build-arg OPENCODE_VERSION=latest"
        ),
    )
    parser.add_argument("image", help="Image reference stored inside the archive, such as opencode-scif:1.0")
    parser.add_argument("context", nargs="?", default=".", help="Build context under /home/coder (default: current directory)")
    parser.add_argument("-f", "--file", default="Dockerfile", help="Dockerfile path, absolute or relative to the context")
    parser.add_argument("--build-arg", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--target", help="Optional final Dockerfile stage")
    parser.add_argument("--secret", action="append", default=[], help="Kaniko secret specification; repeat as needed")
    parser.add_argument("--label", action="append", default=[], help="Additional image label; repeat as needed")
    parser.add_argument("--snapshot-mode", choices=("full", "redo"), default="full")
    parser.add_argument("--reproducible", action="store_true", help="Strip timestamps from the produced image")
    parser.add_argument("--no-cache", action="store_true", help="Do not read the warmed base-image cache")
    parser.add_argument("--timeout", type=int, default=21600, help="Maximum build duration in seconds (default: 21600)")
    parser.add_argument("--verbosity", choices=("error", "warn", "info", "debug", "trace"), default="info")
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/@-]*", args.image):
        fail("image reference contains unsupported characters")
    if args.timeout < 60 or args.timeout > 86400:
        fail("--timeout must be between 60 and 86400 seconds")

    context = beneath_home(Path(args.context), "build context")
    if not context.is_dir():
        fail(f"build context is not a directory: {context}")

    dockerfile_candidate = Path(args.file)
    if not dockerfile_candidate.is_absolute():
        dockerfile_candidate = context / dockerfile_candidate
    dockerfile = beneath_home(dockerfile_candidate, "Dockerfile")
    if not dockerfile.is_file():
        fail(f"Dockerfile does not exist: {dockerfile}")

    safe_name = re.sub(r"[^A-Za-z0-9._-]+", "_", args.image).strip("._-") or "container"
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    export_dir = EXPORTS / f"{safe_name}--{stamp}"
    export_dir.mkdir(mode=0o775, parents=True, exist_ok=False)
    archive = export_dir / f"{safe_name}.docker.tar"
    partial = export_dir / f".{safe_name}.docker.tar.partial"
    log_path = export_dir / "build.log"

    kaniko_args = [
        "/kaniko/executor",
        f"--dockerfile={dockerfile}",
        f"--context=dir://{context}",
        f"--destination={args.image}",
        f"--custom-platform={PLATFORM}",
        f"--tar-path={partial}",
        "--no-push",
        "--no-push-cache",
        f"--cache={'false' if args.no_cache else 'true'}",
        "--cache-dir=/kaniko/cache",
        "--compressed-caching=false",
        "--cleanup=true",
        "--image-download-retry=3",
        f"--snapshot-mode={args.snapshot_mode}",
        f"--verbosity={args.verbosity}",
        "--log-format=text",
        "--log-timestamp=true",
    ]
    if args.target:
        kaniko_args.append(f"--target={args.target}")
    if args.reproducible:
        kaniko_args.append("--reproducible=true")
    kaniko_args.extend(f"--build-arg={value}" for value in args.build_arg)
    kaniko_args.extend(f"--secret={value}" for value in args.secret)
    kaniko_args.extend(f"--label={value}" for value in args.label)

    kubectl = shutil.which("kubectl") or "/home/coder/.local/bin/kubectl"
    base = [kubectl, "-n", NAMESPACE]

    print(f"Waiting for disposable builder pod {BUILDER_POD} ...")
    ready_deadline = time.monotonic() + 180
    while time.monotonic() < ready_deadline:
        status_result = subprocess.run(
            base + ["get", f"pod/{BUILDER_POD}", "-o", "json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if status_result.returncode == 0:
            status = json.loads(status_result.stdout)
            conditions = status.get("status", {}).get("conditions", [])
            if any(
                condition.get("type") == "Ready" and condition.get("status") == "True"
                for condition in conditions
            ):
                break
        time.sleep(2)
    else:
        fail(f"builder pod did not become ready within 180 seconds: {BUILDER_POD}")

    command = base + ["exec", BUILDER_POD, "--"] + kaniko_args
    started = dt.datetime.now(dt.timezone.utc)
    succeeded = False
    process: subprocess.Popen[str] | None = None
    timed_out = threading.Event()
    timer: threading.Timer | None = None

    try:
        with log_path.open("w", encoding="utf-8") as log:
            print(f"Building {args.image} for {PLATFORM}")
            print(f"Context: {context}")
            print(f"Dockerfile: {dockerfile}")
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            def terminate_for_timeout() -> None:
                if process is not None and process.poll() is None:
                    timed_out.set()
                    process.terminate()

            timer = threading.Timer(args.timeout, terminate_for_timeout)
            timer.daemon = True
            timer.start()
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                log.write(line)
            return_code = process.wait()
            timer.cancel()
            if timed_out.is_set():
                fail(f"build exceeded {args.timeout} seconds")
            if return_code != 0:
                raise subprocess.CalledProcessError(return_code, command)
        succeeded = True
    except subprocess.CalledProcessError as error:
        print(f"Build failed with exit code {error.returncode}; see {log_path}", file=sys.stderr)
        raise SystemExit(error.returncode)
    except KeyboardInterrupt:
        if process and process.poll() is None:
            process.terminate()
        print("\nBuild cancelled; recycling builder pod.", file=sys.stderr)
        raise SystemExit(130)
    finally:
        if timer is not None:
            timer.cancel()
        subprocess.run(
            base + ["delete", f"pod/{BUILDER_POD}", "--wait=false", "--ignore-not-found=true"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if not succeeded:
            partial.unlink(missing_ok=True)

    if not partial.is_file() or partial.stat().st_size == 0:
        fail("builder reported success but did not produce a Docker archive")
    partial.rename(archive)

    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    sha256 = digest.hexdigest()
    (export_dir / "SHA256SUMS").write_text(f"{sha256}  {archive.name}\n", encoding="utf-8")

    finished = dt.datetime.now(dt.timezone.utc)
    source_revision = ""
    try:
        source_revision = run(
            ["git", "-C", str(context), "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    manifest = {
        "archive_format": "docker-save",
        "archive_file": archive.name,
        "archive_sha256": sha256,
        "archive_size_bytes": archive.stat().st_size,
        "builder": os.environ.get("FORGE_KANIKO_IMAGE", "kaniko"),
        "created_at": finished.isoformat(),
        "dockerfile": str(dockerfile),
        "duration_seconds": round((finished - started).total_seconds(), 3),
        "image": args.image,
        "platform": PLATFORM,
        "source_context": str(context),
        "source_revision": source_revision or None,
    }
    (export_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (export_dir / "LOAD-IN-SCIF.txt").write_text(
        "Container Forge offline handoff\n"
        "================================\n\n"
        f"Image: {args.image}\n"
        f"Platform: {PLATFORM}\n"
        f"Archive: {archive.name}\n\n"
        "1. Copy every file in this directory to the approved destination.\n"
        "2. Verify the transfer:\n"
        "   sha256sum -c SHA256SUMS\n\n"
        "3. Load the image into Docker:\n"
        f"   docker load --input {archive.name}\n\n"
        "4. Confirm the tag:\n"
        f"   docker image inspect {args.image}\n",
        encoding="utf-8",
    )

    print("\nBuild complete.")
    print(f"Offline bundle: {export_dir}")
    print(f"Docker archive: {archive}")
    print(f"SHA-256: {sha256}")
    PY
    chmod +x /home/coder/.local/bin/container-build

    cat > /home/coder/.local/bin/container-split <<'SPLIT_HELPER'
    #!/bin/sh
    set -eu
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
      echo "Usage: container-split IMAGE.docker.tar [PART_SIZE]" >&2
      echo "Example: container-split image.docker.tar 3900M" >&2
      exit 2
    fi
    archive="$1"
    part_size="$${2:-3900M}"
    if [ ! -f "$a…3265 tokens truncated…    if [ ! -x /home/coder/.local/bin/agentapi ]; then
      curl --retry 5 --retry-delay 5 --fail --retry-all-errors -L \
        -o /home/coder/.local/bin/agentapi \
        https://github.com/coder/agentapi/releases/download/v0.11.2/agentapi-linux-amd64
      chmod +x /home/coder/.local/bin/agentapi
    fi
  EOT
}

resource "coder_app" "container_shell" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "container-forge"
  display_name = "Container Forge"
  icon         = "/icon/docker.svg"
  group        = "Container Development"
  order        = 1
  open_in      = "slim-window"
  command      = <<-EOT
    #!/bin/bash
    set -e
    export PATH="/home/coder/.local/bin:/home/coder/.opencode/bin:$PATH"
    exec olympus-session container-forge '${local.workspace_dir}'
  EOT
}

resource "coder_app" "exports" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "exports"
  display_name = "Container Exports"
  icon         = "/icon/folder.svg"
  group        = "Container Development"
  order        = 2
  url          = "http://localhost:13339${local.exports_base_path}"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13339${local.exports_base_path}/"
    interval  = 5
    threshold = 12
  }
}

resource "coder_app" "codex" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "codex"
  display_name = "Codex"
  icon         = "/icon/openai.svg"
  group        = "AI Agents"
  order        = 10
  open_in      = "slim-window"
  command      = <<-EOT
    #!/bin/bash
    set -e
    export PATH="/home/coder/.local/bin:$PATH"
    exec olympus-session codex '${local.workspace_dir}' codex
  EOT
}

resource "coder_app" "claude_code" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "claude-code"
  display_name = "Claude Code"
  icon         = "/icon/claude.svg"
  group        = "AI Agents"
  order        = 20
  open_in      = "slim-window"
  command      = <<-EOT
    #!/bin/bash
    set -e
    export PATH="/home/coder/.local/bin:$PATH"
    exec olympus-session claude-code '${local.workspace_dir}' claude
  EOT
}

resource "coder_app" "opencode_cli" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "opencode-cli"
  display_name = "OpenCode CLI"
  icon         = "/icon/opencode.svg"
  group        = "AI Agents"
  order        = 30
  open_in      = "slim-window"
  command      = <<-EOT
    #!/bin/bash
    set -e
    export PATH="/home/coder/.opencode/bin:/home/coder/.local/bin:$PATH"
    exec olympus-session opencode '${local.workspace_dir}' opencode
  EOT
}

resource "coder_app" "reasonix" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "reasonix"
  display_name = "Reasonix"
  icon         = "/icon/terminal.svg"
  group        = "AI Agents"
  order        = 40
  open_in      = "slim-window"
  command      = <<-EOT
    #!/bin/bash
    set -e
    export PATH="/home/coder/.local/bin:$PATH"
    exec olympus-session reasonix '${local.workspace_dir}' reasonix
  EOT
}

resource "coder_app" "github_repository" {
  count        = data.coder_workspace.me.start_count > 0 && local.git_repo_set ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "github-repository"
  display_name = local.git_repo_name
  icon         = "/icon/github.svg"
  group        = "Container Development"
  order        = 5
  external     = true
  url          = local.git_repo_url
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "${local.workspace_name}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"                           = "coder-pvc"
      "app.kubernetes.io/part-of"                        = "coder"
      "com.coder.resource"                               = "true"
      "com.coder.workspace.id"                           = data.coder_workspace.me.id
      "com.coder.workspace.name"                         = data.coder_workspace.me.name
      "com.coder.user.id"                                = data.coder_workspace_owner.me.id
      "com.coder.user.username"                          = data.coder_workspace_owner.me.name
      "olympus.dev/workspace-profile"                    = "container-forge"
      "olympus.dev/data-role"                            = "projects-and-exports"
      "olympus.dev/storage-tier"                         = data.coder_parameter.storage_tier.value
      "recurring-job.longhorn.io/source"                 = "enabled"
      "recurring-job.longhorn.io/coder-workspace-backup" = "enabled"
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = local.storage_classes[data.coder_parameter.storage_tier.value]
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_persistent_volume_claim_v1" "builder_cache" {
  metadata {
    name      = "${local.workspace_name}-builder-cache"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "container-builder-cache"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "com.coder.user.id"             = data.coder_workspace_owner.me.id
      "com.coder.user.username"       = data.coder_workspace_owner.me.name
      "olympus.dev/workspace-profile" = "container-forge"
      "olympus.dev/data-role"         = "disposable-builder-cache"
      "olympus.dev/storage-tier"      = data.coder_parameter.storage_tier.value
    }
  }

  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = local.storage_classes[data.coder_parameter.storage_tier.value]
    resources {
      requests = {
        storage = "${data.coder_parameter.cache_disk_size.value}Gi"
      }
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_service_account_v1" "workspace" {
  metadata {
    name      = "${local.workspace_name}-forge"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "container-forge-service-account"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "olympus.dev/workspace-profile" = "container-forge"
    }
  }

  automount_service_account_token = true
}

# The interactive workspace can only inspect, exec into, and recycle its own
# fixed-name builder pod. It cannot create arbitrary pods, jobs, deployments,
# services, secrets, or exec sessions against another workspace.
resource "kubernetes_role_v1" "builder_control" {
  metadata {
    name      = "${local.workspace_name}-builder-control"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "container-forge-builder-control"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "olympus.dev/workspace-profile" = "container-forge"
    }
  }

  rule {
    api_groups     = [""]
    resources      = ["pods"]
    resource_names = [local.builder_pod]
    verbs          = ["get", "delete"]
  }

  rule {
    api_groups     = [""]
    resources      = ["pods/exec"]
    resource_names = [local.builder_pod]
    verbs          = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "builder_control" {
  metadata {
    name      = "${local.workspace_name}-builder-control"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "container-forge-builder-control"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "olympus.dev/workspace-profile" = "container-forge"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.builder_control.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.workspace.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_deployment_v1" "main" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false

  depends_on = [
    kubernetes_persistent_volume_claim_v1.home,
    kubernetes_service_account_v1.workspace,
    kubernetes_role_binding_v1.builder_control,
  ]

  metadata {
    name      = local.workspace_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "coder-workspace"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "com.coder.user.id"             = data.coder_workspace_owner.me.id
      "com.coder.user.username"       = data.coder_workspace_owner.me.name
      "olympus.dev/workspace-profile" = "container-forge"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "com.coder.workspace.id" = data.coder_workspace.me.id
        "olympus.dev/component"   = "workspace"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"        = "coder-workspace"
          "app.kubernetes.io/part-of"     = "coder"
          "com.coder.resource"            = "true"
          "com.coder.workspace.id"        = data.coder_workspace.me.id
          "com.coder.workspace.name"      = data.coder_workspace.me.name
          "com.coder.user.id"             = data.coder_workspace_owner.me.id
          "com.coder.user.username"       = data.coder_workspace_owner.me.name
          "olympus.dev/workspace-profile" = "container-forge"
          "olympus.dev/component"         = "workspace"
        }
      }

      spec {
        node_selector       = local.node_selector
        service_account_name = kubernetes_service_account_v1.workspace.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "dev"
          image             = var.workspace_image
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", coder_agent.main.init_script]

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          dynamic "env" {
            for_each = local.workspace_environment
            content {
              name  = env.key
              value = env.value
            }
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 1000
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4"
              memory = "8Gi"
            }
          }

          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
            read_only  = false
          }
        }

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "olympus.dev/component"
                    operator = "In"
                    values   = ["workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "builder" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.builder_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "container-forge-builder"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "olympus.dev/workspace-profile" = "container-forge"
      "olympus.dev/component"         = "builder"
    }
  }

  spec {
    cluster_ip = "None"
    selector = {
      "com.coder.workspace.id" = data.coder_workspace.me.id
      "olympus.dev/component"   = "builder"
    }

    port {
      name        = "unused"
      port        = 65534
      target_port = 65534
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_stateful_set_v1" "builder" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false

  depends_on = [
    kubernetes_persistent_volume_claim_v1.home,
    kubernetes_persistent_volume_claim_v1.builder_cache,
    kubernetes_service_v1.builder,
  ]

  metadata {
    name      = local.builder_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"        = "container-forge-builder"
      "app.kubernetes.io/part-of"     = "coder"
      "com.coder.resource"            = "true"
      "com.coder.workspace.id"        = data.coder_workspace.me.id
      "com.coder.workspace.name"      = data.coder_workspace.me.name
      "com.coder.user.id"             = data.coder_workspace_owner.me.id
      "com.coder.user.username"       = data.coder_workspace_owner.me.name
      "olympus.dev/workspace-profile" = "container-forge"
      "olympus.dev/component"         = "builder"
    }
  }

  spec {
    replicas     = 1
    service_name = kubernetes_service_v1.builder[0].metadata[0].name

    selector {
      match_labels = {
        "com.coder.workspace.id" = data.coder_workspace.me.id
        "olympus.dev/component"   = "builder"
      }
    }

    update_strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"        = "container-forge-builder"
          "app.kubernetes.io/part-of"     = "coder"
          "com.coder.resource"            = "true"
          "com.coder.workspace.id"        = data.coder_workspace.me.id
          "com.coder.workspace.name"      = data.coder_workspace.me.name
          "com.coder.user.id"             = data.coder_workspace_owner.me.id
          "com.coder.user.username"       = data.coder_workspace_owner.me.name
          "olympus.dev/workspace-profile" = "container-forge"
          "olympus.dev/component"         = "builder"
        }
      }

      spec {
        node_selector                    = local.node_selector
        automount_service_account_token = false
        termination_grace_period_seconds = 10

        security_context {
          fs_group = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "builder"
          image             = var.kaniko_image
          image_pull_policy = "IfNotPresent"
          command = [
            "/bin/sh",
            "-c",
            "mkdir -p /kaniko/cache/tmp; trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done",
          ]

          env {
            name  = "DOCKER_CONFIG"
            value = "/home/coder/.docker"
          }
          env {
            name  = "TMPDIR"
            value = "/kaniko/cache/tmp"
          }
          env {
            name  = "FF_KANIKO_COPY_AS_ROOT"
            value = "true"
          }
          env {
            name  = "FF_KANIKO_COPY_CHMOD_ON_IMPLICIT_DIRS"
            value = "true"
          }
          env {
            name  = "FF_KANIKO_CHOWN_ON_IMPLICIT_DIRS"
            value = "true"
          }
          env {
            name  = "FF_KANIKO_EXPAND_HEREDOC"
            value = "true"
          }
          env {
            name  = "FF_KANIKO_RUN_HONOR_GROUP"
            value = "true"
          }
          env {
            name  = "FF_KANIKO_UNTAR_SKIP_ROOT"
            value = "true"
          }
          env {
            name  = "FF_KANIKO_RUN_VIA_TINI"
            value = "true"
          }

          security_context {
            allow_privilege_escalation = false
            privileged                 = false
            run_as_user                = 0
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = data.coder_parameter.builder_cpu.value
              memory = "${data.coder_parameter.builder_memory.value}Gi"
            }
          }

          readiness_probe {
            exec {
              command = ["/bin/sh", "-c", "test -x /kaniko/executor"]
            }
            initial_delay_seconds = 2
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 12
          }

          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
            read_only  = false
          }

          volume_mount {
            name       = "builder-cache"
            mount_path = "/kaniko/cache"
            read_only  = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
            read_only  = false
          }
        }

        volume {
          name = "builder-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.builder_cache.metadata[0].name
            read_only  = false
          }
        }
      }
    }
  }
}

resource "coder_metadata" "workspace" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment_v1.main[0].id

  item {
    key   = "Purpose"
    value = "Container image forge"
  }

  item {
    key   = "Target"
    value = "Linux/amd64 Docker archive"
  }

  item {
    key   = "Builder"
    value = var.kaniko_image
  }

  item {
    key   = "Placement"
    value = var.build_node
  }

  item {
    key   = "Builder resources"
    value = "${data.coder_parameter.builder_cpu.value} CPU · ${data.coder_parameter.builder_memory.value} GiB"
  }

  item {
    key   = "Projects and exports"
    value = "${data.coder_parameter.storage_tier.value} · ${data.coder_parameter.home_disk_size.value} GiB"
  }

  item {
    key   = "Builder cache"
    value = "${data.coder_parameter.storage_tier.value} · ${data.coder_parameter.cache_disk_size.value} GiB · disposable"
  }

  item {
    key   = "Repository"
    value = local.git_repo_set ? local.git_repo_url : "Empty container project"
  }

  item {
    key   = "Working directory"
    value = local.workspace_dir
  }
}
