<#
.SYNOPSIS
    Manage the unified public-clean publishing branch.
.EXAMPLE
    .\Switch-Branch.ps1           # Show current branch
    .\Switch-Branch.ps1 public    # Switch to public-clean
    .\Switch-Branch.ps1 publish   # Push public-clean to GitHub main, then Bitbucket public-clean
.NOTES
    public-clean is the single publish branch. The GitHub remote publishes it as main;
    the Bitbucket remote publishes it as public-clean. The legacy master branch is retained
    only for historical/local work and is never selected automatically.
#>
param(
    [ValidateSet('public','bitbucket','publish','status')]
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
    Write-Host "Publish mapping: public-clean -> public/main -> origin/public-clean" -ForegroundColor DarkGray
    return
}

if ($Target -eq 'publish') {
    if ($current -ne 'public-clean') {
        throw "Publish only from public-clean. Current branch: $current"
    }
    if (git status --porcelain) {
        throw "Working tree is not clean. Commit or discard tracked changes before publishing."
    }

    Write-Host "Fetching publish remotes..." -ForegroundColor Cyan
    git fetch --prune public
    git fetch --prune origin
    Write-Host "Pushing public-clean to GitHub public/main..." -ForegroundColor Cyan
    git push public 'public-clean:main'
    Write-Host "Pushing public-clean to Bitbucket origin/public-clean..." -ForegroundColor Cyan
    git push origin 'public-clean:public-clean'
    Write-Host "Published successfully to both remotes." -ForegroundColor Green
    return
}

$targetBranch = switch ($Target) {
    'public'    { 'public-clean' }
    'bitbucket' { 'master' } # legacy compatibility only; publishing still requires public-clean
}

if ($current -eq $targetBranch) {
    Write-Host "Already on $targetBranch" -ForegroundColor Yellow
    return
}

Write-Host "Switching from $current -> $targetBranch ..." -ForegroundColor Cyan
git checkout $targetBranch
Write-Host ""
git log --oneline -3
