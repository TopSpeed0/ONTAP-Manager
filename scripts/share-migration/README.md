# Share Migration — Domain Migration Tool

Automates SMB share export/import and CIFS domain migration for NetApp ONTAP SVMs.

## Modes

| Mode | Description |
|------|-------------|
| `Export` | Export all SMB shares + ACLs to JSON snapshot |
| `Import` | Import shares + ACLs from snapshot |
| `Sync` | Export + Import in one pass (idempotent) |
| `DomainMigration` | Full domain move: Export → Delete CIFS → DNS → PDC → Create CIFS → Import |
| `Rollback` | Reverse a failed migration: Delete CIFS → PDC → DNS → Create CIFS → Import |
| `TestCredentials` | Validate domain admin credentials via LDAP |
| `ResetCifsPassword` | Reset CIFS machine account password |

## Usage

```powershell
# Via Script Manager (GUI)
Start-ScriptManager

# Direct invocation
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode DomainMigration
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Rollback
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Rollback -SnapshotPath <path>
```

## Configuration

- **`Config_shareMig.json`** — Live config (gitignored)
- **`Config_shareMig.template.json`** — Template with documentation comments

Key fields:

| Field | Purpose |
|-------|---------|
| `SourceDomainController` | Array of DC IPs for preferred-DC setup (must be IPs, not FQDNs) |
| `SourceDefaultSiteName` | AD site name for CIFS `-DefaultSite` parameter |
| `SourceDiscoveryMode` | Explicit override: `all`, `site`, or `none` (null = auto) |
| `SourceOrganizationalUnit` | OU for computer account (e.g. `CN=Computers`) |
| `SourceNetbiosAlias` | NetBIOS alias registered during CIFS create |
| `DestinationDiscoveryMode` | Same as above, for destination domain |
| `AutoRegisterSPN` | When true, registers missing alias HOST SPNs after a successful CIFS join using the configured domain credential; conflicts stop before share import. |

## Iron Rules — CIFS Domain Migration Order

These rules are **non-negotiable**. Violating the order causes RPC timeouts, stale AD objects, or domain join failures.

### DomainMigration (Source → Destination)

```
1. EXPORT shares (backup before any destructive action)
2. DELETE CIFS while DNS still points to CURRENT domain
   ├─ ONTAP needs the current domain's DCs to cleanly leave AD
   └─ If DNS is changed first → RPC timeout → dirty leave → stale computer object
3. CHANGE DNS to destination domain servers
4. SET preferred DC + discovery-mode for destination domain
   ├─ Clear source domain's preferred DCs
   └─ Set discovery-mode BEFORE creating CIFS (affects DC discovery during join)
5. CREATE CIFS in destination domain
   ├─ Uses -DefaultSite, -NetbiosAlias, -OrganizationalUnit, -Force
   └─ Must happen AFTER DNS + PDC are configured for the new domain
6. CONFIRM preferred DC (post-join verification)
7. IMPORT shares from snapshot
```

### Rollback (Destination → Source)

```
1. DELETE CIFS while DNS still points to CURRENT (destination) domain
   ├─ Use DESTINATION credentials (that's the domain we're leaving)
   └─ Same rule: delete BEFORE changing DNS
2. SET preferred DC + discovery-mode for source domain
   ├─ Clear destination domain's preferred DCs
   ├─ Add source domain DCs (full array)
   └─ Set discovery-mode (may differ from auto-logic — use explicit config)
3. RESTORE DNS to source domain servers
4. CREATE CIFS in source domain
   ├─ Uses source site, OU, aliases from config
   └─ If stale AD computer object exists → Remove-ADComputer first
5. IMPORT shares from snapshot
```

## NetBIOS Alias and SPN Registration

When a CIFS server uses a NetBIOS alias, Kerberos requires matching HOST SPNs.
Set `AutoRegisterSPN` to `true` to register them automatically after a successful
CIFS join. The script uses the configured domain credential, checks each SPN's
current owner before writing, and stops before share import if it finds a conflict
or cannot register an SPN.

With `AutoRegisterSPN` set to `false`, the script logs manual commands using
duplicate-safe `SETSPN -S` syntax instead.

### Why This Order?

| Wrong Order | Failure Mode |
|-------------|-------------|
| DNS change → then CIFS delete | RPC timeout — ONTAP can't reach old DCs to leave domain cleanly |
| CIFS create → then set PDC/discovery-mode | Join may use wrong DC, wrong site, or fail entirely |
| Skip export → migrate | No rollback possible if something fails |
| Use FQDN in preferred DC | `Add-NcCifsPreferredDomainController` rejects hostnames — IP only |

