# Changelog

All notable changes to claude-guardrails are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [0.3.2] — 2026-04-17

### Added
- **`scan-secrets.sh` UserPromptSubmit hook** in both variants. Blocks prompts containing live credentials (AWS, GitHub, Anthropic, OpenAI, Google, Slack, Stripe, 1Password tokens; PEM private-key headers; BIP39 mnemonics; 64-hex private keys; `API_KEY=value` assignments). Prevents pasted secrets from reaching the model or being persisted to `~/.claude/projects/.../*.jsonl`. Pure bash + jq — no new runtime dependency. ~11 ms median per invocation.
- New `docs/maintenance.md` quarterly review checklist covering deny rules, PreToolUse hooks, the secret scanner, the prompt injection defender, and upstream threat research.
- v0.4 "Maintainability & Sustainability" plan in `docs/plan.md` — pattern test corpus, data-file extraction, upstream tracking.

### Fixed
- `tests/ci-test.sh` now forces `HOME` to a fresh `mktemp -d` at script start and aborts if `$HOME` matches real-home patterns (`/Users/*`, `/home/*`, `/root`). Replaces the previous `CI=true` environment-variable gate on `clean_claude_dir()`, which was bypassable and led to the deletion of a real user's `~/.claude/` during development.

### Changed
- README, `full/SETUP.md`, `lite/SETUP.md`, and `CLAUDE.md` updated to document the new UserPromptSubmit layer and the 6-layer defense-in-depth model.
- `install.sh` / `uninstall.sh` now handle `UserPromptSubmit` hooks in both variants (merge via jq on install, surgical removal on uninstall).
- CI test suite grew from 7 scenarios / ~40 assertions to 7 scenarios / 58 assertions; all green.

### Gitignore
- `.claude/settings.local.json` (Claude Code writes machine-specific permission grants here during local sessions).

## [0.3.0] — prior

Initial npm distribution. See git history (`babf128` and earlier) for the install script, uninstall script, and lite/full variant baseline.
