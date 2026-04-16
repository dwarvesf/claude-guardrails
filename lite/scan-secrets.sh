#!/usr/bin/env bash
# scan-secrets.sh — Claude Code UserPromptSubmit hook.
#
# Reads a JSON payload on stdin, inspects the .prompt field for known secret
# patterns, and blocks (exit 2) if any match, or allows (exit 0). A non-zero
# exit in UserPromptSubmit prevents the prompt from reaching the model and
# surfaces the stderr message to the user.
#
# All regex matching runs inside jq (Oniguruma), which supports lookbehind,
# inline flags, and quantifiers the POSIX ERE engine in grep -E does not.
# Requires only bash + jq — jq is already a claude-guardrails dependency.
set -u

INPUT="$(cat)"

# Fail-open on malformed JSON so a Claude Code schema change never blocks
# legitimate work. The first jq call validates parseability; if it fails,
# exit 0 without blocking.
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

# Each pattern is a name|Oniguruma-regex pair. Order matches the prior
# Python implementation so behavior is identical.
HITS="$(
  echo "$INPUT" | jq -r '
    (.prompt // "") as $p |
    [
      {n: "AWS access key ID",
       r: "\\bAKIA[0-9A-Z]{16}\\b"},
      {n: "GitHub token (PAT / OAuth / server-to-server / user / refresh)",
       r: "\\bgh[pousr]_[A-Za-z0-9_]{36,}\\b"},
      {n: "Anthropic API key",
       r: "\\bsk-ant-[A-Za-z0-9\\-_]{50,}\\b"},
      {n: "OpenAI API key",
       r: "\\bsk-(proj-)?[A-Za-z0-9\\-_]{40,}\\b"},
      {n: "Google API key",
       r: "\\bAIza[0-9A-Za-z\\-_]{35}\\b"},
      {n: "Slack token",
       r: "\\bxox[abprs]-[A-Za-z0-9\\-]{10,}\\b"},
      {n: "Stripe key",
       r: "\\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}\\b"},
      {n: "1Password service account token",
       r: "\\bops_[A-Za-z0-9+/=]{40,}\\b"},
      {n: "PEM private-key block header",
       r: "-----BEGIN\\s+(RSA|DSA|EC|OPENSSH|PGP|ENCRYPTED|PRIVATE)(\\s+PRIVATE)?\\s+KEY-----"},
      {n: "Hex private key (64 hex chars — also blocks SHA-256 digests by design)",
       r: "(?<![a-fA-F0-9])(0x)?[a-fA-F0-9]{64}(?![a-fA-F0-9])"},
      {n: "Secret-like variable assignment",
       r: "(?i)\\b(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token|secret[_-]?key|private[_-]?key|passphrase|mnemonic|seed[_-]?phrase)\\s*[=:]\\s*[\"`'"'"']?[A-Za-z0-9+/=_\\-]{16,}[\"`'"'"']?"},
      {n: "BIP39-shaped mnemonic (12+ short words, case-insensitive)",
       r: "(?i)(^|\\s)([a-z]{3,8}\\s+){11}[a-z]{3,8}(\\s|$)"}
    ]
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
