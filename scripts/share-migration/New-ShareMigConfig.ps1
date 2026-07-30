<#
.SYNOPSIS
    Interactive builder for Config_shareMig.json using automated AD/NetApp discovery.
.DESCRIPTION
    Walks the user through building a new Config_shareMig.json config by:
    1. Discovering available clusters from config.json
    2. Querying the source cluster for SVMs with CIFS enabled
    3. Discovering domain info from the SVM's CIFS server
    4. Querying AD for domain controllers, DNS servers, site info
    5. Optionally discovering destination domain info
    6. Generating the full config file

    Can also be used non-interactively with parameters for scripted setup.
.EXAMPLE
    .\New-ShareMigConfig.ps1
    # Fully interactive — guided wizard

    .\New-ShareMigConfig.ps1 -SourceCluster example-cluster -SourceVserver example-svm -DestDomain example.invalid
    # Semi-automated with key values pre-supplied
.NOTES
    Requires: Load-Config.ps1 (for cluster definitions), NetApp.ONTAP module, ActiveDirectory module (RSAT)
#>
[CmdletBinding()]
param(
    [string]$SourceCluster,
    [string]$SourceVserver,
    [string]$DestDomain,
    [string]$OutputPath,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# --- Load workspace config for cluster list ---
$configPath = Join-Path $workspaceRoot 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "config.json not found at $workspaceRoot. Run Load-Config.ps1 first."
}
$globalConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$clusters = $globalConfig.ONTAP_Clusters

# --- Credential helper ---
function Get-StoredPassword {
    param([string]$Name)
    $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
    if (Test-Path -LiteralPath $credScript) {
        & $credScript -Name $Name
    } else {
        $null
    }
}

function Get-StoredCredential {
    param([string]$CredName, [string]$UserName)
    # Resolve username from registry if not provided
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $registryFile = Join-Path $workspaceRoot 'credentials\credentials.json'
        if (Test-Path -LiteralPath $registryFile) {
            $registry = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
            if ($registry.PSObject.Properties.Name -contains $CredName) {
                $UserName = $registry.$CredName.UserName
            }
        }
        if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = $CredName }
    }
    $pwd = Get-StoredPassword -Name $CredName
    if ($pwd) {
        $sec = ConvertTo-SecureString $pwd -AsPlainText -Force
        [pscredential]::new($UserName, $sec)
    } else {
        $null
    }
}

# --- Load credential registry for display ---
$credRegistryFile = Join-Path $workspaceRoot 'credentials\credentials.json'
$credRegistry = @{}
if (Test-Path -LiteralPath $credRegistryFile) {
    $regJson = Get-Content -LiteralPath $credRegistryFile -Raw | ConvertFrom-Json
    foreach ($prop in $regJson.PSObject.Properties) {
        $credRegistry[$prop.Name] = $prop.Value.UserName
    }
}

# --- Helper: prompt with default ---
function Read-HostDefault {
    param([string]$Prompt, [string]$Default)
    $display = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $value = Read-Host $display
    if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value }
}

