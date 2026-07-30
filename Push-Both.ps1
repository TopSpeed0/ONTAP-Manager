<#
.SYNOPSIS
    Push the current branch to both remotes in one step.
.EXAMPLE
    .\Push-Both.ps1           # Push to GitHub main + Bitbucket snapshot-sanitized
    .\Push-Both.ps1 -WhatIf   # Show what would be pushed, push nothing
.NOTES
    One branch, three names:

        local public-clean -> public/main                 (GitHub, PUBLIC)
        local public-clean -> origin/snapshot-sanitized   (Bitbucket, private)

    These Bitbucket branches are never pushed to and must not be overwritten:
        origin/private-history  - the real-names full history (only copy)
        origin/master           - old pre-DFS history, kept for reference
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

$publishBranch = 'public-clean'
$current       = git branch --show-current

if ($current -ne $publishBranch) {
    throw "Push only from '$publishBranch'. Current branch: '$current'."
}
if (git status --porcelain) {
    throw "Working tree is not clean. Commit or discard tracked changes first, then re-run."
}

Write-Host "Local  : $current" -ForegroundColor Cyan
git log --oneline -1
Write-Host ""

$targets = @(
    @{ Remote = 'public'; Branch = 'main';                Label = 'GitHub (PUBLIC)' }
    @{ Remote = 'origin'; Branch = 'snapshot-sanitized';  Label = 'Bitbucket (private)' }
)

foreach ($t in $targets) {
    $refspec = "${publishBranch}:$($t.Branch)"
    $dest    = "$($t.Remote)/$($t.Branch)"

    if (-not $PSCmdlet.ShouldProcess($dest, "git push $($t.Remote) $refspec")) { continue }

    Write-Host "Pushing -> $dest  [$($t.Label)]" -ForegroundColor Cyan
    git push $t.Remote $refspec
    if ($LASTEXITCODE -ne 0) {
        throw "Push to $dest failed. Earlier remotes in this run are already updated."
    }
}

if (-not $WhatIfPreference) {
    Write-Host "Pushed to both remotes." -ForegroundColor Green
}
