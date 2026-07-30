---
name: share-migration
description: 'Export and import ONTAP SMB share configuration, ACLs, and AD group mappings for SVM domain migration. Use when: share migration, share backup, share restore, export shares, import shares, SMB ACL export, CIFS share backup, domain migration, SVM domain move, AD group promotion, share-migration preflight, Config_shareMig.json.'
argument-hint: 'Specify mode (Export, Import, Preflight, Sync) and cluster/SVM pair'
---

# Share Migration

## When to Use
- Backing up all SMB share definitions and ACLs before a CIFS server domain move
- Restoring shares and ACLs after the SVM is re-joined to a new AD domain
- Promoting individual user ACLs to AD groups during migration
- Running preflight validation (DC connectivity, test group/share creation) before production run
- Syncing (export + import in one pass) for same-SVM backup/restore scenarios

## Key Concepts
- **Export** captures share name, path, comment, share-properties, and per-share ACLs (principal, principal type, permission, group members) to a JSON snapshot + CSV summary
- **Import** reads the JSON snapshot, creates shares on the destination, promotes individual users to AD groups, and applies ACLs
- **BuiltIn principals** (`Everyone`, `BUILTIN\*`, `NT AUTHORITY\*`) are applied as-is without AD lookup
- **Domain prefix stripping**: `DOMAIN\username` → `username` for AD queries
- **DFS** is off by default (`SkipDFS: true`). Optional destination DFS link creation uses `New-NcSymlink` + `Add-NcCifsSymlink` (widelink pattern)

## Configuration

Two config files work together:
- `config.json` → cluster inventory, credentials, SSH helpers (already used by all scripts)
- `Config_shareMig.json` → migration-specific: domain, DC, credential, AD OU, group prefix, pairs

Template: `Config_shareMig.template.json` — copy to `Config_shareMig.json` and edit.

### Config_shareMig.json Key Fields

| Field | Description |
|-------|-------------|
| `Domain` | Source AD domain FQDN (e.g., `SOURCE.DOMAIN.COM`) |
| `DomainController` | Preferred DC hostname; blank = auto-discover |
| `CredentialName` | Name in `credentials/` for domain admin password |
| `SkipDFS` | `true` to disable all DFS operations (default) |
| `CreateDestinationDFSLinks` | `true` to create widelinks on destination |
| `GroupOuPath` | AD OU for new groups (e.g., `CN=Users,DC=SOURCE,DC=DOMAIN,DC=COM`) |
| `GroupNamePrefix` | Prefix for auto-created groups (e.g., `ShareMig`) |
| `Preflight.Cluster` / `Preflight.Vserver` | Target for preflight test objects |
| `Pairs[].SourceCluster` / `DestinationCluster` | Cluster alias or FQDN |
| `Pairs[].SourceVserver` / `DestinationVserver` | SVM names |
| `Pairs[].ShareFilter` | Wildcard filter (e.g., `dept_*` or `*` for all) |

## Usage

```powershell
# Load workspace
. .\profile1.ps1

# 1. Run preflight checks first
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Preflight -ApprovePreflight

# 2. Export all shares + ACLs to JSON snapshot
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Export

# 3. After domain move: import from snapshot
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Import -SnapshotPath .\scripts\share-migration\exports\20260616_120000\share-migration.snapshot.json

# 4. Or do export + import in one pass
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Sync

# Via Script Manager
Start-ScriptManager              # GUI grid view
Start-ScriptManager -Console     # Console numbered menu
sm -Filter "share"               # Pre-filter
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-Mode` | `Export`, `Import`, `Preflight`, or `Sync` |
| `-ShareMigrationConfigPath` | Override Config_shareMig.json path |
| `-SnapshotPath` | Path to JSON snapshot (required for Import) |
| `-DomainCredential` | PSCredential for AD operations (auto-loaded from config if omitted) |
| `-DomainController` | Override DC hostname |
| `-ApprovePreflight` | Required flag to acknowledge preflight creates test objects |
| `-Force` | Skip confirmations |
| `-WhatIf` | Dry-run (SupportsShouldProcess) |

## Workflow Details

### Export Flow
1. Load `config.json` + `Config_shareMig.json`
2. Discover DC, authenticate
3. For each pair: list shares via `vserver cifs share show`, apply ShareFilter
4. For each share: export ACLs, classify principals (Group/User/BuiltIn), record group members
5. Write `share-migration.snapshot.json` + `share-migration.shares.csv`

### Import Flow
1. Read JSON snapshot + config
2. For each pair: resolve destination cluster from `config.json`
3. For each share:
   - **User principals** → create AD group `<Prefix>_<ShareName>_<Permission>`, add users
   - **Group principals** → ensure group exists, add members if recorded
   - **BuiltIn principals** → pass through unchanged
4. Create share on destination if it doesn't exist
5. Apply ACLs via `vserver cifs share access-control create`
6. Optionally create DFS widelinks if `SkipDFS=false` and `CreateDFSLink=true`

### Preflight Checks
1. NetApp credential cache verification
2. DC discovery + authentication
3. Create/find test AD group
4. Create/find test SMB share + apply test ACL

## Dependencies
- `NetApp.ONTAP` PowerShell module
- `ActiveDirectory` PowerShell module (RSAT)
- `Load-Config.ps1` (auto-generates SSH/connect functions)
- Credential files in `credentials/` (per-cluster admin + domain admin)

## File Layout
```
Config_shareMig.template.json          # Tracked template
Config_shareMig.json                   # Gitignored, user's real config
scripts/share-migration/
  Invoke-ShareMigration.ps1            # Main script
  .gitignore                           # Ignores exports/ and logs/
  exports/<timestamp>/                 # JSON + CSV snapshots (gitignored)
  logs/                                # Timestamped log files (gitignored)
```
