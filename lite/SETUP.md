# Claude Code Security Config (Lite) - Dwarves Foundation

Minimal security config for daily dev work. Three layers, near-zero friction.

## What's In Here

- `settings.json` - Credential deny rules + 3 hooks
- `CLAUDE-security-section.md` - Security rules to paste into your CLAUDE.md

## What It Blocks

**Deny rules (Read/Edit tools only):**
- SSH keys, AWS creds, GCP config, Docker config
- .env files (read and edit)
- .pem and .key files
- npm/pip/git credentials
- Claude's own settings

**Hooks (Bash commands):**
- `rm -rf /` and similar destructive deletes
- `git push origin main/master/production` (use feature branches)
- `curl ... | bash` pipe-to-shell patterns

**That's it.** No prompt injection scanner, no exfiltration detector, no PostToolUse hooks. Those add noise for internal projects where you trust the codebase.

## Install

### 1. Prereq: make sure jq is installed

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq
```

### 2. Install settings.json

**If you don't have one yet:**
```bash
mkdir -p ~/.claude
cp settings.json ~/.claude/settings.json
```

**If you already have one, merge manually:**
- Add the `permissions.deny` entries to your existing deny list
- Add the `hooks.PreToolUse` entries to your existing hooks
- Make sure `enableAllProjectMcpServers` is `false`

### 3. Add security section to CLAUDE.md

Open `~/.claude/CLAUDE.md` and paste the contents of `CLAUDE-security-section.md` as a new section.

### 4. Verify

Start a new Claude Code session. Ask Claude to try:
- `cat ~/.ssh/id_rsa` -> should be denied
- `cat .env` -> should be denied
- `rm -rf /tmp/test` -> should be blocked by hook
- `git push origin main` -> should be blocked by hook

## When To Upgrade to Full Config

Use the full security config (with prompt injection defender, exfiltration hooks, and sandbox) when:
- Working on open source repos from unknown contributors
- Cloning repos you haven't audited
- Running Claude Code with `--dangerously-skip-permissions`
- Handling production credentials or customer data

For internal Dwarves projects, this lite version is enough.

## When Working on Untrusted Repos

Even with lite config, do this before opening unknown repos:

```bash
# Check for Claude Code config files that could be malicious
find . -path "*/.claude/*" -o -name ".mcp.json" | head -20

# If you find hooks or MCP configs you didn't put there, delete them
```

And enable sandbox for that session:
```
/sandbox
```

## References

- Trail of Bits claude-code-config: https://github.com/trailofbits/claude-code-config
- Anthropic security docs: https://code.claude.com/docs/en/security
