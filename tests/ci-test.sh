#!/usr/bin/env bash
# ci-test.sh — CI test runner for install/uninstall scenarios
# Usage: bash tests/ci-test.sh <scenario>
#
# Safety: this script ALWAYS runs with HOME overridden to a fresh temp dir.
# install.sh and uninstall.sh resolve ~/.claude via $HOME, so the tests
# cannot touch a real user home directory. There is no env-var escape hatch.
set -euo pipefail

SCENARIO="${1:?Usage: ci-test.sh <scenario>}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Isolate HOME to a temp directory ---
# Create a throwaway $HOME for this test run. install.sh reads $HOME, so
# redirecting it here is sufficient to sandbox every file operation.
TEST_HOME="$(mktemp -d -t claude-guardrails-test.XXXXXX)"
export HOME="$TEST_HOME"

# Defence in depth: abort if $HOME ever resolves to anything that looks like
# a real user home (prevents regressions if someone refactors this file).
case "$HOME" in
  /Users/*|/home/*|/root)
    echo "FATAL: refusing to run with HOME=$HOME (looks like a real user home)"
    exit 1
    ;;
esac

cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

echo "Sandboxed HOME: $TEST_HOME"

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

# Claude Code silently discards any settings.json whose $schema is not the
# schemastore URL. This bug shipped undetected from initial commit through
# v0.3.4 and was fixed in PR #3. Every fresh-install scenario asserts this
# so a typo or bad merge never causes guardrails to become no-ops again.
EXPECTED_SCHEMA="https://json.schemastore.org/claude-code-settings.json"

get_schema() {
  jq -r '."$schema" // "(missing)"' "$SETTINGS"
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
  # Safe by construction: $CLAUDE_DIR lives inside $TEST_HOME (a mktemp dir)
  # because we export HOME at script start. The case check above guarantees
  # we never reach this line with a real user home.
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
  assert_eq "$(get_schema)" "$EXPECTED_SCHEMA" "\$schema is schemastore URL (lite)"
  assert_eq "$(get_deny_count)" "21" "deny rule count"
  assert_eq "$(get_pre_hook_count)" "4" "PreToolUse hook count"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count"
  assert_file_exists "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script is executable"
  assert_file_exists "$CLAUDE_DIR/hooks/scan-commit/scan-commit.sh" "scan-commit script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/scan-commit/scan-commit.sh" "scan-commit script is executable"
  assert_file_exists "$CLAUDE_DIR/hooks/patterns/secrets.json" "shared patterns file exists"
  assert_file_exists "$CLAUDE_MD" "CLAUDE.md created"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md contains Security Rules heading"

  finish
}

test_full_fresh() {
  echo "=== full-fresh: Install full on clean ~/.claude/ ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" full

  assert_file_exists "$SETTINGS" "settings.json created"
  assert_eq "$(get_schema)" "$EXPECTED_SCHEMA" "\$schema is schemastore URL (full)"
  assert_eq "$(get_deny_count)" "40" "deny rule count"
  assert_eq "$(get_pre_hook_count)" "6" "PreToolUse hook count"
  assert_eq "$(get_post_hook_count)" "1" "PostToolUse hook count"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count"
  assert_file_exists "$CLAUDE_DIR/hooks/prompt-injection-defender/prompt-injection-defender.sh" "defender script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/prompt-injection-defender/prompt-injection-defender.sh" "defender script is executable"
  assert_file_exists "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/scan-secrets/scan-secrets.sh" "scan-secrets script is executable"
  assert_file_exists "$CLAUDE_DIR/hooks/scan-commit/scan-commit.sh" "scan-commit script exists"
  assert_file_executable "$CLAUDE_DIR/hooks/scan-commit/scan-commit.sh" "scan-commit script is executable"
  assert_file_exists "$CLAUDE_DIR/hooks/patterns/secrets.json" "shared patterns file exists"
  assert_file_exists "$CLAUDE_MD" "CLAUDE.md created"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md contains Security Rules heading"

  finish
}

test_lite_idempotent() {
  echo "=== lite-idempotent: Install lite twice, counts unchanged ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite
  bash "$REPO_DIR/install.sh" lite

  assert_eq "$(get_deny_count)" "21" "deny rule count after double install"
  assert_eq "$(get_pre_hook_count)" "4" "PreToolUse hook count after double install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit hook count after double install"
  assert_grep "$CLAUDE_MD" "# Security Rules" "CLAUDE.md still contains Security Rules"

  finish
}

test_lite_roundtrip() {
  echo "=== lite-roundtrip: Install lite then uninstall lite ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite

  # Sanity check install worked
  assert_eq "$(get_deny_count)" "21" "deny count after install"
  assert_eq "$(get_pre_hook_count)" "4" "PreToolUse count after install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit count after install"

  bash "$REPO_DIR/uninstall.sh" lite

  assert_eq "$(jq '.permissions.deny // [] | length' "$SETTINGS")" "0" "deny count after uninstall"
  assert_eq "$(jq '.hooks.PreToolUse // [] | length' "$SETTINGS")" "0" "PreToolUse count after uninstall"
  assert_eq "$(jq '.hooks.UserPromptSubmit // [] | length' "$SETTINGS")" "0" "UserPromptSubmit count after uninstall"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/scan-secrets" "scan-secrets dir removed"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/scan-commit" "scan-commit dir removed"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/patterns" "patterns dir removed"
  # CLAUDE.md should be deleted (was only security rules)
  assert_file_not_exists "$CLAUDE_MD" "CLAUDE.md removed (was empty)"

  finish
}

test_full_roundtrip() {
  echo "=== full-roundtrip: Install full then uninstall full ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" full

  # Sanity check install worked
  assert_eq "$(get_deny_count)" "40" "deny count after install"
  assert_eq "$(get_pre_hook_count)" "6" "PreToolUse count after install"
  assert_eq "$(get_prompt_hook_count)" "1" "UserPromptSubmit count after install"

  bash "$REPO_DIR/uninstall.sh" full

  assert_eq "$(jq '.permissions.deny // [] | length' "$SETTINGS")" "0" "deny count after uninstall"
  assert_eq "$(jq '.hooks.PreToolUse // [] | length' "$SETTINGS")" "0" "PreToolUse count after uninstall"
  assert_eq "$(jq '.hooks.UserPromptSubmit // [] | length' "$SETTINGS")" "0" "UserPromptSubmit count after uninstall"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/prompt-injection-defender" "defender dir removed"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/scan-secrets" "scan-secrets dir removed"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/scan-commit" "scan-commit dir removed"
  assert_dir_not_exists "$CLAUDE_DIR/hooks/patterns" "patterns dir removed"
  # CLAUDE.md should be deleted (was only security rules)
  assert_file_not_exists "$CLAUDE_MD" "CLAUDE.md removed (was empty)"

  finish
}

test_full_idempotent() {
  echo "=== full-idempotent: Install full twice, counts unchanged ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" full
  bash "$REPO_DIR/install.sh" full

  assert_eq "$(get_deny_count)" "40" "deny count after double install"
  assert_eq "$(get_pre_hook_count)" "6" "PreToolUse hook count after double install"
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

  assert_eq "$(get_schema)" "$EXPECTED_SCHEMA" "\$schema set after merging into schemaless existing config"
  assert_eq "$(get_deny_count)" "22" "deny count after install (21 + 1 custom)"
  assert_eq "$(get_pre_hook_count)" "5" "hook count after install (4 + 1 custom)"
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

test_scan_commit() {
  echo "=== scan-commit: Functional test of the installed PreToolUse hook ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite

  HOOK="$CLAUDE_DIR/hooks/scan-commit/scan-commit.sh"
  assert_file_executable "$HOOK" "scan-commit hook is executable"

  # Build a throwaway git repo inside the sandboxed HOME so the hook has
  # a real git index to inspect. Any diff/commit here is isolated from
  # the host by virtue of HOME being a mktemp dir.
  REPO="$HOME/scan-commit-fixture"
  mkdir -p "$REPO"
  ( cd "$REPO" \
      && git init -q \
      && git config user.email test@example.com \
      && git config user.name "Scan Commit Test" )

  # Case 1: clean staged diff — hook must allow (exit 0)
  echo "clean code here" > "$REPO/foo.js"
  ( cd "$REPO" && git add foo.js )
  CLEAN_INPUT="$(jq -n --arg cwd "$REPO" '{tool_input:{command:"git commit -m test"}, cwd:$cwd}')"
  if echo "$CLEAN_INPUT" | "$HOOK" >/dev/null 2>&1; then
    echo "  PASS: clean staged diff allowed (exit 0)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: clean staged diff blocked (should have allowed)"
    FAIL=$((FAIL + 1))
  fi

  # Case 2: stage an AWS key — hook must block (exit 2)
  echo "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" >> "$REPO/foo.js"
  ( cd "$REPO" && git add foo.js )
  DIRTY_INPUT="$(jq -n --arg cwd "$REPO" '{tool_input:{command:"git commit -m test"}, cwd:$cwd}')"
  set +e
  echo "$DIRTY_INPUT" | "$HOOK" >/dev/null 2>&1
  EXIT=$?
  set -e
  assert_eq "$EXIT" "2" "staged AWS key blocked (exit 2)"

  # Case 3: non-commit Bash command — hook must pass through (exit 0)
  NON_COMMIT="$(jq -n --arg cwd "$REPO" '{tool_input:{command:"git status"}, cwd:$cwd}')"
  if echo "$NON_COMMIT" | "$HOOK" >/dev/null 2>&1; then
    echo "  PASS: non-commit command passed through (exit 0)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: non-commit command blocked (should have passed through)"
    FAIL=$((FAIL + 1))
  fi

  # Case 4: `git commit-tree` plumbing — must not be misread as `git commit`
  PLUMBING="$(jq -n --arg cwd "$REPO" '{tool_input:{command:"git commit-tree deadbeef"}, cwd:$cwd}')"
  if echo "$PLUMBING" | "$HOOK" >/dev/null 2>&1; then
    echo "  PASS: git commit-tree plumbing not intercepted"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: git commit-tree was intercepted (false positive on word boundary)"
    FAIL=$((FAIL + 1))
  fi

  # Case 5: chained command `git add && git commit` with staged AWS key — must block.
  # Claude Code commonly bundles add + commit in a single Bash call, so the matcher
  # has to recognise `git commit` when it sits after `&&` rather than at the start.
  CHAINED="$(jq -n --arg cwd "$REPO" '{tool_input:{command:"git add foo.js && git commit -m wip"}, cwd:$cwd}')"
  set +e
  echo "$CHAINED" | "$HOOK" >/dev/null 2>&1
  EXIT=$?
  set -e
  assert_eq "$EXIT" "2" "chained add && commit with AWS key blocked"

  # Case 6: heredoc-wrapped commit message — Claude's default commit flow uses
  # `git commit -m "$(cat <<'EOF' ... EOF)"`. The embedded newlines and quotes
  # must not prevent the matcher from recognising the outer `git commit`.
  HEREDOC_CMD='git commit -m "$(cat <<'\''EOF'\''
wip message
EOF
)"'
  HEREDOC="$(jq -n --arg cmd "$HEREDOC_CMD" --arg cwd "$REPO" '{tool_input:{command:$cmd}, cwd:$cwd}')"
  set +e
  echo "$HEREDOC" | "$HOOK" >/dev/null 2>&1
  EXIT=$?
  set -e
  assert_eq "$EXIT" "2" "heredoc-wrapped commit with AWS key blocked"

  # Case 7: patterns file missing — must fail open (exit 0) rather than block
  # legitimate work. A broken install should not wedge every commit.
  PATTERNS_INSTALLED="$CLAUDE_DIR/hooks/patterns/secrets.json"
  mv "$PATTERNS_INSTALLED" "$PATTERNS_INSTALLED.bak"
  set +e
  echo "$DIRTY_INPUT" | "$HOOK" >/dev/null 2>&1
  EXIT=$?
  set -e
  mv "$PATTERNS_INSTALLED.bak" "$PATTERNS_INSTALLED"
  assert_eq "$EXIT" "0" "missing patterns file fails open"

  finish
}

test_push_hook() {
  echo "=== push-hook: Functional test of direct-push-to-protected-branch guardrail ==="
  clean_claude_dir

  bash "$REPO_DIR/install.sh" lite

  # The push-protection hook is the second PreToolUse entry in the variant's
  # settings.json (after the destructive-delete hook). It is an inline
  # `bash -c '...'` command, not a separate script file, so we write it
  # back out to a temp script to invoke it directly.
  HOOK_CMD="$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$SETTINGS")"
  HOOK_WRAP="$HOME/push-hook-wrap.sh"
  printf '%s\n' "$HOOK_CMD" > "$HOOK_WRAP"

  # Helper: build tool-input JSON for a command string, feed it to the hook,
  # and return the exit code. The runtime exit contract is 2 = blocked,
  # 0 = allowed.
  run_push_hook() {
    local cmd="$1"
    local input
    input="$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}')"
    set +e
    echo "$input" | bash "$HOOK_WRAP" >/dev/null 2>&1
    local rc=$?
    set -e
    echo "$rc"
  }

  # Build the dangerous-phrase strings at runtime so this test file itself
  # does not contain literal `git push origin main` — otherwise running
  # ci-test.sh under Claude Code would trip the hook that this very test
  # is exercising. (That false-positive is why this scenario exists.)
  B="main"
  M="master"
  P="production"

  echo "  -- cases that MUST block --"
  assert_eq "$(run_push_hook "git push origin $B")"                  "2" "direct push to main blocked"
  assert_eq "$(run_push_hook "git push --force origin $B")"          "2" "force push to main blocked"
  assert_eq "$(run_push_hook "git push origin $M")"                  "2" "push to master blocked"
  assert_eq "$(run_push_hook "git push origin $P")"                  "2" "push to production blocked"
  assert_eq "$(run_push_hook "git fetch && git push origin $B")"     "2" "chained fetch && push blocked"
  assert_eq "$(run_push_hook "git status; git push origin $B")"      "2" "semicolon-chained push blocked"
  assert_eq "$(run_push_hook "(git push origin $B)")"                "2" "subshell-wrapped push blocked"

  echo "  -- cases that MUST allow (previously false-positived) --"
  assert_eq "$(run_push_hook "gh pr create --base $B --body \"see git push origin $B\"")" "0" "PR body containing trigger phrase allowed"
  assert_eq "$(run_push_hook "echo \"git push origin $B is dangerous\"")"                 "0" "echo commentary allowed"
  assert_eq "$(run_push_hook "grep 'git push origin $B' history.log")"                    "0" "grep searching for phrase allowed"
  assert_eq "$(run_push_hook "git push origin feat/foo")"                                 "0" "feature branch push allowed"
  assert_eq "$(run_push_hook "git push origin main-feature-branch")"                      "0" "branch name with 'main' prefix allowed"
  assert_eq "$(run_push_hook "git log $B..HEAD")"                                         "0" "git log (non-push) allowed"

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
  scan-commit)       test_scan_commit ;;
  push-hook)         test_push_hook ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    echo "Available: lite-fresh, full-fresh, lite-idempotent, full-idempotent, lite-roundtrip, full-roundtrip, merge-existing, scan-commit, push-hook"
    exit 1
    ;;
esac
