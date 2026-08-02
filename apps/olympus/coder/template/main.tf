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
  profiles = {
    linux = {
      cpu          = "4"
      memory       = "4"
      disk         = "30"
      storage_tier = "fast"
      gpu          = "none"
      node         = ""
    }
    agent = {
      cpu          = "6"
      memory       = "12"
      disk         = "60"
      storage_tier = "fast"
      gpu          = "none"
      node         = ""
    }
    gpu = {
      cpu          = "4"
      memory       = "8"
      disk         = "80"
      storage_tier = "fast"
      gpu          = "quadro-m4000"
      node         = ""
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

  selected_profile = local.profiles[var.profile]
  storage_classes = {
    fast      = "longhorn-fast"
    resilient = "longhorn-resilient"
    bulk      = "longhorn-bulk"
  }
  gpu_nodes = {
    quadro-m4000 = "precision-5810-01"
    quadro-p2000 = "precision-7810-01"
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "Maximum CPU cores available to the workspace."
  default      = local.selected_profile.cpu
  mutable      = true

  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
  option {
    name  = "6 cores"
    value = "6"
  }
  option {
    name  = "8 cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "Maximum memory available to the workspace."
  default      = local.selected_profile.memory
  mutable      = true

  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
  option {
    name  = "12 GiB"
    value = "12"
  }
  option {
    name  = "16 GiB"
    value = "16"
  }

  option {
    name  = "24 GiB"
    value = "24"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk"
  description  = "Persistent fast-tier home disk size in GiB."
  type         = "number"
  default      = local.selected_profile.disk
  mutable      = false
  validation {
    min = 10
    max = 250
  }
}

data "coder_parameter" "storage_tier" {
  name         = "storage_tier"
  display_name = "Storage tier"
  description  = "Fast uses two SSD replicas; resilient uses three replicas; bulk uses the single HDD and daily backup."
  default      = local.selected_profile.storage_tier
  mutable      = false

  option {
    name  = "Fast SSD · 2 replicas"
    value = "fast"
  }

  option {
    name  = "Resilient · 3 replicas"
    value = "resilient"
  }

  option {
    name  = "Bulk HDD · 1 replica + backup"
    value = "bulk"
  }
}

data "coder_parameter" "gpu" {
  name         = "gpu"
  display_name = "GPU"
  description  = "Reserve a specific physical GPU and pin the workspace to its Precision host."
  default      = local.selected_profile.gpu
  mutable      = true

  option {
    name  = "No GPU"
    value = "none"
  }
  option {
    name  = "Quadro M4000 · 8 GiB · precision-5810-01"
    value = "quadro-m4000"
  }

  option {
    name  = "Quadro P2000 · 5 GiB · precision-7810-01"
    value = "quadro-p2000"
  }
}

data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "GitHub repository"
  description  = "Search repositories available through the Olympus GitHub App, or choose Empty project."
  type         = "string"
  form_type    = "dropdown"
  default      = "__empty_project__"
  mutable      = true
  icon         = "/icon/github.svg"

  option {
    name        = "Empty project"
    value       = "__empty_project__"
    description = "Create a workspace without cloning a repository."
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

data "coder_external_auth" "github" {
  count = local.git_repo_set ? 1 : 0
  id    = "github"
}

locals {
  workspace_name = "coder-${data.coder_workspace.me.id}"
  git_repo_url   = data.coder_parameter.git_repo.value == "__empty_project__" ? "" : trimsuffix(trimspace(data.coder_parameter.git_repo.value), "/")
  git_repo_set   = local.git_repo_url != ""
  git_repo_name  = local.git_repo_set ? trimsuffix(basename(local.git_repo_url), ".git") : ""
  workspace_dir  = local.git_repo_set ? "/home/coder/project/${local.git_repo_name}" : "/home/coder/project"
  selected_node  = data.coder_parameter.gpu.value != "none" ? local.gpu_nodes[data.coder_parameter.gpu.value] : local.selected_profile.node
  node_selector = local.selected_node != "" ? {
    "kubernetes.io/hostname" = local.selected_node
  } : {}
  gpu_limits = data.coder_parameter.gpu.value != "none" ? {
    "nvidia.com/gpu" = "1"
  } : {}
  profile_environment = merge(
    var.profile == "agent" ? {
      "PATH" = "/home/coder/.local/bin:/home/coder/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  startup_script = <<-EOT
    set -eu
    mkdir -p /home/coder/project
    if command -v git >/dev/null 2>&1; then
      git config --global credential.useHttpPath true
      git config --global push.autoSetupRemote true
    fi
    printf '%s\n' '${var.profile}' > /home/coder/.olympus-profile
    %{if var.profile == "agent"~}
    mkdir -p /home/coder/.local/bin /home/coder/.local/lib
    if ! command -v npm >/dev/null 2>&1; then
      node_version="v24.18.1"
      node_dir="/home/coder/.local/lib/node-$${node_version}-linux-x64"
      if [ ! -x "$${node_dir}/bin/node" ]; then
        mkdir -p "$${node_dir}"
        curl -fsSL "https://nodejs.org/dist/$${node_version}/node-$${node_version}-linux-x64.tar.xz" \
          -o /tmp/olympus-node.tar.xz
        tar -xJf /tmp/olympus-node.tar.xz -C "$${node_dir}" --strip-components=1
        rm -f /tmp/olympus-node.tar.xz
      fi
      ln -sfn "$${node_dir}/bin/node" /home/coder/.local/bin/node
      ln -sfn "$${node_dir}/bin/npm" /home/coder/.local/bin/npm
      ln -sfn "$${node_dir}/bin/npx" /home/coder/.local/bin/npx
    fi
    if ! /home/coder/.local/bin/reasonix --version >/dev/null 2>&1; then
      npm install --global --prefix /home/coder/.local reasonix@1.19.1
    fi
    touch /home/coder/.profile
    grep -Fqx 'export PATH="/home/coder/.local/bin:$PATH"' /home/coder/.profile || \
      printf '%s\n' 'export PATH="/home/coder/.local/bin:$PATH"' >> /home/coder/.profile
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
    %{endif~}
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
  count      = data.coder_workspace.me.start_count > 0 && local.git_repo_set ? 1 : 0
  source     = "registry.coder.com/coder/git-clone/coder"
  version    = "2.0.2"
  agent_id   = coder_agent.main.id
  url        = local.git_repo_url
  base_dir   = "/home/coder/project"
  depends_on = [data.coder_external_auth.github]
}

module "code_server" {
  count      = data.coder_workspace.me.start_count
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

module "codex" {
  count    = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder-labs/codex/coder"
  version  = "5.3.0"
  agent_id = coder_agent.main.id
  workdir  = local.workspace_dir
}

module "claude_code" {
  count    = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
  source   = "registry.coder.com/coder/claude-code/coder"
  version  = "5.2.0"
  agent_id = coder_agent.main.id
  workdir  = local.workspace_dir
}

module "opencode" {
  count            = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
  source           = "registry.coder.com/coder-labs/opencode/coder"
  version          = "0.1.2"
  agent_id         = coder_agent.main.id
  workdir          = local.workspace_dir
  icon             = "/icon/opencode.svg"
  report_tasks     = false
  cli_app          = false
  install_agentapi = false

  pre_install_script = <<-EOT
    #!/bin/bash
    set -euo pipefail
    mkdir -p /home/coder/.local/bin
    if [ ! -x /home/coder/.local/bin/agentapi ]; then
      curl --retry 5 --retry-delay 5 --fail --retry-all-errors -L \
        -o /home/coder/.local/bin/agentapi \
        https://github.com/coder/agentapi/releases/download/v0.11.2/agentapi-linux-amd64
      chmod +x /home/coder/.local/bin/agentapi
    fi
  EOT
}

resource "coder_app" "codex" {
  count        = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
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
    cd ${local.workspace_dir}
    exec codex
  EOT
}

resource "coder_app" "claude_code" {
  count        = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
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
    cd ${local.workspace_dir}
    exec claude
  EOT
}

resource "coder_app" "opencode_cli" {
  count        = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
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
    cd ${local.workspace_dir}
    exec opencode
  EOT
}

resource "coder_app" "reasonix" {
  count        = var.profile == "agent" ? data.coder_workspace.me.start_count : 0
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
    cd ${local.workspace_dir}
    exec reasonix
  EOT
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
        node_selector = local.node_selector

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
    value = local.git_repo_set ? local.git_repo_url : "Empty project"
  }

  item {
    key   = "Working directory"
    value = local.workspace_dir
  }
}
