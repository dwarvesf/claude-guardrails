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
#
# Fail closed on the target repo: the hook does not guess which repo the
# commit lands in. It scans the payload cwd (always) plus every repo named by
# any `cd` or `git -C` in the command, and blocks if any of them has a staged
# secret. A regex cannot parse shell exactly, so picking one target would let a
# crafted command steer the scan away from the repo that holds the secret.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="${CLAUDE_GUARDRAILS_PATTERNS:-$SCRIPT_DIR/../patterns/secrets.json}"

INPUT="$(cat)"

# Fail-open on malformed JSON.
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"

# A shell word: one or more double-quoted, single-quoted, backslash-escaped, or
# bare segments (so `-c user.name="A B"`, `"/path with space"` and
# `/path\ with\ space` are each one word).
WORD="((\"[^\"]*\"|'[^']*'|\\\\.|[^[:space:]\"'\\\\;&|)])+)"

# Only act on `git commit` (leave git commit-tree, commit-graph plumbing alone).
# The word boundary after `commit` prevents matching `git commit-tree`, and the
# required whitespace before handles chained commands (`... && git commit ...`).
# Global `-C <dir>` / `-c <k=v>` options may sit between `git` and `commit`.
COMMIT_RE="(^|[^a-zA-Z0-9_-])git([[:space:]]+-[Cc][[:space:]]+$WORD)*[[:space:]]+commit([[:space:]]|\$)"
if ! [[ $CMD =~ $COMMIT_RE ]]; then
  exit 0
fi

# Claude Code passes cwd at the top level of the hook payload.
CWD="$(echo "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty')"
if [[ -n "$CWD" && -d "$CWD" ]]; then
  cd "$CWD" || exit 0
fi

