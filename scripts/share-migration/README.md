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

## Discovery Mode Logic

The script determines discovery-mode using this priority:

1. **Explicit config** (`SourceDiscoveryMode` / `DestinationDiscoveryMode`) — always wins
2. **Auto-logic** (if config is null):
   - Site name set → `site`
   - DC set but no site → `none`
   - Neither → `all`

Use explicit mode when AD topology doesn't match auto-logic (e.g., subnets moved to another domain's Sites & Services).

## NetBIOS Alias & SPN

When CIFS is created with `-NetbiosAlias`, clients can access the SVM using the alias name. However, Kerberos authentication requires SPNs to be registered manually:

```cmd
SETSPN -a host/<alias> <CifsServerName>
SETSPN -a host/<alias>.<domain> <CifsServerName>
```

The script logs these commands as `ACTION REQUIRED` after CIFS creation.

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
