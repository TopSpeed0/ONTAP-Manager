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
    [ValidateSet('Export', 'Import', 'Preflight', 'Sync', 'DomainMigration', 'Rollback', 'TestCredentials', 'ResetCifsPassword', 'SetSPN')]
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
        $_.Alias -eq $ClusterName -or $_.cluster -eq $ClusterName
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
        [string]$UserName  # Optional — resolved from credentials.json if not provided
    )

    # Try registry lookup when UserName not explicitly given
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $registryFile = Join-Path $WorkspaceRoot 'credentials\credentials.json'
        if (Test-Path -LiteralPath $registryFile) {
            $registry = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
            if ($registry.PSObject.Properties.Name -contains $CredentialName) {
                $UserName = $registry.$CredentialName.UserName
            }
        }
        if ([string]::IsNullOrWhiteSpace($UserName)) {
            $UserName = $CredentialName  # Last resort fallback
        }
    }

    $credPath = Join-Path $WorkspaceRoot "credentials\$CredentialName.cred"
    if (Test-Path -LiteralPath $credPath) {
        $sec = & (Join-Path $WorkspaceRoot 'scripts\credentials\Get-Credential.ps1') -Name $CredentialName -AsSecureString
        return [pscredential]::new($UserName, $sec)
    }

    Write-ShareMigLog "Credential file not found for '$CredentialName'. Prompting interactively." 'WARN'
    return Get-Credential -UserName $UserName -Message "Enter password for $UserName ($CredentialName)"
}

function Resolve-CredentialUserName {
    <#
    .SYNOPSIS
        Resolve a username for a credential name. Uses config override first, then credentials.json registry, then fallback.
    #>
    param(
        [Parameter(Mandatory)] [string]$WorkspaceRoot,
        [Parameter(Mandatory)] [string]$CredentialName,
        [string]$ConfigOverride,   # Value from config (SourceDomainUser, CredentialUserName etc.)
        [string]$Fallback = $null  # Last resort (e.g. 'admin', 'administrator')
    )

    # 1. Config override wins if present
    if (-not [string]::IsNullOrWhiteSpace($ConfigOverride)) { return $ConfigOverride }

    # 2. Registry lookup
    $registryFile = Join-Path $WorkspaceRoot 'credentials\credentials.json'
    if (Test-Path -LiteralPath $registryFile) {
        $registry = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
        if ($registry.PSObject.Properties.Name -contains $CredentialName) {
            $regUser = $registry.$CredentialName.UserName
            if (-not [string]::IsNullOrWhiteSpace($regUser)) { return $regUser }
        }
    }

    # 3. Fallback
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return $Fallback }
    return $CredentialName
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
$script:ProtectedMembershipGroups = @('Domain Admins', 'Enterprise Admins', 'Administrators')

function Invoke-ShareMigCli {
    param(
        [Parameter(Mandatory)] [string]$ControllerName,
        [Parameter(Mandatory)] [string]$Command
    )

    $sshFunc = "$Controller-ssh"
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
    & $cluster.cluster | Out-Null
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
    & $cluster.cluster | Out-Null

    # --- LDAP signing check (KB: ADV190023 / NetApp KB 000077994) ---
    # DCs that enforce LDAP signing reject unsigned ONTAP binds during domain join.
    # Setting 'sign' is backward-compatible — DCs that don't require it still accept signed connections.
    # After CIFS deletion, Get-NcCifsSecurity returns null — use SSH to set it directly.
    $cifsSec = Get-NcCifsSecurity -VserverContext $Vserver -ErrorAction SilentlyContinue
    if (-not $cifsSec) {
        Write-ShareMigLog "No CIFS server on $Vserver (post-delete) — setting LDAP session security to 'sign' via SSH" 'WARN'
        Invoke-NcSsh -Command "set advanced -confirmations off; vserver cifs security modify -vserver $Vserver -session-security-for-ad-ldap sign" -ErrorAction SilentlyContinue | Out-Null
        Write-ShareMigLog "LDAP session security set to 'sign' on $Vserver (pre-join)" 'PASS'
    } elseif ($cifsSec.SessionSecurityForAdLdap -eq 'none') {
        Write-ShareMigLog "LDAP session security is 'none' on $Vserver — setting to 'sign' (required by modern DCs)" 'WARN'
        Set-NcCifsSecurity -VserverContext $Vserver -SessionSecurityForAdLdap 'sign' -ErrorAction Stop | Out-Null
        Write-ShareMigLog "LDAP session security set to 'sign' on $Vserver" 'PASS'
    } else {
        Write-ShareMigLog "LDAP session security already '$($cifsSec.SessionSecurityForAdLdap)' on $Vserver — OK" 'INFO'
    }

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
        [Parameter(Mandatory)] [string]$cluster,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string[]]$NameServers,
        [Parameter(Mandatory)] [string[]]$Domains
    )

    # Connect to cluster via ZAPI
    $clusterEntry = Resolve-ClusterEntry -ClusterName $cluster -ClusterList $global:ONTAP_Clusters
    & $clusterEntry.cluster | Out-Null

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
        [Parameter(Mandatory)] [string]$cluster,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string[]]$DomainControllers
    )

    $clusterEntry = Resolve-ClusterEntry -ClusterName $cluster -ClusterList $global:ONTAP_Clusters
    & $clusterEntry.cluster | Out-Null

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
        # Force a real LDAP bind via DirectorySearcher (DirectoryEntry is lazy and may not throw)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = '(objectClass=domainDNS)'
        $searcher.SizeLimit = 1
        $result = $searcher.FindOne()
        if ($result) {
            return [pscustomobject]@{ Success = $true; Domain = $Domain; User = $Username; Server = $ldapPath; Error = $null }
        } else {
            return [pscustomobject]@{ Success = $false; Domain = $Domain; User = $Username; Server = $ldapPath; Error = "LDAP bind succeeded but no domain object found — check DC connectivity" }
        }
    }
    catch {
        $msg = $_.Exception.InnerException.Message ?? $_.Exception.Message
        return [pscustomobject]@{ Success = $false; Domain = $Domain; User = $Username; Server = $ldapPath; Error = $msg }
    }
    finally {
        if ($searcher) { try { $searcher.Dispose() } catch { } }
        if ($entry) { try { $entry.Dispose() } catch { } }
    }
}

