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

variable "profile" {
  type        = string
  description = "Template profile selected by the Coder administrator at publish time."
  default     = "linux"

  validation {
    condition     = contains(["linux", "agent", "gpu", "build"], var.profile)
    error_message = "Profile must be linux, agent, gpu, or build."
  }
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace used for Coder workspaces."
  default     = "coder"
}

variable "image" {
  type        = string
  description = "Linux workspace image selected by the template publisher."
  default     = "codercom/example-base:ubuntu"
}

variable "recovery_home_pvc" {
  type        = string
  description = "Administrator-only recovery canary: mount an already cloned same-namespace home PVC. Leave empty for normal templates."
  default     = ""
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
    ])) && can(length(jsondecode(var.github_repositories_json)) <= 60)
    error_message = "github_repositories_json must contain at most 60 GitHub repositories with name, .git URL, and private/public visibility fields."
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
  profiles = {
    linux = {
      cpu          = "4"
      memory       = "4"
      disk         = "30"
      storage_tier = "fast"
      gpu          = "none"
      node         = "auto"
    }
    agent = {
      cpu          = "6"
      memory       = "12"
      disk         = "60"
      storage_tier = "fast"
      gpu          = "none"
      node         = "auto"
    }
    gpu = {
      cpu          = "4"
      memory       = "8"
      disk         = "80"
      storage_tier = "fast"
      gpu          = "quadro-m4000"
      node         = "auto"
    }
    build = {
      cpu          = "8"
      memory       = "16"
      disk         = "120"
      storage_tier = "bulk"
      gpu          = "none"
      node         = "precision-7810-01"
    }
  }
  workspace_presets = {
    linux = {
      compact = {
        name         = "Compact Sandbox"
        description  = "A small shell, utility, or quick-fix workspace."
        icon         = "/icon/ubuntu.svg"
        default      = false
        cpu          = "2"
        memory       = "4"
        disk         = "20"
        storage_tier = "fast"
        node         = "auto"
        gpu          = "none"
      }
      balanced = {
        name         = "Balanced Linux"
        description  = "The everyday Olympus Linux configuration."
        icon         = "/icon/ubuntu.svg"
        default      = false
        cpu          = "4"
        memory       = "4"
        disk         = "30"
        storage_tier = "fast"
        node         = "auto"
        gpu          = "none"
      }
      atlas = {
        name         = "Atlas Heavy"
        description  = "A roomy CPU workspace pinned to the DL380."
        icon         = "/icon/node.svg"
        default      = false
        cpu          = "16"
        memory       = "32"
        disk         = "120"
        storage_tier = "fast"
        node         = "atlas"
        gpu          = "none"
      }
    }
    agent = {
      focused = {
        name         = "Focused Agent"
        description  = "One or two coding agents with comfortable context and cache space."
        icon         = "/icon/openai.svg"
        default      = false
        cpu          = "6"
        memory       = "12"
        disk         = "60"
        storage_tier = "fast"
        node         = "auto"
        gpu          = "none"
      }
      pair = {
        name         = "Agent Pair"
        description  = "More room for two autonomous agents, tests, and local services."
        icon         = "/icon/openai.svg"
        default      = false
        cpu          = "10"
        memory       = "24"
        disk         = "100"
        storage_tier = "fast"
        node         = "atlas"
        gpu          = "none"
      }
      swarm = {
        name         = "Agent Swarm"
        description  = "Atlas-backed capacity for several concurrent agents and builds."
        icon         = "/icon/openai.svg"
        default      = false
        cpu          = "24"
        memory       = "40"
        disk         = "160"
        storage_tier = "fast"
        node         = "atlas"
        gpu          = "none"
      }
    }
    gpu = {
      m4000 = {
        name         = "M4000 Compatibility"
        description  = "A compact CUDA workspace on the Maxwell Quadro."
        icon         = "/icon/pytorch.svg"
        default      = false
        cpu          = "4"
        memory       = "8"
        disk         = "80"
        storage_tier = "fast"
        node         = "auto"
        gpu          = "quadro-m4000"
      }
      p2000 = {
        name         = "P2000 CUDA"
        description  = "Pascal CUDA development on the 7810; use when Plex does not need the card."
        icon         = "/icon/pytorch.svg"
        default      = false
        cpu          = "6"
        memory       = "12"
        disk         = "100"
        storage_tier = "fast"
        node         = "auto"
        gpu          = "quadro-p2000"
      }
      p40 = {
        name         = "P40 PyTorch"
        description  = "The primary ML preset: 24 GiB Tesla P40 plus Atlas CPU and RAM."
        icon         = "/icon/pytorch.svg"
        default      = false
        cpu          = "16"
        memory       = "32"
        disk         = "160"
        storage_tier = "fast"
        node         = "auto"
        gpu          = "tesla-p40"
      }
    }
    build = {
      standard = {
        name         = "Standard Build"
        description  = "Bulk-backed compilation and dependency caches on the 7810."
        icon         = "/icon/code.svg"
        default      = false
        cpu          = "8"
        memory       = "16"
        disk         = "120"
        storage_tier = "bulk"
        node         = "precision-7810-01"
        gpu          = "none"
      }
      atlas = {
        name         = "Atlas Turbo Build"
        description  = "Large parallel compiles on Atlas with fast replicated storage."
        icon         = "/icon/code.svg"
        default      = false
        cpu          = "32"
        memory       = "48"
        disk         = "200"
        storage_tier = "fast"
        node         = "atlas"
        gpu          = "none"
      }
      archive = {
        name         = "Archive Builder"
        description  = "Maximum bulk workspace capacity for large build trees and caches."
        icon         = "/icon/database.svg"
        default      = false
        cpu          = "8"
        memory       = "24"
        disk         = "250"
        storage_tier = "bulk"
        node         = "precision-7810-01"
        gpu          = "none"
      }
    }
  }

  selected_profile = local.profiles[var.profile]
  storage_classes = {
    fast      = "coder-fast"
    resilient = "coder-resilient"
    bulk      = "coder-bulk"
  }
  gpu_nodes = {
    quadro-m4000 = "precision-5810-01"
    quadro-p2000 = "precision-7810-01"
    tesla-p40    = "atlas"
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "Maximum CPU cores available to the workspace. Atlas is the best home for values above 12."
  type         = "number"
  form_type    = "slider"
  default      = local.selected_profile.cpu
  mutable      = true
  order        = 20
  icon         = "/icon/k8s.svg"

  validation {
    min = 1
    max = 48
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "Maximum memory in GiB. Atlas is the only node intended for workspaces above 24 GiB."
  type         = "number"
  form_type    = "slider"
  default      = local.selected_profile.memory
  mutable      = true
  order        = 30
  icon         = "/icon/memory.svg"

  validation {
    min = 2
    max = 48
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk"
  description  = "Home disk capacity in GiB. Files survive stops and restarts. Deleting the workspace deletes its disk; export needed files first. Daily backups are separate."
  type         = "number"
  form_type    = "slider"
  default      = local.selected_profile.disk
  mutable      = false
  order        = 40
  icon         = "/icon/database.svg"

  validation {
    min = 10
    max = 250
  }
}

data "coder_parameter" "storage_tier" {
  name         = "storage_tier"
  display_name = "Storage tier"
  description  = "Fast uses two SSD replicas; resilient uses three replicas; bulk uses the single HDD and daily backup."
  form_type    = "radio"
  default      = local.selected_profile.storage_tier
  mutable      = false
  order        = 50
  icon         = "/icon/database.svg"

  option {
    name        = "Fast SSD · 2 replicas"
    value       = "fast"
    description = "Best default for development, package caches, and interactive work."
    icon        = "/icon/database.svg"
  }

  option {
    name        = "Resilient · 3 replicas"
    value       = "resilient"
    description = "Maximum redundancy for small, important workspace homes."
    icon        = "/icon/database.svg"
  }

  option {
    name        = "Bulk HDD · 1 replica + backup"
    value       = "bulk"
    description = "Large and economical; slower, with recovery from the daily R2 backup."
    icon        = "/icon/database.svg"
  }
}

data "coder_parameter" "node_placement" {
  name         = "node_placement"
  display_name = "CPU placement"
  description  = "Choose a host for CPU-only work. Selecting a GPU below always overrides this choice with that GPU's physical host."
  form_type    = "radio"
  default      = local.selected_profile.node
  mutable      = true
  order        = 60
  icon         = "/icon/node.svg"

  option {
    name        = "Automatic"
    value       = "auto"
    description = "Let Kubernetes place the workspace according to available capacity."
    icon        = "/icon/k8s.svg"
  }

  option {
    name        = "Atlas · 72 CPU / 62 GiB"
    value       = "atlas"
    description = "Best for agent swarms, large compiles, and memory-heavy work."
    icon        = "/icon/node.svg"
  }

  option {
    name        = "Precision 5810 · 12 CPU / 15 GiB"
    value       = "precision-5810-01"
    description = "General-purpose Precision host with the Quadro M4000."
    icon        = "/icon/node.svg"
  }

  option {
    name        = "Precision 7810 · 8 CPU / 31 GiB"
    value       = "precision-7810-01"
    description = "Build and bulk-storage host with the Quadro P2000."
    icon        = "/icon/node.svg"
  }
}

data "coder_parameter" "gpu" {
  name         = "gpu"
  display_name = "GPU"
  description  = "Reserve one physical GPU and automatically pin the workspace to its host."
  form_type    = "radio"
  default      = local.selected_profile.gpu
  mutable      = true
  order        = 70
  icon         = "/icon/pytorch.svg"

  option {
    name        = "No GPU"
    value       = "none"
    description = "CPU-only workspace using the placement selected above."
    icon        = "/icon/k8s.svg"
  }
  option {
    name        = "Quadro M4000 · 8 GiB"
    value       = "quadro-m4000"
    description = "Maxwell compatibility card on precision-5810-01."
    icon        = "/icon/pytorch.svg"
  }

  option {
    name        = "Quadro P2000 · 5 GiB"
    value       = "quadro-p2000"
    description = "Pascal card on precision-7810-01; normally reserved for Plex transcoding."
    icon        = "/icon/pytorch.svg"
  }

  option {
    name        = "Tesla P40 · 24 GiB"
    value       = "tesla-p40"
    description = "Primary PyTorch/ML card on Atlas."
    icon        = "/icon/pytorch.svg"
  }
}

data "coder_parameter" "preview_port" {
  name         = "preview_port"
  display_name = "Primary web preview"
  description  = "Port used by the Web Preview card. Any other listening port is also available through Coder Open Ports and olympus-preview."
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
    description = "Common FastAPI, Django, and Python HTTP server port."
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
  display_name = "GitHub repository"
  description  = "Search an existing repository, start empty, or request a new repository/fork. Create and Fork require one confirmation click on GitHub after startup."
  type         = "string"
  form_type    = "dropdown"
  default      = "__empty_project__"
  mutable      = true
  order        = 10
  icon         = "/icon/github.svg"

  option {
    name        = "Empty project"
    value       = "__empty_project__"
    description = "Create a workspace without cloning a repository."
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

  option {
    name        = "Clone a GitHub URL"
    value       = "__repository_url__"
    description = "Use any repository you can access, including repositories beyond the suggestions."
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

data "coder_workspace_preset" "olympus" {
  for_each    = local.workspace_presets[var.profile]
  name        = each.value.name
  description = each.value.description
  icon        = each.value.icon
  default     = each.value.default
  parameters = {
    (data.coder_parameter.cpu.name)            = each.value.cpu
    (data.coder_parameter.memory.name)         = each.value.memory
    (data.coder_parameter.home_disk_size.name) = each.value.disk
    (data.coder_parameter.storage_tier.name)   = each.value.storage_tier
    (data.coder_parameter.node_placement.name) = each.value.node
    (data.coder_parameter.gpu.name)            = each.value.gpu
  }
}

data "coder_external_auth" "github" {
  count = local.github_auth_required ? 1 : 0
  id    = "github"
}

locals {
  workspace_name = "coder-${data.coder_workspace.me.id}"
  repository_mode = lookup({
    "__empty_project__"     = "empty"
    "__create_repository__" = "create"
    "__fork_repository__"   = "fork"
  }, data.coder_parameter.git_repo.value, "existing")
  existing_git_repo_url = local.repository_mode == "existing" ? trimsuffix(trimspace(data.coder_parameter.git_repo.value == "__repository_url__" ? try(data.coder_parameter.repository_url[0].value, "") : data.coder_parameter.git_repo.value), "/") : ""
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
  git_repo_set  = local.git_repo_url != "" && local.git_repo_name != ""
  workspace_dir = local.git_repo_set ? "/home/coder/project/${local.git_repo_name}" : "/home/coder/project"
  github_action_url = local.repository_mode == "create" ? "https://github.com/new?owner=${urlencode(var.github_owner)}&name=${urlencode(local.git_repo_name)}" : (
    local.repository_mode == "fork" && local.fork_source_web_url != "" ? "${local.fork_source_web_url}/fork" : ""
  )
  repository_display = local.repository_mode == "empty" ? "Empty project" : (
    local.repository_mode == "create" ? "Create ${var.github_owner}/${local.git_repo_name}" : (
      local.repository_mode == "fork" ? "Fork to ${var.github_owner}/${local.git_repo_name}" : local.git_repo_url
    )
  )
  exports_base_path = format(
    "/@%s/%s.main/apps/exports",
    data.coder_workspace_owner.me.name,
    data.coder_workspace.me.name,
  )
  selected_node = data.coder_parameter.gpu.value != "none" ? local.gpu_nodes[data.coder_parameter.gpu.value] : (
    data.coder_parameter.node_placement.value == "auto" ? "" : data.coder_parameter.node_placement.value
  )
  node_selector = local.selected_node != "" ? {
    "kubernetes.io/hostname" = local.selected_node
  } : {}
  gpu_limits = data.coder_parameter.gpu.value != "none" ? {
    "nvidia.com/gpu" = "1"
  } : {}
  profile_environment = merge(
    {
      "OLYMPUS_CODER_ACCESS_URL"         = "https://coder.jacob-neel.dev"
      "OLYMPUS_CODER_WILDCARD_DOMAIN"    = "jacob-neel.dev"
      "OLYMPUS_CODER_OWNER"              = data.coder_workspace_owner.me.name
      "OLYMPUS_CODER_WORKSPACE"          = data.coder_workspace.me.name
      "OLYMPUS_CODER_AGENT"              = "main"
      "OLYMPUS_WORKSPACE_SKILL_BASE_URL" = "https://raw.githubusercontent.com/link2427/homelab/main/apps/olympus/coder/skills/olympus-workspace"
      # Normal agent workspaces deliberately have no Docker socket. Coder 2.24+
      # otherwise enables Dev Container discovery by default and continuously
      # reports a misleading 500 when it cannot reach Docker.
      "CODER_AGENT_DEVCONTAINERS_ENABLE" = "false"
    },
    var.profile == "agent" ? {
      "OLYMPUS_WORKSPACE_DIR"       = local.workspace_dir
      "OLYMPUS_EXPORTS_BASE_PATH"   = local.exports_base_path
      "DISABLE_AUTOUPDATER"         = "1"
      "OPENCODE_DISABLE_AUTOUPDATE" = "true"
      "GROK_DISABLE_AUTOUPDATER"    = "1"
      "PATH"                        = "/opt/olympus/bin:/usr/local/bin:/home/coder/.local/bin:/home/coder/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    } : {},
    var.profile == "gpu" ? {
      "HF_HOME"                   = "/home/coder/.cache/huggingface"
      "JUPYTER_CONFIG_DIR"        = "/home/coder/.jupyter"
      "MPLCONFIGDIR"              = "/home/coder/.cache/matplotlib"
      "TORCH_HOME"                = "/home/coder/.cache/torch"
      "TORCH_EXTENSIONS_DIR"      = "/home/coder/.cache/torch_extensions"
      "PYTORCH_KERNEL_CACHE_PATH" = "/home/coder/.cache/torch/kernels"
    } : {}
  )
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
  os                 = "linux"
  arch               = "amd64"
  connection_timeout = var.profile == "agent" ? 900 : 180

  startup_script_behavior = "non-blocking"
  startup_script          = var.profile == "agent" ? "" : <<-EOT
    set -eu
    mkdir -p /home/coder/project /home/coder/.local/bin
    olympus_context_installer="$(mktemp /tmp/olympus-context.XXXXXX)"
    if curl --retry 5 --retry-delay 2 --fail --retry-all-errors -fsSL \
      "https://raw.githubusercontent.com/link2427/homelab/main/apps/olympus/coder/skills/olympus-workspace/scripts/install-olympus-workspace" \
      -o "$${olympus_context_installer}"; then
      chmod 0700 "$${olympus_context_installer}"
      if ! "$${olympus_context_installer}"; then
        echo "Olympus context installer failed; workspace startup will continue." >&2
      fi
    else
      echo "Olympus context installer download failed; workspace startup will continue." >&2
    fi
    rm -f "$${olympus_context_installer}"
    if command -v git >/dev/null 2>&1; then
      git config --global credential.useHttpPath true
      git config --global push.autoSetupRemote true
    fi
    printf '%s\n' '${var.profile}' > /home/coder/.olympus-profile

    %{if var.profile == "gpu"~}
    mkdir -p /home/coder/.cache/huggingface \
      /home/coder/.cache/matplotlib \
      /home/coder/.cache/torch/kernels \
      /home/coder/.cache/torch_extensions \
      /home/coder/.jupyter
    python - <<'PY' > /home/coder/.olympus-pytorch 2>&1
    import torch
    print(f"PyTorch: {torch.__version__}")
    print(f"CUDA build: {torch.version.cuda}")
    print(f"CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"GPU: {torch.cuda.get_device_name(0)}")
    PY
    %{endif~}
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "GPU"
    key          = "3_gpu"
    script       = "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader || echo 'No GPU attached'"
    interval     = 30
    timeout      = 5
  }
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

module "code_server" {
  count      = var.profile != "agent" ? data.coder_workspace.me.start_count : 0
  source     = "registry.coder.com/coder/code-server/coder"
  version    = "1.5.2"
  agent_id   = coder_agent.main.id
  folder     = local.workspace_dir
  use_cached = true
}

module "jupyterlab" {
  count    = var.profile == "gpu" ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/jupyterlab/coder"
  version  = "1.2.2"
  agent_id = coder_agent.main.id
}

resource "coder_app" "web_preview" {
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "web-preview"
  display_name = "Web Preview · :${data.coder_parameter.preview_port.value}"
  icon         = "/icon/code.svg"
  group        = "Development"
  order        = 0
  url          = "http://localhost:${data.coder_parameter.preview_port.value}"
  subdomain    = true
  share        = "owner"
}

resource "coder_app" "exports" {
  count        = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
  agent_id     = coder_agent.main.id
  slug         = "exports"
  display_name = "Exports"
  icon         = "/icon/folder.svg"
  group        = "Exports"
  order        = 1
  url          = "http://localhost:13339${local.exports_base_path}"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13339${local.exports_base_path}/"
    interval  = 5
    threshold = 12
  }
}

resource "coder_app" "github_repository" {
  count        = data.coder_workspace.me.start_count > 0 && local.git_repo_set ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "github-repository"
  display_name = local.git_repo_name
  icon         = "/icon/github.svg"
  group        = "Development"
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
  group        = "Development"
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
      "olympus.dev/workspace-profile"                    = var.profile
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

resource "kubernetes_deployment_v1" "main" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false

  depends_on = [kubernetes_persistent_volume_claim_v1.home]

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
      "olympus.dev/workspace-profile" = var.profile
      "olympus.dev/gpu"               = data.coder_parameter.gpu.value
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "com.coder.workspace.id" = data.coder_workspace.me.id
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
          "olympus.dev/workspace-profile" = var.profile
          "olympus.dev/gpu"               = data.coder_parameter.gpu.value
        }
      }

      spec {
        node_selector      = local.node_selector
        runtime_class_name = data.coder_parameter.gpu.value != "none" ? "nvidia" : null

        security_context {
          run_as_non_root        = true
          run_as_user            = 1000
          run_as_group           = 1000
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "dev"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", coder_agent.main.init_script]

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          dynamic "env" {
            for_each = local.profile_environment
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
            limits = merge({
              cpu    = data.coder_parameter.cpu.value
              memory = "${data.coder_parameter.memory.value}Gi"
            }, local.gpu_limits)
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
            claim_name = var.recovery_home_pvc != "" ? var.recovery_home_pvc : kubernetes_persistent_volume_claim_v1.home.metadata[0].name
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
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
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

resource "coder_metadata" "workspace" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment_v1.main[0].id

  item {
    key   = "Profile"
    value = var.profile
  }

  item {
    key   = "Placement"
    value = local.selected_node != "" ? local.selected_node : "Kubernetes automatic"
  }

  item {
    key   = "GPU"
    value = data.coder_parameter.gpu.value
  }

  item {
    key   = "Storage"
    value = "${data.coder_parameter.storage_tier.value} · ${data.coder_parameter.home_disk_size.value} GiB"
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

# Shared runtime is bundled by the publisher; only Agent and Forge instantiate it.
module "runtime" {
  source        = "./runtime"
  count         = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
  agent_id      = coder_agent.main.id
  workspace_dir = local.workspace_dir
}

data "coder_parameter" "repository_url" {
  count        = data.coder_parameter.git_repo.value == "__repository_url__" ? 1 : 0
  name         = "repository_url"
  display_name = "GitHub repository URL"
  description  = "Clone a repository without changing any existing checkout."
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  order        = 11
  validation {
    regex = "^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\\.git)?/?$"
    error = "Enter https://github.com/OWNER/REPOSITORY."
  }
}