### Stale AD Computer Objects

If a previous attempt left a stale computer object in AD:

```powershell
# Check if stale object exists
Get-ADComputer -Identity "<CifsServerName>" -Server "<DC>" -Credential $cred

# Remove it (required before re-joining)
Remove-ADComputer -Identity "<CifsServerName>" -Server "<DC>" -Credential $cred -Confirm:$false
```

The script does NOT auto-remove stale AD objects — this requires explicit action.

## LDAP Signing Requirement (ADV190023)

Microsoft Security Advisory [ADV190023](https://portal.msrc.microsoft.com/en-us/security-guidance/advisory/ADV190023) changed the default for Active Directory Domain Controllers to **require LDAP signing**. When DCs enforce this, ONTAP's `Add-NcCifsServer` (domain join) fails with:

```
LDAP Error: The user has insufficient access rights
LDAP constraint violation occurred, which may indicate the supplied user
has insufficient privilege to add an account in the specified organizational unit
```

This error is misleading — it is **not** a permissions problem. The real cause is that ONTAP is sending unsigned LDAP requests.

### How the Script Handles It

`Start-ShareMigCifs` automatically checks `session-security-for-ad-ldap` on the vserver before joining. If set to `none`, it auto-upgrades to `sign`. This is backward-compatible — DCs that don't require signing still accept signed connections.

### Manual Fix (if needed)

```
# Check current setting
::*> cifs security show -vserver <vserver> -fields session-security-for-ad-ldap

# Set to sign
::*> cifs security modify -vserver <vserver> -session-security-for-ad-ldap sign

# Or via PowerShell ZAPI
Set-NcCifsSecurity -VserverContext <vserver> -SessionSecurityForAdLdap 'sign'
```

### References

- [LDAP Error: Strong authentication required (troubleshooting)](https://kb.netapp.com/on-prem/ontap/da/NAS/NAS-KBs/LDAP_Error__Strong_authentication_is_required_due_to_new_Signing_and_Sealing_Requirements)
- [How to set ONTAP to use LDAP Signing or Sealing for CIFS/NFS](https://kb.netapp.com/on-prem/ontap/da/NAS/NAS-KBs/How_to_set_ONTAP_to_use_LDAP_Signing_or_Sealing_for_CIFS_NFS)
- [LDAP signing and sealing concepts (NetApp docs)](https://docs.netapp.com/us-en/ontap/smb-admin/ldap-signing-sealing-concepts-concept.html)
- [Microsoft ADV190023 — LDAP Channel Binding and Signing](https://portal.msrc.microsoft.com/en-us/security-guidance/advisory/ADV190023)

### Error Signatures

When DCs enforce LDAP signing and ONTAP `session-security-for-ad-ldap` is `none`, you may see:

| Error Message | Context |
|---------------|---------|
| `LDAP Error: Strong authentication is required` | `cifs setup` / `Add-NcCifsServer` |
| `Strong(er) authentication required` | LDAP connection during domain join |
| `LDAP constraint violation ... insufficient privilege to add an account` | Misleading — looks like permissions, actually unsigned LDAP |
| `Unable to connect to <DC> through the <IP> interface` | DC rejects the unsigned LDAP bind |

### Alternative Solutions (if `sign` doesn't work)

1. **LDAPS** (ONTAP 9.5+): `cifs security modify -vserver <vserver> -use-ldaps-for-ad-ldap true`
2. **LDAP over TLS (StartTLS)**: `cifs security modify -vserver <vserver> -use-start-tls-for-ad-ldap true`
3. **Seal** (encrypts + signs): `cifs security modify -vserver <vserver> -session-security-for-ad-ldap seal`
4. **Disable DC requirement** (not recommended): Disable LDAP signing requirement in Domain GPO or DC registry

## Discovery Mode Logic

The script determines discovery-mode using this priority:

1. **Explicit config** (`SourceDiscoveryMode` / `DestinationDiscoveryMode`) — always wins
2. **Auto-logic** (if config is null):
   - Site name set → `site`
   - DC set but no site → `none`
   - Neither → `all`

Use explicit mode when AD topology doesn't match auto-logic (e.g., subnets moved to another domain's Sites & Services).

## Files

```
scripts/share-migration/
├── Invoke-ShareMigration.ps1    # Main script (all modes)
├── README.md                    # This file
├── exports/                     # JSON snapshots (gitignored)
└── logs/                        # Execution logs (gitignored)
Config_shareMig.json             # Live config (workspace root, gitignored)
Config_shareMig.template.json    # Template with comments
```
