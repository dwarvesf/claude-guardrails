# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A security configuration package for Claude Code, providing hardened settings, hooks, and CLAUDE.md security rules. Built for the Dwarves Foundation team, based on Trail of Bits, Lasso Security, and Anthropic security recommendations.

Two variants are provided:

- **`full/`** — Complete 5-layer defense: permission deny rules, PreToolUse hooks (destructive deletes, direct pushes, pipe-to-shell, data exfiltration, permission escalation), PostToolUse prompt injection scanner, CLAUDE.md security rules, and OS-level sandbox guidance. Use for open source repos, untrusted codebases, or production credential handling.

- **`lite/`** — Minimal 3-layer config: permission deny rules, 3 PreToolUse hooks (destructive deletes, direct pushes, pipe-to-shell), and a slim CLAUDE.md security section. No prompt injection scanner or exfiltration hooks. Use for internal/trusted projects.

## Architecture

Each variant contains:
- `settings.json` — Claude Code global settings with `permissions.deny` rules (blocking Read/Edit on sensitive paths like SSH keys, AWS creds, .env files) and `hooks.PreToolUse` entries (blocking dangerous bash patterns before execution)
- `scan-secrets.sh` — UserPromptSubmit hook (bash + jq) that regex-scans prompts for live credentials (AWS keys, GitHub/Anthropic/OpenAI tokens, PEM blocks, BIP39 phrases) and blocks submission before the prompt reaches the model or is persisted to the session transcript. Uses jq's Oniguruma regex engine for lookbehind support — no extra runtime required.
- `scan-commit.sh` — PreToolUse hook (bash + jq) that intercepts `Bash` calls, detects `git commit`, runs `git diff --cached -U0` through the same pattern set as `scan-secrets.sh`, and blocks on match. Closes the gap where Claude writes a secret into code and then commits it (the prompt scanner only catches pasted creds).
- `CLAUDE-security-section.md` — Security rules to merge into a user's `~/.claude/CLAUDE.md`
- `SETUP.md` — Installation and usage guide

Full variant additionally includes:
- `prompt-injection-defender.sh` — A PostToolUse hook that scans Read/WebFetch/Bash outputs for prompt injection patterns (regex-based, warns but does not block)

Shared at the repo root:
- `patterns/secrets.json` — Single source of truth for credential regexes. Installed to `~/.claude/hooks/patterns/secrets.json`. Both `scan-secrets.sh` and `scan-commit.sh` load from this file, so updating a pattern in one place updates both hooks.

## Key Design Decisions

- **Hooks require `jq`** — PreToolUse hooks parse JSON input via `jq`; `scan-secrets.sh` uses jq's regex engine for pattern matching. This is the sole prerequisite for installation.
- **Defense in depth** — No single layer is sufficient. Deny rules only cover Claude's built-in tools (bash can bypass). Hooks are pattern-based (obfuscation can bypass). The sandbox (`/sandbox`) is the only OS-level enforcement but must be enabled per-session.
- **Warn, don't block** for prompt injection — The PostToolUse defender outputs warnings as JSON messages rather than blocking, to avoid false positives on legitimate content.
- **Settings must be merged, not replaced** — Users with existing `~/.claude/settings.json` must manually merge deny rules and hooks to avoid overwriting their config.
