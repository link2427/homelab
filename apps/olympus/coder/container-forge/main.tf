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
    ])) && can(length(jsondecode(var.github_repositories_json)) <= 61)
    error_message = "github_repositories_json must contain at most 61 GitHub repositories with name, .git URL, and private/public visibility fields."
  }
}

variable "github_owner" {
  type        = string
  description = "GitHub account that owns repositories created or forked from the workspace form."
  default     = "link2427"

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_owner))
    error_message = "github_owner must be a valid GitHub account name."
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
  forge_presets = {
    quick = {
      name         = "Quick Image"
      description  = "Small Dockerfiles, utility images, and rapid experiments."
      icon         = "/icon/docker.svg"
      default      = false
      cpu          = "4"
      memory       = "8"
      home_disk    = "80"
      cache_disk   = "40"
      storage_tier = "bulk"
      node         = "precision-7810-01"
    }
    standard = {
      name         = "Standard Forge"
      description  = "Balanced capacity for normal offline image bundles."
      icon         = "/icon/container.svg"
      default      = false
      cpu          = "8"
      memory       = "24"
      home_disk    = "200"
      cache_disk   = "120"
      storage_tier = "bulk"
      node         = "precision-7810-01"
    }
    fast = {
      name         = "Fast Iteration"
      description  = "SSD-backed caching on Atlas for repeated image rebuilds."
      icon         = "/icon/code.svg"
      default      = false
      cpu          = "12"
      memory       = "24"
      home_disk    = "80"
      cache_disk   = "40"
      storage_tier = "fast"
      node         = "atlas"
    }
    cuda = {
      name         = "Large CUDA Image"
      description  = "Atlas compute and roomy bulk storage for multi-stage CUDA/PyTorch images."
      icon         = "/icon/pytorch.svg"
      default      = false
      cpu          = "24"
      memory       = "40"
      home_disk    = "350"
      cache_disk   = "250"
      storage_tier = "bulk"
      node         = "atlas"
    }
  }
}

data "coder_parameter" "builder_cpu" {
  name         = "builder_cpu"
  display_name = "Builder CPU"
  description  = "Maximum CPU cores used while a container image is building."
  type         = "number"
  form_type    = "slider"
  default      = "8"
  mutable      = true
  order        = 20
  icon         = "/icon/k8s.svg"

  validation {
    min = 2
    max = 48
  }
}