# --- Helper: select from list ---
function Select-FromList {
    param([string]$Title, [object[]]$Items, [string]$DisplayProperty, [switch]$AllowMultiple)
    
    Write-Host "`n  $Title" -ForegroundColor Cyan
    $i = 1
    foreach ($item in $Items) {
        $label = if ($DisplayProperty) { $item.$DisplayProperty } else { $item.ToString() }
        Write-Host "    [$i] $label" -ForegroundColor White
        $i++
    }
    Write-Host ""
    
    if ($AllowMultiple) {
        $input = Read-Host "Select (comma-separated, e.g. 1,2)"
        $indices = $input -split ',' | ForEach-Object { [int]$_.Trim() - 1 }
        $indices | ForEach-Object { $Items[$_] }
    } else {
        $choice = Read-Host "Select number"
        $Items[[int]$choice - 1]
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Share Migration Config Builder" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 1: Select source cluster
# ============================================================================
Write-Host "STEP 1: Source Cluster" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

if (-not $SourceCluster) {
    $clusterList = $clusters | ForEach-Object {
        [pscustomobject]@{
            Display = "$($_.cluster) ($($_.Description))"
            Cluster = $_
        }
    }
    $selected = Select-FromList -Title "Available clusters:" -Items $clusterList -DisplayProperty Display
    $srcClusterObj = $selected.Cluster
} else {
    $srcClusterObj = $clusters | Where-Object { $_.cluster -eq $SourceCluster -or $_.Alias -eq $SourceCluster } | Select-Object -First 1
    if (-not $srcClusterObj) { throw "Cluster '$SourceCluster' not found in config.json" }
}

$srcClusterName = $srcClusterObj.cluster
$srcCredName = $srcClusterObj.API_Cred
Write-Host "  Selected: $srcClusterName" -ForegroundColor Green

# ============================================================================
# STEP 2: Connect to source cluster and discover CIFS SVMs
# ============================================================================
Write-Host "`nSTEP 2: Discover CIFS-enabled SVMs on $srcClusterName" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

$srcHost = if ($srcClusterObj.FallbackIP) { $srcClusterObj.FallbackIP } else { $srcClusterObj.cluster }
$srcCred = Get-StoredCredential -CredName $srcCredName

if (-not $srcCred) {
    Write-Host "  [WARN] Could not load credential '$srcCredName' — will prompt" -ForegroundColor Yellow
    $srcCred = Get-Credential -Message "Admin credential for $srcClusterName"
}

Write-Host "  Connecting to $srcHost..." -ForegroundColor DarkGray
$ncController = Connect-NcController -Name $srcHost -Credential $srcCred -HTTPS -Transient
$Global:CurrentNcController = $ncController

# Get SVMs with CIFS
$svms = Get-NcVserver -Query @{ VserverType = 'data'; State = 'running' } | 
    Where-Object { $_.AllowedProtocols -contains 'cifs' }

if (-not $svms) {
    throw "No CIFS-enabled SVMs found on $srcClusterName"
}

if (-not $SourceVserver) {
    $svmList = $svms | ForEach-Object {
        [pscustomobject]@{
            Display = "$($_.Vserver) [protocols: $($_.AllowedProtocols -join ',')]"
            Svm     = $_
        }
    }
    $selectedSvm = Select-FromList -Title "CIFS-enabled SVMs:" -Items $svmList -DisplayProperty Display
    $srcVserver = $selectedSvm.Svm.Vserver
} else {
    $srcVserver = $SourceVserver
    if ($svms.Vserver -notcontains $srcVserver) {
        Write-Host "  [WARN] $SourceVserver not found among CIFS SVMs — proceeding anyway" -ForegroundColor Yellow
    }
}
Write-Host "  Selected SVM: $srcVserver" -ForegroundColor Green

# ============================================================================
# STEP 3: Discover CIFS server and domain info from source SVM
# ============================================================================
Write-Host "`nSTEP 3: Discover domain configuration from CIFS server" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

$cifsServer = Get-NcCifsServer -VserverContext $srcVserver
if (-not $cifsServer) {
    throw "No CIFS server configured on $srcVserver"
}

$srcDomain = $cifsServer.Domain.ToUpper()
$srcCifsName = $cifsServer.CifsServer
$srcNetbiosAliases = ($cifsServer | Get-NcCifsServerAlias -VserverContext $srcVserver -ErrorAction SilentlyContinue) | 
    Select-Object -ExpandProperty Alias -ErrorAction SilentlyContinue

Write-Host "  CIFS Server: $srcCifsName" -ForegroundColor Green
Write-Host "  Domain: $srcDomain" -ForegroundColor Green
if ($srcNetbiosAliases) {
    Write-Host "  NetBIOS Aliases: $($srcNetbiosAliases -join ', ')" -ForegroundColor Green
}

# Get CIFS preferred DCs (current config)
$cifsOptions = Get-NcCifsOption -VserverContext $srcVserver -ErrorAction SilentlyContinue
$cifsPreferredDc = Get-NcCifsPreferredDc -VserverContext $srcVserver -ErrorAction SilentlyContinue

# Get DNS config from SVM
$dnsConfig = Get-NcNetDns -VserverContext $srcVserver -ErrorAction SilentlyContinue
$srcDnsServers = @()
$srcDnsDomains = @()
if ($dnsConfig) {
    $srcDnsServers = @($dnsConfig.NameServers)
    $srcDnsDomains = @($dnsConfig.Domains)
    Write-Host "  DNS Servers: $($srcDnsServers -join ', ')" -ForegroundColor Green
    Write-Host "  DNS Domains: $($srcDnsDomains -join ', ')" -ForegroundColor Green
}

# ============================================================================
# STEP 4: Discover domain controllers from AD
# ============================================================================
Write-Host "`nSTEP 4: Discover domain controllers for $srcDomain" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

$srcDcList = @()
$srcSiteName = $null

try {
    # Try AD cmdlets — may fail if ADWS unreachable
    $adDomain = Get-ADDomain -Identity $srcDomain -ErrorAction Stop
    $srcSiteName = (Get-ADDomainController -Discover -DomainName $srcDomain -ForceDiscover).Site

    $allDCs = Get-ADDomainController -Filter * -Server $srcDomain -ErrorAction Stop |
        Select-Object HostName, IPv4Address, Site, IsGlobalCatalog, OperatingSystem
    
    Write-Host "  Found $($allDCs.Count) domain controllers:" -ForegroundColor Green
    foreach ($dc in $allDCs) {
        Write-Host "    $($dc.HostName) [$($dc.IPv4Address)] Site=$($dc.Site)" -ForegroundColor DarkGray
    }
    
    $srcDcList = @($allDCs.IPv4Address | Where-Object { $_ })
    
    if (-not $srcSiteName -and $allDCs.Site) {
        $srcSiteName = ($allDCs | Group-Object Site | Sort-Object Count -Descending | Select-Object -First 1).Name
    }
} catch {
    Write-Host "  [WARN] AD discovery failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Using DNS/CIFS preferred DC as fallback" -ForegroundColor Yellow
    
    if ($cifsPreferredDc) {
        $srcDcList = @($cifsPreferredDc.PreferredDc)
    }
    if ($srcDnsServers) {
        $srcDcList = @($srcDcList) + @($srcDnsServers) | Select-Object -Unique
    }
}

if ($srcDcList.Count -eq 0) {
    $manualDc = Read-Host "  Enter source DC IP address(es), comma-separated"
    $srcDcList = @($manualDc -split ',' | ForEach-Object { $_.Trim() })
}

Write-Host "  Source DCs: $($srcDcList -join ', ')" -ForegroundColor Green
if ($srcSiteName) { Write-Host "  Site: $srcSiteName" -ForegroundColor Green }

# ============================================================================
# STEP 5: Destination domain configuration
# ============================================================================
Write-Host "`nSTEP 5: Destination Domain" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

if (-not $DestDomain) {
    $DestDomain = Read-HostDefault -Prompt "  Destination domain FQDN" -Default ""
}
$destDomain = $DestDomain.ToUpper()

$destDcList = @()
$destSiteName = $null
$destDnsServers = @()
$destDnsDomains = @($destDomain.ToLower())

if ($destDomain -ne $srcDomain) {
    Write-Host "  Discovering DCs for $destDomain..." -ForegroundColor DarkGray
    try {
        $destAllDCs = Get-ADDomainController -Filter * -Server $destDomain -ErrorAction Stop |
            Select-Object HostName, IPv4Address, Site, IsGlobalCatalog
        
        Write-Host "  Found $($destAllDCs.Count) domain controllers:" -ForegroundColor Green
        foreach ($dc in $destAllDCs) {
            Write-Host "    $($dc.HostName) [$($dc.IPv4Address)] Site=$($dc.Site)" -ForegroundColor DarkGray
        }
        $destDcList = @($destAllDCs.IPv4Address | Where-Object { $_ })
        $destSiteName = (Get-ADDomainController -Discover -DomainName $destDomain -ForceDiscover -ErrorAction SilentlyContinue).Site
        $destDnsServers = @($destDcList | Select-Object -First 2)
    } catch {
        Write-Host "  [WARN] Dest AD discovery failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $manualDestDc = Read-Host "  Enter destination DC IP(s), comma-separated"
        $destDcList = @($manualDestDc -split ',' | ForEach-Object { $_.Trim() })
        $destDnsServers = $destDcList
    }
    
    # Choose a specific DC for the config (first reachable)
    $destDcForConfig = $null
    foreach ($dc in $destDcList) {
        if (Test-Connection -ComputerName $dc -Count 1 -Quiet -TimeoutSeconds 2) {
            $destDcForConfig = $dc
            break
        }
    }
    if (-not $destDcForConfig) { $destDcForConfig = $destDcList[0] }
    Write-Host "  Selected dest DC: $destDcForConfig" -ForegroundColor Green
} else {
    # Same domain (e.g. Export/Import only, no migration)
    $destDcList = $srcDcList
    $destDcForConfig = $srcDcList[0]
    $destSiteName = $srcSiteName
    $destDnsServers = $srcDnsServers
    $destDnsDomains = $srcDnsDomains
    Write-Host "  Same domain — mirroring source config" -ForegroundColor Green
}

# ============================================================================
# STEP 6: Credential names
# ============================================================================
Write-Host "`nSTEP 6: Credential configuration" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

# List available .cred files
$credDir = Join-Path $workspaceRoot 'credentials'
$availableCreds = @()
if (Test-Path $credDir) {
    $availableCreds = Get-ChildItem -Path $credDir -Filter '*.cred' | 
        ForEach-Object { $_.BaseName } | Sort-Object
}

if ($availableCreds) {
    Write-Host "  Available credentials:" -ForegroundColor DarkGray
    $availableCreds | ForEach-Object {
        $regUser = if ($credRegistry.ContainsKey($_)) { " → $($credRegistry[$_])" } else { '' }
        Write-Host "    • $_$regUser" -ForegroundColor DarkGray
    }
    Write-Host ""
}

$srcDomainCredName = Read-HostDefault -Prompt "  Source domain credential name" -Default ""
# Auto-resolve username from registry
$srcRegUser = if ($srcDomainCredName -and $credRegistry.ContainsKey($srcDomainCredName)) { $credRegistry[$srcDomainCredName] } else { '' }
$srcDomainUser = Read-HostDefault -Prompt "  Source domain user (UPN format, or blank for registry)" -Default $srcRegUser
$destDomainCredName = Read-HostDefault -Prompt "  Destination domain credential name" -Default ""
$destRegUser = if ($destDomainCredName -and $credRegistry.ContainsKey($destDomainCredName)) { $credRegistry[$destDomainCredName] } else { '' }
$destDomainUser = Read-HostDefault -Prompt "  Destination domain user (UPN format, or blank for registry)" -Default $destRegUser

# ============================================================================
# STEP 7: Options
# ============================================================================
Write-Host "`nSTEP 7: Migration options" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

$skipDfs = (Read-HostDefault -Prompt "  Skip DFS handling? (true/false)" -Default "true") -eq 'true'
$skipGroupCreation = (Read-HostDefault -Prompt "  Skip AD group creation (replay ACLs as-is)? (true/false)" -Default "true") -eq 'true'
$groupPrefix = Read-HostDefault -Prompt "  Group name prefix" -Default "ShareMig"
$srcNetbiosAlias = Read-HostDefault -Prompt "  Source NetBIOS alias (for DFS)" -Default ($srcNetbiosAliases | Select-Object -First 1)

# Build OU paths from domain
$srcOuPath = "CN=Users," + (($srcDomain -split '\.' | ForEach-Object { "DC=$_" }) -join ',')
$destOuPath = "CN=Users," + (($destDomain -split '\.' | ForEach-Object { "DC=$_" }) -join ',')

$srcGroupOu = Read-HostDefault -Prompt "  Source group OU path" -Default $srcOuPath
$destGroupOu = Read-HostDefault -Prompt "  Destination group OU path" -Default $destOuPath

# ============================================================================
# STEP 8: Migration pairs
# ============================================================================
Write-Host "`nSTEP 8: Migration pairs" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

$pairs = @()
$addMore = $true

while ($addMore) {
    Write-Host "`n  --- New Pair ---" -ForegroundColor DarkGray
    
    $pairName = Read-HostDefault -Prompt "  Pair name" -Default "${srcVserver}_Migration"
    $pairSrcCluster = Read-HostDefault -Prompt "  Source cluster FQDN" -Default "$($srcClusterObj.cluster)"
    $pairSrcVserver = Read-HostDefault -Prompt "  Source vserver" -Default $srcVserver
    $pairSrcCred = Read-HostDefault -Prompt "  Source cluster credential" -Default $srcCredName
    $pairSrcRegUser = if ($pairSrcCred -and $credRegistry.ContainsKey($pairSrcCred)) { $credRegistry[$pairSrcCred] } else { 'admin' }
    $pairSrcUser = Read-HostDefault -Prompt "  Source cluster username (blank=registry)" -Default $pairSrcRegUser
    
    # For same-SVM migration, dest = source
    $sameSvm = (Read-HostDefault -Prompt "  Same-SVM domain migration (dest=source)? (yes/no)" -Default "yes") -in @('yes','y','true')
    
    if ($sameSvm) {
        $pairDestCluster = $pairSrcCluster
        $pairDestVserver = $pairSrcVserver
        $pairDestCred = $pairSrcCred
        $pairDestUser = $pairSrcUser
    } else {
        $pairDestCluster = Read-HostDefault -Prompt "  Destination cluster FQDN" -Default $pairSrcCluster
        $pairDestVserver = Read-HostDefault -Prompt "  Destination vserver" -Default ""
        $pairDestCred = Read-HostDefault -Prompt "  Destination cluster credential" -Default $pairSrcCred
        $pairDestRegUser = if ($pairDestCred -and $credRegistry.ContainsKey($pairDestCred)) { $credRegistry[$pairDestCred] } else { 'admin' }
        $pairDestUser = Read-HostDefault -Prompt "  Destination cluster username (blank=registry)" -Default $pairDestRegUser
    }
    
    $shareFilter = Read-HostDefault -Prompt "  Share filter (glob pattern)" -Default "*"
    
    $pair = [ordered]@{
        '_comment'                    = if ($sameSvm) { "Same-SVM domain migration — DestinationCluster/Vserver = Source" } else { "" }
        'Name'                        = $pairName
        'SourceCluster'               = $pairSrcCluster
        'SourceVserver'               = $pairSrcVserver
        'SourceCredentialName'        = $pairSrcCred
        'SourceCredentialUserName'    = $pairSrcUser
        'DestinationCluster'          = $pairDestCluster
        'DestinationVserver'          = $pairDestVserver
        'DestinationCredentialName'   = $pairDestCred
        'DestinationCredentialUserName' = $pairDestUser
        'DestinationCifsServerName'   = ''
        'DestinationOU'               = ''
        'CreateDFSLink'               = $false
        'ShareFilter'                 = $shareFilter
    }
    $pairs += $pair
    
    $addMore = (Read-HostDefault -Prompt "  Add another pair? (yes/no)" -Default "no") -in @('yes','y')
}

# ============================================================================
# STEP 9: Preflight settings
# ============================================================================
Write-Host "`nSTEP 9: Preflight test share" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────" -ForegroundColor DarkGray

# Get a test volume for preflight
$testVols = Get-NcVol -Query @{ VserverName = $srcVserver; State = 'online' } |
    Where-Object { $_.Name -ne "${srcVserver}_root" -and $_.VolumeStateAttributes.IsVserverRoot -ne $true } |
    Select-Object -First 5

$preflightPath = '/test_vol'
if ($testVols) {
    Write-Host "  Available volumes:" -ForegroundColor DarkGray
    $testVols | ForEach-Object { Write-Host "    • $($_.Name) (junction: $($_.JunctionPath))" -ForegroundColor DarkGray }
    $preflightPath = Read-HostDefault -Prompt "  Preflight share path (junction path)" -Default ($testVols[0].JunctionPath)
} else {
    $preflightPath = Read-Host "  Preflight share path (junction path)"
}

$preflightShare = Read-HostDefault -Prompt "  Preflight share name" -Default "ShareMig_Test"
$preflightGroup = Read-HostDefault -Prompt "  Preflight test group name" -Default "${groupPrefix}_Test_Group"

# ============================================================================
# BUILD THE CONFIG
# ============================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Building Config_shareMig.json..." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$config = [ordered]@{
    '_comment' = "Generated by New-ShareMigConfig.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    'ShareMigration' = [ordered]@{
        'Domain'                          = $srcDomain
        'SourceDomainController'          = @($srcDcList | Select-Object -First 2)
        'SourceDefaultSiteName'           = $srcSiteName
        'SourceDiscoveryMode'             = if ($srcSiteName) { 'site' } else { 'all' }
        'SourceOrganizationalUnit'        = 'CN=Computers'
        'SourceDomainCredentialName'      = $srcDomainCredName
        'SourceDomainUser'                = $srcDomainUser
        'SourceDnsServers'                = $srcDnsServers
        'SourceDnsDomains'                = $srcDnsDomains
        'SourceNetbiosAlias'              = if ($srcNetbiosAlias) { $srcNetbiosAlias } else { $null }
        'DestinationDomain'               = $destDomain
        'DestinationDomainController'     = $destDcForConfig
        'DestinationDefaultSiteName'      = $destSiteName
        'DestinationDiscoveryMode'        = if ($destSiteName) { 'site' } else { 'all' }
        'DestinationOrganizationalUnit'   = $null
        'DestinationDomainCredentialName' = $destDomainCredName
        'DestinationDomainUser'           = $destDomainUser
        'DestinationDnsServers'           = @($destDnsServers | Select-Object -First 2)
        'DestinationDnsDomains'           = $destDnsDomains
        'DestinationNetbiosAlias'         = $null
        'SkipDFS'                         = $skipDfs
        'CreateDestinationDFSLinks'       = $false
        'DfsRoot'                         = '/vol/DFS'
        'SkipGroupCreation'               = $skipGroupCreation
        'SourceGroupOuPath'               = $srcGroupOu
        'DestinationGroupOuPath'          = $destGroupOu
        'GroupNamePrefix'                 = $groupPrefix
        'ExportRoot'                      = 'scripts/share-migration/exports'
        'LogRoot'                         = 'scripts/share-migration/logs'
        'RequirePreflightApproval'        = $true
        'Preflight'                       = [ordered]@{
            'Cluster'   = "$($srcClusterObj.cluster)"
            'Vserver'   = $srcVserver
            'ShareName' = $preflightShare
            'SharePath' = $preflightPath
            'GroupName' = $preflightGroup
        }
        'Pairs'                           = @($pairs)
    }
}

