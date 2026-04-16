# claude-guardrails — Project Plan

## Goal

Ship a ready-to-use security configuration package for Claude Code. Two variants (lite/full), automated install, clear docs.

## Completed

### v0 — Initial configs (94240f5)
- [x] `lite/settings.json` — 15 deny rules, 3 PreToolUse hooks (destructive deletes, direct push, pipe-to-shell)
- [x] `full/settings.json` — 22 deny rules, 5 PreToolUse hooks (adds exfiltration, permission escalation)
- [x] `full/prompt-injection-defender.sh` — PostToolUse hook scanning for injection patterns
- [x] `lite/CLAUDE-security-section.md` — Security rules for CLAUDE.md (compact)
- [x] `full/CLAUDE-security-section.md` — Security rules for CLAUDE.md (comprehensive)
- [x] `full/SETUP.md` — Detailed setup guide with threat model, layer explanations, team deployment

### v0.1 — README + install script (4009d87)
- [x] `README.md` — Quick start, full vs lite comparison table, how-it-works overview, untrusted repo guidance
- [x] `install.sh` — Automated installer (lite/full), merges settings with deduplication, idempotent, backs up existing config
- [x] Simplified README Quick Start to one-liner, collapsed manual steps into `<details>` block
- [x] Known tradeoffs section in README

### v0.2 — Uninstall script
- [x] `uninstall.sh` — Surgical remove (subtracts only guardrails entries, preserves user's custom config)
- [x] Uninstall section in README documenting the approach

### v0.3 — npx distribution
- [x] `bin/claude-guardrails` — Shell CLI entrypoint (install, uninstall, --help, --version)
- [x] `package.json` — Zero-dependency npm package with bin field
- [x] `LICENSE` — MIT license
- [x] Updated README Quick Start to lead with `npx claude-guardrails install`
- [x] Updated README Uninstall to lead with `npx claude-guardrails uninstall`

### v0.3.1 — scan-secrets UserPromptSubmit hook (both variants)
- [x] `full/scan-secrets.sh` + `lite/scan-secrets.sh` — bash + jq scanner for pasted credentials (AWS, GitHub, Anthropic, OpenAI, Google, Slack, Stripe, 1Password, PEM blocks, BIP39 phrases, 64-hex private keys, `API_KEY=value` assignments). All regex matching runs inside jq's Oniguruma engine — no Python, no Perl, no grep -P.
- [x] Installs to `~/.claude/hooks/scan-secrets/scan-secrets.sh` with `UserPromptSubmit` hook entry (`timeout: 5s`)
- [x] `install.sh` — copies script, merges hook via jq. No new dependency beyond jq (already required).
- [x] `uninstall.sh` — removes hook entry + directory, cleans up empty `~/.claude/hooks/`
- [x] CI tests updated: 7 scenarios now assert UserPromptSubmit count and script presence/removal
- [x] Benchmarks: ~11 ms median per invocation (vs ~22 ms for the earlier Python prototype)
- [x] Docs updated: README (comparison table, 6-layer overview, manual-install steps), `full/SETUP.md` (new Step 3 + Layer 4), `lite/SETUP.md` (new entries), `CLAUDE.md` (architecture section), `docs/maintenance.md` (new quarterly review section)

### v0.3.2 — CI test sandbox hardening (post-incident fix)
- [x] `tests/ci-test.sh` — force `HOME` to a fresh `mktemp -d` at script start; defensive `case` check rejects real-home patterns (`/Users/*`, `/home/*`, `/root`); `trap EXIT` cleans up the temp dir; `CI=true` escape hatch removed
- [x] Verified: all 7 scenarios pass (58/58 assertions) under the new sandbox

## Next Up

### Polish & ship
- [x] Test `install.sh` on clean `~/.claude/` (fresh install path)
- [x] Test `install.sh` idempotency (run twice, verify no duplicates)
- [x] Test `install.sh full` (prompt injection defender + PostToolUse hook)
- [x] Test with pre-existing `settings.json` (merge path)
- [x] Add `.gitignore` entry for `.DS_Store` if not already there
- [ ] Commit install script + README changes
- [ ] Tag v0.1 release

### Future ideas
- [x] `uninstall.sh` — Surgical remove approach (done in v0.2)
- [ ] Version check — Warn if installed config is outdated vs repo
- [x] CI test — GitHub Action that runs install.sh in a container to verify it works
- [x] Homebrew / npx distribution — `npx claude-guardrails install` (done in v0.3)
- [ ] Per-project install mode — Write to `.claude/settings.local.json` instead of global
- [ ] Hook test suite — Automated tests that verify each hook blocks what it should
- [ ] MCP server allowlist template — Starter config for common trusted servers
