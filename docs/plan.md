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

### v0.1 — README + install script (9f8143f + uncommitted)
- [x] `README.md` — Quick start, full vs lite comparison table, how-it-works overview, untrusted repo guidance
- [x] `install.sh` — Automated installer (lite/full), merges settings with deduplication, idempotent, backs up existing config
- [x] Simplified README Quick Start to one-liner, collapsed manual steps into `<details>` block

## Next Up

### Polish & ship
- [ ] Test `install.sh` on clean `~/.claude/` (fresh install path)
- [ ] Test `install.sh` idempotency (run twice, verify no duplicates)
- [ ] Test `install.sh full` (prompt injection defender + PostToolUse hook)
- [ ] Test with pre-existing `settings.json` (merge path)
- [ ] Add `.gitignore` entry for `.DS_Store` if not already there
- [ ] Commit install script + README changes
- [ ] Tag v0.1 release

### Future ideas
- [ ] `uninstall.sh` — Remove guardrails cleanly (restore backup)
- [ ] Version check — Warn if installed config is outdated vs repo
- [ ] CI test — GitHub Action that runs install.sh in a container to verify it works
- [ ] Homebrew / npx distribution — `npx claude-guardrails install`
- [ ] Per-project install mode — Write to `.claude/settings.local.json` instead of global
- [ ] Hook test suite — Automated tests that verify each hook blocks what it should
- [ ] MCP server allowlist template — Starter config for common trusted servers
