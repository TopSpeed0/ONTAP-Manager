---
name: dfs-management
description: 'Manage and resolve ONTAP DFS namespace paths and CIFS widelinks (symlinks). Use when: find DFS path, resolve DFS share, CIFS widelink lookup, find volume for DFS namespace, map \\server\dfs\link to NetApp volume/qtree, Find-DFSPath, Get-DFSNameSpaceRoot, DFS symlink, widelink troubleshooting.'
argument-hint: 'Specify the UNC path to resolve (e.g. \\<cifs-alias>\<dfs-share>\<link>) and the vserver'
---

# ONTAP DFS Namespace & CIFS Widelink Management

## When to Use
- Resolve a DFS UNC path (e.g. `\\<cifs-alias>\<dfs-share>\<link>`) to its underlying NetApp volume and qtree
- Look up CIFS widelink (symlink) configuration on an SVM
- Find which aggregate/node hosts a DFS-linked share
- Troubleshoot DFS namespace path issues

## Key Concepts

### DFS on NetApp: How it works
NetApp implements DFS namespace links as **CIFS widelinks** (Unix-style symlinks on the CIFS layer):
- The DFS namespace root (e.g. `dfs`) is a regular CIFS share pointing to a junction path
- Each DFS link (e.g. `Sales`) is a **CIFS widelink** — configured via `Get-NcCifsSymlink` / `vserver cifs symlinks`
- The widelink's `UnixPath` (e.g. `/Sales/`) maps to a `ShareName` (e.g. `SALES$`) on the target SVM
- That target share points to the actual qtree/volume

### UNC Path Format Supported
```
\\<server>\<dfs-share>\<link>           → resolves widelink directly
\\<server>\<dfs-share>\<link>\<qtree>   → resolves through nested DFS link
\\<server>\<share$>                     → direct $ share lookup
```

### ONTAP CLI equivalents
```
vserver cifs symlinks show -vserver <svm>           # list all widelinks
vserver cifs symlinks show -vserver <svm> -unix-path /<link>/
vserver cifs share show -vserver <svm> -share-name <share>
```

## Configuration

DFS settings are defined in `config.json` under `DFS_Config` (see `config.template.json` for schema):

```json
"DFS_Config": {
  "<cluster-alias>": {
    "Vserver": "<nas-svm-name>",
    "CifsServer": "<cifs-netbios-name>",
    "CifsAlias": "<netbios-alias>",
    "DfsShare": "<dfs-share-name>",
    "DfsPath": "/<dfs-junction-path>",
    "Domain": "<ad-domain>"
  }
}
```

The module path is listed in `config.json` under `Personal_modules` and auto-imported by `Load-Config.ps1`.

## Existing Script

The function is implemented in the `Get-DFSNameSpaceRoot.psm1` module (path loaded from `Personal_modules` in `config.json`).

### Aliases available after `Import-Module`
| Alias | Function |
|-------|----------|
| `Find-DFSPath` | `Get-DFSNameSpaceRoot` |
| `Find-DFSRoot` | `Get-DFSNameSpaceRoot` |
| `Get-DFSPath` | `Get-DFSNameSpaceRoot` |
| `fdfsroot` | `Get-DFSNameSpaceRoot` |

### Usage
```powershell
# Module is auto-imported by Load-Config.ps1, or manually:
Import-Module "<path-from-Personal_modules>/Get-DFSNameSpaceRoot.psm1"

# Resolve a DFS path
Find-DFSPath -share '\\<cifs-alias>\<dfs-share>\<link>' -Vserver <svm-name>

# Output includes:
# Share, Volume, UnixPath, vserver, LINK, QTREE, CifsServer, SharePath, JunctionPath, Aggregate, Node
```

### Output Fields
| Field | Description |
|-------|-------------|
| `Share` | Target CIFS share name (e.g. `SALES$`) |
| `Volume` | NetApp volume hosting the data |
| `UnixPath` | Widelink unix path (e.g. `/Sales/`) |
| `vserver` | SVM owning the volume |
| `LINK` | Full ONTAP path to the DFS link (e.g. `/vol/<dfs-volume>/<link>`) |
| `QTREE` | Qtree name within the volume |
| `CifsServer` | CIFS server name (from `Get-NcCifsServer`) |
| `SharePath` | Full path inside the target share |
| `JunctionPath` | NFS junction path of the volume |
| `Aggregate` | Aggregate hosting the volume |
| `Node` | Cluster node owning the aggregate |

## Key Implementation Notes

### Toolkit version compatibility
`Read-NcDirectory -Path "/vol/<volume>"` (volume root) **fails** with newer NetApp.ONTAP toolkit versions — it requires at least one subdirectory level (`/vol/<vol>/<dir>`). The current implementation bypasses this by going directly to `Get-NcCifsSymlink -UnixPath "/<link>/"`.

### Quota units changed in new toolkit
- **Old `DataONTAP` module**: `Get-NcQuotaReport` returns `DiskLimit`/`DiskUsed` in **KB** — multiply by `1KB` before passing to `DisplayInBytes()`
- **New `NetApp.ONTAP` module**: returns values in **bytes** — pass directly to `DisplayInBytes()`, no multiplication needed
- Current code uses bytes (no `* 1KB`). If quota shows as PB when it should be TB, the toolkit changed units.

### `$` share detection
The regex `'\$'` (escaped) is used to detect hidden shares (ending in `$`). Using `'$'` (unescaped) matches end-of-string and causes every path to be treated as a `$` share — a common bug introduced by AI edits.

### Path splitting in PowerShell 7
```powershell
$share = $share.split('\\').split('\')
# Results in: ["", "server", "dfs-share", "link", "optional-qtree"]
# [0]="" [1]="server" [2]="dfs-share" [3]="link" [4]="optional-qtree"
```

## Procedures

### Resolve a DFS UNC path
```powershell
Import-Module "<path-from-Personal_modules>/Get-DFSNameSpaceRoot.psm1" -Force
Find-DFSPath -share '\\<cifs-alias>\<dfs-share>\<LinkName>' -Vserver <svm-name>
```

### List all widelinks on an SVM (ONTAP CLI)
```powershell
Get-<Prefix>Csv -Command "vserver cifs symlinks show -vserver <svm-name> -fields vserver,unix-path,share-name,share-path"
```

### Look up a specific widelink (PowerShell toolkit)
```powershell
Get-NcCifsSymlink -UnixPath '/<link>/' -VserverContext <svm-name>
```
