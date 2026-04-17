#!/usr/bin/env bash
# scan-secrets.sh — Claude Code UserPromptSubmit hook.
#
# Reads a JSON payload on stdin, inspects the .prompt field for known secret
# patterns, and blocks (exit 2) if any match, or allows (exit 0). A non-zero
# exit in UserPromptSubmit prevents the prompt from reaching the model and
# surfaces the stderr message to the user.
#
# Pattern list is loaded from ../patterns/secrets.json (shared with
# scan-commit.sh). All regex matching runs inside jq (Oniguruma), which
# supports lookbehind, inline flags, and quantifiers the POSIX ERE engine
# in grep -E does not. Requires only bash + jq.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="${CLAUDE_GUARDRAILS_PATTERNS:-$SCRIPT_DIR/../patterns/secrets.json}"

INPUT="$(cat)"

# Fail-open on malformed JSON so a Claude Code schema change never blocks
# legitimate work.
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

# Fail-open if the shared patterns file is missing. Log once to stderr so
# the user notices a broken install rather than silently running unguarded.
if [[ ! -f "$PATTERNS_FILE" ]]; then
  echo "scan-secrets: patterns file not found at $PATTERNS_FILE (skipping scan)" >&2
  exit 0
fi

HITS="$(
  echo "$INPUT" | jq -r --slurpfile pats "$PATTERNS_FILE" '
    (.prompt // "") as $p |
    $pats[0]
    | map(select(.r as $r | $p | test($r)))
    | map(.n) | .[]
  '
)"

if [[ -z "$HITS" ]]; then
  exit 0
fi

{
  echo ""
  echo "==================== SECRET DETECTED — PROMPT BLOCKED ===================="
  echo ""
  echo "Your prompt matched the following pattern(s):"
  echo "$HITS" | sed 's/^/  - /'
  echo ""
  echo "The prompt was NOT sent to Claude."
  echo ""
  echo "If this was a real credential:"
  echo "  1. Rotate it on the upstream service NOW (delete + regenerate, not later)."
  echo "  2. Save the new credential directly to a password manager. Never paste"
  echo "     secrets into a Claude Code session. The transcript persists on disk"
  echo "     at ~/.claude/projects/.../*.jsonl and may be logged upstream."
  echo ""
  echo "If this was a false positive (commit SHA, hash, unrelated identifier),"
  echo "rephrase to avoid the pattern and resubmit."
  echo ""
  echo "=========================================================================="
} >&2
exit 2
