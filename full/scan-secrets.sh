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
BIP39_WORDLIST="${CLAUDE_GUARDRAILS_BIP39_WORDLIST:-$SCRIPT_DIR/../patterns/bip39-english.txt}"

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

# BIP39 wordlist pass. A real mnemonic is 12+ consecutive words drawn from
# the 2048-word English list, which deliberately excludes common stop-words
# ("the", "and", "for", ...). Checking set membership avoids the false
# positives the old "12+ short words" regex produced on ordinary prose.
if [[ -f "$BIP39_WORDLIST" ]]; then
  BIP39_HIT="$(
    echo "$INPUT" | jq -r --rawfile wl "$BIP39_WORDLIST" '
      (.prompt // "" | ascii_downcase) as $p |
      [$p | scan("\\b[a-z]{3,8}\\b")] as $tokens |
      ($wl | split("\n") | map(select(length >= 3 and length <= 8))
        | reduce .[] as $w ({}; .[$w] = true)) as $set |
      ($tokens | length) as $n |
      if $n < 12 then empty
      else
        [range(0; $n - 11) | . as $i |
         select([range($i; $i + 12) | $set[$tokens[.]]] | all)]
        | if length > 0
          then "BIP39 mnemonic (12+ consecutive wordlist words)"
          else empty end
      end
    '
  )"
  if [[ -n "$BIP39_HIT" ]]; then
    if [[ -n "$HITS" ]]; then
      HITS="$HITS"$'\n'"$BIP39_HIT"
    else
      HITS="$BIP39_HIT"
    fi
  fi
fi

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