data "coder_parameter" "builder_memory" {
  name         = "builder_memory"
  display_name = "Builder memory"
  description  = "Maximum RAM used by the disposable image-builder pod."
  type         = "number"
  form_type    = "slider"
  default      = "24"
  mutable      = true
  order        = 30
  icon         = "/icon/memory.svg"

  validation {
    min = 4
    max = 48
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Projects and exports"
  description  = "Persistent capacity in GiB for build contexts, Docker archives, logs, and AI-agent state. Large PyTorch/CUDA archives can consume tens of GiB each."
  type         = "number"
  form_type    = "slider"
  default      = "200"
  mutable      = false
  order        = 40
  icon         = "/icon/database.svg"

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
  form_type    = "slider"
  default      = "120"
  mutable      = false
  order        = 50
  icon         = "/icon/database.svg"

  validation {
    min = 40
    max = 500
  }
}

data "coder_parameter" "storage_tier" {
  name         = "storage_tier"
  display_name = "Storage tier"
  description  = "Bulk is appropriate for large export archives; fast is better for repeated builds."
  form_type    = "radio"
  default      = "bulk"
  mutable      = false
  order        = 60
  icon         = "/icon/database.svg"

  option {
    name        = "Bulk HDD · 1 replica + backup"
    value       = "bulk"
    description = "Recommended for large archives and caches where capacity matters most."
    icon        = "/icon/database.svg"
  }
  option {
    name        = "Fast SSD · 2 replicas"
    value       = "fast"
    description = "Faster rebuild loops, but each GiB consumes two GiB of SSD capacity."
    icon        = "/icon/database.svg"
  }
  option {
    name        = "Resilient · 3 replicas"
    value       = "resilient"
    description = "Maximum redundancy; use only for small, important projects."
    icon        = "/icon/database.svg"
  }
}

data "coder_parameter" "forge_node" {
  name         = "forge_node"
  display_name = "Build host"
  description  = "Pins the interactive workspace and its builder to one node so they can safely share ReadWriteOnce volumes."
  form_type    = "radio"
  default      = var.build_node
  mutable      = true
  order        = 70
  icon         = "/icon/node.svg"

  option {
    name        = "Precision 7810 · 8 CPU / 31 GiB"
    value       = "precision-7810-01"
    description = "Default bulk-storage build host."
    icon        = "/icon/node.svg"
  }

  option {
    name        = "Atlas · 72 CPU / 62 GiB"
    value       = "atlas"
    description = "Best for large parallel builds and high-memory image assembly."
    icon        = "/icon/node.svg"
  }

  option {
    name        = "Precision 5810 · 12 CPU / 15 GiB"
    value       = "precision-5810-01"
    description = "Suitable for smaller builds when the other hosts are busy."
    icon        = "/icon/node.svg"
  }
}

data "coder_parameter" "preview_port" {
  name         = "preview_port"
  display_name = "Primary web preview"
  description  = "Port used by the Web Preview card for documentation sites or test UIs authored in this workspace."
  type         = "number"
  form_type    = "dropdown"
  default      = "3000"
  mutable      = true
  order        = 80
  icon         = "/icon/code.svg"

  option {
    name        = "3000 · React / Node"
    value       = "3000"
    description = "Common React, Next.js, Express, and Node development port."
    icon        = "/icon/code.svg"
  }
  option {
    name        = "5173 · Vite"
    value       = "5173"
    description = "Default Vite development server port."
    icon        = "/icon/code.svg"
  }
  option {
    name        = "8000 · Python"
    value       = "8000"
    description = "Common Python development server port."
    icon        = "/icon/python.svg"
  }
  option {
    name        = "8080 · General web"
    value       = "8080"
    description = "Common alternate HTTP and application server port."
    icon        = "/icon/code.svg"
  }
}

data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "Container project"
  description  = "Search an existing repository, start empty, or request a new repository/fork. Create and Fork require one confirmation click on GitHub after startup."
  type         = "string"
  form_type    = "dropdown"
  default      = "__empty_project__"
  mutable      = true
  order        = 10
  icon         = "/icon/github.svg"

  option {
    name        = "Empty container project"
    value       = "__empty_project__"
    description = "Start without cloning a repository."
    icon        = "/icon/folder.svg"
  }

  option {
    name        = "Create new GitHub repository"
    value       = "__create_repository__"
    description = "Start the workspace, confirm creation on GitHub, then clone it automatically."
    icon        = "/icon/github.svg"
  }

  option {
    name        = "Fork public OSS repository"
    value       = "__fork_repository__"
    description = "Start the workspace, confirm the fork on GitHub, then clone it automatically."
    icon        = "/icon/github.svg"
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

data "coder_parameter" "new_repo_name" {
  count        = data.coder_parameter.git_repo.value == "__create_repository__" ? 1 : 0
  name         = "new_repo_name"
  display_name = "New repository name"
  description  = "Keep the same name on the GitHub confirmation page."
  type         = "string"
  form_type    = "input"
  default      = "new-project"
  mutable      = true
  order        = 11
  icon         = "/icon/github.svg"

  validation {
    regex = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"
    error = "Use 1–100 letters, numbers, periods, underscores, or hyphens."
  }
}

data "coder_parameter" "fork_repo_url" {
  count        = data.coder_parameter.git_repo.value == "__fork_repository__" ? 1 : 0
  name         = "fork_repo_url"
  display_name = "Public repository to fork"
  description  = "Enter https://github.com/OWNER/REPOSITORY."
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  order        = 12
  icon         = "/icon/github.svg"

  validation {
    regex = "^(|https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\\.git)?/?)$"
    error = "Enter a public GitHub repository URL such as https://github.com/owner/project."
  }
}

data "coder_workspace_preset" "forge" {
  for_each    = local.forge_presets
  name        = each.value.name
  description = each.value.description
  icon        = each.value.icon
  default     = each.value.default
  parameters = {
    (data.coder_parameter.builder_cpu.name)     = each.value.cpu
    (data.coder_parameter.builder_memory.name)  = each.value.memory
    (data.coder_parameter.home_disk_size.name)  = each.value.home_disk
    (data.coder_parameter.cache_disk_size.name) = each.value.cache_disk
    (data.coder_parameter.storage_tier.name)    = each.value.storage_tier
    (data.coder_parameter.forge_node.name)      = each.value.node
  }
}

locals {
  workspace_name = "coder-${data.coder_workspace.me.id}"
  builder_name   = "${local.workspace_name}-builder"
  builder_pod    = "${local.builder_name}-0"
  repository_mode = lookup({
    "__empty_project__"     = "empty"
    "__create_repository__" = "create"
    "__fork_repository__"   = "fork"
  }, data.coder_parameter.git_repo.value, "existing")
  existing_git_repo_url = local.repository_mode == "existing" ? trimsuffix(trimspace(data.coder_parameter.git_repo.value), "/") : ""
  fork_source_web_url = local.repository_mode == "fork" ? trimsuffix(
    trimsuffix(trimspace(try(data.coder_parameter.fork_repo_url[0].value, "")), "/"),
    ".git",
  ) : ""
  requested_repo_name   = local.repository_mode == "create" ? trimspace(try(data.coder_parameter.new_repo_name[0].value, "")) : ""
  fork_repo_name        = local.fork_source_web_url != "" ? basename(local.fork_source_web_url) : ""
  browser_assisted_repo = contains(["create", "fork"], local.repository_mode)
  github_auth_required  = local.repository_mode != "empty"
  git_repo_name = local.repository_mode == "existing" ? trimsuffix(basename(local.existing_git_repo_url), ".git") : (
    local.repository_mode == "create" ? local.requested_repo_name : local.fork_repo_name
  )
  git_repo_url = local.repository_mode == "empty" ? "" : (
    local.repository_mode == "existing" ? local.existing_git_repo_url : "https://github.com/${var.github_owner}/${local.git_repo_name}.git"
  )
  git_repo_set = local.git_repo_url != "" && local.git_repo_name != ""
  workspace_dir = local.git_repo_set ? "/home/coder/project/${local.git_repo_name}" : "/home/coder/project"
  github_action_url = local.repository_mode == "create" ? "https://github.com/new?owner=${urlencode(var.github_owner)}&name=${urlencode(local.git_repo_name)}" : (
    local.repository_mode == "fork" && local.fork_source_web_url != "" ? "${local.fork_source_web_url}/fork" : ""
  )
  repository_display = local.repository_mode == "empty" ? "Empty container project" : (
    local.repository_mode == "create" ? "Create ${var.github_owner}/${local.git_repo_name}" : (
      local.repository_mode == "fork" ? "Fork to ${var.github_owner}/${local.git_repo_name}" : local.git_repo_url
    )
  )
  node_selector = {
    "kubernetes.io/hostname" = data.coder_parameter.forge_node.value
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
    "OLYMPUS_CODER_ACCESS_URL"         = "https://coder.jacob-neel.dev"
    "OLYMPUS_CODER_WILDCARD_DOMAIN"    = "jacob-neel.dev"
    "OLYMPUS_CODER_OWNER"              = data.coder_workspace_owner.me.name
    "OLYMPUS_CODER_WORKSPACE"          = data.coder_workspace.me.name
    "OLYMPUS_CODER_AGENT"              = "main"
    "OLYMPUS_WORKSPACE_SKILL_BASE_URL" = "https://raw.githubusercontent.com/link2427/homelab/main/apps/olympus/coder/skills/olympus-workspace"
  }
}

data "coder_external_auth" "github" {
  count = local.github_auth_required ? 1 : 0
  id    = "github"
}

resource "terraform_data" "repository_request" {
  input = {
    mode       = local.repository_mode
    repository = local.git_repo_url
    source     = local.fork_source_web_url
  }

  lifecycle {
    precondition {
      condition     = local.repository_mode != "create" || local.requested_repo_name != ""
      error_message = "New repository name is required when Create new GitHub repository is selected."
    }

    precondition {
      condition     = local.repository_mode != "fork" || local.fork_source_web_url != ""
      error_message = "Public repository to fork is required when Fork public OSS repository is selected."
    }
  }
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

    olympus_context_installer="$(mktemp /tmp/olympus-context.XXXXXX)"
    if curl --retry 5 --retry-delay 2 --fail --retry-all-errors -fsSL \
      "https://raw.githubusercontent.com/link2427/homelab/main/apps/olympus/coder/skills/olympus-workspace/scripts/install-olympus-workspace" \
      -o "$olympus_context_installer"; then
      chmod 0700 "$olympus_context_installer"
      if ! "$olympus_context_installer"; then
        echo "Olympus context installer failed; workspace startup will continue." >&2
      fi
    else
      echo "Olympus context installer download failed; workspace startup will continue." >&2
    fi
    rm -f "$olympus_context_installer"

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
      command="/bin/bash"
    else
      command="$(command -v "$1")"
    fi
    exec zellij --session "$session" options \
      --default-cwd "$workdir" \
      --default-shell "$command" \
      --show-startup-tips false
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
    if [ ! -f "$archive" ]; then
      echo "Archive does not exist: $archive" >&2
      exit 1
    fi
    archive="$(cd "$(dirname "$archive")" && pwd -P)/$(basename "$archive")"
    case "$archive" in
      /home/coder/exports/*) ;;
      *) echo "Archive must be under /home/coder/exports." >&2; exit 2 ;;
    esac
    output_dir="$archive.parts"
    if [ -e "$output_dir" ]; then
      echo "Parts directory already exists: $output_dir" >&2
      exit 1
    fi
    mkdir -p "$output_dir"
    archive_name="$(basename "$archive")"
    split -b "$part_size" -d -a 3 "$archive" "$output_dir/$archive_name.part-"
    (
      cd "$output_dir"
      sha256sum "$archive_name".part-* > SHA256SUMS
    )
    cat > "$output_dir/REASSEMBLE-IN-SCIF.txt" <<EOF
    Container Forge split archive
    =============================

    Copy all parts into one directory, then run:

      sha256sum -c SHA256SUMS
      cat $archive_name.part-* > $archive_name
      docker load --input $archive_name
    EOF
    printf 'Split archive ready: %s\n' "$output_dir"
    SPLIT_HELPER
    chmod +x /home/coder/.local/bin/container-split

    cat > /home/coder/.local/bin/container-registry-login <<'PY'
    #!/usr/bin/env python3
    """Store a Docker-compatible registry credential for Kaniko base-image pulls."""

    import base64
    import getpass
    import json
    from pathlib import Path
    import sys

    if len(sys.argv) not in (2, 3):
        print("Usage: container-registry-login REGISTRY [USERNAME]", file=sys.stderr)
        raise SystemExit(2)

    registry = sys.argv[1].strip()
    username = sys.argv[2].strip() if len(sys.argv) == 3 else input("Username: ").strip()
    if not registry or not username:
        print("Registry and username cannot be empty.", file=sys.stderr)
        raise SystemExit(2)

    password = getpass.getpass("Password or token: ")
    if not password:
        print("Password or token cannot be empty.", file=sys.stderr)
        raise SystemExit(2)

    config_path = Path("/home/coder/.docker/config.json")
    config_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        config = {}
    except json.JSONDecodeError as error:
        print(f"Refusing to overwrite invalid {config_path}: {error}", file=sys.stderr)
        raise SystemExit(1)

    auths = config.setdefault("auths", {})
    auths[registry] = {
        "auth": base64.b64encode(f"{username}:{password}".encode()).decode()
    }
    temporary = config_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(config_path)
    config_path.chmod(0o600)
    print(f"Credential stored for {registry}.")
    PY
    chmod +x /home/coder/.local/bin/container-registry-login

    cat > /home/coder/.local/bin/olympus-export <<'EXPORT_HELPER'
    #!/bin/sh
    set -eu
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
      echo "Usage: olympus-export SOURCE [DOWNLOAD_NAME]" >&2
      exit 2
    fi
    source_path="$1"
    download_name="$${2:-$(basename "$source_path")}"
    case "$download_name" in
      ""|.|..|*/*) echo "DOWNLOAD_NAME must be a single file or directory name." >&2; exit 2 ;;
    esac
    if [ ! -e "$source_path" ]; then
      echo "Source does not exist: $source_path" >&2
      exit 1
    fi
    destination="/home/coder/exports/$download_name"
    if [ -e "$destination" ]; then
      echo "Destination already exists: $destination" >&2
      exit 1
    fi
    cp -a -- "$source_path" "$destination"
    printf 'Export ready: %s\n' "$destination"
    EXPORT_HELPER
    chmod +x /home/coder/.local/bin/olympus-export

    if [ ! -e /home/coder/project/CONTAINER-FORGE.md ]; then
      cat > /home/coder/project/CONTAINER-FORGE.md <<'FORGE_GUIDE'
    # Container Forge

    This workspace builds Docker-compatible Linux/amd64 image archives without
    Docker-in-Docker and without mounting a host Docker socket.

    ## Normal workflow

    1. Create a Dockerfile and its build context under `/home/coder`.
    2. Build and export it:

       ```bash
       cd /home/coder/project
       container-build my-image:1.0 . -f Dockerfile
       ```

    3. Open **Exports** in Coder and download the completed bundle directory.
    4. In the offline environment, verify `SHA256SUMS`, then use the exact
       `docker load` command written to `LOAD-IN-SCIF.txt`.

    Common options:

    ```bash
    container-build pytorch-scif:1.0 . \
      --build-arg CUDA_VERSION=13.0 \
      --target runtime

    container-build opencode-scif:1.0 . --reproducible
    ```

    For an archive too large for one approved disc, run:

    ```bash
    container-split /home/coder/exports/<bundle>/<image>.docker.tar 3900M
    ```

    Registry credentials for private base images can be stored with:

    ```bash
    container-registry-login registry.example.mil USERNAME
    ```

    ## Important boundaries

    - The target is Linux/amd64, matching the intended offline Docker hosts.
    - This workspace builds images but does not run them. Put validation in a
      Dockerfile test stage and build that stage with `--target`.
    - Build contexts and Dockerfiles must remain under `/home/coder` because
      that is the only volume mounted into the disposable builder.
    - The builder is recycled after every build so one Dockerfile cannot leave
      filesystem state behind for the next one.
    FORGE_GUIDE
    fi

    filebrowser_version="v2.63.5"
    filebrowser_checksum="b36ad6296db0a749a5adbc792ab5321d11b307106123d44e171b7c158fcca2d9"
    filebrowser_marker="/home/coder/.local/share/filebrowser/version"
    installed_filebrowser_version="$(cat "$filebrowser_marker" 2>/dev/null || true)"
    if [ ! -x /home/coder/.local/bin/filebrowser ] || [ "$installed_filebrowser_version" != "$filebrowser_version" ]; then
      filebrowser_archive="/tmp/container-forge-filebrowser-$filebrowser_version.tar.gz"
      filebrowser_extract_dir="$(mktemp -d /tmp/container-forge-filebrowser.XXXXXX)"
      curl --retry 5 --retry-delay 3 --fail --retry-all-errors -L \
        -o "$filebrowser_archive" \
        "https://github.com/filebrowser/filebrowser/releases/download/$filebrowser_version/linux-amd64-filebrowser.tar.gz"
      printf '%s  %s\n' "$filebrowser_checksum" "$filebrowser_archive" | sha256sum -c -
      tar -xzf "$filebrowser_archive" -C "$filebrowser_extract_dir" filebrowser
      install -m 0755 "$filebrowser_extract_dir/filebrowser" /home/coder/.local/bin/filebrowser
      printf '%s\n' "$filebrowser_version" > "$filebrowser_marker"
      rm -f "$filebrowser_extract_dir/filebrowser" "$filebrowser_archive"
      rmdir "$filebrowser_extract_dir"
    fi

    if ! command -v npm >/dev/null 2>&1; then
      node_version="v24.18.1"
      node_dir="/home/coder/.local/lib/node-$node_version-linux-x64"
      if [ ! -x "$node_dir/bin/node" ]; then
        mkdir -p "$node_dir"
        curl --retry 5 --retry-delay 3 --fail --retry-all-errors -L \
          "https://nodejs.org/dist/$node_version/node-$node_version-linux-x64.tar.xz" \
          -o /tmp/container-forge-node.tar.xz
        tar -xJf /tmp/container-forge-node.tar.xz -C "$node_dir" --strip-components=1
        rm -f /tmp/container-forge-node.tar.xz
      fi
      ln -sfn "$node_dir/bin/node" /home/coder/.local/bin/node
      ln -sfn "$node_dir/bin/npm" /home/coder/.local/bin/npm
      ln -sfn "$node_dir/bin/npx" /home/coder/.local/bin/npx
    fi

    if ! /home/coder/.local/bin/reasonix --version >/dev/null 2>&1; then
      npm install --global --prefix /home/coder/.local reasonix@1.19.1
    fi

    python3 - <<'PY'
    import os
    import re
    from pathlib import Path

    reasonix_home = Path("/home/coder/.reasonix")
    reasonix_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(reasonix_home, 0o700)

    # Talos disables unprivileged user namespaces, so Reasonix cannot nest
    # Bubblewrap. The outer Coder pod remains non-root, capability-free, and
    # protected by RuntimeDefault seccomp.
    config = reasonix_home / "config.toml"
    if config.exists():
        content = config.read_text(encoding="utf-8")
        section = re.search(r"(?ms)^\[sandbox\]\s*\n(?P<body>.*?)(?=^\[|\Z)", content)
        if section:
            body = section.group("body")
            if re.search(r"(?m)^\s*bash\s*=", body):
                updated_body = re.sub(r'(?m)^\s*bash\s*=.*$', 'bash = "off"', body, count=1)
            else:
                updated_body = body + 'bash = "off"\n'
            content = content[:section.start("body")] + updated_body + content[section.end("body"):]
        else:
            content = content.rstrip() + '\n\n[sandbox]\nbash = "off"\nnetwork = true\n'
    else:
        content = '[sandbox]\nbash = "off"\nnetwork = true\n'

    temporary = reasonix_home / "config.toml.coder.tmp"
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, config)

    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if key:
        credentials = reasonix_home / ".env"
        retained = []
        if credentials.exists():
            for line in credentials.read_text(encoding="utf-8").splitlines():
                normalized = line.strip()
                if normalized.startswith("DEEPSEEK_API_KEY="):
                    continue
                if normalized.startswith("export DEEPSEEK_API_KEY="):
                    continue
                retained.append(line)
        retained.append(f"DEEPSEEK_API_KEY={key}")
        credentials_tmp = reasonix_home / ".env.coder.tmp"
        credentials_tmp.write_text("\n".join(retained) + "\n", encoding="utf-8")
        os.chmod(credentials_tmp, 0o600)
        os.replace(credentials_tmp, credentials)
    PY

    if [ -x /usr/bin/gh ]; then
      cat > /home/coder/.local/bin/gh <<'GH_WRAPPER'
    #!/bin/sh
    set -eu
    coder_cli="$(find /tmp -maxdepth 2 -type f -path '/tmp/coder.*/coder' -print -quit)"
    if [ -n "$coder_cli" ]; then
      GH_TOKEN="$($coder_cli external-auth access-token github)"
      export GH_TOKEN
      export GITHUB_TOKEN="$GH_TOKEN"
    fi
    exec /usr/bin/gh "$@"
    GH_WRAPPER
      chmod +x /home/coder/.local/bin/gh
    fi

    if ! curl -fsS "http://127.0.0.1:13339${local.exports_base_path}/" >/dev/null 2>&1; then
      nohup /home/coder/.local/bin/filebrowser \
        --address 127.0.0.1 \
        --port 13339 \
        --root /home/coder/exports \
        --database /home/coder/.local/share/filebrowser/filebrowser.db \
        --baseURL '${local.exports_base_path}' \
        --noauth \
        > /home/coder/.local/share/filebrowser/server.log 2>&1 &
    fi
  EOT
}

