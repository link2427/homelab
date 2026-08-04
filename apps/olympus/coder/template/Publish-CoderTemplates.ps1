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

if ($catalog.Count -gt 63) {
  throw "Coder supports at most 64 dropdown options. Found $($catalog.Count) repositories plus Empty project; narrow the catalog before publishing."
}

$catalogJson = ConvertTo-Json -InputObject $catalog -Depth 4 -Compress
$templateDirectory = $PSScriptRoot
$templates = @(
  @{ Name = "olympus-linux"; Profile = "linux"; Image = "codercom/example-base:ubuntu" },
  @{ Name = "olympus-agent"; Profile = "agent"; Image = "codercom/example-universal:ubuntu" },
  @{ Name = "olympus-gpu"; Profile = "gpu"; Image = "pytorch/pytorch:2.13.0-cuda12.6-cudnn9-runtime" },
  @{ Name = "olympus-build"; Profile = "build"; Image = "codercom/example-universal:ubuntu" }
)

$variablesFile = Join-Path ([System.IO.Path]::GetTempPath()) "olympus-coder-$([guid]::NewGuid().ToString('N')).tfvars.json"

try {
  foreach ($template in $templates) {
    $variables = [ordered]@{
      profile                  = $template.Profile
      image                    = $template.Image
      github_repositories_json = $catalogJson
    }

    ConvertTo-Json -InputObject $variables -Depth 4 | Set-Content -LiteralPath $variablesFile -Encoding utf8NoBOM
    Write-Host "Publishing $($template.Name) with $($catalog.Count) GitHub repositories..."
    & $CoderBinary templates push $template.Name -d $templateDirectory --variables-file $variablesFile -y -m "Refresh searchable GitHub repository selector"
    if ($LASTEXITCODE -ne 0) {
      throw "Publishing $($template.Name) failed with exit code $LASTEXITCODE."
    }
  }

  $forgeDirectory = Join-Path $PSScriptRoot "..\container-forge"
  $forgeVariables = [ordered]@{
    github_repositories_json = $catalogJson
    namespace                = "coder-forge"
  }
  ConvertTo-Json -InputObject $forgeVariables -Depth 4 | Set-Content -LiteralPath $variablesFile -Encoding utf8NoBOM
  Write-Host "Publishing container-forge with $($catalog.Count) GitHub repositories..."
  & $CoderBinary templates push container-forge -d $forgeDirectory --variables-file $variablesFile -y -m "Repair isolated builder and persistent agent terminals"
  if ($LASTEXITCODE -ne 0) {
    throw "Publishing container-forge failed with exit code $LASTEXITCODE."
  }
}
finally {
  Remove-Item -LiteralPath $variablesFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Published $($templates.Count + 1) templates. No repository catalog was written into the Git checkout."
