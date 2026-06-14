# profile1.ps1 — NetApp ONTAP workspace profile
# Loads modules and dot-sources Load-Config.ps1 which auto-generates all
# cluster connect/SSH/CSV functions from config.json.
# Dot-source at the start of every pwsh session for this workspace:
#     . .\profile1.ps1

# === Modules ===
Import-Module NetApp.ONTAP -ErrorAction SilentlyContinue

# Optional personal modules — edit these paths if you have them locally
$_personalModules = @(
    # "$env:USERPROFILE\path\to\Get-DFSNameSpaceRoot.psm1",
    # "$env:USERPROFILE\path\to\Get-NcVolAvil.psm1"
)
foreach ($_mod in $_personalModules) {
    if (Test-Path $_mod) { Import-Module $_mod -ErrorAction SilentlyContinue }
}

# === Load config and auto-generate cluster functions ===
# Creates per-cluster: connect func, SSH func (-s), CSV wrapper (Get-<Prefix>Csv), aliases
$rootDir = $PSScriptRoot
. "$PSScriptRoot\Load-Config.ps1"