# Resolve a shell word ($1) to a path against base dir $2, into RESOLVED:
# expand a leading unquoted `~`, drop quote and escape characters, prefix
# relative paths. Sets a variable instead of printing to avoid a fork per call.
resolve_dir() {
  local d="$1"
  case "$d" in
    "~") d="$HOME" ;;
    "~/"*) d="$HOME/${d#\~/}" ;;
  esac
  d="${d//\"/}"
  d="${d//\'/}"
  d="${d//\\/}"
  case "$d" in
    /*) RESOLVED="$d" ;;
    *) RESOLVED="$2/$d" ;;
  esac
}

# Newline-separated sets. CANDS: directories that may hold the commit's repo.
# BASES: directories a relative `-C` may resolve against.
NL=$'\n'
CANDS="$PWD"
BASES="$PWD"
# Add $2 to the set named $1 unless already present.
add_to() {
  local current="${!1}"
  case "$NL$current$NL" in
    *"$NL$2$NL"*) ;;
    *) printf -v "$1" '%s%s%s' "$current" "$NL" "$2" ;;
  esac
}

# Every `cd` in the command, each argument word resolved two ways: against the
# directory the previous `cd`s led to (bash's view), and raw against the
# payload cwd (in case the compose misreads the shell). Option words such as
# `-P` or `--` become non-directory candidates and drop out below. Each loop
# consumes the matched text, so the walk is linear in the command length.
CUR="$PWD"
REST="$CMD"
CD_RE="(^|[^a-zA-Z0-9_./-])cd([[:blank:]].*)"
ARG_RE="^[[:blank:]]+$WORD"
while [[ $REST =~ $CD_RE ]]; do
  ARGS="${BASH_REMATCH[2]}"
  LAST_WORD=""
  while [[ $ARGS =~ $ARG_RE ]]; do
    LAST_WORD="${BASH_REMATCH[1]}"
    ARGS="${ARGS:${#BASH_REMATCH[0]}}"
    resolve_dir "$LAST_WORD" "$PWD"
    add_to CANDS "$RESOLVED"
    add_to BASES "$RESOLVED"
    resolve_dir "$LAST_WORD" "$CUR"
    add_to CANDS "$RESOLVED"
    add_to BASES "$RESOLVED"
  done
  if [[ -n "$LAST_WORD" ]]; then
    resolve_dir "$LAST_WORD" "$CUR"
    CUR="$RESOLVED"
  fi
  REST="$ARGS"
done

# Every `git ... commit` occurrence, not just the first, so a decoy commit
# cannot hide the real one. Each `-C` resolves against every base (chained
# within one invocation, as git does) and raw against the payload cwd.
REST="$CMD"
FIND_RE="$COMMIT_RE(.*)"
OPT_RE="^[[:space:]]+-([Cc])[[:space:]]+$WORD"
while [[ $REST =~ $FIND_RE ]]; do
  NEXT="${BASH_REMATCH[$(( ${#BASH_REMATCH[@]} - 1 ))]}"
  OPTS="${BASH_REMATCH[0]#*git}"
  DIRS="$BASES"
  while [[ $OPTS =~ $OPT_RE ]]; do
    OPTS="${OPTS:${#BASH_REMATCH[0]}}"
    if [[ "${BASH_REMATCH[1]}" == "C" ]]; then
      OPT_WORD="${BASH_REMATCH[2]}"
      NEW_DIRS=""
      while IFS= read -r base; do
        resolve_dir "$OPT_WORD" "$base"
        add_to CANDS "$RESOLVED"
        NEW_DIRS="$NEW_DIRS$NL$RESOLVED"
      done <<< "$DIRS"
      resolve_dir "$OPT_WORD" "$PWD"
      add_to CANDS "$RESOLVED"
      DIRS="${NEW_DIRS#"$NL"}$NL$RESOLVED"
    fi
  done
  REST="$NEXT"
done

# Keep candidates that are inside a git work tree, deduped by top level.
REPOS=""
while IFS= read -r dir; do
  [[ -n "$dir" && -d "$dir" ]] || continue
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || continue
  [[ -n "$top" ]] || continue
  add_to REPOS "$top"
done <<< "$CANDS"
REPOS="${REPOS#"$NL"}"

# If no candidate is a git repo, let git itself produce the error.
if [[ -z "$REPOS" ]]; then
  exit 0
fi

# Print the names of patterns matched by the staged diff of repo $1.
scan_repo() {
  local repo="$1" diff added
  # Scan only staged changes, not the entire file. This avoids re-flagging
  # secrets that were already committed before the hook existed, and keeps
  # the scan bounded to what's about to be recorded.
  diff="$(git -C "$repo" diff --cached --unified=0 --no-color 2>/dev/null || true)"
  if [[ -z "$diff" ]]; then
    return 0
  fi

  # Extract only the added-line content (lines starting with "+"), skipping
  # the "+++" file-header lines that otherwise leak path strings into the scan.
  #
  # One narrow exemption: Cargo.lock lists a SHA-256 `checksum = "<64 hex>"` per
  # crate, which the 64-hex rule would otherwise block on every lockfile change.
  # A line is dropped only when BOTH hold: the file's basename is exactly
  # `Cargo.lock` (taken from the `+++` header, honoured only between a
  # `diff --git` line and its first `@@` so an added content line can never spoof
  # it), AND the line matches exactly `^checksum = "[0-9a-f]{64}"$`. Everything
  # else, including every other Cargo.lock line, is scanned as before. The 64-char
  # check uses length() (12-char prefix + 64 + closing quote = 77) because mawk
  # builds without regex intervals would not honour `{64}`.
  added="$(echo "$diff" | awk '
    /^diff --git / { hdr = 1; cargo = 0; next }
    /^@@/          { hdr = 0 }
    /^\+\+\+ /     {
      if (hdr) {
        path = substr($0, 5)
        sub(/\t.*$/, "", path)
        gsub(/"/, "", path)
        n = split(path, parts, "/")
        cargo = (parts[n] == "Cargo.lock")
      }
      next
    }
    /^\+/ {
      line = substr($0, 2)
      if (cargo && length(line) == 77 && line ~ /^checksum = "[0-9a-f]+"$/) next
      print line
    }
  ')"

  if [[ -z "$added" ]]; then
    return 0
  fi

  if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "scan-commit: patterns file not found at $PATTERNS_FILE (skipping scan)" >&2
    exit 0
  fi

  jq -Rsr --slurpfile pats "$PATTERNS_FILE" '
    . as $text |
    $pats[0]
    | map(select(.r as $r | $text | test($r)))
    | map(.n) | .[]
  ' <<< "$added"
}

# Note: the BIP39 wordlist check lives only in scan-secrets.sh (the prompt
# scanner), not here. Running it on committed code produces too many false
# positives on legitimate content - documentation, comments, BIP39 test
# fixtures, and the wordlist file itself. The labeled-secret regex in
# patterns/secrets.json already catches `mnemonic: "..."` / `seed_phrase: "..."`
# assignments, which is the realistic commit-time leak path.

REPORT=""
while IFS= read -r repo; do
  HITS="$(scan_repo "$repo")"
  if [[ -z "$HITS" ]]; then
    continue
  fi
  # Show which staged files contain changes so the user knows where to look.
  FILES="$(git -C "$repo" diff --cached --name-only 2>/dev/null | head -10)"
  REPORT="$REPORT${NL}Repository: $repo${NL}  Matched pattern(s):${NL}$(echo "$HITS" | sed 's/^/    - /')${NL}  Files with staged changes:${NL}$(echo "$FILES" | sed 's/^/    /')${NL}"
done <<< "$REPOS"

if [[ -z "$REPORT" ]]; then
  exit 0
fi

{
  echo ""
  echo "==================== SECRET DETECTED — COMMIT BLOCKED ===================="
  echo ""
  echo "Staged changes matched secret pattern(s) in the repo(s) below. The hook"
  echo "scans the session cwd and every repo the command names with cd or -C,"
  echo "so a secret staged in any of them blocks this commit."
  echo "$REPORT"
  echo "The commit was NOT created."
  echo ""
  echo "To resolve:"
  echo "  1. If real: rotate the credential on the upstream service NOW, then"
  echo "     remove the secret from the working tree and re-stage a clean diff."
  echo "     Use 'git restore --staged <file>' to unstage the current change."
  echo "  2. If false positive (commit SHA, hash, unrelated identifier):"
  echo "     stage smaller chunks until the matching one is isolated, or"
  echo "     rephrase the content to avoid the pattern."
  echo "  3. If the secret sits in another repo than the one you commit in,"
  echo "     unstage it there or commit from a session whose cwd is clean."
  echo ""
  echo "=========================================================================="
} >&2
exit 2
