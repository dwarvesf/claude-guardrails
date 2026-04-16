#!/usr/bin/env bash
# ci-test.sh — CI test runner for install/uninstall scenarios
# Usage: bash tests/ci-test.sh <scenario>
set -euo pipefail

SCENARIO="${1:?Usage: ci-test.sh <scenario>}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

# --- Helpers ---

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" label="${3:-}"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label ($actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local path="$1" label="${2:-file exists: $1}"
  if [[ -f "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — file not found: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local path="$1" label="${2:-file absent: $1}"
  if [[ ! -f "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — file should not exist: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_not_exists() {
  local path="$1" label="${2:-dir absent: $1}"
  if [[ ! -d "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — directory should not exist: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_executable() {
  local path="$1" label="${2:-executable: $1}"
  if [[ -x "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — file not executable: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local file="$1" pattern="$2" label="${3:-grep match}"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — pattern '$pattern' not found in $file"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local file="$1" pattern="$2" label="${3:-grep no match}"
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — pattern '$pattern' should not be in $file"
    FAIL=$((FAIL + 1))
  fi
}

get_deny_count() {
  jq '.permissions.deny // [] | length' "$SETTINGS"
}

get_pre_hook_count() {
  jq '.hooks.PreToolUse // [] | length' "$SETTINGS"
}

get_post_hook_count() {
  jq '.hooks.PostToolUse // [] | length' "$SETTINGS"
}

get_prompt_hook_count() {
  jq '.hooks.UserPromptSubmit // [] | length' "$SETTINGS"
}

clean_claude_dir() {
  if [[ -z "${CI:-}" ]]; then
    echo "Error: refusing to delete ~/.claude outside CI. Set CI=true to override."
    exit 1
  fi
  rm -rf "$CLAUDE_DIR"
}

finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

# --- Scenarios ---

test_lite_fresh() {
  echo "=== lite-fresh: Install lite on clean ~/.claude/ ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite

  assert_file_exists "$SETTINGS" "settings.json created"
  assert_eq "$(get_deny_count)" "15" "deny rule count"
  assert_eq "$(get_pre_hook_count)" "3" "PreToolUse hook count"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count"
  assert_file_exists "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script is executable"
  assert_file_exists "$CLAUDE_MD" "CLAUDE.md created"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md contains Security Rules heading"

  finish
}

test_full_fresh() {
  echo "=== full-fresh: Install full on clean ~/.claude/ ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" full

  assert_file_exists "$SETTINGS" "settings.json created"
  assert_eq "$(get_deny_count)" "28" "deny rule count"
  assert_eq "$(get_pre_hook_count)" "5" "PreToolUse hook count"
  assert_eq "$(get_post_hook_count)" "1" "PostToolUse hook count"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count"
  assert_file_exists "$CLAUDE_DIR/hooks/prompt-injection-defender/prompt-injection-defender.sh" "defender script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/prompt-injection-defender/prompt-injection-defender.sh" "defender script is executable"
  assert_file_exists "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script is executable"
  assert_file_exists "$CLAUDE_MD" "CLAUDE.md created"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md contains Security Rules heading"

  finish
}

test_lite_idempotent() {
  echo "=== lite-idempotent: Install lite twice, counts unchanged ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite
  bash "$REPO_DIR/install.sh" lite

  assert_eq "$(get_deny_count)" "15" "deny rule count after double install"
  assert_eq "$(get_pre_hook_count)" "3" "PreToolUse hook count after double install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count after double install"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md still contains Security Rules"

  finish
}

test_lite_roundtrip() {
  echo "=== lite-roundtrip: Install lite then uninstall lite ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite

  # Sanity check install worked
  assert_eq "$(get_deny_count)" "15" "deny count after install"
  assert_eq "$(get_pre_hook_count)" "3" "PreToolUse count after install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit count after install"

  bash "$REPO_DIR/uninstall.sh" lite

  assert_eq "$(jq '.permissions.deny // [] | length' "$SETTINGS")" "0" "deny count after uninstall"
  assert_eq "$(jq '.hooks.PreToolUse // [] | length' "$SETTINGS")" "0" "PreToolUse count after uninstall"
  assert_eq "$(jq '.hooks.UserPromptSubmit // [] | length' "$SETTINGS")" "0" "UserPromptSubmit count after uninstall"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/scan-secrets" "scan-secrets dir removed"
  # CLAUDE.md should be deleted (was only security rules)
  assert_file_not_exists "$CLAUDE_MD" "CLAUDE.md removed (was empty)"

  finish
}

test_full_roundtrip() {
  echo "=== full-roundtrip: Install full then uninstall full ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" full

  # Sanity check install worked
  assert_eq "$(get_deny_count)" "28" "deny count after install"
  assert_eq "$(get_pre_hook_count)" "5" "PreToolUse count after install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit count after install"

  bash "$REPO_DIR/uninstall.sh" full

  assert_eq "$(jq '.permissions.deny // [] | length' "$SETTINGS")" "0" "deny count after uninstall"
  assert_eq "$(jq '.hooks.PreToolUse // [] | length' "$SETTINGS")" "0" "PreToolUse count after uninstall"
  assert_eq "$(jq '.hooks.UserPromptSubmit // [] | length' "$SETTINGS")" "0" "UserPromptSubmit count after uninstall"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/prompt-injection-defender" "defender dir removed"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/scan-secrets" "scan-secrets dir removed"
  # CLAUDE.md should be deleted (was only security rules)
  assert_file_not_exists "$CLAUDE_MD" "CLAUDE.md removed (was empty)"

  finish
}

test_full_idempotent() {
  echo "=== full-idempotent: Install full twice, counts unchanged ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" full
  bash "$REPO_DIR/install.sh" full

  assert_eq "$(get_deny_count)" "28" "deny count after double install"
  assert_eq "$(get_pre_hook_count)" "5" "PreToolUse hook count after double install"
  assert_eq "$(get_post_hook_count)" "1" "PostToolUse hook count after double install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count after double install"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md still contains Security Rules"

  finish
}

test_merge_existing() {
  echo "=== merge-existing: Custom config preserved through install/uninstall ==="
  clean_claude_dir
  mkdir -p "$CLAUDE_DIR"

  # Seed CLAUDE.md with custom content
  cat > "$CLAUDE_MD" <<'EOF'
# My Project Rules

## Coding Style
- Use 2-space indentation
- Prefer const over let
EOF

  # Seed with 1 custom deny rule and 1 custom PreToolUse hook
  cat > "$SETTINGS" <<'EOF'
{
  "permissions": {
    "deny": [
      "Read ~/my-custom-secret.txt"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'echo custom hook'"
          }
        ]
      }
    ]
  }
}
EOF

  # Install lite on top of existing config
  bash "$REPO_DIR/install.sh" lite

  assert_eq "$(get_deny_count)" "16" "deny count after install (15 + 1 custom)"
  assert_eq "$(get_pre_hook_count)" "4" "hook count after install (3 + 1 custom)"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit count after install"
  assert_grep "$CLAUDE_MD" "# My Project Rules" "CLAUDE.md custom content preserved after install"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md security section appended after install"

  # Uninstall lite — custom entries should survive
  bash "$REPO_DIR/uninstall.sh" lite

  assert_eq "$(jq '.permissions.deny // [] | length' "$SETTINGS")" "1" "deny count after uninstall (custom preserved)"
  assert_eq "$(jq '.hooks.PreToolUse // [] | length' "$SETTINGS")" "1" "hook count after uninstall (custom preserved)"
  assert_eq "$(jq '.hooks.UserPromptSubmit // [] | length' "$SETTINGS")" "0" "UserPromptSubmit removed after uninstall"

  # Verify it's actually the custom entries
  assert_eq "$(jq -r '.permissions.deny[0]' "$SETTINGS")" "Read ~/my-custom-secret.txt" "custom deny rule preserved"

  # Verify CLAUDE.md custom content survived uninstall
  assert_file_exists "$CLAUDE_MD" "CLAUDE.md still exists after uninstall"
  assert_grep "$CLAUDE_MD" "# My Project Rules" "CLAUDE.md custom content preserved after uninstall"
  assert_grep "$CLAUDE_MD" "Prefer const over let" "CLAUDE.md custom body preserved after uninstall"
  assert_no_grep "$CLAUDE_MD" "# Security Rules" "security section removed after uninstall"

  finish
}

# --- Dispatch ---

echo "Scenario: $SCENARIO"
echo ""

case "$SCENARIO" in
  lite-fresh)        test_lite_fresh ;;
  full-fresh)        test_full_fresh ;;
  lite-idempotent)   test_lite_idempotent ;;
  full-idempotent)   test_full_idempotent ;;
  lite-roundtrip)    test_lite_roundtrip ;;
  full-roundtrip)    test_full_roundtrip ;;
  merge-existing)    test_merge_existing ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    echo "Available: lite-fresh, full-fresh, lite-idempotent, full-idempotent, lite-roundtrip, full-roundtrip, merge-existing"
    exit 1
    ;;
esac
