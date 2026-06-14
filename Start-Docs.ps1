# Start-Docs.ps1 — Launch the ONTAP Manager docs hub.
# Checks for Python, starts HTTP server on the port from config.json, opens browser.
# Usage: .\Start-Docs.ps1        (uses Docs_Port from config.json, default 8080)
#        .\Start-Docs.ps1 -Port 9090   (override port)

param([int]$Port)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --- Load config.json for port ---
$configPath = Join-Path $root 'config.json'
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not $Port -and $cfg.Docs_Port) { $Port = $cfg.Docs_Port }
}
if (-not $Port) { $Port = 8080 }

# --- Ensure Python is available ---
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    $py = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $py) {
    Write-Host "Python not found. Installing via winget ..." -ForegroundColor Yellow
    winget install --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
    # Refresh PATH for this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Error "Python install succeeded but 'python' still not in PATH. Restart your terminal and try again."
        return
    }
    Write-Host "Python installed successfully." -ForegroundColor Green
}

Write-Host "Python: $($py.Source)" -ForegroundColor DarkGray

# --- Kill any existing server on this port ----------------------------------
$existing = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
            Where-Object State -eq 'Listen'
if ($existing) {
    $proc = Get-Process -Id $existing.OwningProcess -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -match 'python') {
        Write-Host "Stopping existing Python server on port $Port (PID $($proc.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $proc.Id -Force
        Start-Sleep -Milliseconds 500
    }
}

# --- Start HTTP server in background ----------------------------------------
$url = "http://localhost:$Port/docs/"
Write-Host "Starting docs server on port $Port ..." -ForegroundColor Cyan
$job = Start-Process -FilePath $py.Source -ArgumentList "-m", "http.server", $Port `
       -WorkingDirectory $root -WindowStyle Hidden -PassThru

Start-Sleep -Seconds 1

if ($job.HasExited) {
    Write-Error "Server failed to start. Port $Port may be in use."
    return
}

Write-Host "Docs hub running at $url  (PID $($job.Id))" -ForegroundColor Green
Write-Host "Press Ctrl+C or close this window to stop." -ForegroundColor DarkGray

# --- Open browser -----------------------------------------------------------
Start-Process $url

# --- Load ONTAP config into this session ------------------------------------
Write-Host "Loading ONTAP config ..." -ForegroundColor Cyan
. (Join-Path $root 'Load-Config.ps1')

Write-Host "`nReady! Docs hub is at $url" -ForegroundColor Green
Write-Host "Clusters loaded: $($global:ONTAP_Clusters.Count)" -ForegroundColor Green
