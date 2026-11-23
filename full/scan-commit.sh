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
# any `cd` or `git -C` in the command, or in a script file the command runs,
# and blocks if any of them has a staged secret. A regex cannot parse shell exactly, so picking one target would let a
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
    echo "within the hook's time limit (more than ${2:-$MAX_SCAN} $1)."
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
# Increment the counter named $1; block when it passes MAX_SCAN, or $3 when
# given ($2 names it).
bump() {
  printf -v "$1" '%s' "$(( ${!1} + 1 ))"
  if [[ ${!1} -gt ${3:-$MAX_SCAN} ]]; then
    too_many "$2" "${3:-}"
  fi
}
add_cand() {
  if add_to CANDS "$1"; then
    bump CAND_COUNT "candidate directories"
  fi
}

# Script files. A commit can run inside a script the command runs, where the
# command text shows neither `git commit` nor the repo it lands in. Each script
# the command names is read (never run) and its `cd` and `git commit` lines
# join the checks below. Forms: `bash|sh|zsh|dash|ksh [opts] <file>` (also by
# path, e.g. /bin/bash), `source <file>`, `. <file>`, and `./file` or any
# path to an executable text file. Every argument word after an interpreter is
# tried as a file; words that are not files drop out. Script text is parsed
# with one grep per file, linear in its size, and only its directories that
# exist count toward the cap, so a script with many cds into a few
# directories is not blocked. Scripts the scripts run are not followed.
# WORD_CAP bounds the per-word work: past it, the command walk stops and the
# command counts as a commit (cwd scanned), and script cd words block.
SCRIPT_MAX_BYTES=262144
WORD_CAP=1024
CMD_WORDS=0
SCRIPT_CD_WORDS=0
SCRIPT_COUNT=0
SCRIPT_UNREAD=0
SCRIPT_COMMIT=0
SCRIPTS=""
# Like WORD, but also stops at a redirection or backquote (`x.sh>log`).
SWORD="((\"[^\"]*\"|'[^']*'|\\\\.|[^[:space:]\"'\\\\;&|)<>\`])+)"
CD_TOK="cd([[:blank:]]+$SWORD)+"
SH_TOK="([^[:space:]\"'\\\\;&|)<>\`]*/)?(ba|z|da|k)?sh([[:blank:]]+$SWORD)+"
SRC_TOK="(source|\\.)[[:blank:]]+$SWORD"
PATH_TOK="(\"(\\.\\.?|~)?/[^\"]*\"|'(\\.\\.?|~)?/[^']*'|(\\.\\.?|~)?/$SWORD)"
GIT_TOK="git([[:blank:]]+-[Cc][[:blank:]]+$WORD)*[[:blank:]]+commit([[:blank:]]|\$)"
LEAD="(^|[^a-zA-Z0-9_.-])"
CMD_TOK="($CD_TOK|$SH_TOK|$SRC_TOK|$PATH_TOK)"
HEAD_RE="^(cd|source|\\.|([^[:space:]]*/)?(ba|z|da|k)?sh)([[:blank:]].*)\$"
SARG_RE="^[[:blank:]]+$SWORD"

# Queue file $1 (run from directory $2) when it is a script to read. $3 is 1
# for the bare-path form, which counts only an executable text file.
add_script() {
  [[ -f $1 && -r $1 ]] || return 0
  if [[ $3 == 1 ]]; then
    [[ -x $1 ]] || return 0
    LC_ALL=C grep -Iq '' "$1" 2>/dev/null || return 0
  fi
  if add_to SCRIPTS "$2	$1"; then
    bump SCRIPT_COUNT "script files"
  fi
}

# Walk the command's cd and script tokens in order, so a relative script path
# resolves against the payload cwd and against the directory the cds lead to.
if [[ $CMD =~ (sh|source|\.|/) ]]; then
  CUR="$PWD"
  while IFS= read -r tok; do
    [[ $tok =~ ^$CMD_TOK$ ]] || tok="${tok:1}"
    if [[ $tok =~ $HEAD_RE ]]; then
      HEAD="${BASH_REMATCH[1]}"
      ARGS="${BASH_REMATCH[${#BASH_REMATCH[@]} - 1]}"
      BARE=0
    else
      HEAD=""
      ARGS=" $tok"
      BARE=1
    fi
    LAST_WORD=""
    while [[ $ARGS =~ $SARG_RE ]]; do
      LAST_WORD="${BASH_REMATCH[1]}"
      ARGS="${ARGS:${#BASH_REMATCH[0]}}"
      CMD_WORDS=$(( CMD_WORDS + 1 ))
      if [[ $CMD_WORDS -gt $WORD_CAP ]]; then
        SCRIPT_UNREAD=1
        break 2
      fi
      [[ $HEAD == cd ]] && continue
      resolve_dir "$LAST_WORD" "$PWD"
      add_script "$RESOLVED" "$CUR" "$BARE"
      resolve_dir "$LAST_WORD" "$CUR"
      add_script "$RESOLVED" "$CUR" "$BARE"
    done
    if [[ $HEAD == cd && -n $LAST_WORD ]]; then
      resolve_dir "$LAST_WORD" "$CUR"
      CUR="$RESOLVED"
    fi
  done < <(LC_ALL=C grep -aoE "$LEAD$CMD_TOK" <<< "$CMD" 2>/dev/null)
