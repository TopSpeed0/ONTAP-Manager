<#
.SYNOPSIS
    Export and import SMB share configuration, ACLs, and AD group mappings.
.DESCRIPTION
    Reads config.json and Config_shareMig.json, then exports SMB share state from one or more
    source SVMs and imports it to destination SVMs. When ACL entries reference individual
    users, the script can create AD groups and add those users before applying share ACLs.

    The workflow is intentionally config-driven:
      - config.json provides cluster definitions and credential names
      - Config_shareMig.json provides share-migration pairs and AD policy

    Generated JSON exports and logs are written under scripts/share-migration/exports and logs.
.NOTES
    This script uses the repo's existing ONTAP SSH helpers and Add-NcCredential / Get-NcCredential
    pattern for cluster auth checks.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Export', 'Import', 'Preflight', 'Sync', 'DomainMigration', 'Rollback', 'TestCredentials', 'ResetCifsPassword')]
    [string]$Mode = 'Export',

    [string]$ShareMigrationConfigPath,
    [string]$SnapshotPath,
    [string]$OutputRoot,

    [string]$SourceCluster,
    [string]$SourceVserver,
    [string]$DestinationCluster,
    [string]$DestinationVserver,

    [pscredential]$DomainCredential,
    [string]$DomainController,

    [ValidateSet('Source', 'Destination', 'Both')]
    [string]$Target = 'Both',

    [switch]$ApprovePreflight,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-ShareMigLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'PASS')] [string]$Level = 'INFO'
    )

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    if ($script:ShareMigLogFile) {
        Add-Content -LiteralPath $script:ShareMigLogFile -Value $line
    }
}

function Get-WorkspaceRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function ConvertTo-SafeName {
    param([Parameter(Mandatory)] [string]$Name)
    ($Name -replace '[^A-Za-z0-9]+', '_').Trim('_')
}

function Get-ShareMigrationConfig {
    param([Parameter(Mandatory)] [string]$WorkspaceRoot, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $WorkspaceRoot 'Config_shareMig.json'
    }

    $templatePath = Join-Path $WorkspaceRoot 'Config_shareMig.template.json'
    if (-not (Test-Path -LiteralPath $Path)) {
        if (Test-Path -LiteralPath $templatePath) {
            Copy-Item -LiteralPath $templatePath -Destination $Path
            throw "Config_shareMig.json was created from the template at $Path. Edit it and rerun the script."
        }
        throw "Config_shareMig.json not found and template missing at $templatePath"
    }

    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-ShareMigSkipDFS {
    param([Parameter(Mandatory)] $Config)

    return [bool]($Config.ShareMigration.SkipDFS)
}

function Test-ShareMigCreateDestinationDFSLinks {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Pair
    )

    if ($Pair.PSObject.Properties.Name -contains 'CreateDFSLink') {
        return [bool]$Pair.CreateDFSLink
    }

    return [bool]($Config.ShareMigration.CreateDestinationDFSLinks)
}

function Get-ShareMigDfsRoot {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Pair
    )

    if ($Pair.PSObject.Properties.Name -contains 'DfsRoot' -and $Pair.DfsRoot) {
        return [string]$Pair.DfsRoot
    }

    return [string]$Config.ShareMigration.DfsRoot
}

function Resolve-ClusterEntry {
    param(
        [Parameter(Mandatory)] [string]$ClusterName,
        [Parameter(Mandatory)] $ClusterList
    )

    $match = $ClusterList | Where-Object {
        $_.Alias -eq $ClusterName -or $_.ClusterName -eq $ClusterName -or $_.ConnectName -eq $ClusterName
    }
    if (-not $match) {
        throw "Cluster '$ClusterName' was not found in config.json"
    }
    $match | Select-Object -First 1
}

function Get-ClusterCredential {
    param(
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [Parameter(Mandatory)] [string]$CredentialName,
        [Parameter(Mandatory)] [string]$UserName
    )

    $credPath = Join-Path $WorkspaceRoot "credentials\$CredentialName.cred"
    if (Test-Path -LiteralPath $credPath) {
        $sec = & (Join-Path $WorkspaceRoot 'scripts\credentials\Get-Credential.ps1') -Name $CredentialName -AsSecureString
        return [pscredential]::new($UserName, $sec)
    }

    Write-ShareMigLog "Credential file not found for '$CredentialName'. Prompting interactively." 'WARN'
    return Get-Credential -UserName $UserName -Message "Enter password for $UserName ($CredentialName)"
}

function Ensure-NcCredential {
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [pscredential]$Credential
    )

    if (Get-NcCredential -Controller $ControllerName) {
        Write-ShareMigLog "Found cached NetApp credential for $ControllerName" 'PASS'
        return
    }

    Write-ShareMigLog "Caching NetApp credential for $ControllerName" 'INFO'
    Add-NcCredential -Controller $ControllerName -Credential $Credential -ErrorAction Stop | Out-Null
}

# Well-known principals that exist outside AD — skip AD lookups for these.
$script:WellKnownPrincipals = @('Everyone', 'BUILTIN\Administrators', 'BUILTIN\Users', 'BUILTIN\Backup Operators', 'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\Authenticated Users')

function Invoke-ShareMigCli {
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [string]$Command
    )

    $sshFunc = "$ControllerName-s"
    if (-not (Get-Command $sshFunc -ErrorAction SilentlyContinue)) {
        throw "SSH helper '$sshFunc' was not found. Run Load-Config.ps1 first."
    }

    $wrapped = "set advanced -confirmations off; $Command"
    $raw = & $sshFunc -Command $wrapped
    # Check for ONTAP error patterns in output
    $errors = @($raw | Where-Object { $_ -match '^\s*Error:' -or $_ -match 'command failed' })
    if ($errors.Count -gt 0) {
        $errMsg = $errors -join '; '
        throw "ONTAP command failed on $ControllerName`: $errMsg (Command: $Command)"
    }
    return $raw
}

function Stop-ShareMigCifs {
    <#
    .SYNOPSIS
        Delete (unjoin) the CIFS server from its current domain via PowerShell ZAPI.
    #>
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$DomainAdminUser,
        [Parameter(Mandatory)] [string]$DomainAdminPassword
    )

    Write-ShareMigLog "Stopping CIFS server on $Vserver (leaving domain)" 'INFO'
    $cluster = Resolve-ClusterEntry -ClusterName $ControllerName -ClusterList $global:ONTAP_Clusters
    & $cluster.ConnectName | Out-Null
    Remove-NcCifsServer -AdminUsername $DomainAdminUser -AdminPassword $DomainAdminPassword -VserverContext $Vserver -ErrorAction Stop -Confirm:$false
    Write-ShareMigLog "CIFS server deleted from $Vserver — left domain successfully" 'PASS'
}

function Start-ShareMigCifs {
    <#
    .SYNOPSIS
        Create (join) the CIFS server to a new domain via ZAPI (Add-NcCifsServer).
        Supports -DefaultSiteName and -NetbiosAliases natively.
    #>
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$CifsServerName,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$DomainAdminUser,
        [Parameter(Mandatory)] [string]$DomainAdminPassword,
        [string]$OrganizationalUnit,
        [string]$DefaultSiteName,
        [string[]]$NetbiosAliases
    )

    $cluster = Resolve-ClusterEntry -ClusterName $ControllerName -ClusterList $global:ONTAP_Clusters
    & $cluster.ConnectName | Out-Null

    $siteInfo = if ($DefaultSiteName) { " (site: $DefaultSiteName)" } else { '' }
    Write-ShareMigLog "Creating CIFS server '$CifsServerName' on $Vserver — joining domain $Domain$siteInfo" 'INFO'

    $params = @{
        Name            = $CifsServerName
        Domain          = $Domain
        AdminUsername   = $DomainAdminUser
        AdminPassword   = $DomainAdminPassword
        VserverContext  = $Vserver
        Force           = $true
        ErrorAction     = 'Stop'
    }
    if ($OrganizationalUnit) { $params['OrganizationalUnit'] = $OrganizationalUnit }
    if ($DefaultSiteName)    { $params['DefaultSite']        = $DefaultSiteName }
    if ($NetbiosAliases)     { $params['NetbiosAlias']       = $NetbiosAliases }

    Add-NcCifsServer @params
    Write-ShareMigLog "CIFS server '$CifsServerName' joined domain $Domain on $Vserver$siteInfo" 'PASS'
}

