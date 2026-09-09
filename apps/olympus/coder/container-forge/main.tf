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
  default     = "atlas"

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
  storage_classes = {
    fast      = "coder-fast"
    resilient = "coder-resilient"
    bulk      = "coder-bulk"
  }
  forge_presets = {
    quick = {
      name         = "Quick Image"
      description  = "Small Dockerfiles, utility images, and rapid experiments."
      icon         = "/icon/docker.svg"
      default      = false
      cpu          = "4"
      memory       = "8"
      home_disk    = "20"
      cache_disk   = "10"
      storage_tier = "fast"
      node         = "atlas"
    }
    standard = {
      name         = "Standard Forge"
      description  = "Balanced capacity for normal offline image bundles."
      icon         = "/icon/container.svg"
      default      = false
      cpu          = "8"
      memory       = "24"
      home_disk    = "20"
      cache_disk   = "20"
      storage_tier = "fast"
      node         = "atlas"
    }
    fast = {
      name         = "Fast Iteration"
      description  = "SSD-backed caching on Atlas for repeated image rebuilds."
      icon         = "/icon/code.svg"
      default      = false
      cpu          = "12"
      memory       = "24"
      home_disk    = "20"
      cache_disk   = "40"
      storage_tier = "fast"
      node         = "atlas"
    }
    cuda = {
      name         = "Large CUDA Image"
      description  = "Atlas compute with bulk storage for multi-stage CUDA/PyTorch images; requires the Precision 7810 storage node online."
      icon         = "/icon/pytorch.svg"
      default      = false
      cpu          = "24"
      memory       = "40"
      home_disk    = "350"
      cache_disk   = "100"
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
  description  = "Capacity in GiB for build contexts, archives, logs, and agent state. Files survive stops and restarts. Deleting the workspace deletes its disk; export needed files first. Daily backups are separate."
  type         = "number"
  form_type    = "slider"
  default      = "20"
  mutable      = false
  order        = 40
  icon         = "/icon/database.svg"

  validation {
    min = 20
    max = 500
  }
}

data "coder_parameter" "cache_disk_size" {
  name         = "cache_disk_size"
  display_name = "Ephemeral builder cache"
  description  = "Node-local Kaniko cache in GiB. It is deleted when the builder pod is recreated and consumes no Longhorn capacity."
  type         = "number"
  form_type    = "slider"
  default      = "20"
  mutable      = false
  order        = 50
  icon         = "/icon/database.svg"

  validation {
    min = 10
    max = 100
  }
}

data "coder_parameter" "storage_tier" {
  name         = "storage_tier"
  display_name = "Storage tier"
  description  = "Fast SSD is the reliable default. Bulk depends on the Precision 7810 storage node being online."
  form_type    = "radio"
  default      = "fast"
  mutable      = false
  order        = 60
  icon         = "/icon/database.svg"

  option {
    name        = "Bulk HDD · requires online 7810"
    value       = "bulk"
    description = "Large one-replica archives and caches. Volumes cannot start while precision-7810-01 is offline."
    icon        = "/icon/database.svg"
  }
  option {
    name        = "Fast SSD · 2 replicas"
    value       = "fast"
    description = "Recommended default; starts on Atlas even when the bulk-storage node is unavailable."
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
    description = "Bulk-storage host; unavailable whenever this node is offline."
    icon        = "/icon/node.svg"
  }

  option {
    name        = "Atlas · 72 CPU / 62 GiB"
    value       = "atlas"
    description = "Recommended default for reliable builds and high-memory image assembly."
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
    "OLYMPUS_WORKSPACE_DIR"            = local.workspace_dir
    "OLYMPUS_EXPORTS_BASE_PATH"        = local.exports_base_path
    "DISABLE_AUTOUPDATER"              = "1"
    "OPENCODE_DISABLE_AUTOUPDATE"      = "true"
    "PATH"                             = "/opt/olympus/bin:/usr/local/bin:/home/coder/.local/bin:/home/coder/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "FORGE_NAMESPACE"                  = var.namespace
    "FORGE_BUILDER_POD"                = local.builder_pod
    "FORGE_KANIKO_IMAGE"               = var.kaniko_image
    "FORGE_PLATFORM"                   = "linux/amd64"
    "FORGE_WORKSPACE_ID"               = data.coder_workspace.me.id
    "FORGE_WORKSPACE_NAME"             = data.coder_workspace.me.name
    "FORGE_EXPORTS"                    = "/home/coder/exports"
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

  startup_script          = templatefile("${path.module}/forge-bootstrap.sh.tftpl", {})
  startup_script_behavior = "non-blocking"
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
  group        = "Development"
  order        = 1
  open_in      = "slim-window"
  command      = <<-EOT
    #!/bin/bash
    set -e
    export PATH="/opt/olympus/bin:/usr/local/bin:/home/coder/.local/bin:/home/coder/.opencode/bin:$PATH"
    exec olympus-session container-forge '${local.workspace_dir}'
  EOT
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
  count        = data.coder_workspace.me.start_count
  agent_id     = coder_agent.main.id
  slug         = "exports"
  display_name = "Container Exports"
  icon         = "/icon/folder.svg"
  group        = "Development"
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
        "olympus.dev/component"  = "workspace"
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
        node_selector        = local.node_selector
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
      "olympus.dev/component"  = "builder"
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
        "olympus.dev/component"  = "builder"
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
        automount_service_account_token  = false
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
          empty_dir {
            size_limit = "${data.coder_parameter.cache_disk_size.value}Gi"
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
    value = "${data.coder_parameter.cache_disk_size.value} GiB · node-local ephemeral"
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
  count         = data.coder_workspace.me.start_count
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
