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
# Add $2 to the set named $1 unless already present; return 1 if present.
add_to() {
  local current="${!1}"
  case "$NL$current$NL" in
    *"$NL$2$NL"*) return 1 ;;
  esac
  printf -v "$1" '%s%s%s' "$current" "$NL" "$2"
}

# Work cap. A timed-out hook lets the commit through, so a command that names
# more than MAX_SCAN of anything is blocked before any per-candidate git call.
# The cap also keeps the string-set dedupe and the parse loops cheap.
MAX_SCAN=32
CD_COUNT=0
CD_WORDS=0
COMMIT_COUNT=0
OPT_WORDS=0
CAND_COUNT=0
too_many() {
  {
    echo ""
    echo "==================== COMMIT BLOCKED: TOO MANY DIRECTORIES TO SCAN ===================="
    echo ""
    echo "The command names too many directories to scan for staged secrets"
    echo "within the hook's time limit (more than $MAX_SCAN $1)."
    echo ""
    echo "The commit was NOT created."
    echo ""
    echo "To resolve: run the commit from inside the repo, as a short command"
    echo "of its own (cd <repo>, then git commit)."
    echo ""
    echo "======================================================================================="
  } >&2
  exit 2
}
# Increment the counter named $1; block when it passes MAX_SCAN ($2 names it).
bump() {
  printf -v "$1" '%s' "$(( ${!1} + 1 ))"
  if [[ ${!1} -gt $MAX_SCAN ]]; then
    too_many "$2"
  fi
}
add_cand() {
  if add_to CANDS "$1"; then
    bump CAND_COUNT "candidate directories"
  fi
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
  bump CD_COUNT "cd commands"
  ARGS="${BASH_REMATCH[2]}"
  LAST_WORD=""
  while [[ $ARGS =~ $ARG_RE ]]; do
    bump CD_WORDS "cd arguments"
    LAST_WORD="${BASH_REMATCH[1]}"
    ARGS="${ARGS:${#BASH_REMATCH[0]}}"
    resolve_dir "$LAST_WORD" "$PWD"
    add_cand "$RESOLVED"
    add_to BASES "$RESOLVED"
    resolve_dir "$LAST_WORD" "$CUR"
    add_cand "$RESOLVED"
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
  bump COMMIT_COUNT "git commit occurrences"
  NEXT="${BASH_REMATCH[$(( ${#BASH_REMATCH[@]} - 1 ))]}"
  OPTS="${BASH_REMATCH[0]#*git}"
  DIRS="$BASES"
  while [[ $OPTS =~ $OPT_RE ]]; do
    bump OPT_WORDS "git -C / -c options"
    OPTS="${OPTS:${#BASH_REMATCH[0]}}"
    if [[ "${BASH_REMATCH[1]}" == "C" ]]; then
      OPT_WORD="${BASH_REMATCH[2]}"
      NEW_DIRS=""
      while IFS= read -r base; do
        resolve_dir "$OPT_WORD" "$base"
        add_cand "$RESOLVED"
        NEW_DIRS="$NEW_DIRS$NL$RESOLVED"
      done <<< "$DIRS"
      resolve_dir "$OPT_WORD" "$PWD"
      add_cand "$RESOLVED"
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

  # Extract only the added-line content (lines starting with "+"). A "+++" line
  # is a file header only between a `diff --git` line and its first `@@`; inside
  # a hunk it is an added line whose content starts with "++ " and is scanned.
  #
  # One narrow exemption for every pattern: Cargo.lock lists a SHA-256
  # `checksum = "<64 hex>"` per crate. A line is dropped only when BOTH hold: the
  # file's basename is exactly `Cargo.lock` (from the `+++` header), AND the line
  # matches exactly `^checksum = "[0-9a-f]{64}"$`. The 64-char check uses
  # length() (12-char prefix + 64 + closing quote = 77) because mawk builds
  # without regex intervals would not honour `{64}`.
  #
  # Digest exemptions for the 64-hex pattern only: after the added lines and a
  # "\002" line, awk prints a digest view of the same lines that only that
  # pattern reads. The view drops lines of lockfiles and checksum files (by
  # basename), and masks a 64-hex run right after `sha256:`, `sha256: `,
  # `sha256=`, `sha256-`, `sha256 "` or `sha256 '`. Every other pattern scans
  # the full text, so a key on an exempt line or in a lockfile still blocks.
  added="$(echo "$diff" | awk '
    BEGIN {
      split("uv.lock poetry.lock Pipfile.lock package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lock go.sum Gemfile.lock flake.lock composer.lock Package.resolved SHA256SUMS", a, " ")
      for (i in a) lock[a[i]] = 1
    }
    /^diff --git /    { hdr = 1; cargo = 0; skip = 0; next }
    /^@@/             { hdr = 0 }
    /^\+\+\+ / && hdr {
      path = substr($0, 5)
      sub(/\t.*$/, "", path)
      gsub(/"/, "", path)
      n = split(path, parts, "/")
      cargo = (parts[n] == "Cargo.lock")
      skip = (parts[n] in lock) || parts[n] ~ /\.sha256$/
      next
    }
    /^\+/ {
      line = substr($0, 2)
      gsub(/\002/, "?", line)
      if (cargo && length(line) == 77 && line ~ /^checksum = "[0-9a-f]+"$/) next
      print line
      if (skip) next
      d = ""
      while (match(line, /sha256(: ?|=|-| "| \047)[0-9a-fA-F]+/)) {
        d = d substr(line, 1, RSTART - 1)
        m = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        match(m, /[0-9a-fA-F]+$/)
        d = d (RLENGTH == 64 ? substr(m, 1, RSTART - 1) "<sha256>" : m)
      }
      dv[++k] = d line
    }
    END { print "\002"; for (i = 1; i <= k; i++) print dv[i] }
  ')"

  if [[ "$added" == $'\002' ]]; then
    return 0
  fi

  if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "scan-commit: patterns file not found at $PATTERNS_FILE (skipping scan)" >&2
    exit 0
  fi

  jq -Rsr --slurpfile pats "$PATTERNS_FILE" '
    split("\u0002\n") as [$text, $digest] |
    $pats[0]
    | map(select(.r as $r
        | (if (.n | startswith("Hex private key")) then $digest else $text end)
        | test($r)))
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
