# profile1.ps1 — NetApp ONTAP workspace profile
# Loads modules and dot-sources Load-Config.ps1 which auto-generates all
# cluster connect/SSH/CSV functions from config.json.
# Dot-source at the start of every pwsh session for this workspace:
#     . .\profile1.ps1

# === Modules ===
Import-Module NetApp.ONTAP -ErrorAction SilentlyContinue

# === Load config and auto-generate cluster functions ===
# Also loads Personal_modules from config.json (if defined)
# Creates per-cluster: connect func, SSH func (-s), CSV wrapper (Get-<Prefix>Csv), aliases
$rootDir = $PSScriptRoot
. "$PSScriptRoot\Load-Config.ps1"

# === Script Manager ===
# Quick launcher for workspace automation scripts (GUI or console menu)
function global:Start-ScriptManager {
    [CmdletBinding()]
    param([switch]$Console, [string]$Filter)
    & "$PSScriptRoot\scripts\Start-ScriptManager.ps1" @PSBoundParameters
}
Set-Alias -Name sm -Value Start-ScriptManager -Scope Global -Force
