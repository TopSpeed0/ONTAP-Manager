<#
.SYNOPSIS
    Retrieves NetApp cluster credentials from CyberArk Central Credential Provider (CCP).

.DESCRIPTION
    Queries the CyberArk AIM Web Service for the account matching an application ID and
    username, and returns the parsed response (UserName + Content). Nothing is written to
    disk — the secret only ever exists in memory for the life of the caller.

    Canonical copy for the workspace. Consolidated from
    ONTAP\shares\Get-NaApiCred.psm1 (the throwing variant). An older variant under
    ONTAP\shares\Generic\ called `exit` on failure, which kills the whole host session
    rather than letting the caller handle the error — do not reintroduce that behaviour.

.PARAMETER CyberArkAppId
    CyberArk application ID authorised to read the account.

.PARAMETER CyberArkUsername
    The account username to fetch from the vault.

.PARAMETER CCPAddress
    FQDN of the CyberArk CCP / AIM Web Service host.

.PARAMETER netappCluster
    Cluster the credential is intended for. Recorded for traceability; not sent to CyberArk.

.EXAMPLE
    $meta = Get-NaApiCred -CyberArkAppId 'APP-ID' -CyberArkUsername 'SvcAccount' `
                          -CCPAddress 'ccp.domain.local' -netappCluster 'cluster.domain.local'
    $secure = $meta.Content | ConvertTo-SecureString -AsPlainText -Force

.OUTPUTS
    PSCustomObject with UserName and Content (the password) properties.
#>
function Get-NaApiCred {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CyberArkAppId,

        [Parameter(Mandatory = $true)]
        [string]$CyberArkUsername,

        [Parameter(Mandatory = $true)]
        [string]$CCPAddress,

        [Parameter(Mandatory = $true)]
        [string]$netappCluster
    )

    $query = "https://" + $CCPAddress + "/AIMWEBService/api/accounts?appid=" + $CyberArkAppId + "&UserName=" + $CyberArkUsername

    # Fail fast with a clear message when CCP is simply unreachable — otherwise the
    # Invoke-WebRequest failure below reads like an auth problem.
    try {
        $reachable = Test-Connection -TargetName $CCPAddress -TcpPort 443 -Quiet -ErrorAction Stop
    }
    catch {
        throw "Failed to test connectivity to CyberArk CCP at '$CCPAddress' on port 443: $($_.Exception.Message)"
    }

    if (-not $reachable) {
        throw "Connection test to CyberArk CCP at '$CCPAddress' on port 443 failed. Check network connectivity and firewall rules."
    }

    try {
        $response = Invoke-WebRequest -Method Get -Uri $query -UseDefaultCredentials:$true -ErrorAction Stop
        $parsedContent = $response.Content | ConvertFrom-Json

        if (-not $parsedContent.UserName -or -not $parsedContent.Content) {
            throw "CyberArk response for app '$CyberArkAppId' / user '$CyberArkUsername' did not contain a username and password."
        }

        Write-Verbose "Retrieved credential for '$($parsedContent.UserName)' (target cluster: $netappCluster)."
        return $parsedContent
    }
    catch {
        throw "An error occurred while retrieving credentials from CyberArk: $($_.Exception.Message)"
    }
}

function Test-NaRestCredential {
    <#
    .SYNOPSIS
        Prove a credential can actually drive the ONTAP REST API.

    .DESCRIPTION
        A valid password is not enough: ONTAP authorises per `application`, and an account with
        only `ontapi` + `ssh` is rejected by REST with a bare 401 that looks exactly like a wrong
        password. At least one service account in this estate is precisely that, which cost real
        time to diagnose. One GET against /api/cluster settles both questions at once — the password is
        right AND the account carries the `http` application — without needing the elevated
        `security login show` rights that inspecting the entitlement directly would require.

        Returns $true / $false. Never emits the secret.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RestHost,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [switch]$SkipCertificateCheck
    )

    # Header built by hand rather than -Authentication Basic: matches Get-NaRestContext, and
    # PowerShell only sends -Credential pre-emptively for Basic when told to.
    $plain = $Credential.GetNetworkCredential().Password
    $b64 = [Convert]::ToBase64String(
        [System.Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):${plain}"))
    $plain = $null

    $splat = @{
        Method      = 'Get'
        Uri         = "https://$RestHost/api/cluster?fields=name"
        Headers     = @{ Authorization = "Basic $b64"; Accept = 'application/json' }
        ErrorAction = 'Stop'
        TimeoutSec  = 30
    }
    if ($SkipCertificateCheck) { $splat['SkipCertificateCheck'] = $true }

    try {
        $null = Invoke-RestMethod @splat
        return $true
    }
    catch {
        Write-Verbose "REST probe rejected '$($Credential.UserName)': $($_.Exception.Message)"
        return $false
    }
}

function Get-NaCachedCredentialCandidate {
    <#
    .SYNOPSIS
        List the ONTAP PowerShell toolkit's cached credentials that might serve a given cluster.

    .DESCRIPTION
        `Get-NcCredential` reads the toolkit's own store under the caller's profile, encrypted
        with DPAPI to that Windows user — it only decrypts inside their session, and only they
        can read it. Nothing here weakens that; the entries are simply enumerated.

        The catch that makes this function necessary: entries are keyed by whatever host string
        was passed to Connect-NcController, so one cluster can hold several entries naming
        DIFFERENT accounts. Seen in practice: the short alias cached an `http`-capable admin while
        the FQDN cached a service account with no `http`. Keying the lookup on the REST
        hostname therefore finds the one account that cannot do the job. Exact host matches are
        returned first, then any entry sharing the same leading label, deduplicated by username.

    .OUTPUTS
        PSCustomObject with CacheName, Credential and Exact. Empty if the toolkit is unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$HostName
    )

    if (-not (Get-Command -Name Get-NcCredential -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Get-NcCredential is unavailable — import NetApp.ONTAP to use the cache.'
        return @()
    }

    try { $cached = @(Get-NcCredential -ErrorAction Stop) }
    catch {
        Write-Verbose "Reading the toolkit credential cache failed: $($_.Exception.Message)"
        return @()
    }

    $wanted = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $HostName) {
        if ([string]::IsNullOrWhiteSpace($h)) { continue }
        foreach ($form in @($h, $h.Split('.')[0])) {
            if ($wanted -notcontains $form) { $wanted.Add($form) }
        }
    }

    $labels = @($wanted | ForEach-Object { $_.Split('.')[0] } | Select-Object -Unique)
    $seenUser = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $out = [System.Collections.Generic.List[object]]::new()

    # Exact host matches in the order asked for, then same-leading-label entries as a last resort.
    foreach ($pass in @('exact', 'label')) {
        foreach ($entry in $cached) {
            if (-not $entry.Credential -or -not $entry.Credential.UserName) { continue }
            $isExact = $wanted -contains $entry.Name
            if ($pass -eq 'exact' -and -not $isExact) { continue }
            if ($pass -eq 'label') {
                if ($isExact) { continue }
                if ($labels -notcontains $entry.Name.Split('.')[0]) { continue }
            }
            if (-not $seenUser.Add($entry.Credential.UserName)) { continue }
            $out.Add([PSCustomObject]@{
                CacheName  = $entry.Name
                Credential = $entry.Credential
                Exact      = $isExact
            })
        }
    }

    return $out.ToArray()
}

function Resolve-NaCredential {
    <#
    .SYNOPSIS
        Obtain a REST-capable ONTAP credential: CyberArk CCP first, the local toolkit cache second.

    .DESCRIPTION
        CyberArk CCP is the authoritative source — the account is rotated and every fetch is
        audited. It is tried first and always preferred. But when the CCP itself is down
        (`APPEX003E`, seen 2026-07-30) every REST-dependent task stops, including read-only
        assessment that touches nothing.

        The fallback uses credentials ALREADY cached on this machine by the ONTAP toolkit, under
        the caller's own DPAPI key. It grants no access the caller did not already have from a
        PowerShell prompt; it just stops a CCP outage from blocking read-only work. Each candidate
        is proved against REST before being handed back, so a cached account without the `http`
        application is skipped rather than returned to fail later.

        -Source Auto is deliberately NOT "whatever works" for destructive callers. Falling back
        changes the identity in the cluster's audit log (a local account instead of the CyberArk
        service account),
        so a caller doing deletions must pass -AllowFallbackForWrite to accept that consciously.

    .PARAMETER Source
        Auto      CCP, then the cache (read-only callers).
        CyberArk  CCP only — fail if it is down.
        Cache     Local cache only — skip CCP entirely.

    .PARAMETER AllowFallbackForWrite
        Permit the cache fallback even though the caller intends to modify or delete. Records the
        identity swap in the returned object so it can be logged.

    .OUTPUTS
        PSCustomObject: Credential, UserName, SecurePassword, Source ('CyberArk'|'ToolkitCache'),
        CacheName, IdentitySwapped, Attempts (audit trail, no secrets).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RestHost,
        [string]$ClusterAlias,
        [ValidateSet('Auto', 'CyberArk', 'Cache')][string]$Source = 'Auto',
        [string]$CCPAddress,
        [string]$CyberArkAppId,
        [string]$CyberArkUsername,
        [switch]$IsWriteOperation,
        [switch]$AllowFallbackForWrite,
        [switch]$SkipCertificateCheck
    )

    $attempts = [System.Collections.Generic.List[object]]::new()
    $haveCCPConfig = -not ([string]::IsNullOrWhiteSpace($CCPAddress) -or
                           [string]::IsNullOrWhiteSpace($CyberArkAppId) -or
                           [string]::IsNullOrWhiteSpace($CyberArkUsername))

    # ---- 1. CyberArk CCP (authoritative) ----
    if ($Source -in @('Auto', 'CyberArk')) {
        if (-not $haveCCPConfig) {
            $attempts.Add([PSCustomObject]@{ Source = 'CyberArk'; Result = 'Skipped — CCPAddress/AppId/UserName not configured.' })
            if ($Source -eq 'CyberArk') { throw 'Source=CyberArk was requested but the CCP settings are incomplete.' }
        }
        else {
            try {
                $meta = Get-NaApiCred -CyberArkAppId $CyberArkAppId -CyberArkUsername $CyberArkUsername `
                                      -CCPAddress $CCPAddress -netappCluster $RestHost
                $secure = $meta.Content | ConvertTo-SecureString -AsPlainText -Force
                $attempts.Add([PSCustomObject]@{ Source = 'CyberArk'; Result = "OK — retrieved '$($meta.UserName)'." })
                return [PSCustomObject]@{
                    Credential      = [PSCredential]::new($meta.UserName, $secure)
                    UserName        = $meta.UserName
                    SecurePassword  = $secure
                    Source          = 'CyberArk'
                    CacheName       = $null
                    IdentitySwapped = $false
                    Attempts        = $attempts.ToArray()
                }
            }
            catch {
                $attempts.Add([PSCustomObject]@{ Source = 'CyberArk'; Result = "FAILED — $($_.Exception.Message)" })
                if ($Source -eq 'CyberArk') { throw }
            }
        }
    }

    # ---- 2. Local toolkit cache (opportunistic) ----
    if ($IsWriteOperation -and -not $AllowFallbackForWrite) {
        $attempts.Add([PSCustomObject]@{ Source = 'ToolkitCache'; Result = 'Refused — write operation without -AllowFallbackForWrite.' })
        throw ("CyberArk CCP is unavailable and this is a write operation. A cached credential " +
               "would change the identity recorded in the cluster audit log. Re-run with " +
               "-AllowFallbackForWrite to accept that, or wait for the CCP to recover. " +
               "Attempts: " + (($attempts | ForEach-Object { "$($_.Source): $($_.Result)" }) -join ' | '))
    }

    $candidates = @(Get-NaCachedCredentialCandidate -HostName @($RestHost, $ClusterAlias))
    if ($candidates.Count -eq 0) {
        $attempts.Add([PSCustomObject]@{ Source = 'ToolkitCache'; Result = 'No cached credential matches this cluster.' })
    }

    foreach ($c in $candidates) {
        if (Test-NaRestCredential -RestHost $RestHost -Credential $c.Credential -SkipCertificateCheck:$SkipCertificateCheck) {
            $attempts.Add([PSCustomObject]@{
                Source = 'ToolkitCache'
                Result = "OK — '$($c.Credential.UserName)' (cache entry '$($c.CacheName)') answered the REST probe."
            })
            return [PSCustomObject]@{
                Credential      = $c.Credential
                UserName        = $c.Credential.UserName
                SecurePassword  = $c.Credential.Password
                Source          = 'ToolkitCache'
                CacheName       = $c.CacheName
                IdentitySwapped = $true
                Attempts        = $attempts.ToArray()
            }
        }
        $attempts.Add([PSCustomObject]@{
            Source = 'ToolkitCache'
            Result = "Rejected — '$($c.Credential.UserName)' (cache entry '$($c.CacheName)') failed the REST probe; wrong password, or no 'http' application on the account."
        })
    }

    throw ("No REST-capable credential could be resolved for '$RestHost'. Attempts: " +
           (($attempts | ForEach-Object { "$($_.Source): $($_.Result)" }) -join ' | '))
}

Export-ModuleMember -Function Get-NaApiCred, Test-NaRestCredential,
                              Get-NaCachedCredentialCandidate, Resolve-NaCredential