function Set-ShareMigDns {
    <#
    .SYNOPSIS
        Update SVM DNS configuration (servers and search domains) for domain migration.
        Captures current DNS before changing for rollback reference.
    #>
    param(
        [Parameter(Mandatory)] [string]$ClusterConnectName,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string[]]$NameServers,
        [Parameter(Mandatory)] [string[]]$Domains
    )

    # Connect to cluster via ZAPI
    $cluster = Resolve-ClusterEntry -ClusterName $ClusterConnectName -ClusterList $global:ONTAP_Clusters
    & $cluster.ConnectName | Out-Null

    # Capture current DNS for logging / rollback
    $currentDns = Get-NcNetDns -VserverContext $Vserver
    Write-ShareMigLog "Current DNS on $Vserver — Servers: $($currentDns.NameServers -join ', ') | Domains: $($currentDns.Domains -join ', ')" 'INFO'

    # Apply new DNS
    Set-NcNetDns -NameServers $NameServers -Domains $Domains -VserverContext $Vserver -SkipConfigValidation -ErrorAction Stop | Out-Null
    Write-ShareMigLog "Updated DNS on $Vserver — Servers: $($NameServers -join ', ') | Domains: $($Domains -join ', ')" 'PASS'

    return [pscustomobject]@{
        Vserver          = $Vserver
        PreviousServers  = $currentDns.NameServers
        PreviousDomains  = $currentDns.Domains
        NewServers       = $NameServers
        NewDomains       = $Domains
    }
}

function Set-ShareMigPreferredDc {
    <#
    .SYNOPSIS
        Set preferred domain controllers on an SVM for a given domain.
        Captures current preferred DCs for rollback.
    #>
    param(
        [Parameter(Mandatory)] [string]$ClusterConnectName,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string[]]$DomainControllers
    )

    $cluster = Resolve-ClusterEntry -ClusterName $ClusterConnectName -ClusterList $global:ONTAP_Clusters
    & $cluster.ConnectName | Out-Null

    # Capture current preferred DCs for rollback
    $currentPrefDc = Get-NcCifsPreferredDomainController -Domain $Domain | Where-Object { $_.Vserver -eq $Vserver }
    if ($currentPrefDc) {
        Write-ShareMigLog "Current preferred DCs on $Vserver — Domain: $($currentPrefDc.Domain), DCs: $($currentPrefDc.PreferredDc -join ', ')" 'INFO'
        # Remove old preferred DCs first
        foreach ($entry in $currentPrefDc) {
            Remove-NcCifsPreferredDomainController -Domain $entry.Domain -DomainControllers $entry.PreferredDc -VserverContext $Vserver -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # Set new preferred DCs
    Add-NcCifsPreferredDomainController -Domain $Domain -DomainControllers $DomainControllers -SkipConfigValidation:$true -VserverContext $Vserver -ErrorAction Stop | Out-Null
    Write-ShareMigLog "Set preferred DCs on $Vserver — Domain: $Domain, DCs: $($DomainControllers -join ', ')" 'PASS'

    return [pscustomobject]@{
        Vserver     = $Vserver
        PreviousDcs = if ($currentPrefDc) { $currentPrefDc } else { @() }
        NewDomain   = $Domain
        NewDcs      = $DomainControllers
    }
}

function Test-DomainCredential {
    <#
    .SYNOPSIS
        Validate domain credentials via LDAP bind against a domain controller.
        Does NOT require a CIFS server — pure AD authentication test.
    #>
    param(
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$Username,
        [Parameter(Mandatory)] [string]$Password,
        [string]$DomainController
    )

    $ldapPath = if ($DomainController) {
        "LDAP://$DomainController"
    } else {
        "LDAP://$Domain"
    }

    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry($ldapPath, $Username, $Password)
        # Force a bind attempt by accessing a property
        $null = $entry.distinguishedName
        if ($entry.Path) {
            return [pscustomobject]@{ Success = $true; Domain = $Domain; User = $Username; Server = $ldapPath; Error = $null }
        } else {
            return [pscustomobject]@{ Success = $false; Domain = $Domain; User = $Username; Server = $ldapPath; Error = "LDAP bind returned no path — credentials may be invalid" }
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Domain = $Domain; User = $Username; Server = $ldapPath; Error = $_.Exception.Message }
    }
    finally {
        if ($entry) { $entry.Dispose() }
    }
}

function Invoke-CifsPasswordReset {
    <#
    .SYNOPSIS
        Reset CIFS domain password on a specific SVM using PowerShell cmdlet.
    #>
    param(
        [Parameter(Mandatory)] [string]$ClusterConnectName,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$AdminUsername,
        [Parameter(Mandatory)] [string]$AdminPassword
    )

    # Ensure we're connected to the cluster
    $controller = $global:CurrentNcController
    if (-not $controller -or $controller.Name -ne $ClusterConnectName) {
        $cluster = Resolve-ClusterEntry -ClusterName $ClusterConnectName -ClusterList $global:ONTAP_Clusters
        & $cluster.ConnectName
        $controller = $global:CurrentNcController
    }

    $result = Reset-NcCifsPassword -AdminUsername $AdminUsername -AdminPassword $AdminPassword -VserverContext $Vserver -Controller $controller -ErrorAction Stop
    return $result
}

function Invoke-ShareMigCsv {
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [string]$Command,
        [string[]]$Headers
    )

    $sshFunc = "$ControllerName-s"
    if (-not (Get-Command $sshFunc -ErrorAction SilentlyContinue)) {
        throw "SSH helper '$sshFunc' was not found. Run Load-Config.ps1 first."
    }

    $wrapped = "set advanced -confirmations off -showseparator ','; row 0 ; $Command"
    $raw = & $sshFunc -Command $wrapped
    # ONTAP with -showseparator ',' outputs: field1','field2','field3','
    # The real separator is the 3-char sequence ','  (not a bare comma)
    # Split on this to preserve embedded commas within field values (e.g. share-properties)
    # Output has 2 header rows: 1) field names, 2) display names — skip display names row
    $dataLines = @($raw | Where-Object { $_ -and $_.Trim() -and $_ -match "','" })
    if ($dataLines.Count -lt 2) {
        # No data rows is normal (e.g. share with no ACLs)
        return @()
    }
    # First line = field-name headers, second line = display-name headers (skip), rest = data
    $headerFields = $dataLines[0] -split "','" | Where-Object { $_ }
    $dataRows = $dataLines | Select-Object -Skip 2  # skip both header rows
    $results = foreach ($row in $dataRows) {
        $values = $row -split "','" | Where-Object { $_ }
        $obj = [ordered]@{}
        for ($i = 0; $i -lt $headerFields.Count; $i++) {
            $val = if ($i -lt $values.Count) { $values[$i] } else { '' }
            # Strip surrounding double-quotes (ONTAP quotes values with spaces)
            $obj[$headerFields[$i]] = $val -replace '^"(.*)"$', '$1'
        }
        [pscustomobject]$obj
    }
    if ($Headers) {
        # Remap to caller-specified headers if provided
        $results | ForEach-Object {
            $mapped = [ordered]@{}
            $props = $_.PSObject.Properties | Select-Object -ExpandProperty Name
            for ($i = 0; $i -lt $Headers.Count -and $i -lt $props.Count; $i++) {
                $mapped[$Headers[$i]] = $_.$($props[$i])
            }
            [pscustomobject]$mapped
        }
    }
    else {
        $results
    }
}

function Test-ShareMigAdConnection {
    param(
        [Parameter(Mandatory)] [string]$Domain,
        [string]$PreferredController,
        [Parameter(Mandatory)] [pscredential]$Credential
    )

    $dc = $PreferredController
    if ([string]::IsNullOrWhiteSpace($dc)) {
        $dc = (Get-ADDomainController -Discover -DomainName $Domain -Credential $Credential -ErrorAction Stop).HostName
    }

    $null = Get-ADDomain -Server $dc -Credential $Credential -ErrorAction Stop
    return $dc
}

function Ensure-ShareMigAdGroup {
    param(
        [Parameter(Mandatory)] [string]$DomainControllerName,
        [Parameter(Mandatory)] [pscredential]$Credential,
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string]$GroupOuPath
    )

    $group = Get-ADGroup -Identity $GroupName -Server $DomainControllerName -Credential $Credential -ErrorAction SilentlyContinue
    if ($group) {
        Write-ShareMigLog "Found AD group '$GroupName'" 'PASS'
        return $group
    }

    Write-ShareMigLog "Creating AD group '$GroupName'" 'INFO'
    return New-ADGroup -Name $GroupName -SamAccountName $GroupName -GroupCategory Security -GroupScope Global -Path $GroupOuPath -Server $DomainControllerName -Credential $Credential -ErrorAction Stop
}

function Add-ShareMigGroupMembers {
    param(
        [Parameter(Mandatory)] [string]$DomainControllerName,
        [Parameter(Mandatory)] [pscredential]$Credential,
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string[]]$Members
    )

    foreach ($member in $Members | Sort-Object -Unique) {
        try {
            Add-ADGroupMember -Identity $GroupName -Members $member -Server $DomainControllerName -Credential $Credential -ErrorAction Stop
            Write-ShareMigLog "Added '$member' to '$GroupName'" 'PASS'
        }
        catch {
            Write-ShareMigLog "Could not add '$member' to '$GroupName': $($_.Exception.Message)" 'WARN'
        }
    }
}

