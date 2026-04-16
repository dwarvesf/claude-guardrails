#!/usr/bin/env bash
# install.sh — Install claude-guardrails (lite or full variant)
# Usage: ./install.sh [lite|full]   (defaults to lite)
set -euo pipefail

VARIANT="${1:-lite}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VARIANT_DIR="$SCRIPT_DIR/$VARIANT"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# --- Validate ---

if [[ "$VARIANT" != "lite" && "$VARIANT" != "full" ]]; then
  echo "Error: Unknown variant '$VARIANT'. Use 'lite' or 'full'."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed."
  echo "  macOS:        brew install jq"
  echo "  Debian/Ubuntu: sudo apt install jq"
  exit 1
fi

if [[ ! -d "$VARIANT_DIR" ]]; then
  echo "Error: Variant directory not found: $VARIANT_DIR"
  exit 1
fi

echo "Installing claude-guardrails ($VARIANT)..."

# --- Ensure ~/.claude exists ---

mkdir -p "$CLAUDE_DIR"

# --- Merge settings.json ---

if [[ -f "$SETTINGS" ]]; then
  cp "$SETTINGS" "$SETTINGS.backup"
  echo "  Backed up existing settings → settings.json.backup"

  # Merge: deduplicate deny rules and PreToolUse hooks
  jq -s '
    .[0] as $existing | .[1] as $new |
    ($existing * $new) |
    .permissions.deny = (
      [($existing.permissions.deny // [])[], ($new.permissions.deny // [])[]]
      | unique
    ) |
    .hooks.PreToolUse = (
      [($existing.hooks.PreToolUse // [])[], ($new.hooks.PreToolUse // [])[]]
      | unique
    ) |
    .hooks.UserPromptSubmit = (
      [($existing.hooks.UserPromptSubmit // [])[], ($new.hooks.UserPromptSubmit // [])[]]
      | unique
    )
  ' "$SETTINGS.backup" "$VARIANT_DIR/settings.json" > "$SETTINGS.tmp" \
    && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  Merged settings.json (deny rules + hooks deduplicated)"
else
  cp "$VARIANT_DIR/settings.json" "$SETTINGS"
  echo "  Created settings.json"
fi

# --- Append CLAUDE.md security section ---

CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SECURITY_SECTION="$VARIANT_DIR/CLAUDE-security-section.md"

if [[ -f "$CLAUDE_MD" ]] && grep -q "# Security Rules" "$CLAUDE_MD" 2>/dev/null; then
  echo "  CLAUDE.md already contains Security Rules — skipped"
else
  { echo ""; cat "$SECURITY_SECTION"; } >> "$CLAUDE_MD"
  echo "  Appended security rules to CLAUDE.md"
fi

# --- Both variants: scan-secrets UserPromptSubmit hook ---

SCAN_DIR="$CLAUDE_DIR/hooks/scan-secrets"
mkdir -p "$SCAN_DIR"
cp "$VARIANT_DIR/scan-secrets.sh" "$SCAN_DIR/scan-secrets.sh"
chmod +x "$SCAN_DIR/scan-secrets.sh"
echo "  Installed scan-secrets.sh → ~/.claude/hooks/scan-secrets/"

# Merge UserPromptSubmit hook entry into settings.json
PROMPT_HOOK='[{"hooks":[{"type":"command","command":"~/.claude/hooks/scan-secrets/scan-secrets.sh","timeout":5}]}]'

jq --argjson hook "$PROMPT_HOOK" '
  .hooks.UserPromptSubmit = (
    [(.hooks.UserPromptSubmit // [])[], $hook[]]
    | unique
  )
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "  Added UserPromptSubmit hook to settings.json"

# --- Full only: prompt injection defender ---

if [[ "$VARIANT" == "full" ]]; then
  HOOK_DIR="$CLAUDE_DIR/hooks/prompt-injection-defender"
  mkdir -p "$HOOK_DIR"
  cp "$VARIANT_DIR/prompt-injection-defender.sh" "$HOOK_DIR/prompt-injection-defender.sh"
  chmod +x "$HOOK_DIR/prompt-injection-defender.sh"
  echo "  Installed prompt-injection-defender.sh → ~/.claude/hooks/"

  # Merge PostToolUse hook entry into settings.json
  POST_HOOK='[{"matcher":"Read|WebFetch|Bash|mcp__.*","hooks":[{"type":"command","command":"~/.claude/hooks/prompt-injection-defender/prompt-injection-defender.sh"}]}]'

  jq --argjson hook "$POST_HOOK" '
    .hooks.PostToolUse = (
      [(.hooks.PostToolUse // [])[], $hook[]]
      | unique
    )
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  Added PostToolUse hook to settings.json"
fi

# --- Summary ---

echo ""
echo "Done! Summary:"
echo "  Variant:    $VARIANT"
DENY_COUNT=$(jq '.permissions.deny | length' "$SETTINGS")
PRE_COUNT=$(jq '.hooks.PreToolUse | length' "$SETTINGS")
PROMPT_COUNT=$(jq '.hooks.UserPromptSubmit | length' "$SETTINGS")
echo "  Deny rules: $DENY_COUNT"
echo "  PreToolUse hooks: $PRE_COUNT"
echo "  UserPromptSubmit hooks: $PROMPT_COUNT (inbound secret scanner)"
if [[ "$VARIANT" == "full" ]]; then
  POST_COUNT=$(jq '.hooks.PostToolUse | length' "$SETTINGS")
  echo "  PostToolUse hooks: $POST_COUNT (prompt injection scanner)"
fi
echo ""
echo "Start a new Claude Code session to activate. Test with:"
echo "  cat ~/.ssh/id_rsa        → should be denied"
echo "  rm -rf /                 → should be blocked by hook"
echo "  git push origin main     → should be blocked by hook"