module "git_clone" {
  count      = data.coder_workspace.me.start_count > 0 && local.repository_mode == "existing" ? 1 : 0
  source     = "registry.coder.com/coder/git-clone/coder"
  version    = "2.0.2"
  agent_id   = coder_agent.main.id
  url        = local.existing_git_repo_url
  base_dir   = "/home/coder/project"
  depends_on = [data.coder_external_auth.github]
}

resource "coder_script" "browser_assisted_repository" {
  count              = data.coder_workspace.me.start_count > 0 && local.browser_assisted_repo ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = local.repository_mode == "create" ? "Clone newly created repository" : "Clone new GitHub fork"
  icon               = "/icon/github.svg"
  run_on_start       = true
  start_blocks_login = false
  timeout            = 1800
  script = templatefile("${path.module}/repository-bootstrap.sh.tftpl", {
    repository_mode     = local.repository_mode
    repository_name_b64 = base64encode(local.git_repo_name)
    repository_url_b64  = base64encode(local.git_repo_url)
  })

  depends_on = [data.coder_external_auth.github, terraform_data.repository_request]
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

resource "coder_app" "web_preview" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "web-preview"
  display_name = "Web Preview · :${data.coder_parameter.preview_port.value}"
  icon         = "/icon/code.svg"
  group        = "Container Development"
  order        = 0
  url          = "http://localhost:${data.coder_parameter.preview_port.value}"
  subdomain    = true
  share        = "owner"

  healthcheck {
    url       = "http://localhost:${data.coder_parameter.preview_port.value}/"
    interval  = 5
    threshold = 24
  }
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
  url          = trimsuffix(local.git_repo_url, ".git")
}

resource "coder_app" "github_repository_action" {
  count        = data.coder_workspace.me.start_count > 0 && local.browser_assisted_repo ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "github-repository-action"
  display_name = local.repository_mode == "create" ? "Create repository on GitHub" : "Create fork on GitHub"
  icon         = "/icon/github.svg"
  group        = "Container Development"
  order        = 4
  external     = true
  url          = local.github_action_url
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
    value = data.coder_parameter.forge_node.value
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
    value = local.repository_display
  }

  item {
    key   = "Working directory"
    value = local.workspace_dir
  }
}