function Get-ShareAclExport {
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$ShareName,
        [string]$DomainControllerName,
        [pscredential]$DomainCredential
    )

    $aclRows = Get-NcCifsShareAcl -Share $ShareName -VserverContext $Vserver
    $results = @()
    foreach ($row in @($aclRows)) {
        $principal = $row.UserOrGroup
        $principalType = 'Unknown'
        $groupMembers = @()

        if ($principal) {
            # Skip AD lookup for well-known built-in principals
            if ($script:WellKnownPrincipals -contains $principal -or $principal -match '^BUILTIN\\' -or $principal -match '^NT AUTHORITY\\') {
                $principalType = 'BuiltIn'
            }
            elseif (-not $DomainControllerName -or -not $DomainCredential) {
                # No AD connection — treat as pass-through
                $principalType = 'Unknown'
            }
            else {
                # Strip domain prefix for AD lookups (e.g. SYB\user → user)
                $samName = if ($principal -match '\\') { ($principal -split '\\', 2)[1] } else { $principal }
                if (Get-ADGroup -Filter "SamAccountName -eq '$samName'" -Server $DomainControllerName -Credential $DomainCredential -ErrorAction SilentlyContinue) {
                    $principalType = 'Group'
                    $groupMembers = @(Get-ADGroupMember -Identity $samName -Server $DomainControllerName -Credential $DomainCredential -Recursive -ErrorAction SilentlyContinue |
                        Where-Object { $_.ObjectClass -eq 'user' } | ForEach-Object { $_.SamAccountName })
                }
                elseif (Get-ADUser -Filter "SamAccountName -eq '$samName'" -Server $DomainControllerName -Credential $DomainCredential -ErrorAction SilentlyContinue) {
                    $principalType = 'User'
                }
            }
        }

        $results += [pscustomobject]@{
            Principal      = $principal
            PrincipalType  = $principalType
            Permission     = $row.Permission
            GroupMembers   = $groupMembers
        }
    }

    return $results
}

function Get-ShareExportSnapshot {
    param(
        [Parameter(Mandatory)] $Pair,
        [string]$DomainControllerName,
        [pscredential]$DomainCredential
    )

    $sourceCluster = Resolve-ClusterEntry -ClusterName $Pair.SourceCluster -ClusterList $global:ONTAP_Clusters
    $sourceVserver = if ($Pair.SourceVserver) { $Pair.SourceVserver } else { $SourceVserver }
    if ([string]::IsNullOrWhiteSpace($sourceVserver)) {
        throw "SourceVserver is required for pair '$($Pair.Name)'"
    }

    # Capture current CIFS server name and NetBIOS aliases (for DomainMigration mode)
    & $sourceCluster.ConnectName | Out-Null
    $cifsObj = Get-NcCifsServer -VserverContext $sourceVserver
    $cifsServerName = if ($cifsObj) { $cifsObj.CifsServer } else { '' }
    $netbiosAliases = if ($cifsObj -and $cifsObj.NetbiosAliases) { @($cifsObj.NetbiosAliases) } else { @() }

    $shareObjs = Get-NcCifsShare -VserverContext $sourceVserver | Where-Object { $_.ShareName -notin @('admin$', 'c$', 'ipc$') }

    if ($Pair.ShareFilter -and $Pair.ShareFilter -ne '*' ) {
        $shareObjs = $shareObjs | Where-Object { $_.ShareName -like $Pair.ShareFilter }
    }

    $shares = foreach ($share in @($shareObjs)) {
        $shareName = $share.ShareName
        $acl = Get-ShareAclExport -ControllerName $sourceCluster.ConnectName -Vserver $sourceVserver -ShareName $shareName -DomainControllerName $DomainControllerName -DomainCredential $DomainCredential

        [pscustomobject]@{
            SourceCluster   = $sourceCluster.ClusterName
            SourceVserver   = $sourceVserver
            ShareName       = $shareName
            Path            = $share.Path
            Comment         = if ($share.Comment) { $share.Comment } else { '-' }
            ShareProperties = if ($share.ShareProperties) { @($share.ShareProperties) } else { @() }
            Acl             = @($acl)
        }
    }

    [pscustomobject]@{
        PairName        = $Pair.Name
        Source          = $sourceCluster.ClusterName
        Vserver         = $sourceVserver
        CifsServerName  = $cifsServerName
        NetbiosAliases  = $netbiosAliases
        SkipDFS         = [bool]$Pair.SkipDFS
        ExportedAt      = (Get-Date).ToString('o')
        Shares          = @($shares)
    }
}

function New-ShareMigGroupName {
    param(
        [Parameter(Mandatory)] [string]$Prefix,
        [Parameter(Mandatory)] [string]$ShareName,
        [Parameter(Mandatory)] [string]$Permission
    )

    $safeShare = ConvertTo-SafeName -Name $ShareName
    $safePerm = ConvertTo-SafeName -Name $Permission
    "$Prefix`_$safeShare`_$safePerm"
}

function Export-ShareMigration {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [string]$DomainControllerName,
        [pscredential]$DomainCredential
    )

    $exportRoot = if ($OutputRoot) { $OutputRoot } else { Join-Path $WorkspaceRoot ($Config.ShareMigration.ExportRoot ?? 'scripts/share-migration/exports') }
    $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runRoot = Join-Path $exportRoot $runStamp
    $null = New-Item -ItemType Directory -Path $runRoot -Force

    $snapshot = [pscustomobject]@{
        Metadata = [pscustomobject]@{
            ExportedAt = (Get-Date).ToString('o')
            Domain     = $Config.ShareMigration.Domain
            Dc         = $DomainControllerName
            SkipDFS    = Test-ShareMigSkipDFS -Config $Config
        }
        Pairs = @()
    }

    foreach ($pair in @($Config.ShareMigration.Pairs)) {
        Write-ShareMigLog "Exporting pair '$($pair.Name)'" 'INFO'
        $pairSnapshot = Get-ShareExportSnapshot -Pair $pair -DomainControllerName $DomainControllerName -DomainCredential $DomainCredential
        $snapshot.Pairs += $pairSnapshot
    }

    $jsonPath = Join-Path $runRoot 'share-migration.snapshot.json'
    $csvPath = Join-Path $runRoot 'share-migration.shares.csv'
    $snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath

    $flatRows = foreach ($pairSnapshot in $snapshot.Pairs) {
        foreach ($share in $pairSnapshot.Shares) {
            foreach ($acl in $share.Acl) {
                [pscustomobject]@{
                    PairName      = $pairSnapshot.PairName
                    Source        = $pairSnapshot.Source
                    Vserver       = $pairSnapshot.Vserver
                    SkipDFS       = $pairSnapshot.SkipDFS
                    ShareName     = $share.ShareName
                    Path          = $share.Path
                    Principal     = $acl.Principal
                    PrincipalType = $acl.PrincipalType
                    Permission    = $acl.Permission
                }
            }
        }
    }

    $flatRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation
    Write-ShareMigLog "Export written to $jsonPath" 'PASS'
    Write-ShareMigLog "CSV summary written to $csvPath" 'PASS'
    return $snapshot
}

function Test-ShareMigSkipGroupCreation {
    param([Parameter(Mandatory)] $Config)
    return [bool]($Config.ShareMigration.SkipGroupCreation)
}

