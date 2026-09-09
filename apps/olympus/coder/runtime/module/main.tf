terraform {
  required_providers {
    coder = { source = "coder/coder", version = "~> 2.18.0" }
  }
}

variable "agent_id" { type = string }
variable "workspace_dir" { type = string }

locals {
  private_credentials = <<-EOT
    /usr/bin/python3 - <<'PY'
    from pathlib import Path
    import sys
    credentials = Path.home() / '.dsh/.credentials.yaml'
    try:
        if credentials.is_file():
            credentials.chmod(0o600)
    except OSError:
        print('DeepSeek credential permissions need attention', file=sys.stderr)
    PY
  EOT
  terminals = {
    codex        = { name = "Codex", bin = "codex", icon = "/icon/openai.svg", order = 10 }
    claude-code  = { name = "Claude Code", bin = "claude", icon = "/icon/claude.svg", order = 20 }
    opencode-cli = { name = "OpenCode", bin = "opencode", icon = "/icon/opencode.svg", order = 30 }
    pi           = { name = "Pi", bin = "pi", icon = "/icon/terminal.svg", order = 40 }
    prime-agent  = { name = "Prime Agent", bin = "prime-agent", icon = "/icon/terminal.svg", order = 50 }
    reasonix     = { name = "Reasonix CLI", bin = "reasonix", icon = "/icon/terminal.svg", order = 60 }
    deepseek-cli = { name = "DeepSeek CLI", bin = "dsh", icon = "/icon/terminal.svg", order = 70 }
    grok         = { name = "Grok Build", bin = "grok", icon = "/icon/terminal.svg", order = 80 }
  }
  browsers = {
    deepseek         = { name = "DeepSeek Harness", port = 13340, icon = "/icon/code.svg", order = 10 }
    openhands        = { name = "OpenHands", port = 13341, icon = "/icon/code.svg", order = 20 }
    reasonix-desktop = { name = "Reasonix", port = 8787, icon = "/icon/code.svg", order = 30 }
  }
}

resource "coder_script" "initialize" {
  agent_id           = var.agent_id
  display_name       = "Start editor and agent services"
  icon               = "/icon/code.svg"
  run_on_start       = true
  start_blocks_login = false
  timeout            = 60
  script             = <<-EOT
    set -eu
    ${local.private_credentials}
    /usr/bin/python3 /opt/olympus/runtime/olympus-runtime.py init
  EOT
}

resource "coder_script" "context" {
  agent_id           = var.agent_id
  display_name       = "Configure Olympus workspace tools"
  run_on_start       = true
  start_blocks_login = false
  timeout            = 180
  script             = <<-EOT
    export PATH="/opt/olympus/bin:/usr/local/bin:$PATH"
    mkdir -p "$HOME/.config/zellij"
    if [ ! -e "$HOME/.config/zellij/config.kdl" ]; then
      printf '%s\n' 'default_mode "locked"' 'show_startup_tips false' 'show_release_notes false' > "$HOME/.config/zellij/config.kdl"
    fi
    OLYMPUS_WORKSPACE_SKILL_BASE_URL=file:///opt/olympus/skill bash /opt/olympus/skill/scripts/install-olympus-workspace
    /usr/bin/python3 /opt/olympus/runtime/configure.py
    /usr/bin/python3 /opt/olympus/runtime/configure-canvas.py
  EOT
}

resource "coder_script" "update" {
  agent_id           = var.agent_id
  display_name       = "Check harness releases"
  icon               = "/icon/terminal.svg"
  run_on_start       = true
  start_blocks_login = false
  cron               = "0 */15 * * * *"
  timeout            = 3600
  script             = "/opt/olympus/bin/olympus-agent-update"
}

resource "coder_script" "recover" {
  agent_id           = var.agent_id
  display_name       = "Recover unavailable services"
  start_blocks_login = false
  cron               = "0 * * * * *"
  timeout            = 60
  script             = <<-EOT
    set -eu
    ${local.private_credentials}
    mkdir -p "$HOME/.local/state/olympus"
    exec 9> "$HOME/.local/state/olympus/recover.lock"
    flock -n 9 || exit 0
    if ! /opt/olympus/bin/olympus-services pid >/dev/null 2>&1; then
      /usr/bin/python3 /opt/olympus/runtime/olympus-runtime.py init
    fi
    for service in editor exports reasonix deepseek openhands; do
      state="$(/opt/olympus/bin/olympus-services status "$service" || true)"
      case "$state" in
        *" FATAL "*|*" EXITED "*) /opt/olympus/bin/olympus-services start "$service" ;;
      esac
    done
  EOT
}

resource "coder_app" "terminal" {
  for_each     = local.terminals
  agent_id     = var.agent_id
  slug         = each.key
  display_name = each.value.name
  icon         = each.value.icon
  group        = "Terminal Agents"
  order        = each.value.order
  open_in      = "slim-window"
  command      = "/opt/olympus/bin/olympus-session ${each.key} '${var.workspace_dir}' ${each.value.bin}"
}

resource "coder_app" "browser" {
  for_each     = local.browsers
  agent_id     = var.agent_id
  slug         = each.key
  display_name = each.value.name
  icon         = each.value.icon
  group        = "Browser Agents"
  order        = each.value.order
  url          = "http://localhost:${each.value.port}"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://localhost:${each.value.port}/${each.key == "deepseek" ? "__olympus_health" : ""}"
    interval  = 5
    threshold = 12
  }
}

resource "coder_app" "editor" {
  agent_id     = var.agent_id
  slug         = "code-server"
  display_name = "VS Code"
  icon         = "/icon/code.svg"
  group        = "Development"
  order        = 1
  url          = "http://localhost:13337/?folder=${urlencode(var.workspace_dir)}"
  subdomain    = false
  share        = "owner"
  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 12
  }
}

resource "coder_app" "diagnostics" {
  agent_id     = var.agent_id
  slug         = "diagnostics"
  display_name = "Diagnostics"
  icon         = "/icon/terminal.svg"
  group        = "Maintenance"
  order        = 10
  command      = "bash -c '/opt/olympus/bin/olympus-doctor; exec bash -l'"
}

resource "coder_app" "updates" {
  agent_id     = var.agent_id
  slug         = "updates"
  display_name = "Updates"
  icon         = "/icon/terminal.svg"
  group        = "Maintenance"
  order        = 20
  command      = "bash -c '/opt/olympus/bin/olympus-agent-update; /opt/olympus/bin/olympus-doctor; exec bash -l'"
}