# Output
if (-not $OutputPath) {
    $OutputPath = Join-Path $workspaceRoot 'Config_shareMig.json'
}

# Backup existing
if (Test-Path -LiteralPath $OutputPath) {
    $backupPath = $OutputPath + ".bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -LiteralPath $OutputPath -Destination $backupPath
    Write-Host "  Backed up existing config to: $backupPath" -ForegroundColor DarkGray
}

$json = $config | ConvertTo-Json -Depth 10
$json | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "`n  Config written to: $OutputPath" -ForegroundColor Green
Write-Host ""

# Summary
Write-Host "  Summary:" -ForegroundColor Cyan
Write-Host "    Source: $srcClusterName / $srcVserver @ $srcDomain" -ForegroundColor White
Write-Host "    Dest:   $destDomain" -ForegroundColor White
Write-Host "    Pairs:  $($pairs.Count)" -ForegroundColor White
Write-Host "    DCs:    $($srcDcList -join ', ') → $destDcForConfig" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Review the generated Config_shareMig.json" -ForegroundColor DarkGray
Write-Host "    2. Run: .\Invoke-ShareMigration.ps1 -Mode Preflight -ApprovePreflight" -ForegroundColor DarkGray
Write-Host "    3. Run: .\Invoke-ShareMigration.ps1 -Mode TestCredentials -Target Both" -ForegroundColor DarkGray
Write-Host ""