function Test-DomainComputerPermission {
    <#
    .SYNOPSIS
        Validate domain credentials have sufficient permissions by creating and deleting
        a dummy computer object in the target OU. This proves the account can join/unjoin
        machines from the domain (required for CIFS create/delete).
    #>
    param(
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$Username,
        [Parameter(Mandatory)] [string]$Password,
        [string]$DomainController,
        [string]$OrganizationalUnit
    )

    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = [pscredential]::new($Username, $sec)

    # Resolve DC — try specified DC first, fall back to auto-discovery if AD Web Services unreachable
    $dc = $DomainController
    if ([string]::IsNullOrWhiteSpace($dc)) {
        $dc = (Get-ADDomainController -Discover -DomainName $Domain -Credential $cred -ErrorAction Stop).HostName[0]
    }

    # Resolve OU — use provided OU or default to CN=Computers
    # If OU doesn't contain DC= components, it's relative — append domain DN
    # Derive domain DN from FQDN string (avoids Get-ADDomain which needs AD Web Services port 9389)
    $ou = $OrganizationalUnit
    $domainDn = ($Domain -split '\.' | ForEach-Object { "DC=$_" }) -join ','
    if ([string]::IsNullOrWhiteSpace($ou)) {
        $ou = "CN=Computers,$domainDn"
    } elseif ($ou -notmatch 'DC=') {
        $ou = "$ou,$domainDn"
    }

    $dummyName = "SHAREMIG_TEST_$(Get-Random -Minimum 10000 -Maximum 99999)"

    try {
        # Create dummy computer
        New-ADComputer -Name $dummyName -SamAccountName "$dummyName`$" -Path $ou -Server $dc -Credential $cred -ErrorAction Stop
        # Delete dummy computer
        Remove-ADComputer -Identity $dummyName -Server $dc -Credential $cred -Confirm:$false -ErrorAction Stop
        return [pscustomobject]@{ Success = $true; Domain = $Domain; User = $Username; Server = $dc; OU = $ou; Error = $null }
    }
    catch {
        $originalError = $_.Exception.Message
        # If the configured DC is unreachable (AD Web Services port 9389), try discovering a local DC
        if ($originalError -match 'Unable to contact the server' -and $DomainController) {
            try {
                # Discover nearest DC without explicit credentials (uses machine's AD context / DNS SRV)
                $fallbackDc = (Get-ADDomainController -Discover -DomainName $Domain -ForceDiscover -ErrorAction Stop).HostName[0]
                if ($fallbackDc) {
                    $dummyName2 = "SHAREMIG_TEST_$(Get-Random -Minimum 10000 -Maximum 99999)"
                    New-ADComputer -Name $dummyName2 -SamAccountName "$dummyName2`$" -Path $ou -Server $fallbackDc -Credential $cred -ErrorAction Stop
                    Remove-ADComputer -Identity $dummyName2 -Server $fallbackDc -Credential $cred -Confirm:$false -ErrorAction Stop
                    return [pscustomobject]@{ Success = $true; Domain = $Domain; User = $Username; Server = "$fallbackDc (fallback; $dc unreachable)"; OU = $ou; Error = $null }
                }
            } catch {
                # Fallback also failed — report both errors
                $fallbackError = $_.Exception.Message
                return [pscustomobject]@{ Success = $false; Domain = $Domain; User = $Username; Server = $dc; OU = $ou; Error = "Primary DC ($dc): $originalError | Fallback: $fallbackError" }
            }
        }
        # Attempt cleanup if create succeeded but delete failed
        try { Remove-ADComputer -Identity $dummyName -Server $dc -Credential $cred -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        return [pscustomobject]@{ Success = $false; Domain = $Domain; User = $Username; Server = $dc; OU = $ou; Error = $_.Exception.Message }
    }
}

function Register-ShareMigAliasSpns {
    <#
    .SYNOPSIS
        Register missing HOST SPNs for CIFS NetBIOS aliases with SETSPN -S-style ownership checks.
    #>
    param(
        [Parameter(Mandatory)] [string]$CifsServerName,
        [Parameter(Mandatory)] [string[]]$Aliases,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$DomainController,
        [Parameter(Mandatory)] [pscredential]$Credential,
        [string]$LogPrefix = ''
    )

    $prefix = if ($LogPrefix) { "$LogPrefix " } else { '' }
    $registered = 0
    $alreadyPresent = 0
    $conflicts = 0
    $failed = 0

    try {
        $adComputer = Get-ADComputer -Identity $CifsServerName -Server $DomainController -Credential $Credential -Properties servicePrincipalName -ErrorAction Stop
    } catch {
        Write-ShareMigLog "${prefix}Could not read AD computer '$CifsServerName' for SPN registration: $($_.Exception.Message)" 'ERROR'
        return [pscustomobject]@{
            Success        = $false
            Registered     = 0
            AlreadyPresent = 0
            Conflicts      = 0
            Failed         = 1
        }
    }

    $targetDistinguishedName = $adComputer.DistinguishedName
    $existingSpns = @($adComputer.servicePrincipalName)
    $requestedSpns = foreach ($alias in @($Aliases | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)) {
        "HOST/$alias"
        "HOST/$alias.$Domain"
    }
    $spnsToRegister = [System.Collections.Generic.List[string]]::new()

    foreach ($spn in @($requestedSpns | Sort-Object -Unique)) {
        if ($existingSpns -contains $spn) {
            Write-ShareMigLog "${prefix}SPN already present: $spn -> $CifsServerName" 'INFO'
            $alreadyPresent++
            continue
        }

        try {
            $spnOwners = @(Get-ADObject -LDAPFilter "(servicePrincipalName=$spn)" -Server $DomainController -Credential $Credential -Properties distinguishedName -ErrorAction Stop)
        } catch {
            Write-ShareMigLog "${prefix}Could not check SPN ownership for ${spn}: $($_.Exception.Message)" 'ERROR'
            $failed++
            continue
        }

        $otherOwners = @($spnOwners | Where-Object { $_.DistinguishedName -ne $targetDistinguishedName })
        if ($otherOwners.Count -gt 0) {
            Write-ShareMigLog "${prefix}SPN conflict: $spn is already owned by $($otherOwners.DistinguishedName -join ', ')" 'ERROR'
            $conflicts++
            continue
        }

        if ($spnOwners.Count -gt 0) {
            Write-ShareMigLog "${prefix}SPN already present: $spn -> $CifsServerName" 'INFO'
            $alreadyPresent++
            continue
        }

        $spnsToRegister.Add($spn)
    }

    # Do not leave a partially registered alias set behind when any requested SPN conflicts.
    if ($conflicts -gt 0 -or $failed -gt 0) {
        Write-ShareMigLog "${prefix}SPN summary: 0 registered, $alreadyPresent already present, $conflicts conflicts, $failed failed" 'ERROR'
        return [pscustomobject]@{
            Success        = $false
            Registered     = 0
            AlreadyPresent = $alreadyPresent
            Conflicts      = $conflicts
            Failed         = $failed
        }
    }

    foreach ($spn in $spnsToRegister) {
        try {
            Set-ADComputer -Identity $targetDistinguishedName -Add @{ servicePrincipalName = $spn } -Server $DomainController -Credential $Credential -ErrorAction Stop
            Write-ShareMigLog "${prefix}SPN registered: $spn -> $CifsServerName (DC: $DomainController)" 'PASS'
            $existingSpns += $spn
            $registered++
        } catch {
            Write-ShareMigLog "${prefix}SPN registration failed: $spn -> $CifsServerName - $($_.Exception.Message)" 'ERROR'
            $failed++
        }
    }

    $success = $conflicts -eq 0 -and $failed -eq 0
    Write-ShareMigLog "${prefix}SPN summary: $registered registered, $alreadyPresent already present, $conflicts conflicts, $failed failed" $(if ($success) { 'PASS' } else { 'ERROR' })
    return [pscustomobject]@{
        Success        = $success
        Registered     = $registered
        AlreadyPresent = $alreadyPresent
        Conflicts      = $conflicts
        Failed         = $failed
    }
}

function Invoke-CifsPasswordReset {
    <#
    .SYNOPSIS
        Reset CIFS domain password on a specific SVM using PowerShell cmdlet.
    #>
    param(
        [Parameter(Mandatory)] [string]$cluster,
        [Parameter(Mandatory)] [string]$Vserver,
        [Parameter(Mandatory)] [string]$AdminUsername,
        [Parameter(Mandatory)] [string]$AdminPassword
    )

    # Ensure we're connected to the cluster
    $controller = $global:CurrentNcController
    if (-not $controller -or $controller.Name -ne $cluster) {
        $clusterEntry = Resolve-ClusterEntry -ClusterName $cluster -ClusterList $global:ONTAP_Clusters
        & $clusterEntry.cluster
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

    $sshFunc = "$Controller-ssh"
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

    $escapedGroupName = $GroupName.Replace("'", "''")
    $group = @(Get-ADGroup -Filter "Name -eq '$escapedGroupName' -or SamAccountName -eq '$escapedGroupName'" -SearchBase $GroupOuPath -Server $DomainControllerName -Credential $Credential -ErrorAction Stop | Select-Object -First 1)
    if ($group) {
        Write-ShareMigLog "Found AD group '$GroupName'" 'PASS'
        return $group[0]
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

    $shortGroupName = if ($GroupName -match '\\') { ($GroupName -split '\\', 2)[1] } else { $GroupName }
    if ($script:ProtectedMembershipGroups -contains $shortGroupName) {
        Write-ShareMigLog "Skipping membership update for protected group '$GroupName'. Domain Admins, Enterprise Admins, and Administrators are never changed automatically." 'WARN'
        return
    }

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
    & $sourceCluster.cluster | Out-Null
    $cifsObj = Get-NcCifsServer -VserverContext $sourceVserver
    $cifsServerName = if ($cifsObj) { $cifsObj.CifsServer } else { '' }
    $netbiosAliases = if ($cifsObj -and $cifsObj.NetbiosAliases) { @($cifsObj.NetbiosAliases) } else { @() }

    $shareObjs = Get-NcCifsShare -VserverContext $sourceVserver | Where-Object { $_.ShareName -notin @('admin$', 'c$', 'ipc$') }

    if ($Pair.ShareFilter -and $Pair.ShareFilter -ne '*' ) {
        $shareObjs = $shareObjs | Where-Object { $_.ShareName -like $Pair.ShareFilter }
    }

    $shares = foreach ($share in @($shareObjs)) {
        $shareName = $share.ShareName
        $acl = Get-ShareAclExport -ControllerName $sourceCluster.cluster -Vserver $sourceVserver -ShareName $shareName -DomainControllerName $DomainControllerName -DomainCredential $DomainCredential

        [pscustomobject]@{
            SourceCluster   = $sourceCluster.cluster
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
        Source          = $sourceCluster.cluster
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

function Format-ShareMigExportSummary {
    param([Parameter(Mandatory)] $Snapshot)

    $rows = foreach ($pair in @($Snapshot.Pairs)) {
        foreach ($share in @($pair.Shares)) {
            $aclSummary = @($share.Acl | ForEach-Object { "$($_.Principal) ($($_.Permission))" }) -join '; '
            [pscustomobject]@{
                Pair   = $pair.PairName
                Source = "$($pair.Source)/$($pair.Vserver)"
                Share  = $share.ShareName
                Path   = $share.Path
                ACLs   = $aclSummary
            }
        }
    }

    "`nExport Summary"
    "Exported: $($Snapshot.Metadata.ExportedAt)"
    "Domain:   $($Snapshot.Metadata.Domain)"
    "Shares:   $($rows.Count)"
    ''
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 240
}

function Format-ShareMigImportSummary {
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)] [string]$ImportTarget
    )

    $rows = foreach ($pair in @($Snapshot.Pairs)) {
        foreach ($share in @($pair.Shares)) {
            [pscustomobject]@{
                Pair       = $pair.PairName
                Share      = $share.ShareName
                Path       = $share.Path
                ACLCount   = @($share.Acl).Count
                ACLSummary = @($share.Acl | ForEach-Object { "$($_.Principal) ($($_.Permission))" }) -join '; '
            }
        }
    }

    "`nImport Summary"
    "Target:   $ImportTarget"
    "Snapshot: $($Snapshot.Metadata.ExportedAt)"
    "Shares:   $($rows.Count)"
    ''
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 240
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
        [string]$TargetDomainNetbiosName,
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
                $isForeignDomainGroup = $acl.Principal -match '^(?<Domain>[^\\]+)\\' -and $Matches.Domain -ne $TargetDomainNetbiosName
                if ($isForeignDomainGroup) {
                    Write-ShareMigLog "Skipping foreign-domain group '$($acl.Principal)' on '$($Share.ShareName)' (target AD NetBIOS name: $TargetDomainNetbiosName)" 'WARN'
                    continue
                }

                $groupName = if ($acl.Principal -match '\\') { ($acl.Principal -split '\\', 2)[1] } else { $acl.Principal }
                $group = Ensure-ShareMigAdGroup -DomainControllerName $DomainControllerName -Credential $DomainCredential -GroupName $groupName -GroupOuPath $GroupOuPath
                if ($acl.GroupMembers) {
                    Add-ShareMigGroupMembers -DomainControllerName $DomainControllerName -Credential $DomainCredential -GroupName $group.Name -Members @($acl.GroupMembers)
                }
            }
        }
    } else {
        Write-ShareMigLog "SkipGroupCreation=true — replaying ACLs as-is without AD group promotion" 'INFO'
    }

    $destinationCluster = Resolve-ClusterEntry -ClusterName $DestinationClusterName -ClusterList $global:ONTAP_Clusters
    & $destinationCluster.cluster | Out-Null
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

    $existingAcls = @(Get-NcCifsShareAcl -Share $Share.ShareName -VserverContext $DestinationVserver -ErrorAction Stop)
    foreach ($acl in @($Share.Acl)) {
        $targetPrincipal = $acl.Principal

        $isForeignDomainGroup = $acl.PrincipalType -eq 'Group' -and $acl.Principal -match '^(?<Domain>[^\\]+)\\' -and $Matches.Domain -ne $TargetDomainNetbiosName
        if ($isForeignDomainGroup) {
            continue
        }

        # When SkipGroupCreation is off, individual users get promoted to groups
        if (-not $skipGroups -and $acl.PrincipalType -eq 'User') {
            $targetPrincipal = New-ShareMigGroupName -Prefix $GroupPrefix -ShareName $Share.ShareName -Permission $acl.Permission
        }

        $matchingAcl = $existingAcls | Where-Object {
            $_.UserOrGroup -eq $targetPrincipal -and $_.Permission -eq $acl.Permission
        } | Select-Object -First 1
        if ($matchingAcl) {
            Write-ShareMigLog "ACL '$targetPrincipal' on share '$($Share.ShareName)' already applied; skipped" 'PASS'
            continue
        }

        if ($PSCmdlet.ShouldProcess("$DestinationClusterName/$DestinationVserver", "Apply ACL $targetPrincipal -> $($Share.ShareName)")) {
            try {
                Add-NcCifsShareAcl -Share $Share.ShareName -UserOrGroup $targetPrincipal -Permission $acl.Permission -VserverContext $DestinationVserver -ErrorAction Stop | Out-Null
                Write-ShareMigLog "Applied ACL '$targetPrincipal' => '$($Share.ShareName)' ($($acl.Permission))" 'PASS'
                $existingAcls += [pscustomobject]@{ UserOrGroup = $targetPrincipal; Permission = $acl.Permission }
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
    if ($Target -eq 'Both') {
        throw "Import requires -Target Source or -Target Destination. Target Both is not supported."
    }

    $groupOuPath = if ($Target -eq 'Source') {
        $Config.ShareMigration.SourceGroupOuPath ?? $Config.ShareMigration.GroupOuPath
    } else {
        $Config.ShareMigration.DestinationGroupOuPath ?? $Config.ShareMigration.GroupOuPath
    }

    foreach ($pairSnapshot in @($snapshot.Pairs)) {
        $pair = $Config.ShareMigration.Pairs | Where-Object { $_.Name -eq $pairSnapshot.PairName } | Select-Object -First 1
        if (-not $pair) {
            $msg = "Pair '$($pairSnapshot.PairName)' was not found in Config_shareMig.json"
            Write-ShareMigLog $msg 'ERROR'
            throw $msg
        }

        $targetClusterName = if ($Target -eq 'Source') { $pair.SourceCluster } else { $pair.DestinationCluster }
        $targetVserver = if ($Target -eq 'Source') {
            if ($pair.SourceVserver) { $pair.SourceVserver } else { $SourceVserver }
        } else {
            if ($pair.DestinationVserver) { $pair.DestinationVserver } else { $DestinationVserver }
        }
        if ([string]::IsNullOrWhiteSpace($targetVserver)) {
            throw "$Target Vserver is required for pair '$($pair.Name)'"
        }

        $targetCluster = Resolve-ClusterEntry -ClusterName $targetClusterName -ClusterList $global:ONTAP_Clusters
        $targetAdDomain = Get-ADDomain -Server $DomainControllerName -Credential $DomainCredential -ErrorAction Stop
        $targetDomainNetbiosName = $targetAdDomain.NetBIOSName
        Write-ShareMigLog "Importing pair '$($pair.Name)' to $($targetCluster.cluster)/$targetVserver (AD target: $Target, NetBIOS: $targetDomainNetbiosName)" 'INFO'
        foreach ($share in @($pairSnapshot.Shares)) {
            Ensure-ShareMigAclTarget -Pair $pair -Share $share -Config $Config -DomainControllerName $DomainControllerName -DomainCredential $DomainCredential -GroupOuPath $groupOuPath -GroupPrefix $groupPrefix -TargetDomainNetbiosName $targetDomainNetbiosName -DestinationClusterName $targetCluster.cluster -DestinationVserver $targetVserver
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

    Write-ShareMigLog "Preflight step 1: NetApp credential cache check for $($cluster.cluster)" 'INFO'
    $netappCredName = $cluster.API_Cred
    $netappUser = Resolve-CredentialUserName -WorkspaceRoot $WorkspaceRoot -CredentialName $netappCredName -ConfigOverride $cluster.CredentialUserName -Fallback 'admin'
    $netappCred = Get-ClusterCredential -WorkspaceRoot $WorkspaceRoot -CredentialName $netappCredName -UserName $netappUser
    Ensure-NcCredential -ControllerName $cluster.cluster -Credential $netappCred
    try {
        Connect-NcController -Name $cluster.cluster -Credential $netappCred -ErrorAction Stop | Out-Null
    } catch {
        Write-ShareMigLog "Preflight cluster connection FAILED ($($cluster.cluster)) — $($_.Exception.Message)" 'ERROR'
        throw
    }

    Write-ShareMigLog "Preflight step 2: DC discovery and auth against $($Config.ShareMigration.Domain)" 'INFO'
    # Resolve credentials from config if not passed (happens when SkipGroupCreation=true)
    $pfCredential = $DomainCredential
    $pfDc = $DomainControllerName
    if (-not $pfCredential) {
        $srcCredName = $Config.ShareMigration.SourceDomainCredentialName
        if ($srcCredName) {
            $srcCredUser = Resolve-CredentialUserName -WorkspaceRoot $WorkspaceRoot -CredentialName $srcCredName -ConfigOverride $Config.ShareMigration.SourceDomainUser
            $pfCredential = Get-ClusterCredential -WorkspaceRoot $WorkspaceRoot -CredentialName $srcCredName -UserName $srcCredUser
        }
    }
    if ([string]::IsNullOrWhiteSpace($pfDc)) {
        $pfDc = @($Config.ShareMigration.SourceDomainController)[0]
    }
    $resolvedDc = Test-ShareMigAdConnection -Domain $Config.ShareMigration.Domain -PreferredController $pfDc -Credential $pfCredential
    Write-ShareMigLog "Connected to DC $resolvedDc" 'PASS'

    $skipGroups = Test-ShareMigSkipGroupCreation -Config $Config
    if ($skipGroups) {
        Write-ShareMigLog "Preflight step 3: SKIPPED — SkipGroupCreation=true (no AD group test needed)" 'PASS'
    } else {
        Write-ShareMigLog "Preflight step 3: AD group create/discover for $($preflight.GroupName)" 'INFO'
        try {
            Ensure-ShareMigAdGroup -DomainControllerName $resolvedDc -Credential $DomainCredential -GroupName $preflight.GroupName -GroupOuPath ($Config.ShareMigration.SourceGroupOuPath ?? $Config.ShareMigration.GroupOuPath) | Out-Null
        } catch {
            Write-ShareMigLog "Preflight AD group FAILED — $($_.Exception.Message)" 'ERROR'
            throw
        }
    }

    Write-ShareMigLog "Preflight step 4: SMB share create/discover for $($preflight.ShareName)" 'INFO'
    & $cluster.cluster | Out-Null
    $shareExists = Get-NcCifsShare -Name $preflight.ShareName -VserverContext $vserver -ErrorAction SilentlyContinue
    if (-not $shareExists) {
        if ([string]::IsNullOrWhiteSpace($preflight.SharePath)) {
            throw "Preflight SharePath is missing in Config_shareMig.json"
        }
        if ($PSCmdlet.ShouldProcess("$($cluster.cluster)/$vserver", "Create preflight share $($preflight.ShareName)")) {
            try {
                Add-NcCifsShare -Name $preflight.ShareName -Path $preflight.SharePath -ShareProperties @('browsable','oplocks','changenotify') -VserverContext $vserver -ErrorAction Stop | Out-Null
                Write-ShareMigLog "Created preflight share '$($preflight.ShareName)'" 'PASS'
            } catch {
                Write-ShareMigLog "Preflight share creation FAILED — $($_.Exception.Message)" 'ERROR'
                throw
            }
        }
    }
    else {
        Write-ShareMigLog "Preflight share '$($preflight.ShareName)' already exists" 'PASS'
    }

    if ($skipGroups) {
        Write-ShareMigLog "Preflight ACL test: SKIPPED — SkipGroupCreation=true (will replay original principals)" 'PASS'
    } elseif ($PSCmdlet.ShouldProcess("$($cluster.cluster)/$vserver", "Apply preflight ACL $($preflight.GroupName)")) {
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
        Cluster          = $cluster.cluster
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
$autoRegisterSpn = [bool]$shareMigConfig.ShareMigration.AutoRegisterSPN

# AD cmdlets are required for group creation and automatic SPN registration.
if (-not $skipGroups -or $autoRegisterSpn) {
    try { Import-Module ActiveDirectory -ErrorAction Stop } catch {
        throw "ActiveDirectory module is required when SkipGroupCreation=false or AutoRegisterSPN=true. Install RSAT / AD tools first. $($_.Exception.Message)"
    }
}

$resolvedDc = $null
$domainCredential = $DomainCredential
$adDomain = $shareMigConfig.ShareMigration.Domain
$adCredentialName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
$adCredentialUser = $shareMigConfig.ShareMigration.SourceDomainUser
$adController = @($shareMigConfig.ShareMigration.SourceDomainController)[0]

if ($Mode -eq 'Import' -and $Target -eq 'Destination') {
    $adDomain = $shareMigConfig.ShareMigration.DestinationDomain
    $adCredentialName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
    $adCredentialUser = $shareMigConfig.ShareMigration.DestinationDomainUser
    $adController = $shareMigConfig.ShareMigration.DestinationDomainController
}

if (-not $skipGroups) {
    if (-not $domainCredential) {
        $domainCredName = if ($adCredentialName) { $adCredentialName } else { 'administrator' }
        $domainUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $domainCredName -ConfigOverride $adCredentialUser -Fallback 'administrator'
        $domainCredential = Get-ClusterCredential -WorkspaceRoot $workspaceRoot -CredentialName $domainCredName -UserName $domainUser
    }

    if ([string]::IsNullOrWhiteSpace($DomainController)) {
        $DomainController = $adController
    }

    $resolvedDc = Test-ShareMigAdConnection -Domain $adDomain -PreferredController $DomainController -Credential $domainCredential
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
        Format-ShareMigExportSummary -Snapshot $result
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
        Format-ShareMigImportSummary -Snapshot $result -ImportTarget $Target
    }
    'Sync' {
        $exported = Export-ShareMigration -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential
        if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
            $SnapshotPath = Join-Path (Split-Path $script:ShareMigLogFile -Parent) 'share-migration.snapshot.json'
        }
        $exported | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $SnapshotPath
        Import-ShareMigration -SnapshotFile $SnapshotPath -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential | Out-Null
        Format-ShareMigExportSummary -Snapshot $exported
    }
    'DomainMigration' {
        # --- Validate domain credentials are configured ---
        $srcDomain  = $shareMigConfig.ShareMigration.Domain
        $destDomain = $shareMigConfig.ShareMigration.DestinationDomain
        $srcCredName  = $shareMigConfig.ShareMigration.SourceDomainCredentialName
        $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName

        if ([string]::IsNullOrWhiteSpace($srcDomain)) {
            throw "DomainMigration requires 'Domain' (source) in Config_shareMig.json"
        }
        if ([string]::IsNullOrWhiteSpace($destDomain)) {
            throw "DomainMigration requires 'DestinationDomain' in Config_shareMig.json"
        }
        if ([string]::IsNullOrWhiteSpace($srcCredName)) {
            throw "DomainMigration requires 'SourceDomainCredentialName' in Config_shareMig.json"
        }
        if ([string]::IsNullOrWhiteSpace($destCredName)) {
            throw "DomainMigration requires 'DestinationDomainCredentialName' in Config_shareMig.json"
        }

        # Resolve usernames: config override → credentials.json registry → fallback
        $srcCredUser  = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $srcCredName -ConfigOverride $shareMigConfig.ShareMigration.SourceDomainUser
        $destCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $destCredName -ConfigOverride $shareMigConfig.ShareMigration.DestinationDomainUser

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
            throw "Source domain credential test FAILED ($srcCredUser → $srcDomain): $($srcTest.Error)`nUpdate credentials with: .\scripts\credentials\New-Credential.ps1 -Name '$srcCredName'"
        }
        Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser → $srcDomain)" 'PASS'

        $destTest = Test-DomainCredential -Domain $destDomain -Username $destCredUser -Password $destDomainPass -DomainController $destDc
        if (-not $destTest.Success) {
            throw "Destination domain credential test FAILED ($destCredUser → $destDomain): $($destTest.Error)`nUpdate credentials with: .\scripts\credentials\New-Credential.ps1 -Name '$destCredName'"
        }
        Write-ShareMigLog "Destination domain auth: PASSED ($destCredUser → $destDomain)" 'PASS'

        # Test computer object create/delete permission on destination domain (proves join rights)
        $destOu_pf = if ($shareMigConfig.ShareMigration.DestinationOrganizationalUnit) { $shareMigConfig.ShareMigration.DestinationOrganizationalUnit } else { $null }
        $compTestDest = Test-DomainComputerPermission -Domain $destDomain -Username $destCredUser -Password $destDomainPass -DomainController $destDc -OrganizationalUnit $destOu_pf
        if (-not $compTestDest.Success) {
            throw "Destination domain computer-create permission test FAILED ($destCredUser → $destDomain, OU: $($compTestDest.OU)): $($compTestDest.Error)`nEnsure the account can create/delete computer objects in the target OU."
        }
        Write-ShareMigLog "Destination domain computer permission: PASSED (create+delete in $($compTestDest.OU))" 'PASS'

        Write-ShareMigLog "--- Pre-flight: All credential tests PASSED ---" 'PASS'

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
            if ($PSCmdlet.ShouldProcess("$($cluster.cluster)/$vserver", "Delete CIFS server (leave domain $srcDomain)")) {
                try {
                    Stop-ShareMigCifs -ControllerName $cluster.cluster -Vserver $vserver -DomainAdminUser $srcCredUser -DomainAdminPassword $srcDomainPass
                } catch {
                    Write-ShareMigLog "CIFS delete FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                    throw
                }
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
                if ($PSCmdlet.ShouldProcess("$($destCluster.cluster)/$vserver", "Update DNS to $($destDnsServers -join ', ')")) {
                    try {
                        Set-ShareMigDns -cluster $destCluster.cluster -Vserver $vserver -NameServers $destDnsServers -Domains $destDnsDomains
                    } catch {
                        Write-ShareMigLog "DNS update FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                        throw
                    }
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
                & $cluster.cluster | Out-Null

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

            # --- Pre-check: Remove stale machine account from source domain ---
            # If a trust exists between domains, a leftover computer object in the source
            # domain can cause "constraint violation" when creating it in the destination domain.
            $srcDc_mg   = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
            $srcSec_mg  = ConvertTo-SecureString $srcDomainPass -AsPlainText -Force
            $srcCred_mg = [pscredential]::new($srcCredUser, $srcSec_mg)

            try {
                $staleAccount = Get-ADComputer -Identity $cifsName -Server $srcDc_mg -Credential $srcCred_mg -ErrorAction Stop
            } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                $staleAccount = $null
            } catch {
                Write-ShareMigLog "Could not query source domain for stale machine account '$cifsName': $($_.Exception.Message)" 'WARN'
                $staleAccount = $null
            }

            if ($staleAccount) {
                Write-ShareMigLog "Found stale machine account '$cifsName' in source domain $srcDomain — removing to prevent trust conflict" 'WARN'
                try {
                    Remove-ADComputer -Identity $cifsName -Server $srcDc_mg -Credential $srcCred_mg -Confirm:$false -ErrorAction Stop
                    Write-ShareMigLog "Removed stale machine account '$cifsName' from $srcDomain (DC: $srcDc_mg)" 'PASS'
                } catch {
                    Write-ShareMigLog "FAILED to remove stale machine account '$cifsName' from $srcDomain — $($_.Exception.Message)" 'ERROR'
                    throw "Cannot proceed with migration: stale machine account '$cifsName' exists in $srcDomain and could not be removed. Remove it manually and retry."
                }
            } else {
                Write-ShareMigLog "No stale machine account '$cifsName' in source domain $srcDomain — OK" 'INFO'
            }

            $ou = if ($pair.DestinationOU) { $pair.DestinationOU } elseif ($shareMigConfig.ShareMigration.DestinationOrganizationalUnit) { $shareMigConfig.ShareMigration.DestinationOrganizationalUnit } else { $null }
            $destSiteForCifs = $shareMigConfig.ShareMigration.DestinationDefaultSiteName
            # Aliases: prefer snapshot, fall back to config DestinationNetbiosAlias
            $aliases = @($exportedPair.NetbiosAliases | Where-Object { $_ })
            if ($aliases.Count -eq 0) {
                $cfgAlias = $shareMigConfig.ShareMigration.DestinationNetbiosAlias
                if ($cfgAlias) { $aliases = @($cfgAlias) }
            }
            if ($PSCmdlet.ShouldProcess("$($destCluster.cluster)/$vserver", "Create CIFS server '$cifsName' in domain $destDomain")) {
                $cifsParams = @{
                    ControllerName      = $destCluster.cluster
                    Vserver             = $vserver
                    CifsServerName      = $cifsName
                    Domain              = $destDomain
                    DomainAdminUser     = $destCredUser
                    DomainAdminPassword = $destDomainPass
                }
                if ($ou)              { $cifsParams['OrganizationalUnit'] = $ou }
                if ($destSiteForCifs) { $cifsParams['DefaultSiteName']    = $destSiteForCifs }
                if ($aliases.Count -gt 0) { $cifsParams['NetbiosAliases'] = $aliases }
                try {
                    Start-ShareMigCifs @cifsParams
                } catch {
                    Write-ShareMigLog "CIFS create FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                    throw
                }
            }
            # SPN registration for NetBIOS aliases
            if ($aliases.Count -gt 0) {
                if ([bool]$shareMigConfig.ShareMigration.AutoRegisterSPN) {
                    Write-ShareMigLog "--- Registering SPNs for NetBIOS aliases (via AD credential) ---" 'INFO'
                    $spnCred = [pscredential]::new($destCredUser, (ConvertTo-SecureString $destDomainPass -AsPlainText -Force))
                    $spnDc = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]
                    $spnResult = Register-ShareMigAliasSpns -CifsServerName $cifsName -Aliases $aliases -Domain $destDomain -DomainController $spnDc -Credential $spnCred
                    if (-not $spnResult.Success) {
                        Write-ShareMigLog "Stopping migration before share import because automatic SPN registration did not complete." 'ERROR'
                        return
                    }
                } else {
                    Write-ShareMigLog "--- ACTION REQUIRED: Register SPNs for NetBIOS aliases ---" 'WARN'
                    foreach ($alias in $aliases) {
                        Write-ShareMigLog "  SETSPN -S HOST/$alias $cifsName" 'WARN'
                        Write-ShareMigLog "  SETSPN -S HOST/$alias.$destDomain $cifsName" 'WARN'
                    }
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
                if ($PSCmdlet.ShouldProcess("$($destCluster.cluster)/$vserver", "Set preferred DC '$destDc' for domain $destDomain")) {
                    try {
                        Set-ShareMigPreferredDc -cluster $destCluster.cluster -Vserver $vserver -Domain $destDomain -DomainControllers @($destDc)
                    } catch {
                        Write-ShareMigLog "Preferred DC set FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                        throw
                    }
                }
            }
        } else {
            Write-ShareMigLog "--- Step 6/7: Preferred DC skipped (DestinationDomainController not configured) ---" 'INFO'
        }

        # --- Step 7/7: Import shares ---
        Write-ShareMigLog "--- Step 7/7: Importing shares ---" 'INFO'
        try {
            Import-ShareMigration -SnapshotFile $SnapshotPath -Config $shareMigConfig -WorkspaceRoot $workspaceRoot -DomainControllerName $resolvedDc -DomainCredential $domainCredential | Out-Null
        } catch {
            Write-ShareMigLog "Import FAILED — $($_.Exception.Message)" 'ERROR'
            throw
        }
        Write-ShareMigLog "=== DOMAIN MIGRATION COMPLETE ===" 'PASS'
        $exported | ConvertTo-Json -Depth 12
    }
    'TestCredentials' {
        # Pure AD authentication test — no CIFS server required
        # Tests: LDAP bind + computer object create/delete permission
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
        $results = @()

        if ($Target -in @('Source', 'Both')) {
            $srcDomain   = $shareMigConfig.ShareMigration.Domain
            $srcDc       = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
            $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
            if ([string]::IsNullOrWhiteSpace($srcCredName)) {
                throw "Source credentials not configured (SourceDomainCredentialName)"
            }
            $srcCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $srcCredName -ConfigOverride $shareMigConfig.ShareMigration.SourceDomainUser
            $srcPass = & $credScript -Name $srcCredName
            Write-ShareMigLog "Testing source domain credentials: $srcCredUser → $srcDomain (DC: $srcDc)" 'INFO'
            $srcResult = Test-DomainCredential -Domain $srcDomain -Username $srcCredUser -Password $srcPass -DomainController $srcDc
            if ($srcResult.Success) {
                Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser → $srcDomain)" 'PASS'
                # Also test computer create/delete permission
                $srcOu_tc = $shareMigConfig.ShareMigration.SourceOrganizationalUnit
                $srcCompTest = Test-DomainComputerPermission -Domain $srcDomain -Username $srcCredUser -Password $srcPass -DomainController $srcDc -OrganizationalUnit $srcOu_tc
                if ($srcCompTest.Success) {
                    Write-ShareMigLog "Source computer permission: PASSED (create+delete in $($srcCompTest.OU))" 'PASS'
                } else {
                    Write-ShareMigLog "Source computer permission: FAILED — $($srcCompTest.Error)" 'ERROR'
                }
                $srcResult | Add-Member -NotePropertyName 'ComputerPermission' -NotePropertyValue $srcCompTest.Success -Force
                $srcResult | Add-Member -NotePropertyName 'OU' -NotePropertyValue $srcCompTest.OU -Force
            } else {
                Write-ShareMigLog "Source domain auth: FAILED — $($srcResult.Error)" 'ERROR'
                $srcResult | Add-Member -NotePropertyName 'ComputerPermission' -NotePropertyValue $false -Force
                $srcResult | Add-Member -NotePropertyName 'OU' -NotePropertyValue '-' -Force
            }
            $results += $srcResult
        }

        if ($Target -in @('Destination', 'Both')) {
            $destDomain   = $shareMigConfig.ShareMigration.DestinationDomain
            $destDc       = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]
            $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
            if ([string]::IsNullOrWhiteSpace($destCredName)) {
                throw "Destination credentials not configured (DestinationDomainCredentialName)"
            }
            $destCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $destCredName -ConfigOverride $shareMigConfig.ShareMigration.DestinationDomainUser
            $destPass = & $credScript -Name $destCredName
            Write-ShareMigLog "Testing destination domain credentials: $destCredUser → $destDomain (DC: $destDc)" 'INFO'
            $destResult = Test-DomainCredential -Domain $destDomain -Username $destCredUser -Password $destPass -DomainController $destDc
            if ($destResult.Success) {
                Write-ShareMigLog "Destination domain auth: PASSED ($destCredUser → $destDomain)" 'PASS'
                # Also test computer create/delete permission
                $destOu_tc = $shareMigConfig.ShareMigration.DestinationOrganizationalUnit
                $destCompTest = Test-DomainComputerPermission -Domain $destDomain -Username $destCredUser -Password $destPass -DomainController $destDc -OrganizationalUnit $destOu_tc
                if ($destCompTest.Success) {
                    Write-ShareMigLog "Destination computer permission: PASSED (create+delete in $($destCompTest.OU))" 'PASS'
                } else {
                    Write-ShareMigLog "Destination computer permission: FAILED — $($destCompTest.Error)" 'ERROR'
                }
                $destResult | Add-Member -NotePropertyName 'ComputerPermission' -NotePropertyValue $destCompTest.Success -Force
                $destResult | Add-Member -NotePropertyName 'OU' -NotePropertyValue $destCompTest.OU -Force
            } else {
                Write-ShareMigLog "Destination domain auth: FAILED — $($destResult.Error)" 'ERROR'
                $destResult | Add-Member -NotePropertyName 'ComputerPermission' -NotePropertyValue $false -Force
                $destResult | Add-Member -NotePropertyName 'OU' -NotePropertyValue '-' -Force
            }
            $results += $destResult
        }

        $results | Format-Table Success, Domain, User, Server, ComputerPermission, OU, Error -AutoSize | Out-String | Write-Host
    }
    'Rollback' {
        # Roll back a failed DomainMigration: restore DNS → recreate CIFS in source domain → re-import shares
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
        $srcDomain   = $shareMigConfig.ShareMigration.Domain
        $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
        $srcCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $srcCredName -ConfigOverride $shareMigConfig.ShareMigration.SourceDomainUser
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

        # --- Pre-flight: Validate domain credentials (LDAP bind + computer create/delete) ---
        Write-ShareMigLog "--- Pre-flight: Testing domain credentials ---" 'INFO'
        $destDomain  = $shareMigConfig.ShareMigration.DestinationDomain
        $destCredName_pf = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
        $destCredUser_pf = $shareMigConfig.ShareMigration.DestinationDomainUser
        $destDomainPass_pf = if ($destCredName_pf) { & $credScript -Name $destCredName_pf } else { $srcDomainPass }
        $deleteUser_pf = if ($destCredUser_pf) { $destCredUser_pf } else { $srcCredUser }

        $srcDc_pf  = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
        $destDc_pf = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]

        # Test destination domain credentials (used to leave current domain in Step 1)
        $destTest = Test-DomainCredential -Domain $destDomain -Username $deleteUser_pf -Password $destDomainPass_pf -DomainController $destDc_pf
        if (-not $destTest.Success) {
            throw "Destination domain credential test FAILED ($deleteUser_pf → $destDomain): $($destTest.Error)`nUpdate credentials with: .\scripts\credentials\New-Credential.ps1 -Name '$destCredName_pf'"
        }
        Write-ShareMigLog "Destination domain auth: PASSED ($deleteUser_pf → $destDomain)" 'PASS'

        # Test source domain credentials (used to join source domain in Step 4)
        $srcTest = Test-DomainCredential -Domain $srcDomain -Username $srcCredUser -Password $srcDomainPass -DomainController $srcDc_pf
        if (-not $srcTest.Success) {
            throw "Source domain credential test FAILED ($srcCredUser → $srcDomain): $($srcTest.Error)`nUpdate credentials with: .\scripts\credentials\New-Credential.ps1 -Name '$srcCredName'"
        }
        Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser → $srcDomain)" 'PASS'

        # Test computer object create/delete permission on source domain (proves join rights)
        $srcOu_pf = $shareMigConfig.ShareMigration.SourceOrganizationalUnit
        $compTest = Test-DomainComputerPermission -Domain $srcDomain -Username $srcCredUser -Password $srcDomainPass -DomainController $srcDc_pf -OrganizationalUnit $srcOu_pf
        if (-not $compTest.Success) {
            throw "Source domain computer-create permission test FAILED ($srcCredUser → $srcDomain, OU: $($compTest.OU)): $($compTest.Error)`nEnsure the account can create/delete computer objects in the target OU."
        }
        Write-ShareMigLog "Source domain computer permission: PASSED (create+delete in $($compTest.OU))" 'PASS'

        Write-ShareMigLog "--- Pre-flight: All credential tests PASSED ---" 'PASS'

        foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
            $cluster = Resolve-ClusterEntry -ClusterName $pair.SourceCluster -ClusterList $global:ONTAP_Clusters
            $vserver = $pair.SourceVserver
            & $cluster.cluster | Out-Null

            # --- Step 1/5: Delete CIFS (leave current domain — DNS still points to current DCs) ---
            $cifsExists = Get-NcCifsServer -VserverContext $vserver -ErrorAction SilentlyContinue
            if ($cifsExists) {
                Write-ShareMigLog "--- Step 1/5: Deleting CIFS on $vserver ($($cifsExists.CifsServer) in $($cifsExists.Domain)) ---" 'INFO'
                # Use destination credentials to leave the current (destination) domain cleanly
                $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
                $destCredUser = $shareMigConfig.ShareMigration.DestinationDomainUser
                $destDomainPass = if ($destCredName) { & $credScript -Name $destCredName } else { $srcDomainPass }
                $deleteUser = if ($destCredUser) { $destCredUser } else { $srcCredUser }
                try {
                    Stop-ShareMigCifs -ControllerName $cluster.cluster -Vserver $vserver -DomainAdminUser $deleteUser -DomainAdminPassword $destDomainPass
                } catch {
                    Write-ShareMigLog "CIFS delete FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                    throw
                }
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
                try {
                    Set-ShareMigDns -cluster $cluster.cluster -Vserver $vserver -NameServers $srcDnsServers -Domains $srcDnsDomains
                } catch {
                    Write-ShareMigLog "DNS restore FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                    throw
                }
            } else {
                Write-ShareMigLog '--- Step 3/5: DNS restore skipped (SourceDnsServers not configured) ---' 'INFO'
            }

            # --- Step 4/5: Create CIFS (join source domain) ---
            Write-ShareMigLog "--- Step 4/5: Creating CIFS on $vserver (joining $srcDomain) ---" 'INFO'
            $snapData = Get-Content $SnapshotPath -Raw | ConvertFrom-Json
            $snapPair = $snapData.Pairs | Where-Object { $_.PairName -eq $pair.Name } | Select-Object -First 1
            $cifsName = if ($snapPair -and $snapPair.CifsServerName) { $snapPair.CifsServerName } else { $vserver }

            # --- Pre-check: Remove stale machine account from destination domain ---
            # If a trust exists between domains, a leftover computer object in the destination
            # domain can cause "constraint violation" when recreating it in the source (sub)domain.
            $destDomain  = $shareMigConfig.ShareMigration.DestinationDomain
            $destDc_rb   = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]
            $destCredName_rb = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
            $destCredUser_rb = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $destCredName_rb -ConfigOverride $shareMigConfig.ShareMigration.DestinationDomainUser
            $destPass_rb = if ($destCredName_rb) { & $credScript -Name $destCredName_rb } else { $srcDomainPass }
            $destSec_rb  = ConvertTo-SecureString $destPass_rb -AsPlainText -Force
            $destCred_rb = [pscredential]::new($destCredUser_rb, $destSec_rb)

            try {
                $staleAccount = Get-ADComputer -Identity $cifsName -Server $destDc_rb -Credential $destCred_rb -ErrorAction Stop
            } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                $staleAccount = $null
            } catch {
                # If we can't even query — log warning but don't block (DC may be unreachable post-DNS change)
                Write-ShareMigLog "Could not query destination domain for stale machine account '$cifsName': $($_.Exception.Message)" 'WARN'
                $staleAccount = $null
            }

            if ($staleAccount) {
                Write-ShareMigLog "Found stale machine account '$cifsName' in destination domain $destDomain — removing to prevent trust conflict" 'WARN'
                try {
                    Remove-ADComputer -Identity $cifsName -Server $destDc_rb -Credential $destCred_rb -Confirm:$false -ErrorAction Stop
                    Write-ShareMigLog "Removed stale machine account '$cifsName' from $destDomain (DC: $destDc_rb)" 'PASS'
                } catch {
                    Write-ShareMigLog "FAILED to remove stale machine account '$cifsName' from $destDomain — $($_.Exception.Message)" 'ERROR'
                    throw "Cannot proceed with rollback: stale machine account '$cifsName' exists in $destDomain and could not be removed. Remove it manually and retry."
                }
            } else {
                Write-ShareMigLog "No stale machine account '$cifsName' in destination domain $destDomain — OK" 'INFO'
            }

            # Aliases: prefer snapshot, fall back to config
            $aliases = @($snapPair.NetbiosAliases | Where-Object { $_ })
            if ($aliases.Count -eq 0) {
                $cfgAlias = $shareMigConfig.ShareMigration.SourceNetbiosAlias
                if ($cfgAlias) { $aliases = @($cfgAlias) }
            }
            $srcOu = $shareMigConfig.ShareMigration.SourceOrganizationalUnit
            $cifsParams = @{
                ControllerName      = $cluster.cluster
                Vserver             = $vserver
                CifsServerName      = $cifsName
                Domain              = $srcDomain
                DomainAdminUser     = $srcCredUser
                DomainAdminPassword = $srcDomainPass
            }
            if ($srcSiteName)        { $cifsParams['DefaultSiteName']      = $srcSiteName }
            if ($srcOu)              { $cifsParams['OrganizationalUnit']   = $srcOu }
            if ($aliases.Count -gt 0) { $cifsParams['NetbiosAliases']      = $aliases }
            try {
                Start-ShareMigCifs @cifsParams
            } catch {
                Write-ShareMigLog "CIFS create FAILED on $vserver — $($_.Exception.Message)" 'ERROR'
                return
            }

            # SPN registration for NetBIOS aliases
            if ($aliases.Count -gt 0) {
                if ([bool]$shareMigConfig.ShareMigration.AutoRegisterSPN) {
                    Write-ShareMigLog "--- Registering SPNs for NetBIOS aliases (via AD credential) ---" 'INFO'
                    $spnCred = [pscredential]::new($srcCredUser, (ConvertTo-SecureString $srcDomainPass -AsPlainText -Force))
                    $spnDc = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
                    $spnResult = Register-ShareMigAliasSpns -CifsServerName $cifsName -Aliases $aliases -Domain $srcDomain -DomainController $spnDc -Credential $spnCred
                    if (-not $spnResult.Success) {
                        Write-ShareMigLog "Stopping rollback before share import because automatic SPN registration did not complete." 'ERROR'
                        return
                    }
                } else {
                    Write-ShareMigLog "--- ACTION REQUIRED: Register SPNs for NetBIOS aliases ---" 'WARN'
                    foreach ($alias in $aliases) {
                        Write-ShareMigLog "  SETSPN -S HOST/$alias $cifsName" 'WARN'
                        Write-ShareMigLog "  SETSPN -S HOST/$alias.$srcDomain $cifsName" 'WARN'
                    }
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

        # --- Pre-flight: Validate domain credentials before attempting reset ---
        Write-ShareMigLog "--- Pre-flight: Testing domain credentials ---" 'INFO'
        if ($Target -in @('Source', 'Both')) {
            $srcCredName_rc = $shareMigConfig.ShareMigration.SourceDomainCredentialName
            $srcCredUser_rc = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $srcCredName_rc -ConfigOverride $shareMigConfig.ShareMigration.SourceDomainUser
            $srcPass_rc     = & $credScript -Name $srcCredName_rc
            $srcDc_rc       = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
            $srcDomain_rc   = $shareMigConfig.ShareMigration.Domain
            $srcTest_rc = Test-DomainCredential -Domain $srcDomain_rc -Username $srcCredUser_rc -Password $srcPass_rc -DomainController $srcDc_rc
            if (-not $srcTest_rc.Success) {
                throw "Source domain credential test FAILED ($srcCredUser_rc → $srcDomain_rc): $($srcTest_rc.Error)`nUpdate credentials with: .\scripts\credentials\New-Credential.ps1 -Name '$srcCredName_rc'"
            }
            Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser_rc → $srcDomain_rc)" 'PASS'
        }
        if ($Target -in @('Destination', 'Both')) {
            $destCredName_rc = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
            $destCredUser_rc = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $destCredName_rc -ConfigOverride $shareMigConfig.ShareMigration.DestinationDomainUser
            $destPass_rc     = & $credScript -Name $destCredName_rc
            $destDc_rc       = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]
            $destDomain_rc   = $shareMigConfig.ShareMigration.DestinationDomain
            $destTest_rc = Test-DomainCredential -Domain $destDomain_rc -Username $destCredUser_rc -Password $destPass_rc -DomainController $destDc_rc
            if (-not $destTest_rc.Success) {
                throw "Destination domain credential test FAILED ($destCredUser_rc → $destDomain_rc): $($destTest_rc.Error)`nUpdate credentials with: .\scripts\credentials\New-Credential.ps1 -Name '$destCredName_rc'"
            }
            Write-ShareMigLog "Destination domain auth: PASSED ($destCredUser_rc → $destDomain_rc)" 'PASS'
        }
        Write-ShareMigLog "--- Pre-flight: All credential tests PASSED ---" 'PASS'

        foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
            if ($Target -in @('Source', 'Both')) {
                $srcCluster  = Resolve-ClusterEntry -ClusterName $pair.SourceCluster -ClusterList $global:ONTAP_Clusters
                $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
                $srcCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $srcCredName -ConfigOverride $shareMigConfig.ShareMigration.SourceDomainUser
                $srcPass     = & $credScript -Name $srcCredName
                & $srcCluster.cluster | Out-Null
                Write-ShareMigLog "Resetting CIFS password: $($pair.SourceVserver) ($($shareMigConfig.ShareMigration.Domain))" 'INFO'
                try {
                    Reset-NcCifsPassword -AdminUsername $srcCredUser -AdminPassword $srcPass -VserverContext $pair.SourceVserver -ErrorAction Stop
                } catch {
                    Write-ShareMigLog "CIFS password reset FAILED: $($pair.SourceVserver) — $($_.Exception.Message)" 'ERROR'
                    throw
                }
                Write-ShareMigLog "CIFS password reset: $($pair.SourceVserver) — PASSED" 'PASS'
            }

            if ($Target -in @('Destination', 'Both')) {
                $destCluster  = Resolve-ClusterEntry -ClusterName $pair.DestinationCluster -ClusterList $global:ONTAP_Clusters
                $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
                $destCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $destCredName -ConfigOverride $shareMigConfig.ShareMigration.DestinationDomainUser
                $destPass     = & $credScript -Name $destCredName
                & $destCluster.cluster | Out-Null
                Write-ShareMigLog "Resetting CIFS password: $($pair.DestinationVserver) ($($shareMigConfig.ShareMigration.DestinationDomain))" 'INFO'
                try {
                    Reset-NcCifsPassword -AdminUsername $destCredUser -AdminPassword $destPass -VserverContext $pair.DestinationVserver -ErrorAction Stop
                } catch {
                    Write-ShareMigLog "CIFS password reset FAILED: $($pair.DestinationVserver) — $($_.Exception.Message)" 'ERROR'
                    throw
                }
                Write-ShareMigLog "CIFS password reset: $($pair.DestinationVserver) — PASSED" 'PASS'
            }
        }
    }
    'SetSPN' {
        # Standalone SPN registration — queries ONTAP for live CIFS name + aliases,
        # reads existing SPNs from AD, and registers missing ones via Set-ADComputer.
        $credScript = Join-Path $workspaceRoot 'scripts\credentials\Get-Credential.ps1'
        Write-ShareMigLog '=== SET SPN ===' 'INFO'

        # --- Helper: register SPNs for one side ---
        function Register-SideSPNs {
            param(
                [string]$Side,          # 'Source' or 'Destination'
                [string]$Domain,
                [string]$DomainController,
                [string]$CredUser,
                [string]$CredPass,
                [string]$ClusterAlias,
                [string]$Vserver,
                [string]$ConfigAlias     # fallback NetBIOS alias from config
            )

            $cluster = Resolve-ClusterEntry -ClusterName $ClusterAlias -ClusterList $global:ONTAP_Clusters
            & $cluster.cluster | Out-Null

            # Query live CIFS server for name + aliases
            $cifsObj = Get-NcCifsServer -VserverContext $Vserver -ErrorAction SilentlyContinue
            if (-not $cifsObj) {
                Write-ShareMigLog "[$Side] No CIFS server on $Vserver — skipping" 'WARN'
                return
            }
            $cifsName = $cifsObj.CifsServer
            $aliases = @($cifsObj.NetbiosAliases | Where-Object { $_ })
            if ($aliases.Count -eq 0 -and $ConfigAlias) {
                $aliases = @($ConfigAlias)
            }
            if ($aliases.Count -eq 0) {
                Write-ShareMigLog "[$Side] CIFS '$cifsName' on $Vserver has no NetBIOS aliases — nothing to register" 'INFO'
                return
            }

            Write-ShareMigLog "[$Side] CIFS server: $cifsName | Domain: $Domain | DC: $DomainController" 'INFO'
            Write-ShareMigLog "[$Side] NetBIOS aliases: $($aliases -join ', ')" 'INFO'

            # Build credential
            $spnCred = [pscredential]::new($CredUser, (ConvertTo-SecureString $CredPass -AsPlainText -Force))
            Register-ShareMigAliasSpns -CifsServerName $cifsName -Aliases $aliases -Domain $Domain -DomainController $DomainController -Credential $spnCred -LogPrefix "[$Side]" | Out-Null
        }

        # --- Source side ---
        if ($Target -in @('Source', 'Both')) {
            $srcDomain   = $shareMigConfig.ShareMigration.Domain
            $srcDc       = @($shareMigConfig.ShareMigration.SourceDomainController)[0]
            $srcCredName = $shareMigConfig.ShareMigration.SourceDomainCredentialName
            if ([string]::IsNullOrWhiteSpace($srcCredName)) {
                throw "SetSPN requires 'SourceDomainCredentialName' in Config_shareMig.json"
            }
            $srcCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $srcCredName -ConfigOverride $shareMigConfig.ShareMigration.SourceDomainUser
            $srcPass     = & $credScript -Name $srcCredName

            # Pre-flight: test credentials
            $srcTest = Test-DomainCredential -Domain $srcDomain -Username $srcCredUser -Password $srcPass -DomainController $srcDc
            if (-not $srcTest.Success) {
                throw "Source domain credential test FAILED ($srcCredUser → $srcDomain): $($srcTest.Error)"
            }
            Write-ShareMigLog "Source domain auth: PASSED ($srcCredUser → $srcDomain)" 'PASS'

            $srcAlias = $shareMigConfig.ShareMigration.SourceNetbiosAlias
            foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
                Write-ShareMigLog "--- Source: $($pair.Name) ($($pair.SourceCluster)/$($pair.SourceVserver)) ---" 'INFO'
                Register-SideSPNs -Side 'Source' -Domain $srcDomain -DomainController $srcDc `
                    -CredUser $srcCredUser -CredPass $srcPass `
                    -ClusterAlias $pair.SourceCluster -Vserver $pair.SourceVserver `
                    -ConfigAlias $srcAlias
            }
        }

        # --- Destination side ---
        if ($Target -in @('Destination', 'Both')) {
            $destDomain   = $shareMigConfig.ShareMigration.DestinationDomain
            $destDc       = @($shareMigConfig.ShareMigration.DestinationDomainController)[0]
            $destCredName = $shareMigConfig.ShareMigration.DestinationDomainCredentialName
            if ([string]::IsNullOrWhiteSpace($destCredName)) {
                throw "SetSPN requires 'DestinationDomainCredentialName' in Config_shareMig.json"
            }
            $destCredUser = Resolve-CredentialUserName -WorkspaceRoot $workspaceRoot -CredentialName $destCredName -ConfigOverride $shareMigConfig.ShareMigration.DestinationDomainUser
            $destPass     = & $credScript -Name $destCredName

            # Pre-flight: test credentials
            $destTest = Test-DomainCredential -Domain $destDomain -Username $destCredUser -Password $destPass -DomainController $destDc
            if (-not $destTest.Success) {
                throw "Destination domain credential test FAILED ($destCredUser → $destDomain): $($destTest.Error)"
            }
            Write-ShareMigLog "Destination domain auth: PASSED ($destCredUser → $destDomain)" 'PASS'

            $destAlias = $shareMigConfig.ShareMigration.DestinationNetbiosAlias
            foreach ($pair in $shareMigConfig.ShareMigration.Pairs) {
                Write-ShareMigLog "--- Destination: $($pair.Name) ($($pair.DestinationCluster)/$($pair.DestinationVserver)) ---" 'INFO'
                Register-SideSPNs -Side 'Destination' -Domain $destDomain -DomainController $destDc `
                    -CredUser $destCredUser -CredPass $destPass `
                    -ClusterAlias $pair.DestinationCluster -Vserver $pair.DestinationVserver `
                    -ConfigAlias $destAlias
            }
        }

        Write-ShareMigLog '=== SET SPN COMPLETE ===' 'PASS'
    }
}