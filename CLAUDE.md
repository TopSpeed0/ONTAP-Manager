# NetApp ONTAP Automation Workspace — Claude Code

Single source of truth for NetApp ONTAP automation, shared by **GitHub Copilot (VS Code)** and **Claude Code**. The full agent instructions, cluster table, PowerShell helpers, ONTAP conventions, and safety rules live in [.github/copilot-instructions.md](.github/copilot-instructions.md) — **read that file first**, it applies verbatim.

## Workspace source-of-truth tree

Read [SKILL.md](SKILL.md) for the project-owned workspace skill index. It points to this
Claude entry, the existing [.github/copilot-instructions.md](.github/copilot-instructions.md)
instruction blocks, [README.MD](README.MD), [Start-Docs.ps1](Start-Docs.ps1), and the detailed
domain skills under [.github/skills/](.github/skills/). Keep those files layered; do not replace
their scoped blocks with copied versions.

## Claude-specific notes

- **Shell**: PowerShell 7+ (pwsh). Use the Bash tool only when a POSIX command is genuinely needed; most ONTAP work goes through pwsh.
- **Profile**: Every pwsh tool call runs in a fresh non-interactive session that does **not** auto-load `$PROFILE`. Change to the workspace root first, then dot-source `profile1.ps1`:
  ```powershell
  Set-Location "<workspace-root>"; . .\profile1.ps1; <your command>
  ```
  `profile1.ps1` loads `Load-Config.ps1` which auto-generates per-cluster functions (connect, SSH, CSV helpers) from `config.json`. See `config.template.json` for the schema.
- **SSH output**: Prefer the per-cluster SSH helper `<cluster>-ssh` (short alias `<cluster>-s`) for CLI commands - it returns clean raw text. Example: `example-cluster-s "vol show"`. Avoid `Invoke-NcSsh` for interactive/read work: it wraps output in `NcController` / `Value` object noise. Use `Invoke-NcSsh` only when a script needs the returned object.
- **Skills**: Your domain skills live at `~/.claude/skills` — look up the relevant one instead of duplicating instructions. The folders under `.github/skills/<name>/SKILL.md` are project reference docs.
- **Knowledge base**: Search `.github/Netapp Cases/` first when the user reports an ONTAP error or alert. Check `PDF/` for deeper documentation.

## Safety

Never run `vol delete`, `vol offline`, `vserver delete`, `snapmirror break`, or `snapmirror delete` without explicit user confirmation. Always verify the target cluster alias before executing. For SnapMirror state, query the **destination** cluster.
