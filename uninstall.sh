#!/usr/bin/env bash
# uninstall.sh — Remove claude-guardrails from ~/.claude/
# Usage: ./uninstall.sh [lite|full]   (defaults to lite)
#
# Approach: SURGICAL REMOVE
# This script does NOT restore a backup. Instead, it reads the variant's
# settings.json to know exactly which deny rules and hooks were added,
# then subtracts only those entries from your current config. This means:
#   - Your own custom deny rules and hooks are preserved
#   - Works regardless of when you installed or if the backup is stale
#   - Safe to run even if you modified settings.json after install
#
# What gets removed:
#   - permissions.deny entries that match the variant's deny list
#   - hooks.PreToolUse entries that match the variant's hook list
#   - hooks.UserPromptSubmit entries for scan-secrets (both variants)
#   - ~/.claude/hooks/scan-secrets/ directory (both variants)
#   - ~/.claude/hooks/scan-commit/ directory (both variants)
#   - ~/.claude/hooks/patterns/ directory (shared pattern list, both variants)
#   - hooks.PostToolUse entries (full only — prompt injection defender)
#   - ~/.claude/hooks/prompt-injection-defender/ directory (full only)
#   - "# Security Rules" section from ~/.claude/CLAUDE.md
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
  exit 1
fi

if [[ ! -d "$VARIANT_DIR" ]]; then
  echo "Error: Variant directory not found: $VARIANT_DIR"
  exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
  echo "Nothing to uninstall: ~/.claude/settings.json not found."
  exit 0
fi

echo "Uninstalling claude-guardrails ($VARIANT)..."

# --- Back up current settings before modifying ---

cp "$SETTINGS" "$SETTINGS.pre-uninstall"
echo "  Backed up current settings → settings.json.pre-uninstall"

# --- Remove deny rules and PreToolUse hooks ---

VARIANT_SETTINGS="$VARIANT_DIR/settings.json"

