# NetApp ONTAP Automation Workspace

Shared always-on instructions for GitHub Copilot in VS Code and Claude Code. Use [SKILL.md](SKILL.md) as the workspace-level, on-demand index and read the matching project skill in [.github/skills/](.github/skills/) before performing a specialized workflow.

## Workspace Model

- This workspace automates NetApp ONTAP through PowerShell and SSH.
- `config.json` is gitignored and is the only source for cluster definitions. Never hardcode cluster names or IP addresses. Use `config.template.json` for the tracked schema.
- The `cluster` property is the connection host; `Alias` is the user-facing target selector. `API_Cred` explicitly names the encrypted credential to load, even when the cluster value is an FQDN.
- `S3_Config.CredentialName` is for the Ansible S3 playbook. It may intentionally differ from, or duplicate, `API_Cred`.
- `Load-Config.ps1` creates cluster connection functions, `<cluster>-ssh` helpers, short aliases, and `Get-<Alias>Csv` helpers from the configuration. Use `$global:ONTAP_Clusters` or `Get-OntapTargetClusters` to select targets.

## PowerShell and Data Access

- Use PowerShell 7 or later. In a fresh shell, run:
  ```powershell
  Set-Location "<workspace-root>"
  . .\profile1.ps1
  ```
  `profile1.ps1` loads `Load-Config.ps1` and the workspace helpers.
- Prefer NetApp.ONTAP `Get-Nc*` cmdlets for structured reads and reporting. Use `Get-<Alias>Csv` or the `<cluster>-ssh` helper when a cmdlet is unavailable or for a quick CLI investigation.
- Use `<cluster>-ssh` or `<cluster>-s` for interactive SSH reads because it returns clean text. Reserve `Invoke-NcSsh` for scripts that need its returned object.
- Use `-fields` with ONTAP CLI queries. CSV helpers already request unlimited rows; do not add row limits.
- Target clusters by configured alias. When a request says only "cluster", ask which alias to use or offer `-VIP`.
- For SnapMirror state, query the destination cluster.

## Credentials and Execution Boundaries

- Credential material is in `credentials/`; `aes.key` and `*.cred` are intentionally excluded from git. Use the credential scripts and registry rather than embedding secrets in scripts or configuration.
- Use WSL for `ansible-playbook` and `ansible-vault`; the native Windows shell is not the Ansible runtime.
- `Start-ScriptManager` (`sm`) is the workspace script launcher. Register new launchable scripts in `scripts/Start-ScriptManager.ps1`.

## Knowledge and Domain Skills

- For an ONTAP error, alert, or symptom, search [KnownIssues/](KnownIssues/) first, then `.github/Netapp Cases/` when no sanitized article matches. Treat a matching case summary as authoritative workspace context.
- Check [PDF/](PDF/) for deeper ONTAP documentation. Use the `pdf-knowledge-import` workflow when incorporating PDF knowledge into a skill.
- Read the matching project skill before acting on DFS, iSCSI, NDMP, networking, quotas, S3, share migration, SnapMirror, snapshots, SVMs, SVM-DR, or volume management.
- Share migration, snapshot comparison, and DFS cleanup have dedicated runbooks and offline tests. Do not replace their scoped instructions with generic procedures.

## Safety Rules

1. Default to read-only discovery. Before any state-changing ONTAP operation, show the plan and exact commands.
2. Never run `vol delete`, `vol offline`, `vserver delete`, `snapmirror break`, or `snapmirror delete` without explicit user confirmation.
3. Verify the configured target cluster before executing a command. Do not modify network configuration until the user reviews the change.
4. For SVM-DR and data-migration work, present the full plan before executing any step.
5. DFS cleanup must follow Preflight, Resolve, Report, human approval, then Delete. Never bypass the stored verdict, approval, or interactive deletion gates, and never invoke Delete unattended.

## Validation and Session Notes

- Run the workflow's focused offline test after modifying its scripts, including `scripts/testing/Test-DFSCleanupScripts.ps1` for DFS cleanup and `scripts/testing/Test-SnapshotComparisonScripts.ps1` for snapshot comparison.
- At the end of a session, record changes, rationale, key decisions, and git state in `.github/session-log-<date>.md`. These local session logs are gitignored.
