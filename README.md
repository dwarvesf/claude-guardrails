# claude-guardrails

Hardened security configuration for [Claude Code](https://claude.ai/code) — deny rules, hooks, and prompt injection defense out of the box.

## Why This Exists

Claude Code can read your filesystem, run shell commands, and fetch URLs autonomously. A poisoned file in a cloned repo can hijack its behavior via prompt injection. A careless tool call can leak your SSH keys or `.env` secrets. These configs add defense-in-depth so you don't have to think about it on every session.

## Full vs Lite

| | **Lite** | **Full** |
|---|---|---|
| **Use when** | Internal/trusted projects | Open source repos, untrusted codebases, production credentials |
| Credential deny rules | 15 rules (SSH, AWS, .env, .pem, etc.) | 22 rules (adds GnuPG, secrets dirs, shell profiles, etc.) |
| PreToolUse hooks | 3 (destructive deletes, direct push, pipe-to-shell) | 5 (adds data exfiltration, permission escalation) |
| PostToolUse prompt injection scanner | No | Yes (`prompt-injection-defender.sh`) |
| CLAUDE.md security rules | Yes | Yes |
| Sandbox guidance | Mentioned | Full walkthrough |
| **Prereqs** | `jq` | `jq` |

## Quick Start (Lite)

```bash
# 1. Install jq if you don't have it
brew install jq          # macOS
# sudo apt install jq    # Debian/Ubuntu

# 2. Copy settings (or merge if you have existing config)
mkdir -p ~/.claude
cp lite/settings.json ~/.claude/settings.json

# 3. Paste lite/CLAUDE-security-section.md into ~/.claude/CLAUDE.md

# 4. Verify — start a new Claude Code session and try:
#    cat ~/.ssh/id_rsa   → denied
#    rm -rf /            → blocked by hook
#    git push origin main → blocked by hook
```

For the full variant (with prompt injection defender and all 5 hooks), see [`full/SETUP.md`](full/SETUP.md).

> **Existing config?** Don't overwrite — merge the `permissions.deny` and `hooks.PreToolUse` entries into your existing `~/.claude/settings.json` manually.

## How It Works

Five layers, each covering gaps the others miss:

1. **Permission deny rules** — Block Claude's Read/Edit tools from touching sensitive paths (SSH keys, .env, credentials). _Limitation: `bash cat` bypasses these._
2. **PreToolUse hooks** — Block dangerous bash commands before execution (destructive deletes, direct pushes, pipe-to-shell). _Limitation: pattern-based, obfuscation can bypass._
3. **OS-level sandbox** (`/sandbox`) — Filesystem and network isolation at the OS level. The only layer bash can't bypass. _Must be enabled per-session._
4. **PostToolUse prompt injection scanner** (full only) — Scans Read/WebFetch/Bash outputs for injection patterns. Warns but doesn't block to avoid false positives.
5. **CLAUDE.md security rules** — Natural language instructions telling Claude to avoid hardcoded secrets, treat external content as untrusted, etc.

No single layer is sufficient. That's the point.

See [`full/SETUP.md`](full/SETUP.md) for detailed explanations of each layer and their limitations.

## Untrusted Repos

Before opening any cloned repo with Claude Code, check for hidden config:

```bash
find . -path "*/.claude/*" -o -name ".mcp.json" -o -name "CLAUDE.md" | head -20
```

A malicious repo can ship `.claude/hooks/` with arbitrary shell scripts, `.mcp.json` with exfil-capable MCP servers, or `CLAUDE.md` with prompt injection. Inspect before you trust.

## References

- [Trail of Bits — claude-code-config](https://github.com/trailofbits/claude-code-config)
- [Trail of Bits — claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)
- [Lasso Security — Claude hooks prompt injection defender](https://github.com/lasso-security/claude-hooks)
- [Anthropic — Claude Code security docs](https://code.claude.com/docs/en/security)
- [Anthropic — Hooks reference](https://code.claude.com/docs/en/hooks)
- [Snyk — ToxicSkills study](https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/)
- [Check Point Research — CVE-2025-59536](https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/)

---

Maintained by [Dwarves Foundation](https://dwarves.foundation).
