# Changelog

All notable changes to claude-guardrails are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [0.4.0] — 2026-04-17

**Breaking change to the install command.** The npm package has moved from `claude-guardrails` (owned by the `thug` user account) to `@dwarvesf/claude-guardrails` (owned by the Dwarves Foundation organization). The GitHub repo URL is unchanged.

### Migration

Any user running the old install command will continue to get v0.3.0 from the unscoped package (which ships the broken `$schema` URL — see #6). Switch to:

```
npx @dwarvesf/claude-guardrails install        # lite, default
npx @dwarvesf/claude-guardrails install full   # full
npx @dwarvesf/claude-guardrails uninstall      # or uninstall full
```

The unscoped package is deprecated at v0.3.0 with a pointer message; users will see the deprecation warning on install.

### Changed
- `package.json` name: `claude-guardrails` → `@dwarvesf/claude-guardrails`.
- Version: 0.3.6 → 0.4.0 (minor bump, install-command break is a breaking UX change).
- `bin/claude-guardrails` — hardcoded `VERSION` bumped to 0.4.0; Examples section updated to show scoped `npx` command; variant descriptions updated from the stale "3 hooks / 5 hooks" to current "4 PreToolUse hooks / 6 PreToolUse hooks + secret+injection scanners."
- `README.md` Quick Start and Uninstall sections use the scoped command.
- `docs/maintenance.md` quarterly-review checklist points at the scoped `npx` command.

### Ownership
- npm package owned by the `dwarvesf` npm organization (`thug` is a member; add more team members via https://www.npmjs.com/settings/dwarvesf/members).
- Unchanged: GitHub repo (`dwarvesf/claude-guardrails`), CLI bin name (`claude-guardrails`), all file paths, settings.json layout.

## [0.3.6] — 2026-04-17

Follow-up to v0.3.5. The previous release fixed the `$schema` bug for anyone re-running the installer (the jq merge always prefers the new file's value), but the fix happened silently — a user who ran v0.3.6 install after months on a broken v0.3.0–v0.3.4 install had no way to know their guardrails had been inactive the whole time. This release surfaces that state so users understand the remediation.

### Added
- **Install-time remediation notice** — when `install.sh` detects the pre-v0.3.5 `$schema` URL in an existing `~/.claude/settings.json`, it prints a clearly-bordered `NOTICE` after the merge explaining (1) what the old value was, (2) that it silently disabled every guardrail in prior installs, (3) that it's been corrected, and (4) a pointer to the advisory in #6. Fresh installs and existing installs with the correct `$schema` stay quiet (no false positive).
- **`schema-remediation` CI scenario** — 4 assertions covering: broken schema triggers the notice; post-install `$schema` is corrected; fresh install is quiet; correct-existing install is quiet. Wired into the GitHub Actions matrix. CI: 9 scenarios / 92 assertions → 10 scenarios / 96 assertions.

## [0.3.5] — 2026-04-17

Critical hotfix. The wrong `$schema` URL shipped in every release from v0.3.0 through v0.3.4 caused Claude Code to silently discard the entire settings.json. Anyone who installed claude-guardrails fresh on a machine during that window got zero active guardrails — no deny rules, no hooks, no scanner. Reported and fixed by [@valtumi](https://github.com/valtumi) in #3.

### Fixed
- **`$schema` URL in both `lite/settings.json` and `full/settings.json`** — was `https://claude.ai/schemas/claude-code-settings.json` (not accepted by Claude Code), now `https://json.schemastore.org/claude-code-settings.json`. Credit: @valtumi (#3).

### Added
- **CI assertion on `$schema`** — `test_lite_fresh`, `test_full_fresh`, and `test_merge_existing` now verify the post-install `$schema` field matches the schemastore URL. This class of bug previously escaped CI because JSON-parseability and install/uninstall logic tests don't probe whether Claude Code actually honors the file. CI suite: 9 scenarios / 89 assertions → 9 scenarios / 92 assertions.

### Upgrade note
If you have a pre-0.3.5 install, re-running `npx claude-guardrails install` merges the corrected `$schema` value into your existing `~/.claude/settings.json` (the jq merge prefers the new file's value). Or manually edit the `$schema` field to `https://json.schemastore.org/claude-code-settings.json`. **Until you do one of these, your guardrails are not active.**

## [0.3.4] — 2026-04-17

Adds a commit-time secret scanner, closing the gap between the prompt-submit scanner (which catches pasted credentials) and the code Claude writes and then tries to commit. Also tightens the direct-push guardrail's regex to kill a real-world false positive discovered while shipping this change.

### Added
- **`scan-commit.sh` PreToolUse hook (both variants)** — fires on `Bash` tool calls, inspects the command for `git commit`, runs `git diff --cached --unified=0` through the same regex set as `scan-secrets.sh`, and blocks (exit 2) on match. Reports matched pattern name(s) and the list of staged files. Word-boundary matching avoids false positives on `git commit-tree` plumbing.
- **Shared pattern file `patterns/secrets.json`** — single source of truth for credential regexes, loaded by both `scan-secrets.sh` (prompt) and `scan-commit.sh` (staged diff). Installs to `~/.claude/hooks/patterns/secrets.json`. Closes v0.4 WS2 (pattern extraction).
- **New CI scenario `scan-commit`** — functional test that stands up a throwaway git repo inside the sandboxed HOME and asserts seven response cases: clean diff allowed, AWS key blocked, `git status` passes through, `git commit-tree` plumbing not intercepted, `git add && git commit` chained form blocked, heredoc-wrapped commit message blocked, missing patterns file fails open.
- **New CI scenario `push-hook`** — functional test for the direct-push-to-protected-branch guardrail. 13 cases: 7 block (direct, force, master, production, `&&`-chained, `;`-chained, subshell-wrapped) and 6 allow (PR body with trigger phrase, echo commentary, grep searching for phrase, feature branch, `main`-prefixed branch name, non-push git command).

### Changed
- PreToolUse hook counts: **lite 3 → 4**, **full 5 → 6**.
- Both `scan-secrets.sh` scripts refactored to load patterns from `../patterns/secrets.json` (supports `$CLAUDE_GUARDRAILS_PATTERNS` override for testing). Behavior unchanged; pattern list and output format preserved.
- **Direct-push hook regex tightened** to only match `git push` at a command-boundary position (start of string, or after `&`, `|`, `;`, `(`). The old regex matched anywhere in the command string and false-positived on `gh pr create --body "... git push origin main ..."` — hit when creating this release's own PR. The trailing branch-name anchor also now requires whitespace / separator / EOS afterwards, so branches like `main-feature-branch` no longer trigger. Known regression: `sudo git push origin main` no longer matches — tradeoff documented.
- CI suite: 7 scenarios / 58 assertions → 9 scenarios / 89 assertions, all green.
- `install.sh` copies `patterns/secrets.json` + `scan-commit.sh`; `uninstall.sh` removes `~/.claude/hooks/scan-commit/` and `~/.claude/hooks/patterns/`.

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
