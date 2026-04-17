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

# BIP39 wordlist pass. A real mnemonic is 12+ words drawn from the 2048-word
# English list, formatted as space-separated tokens (that is how every wallet
# renders one). Prose that happens to contain the same wordlist words is
# broken up by punctuation, contractions, digits, or short words, so we
# only flag runs of 12+ candidate tokens (3-8 lowercase letters) that are
# separated solely by whitespace, then confirm every token in the run is a
# wordlist member. This rules out sentences like, "question what else you
# need you feel that ready then that ready okay" which tokenised to 13
# wordlist hits under the old count-the-matches approach.
if [[ -f "$BIP39_WORDLIST" ]]; then
  BIP39_HIT="$(
    echo "$INPUT" | jq -r --rawfile wl "$BIP39_WORDLIST" '
      (.prompt // "" | ascii_downcase) as $p |
      ($wl | split("\n") | map(select(length >= 3 and length <= 8))
        | reduce .[] as $w ({}; .[$w] = true)) as $set |
      [ $p
        | scan("(?:\\b[a-z]{3,8}\\b\\s+){11,}\\b[a-z]{3,8}\\b")
        | [scan("\\b[a-z]{3,8}\\b")]
        | select(all(.[]; $set[.]))
      ] as $hits |
      if ($hits | length) > 0
      then "BIP39 mnemonic (12+ consecutive wordlist words)"
      else empty end
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