fi

# Pull each script's cd and git commit lines. A line starting with `S` heads
# each script's block (a token never starts with a capital letter). A script
# over SCRIPT_MAX_BYTES is not read: the command then counts as a commit, so
# the cwd and every repo the command names are scanned (fail closed).
SCRIPT_TOKENS=""
while IFS=$'\t' read -r from file; do
  [[ -n $file ]] || continue
  size="$(wc -c < "$file" 2>/dev/null)"
  size="${size//[[:space:]]/}"
  if [[ -z $size ]] || (( size > SCRIPT_MAX_BYTES )); then
    SCRIPT_UNREAD=1
    continue
  fi
  # Repeated git commit lines are dropped here, so a file of them stays cheap.
  TOKS="$(LC_ALL=C grep -aoE "$LEAD($CD_TOK|$GIT_TOK)" "$file" 2>/dev/null \
    | awk '{ t = $0; sub(/^[^cg]/, "", t) } t ~ /^git/ && seen[t]++ { next } { print }')"
  SCRIPT_TOKENS="$SCRIPT_TOKENS${NL}S$from${NL}$TOKS"
  if [[ "$NL$TOKS" =~ $NL[^a-zA-Z0-9_.$NL-]?git[[:blank:]] ]]; then
    SCRIPT_COMMIT=1
  fi
done <<< "$SCRIPTS"

# Only act on a commit: in the command, in a script it runs, or possibly in a
# script too large to read.
if ! [[ $CMD =~ $COMMIT_RE ]] && [[ $SCRIPT_COMMIT == 0 && $SCRIPT_UNREAD == 0 ]]; then
  exit 0
fi

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

# Each script's cds, walked from the directory the script runs in. Only
# directories that exist become candidates. Its git commit lines are deduped
# and resolved after every base is known, like the command's below.
SCRIPT_GITS=""
while IFS= read -r tok; do
  case "$tok" in
    "") continue ;;
    S*) SCUR="${tok:1}"; continue ;;
  esac
  tok="${tok#[!cg]}"
  if [[ $tok == git* ]]; then
    if add_to SCRIPT_GITS "$tok"; then
      bump COMMIT_COUNT "git commit occurrences"
    fi
    continue
  fi
  ARGS="${tok:2}"
  LAST_WORD=""
  while [[ $ARGS =~ $SARG_RE ]]; do
    bump SCRIPT_CD_WORDS "cd arguments in script files" "$WORD_CAP"
    LAST_WORD="${BASH_REMATCH[1]}"
    ARGS="${ARGS:${#BASH_REMATCH[0]}}"
    for base in "$PWD" "$SCUR"; do
      resolve_dir "$LAST_WORD" "$base"
      if [[ -d $RESOLVED ]]; then
        add_cand "$RESOLVED"
        add_to BASES "$RESOLVED" || true
      fi
    done
  done
  if [[ -n $LAST_WORD ]]; then
    resolve_dir "$LAST_WORD" "$SCUR"
    SCUR="$RESOLVED"
  fi
done <<< "$SCRIPT_TOKENS"

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

# The scripts' unique git commit lines, each `-C` resolved the same way but
# kept only when the directory exists.
while IFS= read -r tok; do
  [[ -n $tok ]] || continue
  OPTS="${tok#git}"
  DIRS="$BASES"
  while [[ $OPTS =~ $OPT_RE ]]; do
    bump OPT_WORDS "git -C / -c options"
    OPTS="${OPTS:${#BASH_REMATCH[0]}}"
    if [[ "${BASH_REMATCH[1]}" == "C" ]]; then
      OPT_WORD="${BASH_REMATCH[2]}"
      NEW_DIRS=""
      while IFS= read -r base; do
        [[ -n $base ]] || continue
        resolve_dir "$OPT_WORD" "$base"
        if [[ -d $RESOLVED ]]; then
          add_cand "$RESOLVED"
          NEW_DIRS="$NEW_DIRS$NL$RESOLVED"
        fi
      done <<< "$DIRS$NL$PWD"
      DIRS="${NEW_DIRS#"$NL"}"
    fi
  done
done <<< "$SCRIPT_GITS"

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
  echo "scans the session cwd and every repo the command, or a script file it"
  echo "runs, names with cd or -C, so a secret staged in any of them blocks"
  echo "this commit."
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
