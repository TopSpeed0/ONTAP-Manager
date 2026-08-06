<#
.SYNOPSIS
    Offline regression tests for duplicate-safe Share Migration SPN registration.

.DESCRIPTION
    Extracts Register-ShareMigAliasSpns from Invoke-ShareMigration.ps1 and runs
    it against mocked Active Directory cmdlets. No ONTAP or AD connection occurs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\share-migration\Invoke-ShareMigration.ps1'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
}

$helper = @($ast.FindAll({
    param($node)
    $node.GetType().Name -eq 'FunctionDefinitionAst' -and $node.Name -eq 'Register-ShareMigAliasSpns'
}, $true))[0]
if (-not $helper) {
    throw 'Register-ShareMigAliasSpns was not found in Invoke-ShareMigration.ps1.'
}

. ([scriptblock]::Create($helper.Extent.Text))

$pass = 0
$fail = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        $result = & $Body
        if ($result -eq $true) {
            Write-Host "  PASS  $Name" -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host "  FAIL  $Name -> $result" -ForegroundColor Red
            $script:fail++
        }
    } catch {
        Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

function Reset-AdMocks {
    $script:loggedMessages = [System.Collections.Generic.List[string]]::new()
    $script:registeredSpns = [System.Collections.Generic.List[string]]::new()
    $script:spnOwners = @{}
    $script:targetComputer = [pscustomobject]@{
        DistinguishedName = 'CN=SY-SMB-TS1,CN=Computers,DC=SYB,DC=COGNYTE,DC=LOCAL'
        servicePrincipalName = @()
    }
}

function Write-ShareMigLog {
    param([string]$Message, [string]$Level)
    $script:loggedMessages.Add("[$Level] $Message")
}

function Get-ADComputer {
    param($Identity, $Server, $Credential, $Properties)
    return $script:targetComputer
}

function Get-ADObject {
    param($LDAPFilter, $Server, $Credential, $Properties)
    if ($LDAPFilter -notmatch '^\(servicePrincipalName=(.+)\)$') {
        throw "Unexpected LDAP filter: $LDAPFilter"
    }
    $spn = $Matches[1]
    if ($script:spnOwners.ContainsKey($spn)) {
        return @($script:spnOwners[$spn])
    }
    return @()
}

function Set-ADComputer {
    param($Identity, $Add, $Server, $Credential)
    $spn = [string]$Add.servicePrincipalName
    $script:registeredSpns.Add($spn)
    $script:targetComputer.servicePrincipalName = @($script:targetComputer.servicePrincipalName) + $spn
}

$testCredential = [pscredential]::new('test@example.invalid', (ConvertTo-SecureString 'unused' -AsPlainText -Force))
$expectedSpns = @('HOST/SYBTST1', 'HOST/SYBTST1.SYB.COGNYTE.LOCAL')

Write-Host "`n=== Share Migration SPN Registration ===" -ForegroundColor Cyan

Test-Case 'missing alias SPNs are registered with the configured AD credential' {
    Reset-AdMocks
    $result = Register-ShareMigAliasSpns -CifsServerName 'SY-SMB-TS1' -Aliases 'SYBTST1' -Domain 'SYB.COGNYTE.LOCAL' -DomainController '192.0.2.10' -Credential $testCredential
    if (-not $result.Success -or $result.Registered -ne 2) { return "unexpected result: $($result | ConvertTo-Json -Compress)" }
    if ((@($script:registeredSpns | Sort-Object) -join ',') -ne ($expectedSpns -join ',')) { return "registered: $($script:registeredSpns -join ', ')" }
    return $true
}

Test-Case 'SPNs already owned by the target computer are not added again' {
    Reset-AdMocks
    $script:targetComputer.servicePrincipalName = $expectedSpns
    $result = Register-ShareMigAliasSpns -CifsServerName 'SY-SMB-TS1' -Aliases 'SYBTST1' -Domain 'SYB.COGNYTE.LOCAL' -DomainController '192.0.2.10' -Credential $testCredential
    if (-not $result.Success -or $result.AlreadyPresent -ne 2 -or $result.Registered -ne 0) { return "unexpected result: $($result | ConvertTo-Json -Compress)" }
    if ($script:registeredSpns.Count -ne 0) { return "unexpected additions: $($script:registeredSpns -join ', ')" }
    return $true
}

Test-Case 'a conflicting alias SPN stops all new registrations' {
    Reset-AdMocks
    $script:spnOwners['HOST/SYBTST1'] = [pscustomobject]@{ DistinguishedName = 'CN=OtherServer,CN=Computers,DC=SYB,DC=COGNYTE,DC=LOCAL' }
    $result = Register-ShareMigAliasSpns -CifsServerName 'SY-SMB-TS1' -Aliases 'SYBTST1' -Domain 'SYB.COGNYTE.LOCAL' -DomainController '192.0.2.10' -Credential $testCredential
    if ($result.Success -or $result.Conflicts -ne 1) { return "unexpected result: $($result | ConvertTo-Json -Compress)" }
    if ($script:registeredSpns.Count -ne 0) { return "partial additions: $($script:registeredSpns -join ', ')" }
    if (-not ($script:loggedMessages -match 'SPN conflict: HOST/SYBTST1')) { return 'conflict was not logged' }
    return $true
}

Write-Host "`nTotal: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }