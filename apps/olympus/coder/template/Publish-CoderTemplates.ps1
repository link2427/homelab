[CmdletBinding()]
param(
  [string]$Owner = "link2427",
  [switch]$IncludeArchived,
  [switch]$Canary
)
$ErrorActionPreference = "Stop"
# The same publisher runs in the cluster. Local use accepts gh login plus a
# dedicated Coder publisher token; it never extracts an interactive login token.
$publisher = Join-Path $PSScriptRoot "../publisher/publish.py"
$arguments = @($publisher, "--owner", $Owner)
if ($IncludeArchived) { $arguments += "--include-archived" }
if ($Canary) { $arguments += "--canary" }
if (-not $env:CODER_SESSION_TOKEN) {
  throw "Set CODER_SESSION_TOKEN to a template-publishing token; the cluster CronJob handles ordinary refreshes automatically."
}
& python @arguments
if ($LASTEXITCODE -ne 0) { throw "Template publication failed." }
