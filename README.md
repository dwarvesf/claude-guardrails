# claude-guardrails

Hardened security configuration for [Claude Code](https://claude.ai/code) — deny rules, hooks, and prompt injection defense out of the box.

## Why This Exists

Claude Code can read your filesystem, run shell commands, and fetch URLs autonomously. A poisoned file in a cloned repo can hijack its behavior via prompt injection. A careless tool call can leak your SSH keys or `.env` secrets. These configs add defense-in-depth so you don't have to think about it on every session.

## Full vs Lite

| | **Lite** | **Full** |
|---|---|---|
| **Use when** | Internal/trusted projects | Open source repos, untrusted codebases, production credentials |
| Credential deny rules | 15 rules (SSH, AWS, .env, .pem, etc.) | 28 rules (adds GnuPG, secrets dirs, shell profiles, etc.) |
| PreToolUse hooks | 3 (destructive deletes, direct push, pipe-to-shell) | 5 (adds data exfiltration, permission escalation) |
| PostToolUse prompt injection scanner | No | Yes (`prompt-injection-defender.sh`) |
| CLAUDE.md security rules | Yes | Yes |
| Sandbox guidance | Mentioned | Full walkthrough |
| **Prereqs** | `jq` | `jq` |

## Quick Start

```bash
# Install jq if you don't have it
brew install jq          # macOS
# sudo apt install jq    # Debian/Ubuntu

# Lite (3 hooks, 15 deny rules — for trusted projects)
npx claude-guardrails install

# Full (5 hooks + prompt injection scanner — for untrusted codebases)
npx claude-guardrails install full
```

The script merges into your existing `~/.claude/settings.json` (backing it up first) and is safe to run repeatedly.

<details>
<summary>Install from source (git clone)</summary>

```bash
git clone https://github.com/dwarvesf/claude-guardrails.git
cd claude-guardrails
./install.sh          # lite
./install.sh full     # full
```

</details>

<details>
<summary>Manual installation</summary>

If you prefer to install manually, see [`full/SETUP.md`](full/SETUP.md) for step-by-step instructions. The key steps are:

1. Copy the variant's `settings.json` to `~/.claude/settings.json` (or merge `permissions.deny` and `hooks.PreToolUse` arrays into your existing config)
2. Append the variant's `CLAUDE-security-section.md` to `~/.claude/CLAUDE.md`
3. (Full only) Copy `prompt-injection-defender.sh` to `~/.claude/hooks/prompt-injection-defender/` and add the `PostToolUse` hook entry to settings

</details>

## Uninstall

```bash
# Remove lite guardrails
npx claude-guardrails uninstall

# Remove full guardrails
npx claude-guardrails uninstall full
```

<details>
<summary>Uninstall from source</summary>

```bash
./uninstall.sh          # lite
./uninstall.sh full     # full
```

</details>

The uninstall uses a **surgical remove** approach — it reads the variant's config to identify exactly which deny rules and hooks were added, then subtracts only those entries from your `~/.claude/settings.json`. Your own custom rules, hooks, and other settings are left untouched. It does _not_ restore from a backup, which means it works correctly even if you modified your settings after install.

A pre-uninstall backup is saved to `~/.claude/settings.json.pre-uninstall` in case you need to roll back.

## How It Works

Five layers, each covering gaps the others miss:

1. **Permission deny rules** — Block Claude's Read/Edit tools from touching sensitive paths (SSH keys, .env, credentials). _Limitation: `bash cat` bypasses these._
2. **PreToolUse hooks** — Block dangerous bash commands before execution (destructive deletes, direct pushes, pipe-to-shell). _Limitation: pattern-based, obfuscation can bypass._
3. **OS-level sandbox** (`/sandbox`) — Filesystem and network isolation at the OS level. The only layer bash can't bypass. _Must be enabled per-session._
4. **PostToolUse prompt injection scanner** (full only) — Scans Read/WebFetch/Bash outputs for injection patterns. Warns but doesn't block to avoid false positives.
5. **CLAUDE.md security rules** — Natural language instructions telling Claude to avoid hardcoded secrets, treat external content as untrusted, etc.

No single layer is sufficient. That's the point.

See [`full/SETUP.md`](full/SETUP.md) for detailed explanations of each layer and their limitations.

## Known Tradeoffs

These guardrails trade convenience for safety. Be aware of what you're signing up for:

**False positives will interrupt your workflow.** The glob patterns are intentionally broad. `Read **/*.key` blocks all `.key` files — including legitimate ones like `translation.key` or `config.key`. `Read **/*secret*` (full) blocks files like `secret_santa.py`. `rm -rf` hook triggers on cleaning build directories (`rm -rf dist/`). When this happens, you'll need to run the command manually or temporarily adjust the rule.

**Deny rules only cover Claude's built-in tools, not bash.** `Read ~/.ssh/id_rsa` is denied, but `bash cat ~/.ssh/id_rsa` is not. The hooks catch some bash patterns, but they can't catch everything. This is a fundamental limitation of pattern matching — the OS-level sandbox (`/sandbox`) is the only real enforcement layer.

**Hooks add latency to every Bash call.** Each PreToolUse hook spawns a subshell, pipes through `jq`, and runs `grep`. With 3 hooks (lite) that's 3 extra processes per Bash tool call. With 5 hooks + PostToolUse scanner (full), it's 6. Noticeable on slower machines or rapid-fire commands.

**The prompt injection scanner is noisy.** It pattern-matches strings like "ignore previous instructions" and "system prompt:" — which appear in legitimate security docs, CTF writeups, and this README. Expect warnings when reading security-related content. It warns but doesn't block, so the cost is distraction rather than breakage.

**Full variant overrides some global settings.** `full/settings.json` sets `alwaysThinkingEnabled: true` and `cleanupPeriodDays: 90`. The merge in `install.sh` uses jq's `*` operator, so these will overwrite your existing values for those keys. Review the diff after install if you have custom global settings.

**No easy per-file exceptions.** If you legitimately need Claude to read a `.env.example` or a test `.pem` file, there's no allowlist mechanism. You either remove the deny rule, use bash to read the file, or copy the file to a non-matching path. This is a gap in Claude Code's permission model, not something we can fix here.

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
