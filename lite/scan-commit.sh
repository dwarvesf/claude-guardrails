#!/usr/bin/env bash
# scan-commit.sh — Claude Code PreToolUse hook (matcher: Bash).
#
# Fires when Claude runs a Bash command. If the command is `git commit`,
# scans the staged diff for secret patterns (shared with scan-secrets.sh)
# and blocks (exit 2) on match. For all other commands, exits 0.
#
# This closes the gap left by scan-secrets.sh: the prompt-submit scanner
# only catches pasted credentials; this hook catches secrets that Claude
# writes into code and then tries to commit.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="${CLAUDE_GUARDRAILS_PATTERNS:-$SCRIPT_DIR/../patterns/secrets.json}"

INPUT="$(cat)"

# Fail-open on malformed JSON.
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"

# Only act on `git commit` (leave git commit-tree, commit-graph plumbing alone).
# The word boundary after `commit` prevents matching `git commit-tree`, and the
# required whitespace before handles chained commands (`... && git commit ...`).
if ! echo "$CMD" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# Claude Code passes cwd at the top level of the hook payload.
CWD="$(echo "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty')"
if [[ -n "$CWD" && -d "$CWD" ]]; then
  cd "$CWD" || exit 0
fi

# If not a git repo, let git itself produce the error.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# Scan only staged changes, not the entire file. This avoids re-flagging
# secrets that were already committed before the hook existed, and keeps
# the scan bounded to what's about to be recorded.
DIFF="$(git diff --cached --unified=0 --no-color 2>/dev/null || true)"
if [[ -z "$DIFF" ]]; then
  exit 0
fi

# Extract only the added-line content (lines starting with "+"), skipping
# the "+++" file-header lines that otherwise leak path strings into the scan.
ADDED="$(echo "$DIFF" | awk '/^\+\+\+ / { next } /^\+/ { sub(/^\+/, ""); print }')"

if [[ -z "$ADDED" ]]; then
  exit 0
fi

if [[ ! -f "$PATTERNS_FILE" ]]; then
  echo "scan-commit: patterns file not found at $PATTERNS_FILE (skipping scan)" >&2
  exit 0
fi

HITS="$(
  jq -Rsr --slurpfile pats "$PATTERNS_FILE" '
    . as $text |
    $pats[0]
    | map(select(.r as $r | $text | test($r)))
    | map(.n) | .[]
  ' <<< "$ADDED"
)"

if [[ -z "$HITS" ]]; then
  exit 0
fi

# Show which staged files contain changes so the user knows where to look.
FILES="$(git diff --cached --name-only 2>/dev/null | head -10)"

{
  echo ""
  echo "==================== SECRET DETECTED — COMMIT BLOCKED ===================="
  echo ""
  echo "Staged changes matched the following pattern(s):"
  echo "$HITS" | sed 's/^/  - /'
  echo ""
  echo "Files with staged changes:"
  echo "$FILES" | sed 's/^/  /'
  echo ""
  echo "The commit was NOT created."
  echo ""
  echo "To resolve:"
  echo "  1. If real: rotate the credential on the upstream service NOW, then"
  echo "     remove the secret from the working tree and re-stage a clean diff."
  echo "     Use 'git restore --staged <file>' to unstage the current change."
  echo "  2. If false positive (commit SHA, hash, unrelated identifier):"
  echo "     stage smaller chunks until the matching one is isolated, or"
  echo "     rephrase the content to avoid the pattern."
  echo ""
  echo "=========================================================================="
} >&2
exit 2
