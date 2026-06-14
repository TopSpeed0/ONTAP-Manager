<#
.SYNOPSIS
    Switch between public-clean (GitHub) and master (Bitbucket) branches.
.EXAMPLE
    .\Switch-Branch.ps1           # Show current branch
    .\Switch-Branch.ps1 public    # Switch to public-clean
    .\Switch-Branch.ps1 bitbucket # Switch to master
#>
param(
    [ValidateSet('public','bitbucket','status')]
    [string]$Target = 'status'
)

$current = git branch --show-current

if ($Target -eq 'status') {
    $label = switch ($current) {
        'public-clean' { 'PUBLIC (GitHub)' }
        'master'       { 'BITBUCKET (master)' }
        default        { $current }
    }
    Write-Host "Branch : $current  [$label]" -ForegroundColor Cyan
    git log --oneline -3
    return
}

$targetBranch = switch ($Target) {
    'public'    { 'public-clean' }
    'bitbucket' { 'master' }
}

if ($current -eq $targetBranch) {
    Write-Host "Already on $targetBranch" -ForegroundColor Yellow
    return
}

Write-Host "Switching from $current -> $targetBranch ..." -ForegroundColor Cyan
git checkout $targetBranch
Write-Host ""
git log --oneline -3
