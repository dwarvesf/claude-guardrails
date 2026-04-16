# Changelog

All notable changes to claude-guardrails are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [0.3.3] — 2026-04-17

Alignment pass against [Trail of Bits' `claude-code-config`](https://github.com/trailofbits/claude-code-config) threat model and deny-rule coverage.

### Added
- **Privacy `env` flags in both variants** — `DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`, `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1`. Intentionally does **not** set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` because that flag also disables auto-updates.
- **Broader credential deny coverage** — both variants add `~/.kube/**` (cluster bearer tokens) and `~/.azure/**` (Azure CLI creds). `full` adds six crypto-wallet app-support paths (MetaMask, Exodus, Phantom, Solflare, Electrum on macOS + `~/.electrum/**` on Linux).
- **Redundant Bash deny rules** as belt-and-suspenders alongside the PreToolUse hooks: `Bash(sudo *)`, `Bash(mkfs *)`, `Bash(dd *)`, `Bash(rm -rf *)`.

### Changed
- Deny rule counts: **lite 15 → 21**, **full 28 → 40**.
- README "How It Works" restructured so `/sandbox` leads as the enforcement boundary and the other layers are framed explicitly as "can be bypassed." Adds a devcontainer pointer to Trail of Bits' companion repo for untrusted-code review sessions.
- CI test `get_deny_count()` expectations updated across all 7 scenarios; still 58/58 assertions green.

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