function Ensure-ShareMigAclTarget {
    param(
        [Parameter(Mandatory)] $Pair,
        [Parameter(Mandatory)] [psobject]$Share,
        [Parameter(Mandatory)] $Config,
        [string]$DomainControllerName,
        [pscredential]$DomainCredential,
        [string]$GroupOuPath,
        [string]$GroupPrefix,
        [Parameter(Mandatory)] [string]$DestinationClusterName,
        [Parameter(Mandatory)] [string]$DestinationVserver
    )

    $skipGroups = Test-ShareMigSkipGroupCreation -Config $Config

    if (-not $skipGroups) {
        # --- AD group promotion: bucket individual users into per-share groups ---
        $groupBuckets = @{}
        foreach ($acl in @($Share.Acl)) {
            if ($acl.PrincipalType -eq 'User') {
                if (-not $groupBuckets.ContainsKey($acl.Permission)) {
                    $groupBuckets[$acl.Permission] = New-Object System.Collections.Generic.List[string]
                }
                $groupBuckets[$acl.Permission].Add($acl.Principal)
            }
        }

        foreach ($permission in $groupBuckets.Keys) {
            $groupName = New-ShareMigGroupName -Prefix $GroupPrefix -ShareName $Share.ShareName -Permission $permission
            Ensure-ShareMigAdGroup -DomainControllerName $DomainControllerName -Credential $DomainCredential -GroupName $groupName -GroupOuPath $GroupOuPath | Out-Null
            Add-ShareMigGroupMembers -DomainControllerName $DomainControllerName -Credential $DomainCredential -GroupName $groupName -Members @($groupBuckets[$permission])
        }

        foreach ($acl in @($Share.Acl)) {
            if ($acl.PrincipalType -eq 'Group') {
                $group = Ensure-ShareMigAdGroup -DomainControllerName $DomainControllerName -Credential $DomainCredential -GroupName $acl.Principal -GroupOuPath $GroupOuPath
                if ($acl.GroupMembers) {
                    Add-ShareMigGroupMembers -DomainControllerName $DomainControllerName -Credential $DomainCredential -GroupName $group.Name -Members @($acl.GroupMembers)
                }
            }
        }
    } else {
        Write-ShareMigLog "SkipGroupCreation=true — replaying ACLs as-is without AD group promotion" 'INFO'
    }

    $destinationCluster = Resolve-ClusterEntry -ClusterName $DestinationClusterName -ClusterList $global:ONTAP_Clusters
    & $destinationCluster.ConnectName | Out-Null
    $existingShare = Get-NcCifsShare -Name $Share.ShareName -VserverContext $DestinationVserver -ErrorAction SilentlyContinue

    if (-not $existingShare) {
        $props = if ($Share.ShareProperties -and $Share.ShareProperties.Count -gt 0) { @($Share.ShareProperties) } else { @('browsable') }
        $comment = if ($Share.Comment -and $Share.Comment -ne '-') { $Share.Comment } else { $null }
        if ($PSCmdlet.ShouldProcess("$DestinationClusterName/$DestinationVserver", "Create share $($Share.ShareName)")) {
            $newShareParams = @{
                Name            = $Share.ShareName
                Path            = $Share.Path
                ShareProperties = $props
                VserverContext  = $DestinationVserver
                ErrorAction     = 'Stop'
            }
            if ($comment) { $newShareParams['Comment'] = $comment }
            Add-NcCifsShare @newShareParams | Out-Null
            Write-ShareMigLog "Created share '$($Share.ShareName)' on $DestinationClusterName/$DestinationVserver" 'PASS'
            # Remove default 'Everyone / Full Control' ACL added by ONTAP
            try {
                Remove-NcCifsShareAcl -Share $Share.ShareName -UserOrGroup 'Everyone' -VserverContext $DestinationVserver -ErrorAction Stop -Confirm:$false | Out-Null
                Write-ShareMigLog "Removed default 'Everyone' ACL from '$($Share.ShareName)'" 'INFO'
            } catch {
                Write-ShareMigLog "Could not remove default 'Everyone' ACL (may not exist): $($_.Exception.Message)" 'WARN'
            }
        }
    }
    else {
        Write-ShareMigLog "Share '$($Share.ShareName)' already exists on $DestinationClusterName/$DestinationVserver" 'PASS'
    }

    foreach ($acl in @($Share.Acl)) {
        $targetPrincipal = $acl.Principal

        # When SkipGroupCreation is off, individual users get promoted to groups
        if (-not $skipGroups -and $acl.PrincipalType -eq 'User') {
            $targetPrincipal = New-ShareMigGroupName -Prefix $GroupPrefix -ShareName $Share.ShareName -Permission $acl.Permission
        }

        if ($PSCmdlet.ShouldProcess("$DestinationClusterName/$DestinationVserver", "Apply ACL $targetPrincipal -> $($Share.ShareName)")) {
            try {
                Add-NcCifsShareAcl -Share $Share.ShareName -UserOrGroup $targetPrincipal -Permission $acl.Permission -VserverContext $DestinationVserver -ErrorAction Stop | Out-Null
                Write-ShareMigLog "Applied ACL '$targetPrincipal' => '$($Share.ShareName)' ($($acl.Permission))" 'PASS'
            }
            catch {
                Write-ShareMigLog "ACL '$targetPrincipal' on share '$($Share.ShareName)' failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    $skipDfs = Test-ShareMigSkipDFS -Config $Config
    $createDfs = Test-ShareMigCreateDestinationDFSLinks -Config $Config -Pair $Pair
    if (-not $skipDfs -and $createDfs) {
        $dfsRoot = Get-ShareMigDfsRoot -Config $Config -Pair $Pair
        $linkName = if ($Share.PSObject.Properties.Name -contains 'DfsLinkName' -and $Share.DfsLinkName) { [string]$Share.DfsLinkName } else { ($Share.ShareName -replace '\$$', '') }
        $cifsUnixPath = "/$linkName/"
        $dfsTargetPath = "$dfsRoot/$linkName"

        $existingCifsSymlink = Get-NcCifsSymlink -UnixPath $cifsUnixPath -VserverContext $destinationVserver -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if ($existingCifsSymlink) {
            Write-ShareMigLog "DFS link '$cifsUnixPath' already exists on $DestinationClusterName/$destinationVserver" 'PASS'
        }
        else {
            $existingLink = $null
            try {
                $existingLink = Read-NcDirectory -VserverContext $destinationVserver -Path $dfsRoot -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq 'symlink' -and $_.Name -eq $linkName }
            }
            catch {
                Write-ShareMigLog "Could not inspect DFS root '$dfsRoot' on ${DestinationClusterName}/${destinationVserver}: $($_.Exception.Message)" 'WARN'
            }

            if ($existingLink) {
                Write-ShareMigLog "DFS symlink '$dfsTargetPath' already exists on $DestinationClusterName/$destinationVserver" 'PASS'
            }
            else {
                if ($PSCmdlet.ShouldProcess("$DestinationClusterName/$destinationVserver", "Create DFS link $linkName at $dfsTargetPath")) {
                    New-NcSymlink -Target "/$linkName" -LinkName $dfsTargetPath -VserverContext $destinationVserver -ErrorAction Stop | Out-Null
                    Add-NcCifsSymlink -UnixPath $cifsUnixPath -CifsPath '/' -Locality 'widelink' -ShareName $Share.ShareName -VserverContext $destinationVserver -ErrorAction Stop | Out-Null
                    Write-ShareMigLog "Created DFS link '$dfsTargetPath' for share '$($Share.ShareName)'" 'PASS'
                }
            }
        }
    }
}

function Import-ShareMigration {
    param(
        [Parameter(Mandatory)] [string]$SnapshotFile,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [string]$DomainControllerName,
        [pscredential]$DomainCredential
    )

    $snapshot = Get-Content -LiteralPath $SnapshotFile -Raw | ConvertFrom-Json
    $groupPrefix = $Config.ShareMigration.GroupNamePrefix
    $groupOuPath = if ($Config.ShareMigration.DestinationGroupOuPath) { $Config.ShareMigration.DestinationGroupOuPath } else { $Config.ShareMigration.GroupOuPath }

    foreach ($pairSnapshot in @($snapshot.Pairs)) {
        $pair = $Config.ShareMigration.Pairs | Where-Object { $_.Name -eq $pairSnapshot.PairName } | Select-Object -First 1
        if (-not $pair) {
            throw "Pair '$($pairSnapshot.PairName)' was not found in Config_shareMig.json"
        }

        $destinationCluster = Resolve-ClusterEntry -ClusterName $pair.DestinationCluster -ClusterList $global:ONTAP_Clusters
        $destinationVserver = if ($pair.DestinationVserver) { $pair.DestinationVserver } else { $DestinationVserver }
        if ([string]::IsNullOrWhiteSpace($destinationVserver)) {
            throw "DestinationVserver is required for pair '$($pair.Name)'"
        }

        Write-ShareMigLog "Importing pair '$($pair.Name)' to $($destinationCluster.ClusterName)/$destinationVserver" 'INFO'
        foreach ($share in @($pairSnapshot.Shares)) {
            Ensure-ShareMigAclTarget -Pair $pair -Share $share -Config $Config -DomainControllerName $DomainControllerName -DomainCredential $DomainCredential -GroupOuPath $groupOuPath -GroupPrefix $groupPrefix -DestinationClusterName $destinationCluster.ClusterName -DestinationVserver $destinationVserver
        }
    }

    return $snapshot
}

function Test-ShareMigPreflight {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [string]$DomainControllerName,
        [pscredential]$DomainCredential
    )

    if (-not $ApprovePreflight -and $Config.ShareMigration.RequirePreflightApproval -ne $false) {
        throw "Preflight creates test AD and share artifacts. Re-run with -ApprovePreflight to continue."
    }

    $preflight = $Config.ShareMigration.Preflight
    $skipDfs = Test-ShareMigSkipDFS -Config $Config
    $cluster = Resolve-ClusterEntry -ClusterName $preflight.Cluster -ClusterList $global:ONTAP_Clusters
    $vserver = $preflight.Vserver
    if ([string]::IsNullOrWhiteSpace($vserver)) {
        throw "Preflight Vserver is missing in Config_shareMig.json"
    }

    if ($skipDfs) {
        Write-ShareMigLog "DFS checks are disabled for this run (SkipDFS=true)" 'PASS'
    }

    Write-ShareMigLog "Preflight step 1: NetApp credential cache check for $($cluster.ConnectName)" 'INFO'
    $netappCredName = $cluster.API_Cred
    $netappUser = if ($cluster.CredentialUserName) { $cluster.CredentialUserName } else { 'admin' }
    $netappCred = Get-ClusterCredential -WorkspaceRoot $WorkspaceRoot -CredentialName $netappCredName -UserName $netappUser
    Ensure-NcCredential -ControllerName $cluster.ConnectName -Credential $netappCred
    Connect-NcController -Name $cluster.ConnectName -Credential $netappCred -ErrorAction Stop | Out-Null

    Write-ShareMigLog "Preflight step 2: DC discovery and auth against $($Config.ShareMigration.Domain)" 'INFO'
    $resolvedDc = Test-ShareMigAdConnection -Domain $Config.ShareMigration.Domain -PreferredController $DomainControllerName -Credential $DomainCredential
    Write-ShareMigLog "Connected to DC $resolvedDc" 'PASS'

    $skipGroups = Test-ShareMigSkipGroupCreation -Config $Config
    if ($skipGroups) {
        Write-ShareMigLog "Preflight step 3: SKIPPED — SkipGroupCreation=true (no AD group test needed)" 'PASS'
    } else {
        Write-ShareMigLog "Preflight step 3: AD group create/discover for $($preflight.GroupName)" 'INFO'
        Ensure-ShareMigAdGroup -DomainControllerName $resolvedDc -Credential $DomainCredential -GroupName $preflight.GroupName -GroupOuPath ($Config.ShareMigration.SourceGroupOuPath ?? $Config.ShareMigration.GroupOuPath) | Out-Null
    }

    Write-ShareMigLog "Preflight step 4: SMB share create/discover for $($preflight.ShareName)" 'INFO'
    & $cluster.ConnectName | Out-Null
    $shareExists = Get-NcCifsShare -Name $preflight.ShareName -VserverContext $vserver -ErrorAction SilentlyContinue
    if (-not $shareExists) {
        if ([string]::IsNullOrWhiteSpace($preflight.SharePath)) {
            throw "Preflight SharePath is missing in Config_shareMig.json"
        }
        if ($PSCmdlet.ShouldProcess("$($cluster.ConnectName)/$vserver", "Create preflight share $($preflight.ShareName)")) {
            Add-NcCifsShare -Name $preflight.ShareName -Path $preflight.SharePath -ShareProperties 'browsable,oplocks,changenotify' -VserverContext $vserver -ErrorAction Stop | Out-Null
            Write-ShareMigLog "Created preflight share '$($preflight.ShareName)'" 'PASS'
        }
    }
    else {
        Write-ShareMigLog "Preflight share '$($preflight.ShareName)' already exists" 'PASS'
    }

    if ($skipGroups) {
        Write-ShareMigLog "Preflight ACL test: SKIPPED — SkipGroupCreation=true (will replay original principals)" 'PASS'
    } elseif ($PSCmdlet.ShouldProcess("$($cluster.ConnectName)/$vserver", "Apply preflight ACL $($preflight.GroupName)")) {
        try {
            Add-NcCifsShareAcl -Share $preflight.ShareName -UserOrGroup $preflight.GroupName -Permission 'full_control' -VserverContext $vserver -ErrorAction Stop | Out-Null
            Write-ShareMigLog "Applied preflight ACL '$($preflight.GroupName)'" 'PASS'
        }
        catch {
            Write-ShareMigLog "Preflight ACL may already exist: $($_.Exception.Message)" 'WARN'
        }
    }

    return [pscustomobject]@{
        DomainController = $resolvedDc
        Cluster          = $cluster.ClusterName
        Vserver          = $vserver
        ShareName        = $preflight.ShareName
        GroupName        = $preflight.GroupName
        SkipDFS          = $skipDfs
    }
}

$workspaceRoot = Get-WorkspaceRoot
. (Join-Path $workspaceRoot 'Load-Config.ps1')

$shareMigConfig = Get-ShareMigrationConfig -WorkspaceRoot $workspaceRoot -Path $ShareMigrationConfigPath
$skipGroups = Test-ShareMigSkipGroupCreation -Config $shareMigConfig

# AD module is only required when group creation is enabled
if (-not $skipGroups) {
    try { Import-Module ActiveDirectory -ErrorAction Stop } catch {
        throw "ActiveDirectory module is required when SkipGroupCreation=false. Install RSAT / AD tools first. $($_.Exception.Message)"
    }
}

$resolvedDc = $null
$domainCredential = $DomainCredential

if (-not $skipGroups) {
    if (-not $domainCredential) {
        $domainUser = if ($shareMigConfig.ShareMigration.SourceDomainUser) { $shareMigConfig.ShareMigration.SourceDomainUser } else { 'administrator' }
        $domainCredName = if ($shareMigConfig.ShareMigration.SourceDomainCredentialName) { $shareMigConfig.ShareMigration.SourceDomainCredentialName } else { $domainUser }
        $domainCredential = Get-ClusterCredential -WorkspaceRoot $workspaceRoot -CredentialName $domainCredName -UserName $domainUser
    }

    if ([string]::IsNullOrWhiteSpace($DomainController)) {
        $DomainController = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
    }

    $resolvedDc = Test-ShareMigAdConnection -Domain $shareMigConfig.ShareMigration.Domain -PreferredController $DomainController -Credential $domainCredential
} else {
    Write-Host "SkipGroupCreation=true — AD connection skipped" -ForegroundColor Cyan
}

$logRoot = if ($OutputRoot) { $OutputRoot } else { Join-Path $workspaceRoot ($shareMigConfig.ShareMigration.LogRoot ?? 'scripts/share-migration/logs') }
$null = New-Item -ItemType Directory -Path $logRoot -Force
$script:ShareMigLogFile = Join-Path $logRoot ("share-migration_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

Write-ShareMigLog "Mode: $Mode" 'INFO'
Write-ShareMigLog "Config: $($ShareMigrationConfigPath ?? (Join-Path $workspaceRoot 'Config_shareMig.json'))" 'INFO'
Write-ShareMigLog "Log file: $script:ShareMigLogFile" 'INFO'
Write-ShareMigLog "DFS handling: $(if (Test-ShareMigSkipDFS -Config $shareMigConfig) { 'skipped' } else { 'enabled' })" 'INFO'
Write-ShareMigLog "Group creation: $(if ($skipGroups) { 'skipped (replay as-is)' } else { 'enabled' })" 'INFO'

switch ($Mode) {
    'Preflight' {
        $result = Test-ShareMigPreflight -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential
        $result | ConvertTo-Json -Depth 6
    }
    'Export' {
        $result = Export-ShareMigration -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential
        $result | ConvertTo-Json -Depth 12
    }
    'Import' {
        if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
            # Auto-find latest snapshot from exports folder
            $exportsDir = Join-Path $workspaceRoot 'scripts\share-migration\exports'
            $latestSnapshot = Get-ChildItem -Path $exportsDir -Filter 'share-migration.snapshot.json' -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestSnapshot) {
                $SnapshotPath = $latestSnapshot.FullName
                Write-ShareMigLog "Auto-selected latest snapshot: $SnapshotPath" 'INFO'
            } else {
                throw "Import mode requires -SnapshotPath (no snapshots found in $exportsDir)"
            }
        }
        $result = Import-ShareMigration -SnapshotFile $SnapshotPath -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential
        $result | ConvertTo-Json -Depth 12
    }
    'Sync' {
        $exported = Export-ShareMigration -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential
        if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
            $SnapshotPath = Join-Path (Split-Path $script:ShareMigLogFile -Parent) 'share-migration.snapshot.json'
        }
        $exported | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $SnapshotPath
        Import-ShareMigration -SnapshotFile $SnapshotPath -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential | Out-Null
        $exported | ConvertTo-Json -Depth 12
    }
    'DomainMigration' {
        # --- Validate domain credentials are configured ---
        $srcDomain  = $shareMigConfig.ShareMigration.Domain
        $destDomain = $shareMigConfig.ShareMigration.DestinationDomain
        $srcCredName  = $shareMigConfig.ShareMigration.SourceDomainCredentialName
        $srcCredUser  = $shareMigConfig.ShareMigration.SourceDomainUser
        $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
        $destCredUser = $shareMigConfig.ShareMigration.DestinationDomainUser

        if ([string]::IsNullOrWhiteSpace($srcDomain)) {
            throw "DomainMigration requires 'Domain' (source) in Config_shareMig.json"
        }
        if ([string]::IsNullOrWhiteSpace($destDomain)) {
            throw "DomainMigration requires 'DestinationDomain' in Config_shareMig.json"
        }
        if ([string]::IsNullOrWhiteSpace($srcCredName) -or [string]::IsNullOrWhiteSpace($srcCredUser)) {
            throw "DomainMigration requires 'SourceDomainCredentialName' and 'SourceDomainUser' in Config_shareMig.json"
        }
        if ([string]::IsNullOrWhiteSpace($destCredName) -or [string]::IsNullOrWhiteSpace($destCredUser)) {
            throw "DomainMigration requires 'DestinationDomainCredentialName' and 'DestinationDomainUser' in Config_shareMig.json"
        }

        # Resolve domain passwords from credential store
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
        $srcDomainPass  = & $credScript -Name $srcCredName
        $destDomainPass = & $credScript -Name $destCredName

        if ([string]::IsNullOrWhiteSpace($srcDomainPass)) {
            throw "Could not retrieve source domain credential '$srcCredName' — run New-Credential.ps1 first"
        }
        if ([string]::IsNullOrWhiteSpace($destDomainPass)) {
            throw "Could not retrieve destination domain credential '$destCredName' — run New-Credential.ps1 first"
        }

        Write-ShareMigLog "=== DOMAIN MIGRATION ===" 'INFO'
        Write-ShareMigLog "Source domain: $srcDomain" 'INFO'
        Write-ShareMigLog "Destination domain: $destDomain" 'INFO'
        Write-ShareMigLog "Pairs to migrate: $($shareMigConfig.ShareMigration.Pairs.Count)" 'INFO'

        # --- Pre-flight: Validate domain credentials via LDAP ---
        Write-ShareMigLog "--- Pre-flight: Testing domain credentials ---" 'INFO'
        $srcDc  = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
        $destDc = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]

        $srcTest = Test-DomainCredential -Domain $srcDomain -Username $srcCredUser -Password $srcDomainPass -DomainController $srcDc
        if (-not $srcTest.Success) {
            throw "Source domain credential test FAILED ($srcCredUser → $srcDomain): $($srcTest.Error)"
        }
        Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser → $srcDomain)" 'PASS'

        $destTest = Test-DomainCredential -Domain $destDomain -Username $destCredUser -Password $destDomainPass -DomainController $destDc
        if (-not $destTest.Success) {
            throw "Destination domain credential test FAILED ($destCredUser → $destDomain): $($destTest.Error)"
        }
        Write-ShareMigLog "Destination domain auth: PASSED ($destCredUser → $destDomain)" 'PASS'

        # --- Step 1/7: Export all shares ---
        Write-ShareMigLog "--- Step 1/7: Exporting shares ---" 'INFO'
        $exported = Export-ShareMigration -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential
        $SnapshotPath = Join-Path (Split-Path $script:ShareMigLogFile -Parent) 'share-migration.snapshot.json'
        $exported | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $SnapshotPath
        Write-ShareMigLog "Export complete: $SnapshotPath" 'PASS'

        # --- Step 2/7: Stop CIFS (leave source domain — DNS still points to source DCs) ---
        Write-ShareMigLog "--- Step 2/7: Stopping CIFS (leaving $srcDomain) ---" 'INFO'
        foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
            $cluster = Resolve-ClusterEntry -ClusterName $pair.SourceCluster -ClusterList $global:ONTAP_Clusters
            $vserver = $pair.SourceVserver
            if ($PSCmdlet.ShouldProcess("$($cluster.ClusterName)/$vserver", "Delete CIFS server (leave domain $srcDomain)")) {
                Stop-ShareMigCifs -ControllerName $cluster.ConnectName -Vserver $vserver -DomainAdminUser $srcCredUser -DomainAdminPassword $srcDomainPass
            }
        }

        # --- Step 3/7: Update DNS (point to destination domain DCs) ---
        $destDnsServers = @($shareMigConfig.ShareMigration.DestinationDnsServers | Where-Object { $_ })
        $destDnsDomains = @($shareMigConfig.ShareMigration.DestinationDnsDomains | Where-Object { $_ })
        if ($destDnsServers.Count -gt 0 -and $destDnsDomains.Count -gt 0) {
            Write-ShareMigLog "--- Step 3/7: Updating DNS for destination domain ---" 'INFO'
            foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
                $destCluster = Resolve-ClusterEntry -ClusterName $pair.DestinationCluster -ClusterList $global:ONTAP_Clusters
                $vserver = $pair.DestinationVserver
                if ($PSCmdlet.ShouldProcess("$($destCluster.ClusterName)/$vserver", "Update DNS to $($destDnsServers -join ', ')")) {
                    Set-ShareMigDns -ClusterConnectName $destCluster.ConnectName -Vserver $vserver -NameServers $destDnsServers -Domains $destDnsDomains
                }
            }
        } else {
            Write-ShareMigLog "--- Step 3/7: DNS update skipped (DestinationDnsServers/DnsDomains not configured) ---" 'INFO'
        }

        # --- Step 4/7: Set preferred DC + discovery-mode ---
        $destDc = $shareMigConfig.ShareMigration.DestinationDomainController
        $destSiteName = $shareMigConfig.ShareMigration.DestinationDefaultSiteName
        if ($destDc -or $destSiteName) {
            Write-ShareMigLog "--- Step 4/7: Setting preferred DC and discovery-mode ---" 'INFO'
            # Determine discovery mode: explicit config wins, then auto-logic
            $destDiscoveryOverride = $shareMigConfig.ShareMigration.DestinationDiscoveryMode
            if ($destDiscoveryOverride) {
                $discoveryMode = $destDiscoveryOverride
            } elseif ($destSiteName) {
                $discoveryMode = 'site'
            } elseif ($destDc) {
                $discoveryMode = 'none'
            } else {
                $discoveryMode = 'all'
            }
            Write-ShareMigLog "Discovery-mode strategy: $discoveryMode (SiteName=$destSiteName, PreferredDC=$destDc)" 'INFO'

            foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
                $cluster = Resolve-ClusterEntry -ClusterName $pair.SourceCluster -ClusterList $global:ONTAP_Clusters
                $vserver = $pair.SourceVserver
                & $cluster.ConnectName | Out-Null

                if ($destDc) {
                    # Clear source domain's preferred DCs (no longer needed after migration)
                    $srcDomain = $shareMigConfig.ShareMigration.Domain
                    $oldSrcPrefDc = Get-NcCifsPreferredDomainController -Domain $srcDomain | Where-Object { $_.Vserver -eq $vserver }
                    if ($oldSrcPrefDc) {
                        foreach ($entry in $oldSrcPrefDc) {
                            Remove-NcCifsPreferredDomainController -Domain $entry.Domain -DomainControllers $entry.PreferredDc -VserverContext $vserver -ErrorAction SilentlyContinue | Out-Null
                        }
                        Write-ShareMigLog "Cleared source preferred DCs ($srcDomain) from $vserver" 'INFO'
                    }
                    # Clear any stale destination domain preferred DCs
                    $oldDestPrefDc = Get-NcCifsPreferredDomainController -Domain $destDomain | Where-Object { $_.Vserver -eq $vserver }
                    if ($oldDestPrefDc) {
                        foreach ($entry in $oldDestPrefDc) {
                            Remove-NcCifsPreferredDomainController -Domain $entry.Domain -DomainControllers $entry.PreferredDc -VserverContext $vserver -ErrorAction SilentlyContinue | Out-Null
                        }
                        Write-ShareMigLog "Cleared old destination preferred DCs from $vserver" 'INFO'
                    }
                    # Add preferred DC for destination domain (must be IP address)
                    Add-NcCifsPreferredDomainController -Domain $destDomain -DomainControllers @($destDc) -SkipConfigValidation:$true -VserverContext $vserver -ErrorAction SilentlyContinue | Out-Null
                    Write-ShareMigLog "Set preferred DC for $destDomain on ${vserver}: $destDc" 'PASS'
                }

                # Set discovery-mode via ZAPI tunnel
                try {
                    Invoke-NcSsh -Command "set advanced -confirmations off; vserver cifs domain discovered-servers discovery-mode modify -vserver $vserver -mode $discoveryMode" | Out-Null
                    Write-ShareMigLog "Set discovery-mode=$discoveryMode on $vserver" 'PASS'
                } catch {
                    Write-ShareMigLog "Could not set discovery-mode: $($_.Exception.Message)" 'WARN'
                }
            }
        } else {
            Write-ShareMigLog "--- Step 4/7: Preferred DC skipped (DestinationDomainController not configured) ---" 'INFO'
        }

        # --- Step 5/7: Start CIFS (join destination domain) ---
        Write-ShareMigLog "--- Step 5/7: Starting CIFS (joining $destDomain) ---" 'INFO'
        foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
            $destCluster = Resolve-ClusterEntry -ClusterName $pair.DestinationCluster -ClusterList $global:ONTAP_Clusters
            $vserver = $pair.DestinationVserver
            # Determine CIFS server name — use config or keep existing
            $exportedPair = $exported.Pairs | Where-Object { $_.PairName -eq $pair.Name } | Select-Object -First 1
            $cifsName = if ($pair.DestinationCifsServerName) { $pair.DestinationCifsServerName } else {
                if ($exportedPair -and $exportedPair.CifsServerName) { $exportedPair.CifsServerName } else { $vserver }
            }
            $ou = if ($pair.DestinationOU) { $pair.DestinationOU } elseif ($shareMigConfig.ShareMigration.DestinationOrganizationalUnit) { $shareMigConfig.ShareMigration.DestinationOrganizationalUnit } else { $null }
            $destSiteForCifs = $shareMigConfig.ShareMigration.DestinationDefaultSiteName
            # Aliases: prefer snapshot, fall back to config DestinationNetbiosAlias
            $aliases = @($exportedPair.NetbiosAliases | Where-Object { $_ })
            if ($aliases.Count -eq 0) {
                $cfgAlias = $shareMigConfig.ShareMigration.DestinationNetbiosAlias
                if ($cfgAlias) { $aliases = @($cfgAlias) }
            }
            if ($PSCmdlet.ShouldProcess("$($destCluster.ClusterName)/$vserver", "Create CIFS server '$cifsName' in domain $destDomain")) {
                $cifsParams = @{
                    ControllerName      = $destCluster.ConnectName
                    Vserver             = $vserver
                    CifsServerName      = $cifsName
                    Domain              = $destDomain
                    DomainAdminUser     = $destCredUser
                    DomainAdminPassword = $destDomainPass
                }
                if ($ou)              { $cifsParams['OrganizationalUnit'] = $ou }
                if ($destSiteForCifs) { $cifsParams['DefaultSiteName']    = $destSiteForCifs }
                if ($aliases.Count -gt 0) { $cifsParams['NetbiosAliases'] = $aliases }
                Start-ShareMigCifs @cifsParams
            }
            # Log SPN commands the user must run in AD (if aliases exist)
            if ($aliases.Count -gt 0) {
                Write-ShareMigLog "--- ACTION REQUIRED: Register SPNs for NetBIOS aliases ---" 'WARN'
                foreach ($alias in $aliases) {
                    Write-ShareMigLog "  SETSPN -a host/$alias $cifsName" 'WARN'
                    Write-ShareMigLog "  SETSPN -a host/$alias.$destDomain $cifsName" 'WARN'
                }
            }
        }

        # --- Step 6/7: Set preferred domain controllers (if configured) ---
        $destDc = $shareMigConfig.ShareMigration.DestinationDomainController
        if ($destDc) {
            Write-ShareMigLog "--- Step 6/7: Confirming preferred domain controllers ---" 'INFO'
            foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
                $destCluster = Resolve-ClusterEntry -ClusterName $pair.DestinationCluster -ClusterList $global:ONTAP_Clusters
                $vserver = $pair.DestinationVserver
                if ($PSCmdlet.ShouldProcess("$($destCluster.ClusterName)/$vserver", "Set preferred DC '$destDc' for domain $destDomain")) {
                    Set-ShareMigPreferredDc -ClusterConnectName $destCluster.ConnectName -Vserver $vserver -Domain $destDomain -DomainControllers @($destDc)
                }
            }
        } else {
            Write-ShareMigLog "--- Step 6/7: Preferred DC skipped (DestinationDomainController not configured) ---" 'INFO'
        }

        # --- Step 7/7: Import shares ---
        Write-ShareMigLog "--- Step 7/7: Importing shares ---" 'INFO'
        Import-ShareMigration -SnapshotFile $SnapshotPath -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential | Out-Null
        Write-ShareMigLog "=== DOMAIN MIGRATION COMPLETE ===" 'PASS'
        $exported | ConvertTo-Json -Depth 12
    }
    'TestCredentials' {
        # Pure AD authentication test — no CIFS server required
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
        $results = @()

        if ($Target -in @('Source', 'Both')) {
            $srcDomain   = $shareMigConfig.ShareMigration.Domain
            $srcDc       = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
            $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
            $srcCredUser = $shareMigConfig.ShareMigration.SourceDomainUser
            if ([string]::IsNullOrWhiteSpace($srcCredName) -or [string]::IsNullOrWhiteSpace($srcCredUser)) {
                throw "Source credentials not configured (SourceDomainCredentialName / SourceDomainUser)"
            }
            $srcPass = & $credScript -Name $srcCredName
            Write-ShareMigLog "Testing source domain credentials: $srcCredUser → $srcDomain (DC: $srcDc)" 'INFO'
            $srcResult = Test-DomainCredential -Domain $srcDomain -Username $srcCredUser -Password $srcPass -DomainController $srcDc
            if ($srcResult.Success) {
                Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser → $srcDomain)" 'PASS'
            } else {
                Write-ShareMigLog "Source domain auth: FAILED — $($srcResult.Error)" 'ERROR'
            }
            $results += $srcResult
        }

        if ($Target -in @('Destination', 'Both')) {
            $destDomain   = $shareMigConfig.ShareMigration.DestinationDomain
            $destDc       = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]
            $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
            $destCredUser = $shareMigConfig.ShareMigration.DestinationDomainUser
            if ([string]::IsNullOrWhiteSpace($destCredName) -or [string]::IsNullOrWhiteSpace($destCredUser)) {
                throw "Destination credentials not configured (DestinationDomainCredentialName / DestinationDomainUser)"
            }
            $destPass = & $credScript -Name $destCredName
            Write-ShareMigLog "Testing destination domain credentials: $destCredUser → $destDomain (DC: $destDc)" 'INFO'
            $destResult = Test-DomainCredential -Domain $destDomain -Username $destCredUser -Password $destPass -DomainController $destDc
            if ($destResult.Success) {
                Write-ShareMigLog "Destination domain auth: PASSED ($destCredUser → $destDomain)" 'PASS'
            } else {
                Write-ShareMigLog "Destination domain auth: FAILED — $($destResult.Error)" 'ERROR'
            }
            $results += $destResult
        }

        $results | Format-Table Success, Domain, User, Server, Error -AutoSize
    }
    'Rollback' {
        # Roll back a failed DomainMigration: restore DNS → recreate CIFS in source domain → re-import shares
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
        $srcDomain   = $shareMigConfig.ShareMigration.Domain
        $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
        $srcCredUser = $shareMigConfig.ShareMigration.SourceDomainUser
        $srcDomainPass = & $credScript -Name $srcCredName

        # Find snapshot to restore from
        if (-not $SnapshotPath) {
            $exportRoot = Join-Path $workspaceRoot ($shareMigConfig.ShareMigration.ExportRoot ?? 'scripts/share-migration/exports')
            $latestSnap = Get-ChildItem -Path $exportRoot -Recurse -Filter '*.snapshot.json' |
                Sort-Object LastWriteTime -Descending |
                Where-Object { $snap = Get-Content $_.FullName -Raw | ConvertFrom-Json; $snap.Pairs[0].Shares.Count -gt 0 } |
                Select-Object -First 1
            if (-not $latestSnap) { throw 'No snapshot with shares found. Specify -SnapshotPath manually.' }
            $SnapshotPath = $latestSnap.FullName
            Write-ShareMigLog "Auto-selected snapshot (with shares): $SnapshotPath" 'INFO'
        }

        Write-ShareMigLog '=== ROLLBACK ===' 'INFO'
        Write-ShareMigLog "Restoring to source domain: $srcDomain" 'INFO'

        foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
            $cluster = Resolve-ClusterEntry -ClusterName $pair.SourceCluster -ClusterList $global:ONTAP_Clusters
            $vserver = $pair.SourceVserver
            & $cluster.ConnectName | Out-Null

            # --- Step 1/5: Delete CIFS (leave current domain — DNS still points to current DCs) ---
            $cifsExists = Get-NcCifsServer -VserverContext $vserver -ErrorAction SilentlyContinue
            if ($cifsExists) {
                Write-ShareMigLog "--- Step 1/5: Deleting CIFS on $vserver ($($cifsExists.CifsServer) in $($cifsExists.Domain)) ---" 'INFO'
                # Use destination credentials to leave the current (destination) domain cleanly
                $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
                $destCredUser = $shareMigConfig.ShareMigration.DestinationDomainUser
                $destDomainPass = if ($destCredName) { & $credScript -Name $destCredName } else { $srcDomainPass }
                $deleteUser = if ($destCredUser) { $destCredUser } else { $srcCredUser }
                Stop-ShareMigCifs -ControllerName $cluster.ConnectName -Vserver $vserver -DomainAdminUser $deleteUser -DomainAdminPassword $destDomainPass
            } else {
                Write-ShareMigLog "--- Step 1/5: No CIFS server on $vserver — skip delete ---" 'INFO'
            }

            # --- Step 2/5: Set preferred DC + discovery-mode for source domain ---
            Write-ShareMigLog "--- Step 2/5: Configuring preferred DC and discovery-mode ---" 'INFO'
            # Reset discovery-mode to 'all' first to allow source DC discovery
            try {
                Invoke-NcSsh -Command "set advanced -confirmations off; vserver cifs domain discovered-servers discovery-mode modify -vserver $vserver -mode all" | Out-Null
                Write-ShareMigLog "Reset discovery-mode=all on $vserver (pre-join)" 'INFO'
            } catch { }
            # Clear destination domain's preferred DCs (set during migration)
            $destDomain = $shareMigConfig.ShareMigration.DestinationDomain
            $oldDestPrefDc = Get-NcCifsPreferredDomainController -Domain $destDomain | Where-Object { $_.Vserver -eq $vserver }
            if ($oldDestPrefDc) {
                foreach ($entry in $oldDestPrefDc) {
                    Remove-NcCifsPreferredDomainController -Domain $entry.Domain -DomainControllers $entry.PreferredDc -VserverContext $vserver -ErrorAction SilentlyContinue | Out-Null
                }
                Write-ShareMigLog "Cleared destination preferred DCs ($destDomain) from $vserver" 'INFO'
            }
            # Also clear any stale source domain preferred DCs
            $oldSrcPrefDc = Get-NcCifsPreferredDomainController -Domain $srcDomain | Where-Object { $_.Vserver -eq $vserver }
            if ($oldSrcPrefDc) {
                foreach ($entry in $oldSrcPrefDc) {
                    Remove-NcCifsPreferredDomainController -Domain $entry.Domain -DomainControllers $entry.PreferredDc -VserverContext $vserver -ErrorAction SilentlyContinue | Out-Null
                }
                Write-ShareMigLog "Cleared stale source preferred DCs ($srcDomain) from $vserver" 'INFO'
            }
            # Add source preferred DC if configured (must be IP address)
            $srcDc = $shareMigConfig.ShareMigration.SourceDomainController
            $srcSiteName = $shareMigConfig.ShareMigration.SourceDefaultSiteName
            if ($srcDc) {
                Add-NcCifsPreferredDomainController -Domain $srcDomain -DomainControllers @($srcDc) -SkipConfigValidation:$true -VserverContext $vserver -ErrorAction SilentlyContinue | Out-Null
                Write-ShareMigLog "Set preferred DC for $srcDomain on ${vserver}: $srcDc" 'PASS'
            }
            # Set discovery-mode: explicit config wins, then auto-logic
            $srcDiscoveryOverride = $shareMigConfig.ShareMigration.SourceDiscoveryMode
            if ($srcDiscoveryOverride) {
                $srcDiscoveryMode = $srcDiscoveryOverride
            } elseif ($srcSiteName) {
                $srcDiscoveryMode = 'site'
            } elseif ($srcDc) {
                $srcDiscoveryMode = 'none'
            } else {
                $srcDiscoveryMode = 'all'
            }
            try {
                Invoke-NcSsh -Command "set advanced -confirmations off; vserver cifs domain discovered-servers discovery-mode modify -vserver $vserver -mode $srcDiscoveryMode" | Out-Null
                Write-ShareMigLog "Set discovery-mode=$srcDiscoveryMode on $vserver" 'PASS'
            } catch {
                Write-ShareMigLog "Could not set discovery-mode: $($_.Exception.Message)" 'WARN'
            }

            # --- Step 3/5: Restore DNS ---
            $srcDnsServers = @($shareMigConfig.ShareMigration.SourceDnsServers | Where-Object { $_ })
            $srcDnsDomains = @($shareMigConfig.ShareMigration.SourceDnsDomains | Where-Object { $_ })
            if ($srcDnsServers.Count -gt 0 -and $srcDnsDomains.Count -gt 0) {
                Write-ShareMigLog "--- Step 3/5: Restoring DNS on $vserver ---" 'INFO'
                Set-ShareMigDns -ClusterConnectName $cluster.ConnectName -Vserver $vserver -NameServers $srcDnsServers -Domains $srcDnsDomains
            } else {
                Write-ShareMigLog '--- Step 3/5: DNS restore skipped (SourceDnsServers not configured) ---' 'INFO'
            }

            # --- Step 4/5: Create CIFS (join source domain) ---
            Write-ShareMigLog "--- Step 4/5: Creating CIFS on $vserver (joining $srcDomain) ---" 'INFO'
            $snapData = Get-Content $SnapshotPath -Raw | ConvertFrom-Json
            $snapPair = $snapData.Pairs | Where-Object { $_.PairName -eq $pair.Name } | Select-Object -First 1
            $cifsName = if ($snapPair -and $snapPair.CifsServerName) { $snapPair.CifsServerName } else { $vserver }
            # Aliases: prefer snapshot, fall back to config
            $aliases = @($snapPair.NetbiosAliases | Where-Object { $_ })
            if ($aliases.Count -eq 0) {
                $cfgAlias = $shareMigConfig.ShareMigration.SourceNetbiosAlias
                if ($cfgAlias) { $aliases = @($cfgAlias) }
            }
            $srcOu = $shareMigConfig.ShareMigration.SourceOrganizationalUnit
            $cifsParams = @{
                ControllerName      = $cluster.ConnectName
                Vserver             = $vserver
                CifsServerName      = $cifsName
                Domain              = $srcDomain
                DomainAdminUser     = $srcCredUser
                DomainAdminPassword = $srcDomainPass
            }
            if ($srcSiteName)        { $cifsParams['DefaultSiteName']      = $srcSiteName }
            if ($srcOu)              { $cifsParams['OrganizationalUnit']   = $srcOu }
            if ($aliases.Count -gt 0) { $cifsParams['NetbiosAliases']      = $aliases }
            Start-ShareMigCifs @cifsParams

            # Log SPN commands the user must run in AD (if aliases exist)
            if ($aliases.Count -gt 0) {
                Write-ShareMigLog "--- ACTION REQUIRED: Register SPNs for NetBIOS aliases ---" 'WARN'
                foreach ($alias in $aliases) {
                    Write-ShareMigLog "  SETSPN -a host/$alias $cifsName" 'WARN'
                    Write-ShareMigLog "  SETSPN -a host/$alias.$srcDomain $cifsName" 'WARN'
                }
            }
        }

        # --- Step 5/5: Import shares from snapshot ---
        Write-ShareMigLog '--- Step 5/5: Importing shares from snapshot ---' 'INFO'
        $rollbackDc = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
        $rollbackCred = New-Object pscredential($srcCredUser, (ConvertTo-SecureString $srcDomainPass -AsPlainText -Force))
        Import-ShareMigration -SnapshotFile $SnapshotPath -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $rollbackDc -DomainCredential $rollbackCred | Out-Null
        Write-ShareMigLog '=== ROLLBACK COMPLETE ===' 'PASS'
    }
    'ResetCifsPassword' {
        # On-demand CIFS machine account password reset
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'

        foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
            if ($Target -in @('Source', 'Both')) {
                $srcCluster  = Resolve-ClusterEntry -ClusterName $pair.SourceCluster -ClusterList $global:ONTAP_Clusters
                $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
                $srcCredUser = $shareMigConfig.ShareMigration.SourceDomainUser
                $srcPass     = & $credScript -Name $srcCredName
                & $srcCluster.ConnectName | Out-Null
                Write-ShareMigLog "Resetting CIFS password: $($pair.SourceVserver) ($($shareMigConfig.ShareMigration.Domain))" 'INFO'
                Reset-NcCifsPassword -AdminUsername $srcCredUser -AdminPassword $srcPass -VserverContext $pair.SourceVserver -ErrorAction Stop
                Write-ShareMigLog "CIFS password reset: $($pair.SourceVserver) — PASSED" 'PASS'
            }

            if ($Target -in @('Destination', 'Both')) {
                $destCluster  = Resolve-ClusterEntry -ClusterName $pair.DestinationCluster -ClusterList $global:ONTAP_Clusters
                $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
                $destCredUser = $shareMigConfig.ShareMigration.DestinationDomainUser
                $destPass     = & $credScript -Name $destCredName
                & $destCluster.ConnectName | Out-Null
                Write-ShareMigLog "Resetting CIFS password: $($pair.DestinationVserver) ($($shareMigConfig.ShareMigration.DestinationDomain))" 'INFO'
                Reset-NcCifsPassword -AdminUsername $destCredUser -AdminPassword $destPass -VserverContext $pair.DestinationVserver -ErrorAction Stop
                Write-ShareMigLog "CIFS password reset: $($pair.DestinationVserver) — PASSED" 'PASS'
            }
        }
    }
}