[CmdletBinding()]
param(
  [string]$Owner,
  [string]$CoderBinary = "coder",
  [switch]$IncludeArchived
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is required. Install it and run 'gh auth login' first."
}

if (-not (Get-Command $CoderBinary -ErrorAction SilentlyContinue)) {
  throw "Coder CLI '$CoderBinary' was not found. Install it and run 'coder login <your Coder URL>' first."
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
  throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
}

if ([string]::IsNullOrWhiteSpace($Owner)) {
  $Owner = (gh api user --jq .login).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Owner)) {
    throw "Could not determine the authenticated GitHub account."
  }
}

$rawRepositories = gh repo list $Owner --limit 1000 --json nameWithOwner,url,isPrivate,isArchived,isFork,description,pushedAt
if ($LASTEXITCODE -ne 0) {
  throw "Could not list repositories for '$Owner'."
}

$repositories = @($rawRepositories | ConvertFrom-Json)
if (-not $IncludeArchived) {
  $repositories = @($repositories | Where-Object { -not $_.isArchived })
}

$catalog = @(
  $repositories |
    Sort-Object @{ Expression = "pushedAt"; Descending = $true }, nameWithOwner |
    ForEach-Object {
      [ordered]@{
        name        = $_.nameWithOwner
        url         = "$($_.url).git"
        visibility  = if ($_.isPrivate) { "private" } else { "public" }
        archived    = [bool]$_.isArchived
        fork        = [bool]$_.isFork
        description = if ($null -eq $_.description) { "" } else { [string]$_.description }
      }
    }
)

if ($catalog.Count -gt 61) {
  throw "Coder supports at most 64 dropdown options. Found $($catalog.Count) repositories plus Empty, Create, and Fork actions; narrow the catalog before publishing."
}

$catalogJson = ConvertTo-Json -InputObject $catalog -Depth 4 -Compress
$templateDirectory = $PSScriptRoot
$templates = @(
  @{
    Name        = "olympus-linux"
    DisplayName = "Olympus Linux"
    Description = "Flexible Ubuntu development with persistent storage and explicit cluster placement."
    Icon        = "/icon/ubuntu.svg"
    Profile     = "linux"
    Image       = "codercom/example-base:ubuntu"
  },
  @{
    Name        = "olympus-agent"
    DisplayName = "Olympus Agent"
    Description = "Persistent autonomous-agent workspace with Codex, Claude Code, OpenCode, Prime Agent, and Reasonix."
    Icon        = "/icon/openai.svg"
    Profile     = "agent"
    Image       = "codercom/example-universal:ubuntu"
  },
  @{
    Name        = "olympus-gpu"
    DisplayName = "Olympus GPU"
    Description = "PyTorch and Jupyter workspace with an explicit M4000, P2000, or P40 reservation."
    Icon        = "/icon/pytorch.svg"
    Profile     = "gpu"
    Image       = "pytorch/pytorch:2.13.0-cuda12.6-cudnn9-runtime"
  },
  @{
    Name        = "olympus-build"
    DisplayName = "Olympus Build"
    Description = "High-capacity compilation workspace with SSD or economical bulk storage."
    Icon        = "/icon/code.svg"
    Profile     = "build"
    Image       = "codercom/example-universal:ubuntu"
  }
)

$variablesFile = Join-Path ([System.IO.Path]::GetTempPath()) "olympus-coder-$([guid]::NewGuid().ToString('N')).tfvars.json"

try {
  foreach ($template in $templates) {
    $variables = [ordered]@{
      profile                  = $template.Profile
      image                    = $template.Image
      github_owner             = $Owner
      github_repositories_json = $catalogJson
    }

    ConvertTo-Json -InputObject $variables -Depth 4 | Set-Content -LiteralPath $variablesFile -Encoding utf8NoBOM
    Write-Host "Publishing $($template.Name) with $($catalog.Count) GitHub repositories..."
    & $CoderBinary templates push $template.Name -d $templateDirectory --variables-file $variablesFile -y -m "Refresh managed Olympus workspace catalog"
    if ($LASTEXITCODE -ne 0) {
      throw "Publishing $($template.Name) failed with exit code $LASTEXITCODE."
    }

    & $CoderBinary templates edit $template.Name --display-name $template.DisplayName --description $template.Description --icon $template.Icon -y
    if ($LASTEXITCODE -ne 0) {
      throw "Updating metadata for $($template.Name) failed with exit code $LASTEXITCODE."
    }
  }

  $forgeDirectory = Join-Path $PSScriptRoot "..\container-forge"
  $forgeVariables = [ordered]@{
    github_repositories_json = $catalogJson
    github_owner             = $Owner
    namespace                = "coder-forge"
    workspace_image          = "codercom/example-base:ubuntu"
    kaniko_image             = "ghcr.io/osscontainertools/kaniko:v1.28.2-alpine@sha256:44f90ae1ba366aeedbd0f2d56dbe246354553e47904338dd9321a41a44bea9ff"
    kubectl_version          = "v1.35.2"
    build_node               = "atlas"
  }
  ConvertTo-Json -InputObject $forgeVariables -Depth 4 | Set-Content -LiteralPath $variablesFile -Encoding utf8NoBOM
  Write-Host "Publishing container-forge with $($catalog.Count) GitHub repositories..."
  & $CoderBinary templates push container-forge -d $forgeDirectory --variables-file $variablesFile -y -m "Refresh managed Olympus workspace catalog"
  if ($LASTEXITCODE -ne 0) {
    throw "Publishing container-forge failed with exit code $LASTEXITCODE."
  }
  & $CoderBinary templates edit container-forge `
    --display-name "Olympus Container Forge" `
    --description "Build and export Docker-compatible Linux/amd64 images for offline transfer." `
    --icon "/icon/container.svg" `
    -y
  if ($LASTEXITCODE -ne 0) {
    throw "Updating metadata for container-forge failed with exit code $LASTEXITCODE."
  }
}
finally {
  Remove-Item -LiteralPath $variablesFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Published $($templates.Count + 1) templates. No repository catalog was written into the Git checkout."
