# claude-guardrails

Hardened security configuration for [Claude Code](https://claude.ai/code) — deny rules, hooks, and prompt injection defense out of the box.

## Why This Exists

Claude Code can read your filesystem, run shell commands, and fetch URLs autonomously. A poisoned file in a cloned repo can hijack its behavior via prompt injection. A careless tool call can leak your SSH keys or `.env` secrets. These configs add defense-in-depth so you don't have to think about it on every session.

## Full vs Lite

| | **Lite** | **Full** |
|---|---|---|
| **Use when** | Internal/trusted projects | Open source repos, untrusted codebases, production credentials |
| Credential deny rules | 21 rules (SSH, AWS, GPG, kube, Azure, .env, .pem, destructive Bash, etc.) | 40 rules (adds secrets dirs, shell profiles, crypto wallets, etc.) |
| PreToolUse hooks | 4 (destructive deletes, direct push, pipe-to-shell, commit-time secret scan) | 6 (adds data exfiltration, permission escalation) |
| UserPromptSubmit inbound secret scanner | Yes (`scan-secrets.sh`) | Yes (`scan-secrets.sh`) |
| PreToolUse commit-time secret scan | Yes (`scan-commit.sh`) | Yes (`scan-commit.sh`) |
| PostToolUse prompt injection scanner | No | Yes (`prompt-injection-defender.sh`) |
| Privacy env flags | Yes (telemetry, error reports, feedback survey off) | Yes |
| CLAUDE.md security rules | Yes | Yes |
| Sandbox guidance | Yes — this is the enforcement layer | Yes + devcontainer pointer |
| **Prereqs** | `jq` | `jq` |

## Quick Start

```bash
# Install jq if you don't have it
brew install jq          # macOS
# sudo apt install jq    # Debian/Ubuntu

# Lite (4 hooks, 21 deny rules — for trusted projects)
npx claude-guardrails install

# Full (6 hooks + prompt injection scanner — for untrusted codebases)
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
3. Copy `patterns/secrets.json` to `~/.claude/hooks/patterns/secrets.json` (shared pattern list for the two scanners below)
4. Copy `scan-secrets.sh` to `~/.claude/hooks/scan-secrets/` and add the `UserPromptSubmit` hook entry to settings
5. Copy `scan-commit.sh` to `~/.claude/hooks/scan-commit/` (its `PreToolUse` hook entry is already in the variant's `settings.json`)
6. (Full only) Copy `prompt-injection-defender.sh` to `~/.claude/hooks/prompt-injection-defender/` and add the `PostToolUse` hook entry to settings

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

Pattern-based hooks and deny rules are defense in depth, not a security boundary. A sufficiently clever prompt injection can rephrase or obfuscate commands around any regex we ship. The layer that actually enforces restrictions against bash is the OS-level sandbox. Enable it every session, then treat everything else as a catch-net for the common, accidental, and obvious cases.

### Sandboxing is the boundary

Run `/sandbox` at session start. Uses Seatbelt on macOS, bubblewrap on Linux. Writes are restricted to the working directory; network access is limited to allowed domains. This is the one layer `bash cat ~/.ssh/id_rsa` cannot escape, which is why our deny rules and hooks are strictly additive on top of it.

For sessions reviewing untrusted code — unknown repos, open-source forks, contractor-submitted branches — step up to a container. Trail of Bits' [claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer) ships a Docker-based setup with optional iptables allowlists. We don't ship one in this repo yet; use theirs.

### The guardrail layers (can be bypassed, still worth having)

Defense-in-depth layers that catch what the sandbox doesn't need to. They do not stop a determined prompt injection:

1. **Permission deny rules** — Block Claude's Read/Edit/Bash tools from touching sensitive paths and running obviously dangerous commands (SSH, AWS, GPG, kubeconfig, Azure, crypto wallets in `full`, plus `sudo`/`mkfs`/`dd`/`rm -rf` as Bash patterns). _Covers Claude's built-in tools; obfuscated bash can slip through._
2. **PreToolUse hooks** — Pattern-match dangerous bash commands before execution (destructive deletes, direct pushes, pipe-to-shell). `full` adds data-exfiltration and permission-escalation patterns. Both variants also ship `scan-commit.sh`, which intercepts `git commit` and runs the staged diff through the same secret regex set used on prompts — catching credentials that Claude writes into code and then tries to commit. _Pattern-based, obfuscation escapes._
3. **UserPromptSubmit secret scanner** — `scan-secrets.sh` (bash + jq) blocks prompts containing live credentials (AWS keys, GitHub / Anthropic / OpenAI tokens, PEM blocks, BIP39 phrases). Prevents pasted secrets from reaching the model or landing in the on-disk session transcript.
4. **PostToolUse prompt injection scanner** (`full` only) — Scans Read/WebFetch/Bash outputs for injection patterns. Warns in-context, doesn't block, so legitimate security content doesn't break.
5. **CLAUDE.md security rules** — Natural-language instructions Claude usually follows (no hardcoded secrets, treat external content as untrusted, etc).
6. **Privacy env flags** — Both variants set `DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`, and `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1`. We deliberately leave `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` unset — that flag also kills auto-updates, which silently strands you on an unpatched version.

No single layer is sufficient. Stack them.

See [`full/SETUP.md`](full/SETUP.md) for detailed explanations of each layer and their limitations.

## Known Tradeoffs

These guardrails trade convenience for safety. Be aware of what you're signing up for:

**False positives will interrupt your workflow.** The glob patterns are intentionally broad. `Read **/*.key` blocks all `.key` files — including legitimate ones like `translation.key` or `config.key`. `Read **/*secret*` (full) blocks files like `secret_santa.py`. `rm -rf` hook triggers on cleaning build directories (`rm -rf dist/`). When this happens, you'll need to run the command manually or temporarily adjust the rule.

**Deny rules only cover Claude's built-in tools, not bash.** `Read ~/.ssh/id_rsa` is denied, but `bash cat ~/.ssh/id_rsa` is not. The hooks catch some bash patterns, but they can't catch everything. This is a fundamental limitation of pattern matching — see the "Sandboxing is the boundary" section above for why `/sandbox` is the layer that actually enforces.

**Hooks add latency to every Bash call.** Each PreToolUse hook spawns a subshell, pipes through `jq`, and runs `grep`. With 4 hooks (lite) that's 4 extra processes per Bash tool call. With 6 hooks + PostToolUse scanner (full), it's 7. The `scan-commit` hook only does its heavy work (`git diff --cached`) when the command actually contains `git commit`, so the cost on non-commit calls is one `jq` invocation + a regex against the command string. Noticeable on slower machines or rapid-fire commands.

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