jq --slurpfile remove "$VARIANT_SETTINGS" '
  # Subtract deny rules that came from the variant
  .permissions.deny = (
    [.permissions.deny // [] | .[] |
      select(. as $rule | ($remove[0].permissions.deny // []) | index($rule) | not)]
  ) |

  # Subtract PreToolUse hooks that came from the variant
  .hooks.PreToolUse = (
    [.hooks.PreToolUse // [] | .[] |
      select(. as $hook | ($remove[0].hooks.PreToolUse // []) | map(. == $hook) | any | not)]
  ) |

  # Clean up empty arrays
  if .permissions.deny == [] then .permissions |= del(.deny) else . end |
  if .hooks.PreToolUse == [] then .hooks |= del(.PreToolUse) else . end |

  # Clean up empty parent objects
  if .permissions == {} then del(.permissions) else . end |
  if .hooks == {} then del(.hooks) else . end
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

DENY_REMOVED=$(jq '.permissions.deny | length' "$VARIANT_SETTINGS")
HOOKS_REMOVED=$(jq '.hooks.PreToolUse | length' "$VARIANT_SETTINGS")
echo "  Removed $DENY_REMOVED deny rules"
echo "  Removed $HOOKS_REMOVED PreToolUse hooks"

# --- Both variants: remove UserPromptSubmit hook + scan-secrets script ---

# Remove UserPromptSubmit entries that reference scan-secrets
jq '
  .hooks.UserPromptSubmit = (
    [.hooks.UserPromptSubmit // [] | .[] |
      select(.hooks | map(.command // "" | test("scan-secrets")) | any | not)]
  ) |
  if .hooks.UserPromptSubmit == [] then .hooks |= del(.UserPromptSubmit) else . end |
  if .hooks == {} then del(.hooks) else . end
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "  Removed UserPromptSubmit hook entry"

# Remove the scan-secrets script directory
SCAN_DIR="$CLAUDE_DIR/hooks/scan-secrets"
if [[ -d "$SCAN_DIR" ]]; then
  rm -rf "$SCAN_DIR"
  echo "  Deleted ~/.claude/hooks/scan-secrets/"
fi

# Remove the scan-commit script directory (PreToolUse hook entry is removed
# automatically by the variant-settings subtract above).
COMMIT_DIR="$CLAUDE_DIR/hooks/scan-commit"
if [[ -d "$COMMIT_DIR" ]]; then
  rm -rf "$COMMIT_DIR"
  echo "  Deleted ~/.claude/hooks/scan-commit/"
fi

# Remove the shared patterns directory. Both scan-secrets and scan-commit
# used it, so when both are gone the patterns file has no remaining reader.
PATTERNS_DIR="$CLAUDE_DIR/hooks/patterns"
if [[ -d "$PATTERNS_DIR" ]]; then
  rm -rf "$PATTERNS_DIR"
  echo "  Deleted ~/.claude/hooks/patterns/"
fi

# --- Full only: remove PostToolUse hook + defender script ---

if [[ "$VARIANT" == "full" ]]; then
  # Remove PostToolUse entries that reference the prompt injection defender
  jq '
    .hooks.PostToolUse = (
      [.hooks.PostToolUse // [] | .[] |
        select(.hooks | map(.command // "" | test("prompt-injection-defender")) | any | not)]
    ) |
    if .hooks.PostToolUse == [] then .hooks |= del(.PostToolUse) else . end |
    if .hooks == {} then del(.hooks) else . end
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  Removed PostToolUse hook entry"

  # Remove the defender script directory
  HOOK_DIR="$CLAUDE_DIR/hooks/prompt-injection-defender"
  if [[ -d "$HOOK_DIR" ]]; then
    rm -rf "$HOOK_DIR"
    echo "  Deleted ~/.claude/hooks/prompt-injection-defender/"
  fi
fi

# Clean up empty hooks directory (both variants may leave it empty)
if [[ -d "$CLAUDE_DIR/hooks" ]] && [ -z "$(ls -A "$CLAUDE_DIR/hooks")" ]; then
  rmdir "$CLAUDE_DIR/hooks"
  echo "  Removed empty ~/.claude/hooks/ directory"
fi

# --- Remove Security Rules section from CLAUDE.md ---

CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

if [[ -f "$CLAUDE_MD" ]] && grep -q "# Security Rules" "$CLAUDE_MD" 2>/dev/null; then
  # Remove from "# Security Rules" heading to the next top-level heading or EOF.
  # Uses awk: skip lines from "# Security Rules" until hitting another "# " heading
  # (or EOF). Also trims trailing blank lines left behind.
  awk '
    /^# Security Rules/ { skip=1; next }
    /^# / && skip { skip=0 }
    !skip { print }
  ' "$CLAUDE_MD" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$CLAUDE_MD.tmp" \
    && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
  echo "  Removed Security Rules section from CLAUDE.md"

  # If CLAUDE.md is now empty (or whitespace-only), remove it
  if [[ ! -s "$CLAUDE_MD" ]] || ! grep -q '[^[:space:]]' "$CLAUDE_MD" 2>/dev/null; then
    rm "$CLAUDE_MD"
    echo "  Deleted empty CLAUDE.md"
  fi
fi

# --- Summary ---

echo ""
echo "Done! Guardrails ($VARIANT) removed."
if [[ -f "$SETTINGS" ]]; then
  REMAINING_DENY=$(jq '.permissions.deny // [] | length' "$SETTINGS")
  REMAINING_HOOKS=$(jq '.hooks.PreToolUse // [] | length' "$SETTINGS")
  echo "  Remaining deny rules: $REMAINING_DENY"
  echo "  Remaining PreToolUse hooks: $REMAINING_HOOKS"
fi
echo ""
echo "A pre-uninstall backup was saved to ~/.claude/settings.json.pre-uninstall"
echo "Start a new Claude Code session for changes to take effect."
