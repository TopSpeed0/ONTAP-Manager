<#
.SYNOPSIS
    Find WHERE a symlink file physically sits on the cluster — which volume and path.

.DESCRIPTION
    Answers the question ONTAP has no command for: given a DFS link name, which volume holds the
    symlink FILE? `vserver cifs symlink show` and the REST unix-symlink-mapping endpoint both
    report only the widelink's bare unix_path and its TARGET share — never the file's location.
    (Verified with fields=** on the REST endpoint: no such field exists.)

    So it is discovered by scanning volumes for directory entries of type 'symlink'.

    Deliberately makes no assumption about volume naming: on svm_example the documented DFS roots
    were the *DFS* named volumes, but symlink files also live in VolX, VolY,
    VolZ, and nested inside qtrees on datavol2 and bigvol1.

.PARAMETER Name
    Match the symlink file name (wildcards allowed). E.g. 'Link1', '*APP1*'.

.PARAMETER Target
    Match the symlink target instead. E.g. '/Link1'.

.PARAMETER Depth
    Directory levels below each volume root to search. Default 1. Use 0 for roots only, higher
    to find symlinks buried deeper (slower).

.PARAMETER WidelinkOnly
    Only return symlinks that have a CIFS widelink table entry, i.e. real DFS links. Excludes
    plain UNIX symlinks such as application links.

.PARAMETER ResolveTarget
    Also follow the chain past the widelink to the real storage: share -> share path -> target
    volume + qtree, with the qtree verified against the qtree table. On by default; use
    -ResolveTarget:$false to skip the extra cluster reads.

.EXAMPLE
    .\Find-NcSymlinkFile.ps1 -Name Link1

    Volume : DFSROOT_B              <- where the symlink FILE sits
    FilePath : Link1
    Target : /Link1
    Share  : Link1$
    TargetPath : /bigvol1/Link1_Q    <- where it LANDS
    TargetVolume : bigvol1
    TargetQtree : Link1_Q
    TargetIsQtree : True
    TargetKind : Qtree

.EXAMPLE
    .\Find-NcSymlinkFile.ps1 -Name '*APP1*'
    # Finds /DFSROOT_A/APP1, /DFSROOT_B/APP1 and the nested /bigvol1/APP1_Q/APP1_Old

.EXAMPLE
    .\Find-NcSymlinkFile.ps1            # every symlink file on the SVM
    .\Find-NcSymlinkFile.ps1 -Depth 2   # search deeper
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$Target,
    [int]$Depth = 1,
    [switch]$WidelinkOnly,
    [string]$Vserver,
    [string]$DFSCleanupConfigPath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path

Import-Module (Join-Path $ScriptDir 'Get-NaApiCred.psm1') -Force
Import-Module (Join-Path $ScriptDir 'Get-DFSCleanupAnalytics.psm1') -Force

$cfgPath = if ($DFSCleanupConfigPath) { $DFSCleanupConfigPath } else { Join-Path $RepoRoot 'Config_DFSCleanup.json' }
if (-not (Test-Path -LiteralPath $cfgPath)) { throw "Config_DFSCleanup.json not found at '$cfgPath'." }
$c = (Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json).DFSCleanup

$main = Get-Content -LiteralPath (Join-Path $RepoRoot 'config.json') -Raw | ConvertFrom-Json
$svm = if ($Vserver) { $Vserver } else { $main.DFS_Config.($c.ClusterAlias).Vserver }

Write-Host "Scanning $($c.RestHost) / $svm for symlink files (depth $Depth)..." -ForegroundColor Cyan

$meta = Get-NaApiCred -CyberArkAppId $c.CyberArk.AppId -CyberArkUsername $c.CyberArk.UserName `
                      -CCPAddress $c.CyberArk.CCPAddress -netappCluster $c.RestHost
$ctx = Get-NaRestContext -RestHost $c.RestHost -Username $meta.UserName `
                         -Password ($meta.Content | ConvertTo-SecureString -AsPlainText -Force)

# Widelink table: used to tell a DFS widelink from a plain UNIX symlink, and to show the share.
# Share and qtree tables: used to follow the chain through to the real volume/qtree the link
# lands on. All fetched once — a per-symlink lookup would be 200+ round trips.
$wl = @{}
$shareByName = @{}
$qtreeSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

try {
    if (-not $global:CurrentNcController) { $null = Connect-NcController $c.ClusterAlias }

    foreach ($w in @(Get-NcCifsSymlink -VserverContext $svm)) {
        $wl["$($w.UnixPath)".Trim('/').ToLowerInvariant()] = $w.ShareName
    }
    foreach ($s in @(Get-NcCifsShare -VserverContext $svm)) {
        if (-not $shareByName.ContainsKey($s.ShareName)) { $shareByName[$s.ShareName] = $s }
    }
    # Exact volume+qtree keys. Matching with -eq rather than -match on purpose: -match is a
    # regex, so a qtree 'Link1_Q' would also match 'Link1_Q2' or 'Link1_Q_old'.
    foreach ($q in @(Get-NcQtree -VserverContext $svm)) {
        if ($q.Qtree) { [void]$qtreeSet.Add("$($q.Volume)/$($q.Qtree)") }
    }
}
catch { Write-Warning "Could not read cluster tables ($($_.Exception.Message)) — target columns may be blank." }

$all = @(Find-NaDFSContainerVolumes -Context $ctx -Vserver $svm -MaxDepth $Depth -MaxUsedGB 0)
$summary = $all | Where-Object { $_.IsSummary } | Select-Object -First 1

# Resolution lives in Resolve-NaSymlinkChain so this script and the workbook's Symlink_Map sheet
# can never disagree about what a symlink points at. Filtering stays here — it is this script's job.
$resolved = @(Resolve-NaSymlinkChain -Containers @($all | Where-Object { -not $_.IsSummary }) `
                -WidelinkMap $wl -ShareMap $shareByName -QtreeSet $qtreeSet `
                -CifsAlias $main.DFS_Config.($c.ClusterAlias).CifsAlias)

$results = @($resolved | Where-Object {
    # -Name matches the file's leaf name, which is what a person knows; FilePath may be nested.
    $leaf = ($_.FilePath -split '/')[-1]
    (-not $Name   -or $leaf -like $Name) -and
    (-not $Target -or "$($_.Target)" -like $Target) -and
    (-not $WidelinkOnly -or $_.IsWidelink)
})

$results | Sort-Object Volume, FilePath

if ($summary) {
    foreach ($sk in @($summary.SkippedVolumes)) {
        Write-Warning "NOT SCANNED: $($sk.Volume) — $($sk.Reason)"
    }
    foreach ($f in @($summary.FailedVolumes)) {
        Write-Warning "COULD NOT LIST: $($f.Volume) — $($f.Reason)"
    }
}
Write-Host "Matched $(@($results).Count) symlink file(s)." -ForegroundColor Green
