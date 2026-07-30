<#
.SYNOPSIS
    Publish the sanitized snapshot branch to both remotes.
.EXAMPLE
    .\Switch-Branch.ps1           # Show current branch and the publish mapping
    .\Switch-Branch.ps1 public    # Switch to the publish branch (public-clean)
    .\Switch-Branch.ps1 publish   # Push to GitHub main AND Bitbucket snapshot-sanitized
.NOTES
    public-clean is the local publish branch. It holds the sanitized snapshot and is
    published under a different name on each remote:

        public-clean -> public/main                 (GitHub, public)
        public-clean -> origin/snapshot-sanitized   (Bitbucket, private)

    Two other Bitbucket branches are NOT published to and must not be overwritten:
        origin/private-history  - the real-names full history (only copy)
        origin/master           - old pre-DFS history, kept for reference
#>
param(
    [ValidateSet('public','publish','status')]
    [string]$Target = 'status'
)

$publishBranch = 'public-clean'
$current = git branch --show-current

if ($Target -eq 'status') {
    Write-Host "Branch : $current" -ForegroundColor Cyan
    git log --oneline -3
    Write-Host ""
    Write-Host "Publish mapping:" -ForegroundColor DarkGray
    Write-Host "  $publishBranch -> public/main               (GitHub)"    -ForegroundColor DarkGray
    Write-Host "  $publishBranch -> origin/snapshot-sanitized (Bitbucket)" -ForegroundColor DarkGray
    return
}

if ($Target -eq 'publish') {
    if ($current -ne $publishBranch) {
        throw "Publish only from $publishBranch. Current branch: $current"
    }
    if (git status --porcelain) {
        throw "Working tree is not clean. Commit or discard tracked changes before publishing."
    }

    Write-Host "Fetching publish remotes..." -ForegroundColor Cyan
    git fetch --prune public
    git fetch --prune origin

    Write-Host "Pushing to GitHub public/main..." -ForegroundColor Cyan
    git push public "${publishBranch}:main"
    if ($LASTEXITCODE -ne 0) { throw "GitHub push failed - stopping before the Bitbucket push." }

    Write-Host "Pushing to Bitbucket origin/snapshot-sanitized..." -ForegroundColor Cyan
    git push origin "${publishBranch}:snapshot-sanitized"
    if ($LASTEXITCODE -ne 0) { throw "Bitbucket push failed. GitHub is already updated." }

    Write-Host "Published to both remotes." -ForegroundColor Green
    return
}

# $Target -eq 'public'
if ($current -eq $publishBranch) {
    Write-Host "Already on $publishBranch" -ForegroundColor Yellow
    return
}

Write-Host "Switching from $current -> $publishBranch ..." -ForegroundColor Cyan
git checkout $publishBranch
Write-Host ""
git log --oneline -3
