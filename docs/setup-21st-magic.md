# Setup: 21st.dev Magic MCP + ui-ux-pro-max Skill (Claude Code)

A reusable runbook for installing the 21st.dev Magic MCP server and the `ui-ux-pro-max` skill on a fresh Windows machine, and wiring them together inside Claude Code.

Hand this whole file to an AI assistant and it will know what to do — and what to ask you for.

---

## What gets installed

1. **21st.dev Magic MCP server** — `@21st-dev/magic` (AI-generated UI components, logo search, refinement)
2. **`ui-ux-pro-max` skill** — from <https://github.com/nextlevelbuilder/ui-ux-pro-max-skill> (UI/UX design intelligence: styles, palettes, fonts, stacks)
3. **The integration** — the skill auto-calls the Magic MCP when building/refining components

## Environment assumptions

- OS: Windows 11, PowerShell 7+
- Claude Code already installed and working
- Node.js + npm available on PATH (for `npx`)
- User home: `C:\Users\<username>\`
- Global Claude config: `C:\Users\<username>\.claude.json`
- Global skills dir: `C:\Users\<username>\.claude\skills\`

---

## 👤 HUMAN STEPS (do these first — AI cannot do them)

These require a browser, an account, or a secret. Complete them before the AI starts.

1. **Get a 21st.dev API key**
   - Go to <https://21st.dev/magic-chat> (the "MCP" section)
   - Sign in (Google/GitHub)
   - Copy the API key shown for the Magic MCP integration
   - Paste it back into chat as: `API_KEY=<paste-here>`
   - ⚠️ Treat as a secret. Do not commit it to git.

2. **Confirm Node.js is installed**
   - Run in pwsh: `node --version` and `npx --version`
   - If missing, install Node 22+ from <https://nodejs.org> first
   - Report the versions back to the AI

3. **Confirm Claude Code is on a recent version**
   - Run: `claude --version`
   - Report the version back

4. **After AI finishes**, restart Claude Code so the new MCP server and skill load:
   - Close all Claude Code windows
   - Reopen — then ask Claude "list your MCP tools" and "list your skills" to verify

---

## 🤖 AI STEPS (do these after the human provides the API key)

Do not skip verification. Do each step in order; stop and ask if a step fails.

### Step 1 — Locate the global Claude config

- Read `C:\Users\<username>\.claude.json`
- Find the `mcpServers` object (create if missing)
- Confirm no existing `magic` key (if present, ask the user whether to overwrite)

### Step 2 — Add the Magic MCP server

Insert this block under `mcpServers` (use the API key the human provided):

```json
"magic": {
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "@21st-dev/magic@latest"],
  "env": {
    "API_KEY": "<HUMAN_PROVIDED_KEY>"
  }
}
```

**Cognyte / corporate-proxy note**: if the user is on a network with TLS interception, `npx` may fail to fetch the package over HTTPS. If that happens, change `command` to the absolute path of `node.exe` and prepend `--use-system-ca`:

```json
"command": "C:\\Program Files\\nodejs\\node.exe",
"args": ["--use-system-ca", "<path-to-npx-cli.js>", "-y", "@21st-dev/magic@latest"]
```

### Step 3 — Install the `ui-ux-pro-max` skill

- Target dir: `C:\Users\<username>\.claude\skills\ui-ux-pro-max\`
- If the directory already exists, ask before overwriting
- Clone the repo:

  ```pwsh
  git clone https://github.com/nextlevelbuilder/ui-ux-pro-max-skill "$env:USERPROFILE\.claude\skills\ui-ux-pro-max"
  ```

- If git clone fails (corporate proxy), fall back to downloading the repo ZIP from GitHub and extracting it to the same path
- Verify the folder contains `SKILL.md`, `data/`, and `scripts/`

### Step 4 — Sanity-check the skill definition

- Read `~/.claude/skills/ui-ux-pro-max/SKILL.md`
- Confirm the frontmatter has `name: ui-ux-pro-max` and a `description` line
- If the skill references a different MCP name than `magic`, note it and adjust (but the standard naming matches)

### Step 5 — Verify JSON is valid

- Re-read `.claude.json` after editing
- Run in pwsh:

  ```pwsh
  Get-Content $env:USERPROFILE\.claude.json -Raw | ConvertFrom-Json | Out-Null
  ```

- If it throws, fix the syntax (most common: trailing comma, unescaped backslash in Windows paths)

### Step 6 — Tell the human what's next

Report back to the human in plain text:

- ✅ MCP `magic` added to `.claude.json`
- ✅ Skill `ui-ux-pro-max` cloned to `~/.claude/skills/ui-ux-pro-max`
- 🔁 Ask them to **restart Claude Code now**
- After restart, suggest they test with: *"build me a glassmorphism login card with shadcn/ui"* — this should trigger the `ui-ux-pro-max` skill, which in turn calls `mcp__magic__21st_magic_component_builder`.

### Step 7 — Post-restart verification (next session)

When the human comes back after restart, verify:

- `mcp__magic__21st_magic_component_builder` appears in the available tools list
- `ui-ux-pro-max` appears in the available skills list
- A simple call to `mcp__magic__logo_search` with query `"github"` returns results (proves the API key works)

If any of those fail, troubleshoot in this order: API key correctness → npx network access → JSON syntax → restart actually happened.

---

## Guardrails

- **Never** commit the API key to git. If a `.mcp.json` is being added to a repo, gitignore it and store the key in `.claude.json` (user-scope) instead.
- **Never** run `npm install -g` for this — `npx -y @21st-dev/magic@latest` keeps it self-updating and avoids polluting global node_modules.
- If the user already has a `magic` MCP entry, **diff before overwriting** and ask.
- Treat the human's "I restarted" as the gate for Step 7 — don't try to invoke the new tools in the same session you edited the config; they only load on Claude Code startup.
